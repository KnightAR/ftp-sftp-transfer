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
# Skip logic (no overwrite):
#   1. If the file already exists on the SFTP remote → skip entirely
#   2. If the local .bz2 already exists on disk → skip compress, upload directly
#   3. Otherwise → extract+compress → upload
#
# Concurrency model:
#   - One compress slot (pbzip2 uses all cores via -p autodetect)
#   - One background upload worker (filesystem queue in temp dir)
#   - Compress and upload overlap: while file N+1 is compressing,
#     file N is uploading in the background
#
# Version : 1.0.0
# Requires: zpaqfranz, pbzip2, sha256sum, sshpass, sftp
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
#   -T N        pbzip2 thread count                   (default: pbzip2 autodetect)
#   -b N        pbzip2 block size in 100KB steps      (default: 100 = 10MB)
#   -m N        pbzip2 memory limit in MB             (default: 2000)
#   -dry-run    Show what would happen; make no changes
#   -v          Verbose / DEBUG logging
#   -h          Show this help
#
# Config file variables (transfer.conf):
#   SFTP_HOST, SFTP_PORT, SFTP_USER, SFTP_PASS, SFTP_REMOTE_DIR
#   REPACK_OUTPUT_DIR       (default: ./repack_output)
#   REPACK_REMOTE_DIR       (overrides SFTP_REMOTE_DIR for repack uploads)
#   REPACK_PBZIP2_BLOCK     (default: 100)
#   REPACK_PBZIP2_MEMORY    (default: 2000)
#
# Lock file:  <output_dir>/<script_name>.lock
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
CLI_PBZIP2_THREADS=0       # 0 = pbzip2 autodetect
CLI_PBZIP2_BLOCK=0         # 0 = use config/default
CLI_PBZIP2_MEMORY=0        # 0 = use config/default
CLI_DRY_RUN=false
CLI_VERBOSE=false

# Positional arguments: input archive patterns
ARG_ARCHIVES=()

# Runtime state
LOCK_FD=200
LOCK_FILE=""
LOG_FILE=""
ERROR_LOG_FILE=""

# Temp directories (set up in setup_temp_dirs)
REPACK_TEMP_DIR=""         # root temp dir for this run
REPACK_QUEUE_DIR=""        # upload queue inbox
REPACK_QUEUE_SENTINEL=""   # sentinel file path (signals queue is closed)
REPACK_VERIFY_DIR=""       # re-download verification files

# Upload worker PID (set after background launch)
UPLOAD_WORKER_PID=""

# Resolved config values (set by load_repack_config)
PBZIP2_BLOCK=""
PBZIP2_MEMORY=""
PBZIP2_THREADS=""
REPACK_OUTPUT_DIR=""
REPACK_REMOTE_DIR_RESOLVED=""

# Stats counters
STAT_TOTAL=0
STAT_SKIPPED_REMOTE=0
STAT_SKIPPED_LOCAL=0
STAT_COMPRESSED=0
STAT_ENQUEUED=0
STAT_FAILED_COMPRESS=0

# ============================================================
# usage
# ============================================================
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <archive.zpaq> [<archive.zpaq> ...]

Extracts files from .zpaq archives, recompresses them to .bz2, and
uploads to SFTP. Subpaths inside the archive are preserved.

Pass multipart archives as a quoted glob pattern:
  ${SCRIPT_NAME} 'vxtl_helium???????.zpaq'

Options:
  -c FILE     Config file                           (default: transfer.conf)
  -u USER     SFTP username override
  -p PASS     SFTP password override
  -o DIR      Local output directory for .bz2 files (default: ./repack_output)
  -r DIR      Remote SFTP base directory override   (default: SFTP_REMOTE_DIR from config)
  -T N        pbzip2 thread count                   (default: autodetect)
  -b N        pbzip2 block size in 100KB steps      (default: 100 = 10MB)
  -m N        pbzip2 memory limit in MB             (default: 2000)
  -dry-run    Show what would happen; make no changes
  -v          Verbose / DEBUG output
  -h          Show this help and exit

Config file variables: SFTP_HOST, SFTP_PORT, SFTP_USER, SFTP_PASS,
                       SFTP_REMOTE_DIR, REPACK_OUTPUT_DIR,
                       REPACK_REMOTE_DIR, REPACK_PBZIP2_BLOCK,
                       REPACK_PBZIP2_MEMORY
EOF
}

# ============================================================
# Argument parsing
# ============================================================
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -c)         CLI_CONFIG="$2";         shift 2 ;;
            -u)         CLI_USER="$2";            shift 2 ;;
            -p)         CLI_PASS="$2";            shift 2 ;;
            -o)         CLI_OUTPUT_DIR="$2";      shift 2 ;;
            -r)         CLI_REMOTE_DIR="$2";      shift 2 ;;
            -T)         CLI_PBZIP2_THREADS="$2";  shift 2 ;;
            -b)         CLI_PBZIP2_BLOCK="$2";    shift 2 ;;
            -m)         CLI_PBZIP2_MEMORY="$2";   shift 2 ;;
            -dry-run)   CLI_DRY_RUN=true;         shift   ;;
            -v)         CLI_VERBOSE=true;          shift   ;;
            -h|--help)  usage; exit 0             ;;
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
    [[ -n "${CLI_USER}" ]]  && SFTP_USER="${CLI_USER}"
    [[ -n "${CLI_PASS}" ]]  && SFTP_PASS="${CLI_PASS}"

    # SFTP connectivity defaults
    : "${SFTP_HOST:=}"
    : "${SFTP_PORT:=22}"
    : "${SFTP_USER:=}"
    : "${SFTP_PASS:=}"
    : "${SFTP_REMOTE_DIR:=}"

    # Repack-specific config with defaults
    : "${REPACK_OUTPUT_DIR:=./repack_output}"
    : "${REPACK_REMOTE_DIR:=}"          # falls back to SFTP_REMOTE_DIR if unset
    : "${REPACK_PBZIP2_BLOCK:=100}"
    : "${REPACK_PBZIP2_MEMORY:=2000}"

    # Logging
    : "${LOG_DIR:=}"
    : "${LOG_RETENTION_DAYS:=30}"

    # CLI overrides for output dir and remote dir
    [[ -n "${CLI_OUTPUT_DIR}" ]]  && REPACK_OUTPUT_DIR="${CLI_OUTPUT_DIR}"
    [[ -n "${CLI_REMOTE_DIR}" ]]  && REPACK_REMOTE_DIR="${CLI_REMOTE_DIR}"

    # Resolve remote dir: CLI/config override, then fall back to SFTP_REMOTE_DIR
    if [[ -n "${REPACK_REMOTE_DIR}" ]]; then
        REPACK_REMOTE_DIR_RESOLVED="${REPACK_REMOTE_DIR}"
    else
        REPACK_REMOTE_DIR_RESOLVED="${SFTP_REMOTE_DIR}"
    fi

    # pbzip2 tuning — CLI flags take priority over config
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

    # pbzip2 thread flag: only pass -p if explicitly requested
    # (default: let pbzip2 autodetect via its own nproc logic)
    if (( CLI_PBZIP2_THREADS > 0 )); then
        PBZIP2_THREADS="${CLI_PBZIP2_THREADS}"
    else
        PBZIP2_THREADS=0   # 0 = autodetect (no -p flag passed to pbzip2)
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
        echo "ERROR: ${errors} required configuration variable(s) missing. Check ${CLI_CONFIG}." >&2
        exit 1
    fi

    if ! [[ "${SFTP_PORT}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: SFTP_PORT must be a number, got: '${SFTP_PORT}'" >&2
        exit 1
    fi

    if ! [[ "${PBZIP2_BLOCK}" =~ ^[0-9]+$ ]] || (( PBZIP2_BLOCK < 1 )); then
        echo "ERROR: pbzip2 block size must be a positive integer, got: '${PBZIP2_BLOCK}'" >&2
        exit 1
    fi

    if ! [[ "${PBZIP2_MEMORY}" =~ ^[0-9]+$ ]] || (( PBZIP2_MEMORY < 1 )); then
        echo "ERROR: pbzip2 memory limit must be a positive integer (MB), got: '${PBZIP2_MEMORY}'" >&2
        exit 1
    fi
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
# Temp directory setup
# ============================================================
setup_temp_dirs() {
    REPACK_TEMP_DIR=$(mktemp -d "/tmp/repack_$$.XXXXXX")
    REPACK_QUEUE_DIR="${REPACK_TEMP_DIR}/upload_queue"
    REPACK_QUEUE_SENTINEL="${REPACK_QUEUE_DIR}/DONE_SENTINEL"
    REPACK_VERIFY_DIR="${REPACK_TEMP_DIR}/verify"

    mkdir -p "${REPACK_QUEUE_DIR}" "${REPACK_VERIFY_DIR}"
    log "DEBUG" "setup_temp_dirs: ${REPACK_TEMP_DIR}"
}

# ============================================================
# Lock file management
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
    log "DEBUG" "release_repack_lock: released"
}

# ============================================================
# Cleanup on exit / signal
# ============================================================
trap_cleanup() {
    local exit_code=$?
    log "DEBUG" "trap_cleanup: exit_code=${exit_code}"

    # Signal upload worker to stop if still running
    if [[ -n "${UPLOAD_WORKER_PID}" ]] && kill -0 "${UPLOAD_WORKER_PID}" 2>/dev/null; then
        # Write sentinel so worker exits its loop cleanly
        touch "${REPACK_QUEUE_SENTINEL}" 2>/dev/null || true
        # Give it a moment to drain, then kill if still running
        local i=0
        while kill -0 "${UPLOAD_WORKER_PID}" 2>/dev/null && (( i < 10 )); do
            sleep 1
            (( i++ )) || true
        done
        kill "${UPLOAD_WORKER_PID}" 2>/dev/null || true
    fi

    # Remove temp directory
    if [[ -n "${REPACK_TEMP_DIR}" && -d "${REPACK_TEMP_DIR}" ]]; then
        rm -rf "${REPACK_TEMP_DIR}"
        log "DEBUG" "trap_cleanup: removed ${REPACK_TEMP_DIR}"
    fi

    release_repack_lock
}

# ============================================================
# Dependency check
# ============================================================
check_repack_dependencies() {
    local missing=0
    local dep
    for dep in zpaqfranz pbzip2 sha256sum sshpass sftp; do
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
# Report upload failures from the queue directory
# ============================================================
report_upload_failures() {
    local failed_count=0
    local f

    while IFS= read -r -d $'\0' f; do
        (( failed_count++ )) || true
        # Read the failed entry to get the remote name for the error message
        # shellcheck disable=SC2034  # item_* vars populated via nameref in _read_queue_entry
        local item_bz2="" item_sha="" item_rdir="" item_rname=""
        _read_queue_entry "${f}" item_bz2 item_sha item_rdir item_rname
        log "ERROR" "Upload FAILED: ${item_rdir}/${item_rname} (local: ${item_bz2})"
    done < <(find "${REPACK_QUEUE_DIR}" -maxdepth 1 -name "*.failed" -print0 2>/dev/null)

    if (( failed_count > 0 )); then
        log "ERROR" "${failed_count} upload(s) failed — re-run to retry (remote skip logic will resume from where it left off)"
        return 1
    fi
    return 0
}

# ============================================================
# Process a single internal file from a zpaq archive
# ============================================================
process_one_file() {
    local zpaq_pattern="$1"
    local internal_path="$2"

    (( STAT_TOTAL++ )) || true

    # Derive local output path: <output_dir>/<internal_path>.bz2
    local local_bz2_path="${REPACK_OUTPUT_DIR}/${internal_path}.bz2"
    local local_sha256_path="${local_bz2_path}.sha256"

    # Derive remote path components
    local remote_subdir remote_name
    remote_subdir=$(dirname "${internal_path}")
    remote_name="$(basename "${internal_path}").bz2"

    # Build remote directory: REPACK_REMOTE_DIR_RESOLVED + subdir if any
    local remote_dir
    if [[ "${remote_subdir}" == "." ]]; then
        remote_dir="${REPACK_REMOTE_DIR_RESOLVED}"
    else
        remote_dir="${REPACK_REMOTE_DIR_RESOLVED}/${remote_subdir}"
    fi

    log "INFO" "process_one_file: ${internal_path}"
    log "DEBUG" "  local:  ${local_bz2_path}"
    log "DEBUG" "  remote: ${remote_dir}/${remote_name}"

    # ------------------------------------------------------------------
    # Skip check 1: remote file already exists
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
    # Skip check 2: local .bz2 already exists — skip compress, go to upload
    # ------------------------------------------------------------------
    if [[ -f "${local_bz2_path}" && -f "${local_sha256_path}" ]]; then
        log "INFO" "  local .bz2 exists — skipping compress, queuing for upload"
        (( STAT_SKIPPED_LOCAL++ )) || true

        if [[ "${CLI_DRY_RUN}" == true ]]; then
            log "INFO" "  DRY-RUN: would upload ${local_bz2_path}"
            return 0
        fi

        enqueue_item "${local_bz2_path}" "${local_sha256_path}" "${remote_dir}" "${remote_name}"
        (( STAT_ENQUEUED++ )) || true
        return 0
    fi

    # ------------------------------------------------------------------
    # Compress
    # ------------------------------------------------------------------
    if [[ "${CLI_DRY_RUN}" == true ]]; then
        log "INFO" "  DRY-RUN: would extract '${internal_path}' and compress to ${local_bz2_path}"
        (( STAT_COMPRESSED++ )) || true
        return 0
    fi

    mkdir -p "$(dirname "${local_bz2_path}")"

    if ! compress_one_file "${zpaq_pattern}" "${internal_path}" "${local_bz2_path}"; then
        log "ERROR" "  compress failed for '${internal_path}' — skipping"
        (( STAT_FAILED_COMPRESS++ )) || true
        return 0   # continue to next file; don't abort entire run
    fi

    (( STAT_COMPRESSED++ )) || true

    # ------------------------------------------------------------------
    # Enqueue for upload
    # ------------------------------------------------------------------
    enqueue_item "${local_bz2_path}" "${local_sha256_path}" "${remote_dir}" "${remote_name}"
    (( STAT_ENQUEUED++ )) || true

    return 0
}

# ============================================================
# Main
# ============================================================
main() {
    parse_args "$@"
    load_repack_config

    # Create output dir early (needed for lock file and logging)
    mkdir -p "${REPACK_OUTPUT_DIR}"

    setup_repack_logging

    log "INFO" "===== ${SCRIPT_NAME} starting ====="
    log "INFO" "archives=${#ARG_ARCHIVES[@]} output=${REPACK_OUTPUT_DIR} remote=${REPACK_REMOTE_DIR_RESOLVED}"
    log "INFO" "pbzip2: block=${PBZIP2_BLOCK}00KB memory=${PBZIP2_MEMORY}MB threads=${PBZIP2_THREADS:-autodetect} level=-9 (extreme)"
    log "INFO" "dry-run=${CLI_DRY_RUN}"

    validate_repack_config
    setup_temp_dirs
    trap 'trap_cleanup' EXIT INT TERM
    acquire_repack_lock

    check_repack_dependencies
    detect_zpaqfranz
    zpaq_calc_threads 0   # sets ZPAQFRANZ_THREADS (used by zpaq_utils functions if needed)

    # Export globals needed by zpaq_repack_ops.sh functions
    # (these are already set as shell variables; exporting ensures they
    # are visible to the upload_worker subshell launched with &)
    export ZPAQFRANZ_BIN
    export SFTP_HOST SFTP_PORT SFTP_USER SFTP_PASS
    export REPACK_QUEUE_DIR REPACK_QUEUE_SENTINEL REPACK_VERIFY_DIR
    export PBZIP2_BLOCK PBZIP2_MEMORY PBZIP2_THREADS
    export LOG_FILE ERROR_LOG_FILE CLI_VERBOSE

    # ------------------------------------------------------------------
    # Launch upload worker in the background
    # ------------------------------------------------------------------
    if [[ "${CLI_DRY_RUN}" == false ]]; then
        upload_worker &
        UPLOAD_WORKER_PID=$!
        log "INFO" "Upload worker started (PID=${UPLOAD_WORKER_PID})"
    fi

    # ------------------------------------------------------------------
    # Main loop: for each archive pattern, list files and process each
    # ------------------------------------------------------------------
    local zpaq_pattern internal_path
    local archive_errors=0

    for zpaq_pattern in "${ARG_ARCHIVES[@]}"; do
        log "INFO" "===== Processing archive: ${zpaq_pattern} ====="

        # list_zpaq_files prints one internal path per line
        local file_list=""
        local list_rc=0
        file_list=$(list_zpaq_files "${zpaq_pattern}") || list_rc=$?

        if (( list_rc != 0 )) || [[ -z "${file_list}" ]]; then
            log "ERROR" "Could not list files in ${zpaq_pattern} — skipping this archive"
            (( archive_errors++ )) || true
            continue
        fi

        while IFS= read -r internal_path; do
            [[ -z "${internal_path}" ]] && continue
            process_one_file "${zpaq_pattern}" "${internal_path}"
        done <<< "${file_list}"

        log "INFO" "===== Archive done: ${zpaq_pattern} ====="
    done

    # ------------------------------------------------------------------
    # Signal upload worker that all items have been enqueued
    # ------------------------------------------------------------------
    if [[ "${CLI_DRY_RUN}" == false ]]; then
        log "INFO" "All files processed — signalling upload worker (sentinel)"
        touch "${REPACK_QUEUE_SENTINEL}"

        log "INFO" "Waiting for upload worker to finish (PID=${UPLOAD_WORKER_PID})..."
        wait "${UPLOAD_WORKER_PID}" || true
        log "INFO" "Upload worker exited"
    fi

    # ------------------------------------------------------------------
    # Report
    # ------------------------------------------------------------------
    log "INFO" "===== ${SCRIPT_NAME} summary ====="
    log "INFO" "  Total files seen:        ${STAT_TOTAL}"
    log "INFO" "  Skipped (remote exists): ${STAT_SKIPPED_REMOTE}"
    log "INFO" "  Skipped (local .bz2):    ${STAT_SKIPPED_LOCAL}"
    log "INFO" "  Compressed:              ${STAT_COMPRESSED}"
    log "INFO" "  Enqueued for upload:     ${STAT_ENQUEUED}"
    log "INFO" "  Compress failures:       ${STAT_FAILED_COMPRESS}"

    # Check for upload failures
    local upload_failures=0
    if [[ "${CLI_DRY_RUN}" == false ]]; then
        report_upload_failures || upload_failures=$?
    fi

    if (( STAT_FAILED_COMPRESS > 0 || archive_errors > 0 || upload_failures > 0 )); then
        log "ERROR" "===== ${SCRIPT_NAME} finished with errors ====="
        exit 1
    fi

    log "INFO" "===== ${SCRIPT_NAME} finished OK ====="
}

main "$@"