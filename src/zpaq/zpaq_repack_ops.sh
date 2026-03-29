#!/usr/bin/env bash
# ============================================================
# src/zpaq/zpaq_repack_ops.sh — zpaq Repack Operations
#
# Implements the extract → compress → upload pipeline used by
# repack_zpaq.sh to recompress files stored inside .zpaq archives
# to .bz2 format and upload them to an SFTP server.
#
# Public functions:
#
#   list_zpaq_files ZPAQ_PATTERN
#       Runs "zpaqfranz l <pattern>" and prints one internal file
#       path per line (only "+" stored entries; deleted "-" entries
#       and header/summary lines are excluded).
#       Output goes to stdout. Returns 0 on success, 1 on error.
#
#   remote_file_exists REMOTE_DIR REMOTE_NAME
#       Probes the SFTP server for <REMOTE_DIR>/<REMOTE_NAME>.
#       Returns 0 if the file is present, 1 if absent or on error.
#       Uses _zpaq_sftp_run from zpaq_sftp_ops.sh.
#
#   ensure_remote_dir REMOTE_DIR
#       Attempts "mkdir <REMOTE_DIR>" on the SFTP server.
#       Ignores errors (directory may already exist).
#
#   compress_one_file ZPAQ_PATTERN INTERNAL_PATH LOCAL_BZ2_PATH
#       Runs:
#         zpaqfranz x <pattern> <internal_path> -stdout
#             | pbzip2 -9 -c -b<N> -m<N>
#             | tee >(sha256sum > <local_bz2_path>.sha256.tmp)
#             > <local_bz2_path>.tmp
#       Checks all PIPESTATUS values.
#       On success: renames .tmp → final; fixes sha256 file (replaces
#       "-" placeholder with the actual filename).
#       On failure: removes .tmp files and returns 1.
#       Returns 0 on success, 1 on error.
#
#   enqueue_item LOCAL_BZ2_PATH SHA256_PATH REMOTE_DIR REMOTE_NAME
#       Writes a queue entry file into REPACK_QUEUE_DIR with a
#       monotonic counter prefix to preserve ordering.
#       Returns 0 always.
#
#   dequeue_next_item
#       Finds the oldest (lowest-numbered) .queued file in
#       REPACK_QUEUE_DIR. Prints its path to stdout.
#       Prints nothing and returns 1 if the queue is empty.
#
#   upload_one_file LOCAL_BZ2_PATH SHA256_PATH REMOTE_DIR REMOTE_NAME
#       Atomic SFTP upload:
#         1. put <local_bz2_path> → <remote_dir>/<remote_name>.tmp_upload
#         2. get <remote_dir>/<remote_name>.tmp_upload → <verify_tmp>
#         3. sha256sum <verify_tmp> vs contents of SHA256_PATH
#         4. rename .tmp_upload → <remote_dir>/<remote_name>
#       Returns 0 on success, 1 on any failure.
#
#   upload_worker
#       Background polling loop. Reads queue entry files, calls
#       upload_one_file for each, marks items .done or .failed.
#       Exits when REPACK_QUEUE_SENTINEL file exists and queue is empty.
#       Intended to be launched with: upload_worker & UPLOAD_WORKER_PID=$!
#
# Required globals (set by repack_zpaq.sh before sourcing):
#   ZPAQFRANZ_BIN       — from zpaq_utils.sh / detect_zpaqfranz()
#   SFTP_HOST, SFTP_PORT, SFTP_USER, SFTP_PASS
#                       — from load_repack_config()
#   REPACK_QUEUE_DIR    — temp dir for queue entry files
#   REPACK_QUEUE_SENTINEL — path to sentinel file (signals queue done)
#   REPACK_VERIFY_DIR   — temp dir for re-download verification files
#   PBZIP2_BLOCK        — pbzip2 -b value (default 100)
#   PBZIP2_MEMORY       — pbzip2 -m value (default 2000)
#   LOG_FILE            — from setup_repack_logging()
#
# Dependency order:
#   Must be sourced after:
#     src/core/logging.sh       (uses log())
#     src/zpaq/zpaq_utils.sh    (uses ZPAQFRANZ_BIN)
#     src/zpaq/zpaq_sftp_ops.sh (uses _zpaq_sftp_run())
# ============================================================

# ---------------------------------------------------------------------------
# Internal: monotonic counter for queue file ordering.
# Each call to enqueue_item() increments this.
# ---------------------------------------------------------------------------
_REPACK_QUEUE_COUNTER=0

# ---------------------------------------------------------------------------
# list_zpaq_files ZPAQ_PATTERN
#
# Runs "zpaqfranz l <ZPAQ_PATTERN>" and prints the internal path of every
# stored ("+") file to stdout, one per line.
#
# The listing format produced by zpaqfranz l is:
#
#   YYYY-MM-DD HH:MM:SS     <size_with_dots>   <ratio>% + <internal/path>
#
# Size uses European thousand separators (dots), which we ignore entirely.
# Only lines containing " + " after a date field are processed.
# Lines beginning with the header, separator, or summary are skipped.
#
# Multipart archives: ZPAQ_PATTERN may contain "???????" wildcards and is
# passed directly to zpaqfranz, which handles multipart internally.
#
# Returns 0 on success, 1 if zpaqfranz fails or produces no output.
# ---------------------------------------------------------------------------
list_zpaq_files() {
    local zpaq_pattern="$1"

    log "INFO" "list_zpaq_files: listing ${zpaq_pattern}"

    local raw_output
    # Run zpaqfranz l; capture stderr separately so it doesn't pollute stdout.
    # zpaqfranz exits non-zero on error; we check explicitly.
    local rc=0
    raw_output=$("${ZPAQFRANZ_BIN}" l "${zpaq_pattern}" 2>/dev/null) || rc=$?

    if (( rc != 0 )); then
        log "ERROR" "list_zpaq_files: zpaqfranz l failed (rc=${rc}) for: ${zpaq_pattern}"
        return 1
    fi

    # Parse: find data lines (start with spaces + date), extract after " + "
    # awk finds the " + " marker and prints everything after it.
    # Trims any trailing carriage returns (Windows-style CRLF from some builds).
    local file_list
    file_list=$(printf '%s\n' "${raw_output}" \
        | awk '/^[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}/ && / \+ / {
            idx = index($0, " + ")
            if (idx > 0) {
                path = substr($0, idx + 3)
                # trim trailing CR if present
                sub(/\r$/, "", path)
                # trim trailing whitespace
                sub(/[[:space:]]+$/, "", path)
                if (path != "") print path
            }
        }')

    if [[ -z "${file_list}" ]]; then
        log "WARN" "list_zpaq_files: no stored files found in ${zpaq_pattern}"
        return 1
    fi

    local count
    count=$(printf '%s\n' "${file_list}" | wc -l | tr -d '[:space:]')
    log "INFO" "list_zpaq_files: found ${count} file(s) in ${zpaq_pattern}"

    printf '%s\n' "${file_list}"
    return 0
}

# ---------------------------------------------------------------------------
# remote_file_exists REMOTE_DIR REMOTE_NAME
#
# Probes the SFTP server for the presence of REMOTE_DIR/REMOTE_NAME.
# Uses "ls -1 <remote_dir>" batch command and greps the output for the
# exact filename — same approach as zpaq_sftp_prune_backups().
#
# Returns 0 if the file exists, 1 if absent or if the ls command fails.
# ---------------------------------------------------------------------------
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
        log "DEBUG" "remote_file_exists: ls failed (rc=${rc}) for ${remote_dir} — treating as absent"
        return 1
    fi

    if printf '%s\n' "${listing}" | grep -qF "${remote_name}"; then
        log "DEBUG" "remote_file_exists: ${remote_name} found in ${remote_dir}"
        return 0
    fi

    log "DEBUG" "remote_file_exists: ${remote_name} not found in ${remote_dir}"
    return 1
}

# ---------------------------------------------------------------------------
# ensure_remote_dir REMOTE_DIR
#
# Creates REMOTE_DIR on the SFTP server if it does not already exist.
# "mkdir" errors are silently ignored — the directory likely already exists.
# Returns 0 always.
# ---------------------------------------------------------------------------
ensure_remote_dir() {
    local remote_dir="$1"

    log "DEBUG" "ensure_remote_dir: mkdir ${remote_dir}"

    # sftp returns non-zero if mkdir fails (e.g. already exists) — ignore.
    _zpaq_sftp_run "mkdir ${remote_dir}" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# compress_one_file ZPAQ_PATTERN INTERNAL_PATH LOCAL_BZ2_PATH
#
# Extracts INTERNAL_PATH from ZPAQ_PATTERN via "zpaqfranz x ... -stdout",
# pipes through pbzip2 (parallel bzip2 at level -9 with configured block/
# memory limits), and simultaneously hashes the bz2 stream via tee+sha256sum.
#
# Pipeline:
#   zpaqfranz x <pattern> <internal_path> -stdout
#       | pbzip2 -9 -c -b<PBZIP2_BLOCK> -m<PBZIP2_MEMORY>
#       | tee >(sha256sum > <local_bz2_path>.sha256.tmp)
#       > <local_bz2_path>.tmp
#
# The sha256 is of the compressed .bz2 bytes (upload/transfer integrity).
#
# On success:
#   - Moves <local_bz2_path>.tmp  → <local_bz2_path>
#   - Fixes <local_bz2_path>.sha256.tmp: replaces the "-" stdin placeholder
#     with the actual filename, writes to <local_bz2_path>.sha256
#   - Removes the .sha256.tmp file
#
# On failure:
#   - Removes both .tmp files
#   - Returns 1
#
# Globals used: ZPAQFRANZ_BIN, PBZIP2_BLOCK, PBZIP2_MEMORY, LOG_FILE
# Returns 0 on success, 1 on error.
# ---------------------------------------------------------------------------
compress_one_file() {
    local zpaq_pattern="$1"
    local internal_path="$2"
    local local_bz2_path="$3"

    local tmp_bz2="${local_bz2_path}.tmp"
    local tmp_sha="${local_bz2_path}.sha256.tmp"
    local final_sha="${local_bz2_path}.sha256"
    local bz2_basename
    bz2_basename=$(basename "${local_bz2_path}")

    # Ensure output directory exists
    mkdir -p "$(dirname "${local_bz2_path}")"

    log "INFO" "compress_one_file: extracting '${internal_path}' from ${zpaq_pattern}"
    log "INFO" "compress_one_file: output → ${local_bz2_path}"

    # Remove any stale temp files from a previous interrupted run
    rm -f "${tmp_bz2}" "${tmp_sha}"

    # Run the three-stage pipeline.
    # tee uses process substitution (requires bash, already guaranteed by
    # the #!/usr/bin/env bash shebang and set -euo pipefail in the caller).
    # We must disable set -e around this block to capture PIPESTATUS reliably —
    # set -e would exit on the first non-zero before we can inspect PIPESTATUS.
    local rc_zpaq rc_pbzip2 rc_tee
    set +e
    "${ZPAQFRANZ_BIN}" x "${zpaq_pattern}" "${internal_path}" -stdout 2>/dev/null \
        | pbzip2 -9 -c -b"${PBZIP2_BLOCK:-100}" -m"${PBZIP2_MEMORY:-2000}" \
        | tee >(sha256sum > "${tmp_sha}") \
        > "${tmp_bz2}"
    rc_zpaq="${PIPESTATUS[0]}"
    rc_pbzip2="${PIPESTATUS[1]}"
    rc_tee="${PIPESTATUS[2]}"
    set -e

    # Check all three stages
    if (( rc_zpaq != 0 || rc_pbzip2 != 0 || rc_tee != 0 )); then
        log "ERROR" "compress_one_file: pipeline failed for '${internal_path}'"
        log "ERROR" "  rc_zpaqfranz=${rc_zpaq} rc_pbzip2=${rc_pbzip2} rc_tee=${rc_tee}"
        rm -f "${tmp_bz2}" "${tmp_sha}"
        return 1
    fi

    # Verify output files exist and are non-empty
    if [[ ! -s "${tmp_bz2}" ]]; then
        log "ERROR" "compress_one_file: output .bz2 is empty or missing: ${tmp_bz2}"
        rm -f "${tmp_bz2}" "${tmp_sha}"
        return 1
    fi

    if [[ ! -f "${tmp_sha}" ]]; then
        log "ERROR" "compress_one_file: sha256 tmp file missing: ${tmp_sha}"
        rm -f "${tmp_bz2}"
        return 1
    fi

    # Fix the sha256 file: sha256sum writes "<hash>  -" when reading from stdin.
    # Replace the "-" placeholder with the actual .bz2 filename so the file is
    # directly usable with "sha256sum -c filename.sha256".
    local hash_value
    hash_value=$(awk '{print $1}' "${tmp_sha}")
    if [[ -z "${hash_value}" ]]; then
        log "ERROR" "compress_one_file: sha256sum produced empty output for '${internal_path}'"
        rm -f "${tmp_bz2}" "${tmp_sha}"
        return 1
    fi

    printf '%s  %s\n' "${hash_value}" "${bz2_basename}" > "${final_sha}"
    rm -f "${tmp_sha}"

    # Atomically move compressed output to final name
    mv "${tmp_bz2}" "${local_bz2_path}"

    local bz2_size
    bz2_size=$(stat -c "%s" "${local_bz2_path}" 2>/dev/null || echo "?")
    log "INFO" "compress_one_file: OK '${internal_path}' → ${bz2_basename} (${bz2_size} bytes, sha256=${hash_value})"
    return 0
}

# ---------------------------------------------------------------------------
# enqueue_item LOCAL_BZ2_PATH SHA256_PATH REMOTE_DIR REMOTE_NAME
#
# Writes a queue entry file to REPACK_QUEUE_DIR. The filename is prefixed
# with a zero-padded monotonic counter to guarantee FIFO ordering even when
# multiple items are enqueued within the same second.
#
# Queue entry file format (key=value, one per line):
#   local_bz2_path=<path>
#   sha256_path=<path>
#   remote_dir=<path>
#   remote_name=<filename>
#
# Returns 0 always.
# ---------------------------------------------------------------------------
enqueue_item() {
    local local_bz2_path="$1"
    local sha256_path="$2"
    local remote_dir="$3"
    local remote_name="$4"

    (( _REPACK_QUEUE_COUNTER++ )) || true

    local entry_file
    entry_file="${REPACK_QUEUE_DIR}/$(printf '%08d' "${_REPACK_QUEUE_COUNTER}").queued"

    cat > "${entry_file}" <<EOF
local_bz2_path=${local_bz2_path}
sha256_path=${sha256_path}
remote_dir=${remote_dir}
remote_name=${remote_name}
EOF

    log "DEBUG" "enqueue_item: queued ${remote_name} → ${entry_file}"
    return 0
}

# ---------------------------------------------------------------------------
# dequeue_next_item
#
# Finds the oldest (lowest-numbered) .queued file in REPACK_QUEUE_DIR
# and prints its path to stdout.
# Returns 0 if an item was found, 1 if the queue is empty.
# ---------------------------------------------------------------------------
dequeue_next_item() {
    local oldest
    # Use find + sort to get the lowest-numbered .queued file
    oldest=$(find "${REPACK_QUEUE_DIR}" -maxdepth 1 -name "*.queued" \
                | sort | head -1)

    if [[ -z "${oldest}" ]]; then
        return 1
    fi

    printf '%s' "${oldest}"
    return 0
}

# ---------------------------------------------------------------------------
# _read_queue_entry ENTRY_FILE VAR_BZ2 VAR_SHA VAR_RDIR VAR_RNAME
#
# Internal: reads a queue entry file into caller-specified variable names
# using bash namerefs.
# ---------------------------------------------------------------------------
_read_queue_entry() {
    local entry_file="$1"
    local -n _rbz2="$2"
    local -n _rsha="$3"
    local -n _rrdir="$4"
    local -n _rrname="$5"

    _rbz2=""
    _rsha=""
    _rrdir=""
    _rrname=""

    local key val line
    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        case "${key}" in
            local_bz2_path) _rbz2="${val}"  ;;
            sha256_path)    _rsha="${val}"   ;;
            remote_dir)     _rrdir="${val}"  ;;
            remote_name)    _rrname="${val}" ;;
        esac
    done < "${entry_file}"
}

# ---------------------------------------------------------------------------
# upload_one_file LOCAL_BZ2_PATH SHA256_PATH REMOTE_DIR REMOTE_NAME
#
# Atomic SFTP upload pipeline:
#   Step 1: Upload LOCAL_BZ2_PATH to REMOTE_DIR/REMOTE_NAME.tmp_upload
#   Step 2: Re-download .tmp_upload to a local verify temp file
#   Step 3: sha256sum the verify file; compare against SHA256_PATH content
#   Step 4: On match: rename .tmp_upload → REMOTE_DIR/REMOTE_NAME
#           On mismatch: remove .tmp_upload, return 1
#
# The .sha256 file contains a line: "<hash>  <filename>"
# We extract just the hash for comparison (sha256sum -c is not used here
# to avoid needing the verify file to be named exactly right).
#
# Returns 0 on success, 1 on any failure.
# ---------------------------------------------------------------------------
upload_one_file() {
    local local_bz2_path="$1"
    local sha256_path="$2"
    local remote_dir="$3"
    local remote_name="$4"

    local remote_tmp="${remote_dir}/${remote_name}.tmp_upload"
    local remote_final="${remote_dir}/${remote_name}"
    local verify_file="${REPACK_VERIFY_DIR}/${remote_name}.verify"

    log "INFO" "upload_one_file: uploading ${remote_name} → ${remote_dir}"

    # Read expected hash from .sha256 file
    local expected_hash
    expected_hash=$(awk '{print $1}' "${sha256_path}" 2>/dev/null)
    if [[ -z "${expected_hash}" ]]; then
        log "ERROR" "upload_one_file: cannot read expected hash from ${sha256_path}"
        return 1
    fi

    # ------------------------------------------------------------------
    # Step 1: Upload to .tmp_upload
    # ------------------------------------------------------------------
    local rc=0
    _zpaq_sftp_run "put ${local_bz2_path} ${remote_tmp}" || rc=$?
    if (( rc != 0 )); then
        log "ERROR" "upload_one_file: upload to tmp failed (rc=${rc}): ${remote_tmp}"
        return 1
    fi
    log "DEBUG" "upload_one_file: upload to tmp OK"

    # ------------------------------------------------------------------
    # Step 2: Re-download for verification
    # ------------------------------------------------------------------
    rm -f "${verify_file}"
    rc=0
    _zpaq_sftp_run "get ${remote_tmp} ${verify_file}" || rc=$?
    if (( rc != 0 )) || [[ ! -f "${verify_file}" ]]; then
        log "ERROR" "upload_one_file: re-download failed (rc=${rc}): ${remote_tmp}"
        _zpaq_sftp_run "rm ${remote_tmp}" || true
        rm -f "${verify_file}"
        return 1
    fi

    # ------------------------------------------------------------------
    # Step 3: Verify sha256
    # ------------------------------------------------------------------
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
    log "DEBUG" "upload_one_file: sha256 OK (${expected_hash})"

    # ------------------------------------------------------------------
    # Step 4: Rename .tmp_upload → final
    # ------------------------------------------------------------------
    rc=0
    _zpaq_sftp_run "rename ${remote_tmp} ${remote_final}" || rc=$?
    if (( rc != 0 )); then
        log "ERROR" "upload_one_file: rename to final failed (rc=${rc}): ${remote_final}"
        _zpaq_sftp_run "rm ${remote_tmp}" || true
        return 1
    fi

    log "INFO" "upload_one_file: OK ${remote_final}"
    return 0
}

# ---------------------------------------------------------------------------
# upload_worker
#
# Background polling loop. Runs until:
#   - The sentinel file REPACK_QUEUE_SENTINEL exists, AND
#   - The queue directory contains no more .queued files.
#
# For each queue entry:
#   1. Reads the entry file
#   2. Calls upload_one_file
#   3. On success: renames .queued → .done
#   4. On failure: renames .queued → .failed (main loop reports these)
#
# Intended usage:
#   upload_worker &
#   UPLOAD_WORKER_PID=$!
#   ...
#   touch "${REPACK_QUEUE_SENTINEL}"
#   wait "${UPLOAD_WORKER_PID}"
#
# Globals used:
#   REPACK_QUEUE_DIR, REPACK_QUEUE_SENTINEL, REPACK_VERIFY_DIR
# ---------------------------------------------------------------------------
upload_worker() {
    log "INFO" "upload_worker: started (PID=$$)"

    while true; do
        # Try to dequeue an item
        local entry_file=""
        entry_file=$(dequeue_next_item) || true

        if [[ -z "${entry_file}" ]]; then
            # Queue is empty — check if we should exit
            if [[ -f "${REPACK_QUEUE_SENTINEL}" ]]; then
                log "INFO" "upload_worker: queue empty and sentinel present — exiting"
                break
            fi
            # No sentinel yet — wait for more items
            sleep 1
            continue
        fi

        # Read the queue entry
        local item_bz2 item_sha item_rdir item_rname
        _read_queue_entry "${entry_file}" item_bz2 item_sha item_rdir item_rname

        if [[ -z "${item_bz2}" || -z "${item_sha}" || -z "${item_rdir}" || -z "${item_rname}" ]]; then
            log "ERROR" "upload_worker: malformed queue entry: ${entry_file}"
            mv "${entry_file}" "${entry_file%.queued}.failed"
            continue
        fi

        log "DEBUG" "upload_worker: processing ${item_rname}"

        # Ensure remote directory exists before uploading
        ensure_remote_dir "${item_rdir}"

        # Upload
        local upload_rc=0
        upload_one_file \
            "${item_bz2}" "${item_sha}" "${item_rdir}" "${item_rname}" \
            || upload_rc=$?

        if (( upload_rc == 0 )); then
            mv "${entry_file}" "${entry_file%.queued}.done"
            log "INFO" "upload_worker: done ${item_rname}"
        else
            mv "${entry_file}" "${entry_file%.queued}.failed"
            log "ERROR" "upload_worker: FAILED ${item_rname} — marked as failed"
        fi
    done

    log "INFO" "upload_worker: exiting"
}