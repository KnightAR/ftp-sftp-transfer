#!/usr/bin/env bash
# ============================================================
# src/split/split_ops.sh — Shared Split Operation Functions
#
# Provides the core split/upload orchestration functions shared
# by split_transfer.sh and split_upload.sh:
#
#   split_run_concurrent_hash_and_split()    — concurrent sha256 + split
#   split_collect_part_metadata()            — per-part size + sha256 (sequential)
#   split_collect_part_metadata_parallel()   — per-part size + sha256 (parallel,
#                                              used by split_upload.sh only)
#   split_upload_manifest()                  — upload manifest to SFTP
#   split_run_upload_workers()               — spawn upload workers + wait (used
#                                              by split_transfer.sh)
#   split_start_upload_workers()             — spawn upload workers in background,
#                                              store PIDs (used by split_upload.sh)
#   split_wait_upload_workers()              — wait for background upload workers
#                                              started by split_start_upload_workers()
#
# Dependency order:
#   Must be sourced after src/core/logging.sh, src/core/constants.sh,
#   src/transfer/sftp.sh, src/split/split_worker.sh,
#   src/workers/counters.sh.
# ============================================================

# ============================================================
# split_run_concurrent_hash_and_split LOCAL_FILE PARTS_DIR PART_PREFIX
#                                      PART_SIZE_BYTES SUFFIX_LEN HASH_OUT_FILE
# Runs sha256sum and gnu split concurrently on LOCAL_FILE.
# Both processes read the file sequentially; sha256 typically
# finishes first or at the same time as split.
# Sets SPLIT_PART_COUNT via split_collect_part_metadata().
# ============================================================
split_run_concurrent_hash_and_split() {
    local local_file="$1"
    local parts_dir="$2"
    local part_prefix="$3"
    local part_size_bytes="$4"
    local suffix_len="$5"
    local hash_out_file="$6"

    log "INFO" "Starting concurrent sha256 + split for: $(basename "${local_file}")"
    log "INFO" "  Part size: ${part_size_bytes} bytes  Suffix length: ${suffix_len}"
    log "INFO" "  Parts dir: ${parts_dir}"

    # Launch sha256sum in background
    sha256sum "${local_file}" > "${hash_out_file}" &
    local sha_pid=$!

    # Launch gnu split in background
    # -d              : numeric suffixes
    # --suffix-length : pad to SUFFIX_LEN digits
    # -b              : part size in bytes
    # Prefix is parts_dir/part_prefix so parts land directly in parts_dir
    split \
        -d \
        --suffix-length="${suffix_len}" \
        -b "${part_size_bytes}" \
        "${local_file}" \
        "${parts_dir}/${part_prefix}" &
    local split_pid=$!

    log "DEBUG" "sha256sum PID=${sha_pid}  split PID=${split_pid}"

    # Wait for both — capture individual exit codes
    local sha_rc=0 split_rc=0
    wait "${sha_pid}"  || sha_rc=$?
    wait "${split_pid}" || split_rc=$?

    if (( sha_rc != 0 )); then
        log "ERROR" "sha256sum failed (rc=${sha_rc}) for: ${local_file}"
        return 1
    fi
    if (( split_rc != 0 )); then
        log "ERROR" "split failed (rc=${split_rc}) for: ${local_file}"
        return 1
    fi

    log "INFO" "Concurrent sha256 + split complete"
}

# ============================================================
# split_collect_part_metadata PARTS_DIR PART_PREFIX PARTS_META_FILE
# For each part file in PARTS_DIR matching PART_PREFIX*, computes
# sha256 and records size.  Writes one line per part to PARTS_META_FILE:
#   <partname>  size=<bytes>  sha256=<hex>
# Also sets SPLIT_PART_COUNT and populates split_part_queue.txt.
# ============================================================
split_collect_part_metadata() {
    local parts_dir="$1"
    local part_prefix="$2"
    local parts_meta_file="$3"
    local queue_file="${SPLIT_JOB_DIR}/split_part_queue.txt"

    : > "${parts_meta_file}"
    : > "${queue_file}"

    SPLIT_PART_COUNT=0

    log "DEBUG" "Scanning for parts in: ${parts_dir} matching: ${part_prefix}*"

    # Parts are named <prefix>NNNNN — sort numerically by suffix.
    # (( n++ )) evaluates to 0 when n=0, which is falsy under set -e —
    # use || true to prevent set -e from aborting on the first part.
    local partfile partname part_size part_hash
    while IFS= read -r partfile; do
        partname=$(basename "${partfile}")
        part_size=$(stat -c '%s' "${partfile}" 2>/dev/null || echo 0)
        part_hash=$(sha256sum "${partfile}" 2>/dev/null | awk '{print $1}')
        printf '%s  size=%s  sha256=%s\n' \
            "${partname}" "${part_size}" "${part_hash}" >> "${parts_meta_file}"
        echo "${partname}" >> "${queue_file}"
        (( SPLIT_PART_COUNT++ )) || true
        log "DEBUG" "Part: ${partname}  size=${part_size}  sha256=${part_hash}"
    done < <(find "${parts_dir}" -maxdepth 1 -name "${part_prefix}*" | sort)

    if (( SPLIT_PART_COUNT == 0 )); then
        log "ERROR" "No parts found in ${parts_dir} matching '${part_prefix}*'"
        return 1
    fi

    log "INFO" "Collected metadata for ${SPLIT_PART_COUNT} parts"
}

# ============================================================
# split_collect_part_metadata_parallel PARTS_DIR PART_PREFIX PARTS_META_FILE
#                                       HASH_WORKERS
#
# Parallel version of split_collect_part_metadata() for use by
# split_upload.sh.  Spawns HASH_WORKERS background processes that
# claim parts from a shared atomic index and compute sha256 + stat
# concurrently.  As each part is hashed its name is appended to
# split_part_queue.txt (with flock) so that upload workers started
# before this function was called can begin uploading immediately
# rather than waiting for all hashing to complete.
#
# After all hash workers finish, appends the sentinel __DONE__ to
# split_part_queue.txt so waiting upload workers know no more parts
# will be added.
#
# Sets SPLIT_PART_COUNT.
# Does NOT sort parts_meta_file — caller must sort before write_manifest().
# ============================================================
split_collect_part_metadata_parallel() {
    local parts_dir="$1"
    local part_prefix="$2"
    local parts_meta_file="$3"
    local hash_workers="$4"
    local queue_file="${SPLIT_JOB_DIR}/split_part_queue.txt"
    local queue_lock="${SPLIT_JOB_DIR}/split_part_queue.lock"

    : > "${parts_meta_file}"
    # queue_file already exists and may have been pre-created by the caller;
    # do not truncate it here — upload workers may already be reading it.

    log "INFO" "Parallel part hashing: workers=${hash_workers}"
    log "DEBUG" "Scanning for parts in: ${parts_dir} matching: ${part_prefix}*"

    # Build the ordered parts list once so subshells can access it via a file.
    # Using a temp file avoids the array-export-across-subshell limitation.
    local parts_list_file="${SPLIT_JOB_DIR}/hash_parts_list.txt"
    find "${parts_dir}" -maxdepth 1 -name "${part_prefix}*" | sort > "${parts_list_file}"

    SPLIT_PART_COUNT=$(wc -l < "${parts_list_file}")
    if (( SPLIT_PART_COUNT == 0 )); then
        log "ERROR" "No parts found in ${parts_dir} matching '${part_prefix}*'"
        return 1
    fi
    log "INFO" "Parts to hash: ${SPLIT_PART_COUNT}"

    # Atomic work-index counter: holds the 0-based index of the next unclaimed part.
    local work_index_file="${SPLIT_JOB_DIR}/hash_work_index"
    local work_index_lock="${SPLIT_JOB_DIR}/hash_work_index.lock"
    echo "0" > "${work_index_file}"

    # Lock file for appending to parts_meta_file (separate from queue lock)
    local meta_lock="${SPLIT_JOB_DIR}/parts_meta.lock"

    # ---- Internal hash worker function (runs as a subshell via &) ----
    _split_hash_worker() {
        local _worker_id="$1"
        local _total="$2"
        local _parts_list_file="$3"
        local _work_index_file="$4"
        local _work_index_lock="$5"
        local _meta_file="$6"
        local _meta_lock="$7"
        local _queue_file="$8"
        local _queue_lock="$9"

        log "DEBUG" "Hash worker ${_worker_id} started (PID $$)"

        while true; do
            # Atomically claim the next index
            local _idx
            _idx=$(
                (
                    flock -x 200
                    local _n
                    _n=$(cat "${_work_index_file}")
                    if (( _n >= _total )); then
                        echo "${_total}"
                    else
                        echo $(( _n + 1 )) > "${_work_index_file}"
                        echo "${_n}"
                    fi
                ) 200>"${_work_index_lock}"
            )

            # No more work
            (( _idx >= _total )) && break

            # Read the part path at that index (1-based for sed)
            local _partfile
            _partfile=$(sed -n "$(( _idx + 1 ))p" "${_parts_list_file}")
            local _partname
            _partname=$(basename "${_partfile}")

            # Compute size + hash
            local _part_size _part_hash
            _part_size=$(stat -c '%s' "${_partfile}" 2>/dev/null || echo 0)
            _part_hash=$(sha256sum "${_partfile}" 2>/dev/null | awk '{print $1}')

            # Append to meta file (flock — arrival order, caller sorts later)
            (
                flock -x 201
                printf '%s  size=%s  sha256=%s\n' \
                    "${_partname}" "${_part_size}" "${_part_hash}" >> "${_meta_file}"
            ) 201>"${_meta_lock}"

            # Append partname to upload queue (flock — shared with upload workers)
            (
                flock -x 200
                echo "${_partname}" >> "${_queue_file}"
            ) 200>"${_queue_lock}"

            log "DEBUG" "Hash worker ${_worker_id}: ${_partname}  size=${_part_size}  sha256=${_part_hash}"
        done

        log "DEBUG" "Hash worker ${_worker_id} finished"
    }

    # Spawn hash workers
    local hash_pids=()
    local i
    for (( i=1; i<=hash_workers; i++ )); do
        _split_hash_worker \
            "${i}" \
            "${SPLIT_PART_COUNT}" \
            "${parts_list_file}" \
            "${work_index_file}" \
            "${work_index_lock}" \
            "${parts_meta_file}" \
            "${meta_lock}" \
            "${queue_file}" \
            "${queue_lock}" &
        hash_pids+=($!)
        log "DEBUG" "Hash worker ${i} PID=${hash_pids[-1]}"
    done

    # Wait for all hash workers; propagate any failure
    local hash_rc=0
    for pid in "${hash_pids[@]}"; do
        wait "${pid}" || { log "ERROR" "A hash worker failed (pid=${pid})"; hash_rc=1; }
    done

    if (( hash_rc != 0 )); then
        return 1
    fi

    log "INFO" "Parallel hashing complete — ${SPLIT_PART_COUNT} parts hashed"

    # Append sentinel so upload workers know no more parts are coming
    (
        flock -x 200
        echo "__DONE__" >> "${queue_file}"
    ) 200>"${queue_lock}"

    log "DEBUG" "Sentinel __DONE__ written to queue"
}

# ============================================================
# split_upload_manifest LOCAL_MANIFEST SFTP_MANIFEST_PATH
# Uploads the manifest file to SFTP.
# ============================================================
split_upload_manifest() {
    local local_manifest="$1"
    local sftp_manifest_path="$2"
    local sftp_out="${SPLIT_JOB_DIR}/split_sftp_manifest.log"

    log "INFO" "Uploading manifest: ${sftp_manifest_path}"

    local rc=0
    SSHPASS="${SFTP_PASS}" sshpass -e sftp \
            -P "${SFTP_PORT}" \
            -o StrictHostKeyChecking=no \
            -o BatchMode=no \
            -o ConnectTimeout=5 \
            -o ServerAliveInterval=15 \
            -o ServerAliveCountMax=3 \
            -o LogLevel=ERROR \
            -b <(printf 'put %s %s\n' "${local_manifest}" "${sftp_manifest_path}") \
            "${SFTP_USER}@${SFTP_HOST}" > "${sftp_out}" 2>&1 || rc=$?

    if [[ -s "${sftp_out}" ]]; then
        while IFS= read -r sftp_line; do
            log "DEBUG" "[sftp] ${sftp_line}"
        done < "${sftp_out}"
    fi

    if (( rc != 0 )); then
        log "ERROR" "Failed to upload manifest to SFTP (rc=${rc}): ${sftp_manifest_path}"
        return 1
    fi

    log "INFO" "Manifest uploaded OK"
}

# ============================================================
# split_run_upload_workers PARTS_STAGING_DIR SFTP_PARTS_DIR NUM_WORKERS
# Spawns NUM_WORKERS split_upload_worker() processes in parallel.
# Waits for all to finish.
# ============================================================
split_run_upload_workers() {
    local parts_staging_dir="$1"
    local sftp_parts_dir="$2"
    local num_workers="$3"

    mkdir -p "${SPLIT_JOB_DIR}/split_status" "${SPLIT_JOB_DIR}/workers"

    log "INFO" "Spawning ${num_workers} split upload worker(s)"
    local pids=()
    local i
    for (( i=1; i<=num_workers; i++ )); do
        split_upload_worker "${i}" "${parts_staging_dir}" "${sftp_parts_dir}" &
        pids+=($!)
        log "DEBUG" "  Worker ${i} PID=${pids[-1]}"
    done

    log "DEBUG" "Waiting for all upload workers to finish..."
    local rc=0
    for pid in "${pids[@]}"; do
        wait "${pid}" || rc=1
    done

    if (( rc != 0 )); then
        log "WARN" "One or more upload workers exited with non-zero status"
    fi

    merge_split_upload_results
    log "INFO" "Upload workers done — uploaded=${SPLIT_CNT_UPLOADED} skipped=${SPLIT_CNT_SKIPPED} failed=${SPLIT_CNT_FAILED} errors=${SPLIT_CNT_ERRORS}"
}

# ============================================================
# split_start_upload_workers PARTS_STAGING_DIR SFTP_PARTS_DIR NUM_WORKERS
#
# Spawns NUM_WORKERS split_upload_worker() processes in the background
# and stores their PIDs in the global array _SPLIT_UPLOAD_WORKER_PIDS.
# Used by split_upload.sh so workers can start consuming the queue
# while parallel hash workers are still filling it.
# Call split_wait_upload_workers() after hashing + sentinel are done.
# ============================================================
# Global PID array populated by split_start_upload_workers()
_SPLIT_UPLOAD_WORKER_PIDS=()

split_start_upload_workers() {
    local parts_staging_dir="$1"
    local sftp_parts_dir="$2"
    local num_workers="$3"

    mkdir -p "${SPLIT_JOB_DIR}/split_status" "${SPLIT_JOB_DIR}/workers"
    _SPLIT_UPLOAD_WORKER_PIDS=()

    log "INFO" "Spawning ${num_workers} upload worker(s) (background)"
    local i
    for (( i=1; i<=num_workers; i++ )); do
        split_upload_worker "${i}" "${parts_staging_dir}" "${sftp_parts_dir}" &
        _SPLIT_UPLOAD_WORKER_PIDS+=($!)
        log "DEBUG" "  Upload worker ${i} PID=${_SPLIT_UPLOAD_WORKER_PIDS[-1]}"
    done
}

# ============================================================
# split_wait_upload_workers
#
# Waits for all upload worker PIDs stored in _SPLIT_UPLOAD_WORKER_PIDS
# (populated by split_start_upload_workers()) to exit, then merges
# their result files and logs the final counts.
# ============================================================
split_wait_upload_workers() {
    log "DEBUG" "Waiting for ${#_SPLIT_UPLOAD_WORKER_PIDS[@]} upload worker(s) to finish..."

    local rc=0
    for pid in "${_SPLIT_UPLOAD_WORKER_PIDS[@]}"; do
        wait "${pid}" || rc=1
    done

    if (( rc != 0 )); then
        log "WARN" "One or more upload workers exited with non-zero status"
    fi

    merge_split_upload_results
    log "INFO" "Upload workers done — uploaded=${SPLIT_CNT_UPLOADED} skipped=${SPLIT_CNT_SKIPPED} failed=${SPLIT_CNT_FAILED} errors=${SPLIT_CNT_ERRORS}"
}