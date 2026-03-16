#!/usr/bin/env bash
# ============================================================
# src/split/split_ops.sh — Shared Split Operation Functions
#
# Provides the core split/upload orchestration functions shared
# by split_transfer.sh and split_upload.sh:
#
#   split_run_concurrent_hash_and_split() — concurrent sha256 + split
#   split_collect_part_metadata()         — per-part size + sha256
#   split_upload_manifest()               — upload manifest to SFTP
#   split_run_upload_workers()            — spawn parallel upload workers
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