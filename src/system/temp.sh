#!/usr/bin/env bash
# ============================================================
# src/system/temp.sh — Temp Directory Setup & Cleanup
#
# Manages the staging area used throughout the pipeline:
#
#   setup_temp_dir() — creates (or validates) TEMP_DIR, builds the
#                      subdirectory layout, and initialises all queue
#                      files and shared atomic counter files that
#                      workers communicate through.
#
#   cleanup_temp()   — tears down the staging area after the run.
#                      If mktemp created TEMP_DIR (TEMP_DIR_CREATED=true)
#                      the entire directory is removed.  If the operator
#                      supplied a custom path via -t, only the contents
#                      created by this script are removed — the directory
#                      itself is left intact.
#
# Queue file layout (all under TEMP_DIR):
#   work_queue.txt      — SIZE EPOCH PATH (space-separated)
#                         Populated by get_ftp_file_list(); consumed by
#                         download workers.
#   ready_queue.txt     — LOCAL_PATH\tSFTP_DEST\tFTP_PATH\tFTP_SIZE\tFTP_MTIME
#                         LOCAL_PATH="SKIP"   → already on SFTP, retention only
#                         LOCAL_PATH="DRYRUN" → dry-run mode, log only
#   confirmed_queue.txt — FTP_PATH\tFTP_SIZE\tFTP_MTIME
#                         Uploads confirmed; Stage 3 retention check reads this.
#
# Counter file layout (all under TEMP_DIR):
#   in_flight_bytes.cnt    — bytes reserved for active downloads (disk guard)
#   active_downloaders.cnt — running FTP download worker count
#   active_uploaders.cnt   — running SFTP upload worker count
#   idle_uploaders.cnt     — upload workers currently waiting for the queue
#   ul_idle_last_print.ts  — epoch of last printed idle summary (rate-limiter)
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()) and
#   src/core/constants.sh (uses TEMP_DIR, TEMP_DIR_CREATED).
# ============================================================

setup_temp_dir() {
    if [[ -n "${TEMP_DIR:-}" ]]; then
        # Operator supplied a custom path via config or -t flag
        mkdir -p "${TEMP_DIR}"
        chmod 700 "${TEMP_DIR}"
        log "DEBUG" "Using custom temp directory: ${TEMP_DIR}"
    else
        # Create a private temp directory; TEMP_DIR_CREATED=true tells
        # cleanup_temp() to remove the whole directory, not just its contents.
        TEMP_DIR=$(mktemp -d -t ftp_sftp_XXXXXXXXXX)
        chmod 700 "${TEMP_DIR}"
        TEMP_DIR_CREATED=true
        log "DEBUG" "Created temp directory: ${TEMP_DIR}"
    fi

    # Staging subdirectories for workers
    mkdir -p "${TEMP_DIR}/staging"
    mkdir -p "${TEMP_DIR}/workers"

    # ---- Queue files ----
    # work_queue.txt      : SIZE EPOCH PATH — files to download from FTP (space-separated)
    # ready_queue.txt     : LOCAL_PATH\tSFTP_DEST_PATH\tFTP_PATH\tFTP_SIZE\tFTP_MTIME
    #                       files downloaded and waiting for SFTP upload
    #                       LOCAL_PATH="SKIP"   — already on SFTP, retention check only
    #                       LOCAL_PATH="DRYRUN" — dry-run mode, log only
    # confirmed_queue.txt : FTP_PATH\tFTP_SIZE\tFTP_MTIME — uploads confirmed, check retention
    touch "${TEMP_DIR}/work_queue.txt"
    touch "${TEMP_DIR}/work_queue.lock"
    touch "${TEMP_DIR}/ready_queue.txt"
    touch "${TEMP_DIR}/ready_queue.lock"
    touch "${TEMP_DIR}/confirmed_queue.txt"
    touch "${TEMP_DIR}/confirmed_queue.lock"

    # ---- Shared atomic counter files ----
    # in_flight_bytes.cnt    : bytes currently reserved for active downloads
    # active_downloaders.cnt : number of running FTP download worker processes
    # active_uploaders.cnt   : number of running SFTP upload worker processes
    echo "0" > "${TEMP_DIR}/in_flight_bytes.cnt"
    echo "0" > "${TEMP_DIR}/active_downloaders.cnt"
    echo "0" > "${TEMP_DIR}/active_uploaders.cnt"
    touch "${TEMP_DIR}/counters.lock"

    # ---- Upload worker idle reporting state ----
    # idle_uploaders.cnt   : workers currently in the empty-queue wait loop
    # ul_idle_last_print.ts : epoch of the last printed idle summary line
    # ul_idle_report.lock  : ensures only one worker evaluates/prints at a time
    echo "0" > "${TEMP_DIR}/idle_uploaders.cnt"
    echo "0" > "${TEMP_DIR}/ul_idle_last_print.ts"
    touch "${TEMP_DIR}/ul_idle_report.lock"
}

# cleanup_job_dir JOB_DIR
# Removes the per-job subdirectory created by split_transfer.sh or
# split_restore.sh.  Each job uses its own scoped directory under TEMP_DIR
# (SPLIT_JOB_DIR or RESTORE_JOB_DIR) so this call only ever touches that
# one job's files — it cannot affect other concurrent jobs or transfer.sh.
#
# JOB_DIR must be a non-empty path that is a direct child of TEMP_DIR.
# The safety check prevents accidental rm -rf of arbitrary paths.
cleanup_job_dir() {
    local job_dir="${1:-}"
    if [[ -z "${job_dir}" ]]; then
        return 0
    fi
    # Safety: job_dir must be a non-empty subdir of a non-empty TEMP_DIR
    if [[ -z "${TEMP_DIR:-}" ]] || [[ "${job_dir}" == "${TEMP_DIR}" ]]; then
        log "WARN" "cleanup_job_dir: refusing to remove job_dir that equals TEMP_DIR: ${job_dir}"
        return 1
    fi
    if [[ -d "${job_dir}" ]]; then
        rm -rf "${job_dir}"
        log "DEBUG" "Removed job directory: ${job_dir}"
    fi
}

cleanup_temp() {
    if [[ "${TEMP_DIR_CREATED}" == true ]] && [[ -d "${TEMP_DIR:-}" ]]; then
        # mktemp-created directory — remove entirely
        rm -rf "${TEMP_DIR}"
        log "DEBUG" "Removed temp directory: ${TEMP_DIR}"
    else
        # Custom directory — remove only the files/subdirs this script created,
        # leaving the directory itself and any pre-existing contents untouched.
        if [[ -d "${TEMP_DIR:-}" ]]; then
            # ---- transfer.sh / split_transfer.sh paths ----
            rm -rf "${TEMP_DIR:?}/staging"
            rm -rf "${TEMP_DIR:?}/workers"
            rm -rf "${TEMP_DIR:?}/mirror_dummy"
            rm -f  "${TEMP_DIR}/work_queue.txt"      "${TEMP_DIR}/work_queue.lock"
            rm -f  "${TEMP_DIR}/ready_queue.txt"     "${TEMP_DIR}/ready_queue.lock"
            rm -f  "${TEMP_DIR}/confirmed_queue.txt" "${TEMP_DIR}/confirmed_queue.lock"
            rm -f  "${TEMP_DIR}/in_flight_bytes.cnt"
            rm -f  "${TEMP_DIR}/active_downloaders.cnt"
            rm -f  "${TEMP_DIR}/active_uploaders.cnt"
            rm -f  "${TEMP_DIR}/counters.lock"
            rm -f  "${TEMP_DIR}/idle_uploaders.cnt"
            rm -f  "${TEMP_DIR}/ul_idle_last_print.ts"
            rm -f  "${TEMP_DIR}/ul_idle_report.lock"
            rm -f  "${TEMP_DIR}/ftp_listing.txt"
            # Remove any leftover .verify temp files from checksum verification
            find "${TEMP_DIR}" -maxdepth 4 -name "*.verify" -delete 2>/dev/null || true
            log "DEBUG" "Cleaned contents of custom temp directory: ${TEMP_DIR}"
        fi
    fi
}