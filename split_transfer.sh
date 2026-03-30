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
source "${SCRIPT_DIR}/src/transfer/archive_verify.sh"
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
# Downloads a single file from FTP using run_lftp() (reuses the same
# FTP_CONNECT_STR / credentials / host as the rest of the pipeline).
# lftp output is captured to a temp file so it appears in the log on
# failure — never silenced completely.
# ============================================================
split_download_from_ftp() {
    local ftp_path="$1"
    local local_dest="$2"
    local ftp_dir
    ftp_dir=$(dirname "${ftp_path}")
    local ftp_file
    ftp_file=$(basename "${ftp_path}")
    local dest_dir
    dest_dir=$(dirname "${local_dest}")
    local lftp_out="${SPLIT_JOB_DIR}/split_lftp_download.log"

    log "INFO" "Downloading from FTP: ${ftp_path} → ${local_dest}"

    # Use run_lftp() which already embeds FTP_CONNECT_STR + credentials + host.
    # lcd into the destination directory so lftp writes the file there directly.
    local rc=0
    run_lftp "lcd ${dest_dir}; cd ${ftp_dir}; get ${ftp_file} -o $(basename "${local_dest}")" \
        > "${lftp_out}" 2>&1 || rc=$?

    # Always log lftp output — visible in DEBUG mode or on failure
    if [[ -s "${lftp_out}" ]]; then
        while IFS= read -r lftp_line; do
            log "DEBUG" "[lftp] ${lftp_line}"
        done < "${lftp_out}"
    fi

    if (( rc != 0 )); then
        log "ERROR" "lftp download failed (rc=${rc}) for: ${ftp_path}"
        return 1
    fi

    if [[ ! -f "${local_dest}" ]]; then
        log "ERROR" "lftp exited OK but local file not found: ${local_dest}"
        return 1
    fi

    log "INFO" "Download complete: ${local_dest} ($(stat -c '%s' "${local_dest}") bytes)"
}

source "${SCRIPT_DIR}/src/split/split_ops.sh"

# ============================================================
# split_print_summary
# Prints the final summary for a split_transfer.sh run.
# ============================================================
split_print_summary() {
    local original_size="$1"
    local original_hash="$2"
    local part_count="$3"
    local sftp_manifest_path="$4"

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
    # ---- Preserve staging on failure so re-runs can resume ----
    # trap_cleanup() checks this flag and skips cleanup_job_dir() on non-zero
    # exit.  We call cleanup_job_dir() explicitly below only after full success.
    SPLIT_PRESERVE_ON_FAILURE=true

    # ---- Parse CLI args ----
    split_parse_args "$@"

    # ---- Resolve config file (split.transfer.conf → transfer.conf) ----
    resolve_split_config

    # ---- Load and validate config ----
    load_config "${SPLIT_CLI_CONFIG}"
    apply_split_defaults
    validate_split_config

    # Override split settings from CLI flags if provided
    [[ -n "${SPLIT_CLI_SIZE}"     ]] && SPLIT_SIZE="${SPLIT_CLI_SIZE}"          || true
    [[ -n "${SPLIT_CLI_WORKERS}"  ]] && SPLIT_PART_WORKERS="${SPLIT_CLI_WORKERS}" || true
    # -t flag overrides SPLIT_TEMP_DIR from config
    [[ -n "${SPLIT_CLI_TEMP_DIR}" ]] && SPLIT_TEMP_DIR="${SPLIT_CLI_TEMP_DIR}"   || true

    # If SPLIT_TEMP_DIR is explicitly set (config or -t flag), use it as TEMP_DIR.
    # Otherwise fall back to TEMP_DIR (from config or mktemp via setup_temp_dir).
    if [[ -n "${SPLIT_TEMP_DIR:-}" ]]; then
        TEMP_DIR="${SPLIT_TEMP_DIR}"
    fi

    # ---- Setup (order matters: temp dir must exist before logging) ----
    setup_temp_dir
    setup_logging
    acquire_lock
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

    # ---- Set up per-job directory ----
    # Each job gets its own subdirectory under TEMP_DIR scoped by filename,
    # so concurrent jobs and cleanup never interfere with each other.
    SPLIT_JOB_DIR="${TEMP_DIR}/${filename}"
    mkdir -p "${SPLIT_JOB_DIR}"

    # Local staging paths (all inside the job dir)
    local local_file="${SPLIT_JOB_DIR}/${filename}"
    local parts_dir="${SPLIT_JOB_DIR}/parts"
    mkdir -p "${parts_dir}"
    local part_prefix="${filename}.part."
    local hash_out_file="${SPLIT_JOB_DIR}/${filename}.sha256"
    local parts_meta_file="${SPLIT_JOB_DIR}/${filename}.partsmeta"
    local local_manifest="${SPLIT_JOB_DIR}/${filename}.manifest"

    # SFTP destination paths
    # Manifest sits in the same dir as the original FTP file would be.
    # Parts go into a "split" subdirectory under that.
    #
    # SFTP_REMOTE_DIR has no trailing slash (config convention, same as
    # transfer.sh / download_worker.sh which uses ${SFTP_REMOTE_DIR}${ftp_path}
    # where ftp_path always starts with "/").
    #
    # ftp_dir is the dirname of the FTP path.  For a root-level file like
    # /blockchain.tar.xz, dirname returns "/" — strip that trailing slash so
    # the concatenation is "bucket" + "" + "/file.manifest" not "bucket//file".
    local sftp_base_dir="${SFTP_REMOTE_DIR}${ftp_dir%/}"
    local sftp_manifest_path="${sftp_base_dir}/${filename}.manifest"
    local sftp_parts_dir="${sftp_base_dir}/${SPLIT_PARTS_SUBDIR}"

    # ---- Resume detection ----
    # Check whether a previous run left usable state in the staging directory.
    # Three cases, evaluated in order:
    #
    #   RESUME  — local manifest + at least one part file already exist.
    #             Skip FTP download, split, sha256, metadata collection, and
    #             manifest write entirely.  Read the existing manifest to
    #             populate MANIFEST_* variables and part hash/size arrays.
    #
    #   PARTIAL — original file is staged locally but parts do not exist yet
    #             (e.g. previous run died between download and split).
    #             Skip FTP download; re-run split+sha256 from the local file.
    #
    #   FULL    — nothing useful staged; run all steps.

    local original_size original_sha256
    local existing_part_count
    existing_part_count=$(find "${parts_dir}" -maxdepth 1 -name "${part_prefix}*" 2>/dev/null | wc -l)

    if [[ -f "${local_manifest}" ]] && (( existing_part_count > 0 )); then
        # ---- RESUME MODE ----
        log "INFO" "Resuming from existing local staging — skipping FTP download and split"
        log "INFO" "  Local manifest : ${local_manifest}"
        log "INFO" "  Parts found    : ${existing_part_count}"
        read_manifest "${local_manifest}"
        original_size="${MANIFEST_ORIGINAL_SIZE}"
        original_sha256="${MANIFEST_ORIGINAL_SHA256}"
        SPLIT_PART_COUNT="${MANIFEST_PART_COUNT}"

        # Rebuild the upload queue from the parts still present locally.
        # Previously-uploaded parts were deleted after verification, so only
        # parts that are physically present still need uploading.
        local queue_file="${SPLIT_JOB_DIR}/split_part_queue.txt"
        : > "${queue_file}"
        local queued_count=0
        while IFS= read -r partfile; do
            echo "$(basename "${partfile}")" >> "${queue_file}"
            (( queued_count++ )) || true
        done < <(find "${parts_dir}" -maxdepth 1 -name "${part_prefix}*" | sort)
        log "INFO" "  Queue rebuilt  : ${queued_count} part(s) remaining to upload"
        

    elif [[ -f "${local_file}" ]] && (( $(stat -c '%s' "${local_file}") > 0 )); then
        # ---- PARTIAL MODE ----
        log "INFO" "Local file already staged — skipping FTP download"
        original_size=$(stat -c '%s' "${local_file}")

        # ---- Step 1a: Archive integrity check ----
        local arc_rc=0
        verify_archive_integrity "${local_file}" || arc_rc=$?
        if (( arc_rc == 1 )); then
            log "ERROR" "Archive integrity check failed — aborting: ${local_file}"
            exit 1
        fi
        # arc_rc=2 means not a known archive format — continue as plain file

        # ---- Step 2: Concurrent sha256 + split ----
        split_run_concurrent_hash_and_split \
            "${local_file}" \
            "${parts_dir}" \
            "${part_prefix}" \
            "${part_size_bytes}" \
            "${SPLIT_SUFFIX_LENGTH}" \
            "${hash_out_file}"

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

        # ---- Step 6: Read manifest into memory ----
        read_manifest "${local_manifest}"

    else
        # ---- FULL RUN ----
        # ---- Step 1: FTP → local ----
        setup_ftp_connection
        split_download_from_ftp "${ftp_path}" "${local_file}"
        original_size=$(stat -c '%s' "${local_file}")

        # ---- Step 1a: Archive integrity check ----
        local arc_rc=0
        verify_archive_integrity "${local_file}" || arc_rc=$?
        if (( arc_rc == 1 )); then
            log "ERROR" "Archive integrity check failed — aborting: ${local_file}"
            exit 1
        fi
        # arc_rc=2 means not a known archive format — continue as plain file

        # ---- Step 2: Concurrent sha256 + split ----
        split_run_concurrent_hash_and_split \
            "${local_file}" \
            "${parts_dir}" \
            "${part_prefix}" \
            "${part_size_bytes}" \
            "${SPLIT_SUFFIX_LENGTH}" \
            "${hash_out_file}"

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

        # ---- Step 6: Read manifest into memory ----
        # Populates MANIFEST_PART_SIZE[] and MANIFEST_PART_SHA256[] associative
        # arrays in the parent process so forked upload workers inherit them.
        read_manifest "${local_manifest}"
    fi

    # ---- Step 7: Create SFTP parts directory ----
    sftp_mkdir_p "${sftp_parts_dir}"

    # ---- Step 8: Upload manifest ----
    split_upload_manifest "${local_manifest}" "${sftp_manifest_path}"

    # ---- Step 9: Upload parts in parallel ----
    split_run_upload_workers \
        "${parts_dir}" \
        "${sftp_parts_dir}" \
        "${SPLIT_PART_WORKERS}"

    # ---- Step 10: Check for failures ----
    if (( SPLIT_CNT_FAILED > 0 || SPLIT_CNT_ERRORS > 0 )); then
        log "ERROR" "Split transfer completed with failures — ${SPLIT_CNT_FAILED} failed, ${SPLIT_CNT_ERRORS} errors"
        log "ERROR" "Re-run split_transfer.sh with the same arguments to resume"
        split_print_summary \
            "${original_size}" "${original_sha256}" \
            "${SPLIT_PART_COUNT}" "${sftp_manifest_path}"
        exit 1
    fi

    # ---- Step 11: Optionally delete original from FTP ----
    if [[ "${SPLIT_CLI_NO_DELETE:-false}" != "true" ]] && \
       [[ "${DELETE_FROM_FTP:-false}" == "true" ]]; then
        log "INFO" "Deleting original file from FTP: ${ftp_path}"
        delete_ftp_file "${ftp_path}"
    fi

    # ---- Summary ----
    split_print_summary \
        "${original_size}" "${original_sha256}" \
        "${SPLIT_PART_COUNT}" "${sftp_manifest_path}"

    # ---- Allow cleanup on success ----
    # On any earlier failure path we exited before reaching here, so the job
    # directory is preserved by trap_cleanup() (SPLIT_PRESERVE_ON_FAILURE=true)
    # for re-run resume.  Clear the flag now so the EXIT trap's
    # cleanup_job_dir() call removes SPLIT_JOB_DIR normally.
    SPLIT_PRESERVE_ON_FAILURE=false

    log "INFO" "split_transfer.sh complete — all ${SPLIT_PART_COUNT} parts uploaded and verified"
}

split_main "$@"