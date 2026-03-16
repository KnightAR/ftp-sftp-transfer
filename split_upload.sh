#!/usr/bin/env bash
# ============================================================
# split_upload.sh — Local File Split Upload Orchestrator
#
# Splits a locally existing file into fixed-size parts, computes
# per-part sha256 hashes, uploads all parts in parallel to SFTP,
# and writes a manifest file alongside the parts so split_restore.sh
# can later reconstruct and verify the original.
#
# Unlike split_transfer.sh, no FTP download is performed — the source
# file already exists on local disk.  The source file is read in-place
# (not copied to staging), so no extra disk space is required beyond
# the split parts themselves.
#
# Usage:
#   ./split_upload.sh <source_file> [OPTIONS]
#
#   -r PATH   Remote SFTP subpath relative to SFTP_REMOTE_DIR
#             (default: / — stored at SFTP bucket root)
#   -s SIZE   Part size override (split -b syntax, e.g. 500m, 2g)
#   -p N      Parallel upload workers
#   -t DIR    Staging temp dir override
#   -d        Delete source file after successful upload + verification
#   -c FILE   Config file override
#   -v        Verbose / DEBUG output
#   -h        Help
#
# Execution flow:
#   1. Parse args + load config
#   2. Validate source file exists and is readable
#   3. Archive integrity check (if VERIFY_ARCHIVE_INTEGRITY=true)
#   4. Concurrent sha256 + split
#   5. Collect per-part metadata
#   6. Write manifest
#   7. Create SFTP parts directory
#   8. Upload manifest
#   9. Upload parts in parallel
#  10. Check for failures
#  11. If -d passed: delete source file
#  12. Cleanup staging (via EXIT trap)
#
# Resume behaviour:
#   RESUME  — manifest + parts in staging: skip to upload
#   PARTIAL — parts dir empty but job dir exists: re-run split
#   FULL    — nothing staged: full flow
#
# SFTP layout produced:
#   <SFTP_REMOTE_DIR><remote_path>/
#   <SFTP_REMOTE_DIR><remote_path>/<filename>.manifest
#   <SFTP_REMOTE_DIR><remote_path>/split/<filename>.part.00001
#   ...
#
# The source file is NOT deleted by default.  Pass -d to delete it
# only after all parts have been uploaded and verified successfully.
#
# Reuses modules from src/ — same config, logging, sftp, split
# worker, manifest, and trap infrastructure as split_transfer.sh.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/src/core/constants.sh"
source "${SCRIPT_DIR}/src/core/logging.sh"
source "${SCRIPT_DIR}/src/core/args.sh"
source "${SCRIPT_DIR}/src/core/config.sh"
source "${SCRIPT_DIR}/src/system/dependencies.sh"
source "${SCRIPT_DIR}/src/system/lock.sh"
source "${SCRIPT_DIR}/src/system/temp.sh"
source "${SCRIPT_DIR}/src/system/trap.sh"
source "${SCRIPT_DIR}/src/transfer/sftp.sh"
source "${SCRIPT_DIR}/src/workers/counters.sh"
source "${SCRIPT_DIR}/src/split/split_config.sh"
source "${SCRIPT_DIR}/src/split/split_upload_args.sh"
source "${SCRIPT_DIR}/src/split/split_manifest.sh"
source "${SCRIPT_DIR}/src/split/split_worker.sh"

# ============================================================
# split_upload_check_dependencies
# Checks tools required by split_upload.sh beyond the base set.
# ============================================================
split_upload_check_dependencies() {
    local missing=0
    for cmd in sshpass split sha256sum stat; do
        if ! command -v "${cmd}" &>/dev/null; then
            echo "ERROR: Required command not found: ${cmd}" >&2
            (( missing++ )) || true
        fi
    done
    if (( missing > 0 )); then
        echo "ERROR: ${missing} required command(s) missing. Aborting." >&2
        exit 1
    fi
}

# ============================================================
# split_upload_print_summary
# Prints the final summary for a split_upload.sh run.
# ============================================================
split_upload_print_summary() {
    local source_file="$1"
    local original_size="$2"
    local original_hash="$3"
    local part_count="$4"
    local sftp_manifest_path="$5"

    log "INFO" "============================================================"
    log "INFO" "Split Upload Summary"
    log "INFO" "============================================================"
    log "INFO" "  Source file     : ${source_file}"
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
# split_upload_main
# Main entry point for split_upload.sh.
# ============================================================
split_upload_main() {
    # ---- Preserve staging on failure so re-runs can resume ----
    SPLIT_PRESERVE_ON_FAILURE=true

    # ---- Parse CLI args ----
    split_upload_parse_args "$@"

    # ---- Resolve config file (split.transfer.conf → transfer.conf) ----
    resolve_split_config

    # ---- Load config ----
    load_config "" "sftp_only"
    apply_split_defaults
    validate_split_config

    # ---- Apply CLI overrides ----
    [[ -n "${UPLOAD_CLI_WORKERS:-}"  ]] && SPLIT_PART_WORKERS="${UPLOAD_CLI_WORKERS}"
    [[ -n "${UPLOAD_CLI_TEMP_DIR:-}" ]] && SPLIT_TEMP_DIR="${UPLOAD_CLI_TEMP_DIR}"
    [[ "${UPLOAD_CLI_VERBOSE:-false}" == true ]] && CLI_VERBOSE=true

    # ---- Resolve TEMP_DIR ----
    if [[ -n "${SPLIT_TEMP_DIR:-}" ]]; then
        TEMP_DIR="${SPLIT_TEMP_DIR}"
    fi

    # ---- Setup ----
    setup_temp_dir
    setup_logging
    acquire_lock
    split_upload_check_dependencies

    # ---- Validate source file ----
    local source_file="${UPLOAD_CLI_SOURCE_FILE}"
    if [[ ! -f "${source_file}" ]]; then
        log "ERROR" "Source file not found: ${source_file}"
        exit 1
    fi
    if [[ ! -r "${source_file}" ]]; then
        log "ERROR" "Source file is not readable: ${source_file}"
        exit 1
    fi

    local filename
    filename=$(basename "${source_file}")

    # ---- Derive SFTP destination paths ----
    # Normalise remote_path: strip trailing slash, ensure leading slash
    local remote_path="${UPLOAD_CLI_REMOTE_PATH:-}"
    remote_path="${remote_path%/}"   # strip trailing slash
    if [[ -n "${remote_path}" ]] && [[ "${remote_path:0:1}" != "/" ]]; then
        remote_path="/${remote_path}"
    fi
    # sftp_base_dir: bucket root + optional subpath (no trailing slash)
    local sftp_base_dir="${SFTP_REMOTE_DIR%/}${remote_path}"
    local sftp_manifest_path="${sftp_base_dir}/${filename}.manifest"
    local sftp_parts_dir="${sftp_base_dir}/${SPLIT_PARTS_SUBDIR}"

    # ---- Per-job staging directory ----
    SPLIT_JOB_DIR="${TEMP_DIR}/${filename}"
    mkdir -p "${SPLIT_JOB_DIR}"
    local parts_dir="${SPLIT_JOB_DIR}/parts"
    mkdir -p "${parts_dir}"

    local part_prefix="${filename}.part."
    local hash_out_file="${SPLIT_JOB_DIR}/${filename}.sha256"
    local parts_meta_file="${SPLIT_JOB_DIR}/${filename}.partsmeta"
    local local_manifest="${SPLIT_JOB_DIR}/${filename}.manifest"

    # Convert SPLIT_SIZE to bytes for the manifest
    local part_size_bytes
    part_size_bytes=$(python3 -c "
import re, sys
s = '${SPLIT_SIZE}'.strip().lower()
m = re.fullmatch(r'([0-9]+)([kmg]?)', s)
if not m:
    sys.exit(1)
n, u = int(m.group(1)), m.group(2)
mult = {'': 1, 'k': 1024, 'm': 1024**2, 'g': 1024**3}.get(u, 1)
print(n * mult)
" 2>/dev/null) || {
        log "ERROR" "Could not parse SPLIT_SIZE='${SPLIT_SIZE}' to bytes"
        exit 1
    }

    log "INFO" "split_upload.sh starting"
    log "INFO" "  Source file   : ${source_file}"
    log "INFO" "  SFTP dest     : ${sftp_base_dir}/"
    log "INFO" "  Part size     : ${SPLIT_SIZE} (${part_size_bytes} bytes)"
    log "INFO" "  Workers       : ${SPLIT_PART_WORKERS}"
    log "INFO" "  Job dir       : ${SPLIT_JOB_DIR}"

    # ---- Resume detection ----
    local original_size original_sha256
    local existing_part_count
    existing_part_count=$(find "${parts_dir}" -maxdepth 1 -name "${part_prefix}*" 2>/dev/null | wc -l)

    if [[ -f "${local_manifest}" ]] && (( existing_part_count > 0 )); then
        # ---- RESUME MODE ----
        log "INFO" "Resuming from existing local staging — skipping split"
        log "INFO" "  Local manifest : ${local_manifest}"
        log "INFO" "  Parts found    : ${existing_part_count}"
        read_manifest "${local_manifest}"
        original_size="${MANIFEST_ORIGINAL_SIZE}"
        original_sha256="${MANIFEST_ORIGINAL_SHA256}"
        SPLIT_PART_COUNT="${MANIFEST_PART_COUNT}"

        # Rebuild upload queue from parts still present locally
        local queue_file="${SPLIT_JOB_DIR}/split_part_queue.txt"
        : > "${queue_file}"
        local queued_count=0
        while IFS= read -r partfile; do
            echo "$(basename "${partfile}")" >> "${queue_file}"
            (( queued_count++ )) || true
        done < <(find "${parts_dir}" -maxdepth 1 -name "${part_prefix}*" | sort)
        log "INFO" "  Queue rebuilt  : ${queued_count} part(s) remaining to upload"

    else
        # ---- FULL / PARTIAL MODE ----
        # In both cases the source file is read in-place from its original path.

        original_size=$(stat -c '%s' "${source_file}")

        # ---- Step 4: Concurrent sha256 + split ----
        split_run_concurrent_hash_and_split \
            "${source_file}" \
            "${parts_dir}" \
            "${part_prefix}" \
            "${part_size_bytes}" \
            "${SPLIT_SUFFIX_LENGTH}" \
            "${hash_out_file}"

        original_sha256=$(awk '{print $1}' "${hash_out_file}")
        log "INFO" "Source file sha256: ${original_sha256}"

        # ---- Step 5: Collect per-part metadata ----
        split_collect_part_metadata \
            "${parts_dir}" \
            "${part_prefix}" \
            "${parts_meta_file}"

        # ---- Step 6: Write manifest ----
        write_manifest \
            "${local_manifest}" \
            "${source_file}" \
            "${filename}" \
            "${original_size}" \
            "${original_sha256}" \
            "${part_size_bytes}" \
            "${SPLIT_PART_COUNT}" \
            "${part_prefix}" \
            "${sftp_parts_dir}" \
            "${parts_meta_file}"

        # ---- Step 6b: Read manifest into memory ----
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
        log "ERROR" "Split upload completed with failures — ${SPLIT_CNT_FAILED} failed, ${SPLIT_CNT_ERRORS} errors"
        log "ERROR" "Re-run split_upload.sh with the same arguments to resume"
        split_upload_print_summary \
            "${source_file}" "${original_size}" "${original_sha256}" \
            "${SPLIT_PART_COUNT}" "${sftp_manifest_path}"
        exit 1
    fi

    # ---- Step 11: Optionally delete source file ----
    if [[ "${UPLOAD_CLI_DELETE:-false}" == "true" ]]; then
        log "INFO" "Deleting source file after successful upload: ${source_file}"
        rm -f "${source_file}"
        log "INFO" "Source file deleted: ${source_file}"
    fi

    # ---- Summary ----
    split_upload_print_summary \
        "${source_file}" "${original_size}" "${original_sha256}" \
        "${SPLIT_PART_COUNT}" "${sftp_manifest_path}"

    # ---- Allow cleanup on success ----
    SPLIT_PRESERVE_ON_FAILURE=false

    log "INFO" "split_upload.sh complete — all ${SPLIT_PART_COUNT} parts uploaded and verified"
}

split_upload_main "$@"