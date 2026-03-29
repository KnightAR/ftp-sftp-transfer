#!/usr/bin/env bash
# ============================================================
# repack_zpaq.sh — Recompress .zpaq Archives to .bz2 and Upload to SFTP
#
# Reads one or more .zpaq archives (including multipart archives via
# "???????" glob patterns), extracts every stored file using zpaqfranz,
# recompresses each file to .bz2 using pbzip2, and uploads the result
# to an SFTP server.
#
# Internal subpaths are preserved verbatim from the zpaq listing:
#   slim/vxtl_helium_20231101.sql  →  <output_dir>/slim/vxtl_helium_20231101.sql.bz2
#                                  →  <SFTP_REMOTE_DIR>/slim/vxtl_helium_20231101.sql.bz2
#
# Concurrency model:
#   Three overlapping background workers connected by filesystem queues:
#     Extract worker  — zpaqfranz x to ramdisk/disk (multithreaded)
#     Compress worker — pbzip2 from extracted file (multithreaded)
#     Upload worker   — SFTP atomic put+verify+rename (I/O bound)
#
# Thread allocation:
#   THREADS_FIRST_EXTRACT = nproc - 1   (burst, first extraction only)
#   THREADS_PIPELINE      = floor((nproc-1)/2)  (steady state, shared)
#   pbzip2 uses THREADS_PIPELINE via -p flag
#
# Ramdisk:
#   A tmpfs is mounted at ZPAQ_TEMP_DIR/ramdisk/ sized at MemAvailable/2.
#   Files that fit within available headroom are extracted there (faster I/O).
#   Falls back to ZPAQ_TEMP_DIR/disk/ if ramdisk is unavailable or full.
#
# Skip logic (no overwrite):
#   1. Remote file already exists on SFTP → skip entirely
#   2. Local .bz2 + .sha256 already exist → skip extract+compress, upload directly
#   3. Otherwise → extract → compress → upload
#
# Version : 2.0.0
# Requires: zpaqfranz, pbzip2, sha256sum, sshpass, sftp, sudo (for mount)
#
# Usage:
#   ./repack_zpaq.sh [OPTIONS] <archive.zpaq|'pattern???????.zpaq'> [...]
#
# Options:
#   -c FILE     Config file                           (default: transfer.conf)
#   -u USER     SFTP username override
#   -p PASS     SFTP password override
#   -o DIR      Local output directory for .bz2 files (default: ./repack_output)
#   -r DIR      Remote SFTP base directory override   (default: SFTP_REMOTE_DIR from config)
#   -b N        pbzip2 block size in 100KB steps      (default: 100 = 10MB)
#   -m N        pbzip2 memory limit in MB             (default: 2000)
#   -dry-run    Show what would happen; make no changes
#   -v          Verbose / DEBUG logging
#   -h          Show this help
#
# Config file variables (transfer.conf):
#   SFTP_HOST, SFTP_PORT, SFTP_USER, SFTP_PASS, SFTP_REMOTE_DIR
#   ZPAQ_TEMP_DIR           (temp/ramdisk root; default: /tmp/repack_<user>)
#   REPACK_OUTPUT_DIR       (default: ./repack_output)
#   REPACK_REMOTE_DIR       (overrides SFTP_REMOTE_DIR for repack uploads)
#   REPACK_PBZIP2_BLOCK     (default: 100)
#   REPACK_PBZIP2_MEMORY    (default: 2000)
#
# Lock file:  <output_dir>/repack_zpaq.sh.lock
# Log file:   <output_dir>/logs/repack_<timestamp>.log
# ============================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ============================================================
# Source modules
# ============================================================
# shellcheck source=src/core/logging.sh
source "${SCRIPT_DIR}/src/core/logging.sh"
# shellcheck source=src/zpaq/zpaq_utils.sh
source "${SCRIPT_DIR}/src/zpaq/zpaq_utils.sh"
# shellcheck source=src/zpaq/zpaq_sftp_ops.sh
source "${SCRIPT_DIR}/src/zpaq/zpaq_sftp_ops.sh"
# shellcheck source=src/zpaq/zpaq_repack_ops.sh
source "${SCRIPT_DIR}/src/zpaq/zpaq_repack_ops.sh"

# ============================================================
# Script globals
# ============================================================
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# CLI options
CLI_CONFIG="${SCRIPT_DIR}/transfer.conf"
CLI_USER=""
CLI_PASS=""
CLI_OUTPUT_DIR=""
CLI_REMOTE_DIR=""
CLI_PBZIP2_BLOCK=0
CLI_PBZIP2_MEMORY=0
CLI_DRY_RUN=false
CLI_VERBOSE=false

# Positional arguments
ARG_ARCHIVES=()

# Runtime state
LOCK_FD=200
LOCK_FILE=""
LOG_FILE=""
ERROR_LOG_FILE=""

# Temp / ramdisk paths
REPACK_TEMP_DIR=""
RAMDISK_PATH=""
RAMDISK_AVAILABLE="false"
RAMDISK_CAP_BYTES=0

# Queue layout
REPACK_QUEUE_DIR=""

# Worker PIDs
EXTRACT_WORKER_PID=""
COMPRESS_WORKER_PID=""
UPLOAD_WORKER_PID=""

# Thread counts (calculated in calc_threads)
THREADS_FIRST_EXTRACT=1
THREADS_PIPELINE=1

# Resolved config values
PBZIP2_BLOCK=""
PBZIP2_MEMORY=""
REPACK_OUTPUT_DIR=""
REPACK_REMOTE_DIR_RESOLVED=""
REPACK_VERIFY_DIR=""

# Stats
STAT_TOTAL=0
STAT_SKIPPED_REMOTE=0
STAT_SKIPPED_LOCAL=0
STAT_ENQUEUED_EXTRACT=0
STAT_ENQUEUED_UPLOAD=0
STAT_FAILED_LIST=0

# ============================================================
# usage
# ============================================================
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <archive.zpaq> [<archive.zpaq> ...]

Extracts files from .zpaq archives, recompresses to .bz2, uploads to SFTP.
Subpaths inside the archive are preserved. Multipart archives via glob:
  ${SCRIPT_NAME} 'vxtl_helium???????.zpaq'

Options:
  -c FILE     Config file                           (default: transfer.conf)
  -u USER     SFTP username override
  -p PASS     SFTP password override
  -o DIR      Local output directory for .bz2 files (default: ./repack_output)
  -r DIR      Remote SFTP base directory override   (default: SFTP_REMOTE_DIR)
  -b N        pbzip2 block size in 100KB steps      (default: 100 = 10MB)
  -m N        pbzip2 memory limit in MB             (default: 2000)
  -dry-run    Show what would happen; make no changes
  -v          Verbose / DEBUG output
  -h          Show this help and exit

Config: SFTP_HOST, SFTP_PORT, SFTP_USER, SFTP_PASS, SFTP_REMOTE_DIR,
        ZPAQ_TEMP_DIR, REPACK_OUTPUT_DIR, REPACK_REMOTE_DIR,
        REPACK_PBZIP2_BLOCK, REPACK_PBZIP2_MEMORY
EOF
}

# ============================================================
# Argument parsing
# ============================================================
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -c)         CLI_CONFIG="$2";        shift 2 ;;
            -u)         CLI_USER="$2";           shift 2 ;;
            -p)         CLI_PASS="$2";           shift 2 ;;
            -o)         CLI_OUTPUT_DIR="$2";     shift 2 ;;
            -r)         CLI_REMOTE_DIR="$2";     shift 2 ;;
            -b)         CLI_PBZIP2_BLOCK="$2";   shift 2 ;;
            -m)         CLI_PBZIP2_MEMORY="$2";  shift 2 ;;
            -dry-run)   CLI_DRY_RUN=true;        shift   ;;
            -v)         CLI_VERBOSE=true;         shift   ;;
            -h|--help)  usage; exit 0            ;;
            -*)
                echo "ERROR: Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
            *)
                ARG_ARCHIVES+=("$1")
                shift
                ;;
        esac
    done

    if (( ${#ARG_ARCHIVES[@]} == 0 )); then
        echo "ERROR: At least one <archive.zpaq> argument is required." >&2
        usage >&2
        exit 1
    fi
}

# ============================================================
# Config loading
# ============================================================
load_repack_config() {
    if [[ -f "${CLI_CONFIG}" ]]; then
        local perms
        perms=$(stat -c "%a" "${CLI_CONFIG}")
        if [[ "${perms}" != "600" && "${perms}" != "400" ]]; then
            echo "WARNING: Config file '${CLI_CONFIG}' has permissions ${perms}. Credentials may be exposed. Run: chmod 600 '${CLI_CONFIG}'" >&2
        fi
        # shellcheck source=/dev/null
        source "${CLI_CONFIG}"
    else
        echo "WARNING: Config file not found: ${CLI_CONFIG} — using built-in defaults only" >&2
    fi

    # CLI overrides
    [[ -n "${CLI_USER}" ]] && SFTP_USER="${CLI_USER}"
    [[ -n "${CLI_PASS}" ]] && SFTP_PASS="${CLI_PASS}"

    # SFTP defaults
    : "${SFTP_HOST:=}"
    : "${SFTP_PORT:=22}"
    : "${SFTP_USER:=}"
    : "${SFTP_PASS:=}"
    : "${SFTP_REMOTE_DIR:=}"

    # Repack defaults
    : "${REPACK_OUTPUT_DIR:=./repack_output}"
    : "${REPACK_REMOTE_DIR:=}"
    : "${REPACK_PBZIP2_BLOCK:=100}"
    : "${REPACK_PBZIP2_MEMORY:=2000}"

    # Temp dir — shared with storezpaq_multi.sh
    : "${ZPAQ_TEMP_DIR:=}"

    # Logging
    : "${LOG_DIR:=}"
    : "${LOG_RETENTION_DAYS:=30}"

    # CLI overrides
    [[ -n "${CLI_OUTPUT_DIR}" ]] && REPACK_OUTPUT_DIR="${CLI_OUTPUT_DIR}"
    [[ -n "${CLI_REMOTE_DIR}" ]] && REPACK_REMOTE_DIR="${CLI_REMOTE_DIR}"

    # Resolve remote dir
    if [[ -n "${REPACK_REMOTE_DIR}" ]]; then
        REPACK_REMOTE_DIR_RESOLVED="${REPACK_REMOTE_DIR}"
    else
        REPACK_REMOTE_DIR_RESOLVED="${SFTP_REMOTE_DIR}"
    fi

    # pbzip2 tuning (CLI overrides config)
    if (( CLI_PBZIP2_BLOCK > 0 )); then
        PBZIP2_BLOCK="${CLI_PBZIP2_BLOCK}"
    else
        PBZIP2_BLOCK="${REPACK_PBZIP2_BLOCK}"
    fi

    if (( CLI_PBZIP2_MEMORY > 0 )); then
        PBZIP2_MEMORY="${CLI_PBZIP2_MEMORY}"
    else
        PBZIP2_MEMORY="${REPACK_PBZIP2_MEMORY}"
    fi
}

# ============================================================
# Config validation
# ============================================================
validate_repack_config() {
    local errors=0

    _require_var() {
        local var_name="$1"
        if [[ -z "${!var_name:-}" ]]; then
            echo "ERROR: Required config variable '${var_name}' is not set." >&2
            (( errors++ )) || true
        fi
    }

    _require_var "SFTP_HOST"
    _require_var "SFTP_USER"
    _require_var "SFTP_PASS"
    _require_var "REPACK_REMOTE_DIR_RESOLVED"

    if (( errors > 0 )); then
        echo "ERROR: ${errors} required configuration variable(s) missing." >&2
        exit 1
    fi

    if ! [[ "${SFTP_PORT}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: SFTP_PORT must be a number, got: '${SFTP_PORT}'" >&2; exit 1
    fi
    if ! [[ "${PBZIP2_BLOCK}" =~ ^[0-9]+$ ]] || (( PBZIP2_BLOCK < 1 )); then
        echo "ERROR: pbzip2 block size must be a positive integer, got: '${PBZIP2_BLOCK}'" >&2; exit 1
    fi
    if ! [[ "${PBZIP2_MEMORY}" =~ ^[0-9]+$ ]] || (( PBZIP2_MEMORY < 1 )); then
        echo "ERROR: pbzip2 memory limit must be a positive integer (MB), got: '${PBZIP2_MEMORY}'" >&2; exit 1
    fi
}

# ============================================================
# Thread count calculation
# ============================================================
calc_threads() {
    local nproc_val
    nproc_val=$(nproc 2>/dev/null || echo 1)

    THREADS_FIRST_EXTRACT=$(( nproc_val - 1 ))
    (( THREADS_FIRST_EXTRACT < 1 )) && THREADS_FIRST_EXTRACT=1

    THREADS_PIPELINE=$(( (nproc_val - 1) / 2 ))
    (( THREADS_PIPELINE < 1 )) && THREADS_PIPELINE=1

    log "INFO" "calc_threads: nproc=${nproc_val} first_extract=${THREADS_FIRST_EXTRACT} pipeline=${THREADS_PIPELINE}"
}

# ============================================================
# Logging setup
# ============================================================
setup_repack_logging() {
    local log_dir
    if [[ -n "${LOG_DIR}" ]]; then
        log_dir="${LOG_DIR}"
    else
        log_dir="${REPACK_OUTPUT_DIR}/logs"
    fi
    mkdir -p "${log_dir}"
    LOG_DIR="${log_dir}"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    LOG_FILE="${log_dir}/repack_${timestamp}.log"
    ERROR_LOG_FILE="${log_dir}/repack_errors_$(date '+%Y%m%d').log"
    touch "${LOG_FILE}" "${ERROR_LOG_FILE}"
}

# ============================================================
# Temp / ramdisk / queue directory setup
# ============================================================
setup_temp_dirs() {
    # Root temp dir
    if [[ -n "${ZPAQ_TEMP_DIR}" ]]; then
        REPACK_TEMP_DIR="${ZPAQ_TEMP_DIR}/repack"
    else
        REPACK_TEMP_DIR="/tmp/repack_${USER:-$(id -un)}"
    fi

    # Ramdisk path (under temp dir)
    RAMDISK_PATH="${REPACK_TEMP_DIR}/ramdisk"

    # Stable queue dir (persists across re-runs for resume)
    REPACK_QUEUE_DIR="${REPACK_TEMP_DIR}/queue"

    # Ephemeral verify dir (unique per run)
    mkdir -p "${REPACK_TEMP_DIR}"
    REPACK_VERIFY_DIR=$(mktemp -d "${REPACK_TEMP_DIR}/verify_$$.XXXXXX")

    # Create queue subdirs
    mkdir -p \
        "${REPACK_QUEUE_DIR}/extract" \
        "${REPACK_QUEUE_DIR}/compress" \
        "${REPACK_QUEUE_DIR}/upload" \
        "${REPACK_TEMP_DIR}/disk"

    log "INFO" "setup_temp_dirs: root=${REPACK_TEMP_DIR}"
    log "INFO" "setup_temp_dirs: queue=${REPACK_QUEUE_DIR}"
    log "DEBUG" "setup_temp_dirs: verify=${REPACK_VERIFY_DIR}"
}

# ============================================================
# Lock file
# ============================================================
acquire_repack_lock() {
    LOCK_FILE="${REPACK_OUTPUT_DIR}/${SCRIPT_NAME}.lock"
    eval "exec ${LOCK_FD}>'${LOCK_FILE}'"
    if ! flock -n "${LOCK_FD}"; then
        local existing_pid
        existing_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "unknown")
        log "ERROR" "Another instance of ${SCRIPT_NAME} is already running (PID: ${existing_pid})."
        log "ERROR" "If this is incorrect, remove: ${LOCK_FILE}"
        exit 1
    fi
    echo $$ > "${LOCK_FILE}"
    log "DEBUG" "acquire_repack_lock: acquired ${LOCK_FILE}"
}

release_repack_lock() {
    flock -u "${LOCK_FD}" 2>/dev/null || true
    rm -f "${LOCK_FILE}"
}

# ============================================================
# Cleanup on exit / signal
# ============================================================
trap_cleanup() {
    local exit_code=$?
    log "DEBUG" "trap_cleanup: exit_code=${exit_code}"

    # Signal all workers to stop
    local pid
    for pid in "${EXTRACT_WORKER_PID}" "${COMPRESS_WORKER_PID}" "${UPLOAD_WORKER_PID}"; do
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            # Write sentinels so workers exit their loops cleanly
            touch "${REPACK_QUEUE_DIR}/extract/DONE_SENTINEL" \
                  "${REPACK_QUEUE_DIR}/compress/DONE_SENTINEL" \
                  "${REPACK_QUEUE_DIR}/upload/DONE_SENTINEL" 2>/dev/null || true
            local i=0
            while kill -0 "${pid}" 2>/dev/null && (( i < 10 )); do
                sleep 1; (( i++ )) || true
            done
            kill "${pid}" 2>/dev/null || true
        fi
    done

    # Unmount ramdisk
    ramdisk_umount

    # Remove only the ephemeral verify dir — queue dir is kept for resume
    if [[ -n "${REPACK_VERIFY_DIR}" && -d "${REPACK_VERIFY_DIR}" ]]; then
        rm -rf "${REPACK_VERIFY_DIR}"
        log "DEBUG" "trap_cleanup: removed verify dir"
    fi

    release_repack_lock
}

# ============================================================
# Dependency check
# ============================================================
check_repack_dependencies() {
    local missing=0
    local dep
    for dep in zpaqfranz pbzip2 sha256sum sshpass sftp sudo; do
        if ! command -v "${dep}" &>/dev/null; then
            log "ERROR" "Missing required dependency: ${dep}"
            (( missing++ )) || true
        fi
    done
    if (( missing > 0 )); then
        log "ERROR" "${missing} required dependency/dependencies missing — aborting"
        exit 2
    fi
}

# ============================================================
# Queue resume: seed counter + count leftover items
# ============================================================
resume_queue_state() {
    # Seed _REPACK_QUEUE_COUNTER from the highest existing item number
    # across all three queue subdirs to avoid collisions with leftovers.
    local highest=0
    local qf qnum
    while IFS= read -r -d $'\0' qf; do
        qnum=$(basename "${qf}")
        qnum="${qnum%%.*}"
        if [[ "${qnum}" =~ ^[0-9]+$ ]] && (( 10#${qnum} > highest )); then
            highest=$(( 10#${qnum} ))
        fi
    done < <(find "${REPACK_QUEUE_DIR}" -maxdepth 2 \
                \( -name "*.pending" -o -name "*.queued" \
                   -o -name "*.done"  -o -name "*.failed" \) \
                -print0 2>/dev/null)
    _REPACK_QUEUE_COUNTER="${highest}"
    log "DEBUG" "resume_queue_state: counter seeded to ${_REPACK_QUEUE_COUNTER}"

    # Remove sentinels from prior run so workers don't exit prematurely
    rm -f \
        "${REPACK_QUEUE_DIR}/extract/DONE_SENTINEL" \
        "${REPACK_QUEUE_DIR}/compress/DONE_SENTINEL" \
        "${REPACK_QUEUE_DIR}/upload/DONE_SENTINEL"

    # Report leftover items by queue
    local n_extract n_compress n_upload
    n_extract=$(find "${REPACK_QUEUE_DIR}/extract" -maxdepth 1 -name "*.pending" 2>/dev/null | wc -l)
    n_compress=$(find "${REPACK_QUEUE_DIR}/compress" -maxdepth 1 -name "*.pending" 2>/dev/null | wc -l)
    n_upload=$(find "${REPACK_QUEUE_DIR}/upload"  -maxdepth 1 -name "*.queued"  2>/dev/null | wc -l)

    local total_resumed=$(( n_extract + n_compress + n_upload ))
    if (( total_resumed > 0 )); then
        log "INFO" "Resuming from previous run: ${n_extract} extract, ${n_compress} compress, ${n_upload} upload item(s)"
    fi
}

# ============================================================
# Cleanup completed queue entries after successful run
# ============================================================
cleanup_done_entries() {
    local done_count=0
    local df
    while IFS= read -r -d $'\0' df; do
        rm -f "${df}"
        (( done_count++ )) || true
    done < <(find "${REPACK_QUEUE_DIR}" -maxdepth 2 -name "*.done" -print0 2>/dev/null)
    if (( done_count > 0 )); then
        log "DEBUG" "cleanup_done_entries: removed ${done_count} completed entry/entries"
    fi
}

# ============================================================
# Report failures from queue dirs
# ============================================================
report_failures() {
    local failed_count=0
    local f
    while IFS= read -r -d $'\0' f; do
        (( failed_count++ )) || true
        # Read the failed entry for context
        local zpaq_pattern="" internal_path="" extracted_file="" \
              local_bz2_path="" remote_dir="" remote_name=""
        _read_entry "${f}"
        local context="${internal_path:-${local_bz2_path:-${extracted_file:-${f}}}}"
        log "ERROR" "FAILED entry: ${context} (queue file: $(basename "${f}"))"
    done < <(find "${REPACK_QUEUE_DIR}" -maxdepth 2 -name "*.failed" -print0 2>/dev/null)

    if (( failed_count > 0 )); then
        log "ERROR" "${failed_count} item(s) failed — re-run to retry (remote skip logic will resume)"
        return 1
    fi
    return 0
}

# ============================================================
# Process one file: skip checks, then enqueue to extract (or upload)
# ============================================================
process_one_file() {
    local zpaq_pattern="$1"
    local internal_path="$2"
    local uncompressed_size="$3"

    (( STAT_TOTAL++ )) || true

    local local_bz2_path="${REPACK_OUTPUT_DIR}/${internal_path}.bz2"
    local local_sha256_path="${local_bz2_path}.sha256"

    local remote_subdir remote_name remote_dir
    remote_subdir=$(dirname "${internal_path}")
    remote_name="$(basename "${internal_path}").bz2"
    if [[ "${remote_subdir}" == "." ]]; then
        remote_dir="${REPACK_REMOTE_DIR_RESOLVED}"
    else
        remote_dir="${REPACK_REMOTE_DIR_RESOLVED}/${remote_subdir}"
    fi

    log "INFO" "process_one_file: ${internal_path} (${uncompressed_size} bytes uncompressed)"
    log "DEBUG" "  local:  ${local_bz2_path}"
    log "DEBUG" "  remote: ${remote_dir}/${remote_name}"

    # ------------------------------------------------------------------
    # Skip 1: remote file already exists
    # ------------------------------------------------------------------
    if [[ "${CLI_DRY_RUN}" == false ]]; then
        if remote_file_exists "${remote_dir}" "${remote_name}"; then
            log "INFO" "  SKIP (remote exists): ${remote_dir}/${remote_name}"
            (( STAT_SKIPPED_REMOTE++ )) || true
            return 0
        fi
    else
        log "INFO" "  DRY-RUN: would check remote for ${remote_dir}/${remote_name}"
    fi

    # ------------------------------------------------------------------
    # Skip 2: local .bz2 + .sha256 already exist — enqueue to upload only
    # ------------------------------------------------------------------
    if [[ -f "${local_bz2_path}" && -f "${local_sha256_path}" ]]; then
        log "INFO" "  local .bz2 exists — skipping extract+compress, queuing for upload"
        (( STAT_SKIPPED_LOCAL++ )) || true

        if [[ "${CLI_DRY_RUN}" == true ]]; then
            log "INFO" "  DRY-RUN: would upload ${local_bz2_path}"
            return 0
        fi

        enqueue_upload "${local_bz2_path}" "${local_sha256_path}" "${remote_dir}" "${remote_name}"
        (( STAT_ENQUEUED_UPLOAD++ )) || true
        return 0
    fi

    # ------------------------------------------------------------------
    # Enqueue for extract → compress → upload
    # ------------------------------------------------------------------
    if [[ "${CLI_DRY_RUN}" == true ]]; then
        log "INFO" "  DRY-RUN: would extract '${internal_path}' and compress to ${local_bz2_path}"
        (( STAT_ENQUEUED_EXTRACT++ )) || true
        return 0
    fi

    mkdir -p "$(dirname "${local_bz2_path}")"
    enqueue_extract "${zpaq_pattern}" "${internal_path}" "${uncompressed_size}"
    (( STAT_ENQUEUED_EXTRACT++ )) || true

    return 0
}

# ============================================================
# Main
# ============================================================
main() {
    parse_args "$@"
    load_repack_config

    mkdir -p "${REPACK_OUTPUT_DIR}"
    setup_repack_logging

    log "INFO" "===== ${SCRIPT_NAME} starting ====="
    log "INFO" "archives=${#ARG_ARCHIVES[@]} output=${REPACK_OUTPUT_DIR} remote=${REPACK_REMOTE_DIR_RESOLVED}"
    log "INFO" "pbzip2: block=${PBZIP2_BLOCK}00KB memory=${PBZIP2_MEMORY}MB level=-9"
    log "INFO" "dry-run=${CLI_DRY_RUN}"

    validate_repack_config
    setup_temp_dirs
    trap 'trap_cleanup' EXIT INT TERM
    acquire_repack_lock

    check_repack_dependencies
    detect_zpaqfranz
    calc_threads

    log "INFO" "threads: first_extract=${THREADS_FIRST_EXTRACT} pipeline=${THREADS_PIPELINE}"

    # Export all globals needed by workers launched with &
    export ZPAQFRANZ_BIN
    export SFTP_HOST SFTP_PORT SFTP_USER SFTP_PASS
    export REPACK_QUEUE_DIR REPACK_VERIFY_DIR
    export REPACK_OUTPUT_DIR REPACK_REMOTE_DIR_RESOLVED
    export RAMDISK_PATH RAMDISK_AVAILABLE RAMDISK_CAP_BYTES
    export REPACK_TEMP_DIR
    export THREADS_FIRST_EXTRACT THREADS_PIPELINE
    export PBZIP2_BLOCK PBZIP2_MEMORY
    export LOG_FILE ERROR_LOG_FILE CLI_VERBOSE
    export ZPAQ_TEMP_DIR

    # ------------------------------------------------------------------
    # Mount ramdisk (dry-run skips mount)
    # ------------------------------------------------------------------
    if [[ "${CLI_DRY_RUN}" == false ]]; then
        ramdisk_mount
        # Re-export after ramdisk_mount may have updated these
        export RAMDISK_AVAILABLE RAMDISK_CAP_BYTES
    fi

    # ------------------------------------------------------------------
    # Queue housekeeping: seed counter, remove prior sentinels, report resume
    # ------------------------------------------------------------------
    resume_queue_state

    # ------------------------------------------------------------------
    # Launch three background workers
    # ------------------------------------------------------------------
    if [[ "${CLI_DRY_RUN}" == false ]]; then
        extract_worker &
        EXTRACT_WORKER_PID=$!
        log "INFO" "Extract worker started (PID=${EXTRACT_WORKER_PID})"

        compress_worker &
        COMPRESS_WORKER_PID=$!
        log "INFO" "Compress worker started (PID=${COMPRESS_WORKER_PID})"

        upload_worker &
        UPLOAD_WORKER_PID=$!
        log "INFO" "Upload worker started (PID=${UPLOAD_WORKER_PID})"
    fi

    # ------------------------------------------------------------------
    # Main loop: list each archive and enqueue files
    # ------------------------------------------------------------------
    local zpaq_pattern
    local archive_errors=0

    for zpaq_pattern in "${ARG_ARCHIVES[@]}"; do
        log "INFO" "===== Processing archive: ${zpaq_pattern} ====="

        local file_list="" list_rc=0
        file_list=$(list_zpaq_files "${zpaq_pattern}") || list_rc=$?

        if (( list_rc != 0 )) || [[ -z "${file_list}" ]]; then
            log "ERROR" "Could not list files in ${zpaq_pattern} — skipping"
            (( archive_errors++ )) || true
            (( STAT_FAILED_LIST++ )) || true
            continue
        fi

        local line uncompressed_size internal_path
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            uncompressed_size="${line%%$'\t'*}"
            internal_path="${line#*$'\t'}"
            [[ -z "${internal_path}" ]] && continue
            process_one_file "${zpaq_pattern}" "${internal_path}" "${uncompressed_size}"
        done <<< "${file_list}"

        log "INFO" "===== Archive enqueued: ${zpaq_pattern} ====="
    done

    # ------------------------------------------------------------------
    # Signal extract worker that all files have been enqueued
    # ------------------------------------------------------------------
    if [[ "${CLI_DRY_RUN}" == false ]]; then
        log "INFO" "All archives listed — writing extract/DONE_SENTINEL"
        touch "${REPACK_QUEUE_DIR}/extract/DONE_SENTINEL"

        # Workers propagate sentinels downstream automatically:
        #   extract_worker writes compress/DONE_SENTINEL on exit
        #   compress_worker writes upload/DONE_SENTINEL on exit
        log "INFO" "Waiting for extract worker  (PID=${EXTRACT_WORKER_PID})..."
        wait "${EXTRACT_WORKER_PID}" || true

        log "INFO" "Waiting for compress worker (PID=${COMPRESS_WORKER_PID})..."
        wait "${COMPRESS_WORKER_PID}" || true

        log "INFO" "Waiting for upload worker   (PID=${UPLOAD_WORKER_PID})..."
        wait "${UPLOAD_WORKER_PID}" || true

        log "INFO" "All workers exited"

        cleanup_done_entries
    fi

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    log "INFO" "===== ${SCRIPT_NAME} summary ====="
    log "INFO" "  Total files seen:           ${STAT_TOTAL}"
    log "INFO" "  Skipped (remote exists):    ${STAT_SKIPPED_REMOTE}"
    log "INFO" "  Skipped (local .bz2):       ${STAT_SKIPPED_LOCAL}"
    log "INFO" "  Enqueued for extract:       ${STAT_ENQUEUED_EXTRACT}"
    log "INFO" "  Enqueued for upload only:   ${STAT_ENQUEUED_UPLOAD}"
    log "INFO" "  Archive list failures:      ${STAT_FAILED_LIST}"

    local failures=0
    if [[ "${CLI_DRY_RUN}" == false ]]; then
        report_failures || failures=$?
    fi

    if (( archive_errors > 0 || failures > 0 )); then
        log "ERROR" "===== ${SCRIPT_NAME} finished with errors ====="
        exit 1
    fi

    log "INFO" "===== ${SCRIPT_NAME} finished OK ====="
}

main "$@"