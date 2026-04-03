#!/usr/bin/env bash
# ============================================================
# src/split/split_worker.sh — Parallel Part Upload Worker
#
# Defines split_upload_worker(), which is spawned in parallel by
# split_transfer.sh and split_upload.sh — one process per
# SPLIT_PART_WORKERS setting.
#
# In split_transfer.sh the queue is fully populated before workers
# start (static list).  In split_upload.sh the queue is populated
# concurrently by parallel hash workers — upload workers start
# immediately and consume parts as hashing completes.  The sentinel
# value __DONE__ appended to the queue file by the hash collector
# signals that no more parts will be added.
#
# Unlike upload_worker.sh (which consumes a dynamic queue fed by
# concurrent downloaders), this worker operates on part files that
# land in staging during the hash phase.  The work queue is a shared
# flat file divided across N workers via atomic pop + flock.
#
# Each worker instance:
#   1. Atomically pops the next part filename from the shared
#      part queue file (TEMP_DIR/split_part_queue.txt).
#   2. Constructs the full local path and SFTP destination path.
#   3. Uploads via sshpass sftp put (with timeout + retry).
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
# Upload retry:
#   sftp put is retried up to SPLIT_UPLOAD_RETRIES times (default 3)
#   with SPLIT_UPLOAD_RETRY_SLEEP seconds between attempts.
#   Each attempt is wrapped with `timeout SPLIT_SFTP_TIMEOUT` to
#   prevent indefinite hangs on object-storage backends that do not
#   honour SSH keepalives.
#
# Shared state files (all under SPLIT_JOB_DIR):
#   split_part_queue.txt   — one part filename per line; atomically popped.
#                            When used with split_upload.sh parallel hashing,
#                            the special sentinel line __DONE__ is appended
#                            after all hash workers finish to signal no more
#                            parts will be added.
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

# _split_sftp_run [timeout_secs] sftp_args...
#
# Runs sftp via sshpass, optionally wrapping with `timeout`.
# If timeout_secs is 0 or empty, no timeout is applied.
# Returns the sftp exit code.
_split_sftp_run() {
    local _timeout="${1}"; shift
    if [[ -n "${_timeout}" ]] && (( _timeout > 0 )); then
        SSHPASS="${SFTP_PASS}" sshpass -e \
            timeout "${_timeout}" \
            sftp "$@"
    else
        SSHPASS="${SFTP_PASS}" sshpass -e sftp "$@"
    fi
}

# split_upload_worker WORKER_ID PARTS_STAGING_DIR SFTP_PARTS_DIR
split_upload_worker() {
    local worker_id="$1"
    local parts_staging_dir="$2"
    local sftp_parts_dir="$3"
    local result_file="${SPLIT_JOB_DIR}/workers/split_ul_worker_${worker_id}.result"
    local queue_file="${SPLIT_JOB_DIR}/split_part_queue.txt"
    local lock_file="${SPLIT_JOB_DIR}/split_part_queue.lock"

    # Resolve config vars with defaults (workers run as subshells —
    # apply_split_defaults may not have been called in this process)
    local upload_retries="${SPLIT_UPLOAD_RETRIES:-3}"
    local upload_retry_sleep="${SPLIT_UPLOAD_RETRY_SLEEP:-15}"
    local sftp_timeout="${SPLIT_SFTP_TIMEOUT:-3600}"

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
        ) 200>"${lock_file}" > "${SPLIT_JOB_DIR}/workers/split_ul_worker_${worker_id}.next"

        partname=$(cat "${SPLIT_JOB_DIR}/workers/split_ul_worker_${worker_id}.next")

        if [[ -z "${partname}" ]]; then
            # Queue is currently empty — hash workers are still running.
            # Wait briefly and retry.  Each upload worker will eventually
            # pop its own __DONE__ sentinel (one is written per worker by
            # split_collect_part_metadata_parallel after all hashing finishes).
            sleep 0.25
            continue
        fi

        # Sentinel line: treat as end-of-queue signal
        if [[ "${partname}" == "__DONE__" ]]; then
            log "DEBUG" "Split upload worker ${worker_id} — popped sentinel, exiting"
            break
        fi

        local local_part="${parts_staging_dir}/${partname}"
        local sftp_dest="${sftp_parts_dir}/${partname}"
        local status_file="${SPLIT_JOB_DIR}/split_status/${partname}"

        # ---- Resolve expected size + hash for this part ----
        # In parallel-hash mode (split_upload.sh full/partial flow) the manifest
        # is not yet written when upload workers start.  Each hash worker writes a
        # sidecar file: ${SPLIT_JOB_DIR}/part_hashes/<partname>.sha256
        # containing "<hex>  <size>" so upload workers can validate immediately.
        # In resume mode (and split_transfer.sh) the sidecar does not exist but
        # the manifest is already loaded into memory — fall back to manifest lookups.
        local _sidecar="${SPLIT_JOB_DIR}/part_hashes/${partname}.sha256"
        local expected_size expected_hash
        if [[ -f "${_sidecar}" ]]; then
            expected_hash=$(awk '{print $1}' "${_sidecar}")
            expected_size=$(awk '{print $2}' "${_sidecar}")
        else
            expected_size=$(get_manifest_part_size "${partname}")
            expected_hash=$(get_manifest_part_hash "${partname}")
        fi
        # Final fallback: stat the local file (always present at upload time)
        if [[ -z "${expected_size}" ]] && [[ -f "${local_part}" ]]; then
            expected_size=$(stat -c '%s' "${local_part}" 2>/dev/null || echo "")
        fi

        # ---- Check if already uploaded on a previous run (resume support) ----
        local existing_size
        existing_size=$(sftp_get_size "${sftp_dest}")

        if [[ -n "${expected_size}" ]] && [[ "${existing_size}" == "${expected_size}" ]]; then
            # Part already exists on SFTP with correct size — verify hash then skip upload
            log "DEBUG" "[SUL${worker_id}] Part already on SFTP with correct size — verifying hash: ${partname}"
            local verify_file="${local_part}.verify"
            local part_ok=false

            if _split_sftp_run "${sftp_timeout}" \
                    -P "${SFTP_PORT}" \
                    -o StrictHostKeyChecking=no \
                    -o BatchMode=no \
                    -o ConnectTimeout=5 \
                    -o ServerAliveInterval=15 \
                    -o ServerAliveCountMax=3 \
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

        # ---- Upload the part (with retry) ----
        local upload_attempt=1
        local upload_ok=false

        while (( upload_attempt <= upload_retries )); do
            log "INFO" "[SUL${worker_id}] Uploading part (attempt ${upload_attempt}/${upload_retries}): ${partname} → ${sftp_dest}"

            if _split_sftp_run "${sftp_timeout}" \
                    -P "${SFTP_PORT}" \
                    -o StrictHostKeyChecking=no \
                    -o BatchMode=no \
                    -o ConnectTimeout=5 \
                    -o ServerAliveInterval=15 \
                    -o ServerAliveCountMax=3 \
                    -o LogLevel=ERROR \
                    -b <(printf 'put %s %s\n' "${local_part}" "${sftp_dest}") \
                    "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
                upload_ok=true
                break
            fi

            log "WARN" "[SUL${worker_id}] SFTP upload failed (attempt ${upload_attempt}/${upload_retries}): ${partname}"
            if (( upload_attempt < upload_retries )); then
                log "INFO" "[SUL${worker_id}] Retrying upload in ${upload_retry_sleep}s: ${partname}"
                sleep "${upload_retry_sleep}"
            fi
            (( upload_attempt++ )) || true
        done

        if [[ "${upload_ok}" != true ]]; then
            log "ERROR" "[SUL${worker_id}] SFTP upload failed after ${upload_retries} attempt(s): ${partname}"
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
        # expected_hash was already resolved from sidecar or manifest at the
        # top of this loop iteration — no re-lookup needed here.
        local verify_file="${local_part}.verify"
        local verify_slots="${SPLIT_VERIFY_SLOTS:-3}"
        local slot_acquired=false
        local slot_fd slot_num

        # Try each slot in round-robin until we acquire one
        for slot_num in $(seq 1 "${verify_slots}"); do
            local slot_lock="${SPLIT_JOB_DIR}/split_verify_slot_${slot_num}.lock"
            # Non-blocking trylock — move to next slot if busy.
            # Open fd first, then attempt lock; close fd if lock fails.
            exec {slot_fd}>"${slot_lock}"
            if flock -n "${slot_fd}"; then
                slot_acquired=true
                break
            fi
            exec {slot_fd}>&-
        done

        # If all slots busy, fall back to blocking wait on slot 1
        if [[ "${slot_acquired}" != true ]]; then
            local slot_lock="${SPLIT_JOB_DIR}/split_verify_slot_1.lock"
            exec {slot_fd}>"${slot_lock}"
            flock -x "${slot_fd}"
        fi

        log "DEBUG" "[SUL${worker_id}] Verify slot acquired — downloading for hash check: ${partname}"

        local actual_hash=""
        local verify_rc=0
        local verify_attempt=1
        local verify_max="${SPLIT_VERIFY_RETRIES:-4}"
        local verify_sleep="${SPLIT_VERIFY_RETRY_SLEEP:-10}"

        # Retry loop: transient SFTP connection failures (e.g. too many concurrent
        # connections) should not permanently fail a part that was successfully
        # uploaded.  The verify slot is held across retries to keep throttling in
        # effect — releasing between attempts would allow immediate re-flooding.
        while (( verify_attempt <= verify_max )); do
            actual_hash=""
            if _split_sftp_run "${sftp_timeout}" \
                    -P "${SFTP_PORT}" \
                    -o StrictHostKeyChecking=no \
                    -o BatchMode=no \
                    -o ConnectTimeout=5 \
                    -o ServerAliveInterval=15 \
                    -o ServerAliveCountMax=3 \
                    -o LogLevel=ERROR \
                    -b <(printf 'get %s %s\n' "${sftp_dest}" "${verify_file}") \
                    "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
                actual_hash=$(sha256sum "${verify_file}" 2>/dev/null | awk '{print $1}')
                rm -f "${verify_file}"
                break
            fi
            rm -f "${verify_file}"
            if (( verify_attempt < verify_max )); then
                log "WARN" "[SUL${worker_id}] Verify re-download attempt ${verify_attempt}/${verify_max} failed — retrying in ${verify_sleep}s: ${partname}"
                sleep "${verify_sleep}"
            fi
            (( verify_attempt++ )) || true
        done

        if [[ -z "${actual_hash}" ]]; then
            verify_rc=1
        fi

        # Release verify slot
        flock -u "${slot_fd}"
        exec {slot_fd}>&-

        if (( verify_rc != 0 )); then
            log "ERROR" "[SUL${worker_id}] Failed to re-download part for hash verification after ${verify_max} attempts: ${partname}"
            echo "FAILED" > "${status_file}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        if [[ "${actual_hash}" != "${expected_hash}" ]]; then
            log "ERROR" "[SUL${worker_id}] Part hash mismatch (manifest=${expected_hash}, sftp=${actual_hash}): ${partname}"
            # Delete the corrupt SFTP part so a re-run re-uploads it cleanly
            _split_sftp_run "${sftp_timeout}" \
                -P "${SFTP_PORT}" \
                -o StrictHostKeyChecking=no \
                -o BatchMode=no \
                -o ConnectTimeout=5 \
                -o ServerAliveInterval=15 \
                -o ServerAliveCountMax=3 \
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

    for result_file in "${SPLIT_JOB_DIR}/workers"/split_ul_worker_*.result; do
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