#!/usr/bin/env bash
# ============================================================
# src/zpaq/zpaq_multipart_ops.sh — Multipart zpaqfranz Add & Sync Operations
#
# Provides:
#
#   zpaq_multipart_add  ARCHIVE_PATTERN FILE_LIST_ARRAY_NAME TEMP_DIR
#       Adds files to the multipart archive using an explicit file
#       list (preferred) or a '.' sweep fallback if the argument
#       list would exceed ARGMAX_SAFE_THRESHOLD bytes.
#       Runs from pushd TEMP_DIR so internal names are relative paths.
#       Returns 0 on success, 1 on failure.
#
#   zpaq_multipart_upload_part  PART_FILE REMOTE_DIR TEMP_DIR
#       Uploads a new .zpaq part using the .tmp_upload → verify →
#       rename pipeline.  Returns 0 on success, 1 on failure.
#
#   zpaq_multipart_upload_manifest  MANIFEST_PATH REMOTE_DIR
#       Uploads the local manifest to REMOTE_DIR (direct overwrite).
#       Returns 0 on success, 1 on failure.
#
#   zpaq_multipart_download_manifest  REMOTE_DIR BASENAME LOCAL_DEST
#       Downloads the remote manifest for BASENAME to LOCAL_DEST.
#       Returns 0 on success, 1 if not found or on error.
#
#   zpaq_multipart_remote_sync  BASENAME LOCAL_DIR REMOTE_DIR MANIFEST_PATH
#       Pre-add remote sync check: downloads remote manifest, compares
#       total_parts, downloads+verifies any missing parts, updates
#       local manifest.  Returns 0 on success, 1 on unrecoverable error.
#
#   zpaq_multipart_build_cache  ARCHIVE_PATTERN
#       Runs a single "zpaqfranz l" and populates ZPAQ_ARCHIVE_CONTENTS[]
#       associative array with all internal filenames.
#       Returns 0 (even for empty/missing archive).
#
#   zpaq_multipart_file_known  INTERNAL_NAME
#       Returns 0 if INTERNAL_NAME is in ZPAQ_ARCHIVE_CONTENTS[].
#       Returns 1 if not known.
#
#   check_archive_format_conflict  BASENAME LOCAL_DIR REMOTE_DIR
#       Detects whether a single-file archive (basename.zpaq) and a
#       multipart archive (basename0000001.zpaq) would conflict.
#       Returns 0 if safe, 1 if a conflict is detected (logs error).
#
# Globals consumed:
#   ZPAQFRANZ_BIN         — set by detect_zpaqfranz()
#   ZPAQFRANZ_THREADS     — set by zpaq_calc_threads()
#   ZPAQ_FRAGMENT         — -fragment N value (default 3)
#   ZPAQ_COMPRESSION      — e.g. "-m5"
#   ZPAQ_EXTRA_FLAGS      — e.g. "-ssd"
#   ARGMAX_SAFE_THRESHOLD — max arg bytes before falling back to '.' sweep
#   SFTP_HOST/PORT/USER/PASS — SFTP credentials
#   MP_MANIFEST_*         — in-memory manifest state (from zpaq_multipart_manifest.sh)
#
# Dependency order:
#   Must be sourced after:
#     src/core/logging.sh
#     src/zpaq/zpaq_utils.sh
#     src/zpaq/zpaq_multipart_manifest.sh
#     src/zpaq/zpaq_sftp_ops.sh
# ============================================================

# ---------------------------------------------------------------------------
# In-memory archive content cache — populated by zpaq_multipart_build_cache()
# ---------------------------------------------------------------------------
declare -gA ZPAQ_ARCHIVE_CONTENTS=()

# ---------------------------------------------------------------------------
# zpaq_multipart_build_cache ARCHIVE_PATTERN
#
# Runs exactly one "zpaqfranz l ARCHIVE_PATTERN" and loads all internal
# filenames into ZPAQ_ARCHIVE_CONTENTS[].
#
# ARCHIVE_PATTERN must be the quoted multipart pattern, e.g.:
#   "${ZPAQ_LOCAL_DIR}/vxtl_helium???????"
#
# Returns 0 always (empty archive or no-parts-yet is not an error).
# ---------------------------------------------------------------------------
zpaq_multipart_build_cache() {
    local archive_pattern="$1"

    ZPAQ_ARCHIVE_CONTENTS=()

    log "INFO" "zpaq_multipart_build_cache: scanning archive contents..."

    local count=0
    local internal_name
    while IFS= read -r internal_name; do
        [[ -z "${internal_name}" ]] && continue
        ZPAQ_ARCHIVE_CONTENTS["${internal_name}"]=1
        (( count++ )) || true
    done < <("${ZPAQFRANZ_BIN}" l "${archive_pattern}" 2>/dev/null \
              | awk '/^\+ /{print $2}')

    log "INFO" "zpaq_multipart_build_cache: loaded ${count} known file(s)"
    return 0
}

# ---------------------------------------------------------------------------
# zpaq_multipart_file_known INTERNAL_NAME
#
# Returns 0 if INTERNAL_NAME is already in ZPAQ_ARCHIVE_CONTENTS[].
# Returns 1 if not known.
# ---------------------------------------------------------------------------
zpaq_multipart_file_known() {
    local internal_name="$1"
    if [[ -n "${ZPAQ_ARCHIVE_CONTENTS[${internal_name}]+set}" ]]; then
        log "DEBUG" "zpaq_multipart_file_known: '${internal_name}' — already in archive"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# _zpaq_multipart_sftp_run BATCH_COMMANDS
#
# Internal SFTP batch runner (wraps _zpaq_sftp_run from zpaq_sftp_ops.sh).
# ---------------------------------------------------------------------------
_zpaq_multipart_sftp_run() {
    _zpaq_sftp_run "$1"
}

# ---------------------------------------------------------------------------
# zpaq_multipart_add ARCHIVE_PATTERN FILE_LIST_ARRAY_NAME TEMP_DIR
#
# Adds files to the multipart zpaqfranz archive.
#
# FILE_LIST_ARRAY_NAME is the name of a bash array variable containing
# relative paths (relative to TEMP_DIR) of files to add.
#
# Strategy:
#   1. Compute total byte length of all relative path arguments.
#   2. If <= ARGMAX_SAFE_THRESHOLD: pass explicit list to zpaqfranz.
#   3. If > ARGMAX_SAFE_THRESHOLD: fall back to '.' sweep from TEMP_DIR.
#
# In both cases, zpaqfranz is invoked from pushd TEMP_DIR so internal
# archive names are relative paths (e.g. "vxtl_helium_20240115.sql",
# "slim/vxtl_helium_20240115.sql").
#
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
zpaq_multipart_add() {
    local archive_pattern="$1"
    local -n _file_list_ref="$2"
    local temp_dir="$3"

    local fragment="${ZPAQ_FRAGMENT:-3}"
    local compression="${ZPAQ_COMPRESSION:--m5}"
    local extra_flags="${ZPAQ_EXTRA_FLAGS:--ssd}"
    local threads="${ZPAQFRANZ_THREADS:-1}"
    local threshold="${ARGMAX_SAFE_THRESHOLD:-131072}"

    if (( ${#_file_list_ref[@]} == 0 )); then
        log "WARN" "zpaq_multipart_add: file list is empty — nothing to add"
        return 1
    fi

    # Compute total argument length
    local total_arg_bytes=0
    local f
    for f in "${_file_list_ref[@]}"; do
        total_arg_bytes=$(( total_arg_bytes + ${#f} + 1 ))  # +1 for space/null separator
    done

    local use_dot_sweep=0
    if (( total_arg_bytes > threshold )); then
        log "INFO" "zpaq_multipart_add: arg list ${total_arg_bytes} bytes > threshold ${threshold} — using '.' sweep fallback"
        use_dot_sweep=1
    else
        log "DEBUG" "zpaq_multipart_add: arg list ${total_arg_bytes} bytes <= threshold ${threshold} — using explicit list"
    fi

    log "INFO" "zpaq_multipart_add: adding ${#_file_list_ref[@]} file(s) to ${archive_pattern}"
    log "INFO" "zpaq_multipart_add: fragment=${fragment} compression=${compression} threads=${threads}"

    local rc=0

    pushd "${temp_dir}" > /dev/null

    # zpaqfranz writes progress to stderr (terminal) and may write to stdout.
    # Stdout is tee'd to LOG_FILE so it appears in the log and on the terminal.
    # Stderr goes directly to the terminal for live progress display.
    # PIPESTATUS[0] captures zpaqfranz's exit code across the tee pipe.
    if (( use_dot_sweep == 0 )); then
        # Explicit file list
        "${ZPAQFRANZ_BIN}" a "${archive_pattern}" \
                    "${_file_list_ref[@]}" \
                    "${compression}" \
                    -fragment "${fragment}" \
                    ${extra_flags} \
                    -threads "${threads}" \
                    | tee -a "${LOG_FILE:-/dev/null}" > /dev/null
        rc="${PIPESTATUS[0]}"
    else
        # Dot sweep fallback
        "${ZPAQFRANZ_BIN}" a "${archive_pattern}" \
                    . \
                    "${compression}" \
                    -fragment "${fragment}" \
                    ${extra_flags} \
                    -threads "${threads}" \
                    | tee -a "${LOG_FILE:-/dev/null}" > /dev/null
        rc="${PIPESTATUS[0]}"
    fi

    popd > /dev/null

    if (( rc != 0 )); then
        log "ERROR" "zpaq_multipart_add: zpaqfranz a failed (rc=${rc})"
        return 1
    fi

    log "INFO" "zpaq_multipart_add: add completed successfully"
    return 0
}

# ---------------------------------------------------------------------------
# zpaq_multipart_upload_part PART_FILE REMOTE_DIR TEMP_DIR
#
# Uploads a single .zpaq part using the atomic pipeline:
#   1. Compute local sha256
#   2. Upload to <remote_dir>/<partname>.tmp_upload
#   3. Download back to TEMP_DIR/.verify/<partname>
#   4. Verify sha256 — mismatch: delete remote tmp, return 1
#   5. Rename remote tmp → live part name
#   6. Delete local verify copy
#
# Returns 0 on success, 1 on any failure.
# Retries upload up to UPLOAD_RETRY_COUNT times on failure.
# ---------------------------------------------------------------------------
zpaq_multipart_upload_part() {
    local part_file="$1"
    local remote_dir="$2"
    local temp_dir="$3"

    local partname
    partname=$(basename "${part_file}")
    local remote_live="${remote_dir}/${partname}"
    local remote_tmp="${remote_dir}/${partname}.tmp_upload"
    local verify_dir="${temp_dir}/.verify"
    local verify_file="${verify_dir}/${partname}"
    local max_retries="${UPLOAD_RETRY_COUNT:-3}"

    mkdir -p "${verify_dir}"

    if [[ ! -f "${part_file}" ]]; then
        log "ERROR" "zpaq_multipart_upload_part: part file not found: ${part_file}"
        return 1
    fi

    # Compute local sha256
    local expected_sha256 expected_size
    expected_sha256=$(sha256sum "${part_file}" 2>/dev/null | awk '{print $1}')
    expected_size=$(stat -c "%s" "${part_file}" 2>/dev/null || echo 0)
    log "INFO" "zpaq_multipart_upload_part: ${partname} sha256=${expected_sha256} size=${expected_size}"

    # Upload with retry
    local attempt rc
    for (( attempt = 1; attempt <= max_retries; attempt++ )); do
        log "INFO" "zpaq_multipart_upload_part: upload attempt ${attempt}/${max_retries}: ${partname} → ${remote_tmp}"
        rc=0
        _zpaq_multipart_sftp_run "put ${part_file} ${remote_tmp}" || rc=$?
        if (( rc == 0 )); then
            break
        fi
        log "WARN" "zpaq_multipart_upload_part: upload failed (rc=${rc}), attempt ${attempt}/${max_retries}"
        sleep $(( attempt * 2 ))
    done

    if (( rc != 0 )); then
        log "ERROR" "zpaq_multipart_upload_part: all ${max_retries} upload attempts failed for ${partname}"
        log "ERROR" "  Part file retained locally: ${part_file}"
        log "ERROR" "  Pre-add sync check on next run will detect and re-attempt upload."
        return 1
    fi

    # Download back for verification
    rm -f "${verify_file}"
    log "INFO" "zpaq_multipart_upload_part: downloading back for verification"
    rc=0
    _zpaq_multipart_sftp_run "get ${remote_tmp} ${verify_file}" || rc=$?
    if (( rc != 0 )) || [[ ! -f "${verify_file}" ]]; then
        log "ERROR" "zpaq_multipart_upload_part: re-download failed (rc=${rc})"
        _zpaq_multipart_sftp_run "rm ${remote_tmp}" || true
        rm -f "${verify_file}"
        return 1
    fi

    # Verify sha256
    local verify_hash
    verify_hash=$(sha256sum "${verify_file}" 2>/dev/null | awk '{print $1}')
    rm -f "${verify_file}"

    if [[ "${verify_hash}" != "${expected_sha256}" ]]; then
        log "ERROR" "zpaq_multipart_upload_part: sha256 MISMATCH after upload"
        log "ERROR" "  expected: ${expected_sha256}"
        log "ERROR" "  got:      ${verify_hash}"
        log "ERROR" "  Removing corrupt remote file: ${remote_tmp}"
        _zpaq_multipart_sftp_run "rm ${remote_tmp}" || true
        return 1
    fi
    log "INFO" "zpaq_multipart_upload_part: sha256 verification OK"

    # Rename tmp → live
    rc=0
    _zpaq_multipart_sftp_run "rename ${remote_tmp} ${remote_live}" || rc=$?
    if (( rc != 0 )); then
        log "ERROR" "zpaq_multipart_upload_part: rename tmp→live failed (rc=${rc})"
        _zpaq_multipart_sftp_run "rm ${remote_tmp}" || true
        return 1
    fi

    log "INFO" "zpaq_multipart_upload_part: ${partname} live on remote (sha256=${expected_sha256})"
    return 0
}

# ---------------------------------------------------------------------------
# zpaq_multipart_upload_manifest MANIFEST_PATH REMOTE_DIR
#
# Uploads the local manifest to REMOTE_DIR, overwriting directly.
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
zpaq_multipart_upload_manifest() {
    local manifest_path="$1"
    local remote_dir="$2"

    if [[ ! -f "${manifest_path}" ]]; then
        log "ERROR" "zpaq_multipart_upload_manifest: local manifest not found: ${manifest_path}"
        return 1
    fi

    local manifest_name
    manifest_name=$(basename "${manifest_path}")
    local remote_manifest="${remote_dir}/${manifest_name}"

    log "DEBUG" "zpaq_multipart_upload_manifest: ${manifest_path} → ${remote_manifest}"
    local rc=0
    _zpaq_multipart_sftp_run "put ${manifest_path} ${remote_manifest}" || rc=$?

    if (( rc != 0 )); then
        log "WARN" "zpaq_multipart_upload_manifest: upload failed (rc=${rc}) — non-fatal; will retry next run"
        return 1
    fi

    log "DEBUG" "zpaq_multipart_upload_manifest: OK"
    return 0
}

# ---------------------------------------------------------------------------
# zpaq_multipart_download_manifest REMOTE_DIR BASENAME LOCAL_DEST
#
# Downloads the remote manifest for BASENAME to LOCAL_DEST.
# Returns 0 on success, 1 if not found or on error.
# ---------------------------------------------------------------------------
zpaq_multipart_download_manifest() {
    local remote_dir="$1"
    local basename="$2"
    local local_dest="$3"

    local remote_path="${remote_dir}/${basename}.zpaq.manifest"

    log "DEBUG" "zpaq_multipart_download_manifest: ${remote_path} → ${local_dest}"
    local rc=0
    _zpaq_multipart_sftp_run "get ${remote_path} ${local_dest}" || rc=$?

    if (( rc != 0 )) || [[ ! -f "${local_dest}" ]]; then
        log "DEBUG" "zpaq_multipart_download_manifest: not found or failed: ${remote_path}"
        rm -f "${local_dest}"
        return 1
    fi

    log "DEBUG" "zpaq_multipart_download_manifest: downloaded OK"
    return 0
}

# ---------------------------------------------------------------------------
# zpaq_multipart_remote_sync BASENAME LOCAL_DIR REMOTE_DIR MANIFEST_PATH TEMP_DIR
#
# Pre-add remote sync check:
#   1. Download remote manifest
#   2. Compare remote total_parts vs local total_parts
#   3. If remote > local: download and verify each missing part
#   4. Update local manifest to reflect synced state
#   5. If local > remote: log warning (upload gap); proceed (upload pipeline
#      will handle re-upload of the local-only part before next add)
#
# Returns 0 on success (including no-op in-sync case).
# Returns 1 on unrecoverable error (e.g. sha256 mismatch on downloaded part).
# ---------------------------------------------------------------------------
zpaq_multipart_remote_sync() {
    local basename="$1"
    local local_dir="$2"
    local remote_dir="$3"
    local manifest_path="$4"
    local temp_dir="$5"

    local remote_manifest_tmp="${temp_dir}/.remote_manifest_sync.tmp"
    rm -f "${remote_manifest_tmp}"

    # Download remote manifest
    if ! zpaq_multipart_download_manifest "${remote_dir}" "${basename}" "${remote_manifest_tmp}"; then
        log "INFO" "zpaq_multipart_remote_sync: no remote manifest — first run, nothing to sync"
        return 0
    fi

    # Compare total_parts
    local diverge_rc
    multipart_manifest_remote_diverged "${manifest_path}" "${remote_manifest_tmp}"
    diverge_rc=$?

    if (( diverge_rc == 1 )); then
        log "INFO" "zpaq_multipart_remote_sync: in sync (total_parts=${MP_MANIFEST_TOTAL_PARTS})"
        rm -f "${remote_manifest_tmp}"
        return 0
    fi

    if (( diverge_rc == 2 )); then
        log "WARN" "zpaq_multipart_remote_sync: local has MORE parts than remote — upload gap from prior run"
        log "WARN" "  Local parts=${MP_MANIFEST_TOTAL_PARTS}; will re-upload missing parts before next add"
        # Identify local-only parts and re-upload them
        local partname
        for partname in $(printf '%s\n' "${!MP_MANIFEST_PART_SHA256[@]}" | sort); do
            local local_part="${local_dir}/${partname}"
            # Check if part is missing on remote by attempting a download of its size
            local check_tmp="${temp_dir}/.remote_check_${partname}.tmp"
            local check_rc=0
            _zpaq_multipart_sftp_run "get ${remote_dir}/${partname} ${check_tmp}" || check_rc=$?
            if (( check_rc != 0 )) || [[ ! -f "${check_tmp}" ]]; then
                log "INFO" "zpaq_multipart_remote_sync: re-uploading local-only part: ${partname}"
                if ! zpaq_multipart_upload_part "${local_part}" "${remote_dir}" "${temp_dir}"; then
                    log "ERROR" "zpaq_multipart_remote_sync: re-upload failed for ${partname}"
                    rm -f "${check_tmp}" "${remote_manifest_tmp}"
                    return 1
                fi
            fi
            rm -f "${check_tmp}"
        done
        rm -f "${remote_manifest_tmp}"
        return 0
    fi

    # diverge_rc == 0: remote has more parts than local — download missing ones
    log "WARN" "zpaq_multipart_remote_sync: remote has more parts than local — downloading missing parts"

    # Parse remote manifest for its parts
    local saved_basename="${MP_MANIFEST_BASENAME}"
    local saved_fragment="${MP_MANIFEST_FRAGMENT}"
    local saved_total_parts="${MP_MANIFEST_TOTAL_PARTS}"
    local saved_total_size="${MP_MANIFEST_TOTAL_SIZE}"
    declare -A saved_sha256=()
    declare -A saved_size_arr=()
    declare -A saved_added=()
    local p
    for p in "${!MP_MANIFEST_PART_SHA256[@]}"; do
        saved_sha256["${p}"]="${MP_MANIFEST_PART_SHA256[${p}]}"
        saved_size_arr["${p}"]="${MP_MANIFEST_PART_SIZE[${p}]}"
        saved_added["${p}"]="${MP_MANIFEST_PART_ADDED[${p}]}"
    done

    # Read remote manifest into MP_MANIFEST_* state
    multipart_manifest_read "${remote_manifest_tmp}"
    local remote_parts_total="${MP_MANIFEST_TOTAL_PARTS}"

    # Restore local manifest state and then add missing parts from remote
    MP_MANIFEST_BASENAME="${saved_basename}"
    MP_MANIFEST_FRAGMENT="${saved_fragment}"
    MP_MANIFEST_TOTAL_PARTS="${saved_total_parts}"
    MP_MANIFEST_TOTAL_SIZE="${saved_total_size}"
    MP_MANIFEST_PART_SHA256=()
    MP_MANIFEST_PART_SIZE=()
    MP_MANIFEST_PART_ADDED=()
    for p in "${!saved_sha256[@]}"; do
        MP_MANIFEST_PART_SHA256["${p}"]="${saved_sha256[${p}]}"
        MP_MANIFEST_PART_SIZE["${p}"]="${saved_size_arr[${p}]}"
        MP_MANIFEST_PART_ADDED["${p}"]="${saved_added[${p}]}"
    done

    # Read remote manifest again just for part list
    local remote_manifest_content
    declare -A remote_part_sha256=()
    declare -A remote_part_size=()
    local in_p=0 line key val partname
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        if [[ "${line}" == "[parts]" ]]; then in_p=1; continue; fi
        if (( in_p )); then
            partname=$(awk '{print $1}' <<< "${line}")
            local rsha
            rsha=$(grep -oP 'sha256=\K[0-9a-f]+' <<< "${line}" || true)
            local rsz
            rsz=$(grep -oP 'size=\K[0-9]+' <<< "${line}" || true)
            [[ -n "${partname}" ]] && remote_part_sha256["${partname}"]="${rsha}" && remote_part_size["${partname}"]="${rsz:-0}"
        fi
    done < "${remote_manifest_tmp}"

    rm -f "${remote_manifest_tmp}"

    # Download each remote part not known locally
    for partname in $(printf '%s\n' "${!remote_part_sha256[@]}" | sort); do
        if multipart_manifest_part_known "${partname}"; then
            log "DEBUG" "zpaq_multipart_remote_sync: ${partname} already known locally — skipping"
            continue
        fi

        local remote_expected_sha256="${remote_part_sha256[${partname}]}"
        local remote_expected_size="${remote_part_size[${partname}]}"
        local local_part="${local_dir}/${partname}"

        log "INFO" "zpaq_multipart_remote_sync: downloading missing part: ${partname}"

        local dl_rc=0
        _zpaq_multipart_sftp_run "get ${remote_dir}/${partname} ${local_part}" || dl_rc=$?

        if (( dl_rc != 0 )) || [[ ! -f "${local_part}" ]]; then
            log "ERROR" "zpaq_multipart_remote_sync: download failed for ${partname}"
            return 1
        fi

        # Verify sha256
        local dl_sha256
        dl_sha256=$(sha256sum "${local_part}" 2>/dev/null | awk '{print $1}')
        if [[ "${dl_sha256}" != "${remote_expected_sha256}" ]]; then
            log "ERROR" "zpaq_multipart_remote_sync: sha256 mismatch for downloaded ${partname}"
            log "ERROR" "  expected: ${remote_expected_sha256}"
            log "ERROR" "  got:      ${dl_sha256}"
            rm -f "${local_part}"
            return 1
        fi

        # Run zpaqfranz t to verify archive integrity
        log "INFO" "zpaq_multipart_remote_sync: verifying integrity of downloaded part: ${partname}"
        if ! zpaq_test_archive "${local_part}"; then
            log "ERROR" "zpaq_multipart_remote_sync: integrity test failed for ${partname}"
            rm -f "${local_part}"
            return 1
        fi

        # Add to local manifest state
        local dl_size
        dl_size=$(stat -c "%s" "${local_part}" 2>/dev/null || echo 0)
        multipart_manifest_add_part "${partname}" "${dl_size}" "${dl_sha256}"
        log "INFO" "zpaq_multipart_remote_sync: synced ${partname} OK"
    done

    log "INFO" "zpaq_multipart_remote_sync: sync complete — total_parts=${MP_MANIFEST_TOTAL_PARTS}"
    return 0
}

# ---------------------------------------------------------------------------
# check_archive_format_conflict BASENAME LOCAL_DIR REMOTE_DIR TEMP_DIR
#
# Checks whether a conflicting archive format exists:
#   - Single-file: <LOCAL_DIR>/<basename>.zpaq or remote equivalent
#   - Multipart:   <LOCAL_DIR>/<basename>0000001.zpaq or remote equivalent
#
# Returns 0 if no conflict (safe to proceed in multipart mode).
# Returns 1 if a conflict is detected (logs clear error).
# ---------------------------------------------------------------------------
check_archive_format_conflict() {
    local basename="$1"
    local local_dir="$2"
    local remote_dir="$3"
    local temp_dir="$4"

    local conflict=0

    # Check local single-file
    if [[ -f "${local_dir}/${basename}.zpaq" ]]; then
        log "ERROR" "check_archive_format_conflict: single-file archive exists locally: ${local_dir}/${basename}.zpaq"
        log "ERROR" "  Cannot use multipart mode for the same base name. Use a different basename,"
        log "ERROR" "  or remove/rename the single-file archive first."
        conflict=1
    fi

    # Check local multipart (any part)
    local multipart_found
    multipart_found=$(find "${local_dir}" -maxdepth 1 \
        -name "${basename}[0-9][0-9][0-9][0-9][0-9][0-9][0-9].zpaq" \
        -print -quit 2>/dev/null || true)

    # No need to check multipart conflict since we ARE in multipart mode —
    # existing multipart parts are expected and valid.

    # Check remote single-file by attempting to download its manifest
    local remote_single_manifest="${temp_dir}/.conflict_check_single.tmp"
    local rc=0
    _zpaq_multipart_sftp_run "get ${remote_dir}/${basename}.manifest ${remote_single_manifest}" || rc=$?
    if (( rc == 0 )) && [[ -f "${remote_single_manifest}" ]]; then
        # A single-file manifest exists on remote — check if it's a single-type manifest
        local archive_type
        archive_type=$(grep -m1 '^archive_type=' "${remote_single_manifest}" | cut -d= -f2 || true)
        # If archive_type is missing or "single", this is a single-file archive
        if [[ -z "${archive_type}" || "${archive_type}" == "single" ]]; then
            log "ERROR" "check_archive_format_conflict: single-file archive manifest found on remote: ${remote_dir}/${basename}.manifest"
            log "ERROR" "  Cannot use multipart mode for the same base name."
            conflict=1
        fi
    fi
    rm -f "${remote_single_manifest}"

    if (( conflict )); then
        return 1
    fi

    log "DEBUG" "check_archive_format_conflict: no conflict detected for basename=${basename}"
    return 0
}