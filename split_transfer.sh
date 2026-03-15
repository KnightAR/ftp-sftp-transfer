#!/usr/bin/env bash
# ============================================================
# split_transfer.sh — Large-File Split Upload Orchestrator
#
# Downloads a single large file from FTP, splits it into fixed-size
# parts, computes per-part sha256 hashes, uploads all parts in
# parallel to SFTP, and writes a manifest file alongside the parts
# so split_restore.sh can later reconstruct and verify the original.
#
# Usage:
#   ./split_transfer.sh <ftp_path> [OPTIONS]
#
# Positional:
#   ftp_path        FTP path of the file to transfer (required)
#
# Options:
#   -c CONFIG       Config file path (default: transfer.conf)
#   -s SIZE         Part size, e.g. 500m, 2g (default: 1g)
#   -p WORKERS      Parallel upload workers (default: 10)
#   -t TEMP_DIR     Override temp directory
#   -n              No delete — keep original FTP file after split
#   -v              Verbose / debug logging
#   -h              Show this help
#
# Pipeline:
#   1. Load config + validate (reuses src/core/config.sh)
#   2. Check dependencies (lftp, sshpass, split, sha256sum)
#   3. Download file from FTP via lftp → local staging
#   4. Concurrent sha256 + split:
#        sha256sum runs as background job on the downloaded file
#        gnu split runs simultaneously (both read sequentially)
#        Both finish before we proceed — sha256 completes first
#        or at the same time as split; we wait for both.
#   5. Collect per-part sizes and sha256 hashes
#   6. Write manifest to local staging
#   7. Delete original local download (staging space reclaimed)
#   8. Upload manifest to SFTP (original FTP dir path)
#   9. Upload parts in parallel via split_upload_worker()
#  10. Verify all parts UPLOADED (none FAILED)
#  11. Optionally delete original from FTP (unless -n)
#  12. Print summary
#
# Disk usage (peak):
#   During split:  original_file + all parts ≈ 2× file size
#   After split:   parts only ≈ original_file size
#   (Original deleted immediately after split+sha256 complete)
#
# SFTP layout produced:
#   <original_ftp_dir>/
#     <filename>.manifest
#     split/
#       <filename>.part.00001
#       <filename>.part.00002
#       ...
#
# Reuses modules from src/ (same config, logging, sftp, ftp,
# lock, temp, trap infrastructure as transfer.sh).
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ---- Source all required modules (dependency order) ----
source "${SCRIPT_DIR}/src/core/constants.sh"
source "${SCRIPT_DIR}/src/core/logging.sh"
source "${SCRIPT_DIR}/src/core/args.sh"
source "${SCRIPT_DIR}/src/core/config.sh"
source "${SCRIPT_DIR}/src/system/dependencies.sh"
source "${SCRIPT_DIR}/src/system/lock.sh"
source "${SCRIPT_DIR}/src/system/temp.sh"
source "${SCRIPT_DIR}/src/system/trap.sh"
source "${SCRIPT_DIR}/src/transfer/ftp.sh"
source "${SCRIPT_DIR}/src/transfer/sftp.sh"
source "${SCRIPT_DIR}/src/transfer/ftp_delete.sh"
source "${SCRIPT_DIR}/src/workers/counters.sh"
source "${SCRIPT_DIR}/src/split/split_config.sh"
source "${SCRIPT_DIR}/src/split/split_args.sh"
source "${SCRIPT_DIR}/src/split/split_manifest.sh"
source "${SCRIPT_DIR}/src/split/split_worker.sh"

# ============================================================
# split_check_dependencies
# Checks tools required by split_transfer.sh beyond the base set.
# ============================================================
split_check_dependencies() {
    local missing=()
    for cmd in lftp sshpass split sha256sum stat; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        log "ERROR" "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

# ============================================================
# split_download_from_ftp FTP_PATH LOCAL_DEST
# Downloads a single file from FTP using lftp.
# Returns the local file path written.
# ============================================================
split_download_from_ftp() {
    local ftp_path="$1"
    local local_dest="$2"
    local ftp_dir
    ftp_dir=$(dirname "${ftp_path}")
    local ftp_file
    ftp_file=$(basename "${ftp_path}")

    log "INFO" "Downloading from FTP: ${ftp_path} → ${local_dest}"

    local lftp_script
    lftp_script=$(cat <<EOF
set net:max-retries 3
set net:reconnect-interval-base 10
set net:timeout 120
open ${FTP_CONNECT_STR}
lcd $(dirname "${local_dest}")
cd ${ftp_dir}
get ${ftp_file} -o $(basename "${local_dest}")
bye
EOF
)
    if ! echo "${lftp_script}" | lftp &>/dev/null; then
        log "ERROR" "lftp download failed for: ${ftp_path}"
        return 1
    fi

    if [[ ! -f "${local_dest}" ]]; then
        log "ERROR" "Download completed but local file not found: ${local_dest}"
        return 1
    fi

    log "INFO" "Download complete: ${local_dest} ($(stat -c '%s' "${local_dest}") bytes)"
}

# ============================================================
# split_run_concurrent_hash_and_split LOCAL_FILE PARTS_DIR PART_PREFIX
#                                      PART_SIZE_BYTES SUFFIX_LEN
#                                      HASH_OUT_FILE
# Runs sha256sum and gnu split concurrently on LOCAL_FILE.
# Both processes read the file sequentially; running them in
# parallel saves one full sequential read on spinning disk.
# Waits for both to finish before returning.
# HASH_OUT_FILE receives the raw "hash  filename" line from sha256sum.
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
    local queue_file="${TEMP_DIR}/split_part_queue.txt"

    : > "${parts_meta_file}"
    : > "${queue_file}"

    SPLIT_PART_COUNT=0

    # Parts are named <prefix>NNNNN — sort numerically by suffix
    local partfile partname part_size part_hash
    while IFS= read -r partfile; do
        partname=$(basename "${partfile}")
        part_size=$(stat -c '%s' "${partfile}" 2>/dev/null || echo 0)
        part_hash=$(sha256sum "${partfile}" 2>/dev/null | awk '{print $1}')
        printf '%s  size=%s  sha256=%s\n' \
            "${partname}" "${part_size}" "${part_hash}" >> "${parts_meta_file}"
        echo "${partname}" >> "${queue_file}"
        (( SPLIT_PART_COUNT++ ))
        log "DEBUG" "Part: ${partname}  size=${part_size}  sha256=${part_hash}"
    done < <(find "${parts_dir}" -maxdepth 1 -name "${part_prefix}*" | sort)

    log "INFO" "Collected metadata for ${SPLIT_PART_COUNT} parts"
}

# ============================================================
# split_upload_manifest LOCAL_MANIFEST SFTP_MANIFEST_PATH
# Uploads the manifest file to SFTP.
# ============================================================
split_upload_manifest() {
    local local_manifest="$1"
    local sftp_manifest_path="$2"

    log "INFO" "Uploading manifest: ${sftp_manifest_path}"

    if ! SSHPASS="${SFTP_PASS}" sshpass -e sftp \
            -P "${SFTP_PORT}" \
            -o StrictHostKeyChecking=no \
            -o BatchMode=no \
            -o ConnectTimeout=30 \
            -o LogLevel=ERROR \
            -b <(printf 'put %s %s\n' "${local_manifest}" "${sftp_manifest_path}") \
            "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
        log "ERROR" "Failed to upload manifest to SFTP: ${sftp_manifest_path}"
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

    mkdir -p "${TEMP_DIR}/split_status" "${TEMP_DIR}/workers"

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
# split_print_summary
# Prints the final summary for a split transfer run.
# ============================================================
split_print_summary() {
    local original_file="$1"
    local original_size="$2"
    local original_hash="$3"
    local part_count="$4"
    local sftp_manifest_path="$5"

    log "INFO" "============================================================"
    log "INFO" "Split Transfer Summary"
    log "INFO" "============================================================"
    log "INFO" "  FTP source      : ${SPLIT_CLI_FTP_PATH}"
    log "INFO" "  Original size   : ${original_size} bytes"
    log "INFO" "  Original sha256 : ${original_hash}"
    log "INFO" "  Parts created   : ${part_count}"
    log "INFO" "  Part size       : ${SPLIT_SIZE}"
    log "INFO" "  Upload workers  : ${SPLIT_PART_WORKERS}"
    log "INFO" "  Uploaded        : ${SPLIT_CNT_UPLOADED}"
    log "INFO" "  Skipped (resume): ${SPLIT_CNT_SKIPPED}"
    log "INFO" "  Failed          : ${SPLIT_CNT_FAILED}"
    log "INFO" "  Errors          : ${SPLIT_CNT_ERRORS}"
    log "INFO" "  Manifest        : ${sftp_manifest_path}"
    log "INFO" "============================================================"
}

# ============================================================
# split_main
# Main entry point for split_transfer.sh.
# ============================================================
split_main() {
    # ---- Parse CLI args ----
    split_parse_args "$@"

    # ---- Load and validate config ----
    load_config "${SPLIT_CLI_CONFIG}"
    apply_split_defaults
    validate_split_config

    # Override split settings from CLI flags if provided
    [[ -n "${SPLIT_CLI_SIZE}"    ]] && SPLIT_SIZE="${SPLIT_CLI_SIZE}"
    [[ -n "${SPLIT_CLI_WORKERS}" ]] && SPLIT_PART_WORKERS="${SPLIT_CLI_WORKERS}"
    [[ -n "${SPLIT_CLI_TEMP}"    ]] && TEMP_DIR="${SPLIT_CLI_TEMP}"

    # ---- Setup ----
    setup_logging
    acquire_lock
    setup_temp_dir
    split_check_dependencies

    log "INFO" "split_transfer.sh ${SCRIPT_VERSION} starting"
    log "INFO" "  FTP path   : ${SPLIT_CLI_FTP_PATH}"
    log "INFO" "  Part size  : ${SPLIT_SIZE}"
    log "INFO" "  Workers    : ${SPLIT_PART_WORKERS}"

    # ---- Derive path components ----
    local ftp_path="${SPLIT_CLI_FTP_PATH}"
    local filename
    filename=$(basename "${ftp_path}")
    local ftp_dir
    ftp_dir=$(dirname "${ftp_path}")

    # Convert human-readable SPLIT_SIZE to bytes for split(1)
    # Accepts: 500m, 1g, 2g, 512k etc.
    local part_size_bytes
    part_size_bytes=$(numfmt --from=iec "${SPLIT_SIZE}" 2>/dev/null \
        || python3 -c "
s='${SPLIT_SIZE}'.lower()
m={'k':1024,'m':1024**2,'g':1024**3,'t':1024**4}
for sfx,mult in m.items():
    if s.endswith(sfx):
        print(int(s[:-1])*mult)
        exit()
print(int(s))
")

    # Local staging paths
    local staging_dir="${TEMP_DIR}/split_staging"
    mkdir -p "${staging_dir}"
    local local_file="${staging_dir}/${filename}"
    local parts_dir="${staging_dir}/parts"
    mkdir -p "${parts_dir}"
    local part_prefix="${filename}.part."
    local hash_out_file="${staging_dir}/${filename}.sha256"
    local parts_meta_file="${staging_dir}/${filename}.partsmeta"
    local local_manifest="${staging_dir}/${filename}.manifest"

    # SFTP destination paths
    # Manifest sits in the same dir as the original FTP file would be
    # Parts go into a "split" subdirectory under that
    local sftp_base_dir="${ftp_dir}"
    local sftp_manifest_path="${sftp_base_dir}/${filename}.manifest"
    local sftp_parts_dir="${sftp_base_dir}/${SPLIT_PARTS_SUBDIR}"

    # ---- Step 1: FTP → local ----
    setup_ftp_connection
    split_download_from_ftp "${ftp_path}" "${local_file}"

    local original_size
    original_size=$(stat -c '%s' "${local_file}")

    # ---- Step 2: Concurrent sha256 + split ----
    split_run_concurrent_hash_and_split \
        "${local_file}" \
        "${parts_dir}" \
        "${part_prefix}" \
        "${part_size_bytes}" \
        "${SPLIT_SUFFIX_LENGTH}" \
        "${hash_out_file}"

    # Extract original file hash from sha256sum output
    local original_sha256
    original_sha256=$(awk '{print $1}' "${hash_out_file}")
    log "INFO" "Original file sha256: ${original_sha256}"

    # ---- Step 3: Delete original (reclaim staging space) ----
    log "INFO" "Deleting local copy of original file: ${local_file}"
    rm -f "${local_file}"

    # ---- Step 4: Collect per-part metadata ----
    split_collect_part_metadata \
        "${parts_dir}" \
        "${part_prefix}" \
        "${parts_meta_file}"

    # ---- Step 5: Write manifest ----
    write_manifest \
        "${local_manifest}" \
        "${ftp_path}" \
        "${filename}" \
        "${original_size}" \
        "${original_sha256}" \
        "${part_size_bytes}" \
        "${SPLIT_PART_COUNT}" \
        "${part_prefix}" \
        "${sftp_parts_dir}" \
        "${parts_meta_file}"

    # ---- Step 6: Create SFTP parts directory ----
    sftp_mkdir_p "${sftp_parts_dir}"

    # ---- Step 7: Upload manifest ----
    split_upload_manifest "${local_manifest}" "${sftp_manifest_path}"

    # ---- Step 8: Upload parts in parallel ----
    split_run_upload_workers \
        "${parts_dir}" \
        "${sftp_parts_dir}" \
        "${SPLIT_PART_WORKERS}"

    # ---- Step 9: Check for failures ----
    if (( SPLIT_CNT_FAILED > 0 || SPLIT_CNT_ERRORS > 0 )); then
        log "ERROR" "Split transfer completed with failures — ${SPLIT_CNT_FAILED} failed, ${SPLIT_CNT_ERRORS} errors"
        log "ERROR" "Re-run split_transfer.sh with the same arguments to resume"
        split_print_summary \
            "${local_file}" "${original_size}" "${original_sha256}" \
            "${SPLIT_PART_COUNT}" "${sftp_manifest_path}"
        exit 1
    fi

    # ---- Step 10: Optionally delete original from FTP ----
    if [[ "${SPLIT_CLI_NO_DELETE:-false}" != "true" ]] && \
       [[ "${DELETE_FROM_FTP:-false}" == "true" ]]; then
        log "INFO" "Deleting original file from FTP: ${ftp_path}"
        delete_ftp_file "${ftp_path}"
    fi

    # ---- Summary ----
    split_print_summary \
        "${local_file}" "${original_size}" "${original_sha256}" \
        "${SPLIT_PART_COUNT}" "${sftp_manifest_path}"

    log "INFO" "split_transfer.sh complete — all ${SPLIT_PART_COUNT} parts uploaded and verified"
}

split_main "$@"