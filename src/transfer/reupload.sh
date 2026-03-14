#!/usr/bin/env bash
# ============================================================
# src/transfer/reupload.sh — Persistent Re-upload Flag Helpers
#
# Manages the reupload.log file — a persistent plain-text file
# (one FTP path per line) that survives across runs and temp-dir
# cleanups.  Any path written here is force-reuploaded on the
# next run regardless of whether the file already exists on SFTP.
#
# The file is written when a checksum verification fails after an
# upload, ensuring the corrupt SFTP copy is replaced on the next
# run even if the script is interrupted before it can retry.
# Entries are cleared after a verified-clean successful upload.
#
# All three operations use flock on a companion .lock file so
# concurrent upload workers never race on the same log entry.
#
#   reupload_flag()        — appends FTP_PATH to REUPLOAD_LOG if
#                            not already present (idempotent).
#
#   reupload_clear()       — removes FTP_PATH from REUPLOAD_LOG
#                            after a verified-clean upload.
#
#   reupload_is_flagged()  — returns 0 (true) if FTP_PATH is in
#                            REUPLOAD_LOG, 1 (false) otherwise.
#                            Used by download_worker() to force
#                            re-download before the SFTP size check.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()) and
#   src/core/constants.sh (uses REUPLOAD_LOG).
# ============================================================

# reupload_flag FTP_PATH
# Appends FTP_PATH to REUPLOAD_LOG if not already present (idempotent).
reupload_flag() {
    local ftp_path="$1"
    local lock="${REUPLOAD_LOG}.lock"
    (
        flock -x 200
        touch "${REUPLOAD_LOG}"
        # Only append if the exact path is not already on its own line
        if ! grep -qxF "${ftp_path}" "${REUPLOAD_LOG}" 2>/dev/null; then
            echo "${ftp_path}" >> "${REUPLOAD_LOG}"
        fi
    ) 200>"${lock}"
    log "WARN" "Flagged for re-upload in ${REUPLOAD_LOG}: ${ftp_path}"
}

# reupload_clear FTP_PATH
# Removes FTP_PATH from REUPLOAD_LOG after a verified-clean upload.
# Uses a temp file + mv for atomic in-place replacement so a concurrent
# read by reupload_is_flagged() never sees a partially-written file.
reupload_clear() {
    local ftp_path="$1"
    local lock="${REUPLOAD_LOG}.lock"
    (
        flock -x 200
        if [[ -f "${REUPLOAD_LOG}" ]]; then
            local tmp="${REUPLOAD_LOG}.tmp"
            grep -vxF "${ftp_path}" "${REUPLOAD_LOG}" > "${tmp}" 2>/dev/null || true
            mv "${tmp}" "${REUPLOAD_LOG}"
        fi
    ) 200>"${lock}"
    log "INFO" "Cleared re-upload flag: ${ftp_path}"
}

# reupload_is_flagged FTP_PATH
# Returns 0 (true) if FTP_PATH is in REUPLOAD_LOG, 1 (false) otherwise.
# No lock needed for a read-only grep — the worst case is a slightly
# stale view, which is harmless: a false positive causes a redundant
# re-upload (safe), and a false negative is resolved on the next run.
reupload_is_flagged() {
    local ftp_path="$1"
    [[ -f "${REUPLOAD_LOG}" ]] || return 1
    grep -qxF "${ftp_path}" "${REUPLOAD_LOG}" 2>/dev/null
}