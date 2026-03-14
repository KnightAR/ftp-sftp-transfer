#!/usr/bin/env bash
# ============================================================
# src/transfer/ftp_delete.sh — FTP File Deletion
#
# Provides delete_ftp_file(), the single function responsible for
# removing a file from the source FTP server after it has been
# confirmed safely uploaded to SFTP and has exceeded the retention
# period defined by RETENTION_DAYS.
#
# Deletion is intentionally isolated in its own file because it is
# the most destructive operation in the pipeline — a bug here could
# permanently remove source files.  Keeping it separate makes the
# guard logic (dry-run, DELETE_FROM_FTP flag) immediately visible
# without having to read through transfer or worker code.
#
# Guard behaviour:
#   - DRY_RUN=true          → logs intent, returns 0 (no network call)
#   - DELETE_FROM_FTP!=true → logs skip, returns 0 (no network call)
#   - Otherwise             → calls run_lftp "rm <path>"
#
# The retention age check (RETENTION_DAYS) is performed by the caller
# (run_deletion_stage) before delete_ftp_file() is invoked, so this
# function only needs to handle the "should I actually delete?" guards.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()) and
#   src/transfer/ftp.sh (uses run_lftp()).
#   load_config() must have run so DRY_RUN, DELETE_FROM_FTP,
#   and RETENTION_DAYS are set.
# ============================================================

delete_ftp_file() {
    local ftp_path="$1"
    local worker_id="${2:-0}"

    # Guard: dry-run mode — never touch the FTP server
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "INFO" "[DRY-RUN] Would delete from FTP: ${ftp_path}"
        return 0
    fi

    # Guard: deletion explicitly disabled via config or -n flag
    if [[ "${DELETE_FROM_FTP}" != "true" ]]; then
        log "DEBUG" "FTP deletion disabled — skipping: ${ftp_path}"
        return 0
    fi

    if run_lftp "rm ${ftp_path}" &>/dev/null; then
        log "INFO" "[DEL${worker_id}] Deleted from FTP (age ≥ ${RETENTION_DAYS}d, confirmed on SFTP): ${ftp_path}"
        return 0
    else
        log "ERROR" "[DEL${worker_id}] Failed to delete from FTP: ${ftp_path}"
        return 1
    fi
}