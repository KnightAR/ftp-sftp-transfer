#!/usr/bin/env bash
# ============================================================
# src/split/split_worker.sh — Parallel Part Upload Worker
#
# Defines split_upload_worker(), which is spawned in parallel by
# split_transfer.sh — one process per SPLIT_PART_WORKERS setting.
#
# Unlike upload_worker.sh (which consumes a dynamic queue fed by
# concurrent downloaders), this worker operates on a static ordered
# list of part files that are all present in staging before any
# worker is spawned.  The work queue is simply the parts directory
# listing divided across N workers via atomic pop.
#
# Each worker instance:
#   1. Atomically pops the next part filename from the shared
#      part queue file (TEMP_DIR/split_part_queue.txt).
#   2. Constructs the full local path and SFTP destination path.
#   3. Uploads via sshpass sftp put.
#   4. Verifies post-upload size via sftp_get_size_retry() —
#      handles object-storage commit lag.
#   5. Re-downloads the part to a .verify temp file and compares
#      sha256 against the manifest hash for that part.
#      This is tighter than sftp_download_verify() in sftp.sh
#      because we compare against the pre-computed manifest hash
#      rather than the local staged file (which is deleted after
#      the sha256 was recorded at split time).
#      Re-downloads are throttled to SPLIT_VERIFY_SLOTS concurrent
#      workers via a flock token-slot semaphore.
#   6. On verify OK  — deletes the local part file immediately to
#      free staging space, marks part as UPLOADED in the shared
#      status directory.
#   7. On verify FAIL — logs error, marks part as FAILED, does NOT
#      delete local part (allows retry on re-run if part still exists).
#   8. Writes per-worker result file for summary merging.
#
# Shared state files (all under TEMP_DIR):
#   split_part_queue.txt   — one part filename per line; atomically popped
#   split_part_queue.lock  — flock target for queue pop
#   split_status/          — one file per part: UPLOADED or FAILED
#
# Dependency order:
#   Must be sourced after src/core/logging.sh, src/core/constants.sh,
#   src/transfer/sftp.sh (uses sftp_get_size_retry),
#   src/workers/counters.sh (uses _inc_result),
#   src/split/split_manifest.sh (uses get_manifest_part_hash,
#   get_manifest_part_size).
# ============================================================

# split_upload_worker WORKER_ID PARTS_STAGING_DIR SFTP_PARTS_DIR
split_upload_worker() {
    local worker_id="$1"
    local parts_staging_dir="$2"
    local sftp_parts_dir="$3"
    local result_file="${TEMP_DIR}/workers/split_ul_worker_${worker_id}.result"
    local queue_file="${TEMP_DIR}/split_part_queue.txt"
    local lock_file="${TEMP_DIR}/split_part_queue.lock"

    cat > "${result_file}" <<EOF
UPLOADED=0
FAILED=0
SKIPPED=0
ERRORS=0
EOF

    log "DEBUG" "Split upload worker ${worker_id} started (PID $$)"

    while true; do
        # Atomically pop the next part filename from the queue
        local partname=""
        (
            flock -x 200
            local _line
            _line=$(head -1 "${queue_file}" 2>/dev/null || true)
            if [[ -n "${_line}" ]]; then
                sed -i '1d' "${queue_file}"
            fi
            echo "${_line}"
        ) 200>"${lock_file}" > "${TEMP_DIR}/workers/split_ul_worker_${worker_id}.next"

        partname=$(cat "${TEMP_DIR}/workers/split_ul_worker_${worker_id}.next")

        if [[ -z "${partname}" ]]; then
            log "DEBUG" "Split upload worker ${worker_id} — queue empty, exiting"
            break
        fi

        local local_part="${parts_staging_dir}/${partname}"
        local sftp_dest="${sftp_parts_dir}/${partname}"
        local status_file="${TEMP_DIR}/split_status/${partname}"

        # ---- Check if already uploaded on a previous run (resume support) ----
        local existing_size
        existing_size=$(sftp_get_size "${sftp_dest}")
        local expected_size
        expected_size=$(get_manifest_part_size "${partname}")

        if [[ "${existing_size}" == "${expected_size}" ]]; then
            # Part already exists on SFTP with correct size — verify hash then skip upload
            log "DEBUG" "[SUL${worker_id}] Part already on SFTP with correct size — verifying hash: ${partname}"
            local expected_hash
            expected_hash=$(get_manifest_part_hash "${partname}")
            local verify_file="${local_part}.verify"
            local part_ok=false

            if SSHPASS="${SFTP_PASS}" sshpass -e sftp \
                    -P "${SFTP_PORT}" \
                    -o StrictHostKeyChecking=no \
                    -o BatchMode=no \
                    -o ConnectTimeout=30 \
                    -o LogLevel=ERROR \
                    -b <(printf 'get %s %s\n' "${sftp_dest}" "${verify_file}") \
                    "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
                local actual_hash
                actual_hash=$(sha256sum "${verify_file}" 2>/dev/null | awk '{print $1}')
                rm -f "${verify_file}"
                if [[ "${actual_hash}" == "${expected_hash}" ]]; then
                    log "INFO" "[SUL${worker_id}] Part already verified on SFTP — skipping upload: ${partname}"
                    echo "UPLOADED" > "${status_file}"
                    rm -f "${local_part}"
                    _inc_result "${result_file}" "SKIPPED"
                    part_ok=true
                fi
            else
                rm -f "${verify_file}"
            fi

            if [[ "${part_ok}" == true ]]; then
                continue
            fi
            # Hash mismatch on existing SFTP copy — fall through to re-upload
            log "WARN" "[SUL${worker_id}] Existing SFTP part hash mismatch — re-uploading: ${partname}"
        fi

        # ---- Upload the part ----
        log "INFO" "[SUL${worker_id}] Uploading part: ${partname} → ${sftp_dest}"

        if ! SSHPASS="${SFTP_PASS}" sshpass -e sftp \
                -P "${SFTP_PORT}" \
                -o StrictHostKeyChecking=no \
                -o BatchMode=no \
                -o ConnectTimeout=60 \
                -o LogLevel=ERROR \
                -b <(printf 'put %s %s\n' "${local_part}" "${sftp_dest}") \
                "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
            log "ERROR" "[SUL${worker_id}] SFTP upload failed: ${partname}"
            echo "FAILED" > "${status_file}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        # ---- Verify post-upload size (with retry for object-storage lag) ----
        local post_size
        post_size=$(sftp_get_size_retry "${sftp_dest}" "${expected_size}")
        if [[ "${post_size}" != "${expected_size}" ]]; then
            log "ERROR" "[SUL${worker_id}] Part size mismatch after upload (expected=${expected_size}, got=${post_size}): ${partname}"
            echo "FAILED" > "${status_file}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        # ---- Verify sha256 against manifest hash ----
        # Re-download the uploaded part from SFTP to a .verify temp file and
        # compare its sha256 against the manifest hash.  This confirms the
        # remote copy is byte-perfect — not just that the upload source was clean.
        #
        # Concurrency throttle: use a flock token-slot semaphore so at most
        # SPLIT_VERIFY_SLOTS (default 3) workers re-download simultaneously.
        # This prevents connection overload on object-storage SFTP backends
        # when all 10 upload workers try to pull 1 GiB each at the same time.
        # Upload and queue-pop remain fully parallel — only the verify step is
        # throttled.
        local expected_hash
        expected_hash=$(get_manifest_part_hash "${partname}")
        local verify_file="${local_part}.verify"
        local verify_slots="${SPLIT_VERIFY_SLOTS:-3}"
        local slot_acquired=false
        local slot_fd slot_num

        # Try each slot in round-robin until we acquire one
        # shellcheck disable=SC2034
        for slot_num in $(seq 1 "${verify_slots}"); do
            local slot_lock="${TEMP_DIR}/split_verify_slot_${slot_num}.lock"
            # Non-blocking trylock — move to next slot if busy
            if exec {slot_fd}>"${slot_lock}" && flock -n "${slot_fd}"; then
                slot_acquired=true
                break
            fi
            exec {slot_fd}>&- 2>/dev/null || true
        done

        # If all slots busy, fall back to blocking wait on slot 1
        if [[ "${slot_acquired}" != true ]]; then
            local slot_lock="${TEMP_DIR}/split_verify_slot_1.lock"
            exec {slot_fd}>"${slot_lock}"
            flock -x "${slot_fd}"
        fi

        log "DEBUG" "[SUL${worker_id}] Verify slot acquired — downloading for hash check: ${partname}"

        local actual_hash=""
        local verify_rc=0
        if SSHPASS="${SFTP_PASS}" sshpass -e sftp \
                -P "${SFTP_PORT}" \
                -o StrictHostKeyChecking=no \
                -o BatchMode=no \
                -o ConnectTimeout=60 \
                -o LogLevel=ERROR \
                -b <(printf 'get %s %s\n' "${sftp_dest}" "${verify_file}") \
                "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
            actual_hash=$(sha256sum "${verify_file}" 2>/dev/null | awk '{print $1}')
        else
            verify_rc=1
        fi

        # Release verify slot
        flock -u "${slot_fd}"
        exec {slot_fd}>&-
        rm -f "${verify_file}"

        if (( verify_rc != 0 )); then
            log "ERROR" "[SUL${worker_id}] Failed to re-download part for hash verification: ${partname}"
            echo "FAILED" > "${status_file}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        if [[ "${actual_hash}" != "${expected_hash}" ]]; then
            log "ERROR" "[SUL${worker_id}] Part hash mismatch (manifest=${expected_hash}, sftp=${actual_hash}): ${partname}"
            # Delete the corrupt SFTP part so a re-run re-uploads it cleanly
            SSHPASS="${SFTP_PASS}" sshpass -e sftp \
                -P "${SFTP_PORT}" \
                -o StrictHostKeyChecking=no \
                -o BatchMode=no \
                -o ConnectTimeout=15 \
                -o LogLevel=ERROR \
                -b <(printf 'rm %s\n' "${sftp_dest}") \
                "${SFTP_USER}@${SFTP_HOST}" &>/dev/null || true
            echo "FAILED" > "${status_file}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        # ---- Part fully verified — delete local copy, mark UPLOADED ----
        log "INFO" "[SUL${worker_id}] Part verified OK (sha256=${actual_hash}): ${partname}"
        rm -f "${local_part}"
        echo "UPLOADED" > "${status_file}"
        _inc_result "${result_file}" "UPLOADED"
    done

    log "DEBUG" "Split upload worker ${worker_id} finished"
}

# merge_split_upload_results
# Sums all per-worker split upload result files into local variables
# SPLIT_CNT_UPLOADED, SPLIT_CNT_FAILED, SPLIT_CNT_SKIPPED, SPLIT_CNT_ERRORS.
merge_split_upload_results() {
    SPLIT_CNT_UPLOADED=0
    SPLIT_CNT_FAILED=0
    SPLIT_CNT_SKIPPED=0
    SPLIT_CNT_ERRORS=0

    for result_file in "${TEMP_DIR}/workers"/split_ul_worker_*.result; do
        [[ -f "${result_file}" ]] || continue
        while IFS='=' read -r key value; do
            [[ -z "${key}" ]] && continue
            case "${key}" in
                UPLOADED) SPLIT_CNT_UPLOADED=$(( SPLIT_CNT_UPLOADED + value )) ;;
                FAILED)   SPLIT_CNT_FAILED=$(( SPLIT_CNT_FAILED + value )) ;;
                SKIPPED)  SPLIT_CNT_SKIPPED=$(( SPLIT_CNT_SKIPPED + value )) ;;
                ERRORS)   SPLIT_CNT_ERRORS=$(( SPLIT_CNT_ERRORS + value )) ;;
            esac
        done < "${result_file}"
    done
}