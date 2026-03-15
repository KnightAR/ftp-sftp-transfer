#!/usr/bin/env bash
# ============================================================
# src/transfer/sftp.sh — SFTP Server I/O Helpers
#
# All functions that communicate directly with the SFTP server.
# Every function uses sshpass + sftp in batch mode via process
# substitution (<(printf '...')), which avoids temp batch files.
#
#   sftp_get_size()         — queries ls -l on a single remote path
#                             and returns the file size (or "NOT_FOUND").
#                             Always called inside $(...) by callers that
#                             capture the return value, so ALL debug output
#                             is written directly to ${LOG_FILE} + stderr —
#                             never to stdout — to avoid corrupting the
#                             captured variable with log text.
#
#   sftp_get_size_retry()   — calls sftp_get_size() up to MAX_TRIES times,
#                             sleeping between attempts, until the size
#                             matches EXPECTED_SIZE.  Handles object-storage
#                             backends that report a partial/chunk size for
#                             a few seconds after a put completes.
#
#   sftp_mkdir_p()          — creates a full remote directory path
#                             recursively using "-mkdir" batch commands
#                             (errors on already-existing dirs are silently
#                             ignored via &>/dev/null).
#
#   sftp_download_verify()  — re-downloads a remote file to a local .verify
#                             temp file, computes sha256sum for both the
#                             staged copy and the re-downloaded copy, and
#                             compares them.  The .verify file is always
#                             cleaned up via trap ... RETURN.
#                             Returns 0 on match, 1 on any failure.
#
#   sftp_delete_file()      — removes a single file from the SFTP server.
#                             Used after a checksum failure to delete the
#                             corrupt upload so the next run re-uploads from
#                             scratch.  Failure is logged but non-fatal —
#                             the caller must still mark the file as an
#                             error so the FTP source is never deleted for
#                             an unverified SFTP copy.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log(), LOG_FILE)
#   and src/core/constants.sh (uses CLI_VERBOSE).
#   load_config() must have run so SFTP_HOST, SFTP_PORT, SFTP_USER,
#   and SFTP_PASS are set.
# ============================================================

# Check if a file exists on SFTP and return its size (or "NOT_FOUND").
# Usage: sftp_get_size "remote/path/file.gz"
sftp_get_size() {
    local remote_path="$1"
    local result

    # Use "ls -l <path>" and anchor the awk match to the exact basename of the
    # remote path. Without this anchor, some SFTP servers respond to "ls -l
    # /dir/file" by listing the parent directory — causing awk to pick up the
    # first file line regardless of name, which returns the wrong size when two
    # files in different subdirectories share the same basename.
    local remote_basename
    remote_basename=$(basename "${remote_path}")

    # Capture raw SFTP output into a variable so we can both log it (in verbose
    # mode) and feed it to awk — avoids a second round-trip to the server.
    local raw_ls
    raw_ls=$(SSHPASS="${SFTP_PASS}" sshpass -e sftp \
        -P "${SFTP_PORT}" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=no \
        -o ConnectTimeout=5 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o LogLevel=ERROR \
        -b <(printf 'ls -l %s\n' "${remote_path}") \
        "${SFTP_USER}@${SFTP_HOST}" 2>/dev/null || true)

    result=$(printf '%s\n' "${raw_ls}" \
        | awk -v name="${remote_basename}" \
            'NF>=9 && /^[-]/ && ($NF==name || substr($NF,length($NF)-length(name),1)=="/" && substr($NF,length($NF)-length(name)+1)==name) {print $5}' \
        | head -1)

    # In verbose mode: emit one single atomic log entry containing the query,
    # every raw ls line, and the matched result.
    # IMPORTANT: this function is always called inside $(...) by callers that
    # capture its return value via stdout.  log() writes to stdout, which means
    # any log() call here would be captured into the caller's variable instead
    # of being printed.  We therefore write directly to the log files and stderr
    # (bypassing stdout entirely) using the same flock pattern as log().
    if [[ "${CLI_VERBOSE}" == true ]]; then
        local dbg_msg
        dbg_msg="sftp_get_size: path=${remote_path} basename=${remote_basename} result='${result:-NOT_FOUND}'"
        if [[ -z "${raw_ls}" ]]; then
            dbg_msg+=" | raw=<empty>"
        else
            local raw_line
            while IFS= read -r raw_line; do
                dbg_msg+=" | ${raw_line}"
            done <<< "${raw_ls}"
        fi
        local dbg_line="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG]  ${dbg_msg}"
        (
            flock -x 200
            echo "${dbg_line}" >> "${LOG_FILE}"
            echo "${dbg_line}" >&2
        ) 200>"${LOG_FILE}.lock"
    fi

    if [[ -z "${result}" ]]; then
        echo "NOT_FOUND"
    else
        echo "${result}"
    fi
}

# sftp_get_size_retry REMOTE_PATH EXPECTED_SIZE [MAX_TRIES] [SLEEP_SECS]
#
# Calls sftp_get_size up to MAX_TRIES times (default 4), sleeping SLEEP_SECS
# (default 3) between attempts, until the returned size equals EXPECTED_SIZE.
#
# Returns the size once it matches, or the last value seen if it never matches.
#
# Rationale: some SFTP servers (especially object-storage backends) do not
# reflect the final file size in ls -l immediately after a put completes —
# they may return a partial/chunk size (e.g. 262144000 = 256 MiB) for a few
# seconds while the write is being committed.  Retrying avoids false-positive
# "Upload size verification failed" errors on large files.
sftp_get_size_retry() {
    local remote_path="$1"
    local expected_size="$2"
    local max_tries="${3:-4}"
    local sleep_secs="${4:-3}"

    local attempt=1
    local size
    while (( attempt <= max_tries )); do
        size=$(sftp_get_size "${remote_path}")
        if [[ "${size}" == "${expected_size}" ]]; then
            echo "${size}"
            return 0
        fi
        if (( attempt < max_tries )); then
            # Write directly to log file + stderr — same reason as sftp_get_size:
            # this function is called inside $(...) so log() stdout would be captured.
            local retry_line="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG]  sftp_get_size_retry: attempt ${attempt}/${max_tries} got '${size}', expected '${expected_size}' — retrying in ${sleep_secs}s (${remote_path})"
            (
                flock -x 200
                echo "${retry_line}" >> "${LOG_FILE}"
                [[ "${CLI_VERBOSE}" == true ]] && echo "${retry_line}" >&2
            ) 200>"${LOG_FILE}.lock"
            sleep "${sleep_secs}"
        fi
        (( attempt++ )) || true
    done
    # Return whatever we last got (caller decides if it's an error)
    echo "${size}"
}

# Create a directory path recursively on SFTP.
# Usage: sftp_mkdir_p "/ihub-db-backups/db/2024"
# Uses "-mkdir" (with leading dash) which suppresses the error that sftp
# would otherwise return when the directory already exists.
sftp_mkdir_p() {
    local full_path="$1"
    local batch_cmds=""
    local current=""

    IFS='/' read -ra parts <<< "${full_path}"
    for part in "${parts[@]}"; do
        [[ -z "${part}" ]] && continue
        current="${current}/${part}"
        batch_cmds+="-mkdir ${current}"$'\n'
    done

    SSHPASS="${SFTP_PASS}" sshpass -e sftp \
        -P "${SFTP_PORT}" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=no \
        -o ConnectTimeout=5 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o LogLevel=ERROR \
        -b <(printf '%s' "${batch_cmds}") \
        "${SFTP_USER}@${SFTP_HOST}" &>/dev/null || true
}

# sftp_download_verify LOCAL_STAGED_FILE SFTP_REMOTE_PATH WORKER_TAG
#
# Re-downloads SFTP_REMOTE_PATH to a temporary .verify file next to
# LOCAL_STAGED_FILE, computes sha256sum of both, and compares them.
#
# Returns:
#   0  — checksums match (SFTP copy is byte-identical to local staged file)
#   1  — checksum mismatch or download/hash failure
#
# The .verify temp file is always removed before returning, even on error.
#
# Design notes:
#   - Uses process-substitution batch mode (same pattern as sftp_get_size)
#     so no temp batch-command file is needed.
#   - The "get REMOTE LOCAL" sftp batch command writes the downloaded file
#     to the local path; sftp exits non-zero on transfer failure.
#   - sha256sum output format: "<hash>  <filename>" — only the hash field
#     is compared so the filename mismatch between .verify and staged is fine.
sftp_download_verify() {
    local local_staged="$1"
    local remote_path="$2"
    local worker_tag="${3:-UL?}"

    local verify_file="${local_staged}.verify"

    # Always clean up the temp verify file, even on early return
    # shellcheck disable=SC2064
    trap "rm -f '${verify_file}'" RETURN

    # Re-download the remote file to a local .verify temp file
    if ! SSHPASS="${SFTP_PASS}" sshpass -e sftp \
            -P "${SFTP_PORT}" \
            -o StrictHostKeyChecking=no \
            -o BatchMode=no \
            -o ConnectTimeout=5 \
            -o ServerAliveInterval=15 \
            -o ServerAliveCountMax=3 \
            -o LogLevel=ERROR \
            -b <(printf 'get %s %s\n' "${remote_path}" "${verify_file}") \
            "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
        log "ERROR" "[${worker_tag}] Checksum verify: failed to re-download from SFTP: ${remote_path}"
        return 1
    fi

    if [[ ! -f "${verify_file}" ]]; then
        log "ERROR" "[${worker_tag}] Checksum verify: re-download produced no local file: ${verify_file}"
        return 1
    fi

    # Compute sha256 for both files; sha256sum output: "<hash>  <path>"
    local hash_staged hash_sftp
    hash_staged=$(sha256sum "${local_staged}" 2>/dev/null | awk '{print $1}')
    hash_sftp=$(sha256sum   "${verify_file}"  2>/dev/null | awk '{print $1}')

    if [[ -z "${hash_staged}" ]] || [[ -z "${hash_sftp}" ]]; then
        log "ERROR" "[${worker_tag}] Checksum verify: sha256sum failed (staged='${hash_staged}' sftp='${hash_sftp}'): ${remote_path}"
        return 1
    fi

    if [[ "${hash_staged}" != "${hash_sftp}" ]]; then
        log "ERROR" "[${worker_tag}] Checksum MISMATCH (staged=${hash_staged}, sftp=${hash_sftp}): ${remote_path}"
        return 1
    fi

    log "DEBUG" "[${worker_tag}] Checksum OK (sha256=${hash_staged}): ${remote_path}"
    return 0
}

# sftp_delete_file REMOTE_PATH WORKER_TAG
#
# Deletes a single file from the SFTP server.  Used to remove a corrupt
# upload so the next run treats it as NOT_FOUND and re-uploads from FTP.
#
# Returns 0 on success, 1 on failure (logged but not fatal — the caller
# must still mark the file as an error and skip _enqueue_confirmed so the
# FTP source is never deleted for a file with an unverified SFTP copy).
sftp_delete_file() {
    local remote_path="$1"
    local worker_tag="${2:-UL?}"

    if SSHPASS="${SFTP_PASS}" sshpass -e sftp \
            -P "${SFTP_PORT}" \
            -o StrictHostKeyChecking=no \
            -o BatchMode=no \
            -o ConnectTimeout=5 \
            -o ServerAliveInterval=15 \
            -o ServerAliveCountMax=3 \
            -o LogLevel=ERROR \
            -b <(printf 'rm %s\n' "${remote_path}") \
            "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
        log "WARN" "[${worker_tag}] Deleted corrupt SFTP file to force re-upload on next run: ${remote_path}"
        return 0
    else
        log "ERROR" "[${worker_tag}] Failed to delete corrupt SFTP file — manual intervention may be required: ${remote_path}"
        return 1
    fi
}