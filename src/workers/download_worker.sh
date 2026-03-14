#!/usr/bin/env bash
# ============================================================
# src/workers/download_worker.sh — Stage 1: FTP Download Worker
#
# Defines download_worker(), which is spawned in parallel by
# run_pipeline() — one process per FTP_MAX_WORKERS setting.
#
# Each worker instance runs an independent loop that:
#
#   1. Atomically pops one entry from work_queue.txt
#      (SIZE EPOCH FILEPATH — space-separated).
#   2. Skips dot-files and exclusion-list matches.
#   3. Determines whether the file needs to be transferred:
#        a. reupload.log check  — if flagged from a previous
#           checksum failure, force re-download regardless of
#           SFTP state.
#        b. VERIFY_MODE check   — if -V is active, always
#           re-download so the upload worker has a fresh local
#           copy to checksum against the SFTP copy.
#        c. Normal SFTP check   — sftp_get_size(); skip if sizes
#           match, overwrite if they differ and OVERWRITE_ON_SIZE_DIFF
#           is true, or enqueue as SKIP for retention-only if not.
#   4. Calls wait_for_disk_space() before reserving in-flight bytes.
#   5. Downloads via run_lftp "get SRC -o DST".
#      FTP directory structure is mirrored under the per-worker
#      staging subdirectory so files with identical names in
#      different FTP subdirectories never collide locally.
#   6. Verifies the downloaded file size matches the FTP listing.
#   7. Appends a real entry to ready_queue.txt for upload workers.
#
# Per-worker result files (TEMP_DIR/workers/dl_worker_N.result)
# are written in KEY=VALUE format and summed by merge_worker_results()
# at the end of the run.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh, src/core/constants.sh,
#   src/transfer/exclusions.sh (uses is_excluded()),
#   src/transfer/ftp.sh (uses run_lftp()),
#   src/transfer/sftp.sh (uses sftp_get_size()),
#   src/transfer/reupload.sh (uses reupload_is_flagged()),
#   src/workers/counters.sh (uses _counter_add, _enqueue_ready, _inc_result),
#   src/workers/disk_guard.sh (uses wait_for_disk_space()).
# ============================================================

download_worker() {
    local worker_id="$1"
    local result_file="${TEMP_DIR}/workers/dl_worker_${worker_id}.result"
    local queue_file="${TEMP_DIR}/work_queue.txt"
    local lock_file="${TEMP_DIR}/work_queue.lock"

    # Initialise per-worker result counters
    cat > "${result_file}" <<EOF
SCANNED=0
TRANSFERRED=0
OVERWRITTEN=0
SKIPPED=0
DELETED=0
ERRORS=0
EOF

    _counter_add "${TEMP_DIR}/active_downloaders.cnt" 1
    log "DEBUG" "Download worker ${worker_id} started (PID $$)"

    local staging_dir="${TEMP_DIR}/staging/dl_worker_${worker_id}"
    mkdir -p "${staging_dir}"

    while true; do
        # Atomically pop the next line from the work queue.
        # The pop is done inside a flock subshell; the result is written to a
        # per-worker file rather than captured via $() to avoid a race where
        # two workers read the same line before either has removed it.
        local line=""
        (
            flock -x 200
            local _line
            _line=$(head -1 "${queue_file}" 2>/dev/null || true)
            if [[ -n "${_line}" ]]; then
                sed -i '1d' "${queue_file}"
            fi
            echo "${_line}"
        ) 200>"${lock_file}" > "${TEMP_DIR}/workers/dl_worker_${worker_id}.next_line"

        line=$(cat "${TEMP_DIR}/workers/dl_worker_${worker_id}.next_line")

        if [[ -z "${line}" ]]; then
            log "DEBUG" "Download worker ${worker_id} — queue empty, exiting"
            break
        fi

        # Parse line: SIZE MTIME_EPOCH FILEPATH  (space-separated, path may contain spaces)
        local ftp_size ftp_mtime ftp_path
        ftp_size=$(echo  "${line}" | awk '{print $1}')
        ftp_mtime=$(echo "${line}" | awk '{print $2}')
        ftp_path=$(echo  "${line}" | awk '{for(i=3;i<=NF;i++) printf "%s%s",$i,(i==NF?"\n":" ")}')

        if [[ -z "${ftp_size}" ]] || [[ -z "${ftp_mtime}" ]] || [[ -z "${ftp_path}" ]]; then
            log "WARN" "Download worker ${worker_id} — malformed queue entry, skipping: '${line}'"
            continue
        fi

        _inc_result "${result_file}" "SCANNED"

        local basename_file
        basename_file=$(basename "${ftp_path}")

        # ---- 1. Skip dot files ----
        if [[ "${basename_file}" == .* ]]; then
            log "DEBUG" "[DL${worker_id}] Skipping dot file: ${ftp_path}"
            _inc_result "${result_file}" "SKIPPED"
            continue
        fi

        # ---- 2. Skip excluded files ----
        if is_excluded "${basename_file}"; then
            log "DEBUG" "[DL${worker_id}] Skipping excluded file: ${ftp_path}"
            _inc_result "${result_file}" "SKIPPED"
            continue
        fi

        # ---- 3. Build SFTP destination path ----
        local sftp_dest_path="${SFTP_REMOTE_DIR}${ftp_path}"

        # ---- 4. Check current SFTP state ----
        # In VERIFY_MODE every file must be re-downloaded from FTP so the upload
        # worker can re-confirm the SFTP copy via checksum — skip this block.
        local transfer_needed=false transfer_reason="" is_overwrite=false

        # Check reupload.log first — a flagged file is always force-re-downloaded
        # and re-uploaded regardless of its current state on SFTP.  This catches
        # the case where a previous checksum failure was recorded and the SFTP
        # delete may or may not have succeeded.
        if reupload_is_flagged "${ftp_path}"; then
            transfer_needed=true
            is_overwrite=true
            transfer_reason="flagged in reupload.log (previous checksum failure — forcing re-upload)"
            log "WARN" "[DL${worker_id}] Re-upload flagged for: ${ftp_path}"
        elif [[ "${VERIFY_MODE}" == "true" ]]; then
            # Force transfer regardless of what is already on SFTP
            transfer_needed=true
            local sftp_size_vm
            sftp_size_vm=$(sftp_get_size "${sftp_dest_path}")
            if [[ "${sftp_size_vm}" == "NOT_FOUND" ]]; then
                transfer_reason="verify-mode: new file (not on SFTP)"
            else
                is_overwrite=true
                transfer_reason="verify-mode: re-downloading for checksum verification (SFTP size=${sftp_size_vm})"
            fi
        else
            local sftp_size
            sftp_size=$(sftp_get_size "${sftp_dest_path}")

            if [[ "${sftp_size}" == "NOT_FOUND" ]]; then
                transfer_needed=true
                transfer_reason="new file (not on SFTP)"
            elif [[ "${sftp_size}" != "${ftp_size}" ]]; then
                if [[ "${OVERWRITE_ON_SIZE_DIFF}" == "true" ]]; then
                    transfer_needed=true
                    is_overwrite=true
                    transfer_reason="size mismatch (FTP=${ftp_size}, SFTP=${sftp_size})"
                else
                    log "WARN" "[DL${worker_id}] Size mismatch, overwrite disabled — skipping: ${ftp_path}"
                    _inc_result "${result_file}" "SKIPPED"
                    # Still needs retention check — enqueue as SKIP
                    _enqueue_ready "SKIP" "SKIP" "${ftp_path}" "${ftp_size}" "${ftp_mtime}"
                    continue
                fi
            else
                log "DEBUG" "[DL${worker_id}] Already synced — queuing for retention check only: ${ftp_path}"
                _inc_result "${result_file}" "SKIPPED"
                _enqueue_ready "SKIP" "SKIP" "${ftp_path}" "${ftp_size}" "${ftp_mtime}"
                continue
            fi
        fi

        # ---- 5. Dry-run: log intent and enqueue as DRYRUN (no actual download) ----
        if [[ "${DRY_RUN}" == "true" ]]; then
            log "INFO" "[DRY-RUN] Would download: ${ftp_path} → staging (${ftp_size} bytes)"
            _enqueue_ready "DRYRUN" "${sftp_dest_path}" "${ftp_path}" "${ftp_size}" "${ftp_mtime}"
            if [[ "${is_overwrite}" == true ]]; then
                _inc_result "${result_file}" "OVERWRITTEN"
            else
                _inc_result "${result_file}" "TRANSFERRED"
            fi
            continue
        fi

        # ---- 6. Wait for sufficient disk space ----
        if ! wait_for_disk_space "${worker_id}" "${ftp_size}"; then
            log "WARN" "[DL${worker_id}] Skipping — insufficient disk space: ${ftp_path}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        # ---- 7. Reserve in-flight bytes (committed to download) ----
        _counter_add "${TEMP_DIR}/in_flight_bytes.cnt" "${ftp_size}"

        # ---- 8. Download from FTP to local staging ----
        # Preserve the FTP directory structure under the worker staging dir so that
        # identically-named files in different FTP subdirectories (e.g. /file.bz2 and
        # /slim/file.bz2) never collide at the same local path.
        local ftp_dir local_subdir local_file
        ftp_dir=$(dirname "${ftp_path}")
        # Avoid double-slash for root files: dirname("/file") = "/" so subdir = staging_dir
        if [[ "${ftp_dir}" == "/" ]]; then
            local_subdir="${staging_dir}"
        else
            local_subdir="${staging_dir}${ftp_dir}"
        fi
        mkdir -p "${local_subdir}"
        local_file="${local_subdir}/${basename_file}"
        log "INFO" "[DL${worker_id}] Downloading (${transfer_reason}): ${ftp_path} → ${local_file}"

        if ! run_lftp "get ${ftp_path} -o ${local_file}" &>/dev/null; then
            log "ERROR" "[DL${worker_id}] FTP download failed: ${ftp_path}"
            _counter_add "${TEMP_DIR}/in_flight_bytes.cnt" "$(( -ftp_size ))"
            rm -f "${local_file}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        # ---- 9. Release in-flight reservation (file is now on local disk) ----
        _counter_add "${TEMP_DIR}/in_flight_bytes.cnt" "$(( -ftp_size ))"

        # ---- 10. Verify downloaded file size ----
        if [[ ! -f "${local_file}" ]]; then
            log "ERROR" "[DL${worker_id}] Downloaded file missing at staging: ${local_file}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        local local_size
        local_size=$(stat -c '%s' "${local_file}")
        if [[ "${local_size}" != "${ftp_size}" ]]; then
            log "ERROR" "[DL${worker_id}] Size mismatch (expected=${ftp_size}, got=${local_size}): ${ftp_path}"
            rm -f "${local_file}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        log "DEBUG" "[DL${worker_id}] Download verified (${ftp_size} bytes): ${ftp_path}"

        # ---- 11. Count and enqueue for SFTP upload ----
        if [[ "${is_overwrite}" == true ]]; then
            _inc_result "${result_file}" "OVERWRITTEN"
        else
            _inc_result "${result_file}" "TRANSFERRED"
        fi
        _enqueue_ready "${local_file}" "${sftp_dest_path}" "${ftp_path}" "${ftp_size}" "${ftp_mtime}"

    done

    _counter_add "${TEMP_DIR}/active_downloaders.cnt" -1
    log "DEBUG" "Download worker ${worker_id} finished"
}