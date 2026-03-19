#!/usr/bin/env bash
# ============================================================
# storezpaq.sh — Upload a .zpaq Archive to an SFTP Server
#
# Uploads a local .zpaq archive to a remote SFTP directory with:
#   - Pre-upload integrity check (zpaqfranz t)
#   - No-op detection via local .manifest (skip if unchanged)
#   - Remote divergence detection (warn if remote was modified externally)
#   - Atomic upload: write to .zpaq.tmp_upload, verify sha256, rename
#   - Timestamped backup rotation (rename old live → <base>.<ts>.zpaq)
#   - Configurable backup retention (-k, default 7)
#   - Manifest upload after successful transfer
#
# Version : 1.0.0
# Requires: zpaqfranz, sshpass, sha256sum
#
# Usage:
#   ./storezpaq.sh [OPTIONS] <archive.zpaq>
#
#   The remote destination is derived directly from the archive path:
#
#     SFTP_REMOTE_DIR + dirname(<archive.zpaq>)
#
#   Examples (SFTP_REMOTE_DIR=/ihub-db-backups):
#     ./storezpaq.sh backup.zpaq
#         → /ihub-db-backups/backup.zpaq
#     ./storezpaq.sh zpaq/daily/backup.zpaq
#         → /ihub-db-backups/zpaq/daily/backup.zpaq
#     ./storezpaq.sh /abs/path/backup.zpaq
#         → /ihub-db-backups/backup.zpaq  (absolute paths use basename only)
#
# Options:
#   -c FILE    Config file (SFTP credentials)     (default: ./transfer.conf)
#   -k N       Number of timestamped backups to keep (default: 7)
#   -t DIR     Temp directory for verification    (default: auto mktemp)
#   -f         Force upload even if manifest shows no change
#   -v         Verbose / DEBUG output to stdout
#   -h         Show this help message
#
# Config file variables used (same file as transfer.sh):
#   SFTP_HOST       — SFTP server hostname
#   SFTP_PORT       — SFTP port (default: 22)
#   SFTP_USER       — SFTP username
#   SFTP_PASS       — SFTP password
#   SFTP_REMOTE_DIR — remote base directory (e.g. /ihub-db-backups)
#
# Lock file: <archive>.zpaq.lock  (flock exclusive, crash-safe)
#
# Source layout:
#   src/core/     — logging
#   src/system/   — lock
#   src/zpaq/     — zpaq_utils, zpaq_manifest, zpaq_sftp_ops
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
# shellcheck source=src/zpaq/zpaq_manifest.sh
source "${SCRIPT_DIR}/src/zpaq/zpaq_manifest.sh"
# shellcheck source=src/zpaq/zpaq_sftp_ops.sh
source "${SCRIPT_DIR}/src/zpaq/zpaq_sftp_ops.sh"

# ============================================================
# Script-level globals
# ============================================================

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# CLI options (with defaults)
CLI_CONFIG="${SCRIPT_DIR}/transfer.conf"
CLI_KEEP=7
CLI_TEMP_DIR=""
CLI_FORCE=false
CLI_VERBOSE=false

# Runtime state
ZPAQ_FILE=""

TEMP_DIR=""
TEMP_DIR_CREATED=false

# Lock state
LOCK_FILE=""
LOCK_FD=9

LOG_FILE=""
ERROR_LOG_FILE=""

# SFTP credentials — populated by load_config_local(), same vars as transfer.sh
SFTP_HOST=""
SFTP_PORT="22"
SFTP_USER=""
SFTP_PASS=""
SFTP_REMOTE_DIR=""      # base remote dir from config (e.g. /ihub-db-backups)

# Resolved remote target directory — set by resolve_remote_target_dir()
# = SFTP_REMOTE_DIR / dirname(ZPAQ_FILE)  (for relative archive paths)
# = SFTP_REMOTE_DIR                       (for absolute paths — uses basename only)
REMOTE_TARGET_DIR=""

# ============================================================
# usage
# ============================================================
usage() {
    cat >&2 <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <archive.zpaq>

Uploads a .zpaq archive to an SFTP server. The remote path is derived
from the archive path relative to the working directory:

  SFTP_REMOTE_DIR + dirname(<archive.zpaq>)

Examples (SFTP_REMOTE_DIR=/ihub-db-backups):
  ${SCRIPT_NAME} backup.zpaq
      → /ihub-db-backups/backup.zpaq
  ${SCRIPT_NAME} zpaq/daily/backup.zpaq
      → /ihub-db-backups/zpaq/daily/backup.zpaq

Options:
  -c FILE    Config file (SFTP credentials)       (default: ./transfer.conf)
  -k N       Timestamped backups to keep          (default: 7)
  -t DIR     Temp dir for verification downloads  (default: auto mktemp)
  -f         Force upload even if archive unchanged
  -v         Verbose / DEBUG output
  -h         Show this help

Config variables (transfer.conf): SFTP_HOST, SFTP_PORT, SFTP_USER,
                                   SFTP_PASS, SFTP_REMOTE_DIR
Lock file: <archive>.zpaq.lock
EOF
}

# ============================================================
# parse_args
# ============================================================
parse_args() {
    local opt
    while getopts ":c:k:t:fvh" opt; do
        case "${opt}" in
            c) CLI_CONFIG="${OPTARG}"  ;;
            k) CLI_KEEP="${OPTARG}"    ;;
            t) CLI_TEMP_DIR="${OPTARG}";;
            f) CLI_FORCE=true          ;;
            v) CLI_VERBOSE=true        ;;
            h) usage; exit 0           ;;
            :) echo "ERROR: Option -${OPTARG} requires an argument." >&2; usage; exit 1 ;;
            ?) echo "ERROR: Unknown option: -${OPTARG}" >&2; usage; exit 1 ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    if (( $# < 1 )); then
        echo "ERROR: <archive.zpaq> is required." >&2
        usage
        exit 1
    fi

    ZPAQ_FILE="$1"

    if [[ "${ZPAQ_FILE}" != *.zpaq ]]; then
        echo "ERROR: Archive file must end in .zpaq: ${ZPAQ_FILE}" >&2
        exit 1
    fi

    if [[ ! -f "${ZPAQ_FILE}" ]]; then
        echo "ERROR: Archive file not found: ${ZPAQ_FILE}" >&2
        exit 1
    fi

    # Validate -k is a positive integer
    if ! [[ "${CLI_KEEP}" =~ ^[0-9]+$ ]] || (( CLI_KEEP < 1 )); then
        echo "ERROR: -k must be a positive integer (got: ${CLI_KEEP})" >&2
        exit 1
    fi
}

# ============================================================
# setup_logging_local
# ============================================================
setup_logging_local() {
    local archive_dir
    archive_dir=$(dirname "${ZPAQ_FILE}")
    local archive_base
    archive_base=$(basename "${ZPAQ_FILE}" .zpaq)

    LOG_FILE="${archive_dir}/${archive_base}.log"
    ERROR_LOG_FILE="${archive_dir}/${archive_base}.error.log"

    mkdir -p "${archive_dir}"
    touch "${LOG_FILE}" "${ERROR_LOG_FILE}"

    log "INFO" "=== ${SCRIPT_NAME} started (PID $$) ==="
    log "INFO" "Archive : ${ZPAQ_FILE}"
}

# ============================================================
# setup_staging
# ============================================================
setup_staging() {
    if [[ -n "${CLI_TEMP_DIR}" ]]; then
        TEMP_DIR="${CLI_TEMP_DIR}"
        mkdir -p "${TEMP_DIR}"
        chmod 700 "${TEMP_DIR}"
        log "DEBUG" "Using custom temp dir: ${TEMP_DIR}"
    else
        TEMP_DIR=$(mktemp -d -t storezpaq_XXXXXXXXXX)
        chmod 700 "${TEMP_DIR}"
        TEMP_DIR_CREATED=true
        log "DEBUG" "Created temp dir: ${TEMP_DIR}"
    fi
}

# ============================================================
# cleanup
# ============================================================
cleanup() {
    local exit_code=$?

    if [[ "${TEMP_DIR_CREATED}" == true ]] && [[ -d "${TEMP_DIR:-}" ]]; then
        rm -rf "${TEMP_DIR}"
        log "DEBUG" "Removed temp dir: ${TEMP_DIR}"
    fi

    release_lock

    if (( exit_code != 0 )); then
        log "WARN" "${SCRIPT_NAME} exited with code ${exit_code}"
    fi
}

# ============================================================
# load_config_local
#
# Sources transfer.conf (same file used by transfer.sh).
# ============================================================
load_config_local() {
    if [[ ! -f "${CLI_CONFIG}" ]]; then
        echo "ERROR: Config file not found: ${CLI_CONFIG}" >&2
        echo "       Create one based on transfer.example.conf or specify -c FILE" >&2
        exit 1
    fi

    # Warn if credentials file is world-readable
    local perms
    perms=$(stat -c "%a" "${CLI_CONFIG}" 2>/dev/null || echo "unknown")
    if [[ "${perms}" != "600" && "${perms}" != "400" && "${perms}" != "unknown" ]]; then
        echo "WARNING: Config file '${CLI_CONFIG}' has permissions ${perms}." >&2
        echo "         Credentials may be exposed. Run: chmod 600 '${CLI_CONFIG}'" >&2
    fi

    # shellcheck source=/dev/null
    source "${CLI_CONFIG}"

    # Default port if config did not set it
    SFTP_PORT="${SFTP_PORT:-22}"

    log "DEBUG" "Config loaded: ${CLI_CONFIG}"
}

# ============================================================
# validate_config_local
# ============================================================
validate_config_local() {
    local errors=()

    [[ -z "${SFTP_HOST:-}"       ]] && errors+=("SFTP_HOST is required")
    [[ -z "${SFTP_USER:-}"       ]] && errors+=("SFTP_USER is required")
    [[ -z "${SFTP_PASS:-}"       ]] && errors+=("SFTP_PASS is required")
    [[ -z "${SFTP_REMOTE_DIR:-}" ]] && errors+=("SFTP_REMOTE_DIR is required (set in transfer.conf)")

    if (( ${#errors[@]} > 0 )); then
        echo "ERROR: Configuration validation failed:" >&2
        local e
        for e in "${errors[@]}"; do
            echo "  - ${e}" >&2
        done
        exit 1
    fi
}

# ============================================================
# resolve_remote_target_dir
#
# Derives REMOTE_TARGET_DIR from SFTP_REMOTE_DIR and the archive path:
#
#   Relative archive path  → SFTP_REMOTE_DIR/dirname(ZPAQ_FILE)
#   Absolute archive path  → SFTP_REMOTE_DIR  (basename only; no local prefix)
#
# This mirrors how download_worker.sh uses SFTP_REMOTE_DIR as a base prefix.
# ============================================================
resolve_remote_target_dir() {
    local base_dir="${SFTP_REMOTE_DIR%/}"   # strip any trailing slash

    if [[ "${ZPAQ_FILE}" == /* ]]; then
        # Absolute path — use SFTP_REMOTE_DIR directly (don't embed local dirs)
        REMOTE_TARGET_DIR="${base_dir}"
    else
        # Relative path — append dirname so zpaq/daily/backup.zpaq
        # becomes SFTP_REMOTE_DIR/zpaq/daily
        local archive_dir
        archive_dir=$(dirname "${ZPAQ_FILE}")
        if [[ "${archive_dir}" == "." ]]; then
            REMOTE_TARGET_DIR="${base_dir}"
        else
            REMOTE_TARGET_DIR="${base_dir}/${archive_dir}"
        fi
    fi

    log "DEBUG" "resolve_remote_target_dir: ${ZPAQ_FILE} → ${REMOTE_TARGET_DIR}"
}

# ============================================================
# check_remote_divergence
#
# Downloads the remote manifest (if any) and compares it with
# the local manifest.  Warns but does not abort if they diverge
# (the remote was modified outside storezpaq.sh).
# ============================================================
check_remote_divergence() {
    local remote_manifest_tmp="${TEMP_DIR}/remote_check.manifest"

    log "DEBUG" "check_remote_divergence: downloading remote manifest for comparison"

    if ! zpaq_sftp_download_manifest \
            "${REMOTE_TARGET_DIR}" "${ZPAQ_FILE}" "${remote_manifest_tmp}"; then
        log "DEBUG" "check_remote_divergence: no remote manifest — first run, no divergence check"
        return 0
    fi

    local local_manifest
    local_manifest=$(manifest_path "${ZPAQ_FILE}")

    if manifest_remote_diverged "${local_manifest}" "${remote_manifest_tmp}"; then
        log "WARN" "Remote archive appears to have been modified outside storezpaq.sh."
        log "WARN" "Remote manifest sha256/size does not match local manifest."
        log "WARN" "Proceeding with upload — the remote will be overwritten."
        log "WARN" "The previous remote version will be preserved as a timestamped backup."
    else
        log "DEBUG" "check_remote_divergence: remote matches local manifest — no divergence"
    fi

    rm -f "${remote_manifest_tmp}"
}

# ============================================================
# main
# ============================================================
main() {
    parse_args "$@"

    # Acquire lock before any I/O
    LOCK_FILE="${ZPAQ_FILE}.lock"
    acquire_lock

    # Setup logging (needs ZPAQ_FILE to be set)
    setup_logging_local

    # Register cleanup trap
    trap cleanup INT TERM EXIT

    # Load and validate config
    load_config_local
    validate_config_local

    # Resolve remote destination from archive path + SFTP_REMOTE_DIR
    resolve_remote_target_dir

    log "INFO" "Remote  : ${REMOTE_TARGET_DIR}/$(basename "${ZPAQ_FILE}")"

    # Detect zpaqfranz
    detect_zpaqfranz

    # Setup temp dir for verification downloads
    setup_staging

    # ------------------------------------------------------------------
    # Step 1: Integrity test — verify the local archive before uploading
    # ------------------------------------------------------------------
    log "INFO" "Step 1/5: Testing local archive integrity"
    if ! zpaq_test_archive "${ZPAQ_FILE}"; then
        log "ERROR" "Local archive failed integrity test — aborting upload"
        log "ERROR" "Run 'zpaqfranz t ${ZPAQ_FILE}' for details"
        exit 1
    fi

    # ------------------------------------------------------------------
    # Step 2: No-op check — skip if archive unchanged since last upload
    # ------------------------------------------------------------------
    log "INFO" "Step 2/5: Checking whether archive has changed since last upload"
    if [[ "${CLI_FORCE}" == false ]]; then
        if ! manifest_changed "${ZPAQ_FILE}"; then
            log "INFO" "Archive is unchanged since last upload — nothing to do."
            log "INFO" "Use -f to force upload regardless."
            trap - INT TERM EXIT
            cleanup
            exit 0
        fi
        log "INFO" "Archive has changed — upload needed"
    else
        log "INFO" "Force mode (-f) — skipping no-op check"
    fi

    # ------------------------------------------------------------------
    # Step 3: Remote divergence check — warn if remote was modified externally
    # ------------------------------------------------------------------
    log "INFO" "Step 3/5: Checking remote manifest for external modifications"
    check_remote_divergence

    # ------------------------------------------------------------------
    # Step 4: Upload workflow (upload → verify → rename → prune → manifest)
    # ------------------------------------------------------------------
    log "INFO" "Step 4/5: Uploading archive to ${REMOTE_TARGET_DIR}"
    if ! zpaq_sftp_upload_workflow \
            "${ZPAQ_FILE}" \
            "${REMOTE_TARGET_DIR}" \
            "${CLI_KEEP}" \
            "${TEMP_DIR}"; then
        log "ERROR" "Upload workflow failed — archive may be in partial state"
        log "ERROR" "Check ${REMOTE_TARGET_DIR} on SFTP server for .zpaq.tmp_upload files"
        exit 1
    fi

    # ------------------------------------------------------------------
    # Step 5: Summary
    # ------------------------------------------------------------------
    log "INFO" "Step 5/5: Upload complete"

    local archive_base
    archive_base=$(basename "${ZPAQ_FILE}" .zpaq)
    local local_manifest
    local_manifest=$(manifest_path "${ZPAQ_FILE}")

    # Read the manifest we just wrote to display a clean summary
    if manifest_read "${local_manifest}"; then
        log "INFO" "  Remote : ${REMOTE_TARGET_DIR}/${archive_base}.zpaq"
        log "INFO" "  SHA256 : ${MANIFEST_SHA256}"
        log "INFO" "  Size   : ${MANIFEST_SIZE} bytes"
        log "INFO" "  Uploaded: ${MANIFEST_UPLOADED}"
        log "INFO" "  Backups kept: ${CLI_KEEP}"
    fi

    log "INFO" "=== ${SCRIPT_NAME} complete ==="

    trap - INT TERM EXIT
    cleanup
}

main "$@"