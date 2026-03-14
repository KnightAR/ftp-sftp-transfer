#!/usr/bin/env bash
# ============================================================
# src/pipeline/deletion_stage.sh — Stage 3: FTP Deletion
#
# Defines run_deletion_stage(), which runs after all upload workers
# have finished and applies the mtime-based retention policy to every
# file that was confirmed uploaded during this run.
#
# How it works:
#   1. Reads confirmed_queue.txt (FTP_PATH\tFTP_SIZE\tFTP_MTIME).
#      This queue is populated by upload workers via _enqueue_confirmed()
#      for every file whose SFTP copy was verified (size + checksum).
#   2. Spawns up to FTP_MAX_WORKERS parallel deletion sub-workers to
#      keep deletion throughput proportional to the FTP connection limit.
#   3. Each sub-worker atomically pops entries and evaluates age:
#        age_days = (now_epoch - ftp_mtime) / 86400
#      Files older than RETENTION_DAYS are deleted via delete_ftp_file().
#      Younger files are logged at DEBUG level and left on FTP.
#   4. Waits for all sub-workers before returning.
#
# Note: delete_ftp_file() in src/transfer/ftp_delete.sh applies its own
# DRY_RUN and DELETE_FROM_FTP guards, so this function does not need to
# re-check those flags — it just calls delete_ftp_file() for every
# age-eligible entry and lets the guard layer decide.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()),
#   src/transfer/ftp_delete.sh (uses delete_ftp_file()),
#   src/workers/counters.sh (uses _inc_result()),
#   and src/core/constants.sh (uses TEMP_DIR).
#   load_config() must have run so FTP_MAX_WORKERS, RETENTION_DAYS,
#   and DELETE_FROM_FTP are set.
# ============================================================

run_deletion_stage() {
    local confirmed_queue="${TEMP_DIR}/confirmed_queue.txt"
    local del_lock="${TEMP_DIR}/confirmed_queue.lock"
    local result_file="${TEMP_DIR}/workers/deletion_stage.result"

    # Initialise result counters for the deletion stage
    cat > "${result_file}" <<EOF
SCANNED=0
TRANSFERRED=0
OVERWRITTEN=0
SKIPPED=0
DELETED=0
ERRORS=0
EOF

    local confirmed_count
    confirmed_count=$(wc -l < "${confirmed_queue}")
    log "INFO" "Deletion stage: evaluating ${confirmed_count} confirmed file(s) for FTP retention policy (≥ ${RETENTION_DAYS}d)"

    if (( confirmed_count == 0 )); then
        return 0
    fi

    local now_epoch
    now_epoch=$(date +%s)

    # Spawn up to FTP_MAX_WORKERS deletion sub-workers in parallel.
    # Re-using FTP_MAX_WORKERS (rather than a separate config variable) keeps
    # the total number of simultaneous FTP connections within the same limit
    # used during the download phase.
    local del_pids=()
    for (( i=1; i<=FTP_MAX_WORKERS; i++ )); do
        (
            local my_id="${i}"
            while true; do
                # Atomically pop the next confirmed entry
                local entry=""
                (
                    flock -x 200
                    local _entry
                    _entry=$(head -1 "${confirmed_queue}" 2>/dev/null || true)
                    if [[ -n "${_entry}" ]]; then
                        sed -i '1d' "${confirmed_queue}"
                    fi
                    echo "${_entry}"
                ) 200>"${del_lock}" > "${TEMP_DIR}/workers/del_worker_${my_id}.next"

                entry=$(cat "${TEMP_DIR}/workers/del_worker_${my_id}.next")
                [[ -z "${entry}" ]] && break

                # Parse: FTP_PATH \t FTP_SIZE \t FTP_MTIME
                local ftp_path ftp_size ftp_mtime
                IFS=$'\t' read -r ftp_path ftp_size ftp_mtime <<< "${entry}"

                local age_seconds=$(( now_epoch - ftp_mtime ))
                local age_days=$(( age_seconds / 86400 ))

                if (( age_days >= RETENTION_DAYS )) && [[ "${DELETE_FROM_FTP}" == "true" ]]; then
                    if delete_ftp_file "${ftp_path}" "${my_id}"; then
                        _inc_result "${result_file}" "DELETED"
                    else
                        _inc_result "${result_file}" "ERRORS"
                    fi
                else
                    if [[ "${DELETE_FROM_FTP}" != "true" ]]; then
                        log "DEBUG" "[DEL${my_id}] FTP deletion disabled — keeping: ${ftp_path}"
                    else
                        log "DEBUG" "[DEL${my_id}] File is ${age_days}d old (< ${RETENTION_DAYS}d) — keeping on FTP: ${ftp_path}"
                    fi
                fi
            done
        ) &
        del_pids+=($!)
    done

    # Wait for all deletion sub-workers to finish before returning
    for pid in "${del_pids[@]}"; do
        wait "${pid}" || true
    done

    log "DEBUG" "Deletion stage complete"
}