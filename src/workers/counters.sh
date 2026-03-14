#!/usr/bin/env bash
# ============================================================
# src/workers/counters.sh — Atomic Counters & Queue Helpers
#
# All shared-state helpers used by the parallel worker processes.
# Because download and upload workers run as concurrent background
# sub-processes, every read-modify-write on a shared file must be
# protected by an exclusive flock to prevent races.
#
# Atomic counter operations:
#   _counter_add FILE DELTA  — adds DELTA (±int) to a .cnt file;
#                              clamps to zero (counters never go negative).
#   _counter_get FILE        — reads and prints the current value.
#                              Reads do not need a lock because bash
#                              reads a single integer atomically on any
#                              modern filesystem.
#
# Queue helpers:
#   _enqueue_ready()         — appends one tab-separated entry to
#                              ready_queue.txt (LOCAL→SFTP work item).
#   _enqueue_confirmed()     — appends one tab-separated entry to
#                              confirmed_queue.txt (completed upload,
#                              ready for retention check in Stage 3).
#
# Worker result helpers:
#   _inc_result()            — atomically increments a named KEY=VALUE
#                              counter in a per-worker .result file.
#                              merge_worker_results() in pipeline.sh
#                              sums all .result files into the global
#                              CNT_* variables at the end of the run.
#
# Idle reporting:
#   _ul_report_idle()        — prints a rate-limited "X/Y workers idle"
#                              summary line at most once per
#                              DISK_WAIT_INTERVAL seconds across all
#                              upload workers combined.  Uses flock so
#                              only one worker evaluates and prints at a
#                              time, preventing log spam when many workers
#                              are simultaneously waiting for downloads.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()) and
#   src/core/constants.sh (uses TEMP_DIR indirectly via callers).
#   TEMP_DIR and DISK_WAIT_INTERVAL must be set before any of these
#   functions are called (set by setup_temp_dir() and load_config()).
# ============================================================

# _counter_add FILE DELTA
# Atomically adds DELTA (positive or negative integer) to a counter file.
_counter_add() {
    local file="$1"
    local delta="$2"
    local lock="${TEMP_DIR}/counters.lock"
    (
        flock -x 200
        local current
        current=$(cat "${file}" 2>/dev/null || echo 0)
        local new_val=$(( current + delta ))
        (( new_val < 0 )) && new_val=0   # clamp — counters must never go negative
        echo "${new_val}" > "${file}"
    ) 200>"${lock}"
}

# _counter_get FILE — prints current value (read does not need a lock)
_counter_get() {
    cat "${1}" 2>/dev/null || echo 0
}

# _enqueue_ready LOCAL_PATH SFTP_DEST FTP_PATH FTP_SIZE FTP_MTIME
# Appends a tab-separated entry to ready_queue atomically.
# Special LOCAL_PATH values:
#   "SKIP"   — file already confirmed on SFTP; upload worker does retention check only
#   "DRYRUN" — dry-run mode; upload worker logs intent only
_enqueue_ready() {
    local local_path="$1" sftp_dest="$2" ftp_path="$3" ftp_size="$4" ftp_mtime="$5"
    (
        flock -x 200
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${local_path}" "${sftp_dest}" "${ftp_path}" "${ftp_size}" "${ftp_mtime}" \
            >> "${TEMP_DIR}/ready_queue.txt"
    ) 200>"${TEMP_DIR}/ready_queue.lock"
}

# _enqueue_confirmed FTP_PATH FTP_SIZE FTP_MTIME
# Appends a tab-separated entry to confirmed_queue atomically.
# Stage 3 (run_deletion_stage) reads this queue to apply the retention policy.
_enqueue_confirmed() {
    local ftp_path="$1" ftp_size="$2" ftp_mtime="$3"
    (
        flock -x 200
        printf '%s\t%s\t%s\n' "${ftp_path}" "${ftp_size}" "${ftp_mtime}" \
            >> "${TEMP_DIR}/confirmed_queue.txt"
    ) 200>"${TEMP_DIR}/confirmed_queue.lock"
}

# _inc_result RESULT_FILE COUNTER_NAME
# Atomically increments a named counter in a worker result file.
# Result files use KEY=VALUE format; merge_worker_results() reads them.
_inc_result() {
    local result_file="$1" counter="$2"
    (
        flock -x 200
        local current new_val
        current=$(grep "^${counter}=" "${result_file}" 2>/dev/null | cut -d= -f2 || echo 0)
        new_val=$(( current + 1 ))
        if grep -q "^${counter}=" "${result_file}" 2>/dev/null; then
            sed -i "s/^${counter}=.*/${counter}=${new_val}/" "${result_file}"
        else
            echo "${counter}=${new_val}" >> "${result_file}"
        fi
    ) 200>"${result_file}.lock"
}

# _ul_report_idle IDLE_COUNT TOTAL_WORKERS
# Prints an aggregated "Upload Workers: X/Y idle" summary line at most once
# per DISK_WAIT_INTERVAL seconds across all upload workers combined.
# Time-only gate — no change-trigger — prevents flickering when the idle count
# oscillates by 1 as workers briefly deregister to retry the queue each second.
# Uses flock so only one worker evaluates and prints at a time.
_ul_report_idle() {
    local idle_count="$1"
    local total_workers="$2"
    (
        flock -x 200
        local last_print now elapsed
        last_print=$(cat "${TEMP_DIR}/ul_idle_last_print.ts" 2>/dev/null || echo 0)
        now=$(date +%s)
        elapsed=$(( now - last_print ))

        if (( elapsed >= DISK_WAIT_INTERVAL )); then
            log "DEBUG" "Upload Workers: ${idle_count}/${total_workers} thread(s) idle, waiting for downloads"
            echo "${now}" > "${TEMP_DIR}/ul_idle_last_print.ts"
        fi
    ) 200>"${TEMP_DIR}/ul_idle_report.lock"
}