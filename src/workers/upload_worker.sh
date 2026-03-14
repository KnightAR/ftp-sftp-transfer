#!/usr/bin/env bash
# ============================================================
# src/workers/upload_worker.sh — Stage 2: SFTP Upload Worker
#
# Defines upload_worker(), which is spawned in parallel by
# run_pipeline() — one process per SFTP_MAX_WORKERS setting.
#
# Each worker instance runs an independent polling loop that:
#
#   1. Atomically pops one entry from ready_queue.txt
#      (LOCAL_PATH\tSFTP_DEST\tFTP_PATH\tFTP_SIZE\tFTP_MTIME).
#   2. If the queue is empty but downloaders are still running,
#      registers as idle and sleeps 1s before retrying.  Idle
#      count is reported via _ul_report_idle() (rate-limited).
#   3. If the queue is empty and all downloaders are done, exits.
#   4. Handles three entry types:
#        SKIP    — file already on SFTP; enqueue for retention check.
#        DRYRUN  — dry-run mode; log intent, enqueue for retention log.
#        <path>  — real local staged file; proceed with upload.
#   5. For real entries, branches on VERIFY_MODE:
#        VERIFY_MODE=true:
#          - Does NOT re-upload (the SFTP copy is expected to exist).
#          - Checks size via sftp_get_size().
#          - Calls sftp_download_verify() to compare sha256 of the
#            FTP-fresh staged file against the existing SFTP copy.
#          - On failure: reupload_flag() + sftp_delete_file() so the
#            next normal run re-uploads from scratch.
#          - On success: reupload_clear(), enqueue confirmed.
#        Normal mode:
#          - sftp_mkdir_p() to ensure destination directory exists.
#          - sshpass sftp put to upload.
#          - sftp_get_size_retry() to verify post-upload size
#            (retries handle object-storage commit lag).
#          - If VERIFY_CHECKSUM=true: sftp_download_verify().
#          - On checksum failure: reupload_flag() + sftp_delete_file().
#          - On success: reupload_clear(), log confirmed, enqueue.
#   6. Confirmed entries are appended to confirmed_queue.txt for
#      Stage 3 (run_deletion_stage) to apply the retention policy.
#   7. Deletes the local staged file after every outcome (success or
#      failure) to free staging disk space promptly.
#
# Per-worker result files (TEMP_DIR/workers/ul_worker_N.result) are
# written in KEY=VALUE format — upload workers only increment ERRORS
# and DELETED since transfer counts are recorded by download workers.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh, src/core/constants.sh,
#   src/transfer/sftp.sh (uses sftp_get_size, sftp_get_size_retry,
#     sftp_mkdir_p, sftp_download_verify, sftp_delete_file),
#   src/transfer/reupload.sh (uses reupload_flag, reupload_clear),
#   src/workers/counters.sh (uses _counter_add, _counter_get,
#     _enqueue_confirmed, _inc_result, _ul_report_idle).
# ============================================================

upload_worker() {
    local worker_id="$1"
    local result_file="${TEMP_DIR}/workers/ul_worker_${worker_id}.result"
    local queue_file="${TEMP_DIR}/ready_queue.txt"
    local lock_file="${TEMP_DIR}/ready_queue.lock"

    # Upload workers only track deletion errors from the retention phase;
    # transfer counts are already recorded by download workers.
    cat > "${result_file}" <<EOF
SCANNED=0
TRANSFERRED=0
OVERWRITTEN=0
SKIPPED=0
DELETED=0
ERRORS=0
EOF

    _counter_add "${TEMP_DIR}/active_uploaders.cnt" 1
    log "DEBUG" "Upload worker ${worker_id} started (PID $$)"

    while true; do
        # Atomically pop the next entry from the ready queue.
        # Same flock+file pattern as download_worker to avoid $() capture races.
        local line=""
        (
            flock -x 200
            local _line
            _line=$(head -1 "${queue_file}" 2>/dev/null || true)
            if [[ -n "${_line}" ]]; then
                sed -i '1d' "${queue_file}"
            fi
            echo "${_line}"
        ) 200>"${lock_file}" > "${TEMP_DIR}/workers/ul_worker_${worker_id}.next_line"

        line=$(cat "${TEMP_DIR}/workers/ul_worker_${worker_id}.next_line")

        if [[ -z "${line}" ]]; then
            # Queue is empty — only exit if all downloaders are also done
            local active_dl
            active_dl=$(_counter_get "${TEMP_DIR}/active_downloaders.cnt")
            if (( active_dl == 0 )); then
                log "DEBUG" "Upload worker ${worker_id} — queue empty and all downloaders finished, exiting"
                break
            fi
            # Register as idle, print aggregated summary (rate-limited), then wait.
            # idle_uploaders.cnt tracks workers genuinely waiting — distinct from
            # active_uploaders.cnt which counts all workers alive regardless of state.
            _counter_add "${TEMP_DIR}/idle_uploaders.cnt" 1
            local idle_count
            idle_count=$(_counter_get "${TEMP_DIR}/idle_uploaders.cnt")
            _ul_report_idle "${idle_count}" "${SFTP_MAX_WORKERS}"
            sleep 1
            # Deregister idle before looping back to try the queue again
            _counter_add "${TEMP_DIR}/idle_uploaders.cnt" -1
            continue
        fi

        # Parse tab-separated ready_queue entry:
        # LOCAL_PATH \t SFTP_DEST_PATH \t FTP_PATH \t FTP_SIZE \t FTP_MTIME
        local local_path sftp_dest_path ftp_path ftp_size ftp_mtime
        IFS=$'\t' read -r local_path sftp_dest_path ftp_path ftp_size ftp_mtime <<< "${line}"

        if [[ -z "${ftp_path}" ]] || [[ -z "${ftp_size}" ]] || [[ -z "${ftp_mtime}" ]]; then
            log "WARN" "Upload worker ${worker_id} — malformed ready_queue entry, skipping: '${line}'"
            continue
        fi

        local upload_confirmed=false

        # ---- SKIP: already confirmed on SFTP — retention check only ----
        if [[ "${local_path}" == "SKIP" ]]; then
            # In VERIFY_MODE download_worker forces re-download of every file,
            # so SKIP entries should not appear.  If one does (edge case), log it
            # so the operator knows this file was not re-verified via checksum.
            if [[ "${VERIFY_MODE}" == "true" ]]; then
                log "WARN" "[UL${worker_id}] VERIFY_MODE: unexpected SKIP entry — file not re-verified: ${ftp_path}"
            else
                log "DEBUG" "[UL${worker_id}] Already on SFTP — retention check only: ${ftp_path}"
            fi
            upload_confirmed=true

        # ---- DRYRUN: log intent only ----
        elif [[ "${local_path}" == "DRYRUN" ]]; then
            log "INFO" "[DRY-RUN] Would upload: ${ftp_path} → ${sftp_dest_path} (${ftp_size} bytes)"
            upload_confirmed=true

        # ---- Real upload ----
        else
            local sftp_dest_dir
            sftp_dest_dir=$(dirname "${sftp_dest_path}")

            if [[ "${VERIFY_MODE}" == "true" ]]; then
                # ---- VERIFY_MODE: skip re-uploading, verify the existing SFTP copy ----
                # download_worker already re-downloaded the file from FTP to staging so
                # we have a fresh local copy to checksum against.  We must NOT re-upload
                # because the file is expected to already be correct on SFTP — the whole
                # point of verify mode is to confirm the existing copy without overwriting.
                log "INFO" "[UL${worker_id}] [VERIFY] Skipping upload — verifying existing SFTP copy: ${sftp_dest_path}"

                # Size check first — if NOT_FOUND the file is genuinely missing on SFTP
                local verify_size
                verify_size=$(sftp_get_size "${sftp_dest_path}")
                if [[ "${verify_size}" == "NOT_FOUND" ]]; then
                    log "ERROR" "[UL${worker_id}] [VERIFY] File not found on SFTP — was never uploaded: ${sftp_dest_path}"
                    rm -f "${local_path}"
                    _inc_result "${result_file}" "ERRORS"
                    continue
                fi
                if [[ "${verify_size}" != "${ftp_size}" ]]; then
                    log "ERROR" "[UL${worker_id}] [VERIFY] Size mismatch on SFTP (expected=${ftp_size}, sftp_reported=${verify_size}): ${sftp_dest_path}"
                    rm -f "${local_path}"
                    _inc_result "${result_file}" "ERRORS"
                    continue
                fi

                # Checksum: re-download SFTP copy and compare against FTP-fresh staged file
                if ! sftp_download_verify "${local_path}" "${sftp_dest_path}" "UL${worker_id}"; then
                    log "ERROR" "[UL${worker_id}] [VERIFY] Checksum FAILED — flagging for re-upload and deleting corrupt SFTP copy: ${sftp_dest_path}"
                    # 1. Write to reupload.log before delete attempt
                    reupload_flag "${ftp_path}"
                    # 2. Delete the corrupt SFTP copy
                    sftp_delete_file "${sftp_dest_path}" "UL${worker_id}"
                    rm -f "${local_path}"
                    _inc_result "${result_file}" "ERRORS"
                    continue
                fi

                # Checksum passed — remove from reupload.log if previously flagged
                reupload_clear "${ftp_path}"
                log "INFO" "[UL${worker_id}] [VERIFY] Verified OK [${ftp_size} bytes, checksum OK]: ${ftp_path} → ${sftp_dest_path}"
                rm -f "${local_path}"
                upload_confirmed=true

            else
                # ---- Normal mode: upload → size verify → checksum verify ----
                log "DEBUG" "[UL${worker_id}] Ensuring SFTP directory: ${sftp_dest_dir}"
                sftp_mkdir_p "${sftp_dest_dir}"

                log "DEBUG" "[UL${worker_id}] Uploading: ${local_path} → ${sftp_dest_path}"
                if ! SSHPASS="${SFTP_PASS}" sshpass -e sftp \
                        -P "${SFTP_PORT}" \
                        -o StrictHostKeyChecking=no \
                        -o BatchMode=no \
                        -o ConnectTimeout=30 \
                        -o LogLevel=ERROR \
                        -b <(printf 'put %s %s\n' "${local_path}" "${sftp_dest_path}") \
                        "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
                    log "ERROR" "[UL${worker_id}] SFTP upload failed: ${sftp_dest_path}"
                    rm -f "${local_path}"
                    _inc_result "${result_file}" "ERRORS"
                    continue
                fi

                # Verify upload by re-checking size on SFTP.
                # Uses sftp_get_size_retry (up to 4 attempts, 3s apart) because some
                # object-storage SFTP backends report a partial/chunk size immediately
                # after put completes and need a moment to commit the final file size.
                local post_size
                post_size=$(sftp_get_size_retry "${sftp_dest_path}" "${ftp_size}")
                if [[ "${post_size}" != "${ftp_size}" ]]; then
                    log "ERROR" "[UL${worker_id}] Upload size verification failed (expected=${ftp_size}, sftp_reported=${post_size}): ${sftp_dest_path}"
                    rm -f "${local_path}"
                    _inc_result "${result_file}" "ERRORS"
                    continue
                fi

                # Checksum verification — re-download the SFTP copy and compare sha256
                # against the local staged file.  Always enabled on this intranet/uncapped
                # connection; controlled by VERIFY_CHECKSUM in the config.
                if [[ "${VERIFY_CHECKSUM}" == "true" ]]; then
                    if ! sftp_download_verify "${local_path}" "${sftp_dest_path}" "UL${worker_id}"; then
                        log "ERROR" "[UL${worker_id}] Checksum verification failed — flagging for re-upload and deleting corrupt SFTP copy: ${sftp_dest_path}"
                        # 1. Write to reupload.log before delete attempt so the file
                        #    is flagged even if the SFTP delete fails.
                        reupload_flag "${ftp_path}"
                        # 2. Delete the corrupt SFTP copy so the next run finds
                        #    NOT_FOUND and re-uploads cleanly.
                        sftp_delete_file "${sftp_dest_path}" "UL${worker_id}"
                        rm -f "${local_path}"
                        _inc_result "${result_file}" "ERRORS"
                        continue
                    fi
                fi

                # Checksum passed — remove from reupload.log if previously flagged
                reupload_clear "${ftp_path}"
                log "INFO" "[UL${worker_id}] Upload confirmed [${ftp_size} bytes, checksum OK]: ${ftp_path} → ${sftp_dest_path}"
                rm -f "${local_path}"
                upload_confirmed=true
            fi
        fi

        # Enqueue for Stage 3 retention check if upload was confirmed
        if [[ "${upload_confirmed}" == true ]]; then
            _enqueue_confirmed "${ftp_path}" "${ftp_size}" "${ftp_mtime}"
        fi

    done

    _counter_add "${TEMP_DIR}/active_uploaders.cnt" -1
    log "DEBUG" "Upload worker ${worker_id} finished"
}