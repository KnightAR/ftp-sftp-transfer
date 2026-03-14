#!/usr/bin/env bash
# ============================================================
# src/pipeline/summary.sh — Run Summary Printer
#
# Defines print_summary(), which is called at the very end of
# main() after cleanup and lock release.
#
# Computes the total run duration from RUN_START_EPOCH (set in
# main()) to now, formats it as either "Xs" or "Xm Ys", then
# renders a fixed-width Unicode box containing:
#   - Start / finish timestamps
#   - Duration
#   - Worker counts
#   - Per-category file counters from the global CNT_* variables
#     (populated by merge_worker_results() in pipeline.sh)
#
# The summary is both printed to stdout and appended to LOG_FILE
# so it appears in the run's log file as well as the terminal.
#
# A final log() call at INFO or WARN level records whether the run
# completed cleanly or with errors, and points the operator to
# ERROR_LOG_FILE if there were any.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log(), LOG_FILE)
#   and src/core/constants.sh (uses RUN_START_TIME, RUN_START_EPOCH,
#   all CNT_* variables, DRY_RUN, FTP_MAX_WORKERS, SFTP_MAX_WORKERS).
# ============================================================

print_summary() {
    local end_epoch
    end_epoch=$(date +%s)
    local end_time
    end_time=$(date '+%Y-%m-%d %H:%M:%S')
    local duration=$(( end_epoch - RUN_START_EPOCH ))

    # Format duration as "Xs" for short runs, "Xm Ys" for anything over a minute
    local duration_str
    if (( duration < 60 )); then
        duration_str="${duration}s"
    else
        duration_str="$(( duration / 60 ))m $(( duration % 60 ))s"
    fi

    # Append "[DRY-RUN]" label to the summary header when applicable
    local dry_run_label=""
    [[ "${DRY_RUN}" == "true" ]] && dry_run_label=" [DRY-RUN]"

    local summary
    summary=$(cat <<EOF

╔══════════════════════════════════════════════════╗
║         Transfer Run Summary${dry_run_label}
╠══════════════════════════════════════════════════╣
║  Started        : ${RUN_START_TIME}
║  Finished       : ${end_time}
║  Duration       : ${duration_str}
║  DL Workers     : ${FTP_MAX_WORKERS}  (FTP → staging)
║  UL Workers     : ${SFTP_MAX_WORKERS}  (staging → SFTP)
╠══════════════════════════════════════════════════╣
║  Files Scanned      : ${CNT_SCANNED}
║  Files Transferred  : ${CNT_TRANSFERRED}
║  Files Overwritten  : ${CNT_OVERWRITTEN}
║  Files Skipped      : ${CNT_SKIPPED}
║  FTP Files Deleted  : ${CNT_DELETED}
║  Errors             : ${CNT_ERRORS}
╚══════════════════════════════════════════════════╝
EOF
)

    # Print to stdout and also append to the run's log file
    echo "${summary}"
    echo "${summary}" >> "${LOG_FILE}"

    if (( CNT_ERRORS > 0 )); then
        log "WARN" "Run completed with ${CNT_ERRORS} error(s). Check: ${ERROR_LOG_FILE}"
    else
        log "INFO" "Run completed successfully with no errors."
    fi
}