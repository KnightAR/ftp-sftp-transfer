#!/usr/bin/env bash
# ============================================================
# src/split/restore_worker.sh — Parallel Part Download Worker
#
# Defines restore_download_worker(), spawned in parallel by
# split_restore.sh — one process per SPLIT_RESTORE_WORKERS setting.
#
# Role in the restore pipeline:
#   restore_download_worker()  (this file)  — N parallel workers
#     Download part from SFTP → verify size + sha256 → mark VERIFIED
#   restore_commit_thread()    (restore_commit.sh) — 1 sequential thread
#     Watches for VERIFIED parts in order → appends to output file →
#     marks COMMITTED → deletes local part
#
# Each worker instance:
#   1. Atomically pops the next part filename from the shared
#      download queue (TEMP_DIR/restore_part_queue.txt).
#   2. Downloads the part from SFTP into PARTS_STAGING_DIR, retrying up
#      to SPLIT_RESTORE_RETRIES times on failure (transient connection
#      rejections or empty listings from object-storage backends).
#   3. Verifies the downloaded size matches the manifest size for
#      that part (fast check before sha256).
#   4. Computes sha256 of the downloaded part and compares against
#      the manifest hash for that part.
#   5. On verify OK  — writes VERIFIED to
#      TEMP_DIR/restore_status/<partname> so the commit thread knows
#      it is safe to append this part to the output file.
#      Does NOT delete the local part — the commit thread does that
#      after appending.
#   6. On verify FAIL — logs error, marks FAILED, deletes the
#      corrupt local part file so a re-run re-downloads it cleanly.
#   7. Resume support: if the status file for a part already says COMMITTED
#      (staging preserved from a prior failed run), skips the part entirely —
#      it was already appended to the output file.  If the local part file
#      exists with matching size+sha256, marks it VERIFIED without
#      re-downloading.
#   8. Writes a per-worker result file for summary merging.
#
# Shared state files (all under TEMP_DIR):
#   restore_part_queue.txt     — one part filename per line; atomically popped
#   restore_part_queue.lock    — flock target for queue pop
#   restore_status/            — one file per part: VERIFIED, FAILED,
#                                or COMMITTED (written by commit thread)
#
# Disk usage note:
#   Peak usage during restore ≈ original_file_size + 1 part (commit
#   thread deletes each part after appending).  Workers only hold
#   one downloaded part at a time while the commit thread consumes
#   completed parts concurrently.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh, src/core/constants.sh,
#   src/transfer/sftp.sh (uses sftp_get_size),
#   src/split/split_manifest.sh (uses get_manifest_part_hash,
#   get_manifest_part_size).
# ============================================================

# restore_download_worker WORKER_ID PARTS_STAGING_DIR SFTP_PARTS_DIR
restore_download_worker() {
    local worker_id="$1"
    local parts_staging_dir="$2"
    local sftp_parts_dir="$3"
    local result_file="${RESTORE_JOB_DIR}/workers/restore_dl_worker_${worker_id}.result"
    local queue_file="${RESTORE_JOB_DIR}/restore_part_queue.txt"
    local lock_file="${RESTORE_JOB_DIR}/restore_part_queue.lock"

    cat > "${result_file}" <<EOF
VERIFIED=0
FAILED=0
SKIPPED=0
ERRORS=0
EOF

    log "DEBUG" "Restore download worker ${worker_id} started (PID $$)"

    while true; do
        # ---- Atomically pop the next part filename from the queue ----
        local partname=""
        (
            flock -x 200
            local _line
            _line=$(head -1 "${queue_file}" 2>/dev/null || true)
            if [[ -n "${_line}" ]]; then
                sed -i '1d' "${queue_file}"
            fi
            echo "${_line}"
        ) 200>"${lock_file}" > "${RESTORE_JOB_DIR}/workers/restore_dl_worker_${worker_id}.next"

        partname=$(cat "${RESTORE_JOB_DIR}/workers/restore_dl_worker_${worker_id}.next")

        if [[ -z "${partname}" ]]; then
            log "DEBUG" "Restore download worker ${worker_id} — queue empty, exiting"
            break
        fi

        local local_part="${parts_staging_dir}/${partname}"
        local sftp_src="${sftp_parts_dir}/${partname}"
        local status_file="${RESTORE_JOB_DIR}/restore_status/${partname}"

        local expected_size
        expected_size=$(get_manifest_part_size "${partname}")
        local expected_hash
        expected_hash=$(get_manifest_part_hash "${partname}")

        # ---- Resume: skip if already committed in a prior run ----
        # Since staging is preserved on failure (RESTORE_PRESERVE_ON_FAILURE=true),
        # the status file from the previous run survives.  If it says COMMITTED,
        # the part was already appended to the output file and the local part file
        # was deleted by the commit thread — nothing left to do.
        if [[ -f "${status_file}" ]]; then
            local prior_status
            prior_status=$(cat "${status_file}" 2>/dev/null || true)
            if [[ "${prior_status}" == "COMMITTED" ]]; then
                log "INFO" "[RDL${worker_id}] Part already committed in prior run — skipping: ${partname}"
                _inc_result "${result_file}" "SKIPPED"
                continue
            fi
        fi

        # ---- Resume: check if part already downloaded and verified ----
        if [[ -f "${local_part}" ]]; then
            local existing_size
            existing_size=$(stat -c '%s' "${local_part}" 2>/dev/null || echo 0)
            if [[ "${existing_size}" == "${expected_size}" ]]; then
                log "DEBUG" "[RDL${worker_id}] Part exists locally with correct size — verifying hash: ${partname}"
                local actual_hash
                actual_hash=$(sha256sum "${local_part}" 2>/dev/null | awk '{print $1}')
                if [[ "${actual_hash}" == "${expected_hash}" ]]; then
                    log "INFO" "[RDL${worker_id}] Part already verified locally — skipping download: ${partname}"
                    echo "VERIFIED" > "${status_file}"
                    _inc_result "${result_file}" "SKIPPED"
                    continue
                fi
                # Hash mismatch on existing local file — re-download
                log "WARN" "[RDL${worker_id}] Local part hash mismatch — re-downloading: ${partname}"
                rm -f "${local_part}"
                # Clear any stale VERIFIED status so the commit thread does not
                # try to append this part while it is being re-downloaded.
                rm -f "${status_file}"
            else
                # Wrong size — truncated/corrupt download, re-download
                log "WARN" "[RDL${worker_id}] Local part size mismatch (expected=${expected_size}, got=${existing_size}) — re-downloading: ${partname}"
                rm -f "${local_part}"
                # Clear any stale VERIFIED status so the commit thread does not
                # try to append this part while it is being re-downloaded.
                rm -f "${status_file}"
            fi
        fi

        # ---- Download the part from SFTP (with retry) ----
        # Object-storage SFTP backends can transiently return empty listings
        # or reject connections under load.  Retry up to SPLIT_RESTORE_RETRIES
        # times with SPLIT_RESTORE_RETRY_SLEEP seconds between attempts.
        log "INFO" "[RDL${worker_id}] Downloading part: ${sftp_src} → ${local_part}"

        local dl_attempt=1
        local dl_max="${SPLIT_RESTORE_RETRIES:-4}"
        local dl_sleep="${SPLIT_RESTORE_RETRY_SLEEP:-10}"
        local dl_ok=false

        while (( dl_attempt <= dl_max )); do
            log "DEBUG" "[RDL${worker_id}] Download attempt ${dl_attempt}/${dl_max}: ${partname}"
            rm -f "${local_part}"
            if ! SSHPASS="${SFTP_PASS}" sshpass -e sftp \
                    -P "${SFTP_PORT}" \
                    -o StrictHostKeyChecking=no \
                    -o BatchMode=yes \
                    -o ConnectTimeout=5 \
                    -o ServerAliveInterval=15 \
                    -o ServerAliveCountMax=3 \
                    -o LogLevel=ERROR \
                    -b <(printf 'get %s %s\n' "${sftp_src}" "${local_part}") \
                    "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
                rm -f "${local_part}"
                if (( dl_attempt < dl_max )); then
                    log "WARN" "[RDL${worker_id}] Download attempt ${dl_attempt}/${dl_max} failed (sftp error) — retrying in ${dl_sleep}s: ${partname}"
                    sleep "${dl_sleep}"
                fi
                (( dl_attempt++ )) || true
                continue
            fi

            # sftp exited 0 — verify the downloaded size matches the manifest.
            # A truncated remote file can cause sftp to exit 0 with a short file.
            local actual_size
            actual_size=$(stat -c '%s' "${local_part}" 2>/dev/null || echo 0)
            if [[ "${actual_size}" != "${expected_size}" ]]; then
                rm -f "${local_part}"
                if (( dl_attempt < dl_max )); then
                    log "WARN" "[RDL${worker_id}] Download attempt ${dl_attempt}/${dl_max} yielded wrong size (expected=${expected_size}, got=${actual_size}) — retrying in ${dl_sleep}s: ${partname}"
                    sleep "${dl_sleep}"
                else
                    log "ERROR" "[RDL${worker_id}] Download attempt ${dl_attempt}/${dl_max} yielded wrong size (expected=${expected_size}, got=${actual_size}) — no more retries: ${partname}"
                fi
                (( dl_attempt++ )) || true
                continue
            fi

            dl_ok=true
            break
        done

        if [[ "${dl_ok}" != true ]]; then
            log "ERROR" "[RDL${worker_id}] SFTP download failed after ${dl_max} attempts: ${partname}"
            rm -f "${local_part}"
            echo "FAILED" > "${status_file}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        # ---- Verify sha256 against manifest hash ----
        local actual_hash
        actual_hash=$(sha256sum "${local_part}" 2>/dev/null | awk '{print $1}')

        if [[ "${actual_hash}" != "${expected_hash}" ]]; then
            log "ERROR" "[RDL${worker_id}] Part hash mismatch (manifest=${expected_hash}, got=${actual_hash}): ${partname}"
            # Delete corrupt local file so a re-run re-downloads cleanly
            rm -f "${local_part}"
            echo "FAILED" > "${status_file}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        # ---- Part fully verified — mark VERIFIED for commit thread ----
        log "INFO" "[RDL${worker_id}] Part verified OK (sha256=${actual_hash}): ${partname}"
        echo "VERIFIED" > "${status_file}"
        _inc_result "${result_file}" "VERIFIED"
    done

    log "DEBUG" "Restore download worker ${worker_id} finished"
}

# merge_restore_download_results
# Sums all per-worker restore download result files into local variables
# RESTORE_CNT_VERIFIED, RESTORE_CNT_FAILED, RESTORE_CNT_SKIPPED, RESTORE_CNT_ERRORS.
merge_restore_download_results() {
    RESTORE_CNT_VERIFIED=0
    RESTORE_CNT_FAILED=0
    RESTORE_CNT_SKIPPED=0
    RESTORE_CNT_ERRORS=0

    for result_file in "${RESTORE_JOB_DIR}/workers"/restore_dl_worker_*.result; do
        [[ -f "${result_file}" ]] || continue
        while IFS='=' read -r key value; do
            [[ -z "${key}" ]] && continue
            case "${key}" in
                VERIFIED) RESTORE_CNT_VERIFIED=$(( RESTORE_CNT_VERIFIED + value )) ;;
                FAILED)   RESTORE_CNT_FAILED=$(( RESTORE_CNT_FAILED + value )) ;;
                SKIPPED)  RESTORE_CNT_SKIPPED=$(( RESTORE_CNT_SKIPPED + value )) ;;
                ERRORS)   RESTORE_CNT_ERRORS=$(( RESTORE_CNT_ERRORS + value )) ;;
            esac
        done < "${result_file}"
    done
}