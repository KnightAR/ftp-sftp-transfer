#!/usr/bin/env bash
# ============================================================
# split_restore.sh — Large-File Split Download & Reassemble
#
# Downloads all parts of a split file from SFTP, streams them
# into the reassembled output file in strict order (minimising
# peak disk usage), and verifies the final sha256 against the
# manifest.
#
# Usage:
#   ./split_restore.sh <manifest_path> [OPTIONS]
#
# Positional:
#   manifest_path   SFTP path of the .manifest file (required)
#
# Options:
#   -o OUTPUT       Local path to write the reassembled file
#                   (required unless -V / --verify-only)
#   -c CONFIG       Config file path (default: transfer.conf)
#   -p WORKERS      Parallel download workers (default: 10)
#   -t TEMP_DIR     Override temp directory
#   -V              Verify-only — download + verify parts without
#                   assembling output file (checks SFTP integrity)
#   -v              Verbose / debug logging
#   -h              Show this help
#
# Pipeline:
#   1. Load config + validate
#   2. Check dependencies (sshpass, sha256sum, stat)
#   3. Download manifest from SFTP and parse it
#   4. Build restore_part_queue.txt (all part filenames in order)
#   5. Create parts staging directory
#   6. Start restore_commit_thread() as a background process
#   7. Spawn N restore_download_worker() processes in parallel
#   8. Wait for all download workers to finish
#   9. Wait for commit thread to finish (join)
#  10. Verify final output file sha256 against MANIFEST_ORIGINAL_SHA256
#  11. Print summary
#
# Disk usage (streaming benefit):
#   Peak ≈ output_file_growing + (SPLIT_RESTORE_WORKERS × part_size)
#   Example: 140 GB file, 1 GB parts, 4 workers → peak ≈ 144 GB
#   Compare to naive approach: peak ≈ 280 GB (all parts + output)
#
# Verify-only mode (-V):
#   Downloads and sha256-checks every part without writing output.
#   Useful for verifying SFTP storage integrity after split_transfer.
#   No OUTPUT path required; RESTORE_VERIFY_ONLY=true is set.
#
# Reuses modules from src/ (same config, logging, sftp, lock,
# temp, trap infrastructure as transfer.sh and split_transfer.sh).
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
source "${SCRIPT_DIR}/src/transfer/sftp.sh"
source "${SCRIPT_DIR}/src/workers/counters.sh"
source "${SCRIPT_DIR}/src/split/split_config.sh"
source "${SCRIPT_DIR}/src/split/restore_args.sh"
source "${SCRIPT_DIR}/src/split/split_manifest.sh"
source "${SCRIPT_DIR}/src/split/restore_worker.sh"
source "${SCRIPT_DIR}/src/split/restore_commit.sh"

# ============================================================
# restore_check_dependencies
# Checks tools required by split_restore.sh.
# ============================================================
restore_check_dependencies() {
    local missing=()
    for cmd in sshpass sha256sum stat; do
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
# restore_download_manifest SFTP_MANIFEST_PATH LOCAL_MANIFEST_PATH
# Downloads the manifest file from SFTP.
# ============================================================
restore_download_manifest() {
    local sftp_manifest_path="$1"
    local local_manifest_path="$2"

    log "INFO" "Downloading manifest: ${sftp_manifest_path}"

    if ! SSHPASS="${SFTP_PASS}" sshpass -e sftp \
            -P "${SFTP_PORT}" \
            -o StrictHostKeyChecking=no \
            -o BatchMode=no \
            -o ConnectTimeout=30 \
            -o LogLevel=ERROR \
            -b <(printf 'get %s %s\n' "${sftp_manifest_path}" "${local_manifest_path}") \
            "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
        log "ERROR" "Failed to download manifest from SFTP: ${sftp_manifest_path}"
        return 1
    fi

    if [[ ! -f "${local_manifest_path}" ]]; then
        log "ERROR" "Manifest download completed but file not found: ${local_manifest_path}"
        return 1
    fi

    log "INFO" "Manifest downloaded OK: ${local_manifest_path}"
}

# ============================================================
# restore_build_queue
# Reads the MANIFEST_PART_SIZE associative array (populated by read_manifest())
# to build the ordered list of part filenames and writes them to
# TEMP_DIR/restore_part_queue.txt (one per line, sorted numerically).
# Using the manifest array keys guarantees the queue exactly matches what was
# recorded at split time — no counter arithmetic, no off-by-one risk.
# Also creates the restore_status and workers directories.
# ============================================================
restore_build_queue() {
    local queue_file="${RESTORE_JOB_DIR}/restore_part_queue.txt"
    : > "${queue_file}"

    mkdir -p "${RESTORE_JOB_DIR}/restore_status"
    mkdir -p "${RESTORE_JOB_DIR}/workers"

    # Build queue directly from the manifest's [parts] section.
    # MANIFEST_PART_SIZE keys are the authoritative part names in the exact
    # format they were written — sorted numerically to guarantee reassembly order.
    local partname
    local queued=0
    for partname in $(echo "${!MANIFEST_PART_SIZE[@]}" | tr ' ' '\n' | sort); do
        echo "${partname}" >> "${queue_file}"
        (( queued++ )) || true
    done

    log "INFO" "Download queue built: ${queued} parts"
}

# ============================================================
# restore_run_download_workers PARTS_STAGING_DIR SFTP_PARTS_DIR NUM_WORKERS
# Spawns NUM_WORKERS restore_download_worker() processes in parallel.
# Waits for all to finish.
# ============================================================
restore_run_download_workers() {
    local parts_staging_dir="$1"
    local sftp_parts_dir="$2"
    local num_workers="$3"

    log "INFO" "Spawning ${num_workers} download worker(s)"
    local pids=()
    local i
    for (( i=1; i<=num_workers; i++ )); do
        restore_download_worker "${i}" "${parts_staging_dir}" "${sftp_parts_dir}" &
        pids+=($!)
        log "DEBUG" "  Worker ${i} PID=${pids[-1]}"
    done

    log "DEBUG" "Waiting for all download workers to finish..."
    local rc=0
    for pid in "${pids[@]}"; do
        wait "${pid}" || rc=1
    done

    if (( rc != 0 )); then
        log "WARN" "One or more download workers exited with non-zero status"
    fi

    merge_restore_download_results
    log "INFO" "Download workers done — verified=${RESTORE_CNT_VERIFIED} skipped=${RESTORE_CNT_SKIPPED} failed=${RESTORE_CNT_FAILED} errors=${RESTORE_CNT_ERRORS}"
}

# ============================================================
# restore_verify_output OUTPUT_FILE
# Computes sha256 of the assembled output file and compares
# against MANIFEST_ORIGINAL_SHA256.
# Returns 0 on match, 1 on mismatch.
# ============================================================
restore_verify_output() {
    local output_file="$1"
    local output_size
    output_size=$(stat -c '%s' "${output_file}" 2>/dev/null || echo 0)

    log "INFO" "Verifying assembled file..."
    log "INFO" "  Expected size   : ${MANIFEST_ORIGINAL_SIZE} bytes"
    log "INFO" "  Actual size     : ${output_size} bytes"

    if [[ "${output_size}" != "${MANIFEST_ORIGINAL_SIZE}" ]]; then
        log "ERROR" "Output file size mismatch (expected=${MANIFEST_ORIGINAL_SIZE}, got=${output_size})"
        return 1
    fi

    log "INFO" "Computing sha256 of output file (this may take a moment for large files)..."
    local actual_hash
    actual_hash=$(sha256sum "${output_file}" 2>/dev/null | awk '{print $1}')

    if [[ "${actual_hash}" != "${MANIFEST_ORIGINAL_SHA256}" ]]; then
        log "ERROR" "Output file sha256 mismatch"
        log "ERROR" "  Expected: ${MANIFEST_ORIGINAL_SHA256}"
        log "ERROR" "  Actual  : ${actual_hash}"
        return 1
    fi

    log "INFO" "Output file verified OK — sha256=${actual_hash}"
    return 0
}

# ============================================================
# restore_print_summary
# Prints the final summary for a restore run.
# ============================================================
restore_print_summary() {
    local output_file="${1:-N/A (verify-only)}"
    local verify_status="$2"

    log "INFO" "============================================================"
    log "INFO" "Split Restore Summary"
    log "INFO" "============================================================"
    log "INFO" "  Manifest        : ${RESTORE_CLI_MANIFEST}"
    log "INFO" "  Original file   : ${MANIFEST_ORIGINAL_FILENAME}"
    log "INFO" "  Original size   : ${MANIFEST_ORIGINAL_SIZE} bytes"
    log "INFO" "  Parts total     : ${MANIFEST_PART_COUNT}"
    log "INFO" "  Download workers: ${SPLIT_RESTORE_WORKERS}"
    log "INFO" "  Verified        : ${RESTORE_CNT_VERIFIED}"
    log "INFO" "  Skipped (resume): ${RESTORE_CNT_SKIPPED}"
    log "INFO" "  Failed          : ${RESTORE_CNT_FAILED}"
    log "INFO" "  Errors          : ${RESTORE_CNT_ERRORS}"
    log "INFO" "  Output file     : ${output_file}"
    log "INFO" "  Final verify    : ${verify_status}"
    log "INFO" "============================================================"
}

# ============================================================
# restore_main
# Main entry point for split_restore.sh.
# ============================================================
restore_main() {
    # ---- Preserve staging on failure so re-runs can resume ----
    # trap_cleanup() checks this flag and skips cleanup_temp() on non-zero exit.
    # We call cleanup_temp() explicitly below only after full success.
    RESTORE_PRESERVE_ON_FAILURE=true

    # ---- Parse CLI args ----
    restore_parse_args "$@"

    # ---- Load and validate config ----
    # "sftp-only" skips FTP credential validation — restore only needs SFTP.
    load_config "${RESTORE_CLI_CONFIG}" "sftp-only"
    apply_split_defaults
    validate_split_config

    # Override settings from CLI flags if provided
    [[ -n "${RESTORE_CLI_WORKERS}"  ]] && SPLIT_RESTORE_WORKERS="${RESTORE_CLI_WORKERS}"
    # -t flag overrides SPLIT_TEMP_DIR from config
    [[ -n "${RESTORE_CLI_TEMP_DIR}" ]] && SPLIT_TEMP_DIR="${RESTORE_CLI_TEMP_DIR}"

    # split_restore.sh requires a static temp directory — no mktemp fallback.
    # A static path ensures staging survives a failed run for resume on re-run.
    if [[ -z "${SPLIT_TEMP_DIR:-}" ]]; then
        echo "ERROR: SPLIT_TEMP_DIR is not set. Set it in transfer.conf or use -t." >&2
        echo "       A static path is required so staging survives failures for resume." >&2
        exit 1
    fi
    TEMP_DIR="${SPLIT_TEMP_DIR}"

    # Set verify-only mode from CLI flag
    RESTORE_VERIFY_ONLY="${RESTORE_CLI_VERIFY:-false}"

    # Derive default output path from manifest basename if -o was not given.
    # /some/dir/blockchain.tar.xz.manifest  →  <cwd>/blockchain.tar.xz
    if [[ -z "${RESTORE_CLI_OUTPUT}" ]] && [[ "${RESTORE_VERIFY_ONLY}" != "true" ]]; then
        local manifest_basename
        manifest_basename=$(basename "${RESTORE_CLI_MANIFEST}")
        RESTORE_CLI_OUTPUT="${PWD}/${manifest_basename%.manifest}"
    fi

    # ---- Setup (order matters: temp dir must exist before logging) ----
    setup_temp_dir
    setup_logging
    acquire_lock
    restore_check_dependencies

    log "INFO" "split_restore.sh ${SCRIPT_VERSION} starting"
    log "INFO" "  Manifest   : ${RESTORE_CLI_MANIFEST}"
    if [[ "${RESTORE_VERIFY_ONLY}" == "true" ]]; then
        log "INFO" "  Mode       : verify-only (no output file)"
    else
        log "INFO" "  Output     : ${RESTORE_CLI_OUTPUT}"
    fi
    log "INFO" "  Workers    : ${SPLIT_RESTORE_WORKERS}"

    # ---- Step 1: Download and parse manifest ----
    # Per-job directory scoped by manifest basename (minus .manifest suffix),
    # with .restore appended to avoid collision with a concurrent split_transfer
    # job for the same file.  e.g. blockchain.tar.xz.manifest → blockchain.tar.xz.restore/
    local manifest_basename
    manifest_basename=$(basename "${RESTORE_CLI_MANIFEST}" .manifest)
    RESTORE_JOB_DIR="${TEMP_DIR}/${manifest_basename}.restore"
    mkdir -p "${RESTORE_JOB_DIR}"
    local parts_dir="${RESTORE_JOB_DIR}/parts"
    mkdir -p "${parts_dir}"

    local local_manifest="${RESTORE_JOB_DIR}/manifest"
    restore_download_manifest "${RESTORE_CLI_MANIFEST}" "${local_manifest}"
    read_manifest "${local_manifest}"
    verify_manifest_header

    log "INFO" "Manifest parsed:"
    log "INFO" "  Original file : ${MANIFEST_ORIGINAL_FILENAME}"
    log "INFO" "  Original size : ${MANIFEST_ORIGINAL_SIZE} bytes"
    log "INFO" "  Part count    : ${MANIFEST_PART_COUNT}"
    log "INFO" "  Part prefix   : ${MANIFEST_PART_PREFIX}"
    log "INFO" "  SFTP parts dir: ${MANIFEST_SFTP_PARTS_DIR}"

    # ---- Step 2: Build download queue ----
    restore_build_queue

    # ---- Step 3: Start commit thread in background ----
    local output_file="${RESTORE_CLI_OUTPUT:-/dev/null}"
    restore_commit_thread "${output_file}" "${parts_dir}" &
    local commit_pid=$!
    log "DEBUG" "Commit thread PID=${commit_pid}"

    # ---- Step 4: Run download workers in parallel ----
    restore_run_download_workers \
        "${parts_dir}" \
        "${MANIFEST_SFTP_PARTS_DIR}" \
        "${SPLIT_RESTORE_WORKERS}"

    # ---- Step 5: Wait for commit thread to finish ----
    log "INFO" "Waiting for commit thread to finish..."
    if ! wait_for_commit_thread 7200; then
        log "ERROR" "Commit thread failed — restore incomplete"
        restore_print_summary "${output_file}" "FAILED"
        exit 1
    fi
    # Reap the commit thread process
    wait "${commit_pid}" 2>/dev/null || true

    # ---- Step 6: Check for download failures ----
    if (( RESTORE_CNT_FAILED > 0 || RESTORE_CNT_ERRORS > 0 )); then
        log "ERROR" "Restore completed with failures — ${RESTORE_CNT_FAILED} failed, ${RESTORE_CNT_ERRORS} errors"
        log "ERROR" "Re-run split_restore.sh with the same arguments to resume"
        restore_print_summary "${output_file}" "FAILED"
        exit 1
    fi

    # ---- Step 7: Verify assembled output file (non-verify-only mode) ----
    local verify_status="OK"
    if [[ "${RESTORE_VERIFY_ONLY}" != "true" ]]; then
        if ! restore_verify_output "${output_file}"; then
            log "ERROR" "Final output file verification failed"
            restore_print_summary "${output_file}" "HASH MISMATCH"
            exit 1
        fi
    else
        log "INFO" "Verify-only mode — skipping final assembly check"
    fi

    # ---- Summary ----
    if [[ "${RESTORE_VERIFY_ONLY}" == "true" ]]; then
        restore_print_summary "N/A (verify-only)" "${verify_status}"
    else
        restore_print_summary "${output_file}" "${verify_status}"
    fi

    # ---- Allow cleanup on success ----
    # On any earlier failure path we exited before reaching here, so the job
    # directory is preserved by trap_cleanup() (RESTORE_PRESERVE_ON_FAILURE=true)
    # for re-run resume.  Clear the flag now so the EXIT trap's
    # cleanup_job_dir() call removes RESTORE_JOB_DIR normally.
    RESTORE_PRESERVE_ON_FAILURE=false

    log "INFO" "split_restore.sh complete"
}

restore_main "$@"