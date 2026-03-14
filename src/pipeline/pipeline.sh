#!/usr/bin/env bash
# ============================================================
# src/pipeline/pipeline.sh — Pipeline Orchestrator
#
# Defines two functions that coordinate the three-stage pipeline:
#
#   run_pipeline()          — launches all download and upload workers
#                             in parallel, waits for them to finish,
#                             then calls run_deletion_stage() and
#                             merge_worker_results().
#
#   merge_worker_results()  — reads every per-worker .result file from
#                             TEMP_DIR/workers/ and accumulates their
#                             KEY=VALUE counters into the global CNT_*
#                             variables declared in constants.sh.
#                             Called once at the end of run_pipeline()
#                             so print_summary() has final totals.
#
# Pipeline stages:
#   Stage 1 — FTP_MAX_WORKERS download workers (download_worker.sh)
#             Each pops from work_queue.txt, downloads to staging,
#             and pushes to ready_queue.txt.
#
#   Stage 2 — SFTP_MAX_WORKERS upload workers (upload_worker.sh)
#             Each pops from ready_queue.txt, uploads to SFTP, and
#             pushes confirmed entries to confirmed_queue.txt.
#             Workers self-exit once the queue is drained and all
#             downloaders have finished.
#
#   Stage 3 — run_deletion_stage() (deletion_stage.sh)
#             Runs serially after all workers finish; reads
#             confirmed_queue.txt and applies retention policy.
#
# Worker PIDs are tracked in WORKER_PIDS[] (constants.sh) so that
# trap_cleanup() can send SIGTERM to all workers on an abnormal exit.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh, src/core/constants.sh,
#   src/workers/download_worker.sh, src/workers/upload_worker.sh,
#   src/pipeline/deletion_stage.sh.
#   load_config() must have run so FTP_MAX_WORKERS and SFTP_MAX_WORKERS
#   are set.
# ============================================================

run_pipeline() {
    local queue_size
    queue_size=$(wc -l < "${TEMP_DIR}/work_queue.txt")

    if (( queue_size == 0 )); then
        log "INFO" "Work queue is empty — nothing to process"
        return 0
    fi

    log "INFO" "Starting pipeline: ${FTP_MAX_WORKERS} FTP download worker(s), ${SFTP_MAX_WORKERS} SFTP upload worker(s) — ${queue_size} file(s) queued"

    mkdir -p "${TEMP_DIR}/workers"

    # ---- Stage 1: Launch FTP download workers ----
    local dl_pids=()
    for (( i=1; i<=FTP_MAX_WORKERS; i++ )); do
        download_worker "${i}" &
        dl_pids+=($!)
        WORKER_PIDS+=($!)
        log "DEBUG" "Spawned download worker ${i} (PID ${!})"
    done

    # ---- Stage 2: Launch SFTP upload workers ----
    # Uploaders start immediately and poll ready_queue; they self-exit once
    # the queue is drained and all downloaders are confirmed done.
    local ul_pids=()
    for (( i=1; i<=SFTP_MAX_WORKERS; i++ )); do
        upload_worker "${i}" &
        ul_pids+=($!)
        WORKER_PIDS+=($!)
        log "DEBUG" "Spawned upload worker ${i} (PID ${!})"
    done

    # Wait for all download workers
    local any_error=false
    for pid in "${dl_pids[@]}"; do
        if ! wait "${pid}"; then
            log "ERROR" "Download worker (PID ${pid}) exited with an error"
            any_error=true
        fi
    done
    [[ "${any_error}" == true ]] && log "WARN" "One or more download workers encountered errors"

    # Wait for all upload workers
    any_error=false
    for pid in "${ul_pids[@]}"; do
        if ! wait "${pid}"; then
            log "ERROR" "Upload worker (PID ${pid}) exited with an error"
            any_error=true
        fi
    done
    [[ "${any_error}" == true ]] && log "WARN" "One or more upload workers encountered errors"

    # ---- Stage 3: FTP deletion (all uploads confirmed) ----
    run_deletion_stage

    # ---- Merge worker result files into global counters ----
    merge_worker_results
}

merge_worker_results() {
    # Sum every per-worker KEY=VALUE result file into the global CNT_* counters.
    # Worker result files are written by download_worker, upload_worker, and
    # run_deletion_stage into TEMP_DIR/workers/*.result
    for result_file in "${TEMP_DIR}/workers"/*.result; do
        [[ -f "${result_file}" ]] || continue
        while IFS='=' read -r key value; do
            [[ -z "${key}" ]] && continue
            case "${key}" in
                SCANNED)     CNT_SCANNED=$(( CNT_SCANNED + value )) ;;
                TRANSFERRED) CNT_TRANSFERRED=$(( CNT_TRANSFERRED + value )) ;;
                OVERWRITTEN) CNT_OVERWRITTEN=$(( CNT_OVERWRITTEN + value )) ;;
                SKIPPED)     CNT_SKIPPED=$(( CNT_SKIPPED + value )) ;;
                DELETED)     CNT_DELETED=$(( CNT_DELETED + value )) ;;
                ERRORS)      CNT_ERRORS=$(( CNT_ERRORS + value )) ;;
            esac
        done < "${result_file}"
    done
}