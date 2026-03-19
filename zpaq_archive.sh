#!/usr/bin/env bash
# ============================================================
# zpaq_archive.sh — Download Sources & Add to a zpaq Archive
#
# Downloads files from one or more FTP, SFTP, or local sources
# and stores them inside a single .zpaq archive using zpaqfranz.
# Files already present in the archive are skipped (idempotent).
# A flock-based exclusive lock on <archive>.zpaq.lock prevents
# concurrent runs from corrupting the archive.
#
# Version : 1.0.0
# Requires: zpaqfranz, lftp (FTP sources), sshpass (SFTP sources)
#
# Usage:
#   ./zpaq_archive.sh [OPTIONS] <archive.zpaq> <source> [<source> ...]
#
#   <archive.zpaq>   Path to the .zpaq archive to create or append to.
#                    The file is created if it does not yet exist.
#
#   <source>         One or more sources to download and archive:
#                      ftp://[user:pass@]host[:port]/path
#                      sftp://[user:pass@]host[:port]/path
#                      /absolute/local/path
#                      relative/local/path
#                    Credentials embedded in the URL are used when no
#                    -u/-p flags are given.
#
# Options:
#   -c FILE    Config file for SFTP/FTP credentials  (default: ./transfer.conf)
#   -u USER    FTP/SFTP username override
#   -p PASS    FTP/SFTP password override
#   -t DIR     Staging temp directory                (default: auto mktemp)
#   -j N       Parallel download workers             (default: 4)
#   -v         Verbose / DEBUG output to stdout
#   -h         Show this help message
#
# Lock file: <archive>.zpaq.lock  (flock exclusive, crash-safe)
#
# Source layout:
#   src/core/        — constants, logging
#   src/system/      — lock
#   src/zpaq/        — zpaq_utils, zpaq_archive_ops
#   src/transfer/    — ftp_download, sftp_download
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
# shellcheck source=src/system/lock.sh
source "${SCRIPT_DIR}/src/system/lock.sh"
# shellcheck source=src/zpaq/zpaq_utils.sh
source "${SCRIPT_DIR}/src/zpaq/zpaq_utils.sh"
# shellcheck source=src/zpaq/zpaq_archive_ops.sh
source "${SCRIPT_DIR}/src/zpaq/zpaq_archive_ops.sh"
# shellcheck source=src/transfer/ftp_download.sh
source "${SCRIPT_DIR}/src/transfer/ftp_download.sh"
# shellcheck source=src/transfer/sftp_download.sh
source "${SCRIPT_DIR}/src/transfer/sftp_download.sh"

# ============================================================
# Script-level globals
# ============================================================

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# CLI options (with defaults)
CLI_CONFIG="${SCRIPT_DIR}/transfer.conf"
CLI_USER=""
CLI_PASS=""
CLI_TEMP_DIR=""
CLI_WORKERS=4
CLI_VERBOSE=false

# Runtime state
ZPAQ_FILE=""           # resolved archive path
SOURCES=()             # remaining positional args

TEMP_DIR=""            # set by setup_staging()
TEMP_DIR_CREATED=false

# Lock state — reuse the same fd/file variables that lock.sh references
LOCK_FILE=""           # set after ZPAQ_FILE is known
LOCK_FD=9

LOG_FILE=""            # set by setup_logging_local()
ERROR_LOG_FILE=""      # not used but lock.sh references SCRIPT_NAME which needs it

# ============================================================
# usage
# ============================================================
usage() {
    cat >&2 <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <archive.zpaq> <source> [<source> ...]

Downloads files from FTP, SFTP, or local paths and appends them to a
.zpaq archive via zpaqfranz.  Already-archived files are skipped.

Arguments:
  <archive.zpaq>   Target .zpaq archive (created if absent)
  <source> ...     One or more sources:
                     ftp://[user:pass@]host[:port]/path
                     sftp://[user:pass@]host[:port]/path
                     /absolute/or/relative/local/path

Options:
  -c FILE    Config file for credentials  (default: ./transfer.conf)
  -u USER    Username for FTP/SFTP sources
  -p PASS    Password for FTP/SFTP sources
  -t DIR     Staging temp directory       (default: auto mktemp)
  -j N       Parallel download workers   (default: 4)
  -v         Verbose / DEBUG output
  -h         Show this help

Lock file: <archive>.zpaq.lock
EOF
}

# ============================================================
# parse_args
# ============================================================
parse_args() {
    local opt
    while getopts ":c:u:p:t:j:vh" opt; do
        case "${opt}" in
            c) CLI_CONFIG="${OPTARG}"   ;;
            u) CLI_USER="${OPTARG}"     ;;
            p) CLI_PASS="${OPTARG}"     ;;
            t) CLI_TEMP_DIR="${OPTARG}" ;;
            j) CLI_WORKERS="${OPTARG}"  ;;
            v) CLI_VERBOSE=true         ;;
            h) usage; exit 0            ;;
            :) echo "ERROR: Option -${OPTARG} requires an argument." >&2; usage; exit 1 ;;
            ?) echo "ERROR: Unknown option: -${OPTARG}" >&2; usage; exit 1 ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    if (( $# < 2 )); then
        echo "ERROR: <archive.zpaq> and at least one <source> are required." >&2
        usage
        exit 1
    fi

    ZPAQ_FILE="$1"
    shift
    SOURCES=("$@")

    # Ensure archive path ends in .zpaq
    if [[ "${ZPAQ_FILE}" != *.zpaq ]]; then
        echo "ERROR: Archive file must end in .zpaq: ${ZPAQ_FILE}" >&2
        exit 1
    fi

    # Validate -j is numeric
    if ! [[ "${CLI_WORKERS}" =~ ^[0-9]+$ ]] || (( CLI_WORKERS < 1 )); then
        echo "ERROR: -j must be a positive integer (got: ${CLI_WORKERS})" >&2
        exit 1
    fi
}

# ============================================================
# setup_logging_local
# Sets LOG_FILE to a path next to the archive so that all zpaqfranz
# output and progress is co-located with the archive.
# ============================================================
setup_logging_local() {
    local archive_dir
    archive_dir=$(dirname "${ZPAQ_FILE}")
    local archive_base
    archive_base=$(basename "${ZPAQ_FILE}" .zpaq)

    LOG_FILE="${archive_dir}/${archive_base}.log"
    ERROR_LOG_FILE="${archive_dir}/${archive_base}.error.log"

    mkdir -p "${archive_dir}"
    # Initialise log files (append — do not truncate across runs)
    touch "${LOG_FILE}" "${ERROR_LOG_FILE}"

    log "INFO" "=== ${SCRIPT_NAME} started (PID $$) ==="
    log "INFO" "Archive : ${ZPAQ_FILE}"
    log "INFO" "Sources : ${SOURCES[*]}"
    log "INFO" "Workers : ${CLI_WORKERS}"
}

# ============================================================
# setup_staging
# Creates or validates the temp/staging directory.
# ============================================================
setup_staging() {
    if [[ -n "${CLI_TEMP_DIR}" ]]; then
        TEMP_DIR="${CLI_TEMP_DIR}"
        mkdir -p "${TEMP_DIR}"
        chmod 700 "${TEMP_DIR}"
        log "DEBUG" "Using custom staging dir: ${TEMP_DIR}"
    else
        TEMP_DIR=$(mktemp -d -t zpaq_archive_XXXXXXXXXX)
        chmod 700 "${TEMP_DIR}"
        TEMP_DIR_CREATED=true
        log "DEBUG" "Created staging dir: ${TEMP_DIR}"
    fi
}

# ============================================================
# cleanup
# ============================================================
cleanup() {
    local exit_code=$?

    # Kill any background download workers still running
    if (( ${#WORKER_PIDS[@]} > 0 )); then
        log "WARN" "Sending SIGTERM to ${#WORKER_PIDS[@]} background worker(s)"
        kill "${WORKER_PIDS[@]}" 2>/dev/null || true
        local tries=0
        while (( tries < 5 )); do
            local alive=0
            local pid
            for pid in "${WORKER_PIDS[@]}"; do
                kill -0 "${pid}" 2>/dev/null && (( alive++ )) || true
            done
            (( alive == 0 )) && break
            sleep 1
            (( tries++ )) || true
        done
        kill -9 "${WORKER_PIDS[@]}" 2>/dev/null || true
    fi

    # Remove staging directory
    if [[ "${TEMP_DIR_CREATED}" == true ]] && [[ -d "${TEMP_DIR:-}" ]]; then
        rm -rf "${TEMP_DIR}"
        log "DEBUG" "Removed staging dir: ${TEMP_DIR}"
    fi

    release_lock

    if (( exit_code != 0 )); then
        log "WARN" "${SCRIPT_NAME} exited with code ${exit_code}"
    fi
}

# ============================================================
# load_credentials_from_config
# Sources transfer.conf (if present) to pick up FTP_USER/FTP_PASS
# and SFTP_USER/SFTP_PASS as fallbacks when -u/-p are not given.
# ============================================================
load_credentials_from_config() {
    if [[ -f "${CLI_CONFIG}" ]]; then
        # shellcheck source=/dev/null
        source "${CLI_CONFIG}"
        log "DEBUG" "Sourced config: ${CLI_CONFIG}"
    else
        log "DEBUG" "Config not found (${CLI_CONFIG}) — using CLI credentials only"
    fi
}

# ============================================================
# resolve_credentials SOURCE_URL
#
# Sets RESOLVED_USER and RESOLVED_PASS for a given source URL.
# Priority: embedded URL credentials > -u/-p flags > config file vars.
# ============================================================
RESOLVED_USER=""
RESOLVED_PASS=""

resolve_credentials() {
    local url="$1"

    RESOLVED_USER=""
    RESOLVED_PASS=""

    # Extract embedded credentials from URL (user:pass@host)
    local embedded=""
    case "${url}" in
        ftp://*@*|sftp://*@*)
            local rest="${url#*://}"
            embedded="${rest%%@*}"
            ;;
    esac

    if [[ -n "${embedded}" && "${embedded}" == *:* ]]; then
        RESOLVED_USER="${embedded%%:*}"
        RESOLVED_PASS="${embedded#*:}"
        return 0
    fi

    # CLI flags take next priority
    if [[ -n "${CLI_USER}" ]]; then
        RESOLVED_USER="${CLI_USER}"
        RESOLVED_PASS="${CLI_PASS}"
        return 0
    fi

    # Fall back to config-file variables
    case "${url}" in
        ftp://*)
            RESOLVED_USER="${FTP_USER:-}"
            RESOLVED_PASS="${FTP_PASS:-}"
            ;;
        sftp://*)
            RESOLVED_USER="${SFTP_USER:-}"
            RESOLVED_PASS="${SFTP_PASS:-}"
            ;;
    esac
}

# ============================================================
# process_source SOURCE
#
# Dispatches a single source argument to the appropriate downloader,
# then calls zpaq_add_source for each downloaded file.
# ============================================================

# Background worker PID tracking
WORKER_PIDS=()

# Staging subdirectory for downloaded files (shared across sources)
STAGE_DIR=""

process_source() {
    local source="$1"

    log "INFO" "Processing source: ${source}"

    case "${source}" in
        ftp://*)
            resolve_credentials "${source}"
            if ! ftp_download_url "${source}" \
                    "${RESOLVED_USER}" "${RESOLVED_PASS}" "${STAGE_DIR}"; then
                log "ERROR" "FTP download failed for: ${source}"
                return 1
            fi
            local f
            for f in "${FTP_DOWNLOADED_FILES[@]}"; do
                # Internal prefix = path relative to STAGE_DIR, dirname only
                local rel="${f#"${STAGE_DIR}"/}"
                local prefix
                prefix=$(dirname "${rel}")
                [[ "${prefix}" == "." ]] && prefix=""
                zpaq_add_source "${ZPAQ_FILE}" "${prefix}" "${f}" "${TEMP_DIR}"
            done
            ;;

        sftp://*)
            resolve_credentials "${source}"
            if ! sftp_download_url "${source}" \
                    "${RESOLVED_USER}" "${RESOLVED_PASS}" "${STAGE_DIR}"; then
                log "ERROR" "SFTP download failed for: ${source}"
                return 1
            fi
            local f
            for f in "${SFTP_DOWNLOADED_FILES[@]}"; do
                local rel="${f#"${STAGE_DIR}"/}"
                local prefix
                prefix=$(dirname "${rel}")
                [[ "${prefix}" == "." ]] && prefix=""
                zpaq_add_source "${ZPAQ_FILE}" "${prefix}" "${f}" "${TEMP_DIR}"
            done
            ;;

        *)
            # Local path (absolute or relative)
            if [[ ! -e "${source}" ]]; then
                log "ERROR" "Local source not found: ${source}"
                return 1
            fi

            if [[ -d "${source}" ]]; then
                # Directory: find all files and add each
                local f
                while IFS= read -r f; do
                    local rel="${f#"${source}"/}"
                    local prefix
                    prefix=$(dirname "${rel}")
                    [[ "${prefix}" == "." ]] && prefix=""
                    zpaq_add_source "${ZPAQ_FILE}" "${prefix}" "${f}" "${TEMP_DIR}"
                done < <(find "${source}" -type f | sort)
            else
                # Single local file
                zpaq_add_source "${ZPAQ_FILE}" "" "${source}" "${TEMP_DIR}"
            fi
            ;;
    esac
}

# ============================================================
# run_parallel_downloads
#
# Launches up to CLI_WORKERS parallel background processes, each
# handling one source.  Downloads are parallelised; the zpaq add
# calls inside zpaq_add_source are serial (zpaqfranz is not
# re-entrant on the same archive).
#
# Implementation note: to keep the zpaqfranz add calls serial while
# downloads are parallel, we split the work into two phases:
#   Phase 1 — parallel: download each source into its own subdir
#   Phase 2 — serial: walk staged files and add to zpaq
# ============================================================
run_parallel_downloads() {
    local -a source_dirs=()

    # Assign each source a dedicated staging subdirectory
    local i
    for (( i = 0; i < ${#SOURCES[@]}; i++ )); do
        source_dirs+=("${STAGE_DIR}/src_${i}")
        mkdir -p "${STAGE_DIR}/src_${i}"
    done

    # Phase 1: parallel downloads
    local -a dl_pids=()
    for (( i = 0; i < ${#SOURCES[@]}; i++ )); do
        local src="${SOURCES[${i}]}"
        local src_dir="${source_dirs[${i}]}"
        log "INFO" "Launching download worker ${i} for: ${src}"

        (
            # Each worker runs in a subshell with its own staging dir
            case "${src}" in
                ftp://*)
                    resolve_credentials "${src}"
                    ftp_download_url "${src}" \
                        "${RESOLVED_USER}" "${RESOLVED_PASS}" "${src_dir}" \
                        || exit 1
                    ;;
                sftp://*)
                    resolve_credentials "${src}"
                    sftp_download_url "${src}" \
                        "${RESOLVED_USER}" "${RESOLVED_PASS}" "${src_dir}" \
                        || exit 1
                    ;;
                *)
                    # Local path: just copy into src_dir preserving structure
                    if [[ -d "${src}" ]]; then
                        rsync -a "${src}/" "${src_dir}/" 2>/dev/null \
                            || cp -a "${src}/." "${src_dir}/"
                    elif [[ -f "${src}" ]]; then
                        cp -p "${src}" "${src_dir}/"
                    else
                        echo "ERROR: local source not found: ${src}" >&2
                        exit 1
                    fi
                    ;;
            esac
        ) &
        dl_pids+=($!)
        WORKER_PIDS+=($!)
    done

    # Wait for all download workers
    local all_ok=true
    local pid
    for pid in "${dl_pids[@]}"; do
        if ! wait "${pid}"; then
            log "ERROR" "Download worker (PID ${pid}) failed"
            all_ok=false
        fi
    done
    WORKER_PIDS=()

    if [[ "${all_ok}" != true ]]; then
        log "ERROR" "One or more download workers failed — aborting"
        return 1
    fi

    # Phase 2: serial zpaq add (zpaqfranz is not safe to call concurrently
    # on the same archive)
    log "INFO" "All downloads complete — adding files to archive (serial)"
    for (( i = 0; i < ${#SOURCES[@]}; i++ )); do
        local src_dir="${source_dirs[${i}]}"
        local f
        while IFS= read -r f; do
            local rel="${f#"${src_dir}"/}"
            local prefix
            prefix=$(dirname "${rel}")
            [[ "${prefix}" == "." ]] && prefix=""
            if ! zpaq_add_source "${ZPAQ_FILE}" "${prefix}" "${f}" "${TEMP_DIR}"; then
                log "ERROR" "Failed to add to archive: ${f}"
                all_ok=false
            fi
        done < <(find "${src_dir}" -type f | sort)
    done

    [[ "${all_ok}" == true ]]
}

# ============================================================
# main
# ============================================================
main() {
    parse_args "$@"

    # Setup logging before anything else that calls log()
    setup_logging_local

    # Acquire exclusive lock on the archive
    LOCK_FILE="${ZPAQ_FILE}.lock"
    acquire_lock

    # Register cleanup trap (after lock is acquired)
    trap cleanup INT TERM EXIT

    # Detect zpaqfranz
    detect_zpaqfranz

    # Load config for credential fallbacks
    load_credentials_from_config

    # Setup staging directory
    setup_staging
    STAGE_DIR="${TEMP_DIR}/stage"
    mkdir -p "${STAGE_DIR}"

    # Run parallel downloads + serial zpaq adds
    if ! run_parallel_downloads; then
        log "ERROR" "Archive run failed"
        exit 1
    fi

    log "INFO" "=== ${SCRIPT_NAME} complete ==="

    # Clean shutdown — remove trap before manual cleanup to avoid double-run
    trap - INT TERM EXIT
    cleanup
}

main "$@"