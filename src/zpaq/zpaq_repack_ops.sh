#!/usr/bin/env bash
# ============================================================
# src/zpaq/zpaq_repack_ops.sh — zpaq Repack Operations
#
# Implements a three-stage extract → compress → upload pipeline used by
# repack_zpaq.sh to recompress files stored inside .zpaq archives to
# .bz2 format and upload them to an SFTP server.
#
# Stage 1 — Extract worker:
#   zpaqfranz x <pattern> <internal_path> <dir> -threads N
#   Extracts to a tmpfs ramdisk (if headroom available) or disk fallback.
#   First extraction uses THREADS_FIRST_EXTRACT (nproc-1); all subsequent
#   extractions use THREADS_PIPELINE (floor((nproc-1)/2)).
#
# Stage 2 — Compress worker:
#   pbzip2 -9 -c -p<N> -b<N> -m<N> <extracted_file>
#       | tee >(sha256sum > .sha256.tmp)
#       > .bz2.tmp
#   Reads from the extracted file on ramdisk/disk. On completion the
#   extract dir is removed immediately (freeing RAM or disk space).
#
# Stage 3 — Upload worker:
#   Atomic SFTP: put to .tmp_upload → re-download → sha256 verify → rename.
#
# Queue layout (all under REPACK_QUEUE_DIR):
#   extract/<N>.pending   — main loop → extract worker
#   compress/<N>.pending  — extract worker → compress worker
#   upload/<N>.queued     — compress worker → upload worker
#   upload/<N>.done       — upload worker success
#   upload/<N>.failed     — upload worker failure
#
# Each worker propagates a DONE_SENTINEL to its downstream queue when
# it has drained its input queue and seen the upstream sentinel:
#   extract/DONE_SENTINEL  — written by main loop
#   compress/DONE_SENTINEL — written by extract worker on exit
#   upload/DONE_SENTINEL   — written by compress worker on exit
#
# Required globals (set by repack_zpaq.sh):
#   ZPAQFRANZ_BIN           — from detect_zpaqfranz()
#   SFTP_HOST, SFTP_PORT, SFTP_USER, SFTP_PASS
#   REPACK_QUEUE_DIR        — root queue directory
#   RAMDISK_PATH            — tmpfs mount point
#   RAMDISK_AVAILABLE       — "true" if tmpfs mounted successfully
#   RAMDISK_CAP_BYTES       — tmpfs size cap in bytes (MemAvailable/2 at mount time)
#   REPACK_OUTPUT_DIR       — local output directory for .bz2 files
#   REPACK_REMOTE_DIR_RESOLVED — remote SFTP base directory
#   REPACK_VERIFY_DIR       — ephemeral dir for re-download verification files
#   THREADS_FIRST_EXTRACT   — thread count for first zpaqfranz extraction
#   THREADS_PIPELINE        — thread count for subsequent extract + pbzip2
#   PBZIP2_BLOCK            — pbzip2 -b value
#   PBZIP2_MEMORY           — pbzip2 -m value
#   LOG_FILE                — from setup_repack_logging()
#
# Dependency order:
#   Must be sourced after:
#     src/core/logging.sh       (uses log())
#     src/zpaq/zpaq_utils.sh    (uses ZPAQFRANZ_BIN)
#     src/zpaq/zpaq_sftp_ops.sh (uses _zpaq_sftp_run())
# ============================================================

# ---------------------------------------------------------------------------
# Monotonic counter for queue file ordering — seeded from existing queue
# items by repack_zpaq.sh main() on startup.
# ---------------------------------------------------------------------------
_REPACK_QUEUE_COUNTER=0

# Tracks whether the first extraction has already run this session.
_FIRST_EXTRACT_DONE=false

# ============================================================
# Logging helper for functions called inside $(...)
# ============================================================

# _subshell_log LEVEL MESSAGE
# Writes directly to LOG_FILE + stderr. Safe inside $(...) subshells where
# log() must not be used (log() writes to stdout, polluting captured output).
_subshell_log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[${timestamp}] [${level}]  ${message}"
    echo "${line}" >> "${LOG_FILE:-/dev/null}"
    echo "${line}" >&2
}

# ============================================================
# list_zpaq_files ZPAQ_PATTERN
# ============================================================
# Runs "zpaqfranz l <ZPAQ_PATTERN>" and prints one line per stored file:
#   <uncompressed_bytes>\t<internal/path>
#
# The size field uses European dot thousand-separators (e.g. 6.405.382.298)
# which are stripped before output. Only "+" (stored) entries are included;
# "-" (deleted) entries and header/summary lines are excluded.
#
# Multipart archives: ZPAQ_PATTERN may contain "???????" wildcards and is
# passed directly to zpaqfranz, which handles multipart internally.
#
# IMPORTANT: Called inside $(...) — uses _subshell_log() not log().
# Returns 0 on success, 1 on error or empty listing.
# ============================================================
list_zpaq_files() {
    local zpaq_pattern="$1"

    _subshell_log "INFO" "list_zpaq_files: listing ${zpaq_pattern}"

    local raw_output rc=0
    raw_output=$("${ZPAQFRANZ_BIN}" l "${zpaq_pattern}" 2>/dev/null) || rc=$?

    if (( rc != 0 )); then
        _subshell_log "ERROR" "list_zpaq_files: zpaqfranz l failed (rc=${rc}) for: ${zpaq_pattern}"
        return 1
    fi

    # Parse data lines: date field present + " + " marker present.
    # Field layout (after leading optional whitespace):
    #   $1=date  $2=time  $3=size(dots)  $4=ratio%  $5="+"  $6...=path
    # We use index() to find " + " and extract everything after it as the
    # path, avoiding any whitespace splitting issues in the path itself.
    # Size is field $3 with dots stripped.
    local file_list
    file_list=$(printf '%s\n' "${raw_output}" \
        | awk '/[0-9]{4}-[0-9]{2}-[0-9]{2}/ && / \+ / {
            idx = index($0, " + ")
            if (idx > 0) {
                path = substr($0, idx + 3)
                sub(/\r$/, "", path)
                sub(/[[:space:]]+$/, "", path)
                if (path == "") next
                # Extract size field (3rd whitespace-delimited token)
                # and strip European dot thousand-separators
                size = $3
                gsub(/\./, "", size)
                if (size !~ /^[0-9]+$/) size = "0"
                print size "\t" path
            }
        }')

    if [[ -z "${file_list}" ]]; then
        _subshell_log "WARN" "list_zpaq_files: no stored files found in ${zpaq_pattern}"
        return 1
    fi

    local count
    count=$(printf '%s\n' "${file_list}" | wc -l | tr -d '[:space:]')
    _subshell_log "INFO" "list_zpaq_files: found ${count} file(s) in ${zpaq_pattern}"

    printf '%s\n' "${file_list}"
    return 0
}

# ============================================================
# Ramdisk management
# ============================================================

# ramdisk_mount
# Reads MemAvailable from /proc/meminfo, halves it, and mounts a tmpfs at
# RAMDISK_PATH with that size cap. Sets RAMDISK_AVAILABLE=true on success.
# Falls back gracefully on failure (RAMDISK_AVAILABLE=false).
ramdisk_mount() {
    local mem_avail_kb
    mem_avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)

    if (( mem_avail_kb == 0 )); then
        log "WARN" "ramdisk_mount: cannot read MemAvailable — falling back to disk"
        RAMDISK_AVAILABLE="false"
        return 0
    fi

    # Half of available RAM in bytes
    local cap_bytes=$(( mem_avail_kb * 1024 / 2 ))
    RAMDISK_CAP_BYTES="${cap_bytes}"

    local cap_human
    cap_human=$(awk -v b="${cap_bytes}" 'BEGIN { printf "%.1f GiB", b/1073741824 }')

    mkdir -p "${RAMDISK_PATH}"
    log "INFO" "ramdisk_mount: mounting tmpfs at ${RAMDISK_PATH} (cap=${cap_human})"

    local rc=0
    sudo mount -t tmpfs -o "size=${cap_bytes}" tmpfs "${RAMDISK_PATH}" || rc=$?

    if (( rc != 0 )); then
        log "WARN" "ramdisk_mount: sudo mount failed (rc=${rc}) — falling back to disk for all extractions"
        RAMDISK_AVAILABLE="false"
        rmdir "${RAMDISK_PATH}" 2>/dev/null || true
        return 0
    fi

    RAMDISK_AVAILABLE="true"
    log "INFO" "ramdisk_mount: mounted OK (cap=${cap_human}, RAMDISK_AVAILABLE=true)"
    return 0
}

# ramdisk_umount
# Unmounts the tmpfs ramdisk. Called from trap_cleanup in repack_zpaq.sh.
ramdisk_umount() {
    if [[ "${RAMDISK_AVAILABLE:-false}" != "true" ]]; then
        return 0
    fi
    if ! mountpoint -q "${RAMDISK_PATH}" 2>/dev/null; then
        return 0
    fi
    log "INFO" "ramdisk_umount: unmounting ${RAMDISK_PATH}"
    sudo umount "${RAMDISK_PATH}" 2>/dev/null || \
        log "WARN" "ramdisk_umount: umount returned non-zero (may already be unmounted)"
    rmdir "${RAMDISK_PATH}" 2>/dev/null || true
}

# ramdisk_headroom
# Prints the number of free bytes remaining under the ramdisk cap.
# Uses du to measure actual current usage.
# Prints 0 if RAMDISK_AVAILABLE=false.
ramdisk_headroom() {
    if [[ "${RAMDISK_AVAILABLE:-false}" != "true" ]]; then
        echo 0
        return 0
    fi
    local used_bytes
    used_bytes=$(du -sb "${RAMDISK_PATH}" 2>/dev/null | awk '{print $1}')
    used_bytes="${used_bytes:-0}"
    local headroom=$(( RAMDISK_CAP_BYTES - used_bytes ))
    (( headroom < 0 )) && headroom=0
    echo "${headroom}"
}

# ============================================================
# extract_one_file ZPAQ_PATTERN INTERNAL_PATH UNCOMPRESSED_SIZE
#                 EXTRACT_DIR_VAR THREADS
# ============================================================
# Extracts INTERNAL_PATH from ZPAQ_PATTERN into a subdirectory, choosing
# ramdisk or disk based on available headroom.
#
# Sets the caller's EXTRACT_DIR_VAR nameref to the chosen extraction root
# directory (the parent that zpaqfranz writes into, preserving subpaths).
# The extracted file will be at: <extract_dir>/<internal_path>
#
# Returns 0 on success, 1 on error.
# ============================================================
extract_one_file() {
    local zpaq_pattern="$1"
    local internal_path="$2"
    local uncompressed_size="$3"
    local -n _extract_dir_ref="$4"
    local threads="$5"

    # Size with 10% padding
    local needed_bytes
    needed_bytes=$(awk -v s="${uncompressed_size}" 'BEGIN { printf "%d", int(s * 1.10) }')

    # Decide: ramdisk or disk?
    local use_ramdisk=false
    if [[ "${RAMDISK_AVAILABLE:-false}" == "true" ]]; then
        local headroom
        headroom=$(ramdisk_headroom)
        if (( needed_bytes > 0 && needed_bytes <= headroom )); then
            use_ramdisk=true
        else
            local headroom_gib
            headroom_gib=$(awk -v b="${headroom}" 'BEGIN { printf "%.1f", b/1073741824 }')
            local needed_gib
            needed_gib=$(awk -v b="${needed_bytes}" 'BEGIN { printf "%.1f", b/1073741824 }')
            log "DEBUG" "extract_one_file: ramdisk headroom ${headroom_gib} GiB < needed ${needed_gib} GiB — using disk"
        fi
    fi

    # Allocate extraction directory
    local counter_str
    counter_str=$(printf '%08d' "${_REPACK_QUEUE_COUNTER}")
    if [[ "${use_ramdisk}" == true ]]; then
        _extract_dir_ref="${RAMDISK_PATH}/${counter_str}"
        log "DEBUG" "extract_one_file: using ramdisk → ${_extract_dir_ref}"
    else
        _extract_dir_ref="${REPACK_TEMP_DIR}/disk/${counter_str}"
        log "DEBUG" "extract_one_file: using disk → ${_extract_dir_ref}"
    fi
    mkdir -p "${_extract_dir_ref}"

    log "INFO" "extract_one_file: extracting '${internal_path}' (threads=${threads})"

    local rc=0
    "${ZPAQFRANZ_BIN}" x "${zpaq_pattern}" "${internal_path}" \
        "${_extract_dir_ref}" -threads "${threads}" \
        | tee -a "${LOG_FILE:-/dev/null}"
    rc="${PIPESTATUS[0]}"

    if (( rc != 0 )); then
        log "ERROR" "extract_one_file: zpaqfranz x failed (rc=${rc}) for '${internal_path}'"
        rm -rf "${_extract_dir_ref}"
        _extract_dir_ref=""
        return 1
    fi

    # Verify the expected output file exists
    local extracted_file="${_extract_dir_ref}/${internal_path}"
    if [[ ! -f "${extracted_file}" ]]; then
        log "ERROR" "extract_one_file: expected output not found: ${extracted_file}"
        rm -rf "${_extract_dir_ref}"
        _extract_dir_ref=""
        return 1
    fi

    log "INFO" "extract_one_file: OK '${internal_path}' → ${_extract_dir_ref}"
    return 0
}

# ============================================================
# compress_one_file EXTRACTED_FILE LOCAL_BZ2_PATH
# ============================================================
# Compresses EXTRACTED_FILE to LOCAL_BZ2_PATH using pbzip2, simultaneously
# hashing the .bz2 stream via tee+sha256sum for upload verification.
#
# Pipeline:
#   pbzip2 -9 -c -p<N> -b<N> -m<N> <extracted_file>
#       | tee >(sha256sum > <local_bz2_path>.sha256.tmp)
#       > <local_bz2_path>.tmp
#
# On success:
#   - Moves .bz2.tmp → final .bz2
#   - Fixes .sha256.tmp: replaces "-" with actual filename → .sha256
# On failure:
#   - Removes .tmp files; returns 1
#
# Returns 0 on success, 1 on error.
# ============================================================
compress_one_file() {
    local extracted_file="$1"
    local local_bz2_path="$2"

    local tmp_bz2="${local_bz2_path}.tmp"
    local tmp_sha="${local_bz2_path}.sha256.tmp"
    local final_sha="${local_bz2_path}.sha256"
    local bz2_basename
    bz2_basename=$(basename "${local_bz2_path}")

    mkdir -p "$(dirname "${local_bz2_path}")"
    rm -f "${tmp_bz2}" "${tmp_sha}"

    log "INFO" "compress_one_file: '${extracted_file}' → ${bz2_basename} (threads=${THREADS_PIPELINE})"

    # Build pbzip2 -p flag: only pass it when an explicit thread count is set.
    # THREADS_PIPELINE=0 means pbzip2 autodetects — but in practice
    # THREADS_PIPELINE is always calculated from nproc, so it's always > 0.
    local pbzip2_threads_arg=()
    if (( THREADS_PIPELINE > 0 )); then
        pbzip2_threads_arg=( "-p${THREADS_PIPELINE}" )
    fi

    local rc_pbzip2 rc_tee
    set +e
    pbzip2 -9 -c \
        "${pbzip2_threads_arg[@]}" \
        -b"${PBZIP2_BLOCK:-100}" \
        -m"${PBZIP2_MEMORY:-2000}" \
        "${extracted_file}" \
        | tee >(sha256sum > "${tmp_sha}") \
        > "${tmp_bz2}"
    rc_pbzip2="${PIPESTATUS[0]}"
    rc_tee="${PIPESTATUS[1]}"
    set -e

    if (( rc_pbzip2 != 0 || rc_tee != 0 )); then
        log "ERROR" "compress_one_file: pipeline failed (rc_pbzip2=${rc_pbzip2} rc_tee=${rc_tee}) for ${bz2_basename}"
        rm -f "${tmp_bz2}" "${tmp_sha}"
        return 1
    fi

    if [[ ! -s "${tmp_bz2}" ]]; then
        log "ERROR" "compress_one_file: output .bz2 is empty: ${tmp_bz2}"
        rm -f "${tmp_bz2}" "${tmp_sha}"
        return 1
    fi

    if [[ ! -f "${tmp_sha}" ]]; then
        log "ERROR" "compress_one_file: sha256 tmp missing: ${tmp_sha}"
        rm -f "${tmp_bz2}"
        return 1
    fi

    local hash_value
    hash_value=$(awk '{print $1}' "${tmp_sha}")
    if [[ -z "${hash_value}" ]]; then
        log "ERROR" "compress_one_file: sha256sum produced empty output for ${bz2_basename}"
        rm -f "${tmp_bz2}" "${tmp_sha}"
        return 1
    fi

    printf '%s  %s\n' "${hash_value}" "${bz2_basename}" > "${final_sha}"
    rm -f "${tmp_sha}"
    mv "${tmp_bz2}" "${local_bz2_path}"

    local bz2_size
    bz2_size=$(stat -c "%s" "${local_bz2_path}" 2>/dev/null || echo "?")
    log "INFO" "compress_one_file: OK ${bz2_basename} (${bz2_size} bytes, sha256=${hash_value})"
    return 0
}

# ============================================================
# SFTP helpers (remote_file_exists, ensure_remote_dir, upload_one_file)
# ============================================================

# remote_file_exists REMOTE_DIR REMOTE_NAME
# Returns 0 if REMOTE_DIR/REMOTE_NAME exists on SFTP server, 1 if absent.
remote_file_exists() {
    local remote_dir="$1"
    local remote_name="$2"

    log "DEBUG" "remote_file_exists: checking ${remote_dir}/${remote_name}"

    local listing rc=0
    listing=$(SSHPASS="${SFTP_PASS}" sshpass -e sftp \
                -o StrictHostKeyChecking=no \
                -o BatchMode=no \
                -P "${SFTP_PORT}" \
                "${SFTP_USER}@${SFTP_HOST}" \
                -b <(printf 'ls -1 %s\n' "${remote_dir}") \
                2>/dev/null) || rc=$?

    if (( rc != 0 )); then
        log "DEBUG" "remote_file_exists: ls failed (rc=${rc}) — treating as absent"
        return 1
    fi

    if printf '%s\n' "${listing}" | grep -qF "${remote_name}"; then
        log "DEBUG" "remote_file_exists: found ${remote_name}"
        return 0
    fi

    log "DEBUG" "remote_file_exists: not found ${remote_name}"
    return 1
}

# ensure_remote_dir REMOTE_DIR
# Creates REMOTE_DIR on SFTP; ignores errors (may already exist).
ensure_remote_dir() {
    local remote_dir="$1"
    log "DEBUG" "ensure_remote_dir: mkdir ${remote_dir}"
    _zpaq_sftp_run "mkdir ${remote_dir}" 2>/dev/null || true
    return 0
}

# upload_one_file LOCAL_BZ2_PATH SHA256_PATH REMOTE_DIR REMOTE_NAME
# Atomic SFTP upload: put → re-download → sha256 verify → rename.
# Returns 0 on success, 1 on any failure.
upload_one_file() {
    local local_bz2_path="$1"
    local sha256_path="$2"
    local remote_dir="$3"
    local remote_name="$4"

    local remote_tmp="${remote_dir}/${remote_name}.tmp_upload"
    local remote_final="${remote_dir}/${remote_name}"
    local verify_file="${REPACK_VERIFY_DIR}/${remote_name}.verify"

    log "INFO" "upload_one_file: ${remote_name} → ${remote_dir}"

    local expected_hash
    expected_hash=$(awk '{print $1}' "${sha256_path}" 2>/dev/null)
    if [[ -z "${expected_hash}" ]]; then
        log "ERROR" "upload_one_file: cannot read expected hash from ${sha256_path}"
        return 1
    fi

    # Step 1: upload to .tmp_upload
    local rc=0
    _zpaq_sftp_run "put ${local_bz2_path} ${remote_tmp}" || rc=$?
    if (( rc != 0 )); then
        log "ERROR" "upload_one_file: upload to tmp failed (rc=${rc})"
        return 1
    fi

    # Step 2: re-download for verification
    rm -f "${verify_file}"
    rc=0
    _zpaq_sftp_run "get ${remote_tmp} ${verify_file}" || rc=$?
    if (( rc != 0 )) || [[ ! -f "${verify_file}" ]]; then
        log "ERROR" "upload_one_file: re-download failed (rc=${rc})"
        _zpaq_sftp_run "rm ${remote_tmp}" || true
        rm -f "${verify_file}"
        return 1
    fi

    # Step 3: verify sha256
    local actual_hash
    actual_hash=$(sha256sum "${verify_file}" 2>/dev/null | awk '{print $1}')
    rm -f "${verify_file}"

    if [[ "${actual_hash}" != "${expected_hash}" ]]; then
        log "ERROR" "upload_one_file: sha256 mismatch for ${remote_name}"
        log "ERROR" "  expected: ${expected_hash}"
        log "ERROR" "  got:      ${actual_hash}"
        _zpaq_sftp_run "rm ${remote_tmp}" || true
        return 1
    fi
    log "DEBUG" "upload_one_file: sha256 OK"

    # Step 4: rename to final
    rc=0
    _zpaq_sftp_run "rename ${remote_tmp} ${remote_final}" || rc=$?
    if (( rc != 0 )); then
        log "ERROR" "upload_one_file: rename failed (rc=${rc})"
        _zpaq_sftp_run "rm ${remote_tmp}" || true
        return 1
    fi

    log "INFO" "upload_one_file: OK ${remote_final}"
    return 0
}

# ============================================================
# Queue helpers
# ============================================================

# _enqueue SUBDIR KEY=VALUE...
# Internal: write a queue entry file into REPACK_QUEUE_DIR/SUBDIR/.
# Increments _REPACK_QUEUE_COUNTER; uses zero-padded counter as filename.
_enqueue() {
    local subdir="$1"
    shift
    (( _REPACK_QUEUE_COUNTER++ )) || true
    local suffix="pending"
    [[ "${subdir}" == "upload" ]] && suffix="queued"
    local entry_file
    entry_file="${REPACK_QUEUE_DIR}/${subdir}/$(printf '%08d' "${_REPACK_QUEUE_COUNTER}").${suffix}"
    printf '%s\n' "$@" > "${entry_file}"
    log "DEBUG" "_enqueue: ${subdir}/$(basename "${entry_file}")"
}

# _dequeue SUBDIR SUFFIX
# Internal: find oldest entry in REPACK_QUEUE_DIR/SUBDIR with given SUFFIX.
# Prints the full path. Returns 1 if empty.
_dequeue() {
    local subdir="$1"
    local suffix="$2"
    local oldest
    oldest=$(find "${REPACK_QUEUE_DIR}/${subdir}" -maxdepth 1 -name "*.${suffix}" \
                | sort | head -1)
    if [[ -z "${oldest}" ]]; then
        return 1
    fi
    printf '%s' "${oldest}"
    return 0
}

# enqueue_extract ZPAQ_PATTERN INTERNAL_PATH UNCOMPRESSED_SIZE
enqueue_extract() {
    local zpaq_pattern="$1"
    local internal_path="$2"
    local uncompressed_size="$3"
    _enqueue "extract" \
        "zpaq_pattern=${zpaq_pattern}" \
        "internal_path=${internal_path}" \
        "uncompressed_size=${uncompressed_size}"
}

# enqueue_compress EXTRACTED_FILE EXTRACT_DIR LOCAL_BZ2_PATH SHA256_PATH REMOTE_DIR REMOTE_NAME
enqueue_compress() {
    local extracted_file="$1"
    local extract_dir="$2"
    local local_bz2_path="$3"
    local sha256_path="$4"
    local remote_dir="$5"
    local remote_name="$6"
    _enqueue "compress" \
        "extracted_file=${extracted_file}" \
        "extract_dir=${extract_dir}" \
        "local_bz2_path=${local_bz2_path}" \
        "sha256_path=${sha256_path}" \
        "remote_dir=${remote_dir}" \
        "remote_name=${remote_name}"
}

# enqueue_upload LOCAL_BZ2_PATH SHA256_PATH REMOTE_DIR REMOTE_NAME
enqueue_upload() {
    local local_bz2_path="$1"
    local sha256_path="$2"
    local remote_dir="$3"
    local remote_name="$4"
    _enqueue "upload" \
        "local_bz2_path=${local_bz2_path}" \
        "sha256_path=${sha256_path}" \
        "remote_dir=${remote_dir}" \
        "remote_name=${remote_name}"
}

# dequeue_extract — prints path of oldest extract .pending entry, returns 1 if empty
dequeue_extract() { _dequeue "extract" "pending"; }

# dequeue_compress — prints path of oldest compress .pending entry, returns 1 if empty
dequeue_compress() { _dequeue "compress" "pending"; }

# dequeue_upload — prints path of oldest upload .queued entry, returns 1 if empty
dequeue_upload() { _dequeue "upload" "queued"; }

# _read_entry ENTRY_FILE KEY...
# Reads key=value pairs from an entry file into variables named after the keys.
# Uses namerefs — caller must declare the variables before calling.
_read_entry() {
    local entry_file="$1"
    local key val line
    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        # Only assign keys that are valid shell identifiers to avoid injection
        if [[ "${key}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            printf -v "${key}" '%s' "${val}"
        fi
    done < "${entry_file}"
}

# ============================================================
# extract_worker
# ============================================================
# Background loop. Drains the extract queue, calls extract_one_file,
# and populates the compress queue. On exit writes compress/DONE_SENTINEL.
# ============================================================
extract_worker() {
    log "INFO" "extract_worker: started (PID=$$)"

    while true; do
        local entry_file=""
        entry_file=$(dequeue_extract) || true

        if [[ -z "${entry_file}" ]]; then
            if [[ -f "${REPACK_QUEUE_DIR}/extract/DONE_SENTINEL" ]]; then
                log "INFO" "extract_worker: queue empty + sentinel — exiting"
                break
            fi
            sleep 1
            continue
        fi

        # Read entry fields
        local zpaq_pattern="" internal_path="" uncompressed_size=""
        _read_entry "${entry_file}"

        if [[ -z "${zpaq_pattern}" || -z "${internal_path}" ]]; then
            log "ERROR" "extract_worker: malformed entry: ${entry_file}"
            mv "${entry_file}" "${entry_file%.pending}.failed"
            continue
        fi

        # Determine thread count: burst on first extraction, halved thereafter
        local threads
        if [[ "${_FIRST_EXTRACT_DONE}" == "false" ]]; then
            threads="${THREADS_FIRST_EXTRACT}"
            _FIRST_EXTRACT_DONE=true
            log "INFO" "extract_worker: first extraction — using ${threads} threads (burst)"
        else
            threads="${THREADS_PIPELINE}"
        fi

        # Derive output paths
        local remote_subdir remote_name remote_dir
        remote_subdir=$(dirname "${internal_path}")
        remote_name="$(basename "${internal_path}").bz2"
        if [[ "${remote_subdir}" == "." ]]; then
            remote_dir="${REPACK_REMOTE_DIR_RESOLVED}"
        else
            remote_dir="${REPACK_REMOTE_DIR_RESOLVED}/${remote_subdir}"
        fi
        local local_bz2_path="${REPACK_OUTPUT_DIR}/${internal_path}.bz2"
        local sha256_path="${local_bz2_path}.sha256"

        # Extract
        local extract_dir=""
        local extract_rc=0
        extract_one_file \
            "${zpaq_pattern}" "${internal_path}" \
            "${uncompressed_size:-0}" \
            extract_dir "${threads}" || extract_rc=$?

        if (( extract_rc != 0 )) || [[ -z "${extract_dir}" ]]; then
            log "ERROR" "extract_worker: extraction failed for '${internal_path}'"
            mv "${entry_file}" "${entry_file%.pending}.failed"
            continue
        fi

        local extracted_file="${extract_dir}/${internal_path}"

        # Mark extract entry done and enqueue to compress
        mv "${entry_file}" "${entry_file%.pending}.done"
        enqueue_compress \
            "${extracted_file}" "${extract_dir}" \
            "${local_bz2_path}" "${sha256_path}" \
            "${remote_dir}" "${remote_name}"
    done

    # Propagate sentinel downstream
    touch "${REPACK_QUEUE_DIR}/compress/DONE_SENTINEL"
    log "INFO" "extract_worker: wrote compress/DONE_SENTINEL"
    log "INFO" "extract_worker: exiting"
}

# ============================================================
# compress_worker
# ============================================================
# Background loop. Drains the compress queue, calls compress_one_file,
# removes the extraction directory (freeing RAM/disk), and populates the
# upload queue. On exit writes upload/DONE_SENTINEL.
# ============================================================
compress_worker() {
    log "INFO" "compress_worker: started (PID=$$)"

    while true; do
        local entry_file=""
        entry_file=$(dequeue_compress) || true

        if [[ -z "${entry_file}" ]]; then
            if [[ -f "${REPACK_QUEUE_DIR}/compress/DONE_SENTINEL" ]]; then
                log "INFO" "compress_worker: queue empty + sentinel — exiting"
                break
            fi
            sleep 1
            continue
        fi

        # Read entry fields
        local extracted_file="" extract_dir="" local_bz2_path="" \
              sha256_path="" remote_dir="" remote_name=""
        _read_entry "${entry_file}"

        if [[ -z "${extracted_file}" || -z "${local_bz2_path}" ]]; then
            log "ERROR" "compress_worker: malformed entry: ${entry_file}"
            mv "${entry_file}" "${entry_file%.pending}.failed"
            continue
        fi

        # Verify extracted file still exists (may have been cleaned up if script
        # was interrupted and restarted with a stale compress queue entry)
        if [[ ! -f "${extracted_file}" ]]; then
            log "ERROR" "compress_worker: extracted file missing (stale entry?): ${extracted_file}"
            mv "${entry_file}" "${entry_file%.pending}.failed"
            continue
        fi

        # Compress
        local compress_rc=0
        compress_one_file "${extracted_file}" "${local_bz2_path}" || compress_rc=$?

        # Always clean up the extraction directory to free RAM/disk
        if [[ -n "${extract_dir}" && -d "${extract_dir}" ]]; then
            rm -rf "${extract_dir}"
            log "DEBUG" "compress_worker: cleaned up extract_dir ${extract_dir}"
        fi

        if (( compress_rc != 0 )); then
            log "ERROR" "compress_worker: compression failed for $(basename "${local_bz2_path}")"
            mv "${entry_file}" "${entry_file%.pending}.failed"
            continue
        fi

        # Mark compress entry done and enqueue to upload
        mv "${entry_file}" "${entry_file%.pending}.done"
        enqueue_upload \
            "${local_bz2_path}" "${sha256_path}" \
            "${remote_dir}" "${remote_name}"
    done

    # Propagate sentinel downstream
    touch "${REPACK_QUEUE_DIR}/upload/DONE_SENTINEL"
    log "INFO" "compress_worker: wrote upload/DONE_SENTINEL"
    log "INFO" "compress_worker: exiting"
}

# ============================================================
# upload_worker
# ============================================================
# Background loop. Drains the upload queue, calls upload_one_file,
# marks entries .done or .failed. Exits when upload/DONE_SENTINEL
# exists and queue is empty.
# ============================================================
upload_worker() {
    log "INFO" "upload_worker: started (PID=$$)"

    while true; do
        local entry_file=""
        entry_file=$(dequeue_upload) || true

        if [[ -z "${entry_file}" ]]; then
            if [[ -f "${REPACK_QUEUE_DIR}/upload/DONE_SENTINEL" ]]; then
                log "INFO" "upload_worker: queue empty + sentinel — exiting"
                break
            fi
            sleep 1
            continue
        fi

        # Read entry fields
        local local_bz2_path="" sha256_path="" remote_dir="" remote_name=""
        _read_entry "${entry_file}"

        if [[ -z "${local_bz2_path}" || -z "${remote_dir}" || -z "${remote_name}" ]]; then
            log "ERROR" "upload_worker: malformed entry: ${entry_file}"
            mv "${entry_file}" "${entry_file%.queued}.failed"
            continue
        fi

        ensure_remote_dir "${remote_dir}"

        local upload_rc=0
        upload_one_file \
            "${local_bz2_path}" "${sha256_path}" \
            "${remote_dir}" "${remote_name}" || upload_rc=$?

        if (( upload_rc == 0 )); then
            mv "${entry_file}" "${entry_file%.queued}.done"
            log "INFO" "upload_worker: done ${remote_name}"
        else
            mv "${entry_file}" "${entry_file%.queued}.failed"
            log "ERROR" "upload_worker: FAILED ${remote_name}"
        fi
    done

    log "INFO" "upload_worker: exiting"
}