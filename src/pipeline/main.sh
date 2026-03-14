#!/usr/bin/env bash
# ============================================================
# src/pipeline/main.sh — Main Entrypoint
#
# Defines main(), which is the top-level orchestration function
# called by transfer.sh.  It sequences every setup step and
# pipeline stage in the correct dependency order:
#
#   1.  parse_args()          — process CLI flags (-c, -d, -v, -V …)
#   2.  load_config()         — source config file, apply CLI overrides,
#                               set defaults, validate all variables
#   3.  setup_logging()       — create LOG_DIR, open LOG_FILE and ERROR_LOG_FILE
#   4.  Startup log banner    — version, PID, mode flags
#   5.  reupload.log warning  — alert operator if prior checksum failures
#                               are pending re-upload on this run
#   6.  check_dependencies()  — verify lftp, sshpass, sftp are present
#   7.  acquire_lock()        — prevent overlapping cron runs
#   8.  setup_temp_dir()      — create staging area and queue/counter files
#   9.  load_exclusions()     — read EXCLUDE_LIST patterns into memory
#   10. setup_ftp_connection() — test FTP connectivity, assemble FTP_CONNECT_STR
#   11. get_ftp_file_list()   — recursive FTP listing → work_queue.txt
#   12. run_pipeline()        — Stage 1 (download) + Stage 2 (upload) +
#                               Stage 3 (deletion) + merge results
#   13. rotate_logs()         — prune transfer_*.log files older than
#                               LOG_RETENTION_DAYS
#   14. cleanup_temp()        — remove staging area
#   15. release_lock()        — remove PID lock file
#   16. trap removal          — disarm trap_cleanup so the final cleanup
#                               calls above do not trigger a second pass
#   17. print_summary()       — render and log the run summary box
#
# The trap registered in src/system/trap.sh handles abnormal exits
# (Ctrl+C, SIGTERM, unhandled errors) and calls cleanup_temp() +
# release_lock() automatically.  The explicit calls in steps 14–15
# above are for the clean-exit path only; "trap - INT TERM EXIT" in
# step 16 prevents the trap from running a second cleanup after main()
# has already done it.
#
# Dependency order:
#   This file must be sourced last — it calls functions from every
#   other module.  All other src/**/*.sh files must be sourced before
#   this one (enforced by the source order in transfer.sh).
# ============================================================

main() {
    RUN_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    RUN_START_EPOCH=$(date +%s)

    # 1. Parse CLI flags
    parse_args "$@"

    # 2. Load and validate configuration
    load_config

    # 3. Setup logging (needs LOG_DIR from config)
    setup_logging

    log "INFO" "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} — Transfer run started (PID $$) ==="
    [[ "${DRY_RUN}"        == "true" ]] && log "INFO" "*** DRY-RUN MODE ENABLED — No files will be moved or deleted ***"
    [[ "${VERIFY_MODE}"    == "true" ]] && log "INFO" "*** VERIFY MODE ENABLED — All FTP files will be re-downloaded and SFTP copies checksum-verified ***"
    [[ "${VERIFY_CHECKSUM}" == "true" ]] && [[ "${VERIFY_MODE}" != "true" ]] && log "INFO" "Checksum verification enabled (VERIFY_CHECKSUM=true) — SFTP uploads will be re-downloaded and sha256-verified"

    # 5. Warn at startup if reupload.log has entries from a previous checksum failure.
    # This gives the operator an immediate heads-up before the run begins rather than
    # only discovering re-uploads mid-run in the log.
    if [[ -f "${REUPLOAD_LOG}" ]]; then
        local reupload_count
        reupload_count=$(grep -c . "${REUPLOAD_LOG}" 2>/dev/null || echo 0)
        if (( reupload_count > 0 )); then
            log "WARN" "*** REUPLOAD PENDING: ${reupload_count} file(s) flagged for forced re-upload from a previous checksum failure ***"
            log "WARN" "    Flagged file list: ${REUPLOAD_LOG}"
            while IFS= read -r flagged_path; do
                [[ -z "${flagged_path}" ]] && continue
                log "WARN" "    Re-upload pending: ${flagged_path}"
            done < "${REUPLOAD_LOG}"
        fi
    fi

    # 6. Check required dependencies (with interactive install prompt)
    check_dependencies

    # 7. Acquire PID lock (prevent overlapping cron runs)
    acquire_lock
    log "DEBUG" "Acquired PID lock: ${LOCK_FILE}"

    # 8. Setup temp/staging directory
    setup_temp_dir

    # 9. Load exclusion patterns
    load_exclusions

    # 10. Setup and verify FTP connection
    setup_ftp_connection

    # 11. Retrieve recursive FTP file listing → work queue
    get_ftp_file_list

    local queue_size
    queue_size=$(wc -l < "${TEMP_DIR}/work_queue.txt")
    log "INFO" "Work queue populated: ${queue_size} file(s) to evaluate"

    # 12. Run decoupled download/upload pipeline (Stages 1, 2, 3)
    run_pipeline

    # 13. Rotate old general logs
    rotate_logs

    # 14. Clean up temp directory
    cleanup_temp

    # 15. Release PID lock
    release_lock

    # 16. Remove the trap now that we're doing a clean exit.
    # Without this, bash would fire trap_cleanup() on EXIT after main() returns,
    # which would call cleanup_temp() and release_lock() a second time.
    trap - INT TERM EXIT

    # 17. Print and log run summary
    print_summary
}