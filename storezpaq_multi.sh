#!/usr/bin/env bash
# ============================================================
# storezpaq_multi.sh — Multipart zpaqfranz Archive with Date Grouping
#
# Downloads compressed SQL dump files from SFTP/FTP/local sources,
# groups them by date (YYYYMMDD from filename), decompresses each
# group, and adds them to a multipart zpaqfranz archive.
#
# Each date group (normal mode) or all groups combined (backfill mode)
# produces exactly one new .zpaq part.  Only the new part is uploaded
# after each add — the entire archive is never re-transferred.
#
# Version : 1.0.0
# Requires: zpaqfranz, xz, sshpass, sftp, sha256sum
# Optional: lbzip2 or pbzip2 (bz2), pigz (gz), unzip (zip)
#
# Usage:
#   ./storezpaq_multi.sh [OPTIONS] <basename> <source> [<source> ...]
#
#   <basename>   Archive base name (e.g. vxtl_helium). No extension.
#                The script appends ??????? internally.
#
#   <source>     One or more sources (quoted wildcards supported):
#                  sftp://host/path/to/files_*.sql.xz
#                  ftp://host/path/to/files_*.sql.bz2
#                  /local/path/files_*.sql.gz
#
# Options:
#   -c FILE         Config file                        (default: storezpaq.conf)
#   -u USER         SFTP username override
#   -p PASS         SFTP password override
#   -t DIR          Temp/work directory                (default: /tmp/storezpaq_PID)
#   -j N            Parallel download threads          (default: 4)
#   -T N            zpaqfranz thread count override
#   -backfill       Backfill mode: combine all groups into one add
#   -backfill-days N  Limit backfill to N most recent unarchived days
#   -dry-run        Show what would be done, no changes
#   -v              Verbose / DEBUG logging
#   -h              Show this help
#
# Lock file: <ZPAQ_LOCAL_DIR>/<basename>.zpaq.lock
# Log file:  <ZPAQ_LOCAL_DIR>/<basename>_multi.log
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
# shellcheck source=src/zpaq/zpaq_archive_ops.sh
source "${SCRIPT_DIR}/src/zpaq/zpaq_archive_ops.sh"
# shellcheck source=src/zpaq/zpaq_sftp_ops.sh
source "${SCRIPT_DIR}/src/zpaq/zpaq_sftp_ops.sh"
# shellcheck source=src/zpaq/zpaq_multipart_manifest.sh
source "${SCRIPT_DIR}/src/zpaq/zpaq_multipart_manifest.sh"
# shellcheck source=src/zpaq/zpaq_multipart_ops.sh
source "${SCRIPT_DIR}/src/zpaq/zpaq_multipart_ops.sh"
# shellcheck source=src/zpaq/zpaq_grouping.sh
source "${SCRIPT_DIR}/src/zpaq/zpaq_grouping.sh"

# ============================================================
# Script globals
# ============================================================
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# CLI options
CLI_CONFIG="${SCRIPT_DIR}/storezpaq.conf"
CLI_USER=""
CLI_PASS=""
CLI_TEMP_DIR=""
CLI_DOWNLOAD_WORKERS=4
CLI_ZPAQ_THREADS=0
CLI_BACKFILL=false
CLI_BACKFILL_DAYS=0
CLI_DRY_RUN=false
CLI_VERBOSE=false

# Positional arguments
ARG_BASENAME=""
ARG_SOURCES=()

# Runtime state
LOCK_FD=200
LOCK_FILE=""
LOG_FILE=""
LOG_DIR=""
ZPAQ_TEMP_DIR_ACTIVE=""   # actual temp dir used this run (may be auto-generated)

# ============================================================
# Usage
# ============================================================
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <basename> <source> [<source> ...]

  <basename>   Archive base name (no extension, no ? characters).
  <source>     One or more SFTP/FTP/local source paths. Wildcards supported
               if the argument is quoted (e.g. 'sftp://host/path/*.sql.xz').

Options:
  -c FILE         Config file                         (default: storezpaq.conf)
  -u USER         SFTP username override
  -p PASS         SFTP password override
  -t DIR          Temp/work directory                 (default: /tmp/storezpaq_PID)
  -j N            Parallel download workers           (default: 4)
  -T N            zpaqfranz thread count override
  -backfill       Combine all unarchived groups into one zpaq add
  -backfill-days N  Limit backfill to N most recent unarchived days
  -dry-run        Show what would be done; make no changes
  -v              Verbose / DEBUG output
  -h              Show this help and exit
EOF
}

# ============================================================
# Argument parsing
# ============================================================
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -c)         CLI_CONFIG="$2";           shift 2 ;;
            -u)         CLI_USER="$2";             shift 2 ;;
            -p)         CLI_PASS="$2";             shift 2 ;;
            -t)         CLI_TEMP_DIR="$2";         shift 2 ;;
            -j)         CLI_DOWNLOAD_WORKERS="$2"; shift 2 ;;
            -T)         CLI_ZPAQ_THREADS="$2";     shift 2 ;;
            -backfill)  CLI_BACKFILL=true;         shift   ;;
            -backfill-days)
                        CLI_BACKFILL_DAYS="$2";    shift 2 ;;
            -dry-run)   CLI_DRY_RUN=true;          shift   ;;
            -v)         CLI_VERBOSE=true;           shift   ;;
            -h|--help)  usage; exit 0 ;;
            -*)
                echo "ERROR: Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
            *)
                if [[ -z "${ARG_BASENAME}" ]]; then
                    ARG_BASENAME="$1"
                else
                    ARG_SOURCES+=("$1")
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${ARG_BASENAME}" ]]; then
        echo "ERROR: <basename> is required." >&2
        usage >&2
        exit 1
    fi

    if (( ${#ARG_SOURCES[@]} == 0 )); then
        echo "ERROR: At least one <source> is required." >&2
        usage >&2
        exit 1
    fi
}

# ============================================================
# Config loading with script-level defaults
# ============================================================
load_multi_config() {
    # Source config file if it exists
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
    [[ -n "${CLI_TEMP_DIR}" ]] && ZPAQ_TEMP_DIR="${CLI_TEMP_DIR}"

    # Apply script-level defaults for every config key
    # Connectivity
    : "${SFTP_HOST:=}"
    : "${SFTP_PORT:=22}"
    : "${SFTP_USER:=}"
    : "${SFTP_PASS:=}"
    : "${SFTP_REMOTE_DIR:=}"

    # Local paths
    : "${ZPAQ_LOCAL_DIR:=}"
    : "${ZPAQ_TEMP_DIR:=}"

    # zpaqfranz compression
    : "${ZPAQ_THREADS:=}"
    : "${ZPAQ_COMPRESSION:=-m5}"
    : "${ZPAQ_EXTRA_FLAGS:=-ssd}"
    # Set to "true" to pass -stdinsize to zpaqfranz for % progress on stdin adds.
    # Requires a zpaqfranz build with the -stdinsize patch (v64.6+).
    # Disabled by default for compatibility with unpatched zpaqfranz builds.
    : "${ZPAQ_STDINSIZE_HINT:=false}"

    # Multipart
    : "${ZPAQ_MULTIPART_QUESTION_MARKS:=7}"
    : "${ZPAQ_FRAGMENT:=3}"

    # Decompression
    : "${XZ_DECOMPRESS_THREADS:=4}"

    # Space management
    : "${ZPAQ_HEADROOM_RATIO:=0.30}"
    : "${BACKFILL_MIN_FREE_GB:=100}"
    : "${SIZE_HISTORY_SAMPLES:=5}"
    : "${SIZE_ESTIMATE_SAFETY_FACTOR:=1.20}"
    : "${BZ2_DEFAULT_RATIO:=3.5}"

    # File list / ARG_MAX
    : "${ARGMAX_SAFE_THRESHOLD:=131072}"

    # Upload
    : "${UPLOAD_RETRY_COUNT:=3}"

    # Monitoring
    : "${ZPAQ_LOCAL_SIZE_WARN_GB:=500}"

    # Logging
    : "${LOG_DIR:=${ZPAQ_LOCAL_DIR}/logs}"
    : "${LOG_RETENTION_DAYS:=30}"
}

# ============================================================
# Validate required config
# ============================================================
validate_multi_config() {
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
    _require_var "SFTP_REMOTE_DIR"
    _require_var "ZPAQ_LOCAL_DIR"

    if (( errors > 0 )); then
        echo "ERROR: ${errors} required configuration variable(s) missing. Check ${CLI_CONFIG}." >&2
        exit 1
    fi

    # Validate numerics
    if ! [[ "${SFTP_PORT}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: SFTP_PORT must be a number, got: '${SFTP_PORT}'" >&2
        exit 1
    fi
    if ! [[ "${ZPAQ_FRAGMENT}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: ZPAQ_FRAGMENT must be a number, got: '${ZPAQ_FRAGMENT}'" >&2
        exit 1
    fi
}

# ============================================================
# Logging setup
# ============================================================
setup_multi_logging() {
    LOG_DIR="${ZPAQ_LOCAL_DIR}/logs"
    mkdir -p "${LOG_DIR}"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    LOG_FILE="${LOG_DIR}/${ARG_BASENAME}_multi_${timestamp}.log"
    # ERROR_LOG_FILE used by logging.sh
    ERROR_LOG_FILE="${LOG_DIR}/${ARG_BASENAME}_multi_errors_$(date '+%Y%m%d').log"
    touch "${LOG_FILE}" "${ERROR_LOG_FILE}"

    # Rotate logs > 50 MB
    find "${LOG_DIR}" -name "${ARG_BASENAME}_multi_*.log" -size +50M -delete 2>/dev/null || true
}

# ============================================================
# Lock file management
# ============================================================
acquire_multi_lock() {
    LOCK_FILE="${ZPAQ_LOCAL_DIR}/${ARG_BASENAME}.zpaq.lock"
    eval "exec ${LOCK_FD}>'${LOCK_FILE}'"
    if ! flock -n "${LOCK_FD}"; then
        local existing_pid
        existing_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "unknown")
        log "ERROR" "Another instance is already running for '${ARG_BASENAME}' (PID: ${existing_pid})."
        log "ERROR" "If this is incorrect, remove: ${LOCK_FILE}"
        exit 1
    fi
    echo $$ > "${LOCK_FILE}"
    log "DEBUG" "acquire_multi_lock: acquired ${LOCK_FILE}"
}

release_multi_lock() {
    flock -u "${LOCK_FD}" 2>/dev/null || true
    rm -f "${LOCK_FILE}"
    log "DEBUG" "release_multi_lock: released"
}

# ============================================================
# Temp directory management
# ============================================================
setup_temp_dir() {
    if [[ -n "${ZPAQ_TEMP_DIR}" ]]; then
        ZPAQ_TEMP_DIR_ACTIVE="${ZPAQ_TEMP_DIR}/storezpaq_$$"
    else
        ZPAQ_TEMP_DIR_ACTIVE=$(mktemp -d "/tmp/storezpaq_$$.XXXXXX")
    fi
    mkdir -p "${ZPAQ_TEMP_DIR_ACTIVE}"
    log "DEBUG" "setup_temp_dir: using ${ZPAQ_TEMP_DIR_ACTIVE}"
}

cleanup_temp_dir() {
    if [[ -n "${ZPAQ_TEMP_DIR_ACTIVE}" && -d "${ZPAQ_TEMP_DIR_ACTIVE}" ]]; then
        rm -rf "${ZPAQ_TEMP_DIR_ACTIVE}"
        log "DEBUG" "cleanup_temp_dir: removed ${ZPAQ_TEMP_DIR_ACTIVE}"
    fi
}

# ============================================================
# Cleanup on exit / signal
# ============================================================
trap_cleanup() {
    local exit_code=$?
    log "DEBUG" "trap_cleanup: exit_code=${exit_code}"
    cleanup_temp_dir
    release_multi_lock
}

# ============================================================
# Dependency check
# ============================================================
check_dependencies() {
    local missing=0
    local dep
    for dep in zpaqfranz xz sshpass sha256sum sftp; do
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
# Archive pattern builder
# ============================================================
archive_pattern() {
    local qmarks
    qmarks=$(printf '%0.s?' $(seq 1 "${ZPAQ_MULTIPART_QUESTION_MARKS:-7}"))
    echo "${ZPAQ_LOCAL_DIR}/${ARG_BASENAME}${qmarks}"
}

# ============================================================
# Local size warning check
# ============================================================
check_local_size_warning() {
    local warn_gb="${ZPAQ_LOCAL_SIZE_WARN_GB:-500}"
    local total_bytes=0
    local f
    while IFS= read -r -d $'\0' f; do
        local fsz
        fsz=$(stat -c "%s" "${f}" 2>/dev/null || echo 0)
        total_bytes=$(( total_bytes + fsz ))
    done < <(find "${ZPAQ_LOCAL_DIR}" -maxdepth 1 \
               -name "${ARG_BASENAME}[0-9]*.zpaq" -print0 2>/dev/null)

    local total_gb
    total_gb=$(awk -v b="${total_bytes}" 'BEGIN { printf "%.1f", b/1073741824 }')
    if awk -v t="${total_gb}" -v w="${warn_gb}" 'BEGIN { exit (t < w) ? 0 : 1 }' 2>/dev/null; then
        : # Below threshold
    else
        log "WARN" "LOCAL SIZE WARNING: total local archive size ${total_gb} GB >= ${warn_gb} GB threshold"
        log "WARN" "  Consider starting a new archive with a different basename."
    fi
}

# ============================================================
# Source file expansion — expand wildcards per source spec
# ============================================================
expand_sources() {
    local -n _all_files_ref="$1"
    _all_files_ref=""

    local source_spec
    for source_spec in "${ARG_SOURCES[@]}"; do
        local expanded=""

        if [[ "${source_spec}" == sftp://* ]]; then
            if [[ "${source_spec}" == *"*"* || "${source_spec}" == *"?"* ]]; then
                expand_sftp_wildcard "${source_spec}" expanded
            else
                expanded="${source_spec}"$'\n'
            fi
        elif [[ "${source_spec}" == ftp://* ]]; then
            # FTP wildcard expansion — treat as local pattern for now (lftp-based expansion
            # would be added in a future phase; for now add the literal URL)
            log "WARN" "expand_sources: FTP wildcard expansion not yet implemented — treating as literal: ${source_spec}"
            expanded="${source_spec}"$'\n'
        else
            # Local path
            if [[ "${source_spec}" == *"*"* || "${source_spec}" == *"?"* ]]; then
                expand_local_wildcard "${source_spec}" expanded
            elif [[ -d "${source_spec}" ]]; then
                # Directory — find all supported compressed SQL files
                local dir_files=""
                while IFS= read -r -d $'\0' f; do
                    dir_files+="${f}"$'\n'
                done < <(find "${source_spec}" -maxdepth 2 \
                    \( -name "*.sql.xz" -o -name "*.sql.bz2" -o -name "*.sql.gz" \
                       -o -name "*.sql.zip" -o -name "*.sql" \) \
                    -print0 2>/dev/null | sort -z)
                expanded="${dir_files}"
            else
                expanded="${source_spec}"$'\n'
            fi
        fi

        _all_files_ref+="${expanded}"
    done

    # Deduplicate and sort
    _all_files_ref=$(sort -u <<< "${_all_files_ref}")
}

# ============================================================
# Download a single file from SFTP to ZPAQ_TEMP_DIR_ACTIVE,
# preserving the remote subdirectory structure.
# ============================================================
download_source_file() {
    local source_url="$1"
    local dest_dir="$2"

    if [[ "${source_url}" == sftp://* ]]; then
        local url_path="${source_url#sftp://}"
        local remote_path="/${url_path#*/}"
        local remote_subdir
        remote_subdir=$(dirname "${remote_path}")
        local remote_base
        remote_base=$(basename "${remote_path}")

        # Determine relative subdir from SFTP_REMOTE_DIR
        local rel_subdir="${remote_subdir#${SFTP_REMOTE_DIR}}"
        rel_subdir="${rel_subdir#/}"
        local local_subdir="${dest_dir}"
        [[ -n "${rel_subdir}" ]] && local_subdir="${dest_dir}/${rel_subdir}"
        mkdir -p "${local_subdir}"

        local dest_file="${local_subdir}/${remote_base}"
        log "INFO" "download_source_file: ${source_url} → ${dest_file}"

        local rc=0
        _zpaq_sftp_run "get ${remote_path} ${dest_file}" || rc=$?
        if (( rc != 0 )) || [[ ! -f "${dest_file}" ]]; then
            log "ERROR" "download_source_file: SFTP download failed (rc=${rc}): ${source_url}"
            return 1
        fi
        echo "${dest_file}"

    elif [[ "${source_url}" == ftp://* ]]; then
        log "ERROR" "download_source_file: FTP download not yet implemented: ${source_url}"
        return 1
    else
        # Local file — already on disk
        echo "${source_url}"
    fi
}

# ============================================================
# Process a single group (normal mode):
#   download → decompress → add → upload → cleanup
# ============================================================
process_group() {
    local date_key="$1"
    local group_files="$2"      # space-separated list of source URLs/paths
    local manifest_path="$3"
    local history_file="$4"

    log "INFO" "process_group: ===== GROUP ${date_key} ====="

    # Check each file against archive content cache
    local files_to_add=()
    local f
    for f in ${group_files}; do
        local internal_name
        internal_name=$(basename "${f}")
        # Strip compression extensions
        internal_name="${internal_name%.xz}"
        internal_name="${internal_name%.bz2}"
        internal_name="${internal_name%.gz}"
        internal_name="${internal_name%.zip}"

        # Also check for slim/ prefix preserved from source path
        local rel_internal="${f}"
        # Strip SFTP URL prefix if present
        [[ "${rel_internal}" == sftp://* ]] && rel_internal="${rel_internal#sftp://*/}"
        # Strip SFTP_REMOTE_DIR prefix
        rel_internal="${rel_internal#${SFTP_REMOTE_DIR}/}"
        # Strip compression extension
        rel_internal="${rel_internal%.xz}"
        rel_internal="${rel_internal%.bz2}"
        rel_internal="${rel_internal%.gz}"
        rel_internal="${rel_internal%.zip}"

        if zpaq_multipart_file_known "${rel_internal}"; then
            log "INFO" "process_group: ${rel_internal} already in archive — skipping"
        else
            files_to_add+=("${f}")
        fi
    done

    if (( ${#files_to_add[@]} == 0 )); then
        log "INFO" "process_group: all files in group ${date_key} already archived — skipping group"
        return 0
    fi

    # Space check
    local local_files=()
    # For space estimation we need local paths; estimate from source paths
    local estimate_list="${files_to_add[*]}"
    # Download to temp for local estimation — space check first with estimates
    local estimated_bytes
    estimated_bytes=$(estimate_group_uncompressed_size "${estimate_list}" "${history_file}")

    local available_bytes
    available_bytes=$(df --output=avail -B1 "${ZPAQ_TEMP_DIR_ACTIVE}" 2>/dev/null | tail -1 | tr -d '[:space:]')

    if ! check_space "${estimated_bytes}" "${available_bytes}"; then
        log "ERROR" "process_group: insufficient space for group ${date_key} — skipping (will retry next run)"
        return 0
    fi

    # Download all files in this group
    local downloaded_files=()
    for f in "${files_to_add[@]}"; do
        local local_path
        if ! local_path=$(download_source_file "${f}" "${ZPAQ_TEMP_DIR_ACTIVE}"); then
            log "ERROR" "process_group: download failed for ${f} — aborting group ${date_key}"
            return 1
        fi
        downloaded_files+=("${local_path}")
    done

    # Decompress each downloaded file
    local decompressed_rel_paths=()
    for f in "${downloaded_files[@]}"; do
        if ! decompress_file "${f}" "${ZPAQ_TEMP_DIR_ACTIVE}" "${ZPAQ_TEMP_DIR_ACTIVE}" "${history_file}"; then
            log "ERROR" "process_group: decompression failed for ${f} — aborting group ${date_key}"
            return 1
        fi
        # Compute the relative path that decompress_file produced
        local rel_path="${f#${ZPAQ_TEMP_DIR_ACTIVE}/}"
        rel_path="${rel_path%.xz}"
        rel_path="${rel_path%.bz2}"
        rel_path="${rel_path%.gz}"
        rel_path="${rel_path%.zip}"
        decompressed_rel_paths+=("${rel_path}")
    done

    if [[ "${CLI_DRY_RUN}" == true ]]; then
        log "INFO" "process_group: DRY-RUN — would add ${#decompressed_rel_paths[@]} file(s) to archive"
        for f in "${decompressed_rel_paths[@]}"; do
            log "INFO" "  + ${f}"
        done
        # Clean up decompressed files
        for f in "${decompressed_rel_paths[@]}"; do
            rm -f "${ZPAQ_TEMP_DIR_ACTIVE}/${f}"
        done
        return 0
    fi

    # Fragment consistency check
    if ! multipart_manifest_check_fragment "${manifest_path}" "${ZPAQ_FRAGMENT}"; then
        log "ERROR" "process_group: fragment mismatch — aborting"
        return 1
    fi

    # zpaqfranz add
    local archive_pat
    archive_pat=$(archive_pattern)

    local add_rc=0
    zpaq_multipart_add "${archive_pat}" decompressed_rel_paths "${ZPAQ_TEMP_DIR_ACTIVE}" || add_rc=$?

    if (( add_rc != 0 )); then
        log "ERROR" "process_group: zpaqfranz add failed for group ${date_key}"
        return 1
    fi

    # Find the new part that was just created (highest numbered part)
    local new_part
    new_part=$(find "${ZPAQ_LOCAL_DIR}" -maxdepth 1 \
        -name "${ARG_BASENAME}[0-9][0-9][0-9][0-9][0-9][0-9][0-9].zpaq" \
        | sort | tail -1)

    if [[ -z "${new_part}" ]]; then
        log "ERROR" "process_group: could not find newly created part file"
        return 1
    fi
    log "INFO" "process_group: new part created: $(basename "${new_part}")"

    # Upload new part
    if ! zpaq_multipart_upload_part "${new_part}" "${SFTP_REMOTE_DIR}" "${ZPAQ_TEMP_DIR_ACTIVE}"; then
        log "ERROR" "process_group: upload failed for $(basename "${new_part}")"
        return 1
    fi

    # Update manifest in-memory
    local part_sha256 part_size
    part_sha256=$(sha256sum "${new_part}" | awk '{print $1}')
    part_size=$(stat -c "%s" "${new_part}")
    local partname
    partname=$(basename "${new_part}")

    # Lock fragment on first add
    if [[ "${MP_MANIFEST_TOTAL_PARTS}" -eq 0 || -z "${MP_MANIFEST_FRAGMENT}" ]]; then
        MP_MANIFEST_FRAGMENT="${ZPAQ_FRAGMENT}"
    fi

    multipart_manifest_add_part "${partname}" "${part_size}" "${part_sha256}"

    # Write manifest to disk and upload
    multipart_manifest_write "${manifest_path}"
    if ! zpaq_multipart_upload_manifest "${manifest_path}" "${SFTP_REMOTE_DIR}"; then
        log "WARN" "process_group: manifest upload failed (non-fatal)"
    fi

    # Update archive content cache with newly added files
    for f in "${decompressed_rel_paths[@]}"; do
        ZPAQ_ARCHIVE_CONTENTS["${f}"]=1
    done

    # Cleanup decompressed files
    for f in "${decompressed_rel_paths[@]}"; do
        rm -f "${ZPAQ_TEMP_DIR_ACTIVE}/${f}"
        log "DEBUG" "process_group: cleaned up ${f}"
    done

    log "INFO" "process_group: ===== GROUP ${date_key} COMPLETE ====="
    return 0
}

# ============================================================
# Backfill mode: all groups in a single add
# ============================================================
process_backfill() {
    local -n _date_groups_ref="$1"
    local sorted_dates="$2"
    local manifest_path="$3"
    local history_file="$4"

    log "INFO" "process_backfill: ===== BACKFILL MODE START ====="

    # Collect all unarchived files across all groups
    local all_source_files=()
    local date_key f

    for date_key in ${sorted_dates}; do
        local group_files="${_date_groups_ref[${date_key}]}"
        for f in ${group_files}; do
            local rel_internal="${f}"
            [[ "${rel_internal}" == sftp://* ]] && rel_internal="${rel_internal#sftp://*/}"
            rel_internal="${rel_internal#${SFTP_REMOTE_DIR}/}"
            rel_internal="${rel_internal%.xz}"
            rel_internal="${rel_internal%.bz2}"
            rel_internal="${rel_internal%.gz}"
            rel_internal="${rel_internal%.zip}"

            if zpaq_multipart_file_known "${rel_internal}"; then
                log "INFO" "process_backfill: ${rel_internal} already archived — skipping"
            else
                all_source_files+=("${f}")
            fi
        done
    done

    if (( ${#all_source_files[@]} == 0 )); then
        log "INFO" "process_backfill: all files already archived — nothing to do"
        return 0
    fi

    # Apply -backfill-days filter if set (keep N most recent unarchived dates)
    if (( CLI_BACKFILL_DAYS > 0 )); then
        local unique_dates=()
        for f in "${all_source_files[@]}"; do
            local d
            d=$(extract_date_from_filename "${f}")
            if [[ "${d}" != "undated" ]]; then
                unique_dates+=("${d}")
            fi
        done
        # Get N most recent
        local cutoff_date
        cutoff_date=$(printf '%s\n' "${unique_dates[@]}" | sort -u | tail -n "${CLI_BACKFILL_DAYS}" | head -1)

        local filtered_files=()
        for f in "${all_source_files[@]}"; do
            local fd
            fd=$(extract_date_from_filename "${f}")
            if [[ "${fd}" == "undated" || "${fd}" > "${cutoff_date}" || "${fd}" == "${cutoff_date}" ]]; then
                filtered_files+=("${f}")
            fi
        done
        all_source_files=("${filtered_files[@]}")
        log "INFO" "process_backfill: limited to ${CLI_BACKFILL_DAYS} most recent unarchived days (cutoff=${cutoff_date}), ${#all_source_files[@]} file(s)"
    fi

    log "INFO" "process_backfill: processing ${#all_source_files[@]} file(s) across all groups"

    # Estimate total space needed
    local estimate_list="${all_source_files[*]}"
    local total_estimated
    total_estimated=$(estimate_group_uncompressed_size "${estimate_list}" "${history_file}")

    local available_bytes
    available_bytes=$(df --output=avail -B1 "${ZPAQ_TEMP_DIR_ACTIVE}" 2>/dev/null | tail -1 | tr -d '[:space:]')

    # Backfill space check includes the 100 GB hard floor
    local floor_bytes
    floor_bytes=$(awk -v g="${BACKFILL_MIN_FREE_GB:-100}" 'BEGIN { printf "%d", g * 1073741824 }')
    local total_required
    total_required=$(awk -v n="${total_estimated}" -v h="${ZPAQ_HEADROOM_RATIO:-0.30}" -v fl="${floor_bytes}" \
        'BEGIN { printf "%d", int(n * (1 + h)) + fl }')

    if (( available_bytes < total_required )); then
        local avail_gb
        avail_gb=$(awk -v b="${available_bytes}" 'BEGIN { printf "%.1f", b/1073741824 }')
        local req_gb
        req_gb=$(awk -v b="${total_required}" 'BEGIN { printf "%.1f", b/1073741824 }')
        log "WARN" "process_backfill: insufficient space for full backfill — need ${req_gb} GB, have ${avail_gb} GB"
        log "WARN" "  Deferring oldest groups to fit within available space..."

        # Trim oldest groups until we fit
        local trimmed_files=()
        local running_estimate=0
        for f in "${all_source_files[@]}"; do
            local fsz
            fsz=$(estimate_group_uncompressed_size "${f}" "${history_file}")
            local projected
            projected=$(awk -v r="${running_estimate}" -v n="${fsz}" -v h="${ZPAQ_HEADROOM_RATIO:-0.30}" -v fl="${floor_bytes}" \
                'BEGIN { printf "%d", int((r+n) * (1+h)) + fl }')
            if (( projected <= available_bytes )); then
                trimmed_files+=("${f}")
                running_estimate=$(( running_estimate + fsz ))
            else
                local fd
                fd=$(extract_date_from_filename "${f}")
                log "WARN" "  Deferring: ${f} (date=${fd})"
            fi
        done
        all_source_files=("${trimmed_files[@]}")
        log "INFO" "process_backfill: after trimming: ${#all_source_files[@]} file(s) will be processed"
    fi

    if (( ${#all_source_files[@]} == 0 )); then
        log "ERROR" "process_backfill: no files fit within available space — aborting backfill"
        return 1
    fi

    if [[ "${CLI_DRY_RUN}" == true ]]; then
        log "INFO" "process_backfill: DRY-RUN — would download and add ${#all_source_files[@]} file(s)"
        for f in "${all_source_files[@]}"; do
            log "INFO" "  + ${f}"
        done
        return 0
    fi

    # Fragment check
    if ! multipart_manifest_check_fragment "${manifest_path}" "${ZPAQ_FRAGMENT}"; then
        log "ERROR" "process_backfill: fragment mismatch — aborting"
        return 1
    fi

    # Download and decompress all files
    local decompressed_rel_paths=()
    for f in "${all_source_files[@]}"; do
        local local_path
        if ! local_path=$(download_source_file "${f}" "${ZPAQ_TEMP_DIR_ACTIVE}"); then
            log "ERROR" "process_backfill: download failed for ${f} — aborting"
            return 1
        fi

        if ! decompress_file "${local_path}" "${ZPAQ_TEMP_DIR_ACTIVE}" "${ZPAQ_TEMP_DIR_ACTIVE}" "${history_file}"; then
            log "ERROR" "process_backfill: decompression failed for ${local_path} — aborting"
            return 1
        fi

        local rel_path="${local_path#${ZPAQ_TEMP_DIR_ACTIVE}/}"
        rel_path="${rel_path%.xz}"
        rel_path="${rel_path%.bz2}"
        rel_path="${rel_path%.gz}"
        rel_path="${rel_path%.zip}"
        decompressed_rel_paths+=("${rel_path}")
    done

    log "INFO" "process_backfill: all files downloaded and decompressed — starting zpaqfranz add"

    # zpaqfranz add (single invocation for all files)
    local archive_pat
    archive_pat=$(archive_pattern)
    local add_rc=0
    zpaq_multipart_add "${archive_pat}" decompressed_rel_paths "${ZPAQ_TEMP_DIR_ACTIVE}" || add_rc=$?

    if (( add_rc != 0 )); then
        log "ERROR" "process_backfill: zpaqfranz add failed"
        return 1
    fi

    # Find new part
    local new_part
    new_part=$(find "${ZPAQ_LOCAL_DIR}" -maxdepth 1 \
        -name "${ARG_BASENAME}[0-9][0-9][0-9][0-9][0-9][0-9][0-9].zpaq" \
        | sort | tail -1)

    if [[ -z "${new_part}" ]]; then
        log "ERROR" "process_backfill: could not find newly created part file"
        return 1
    fi

    log "INFO" "process_backfill: new part: $(basename "${new_part}")"

    # Upload
    if ! zpaq_multipart_upload_part "${new_part}" "${SFTP_REMOTE_DIR}" "${ZPAQ_TEMP_DIR_ACTIVE}"; then
        log "ERROR" "process_backfill: upload failed"
        return 1
    fi

    # Update manifest
    local part_sha256 part_size partname
    part_sha256=$(sha256sum "${new_part}" | awk '{print $1}')
    part_size=$(stat -c "%s" "${new_part}")
    partname=$(basename "${new_part}")

    [[ "${MP_MANIFEST_TOTAL_PARTS}" -eq 0 || -z "${MP_MANIFEST_FRAGMENT}" ]] && \
        MP_MANIFEST_FRAGMENT="${ZPAQ_FRAGMENT}"

    multipart_manifest_add_part "${partname}" "${part_size}" "${part_sha256}"
    multipart_manifest_write "${manifest_path}"
    zpaq_multipart_upload_manifest "${manifest_path}" "${SFTP_REMOTE_DIR}" || \
        log "WARN" "process_backfill: manifest upload failed (non-fatal)"

    # Update cache
    for f in "${decompressed_rel_paths[@]}"; do
        ZPAQ_ARCHIVE_CONTENTS["${f}"]=1
    done

    # Cleanup
    for f in "${decompressed_rel_paths[@]}"; do
        rm -f "${ZPAQ_TEMP_DIR_ACTIVE}/${f}"
    done

    log "INFO" "process_backfill: ===== BACKFILL COMPLETE ====="
    return 0
}

# ============================================================
# Main
# ============================================================
main() {
    parse_args "$@"
    load_multi_config
    validate_multi_config

    # Setup logging (after config so LOG_DIR is known)
    setup_multi_logging

    # Now log() is available
    log "INFO" "===== ${SCRIPT_NAME} starting ====="
    log "INFO" "basename=${ARG_BASENAME} sources=${#ARG_SOURCES[@]} backfill=${CLI_BACKFILL} dry-run=${CLI_DRY_RUN}"

    # Setup temp dir and lock
    setup_temp_dir
    trap 'trap_cleanup' EXIT INT TERM
    acquire_multi_lock

    # Detect tools
    check_dependencies
    detect_zpaqfranz
    zpaq_calc_threads "${CLI_ZPAQ_THREADS}"
    detect_decompressor

    # Ensure local archive directory exists
    mkdir -p "${ZPAQ_LOCAL_DIR}"

    local manifest_path
    manifest_path=$(multipart_manifest_path "${ARG_BASENAME}" "${ZPAQ_LOCAL_DIR}")
    local history_file="${ZPAQ_LOCAL_DIR}/${ARG_BASENAME}.size_history"
    local archive_pat
    archive_pat=$(archive_pattern)

    # Conflict check
    if ! check_archive_format_conflict "${ARG_BASENAME}" "${ZPAQ_LOCAL_DIR}" \
            "${SFTP_REMOTE_DIR}" "${ZPAQ_TEMP_DIR_ACTIVE}"; then
        log "ERROR" "Archive format conflict detected — aborting"
        exit 1
    fi

    # Load local manifest if it exists
    if [[ -f "${manifest_path}" ]]; then
        multipart_manifest_read "${manifest_path}"
        MP_MANIFEST_BASENAME="${ARG_BASENAME}"
    else
        # Initialize in-memory state for a new archive
        MP_MANIFEST_BASENAME="${ARG_BASENAME}"
        MP_MANIFEST_QUESTION_MARKS="${ZPAQ_MULTIPART_QUESTION_MARKS:-7}"
        MP_MANIFEST_FRAGMENT="${ZPAQ_FRAGMENT:-3}"
        MP_MANIFEST_TOTAL_PARTS=0
        MP_MANIFEST_TOTAL_SIZE=0
    fi

    # Pre-add remote sync
    log "INFO" "Running pre-add remote sync check..."
    if ! zpaq_multipart_remote_sync \
            "${ARG_BASENAME}" "${ZPAQ_LOCAL_DIR}" "${SFTP_REMOTE_DIR}" \
            "${manifest_path}" "${ZPAQ_TEMP_DIR_ACTIVE}"; then
        log "ERROR" "Remote sync failed — aborting"
        exit 1
    fi

    # Build archive content cache (single zpaqfranz l scan)
    zpaq_multipart_build_cache "${archive_pat}"

    # Expand sources and group by date
    log "INFO" "Expanding sources and grouping by date..."
    local all_files=""
    expand_sources all_files

    if [[ -z "${all_files}" ]]; then
        log "WARN" "No source files found matching the given patterns — nothing to do"
        exit 0
    fi

    declare -A date_groups=()
    group_files_by_date "${all_files}" date_groups

    local group_count="${#date_groups[@]}"
    log "INFO" "Found ${group_count} date group(s)"

    if (( group_count == 0 )); then
        log "INFO" "No groups to process — exiting"
        exit 0
    fi

    # Sort dates oldest-first (YYYYMMDD is lexicographically safe)
    local sorted_dates
    sorted_dates=$(printf '%s\n' "${!date_groups[@]}" | sort)

    # Local size warning
    check_local_size_warning

    # Process groups
    if [[ "${CLI_BACKFILL}" == true ]]; then
        process_backfill date_groups "${sorted_dates}" "${manifest_path}" "${history_file}"
    else
        local date_key
        for date_key in ${sorted_dates}; do
            process_group "${date_key}" "${date_groups[${date_key}]}" \
                "${manifest_path}" "${history_file}"
        done
    fi

    log "INFO" "===== ${SCRIPT_NAME} finished ====="
}

main "$@"