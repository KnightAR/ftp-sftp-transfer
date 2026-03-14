#!/usr/bin/env bash
# ============================================================
# transfer.sh — FTP to SFTP Transfer Script
#
# Purpose : Mirror files from an FTP server to an SFTP server,
#           with size-based overwrite detection, parallel
#           workers, mtime-based FTP retention/deletion, and
#           structured logging.
#
# OS      : Ubuntu Linux
# Requires: lftp, sshpass, sftp (openssh-client)
#
# Usage   : ./transfer.sh [OPTIONS]
#   -c FILE   Path to config file       (default: ./transfer.conf)
#   -e FILE   Path to exclusion list    (default: value in config)
#   -t DIR    Override temp directory   (this run only)
#   -d        Enable dry-run mode       (this run only)
#   -n        Disable FTP deletion      (this run only)
#   -p N      Override max parallel workers (this run only)
#   -v        Verbose / DEBUG to stdout (this run only)
#   -h        Show this help message
#
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# ============================================================
# SECTION 1 — CONSTANTS & DEFAULTS
# ============================================================

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SCRIPT_VERSION="1.0.0"

# Default config path (overridden by -c flag)
DEFAULT_CONFIG="${SCRIPT_DIR}/transfer.conf"

# PID lock file
LOCK_FILE="/tmp/ftp_sftp_transfer.lock"
LOCK_FD=9

# Runtime state
TEMP_DIR_CREATED=false
LOG_FILE=""
ERROR_LOG_FILE=""
FTP_CONNECT_STR=""       # Assembled lftp connection string

# Counters (updated by workers via temp files, merged at end)
CNT_SCANNED=0
CNT_TRANSFERRED=0
CNT_OVERWRITTEN=0
CNT_SKIPPED=0
CNT_DELETED=0
CNT_ERRORS=0

RUN_START_TIME=""
RUN_START_EPOCH=0

# ============================================================
# SECTION 2 — CLI FLAG PARSING
# ============================================================

# CLI override variables (empty = use config file value)
CLI_CONFIG=""
CLI_EXCLUDE_LIST=""
CLI_TEMP_DIR=""
CLI_DRY_RUN=""
CLI_DELETE_FROM_FTP=""
CLI_MAX_PARALLEL=""
CLI_VERBOSE=false

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — FTP to SFTP Transfer Script

Usage: ${SCRIPT_NAME} [OPTIONS]

Options:
  -c FILE   Path to config file           (default: ./transfer.conf)
  -e FILE   Path to exclusion list        (default: value in config)
  -t DIR    Override temp/staging dir     (this run only)
  -d        Enable dry-run mode           (no files moved or deleted)
  -n        Disable FTP deletion          (transfer only, no deletes)
  -p N      Override max parallel workers (this run only)
  -v        Verbose output (DEBUG level)  (stdout + log)
  -h        Show this help message

Examples:
  ${SCRIPT_NAME}                          # Normal run with ./transfer.conf
  ${SCRIPT_NAME} -d                       # Dry run (no changes made)
  ${SCRIPT_NAME} -d -v                    # Dry run with verbose output
  ${SCRIPT_NAME} -c /etc/transfer.conf    # Use alternate config file
  ${SCRIPT_NAME} -n -p 1                  # No FTP deletion, single worker
EOF
    exit 0
}

parse_args() {
    while getopts ":c:e:t:p:dnvh" opt; do
        case "${opt}" in
            c) CLI_CONFIG="${OPTARG}" ;;
            e) CLI_EXCLUDE_LIST="${OPTARG}" ;;
            t) CLI_TEMP_DIR="${OPTARG}" ;;
            p) CLI_MAX_PARALLEL="${OPTARG}" ;;
            d) CLI_DRY_RUN="true" ;;
            n) CLI_DELETE_FROM_FTP="false" ;;
            v) CLI_VERBOSE=true ;;
            h) usage ;;
            :) echo "ERROR: Option -${OPTARG} requires an argument." >&2; exit 1 ;;
            \?) echo "ERROR: Unknown option -${OPTARG}." >&2; exit 1 ;;
        esac
    done
}

# ============================================================
# SECTION 3 — CONFIG LOADING & VALIDATION
# ============================================================

load_config() {
    local config_file="${CLI_CONFIG:-${DEFAULT_CONFIG}}"

    if [[ ! -f "${config_file}" ]]; then
        echo "ERROR: Config file not found: ${config_file}" >&2
        echo "       Create one based on transfer.conf.example or specify -c FILE" >&2
        exit 1
    fi

    # Warn if config file is world-readable (credentials at risk)
    local perms
    perms=$(stat -c "%a" "${config_file}")
    if [[ "${perms}" != "600" && "${perms}" != "400" ]]; then
        echo "WARNING: Config file '${config_file}' has permissions ${perms}." >&2
        echo "         Credentials may be exposed. Run: chmod 600 '${config_file}'" >&2
    fi

    # shellcheck source=/dev/null
    source "${config_file}"

    # Apply CLI overrides (flags take precedence over config values)
    [[ -n "${CLI_EXCLUDE_LIST}" ]]  && EXCLUDE_LIST="${CLI_EXCLUDE_LIST}"
    [[ -n "${CLI_TEMP_DIR}" ]]      && TEMP_DIR="${CLI_TEMP_DIR}"
    [[ -n "${CLI_DRY_RUN}" ]]       && DRY_RUN="${CLI_DRY_RUN}"
    [[ -n "${CLI_DELETE_FROM_FTP}" ]] && DELETE_FROM_FTP="${CLI_DELETE_FROM_FTP}"
    [[ -n "${CLI_MAX_PARALLEL}" ]]  && MAX_PARALLEL="${CLI_MAX_PARALLEL}"

    validate_config
}

validate_config() {
    local errors=0

    check_var() {
        local var_name="$1"
        local var_value="${!var_name:-}"
        if [[ -z "${var_value}" ]]; then
            echo "ERROR: Required config variable '${var_name}' is not set." >&2
            (( errors++ )) || true
        fi
    }

    check_var "FTP_HOST"
    check_var "FTP_PORT"
    check_var "FTP_USER"
    check_var "FTP_PASS"
    check_var "FTP_REMOTE_DIR"
    check_var "SFTP_HOST"
    check_var "SFTP_PORT"
    check_var "SFTP_USER"
    check_var "SFTP_PASS"
    check_var "SFTP_REMOTE_DIR"
    check_var "RETENTION_DAYS"
    check_var "MAX_PARALLEL"
    check_var "LOG_DIR"
    check_var "LOG_RETENTION_DAYS"

    # Validate numeric values
    if ! [[ "${RETENTION_DAYS:-}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: RETENTION_DAYS must be a positive integer, got: '${RETENTION_DAYS:-}'" >&2
        (( errors++ )) || true
    fi
    if ! [[ "${MAX_PARALLEL:-}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: MAX_PARALLEL must be a positive integer, got: '${MAX_PARALLEL:-}'" >&2
        (( errors++ )) || true
    fi
    if ! [[ "${LOG_RETENTION_DAYS:-}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: LOG_RETENTION_DAYS must be a positive integer, got: '${LOG_RETENTION_DAYS:-}'" >&2
        (( errors++ )) || true
    fi
    if ! [[ "${FTP_PORT:-}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: FTP_PORT must be a number, got: '${FTP_PORT:-}'" >&2
        (( errors++ )) || true
    fi
    if ! [[ "${SFTP_PORT:-}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: SFTP_PORT must be a number, got: '${SFTP_PORT:-}'" >&2
        (( errors++ )) || true
    fi

    if (( errors > 0 )); then
        echo "ERROR: ${errors} configuration error(s) found. Please fix transfer.conf and retry." >&2
        exit 1
    fi
}

# ============================================================
# SECTION 4 — DEPENDENCY CHECK WITH INTERACTIVE INSTALL PROMPT
# ============================================================

# Map of binary → apt package name
declare -A DEP_PACKAGES=(
    [lftp]="lftp"
    [sshpass]="sshpass"
    [sftp]="openssh-client"
)

check_dependencies() {
    local missing=()
    local missing_pkgs=()

    echo "Checking required dependencies..."

    for binary in "${!DEP_PACKAGES[@]}"; do
        if ! command -v "${binary}" &>/dev/null; then
            missing+=("${binary}")
            missing_pkgs+=("${DEP_PACKAGES[${binary}]}")
        else
            echo "  [OK] ${binary} ($(command -v "${binary}"))"
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        echo "  All dependencies satisfied."
        echo ""
        return 0
    fi

    # --- One or more binaries are missing ---
    echo ""
    echo "============================================================"
    echo " MISSING DEPENDENCIES DETECTED"
    echo "============================================================"
    echo " The following required binaries were not found on this system:"
    echo ""
    for i in "${!missing[@]}"; do
        echo "   - ${missing[$i]}  (package: ${missing_pkgs[$i]})"
    done
    echo ""

    # Build the install command for only the missing packages
    # De-duplicate packages in case two binaries share one package
    local unique_pkgs
    unique_pkgs=$(printf '%s\n' "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')
    local install_cmd="sudo apt-get install -y ${unique_pkgs}"

    echo " To install the missing dependencies, run:"
    echo "   ${install_cmd}"
    echo "============================================================"
    echo ""

    # Detect whether we are running interactively
    if [[ -t 0 ]]; then
        # Interactive terminal — prompt the user
        local answer=""
        while true; do
            read -rp " Would you like to run this command now? [y/N]: " answer
            case "${answer,,}" in
                y|yes)
                    echo ""
                    echo " Running: ${install_cmd}"
                    echo "------------------------------------------------------------"
                    eval "${install_cmd}"
                    local install_exit=$?
                    if (( install_exit == 0 )); then
                        echo "------------------------------------------------------------"
                        echo " Installation complete. Re-checking dependencies..."
                        echo ""
                        # Re-verify all binaries are now present
                        local still_missing=()
                        for binary in "${missing[@]}"; do
                            if ! command -v "${binary}" &>/dev/null; then
                                still_missing+=("${binary}")
                            else
                                echo "  [OK] ${binary} now found at: $(command -v "${binary}")"
                            fi
                        done
                        if (( ${#still_missing[@]} > 0 )); then
                            echo ""
                            echo "ERROR: The following binaries are still missing after installation:" >&2
                            printf '  - %s\n' "${still_missing[@]}" >&2
                            echo "       Please install them manually and re-run the script." >&2
                            exit 1
                        fi
                        echo ""
                        echo " All dependencies are now satisfied. Continuing..."
                        echo ""
                        return 0
                    else
                        echo ""
                        echo "ERROR: apt-get installation failed (exit code ${install_exit})." >&2
                        echo "       Please install the packages manually and re-run the script." >&2
                        exit 1
                    fi
                    ;;
                n|no|"")
                    echo ""
                    echo " Aborting. Please install the missing dependencies manually:"
                    echo "   ${install_cmd}"
                    echo " Then re-run the script."
                    exit 1
                    ;;
                *)
                    echo " Please answer 'y' (yes) or 'n' (no)."
                    ;;
            esac
        done
    else
        # Non-interactive (cron, CI, pipe) — just exit with error
        echo "ERROR: Running non-interactively — cannot prompt for installation." >&2
        echo "       Please install missing packages manually and re-run the script:" >&2
        echo "         ${install_cmd}" >&2
        exit 1
    fi
}

# ============================================================
# SECTION 5 — LOGGING
# ============================================================

setup_logging() {
    mkdir -p "${LOG_DIR}"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    LOG_FILE="${LOG_DIR}/transfer_${timestamp}.log"
    ERROR_LOG_FILE="${LOG_DIR}/errors_$(date '+%Y%m%d').log"
    touch "${LOG_FILE}" "${ERROR_LOG_FILE}"
}

# log LEVEL "message"
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[${timestamp}] [${level}]  ${message}"

    # Always write to general log
    echo "${line}" >> "${LOG_FILE}"

    # Write errors to dedicated error log as well
    if [[ "${level}" == "ERROR" ]]; then
        echo "${line}" >> "${ERROR_LOG_FILE}"
    fi

    # Write to stdout based on level and verbosity
    if [[ "${level}" == "ERROR" ]]; then
        echo "${line}" >&2
    elif [[ "${level}" == "WARN" ]]; then
        echo "${line}"
    elif [[ "${level}" == "INFO" ]]; then
        echo "${line}"
    elif [[ "${level}" == "DEBUG" ]] && [[ "${CLI_VERBOSE}" == true ]]; then
        echo "${line}"
    fi
}

rotate_logs() {
    if [[ ! -d "${LOG_DIR}" ]]; then
        return 0
    fi

    local removed=0
    while IFS= read -r -d '' old_log; do
        rm -f "${old_log}"
        (( removed++ )) || true
    done < <(find "${LOG_DIR}" -maxdepth 1 -name "transfer_*.log" \
                  -mtime +"${LOG_RETENTION_DAYS}" -print0 2>/dev/null)

    if (( removed > 0 )); then
        log "INFO" "Log rotation: removed ${removed} general log(s) older than ${LOG_RETENTION_DAYS} days"
    else
        log "DEBUG" "Log rotation: no general logs older than ${LOG_RETENTION_DAYS} days found"
    fi
    # Note: errors_*.log files are intentionally never auto-deleted
}

# ============================================================
# SECTION 6 — PID LOCK FILE
# ============================================================

acquire_lock() {
    eval "exec ${LOCK_FD}>'${LOCK_FILE}'"
    if ! flock -n "${LOCK_FD}"; then
        local existing_pid
        existing_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "unknown")
        echo "ERROR: Another instance of ${SCRIPT_NAME} is already running (PID: ${existing_pid})." >&2
        echo "       If this is incorrect, remove the lock file: ${LOCK_FILE}" >&2
        exit 1
    fi
    echo $$ > "${LOCK_FILE}"
}

release_lock() {
    flock -u "${LOCK_FD}" 2>/dev/null || true
    rm -f "${LOCK_FILE}"
}

# ============================================================
# SECTION 7 — TEMP DIRECTORY SETUP
# ============================================================

setup_temp_dir() {
    if [[ -n "${TEMP_DIR:-}" ]]; then
        # User-specified temp dir
        mkdir -p "${TEMP_DIR}"
        chmod 700 "${TEMP_DIR}"
        log "DEBUG" "Using custom temp directory: ${TEMP_DIR}"
    else
        # Create a secure system temp dir
        TEMP_DIR=$(mktemp -d -t ftp_sftp_XXXXXXXXXX)
        chmod 700 "${TEMP_DIR}"
        TEMP_DIR_CREATED=true
        log "DEBUG" "Created temp directory: ${TEMP_DIR}"
    fi

    # Create staging subdirectories for workers
    mkdir -p "${TEMP_DIR}/staging"
    mkdir -p "${TEMP_DIR}/workers"

    # Work queue files
    touch "${TEMP_DIR}/work_queue.txt"
    touch "${TEMP_DIR}/work_queue.lock"
}

cleanup_temp() {
    if [[ "${TEMP_DIR_CREATED}" == true ]] && [[ -d "${TEMP_DIR:-}" ]]; then
        rm -rf "${TEMP_DIR}"
        log "DEBUG" "Removed temp directory: ${TEMP_DIR}"
    else
        # Custom temp dir — only clean up contents, not the dir itself
        if [[ -d "${TEMP_DIR:-}" ]]; then
            rm -rf "${TEMP_DIR:?}/staging"
            rm -rf "${TEMP_DIR:?}/workers"
            rm -rf "${TEMP_DIR:?}/mirror_dummy"
            rm -f  "${TEMP_DIR}/work_queue.txt"
            rm -f  "${TEMP_DIR}/work_queue.lock"
            rm -f  "${TEMP_DIR}/ftp_listing.txt"
            log "DEBUG" "Cleaned contents of custom temp directory: ${TEMP_DIR}"
        fi
    fi
}

# ============================================================
# SECTION 8 — EXCLUSION LIST
# ============================================================

# Global array to hold loaded exclusion patterns
EXCLUSION_PATTERNS=()

load_exclusions() {
    if [[ -z "${EXCLUDE_LIST:-}" ]] || [[ ! -f "${EXCLUDE_LIST}" ]]; then
        log "WARN" "Exclusion list not found or not set: '${EXCLUDE_LIST:-}' — proceeding without exclusions"
        return 0
    fi

    local count=0
    while IFS= read -r line; do
        # Strip inline comments
        line="${line%%#*}"
        # Strip leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        # Skip empty lines
        [[ -z "${line}" ]] && continue
        EXCLUSION_PATTERNS+=("${line}")
        (( count++ )) || true
    done < "${EXCLUDE_LIST}"

    log "INFO" "Loaded ${count} exclusion pattern(s) from: ${EXCLUDE_LIST}"
}

is_excluded() {
    local filename="$1"
    local pattern
    for pattern in "${EXCLUSION_PATTERNS[@]}"; do
        # SC2053: unquoted RHS is intentional — enables glob/wildcard pattern matching
        # shellcheck disable=SC2053
        if [[ "${filename}" == ${pattern} ]]; then
            return 0  # excluded
        fi
    done
    return 1  # not excluded
}

# ============================================================
# SECTION 9 — FTP CONNECTION (PLAIN FTP, TLS DISABLED)
# ============================================================

setup_ftp_connection() {
    # TLS is explicitly disabled — the server does not use or support TLS.
    # This matches the working lftp invocation:
    #   lftp -e "set ftp:ssl-allow no; ls /; quit" -u user,pass host
    FTP_CONNECT_STR="set ftp:ssl-allow no; set net:timeout 30; set net:max-retries 3;"

    log "INFO" "FTP connection configured — plain FTP (TLS disabled) to ${FTP_HOST}:${FTP_PORT}"

    # Verify the connection is reachable before proceeding
    # Host is passed as a positional argument (not inside -e) matching:
    #   lftp -e "set ftp:ssl-allow no; ls /; quit" -u user,pass host
    local test_result
    test_result=$(lftp \
        -e "${FTP_CONNECT_STR} ls; quit" \
        -u "${FTP_USER}","${FTP_PASS}" \
        "${FTP_HOST}:${FTP_PORT}" 2>&1) \
        && local ftp_ok=true || local ftp_ok=false

    if [[ "${ftp_ok}" == true ]]; then
        log "INFO" "FTP connection successful"
    else
        log "ERROR" "FTP connection failed to ${FTP_HOST}:${FTP_PORT}"
        log "ERROR" "lftp output: ${test_result}"
        exit 1
    fi
}

# Run an lftp command against the FTP server
# Matches the working manual invocation:
#   lftp -e "set ftp:ssl-allow no; <cmds>; quit" -u user,pass host
# Usage: run_lftp <lftp_commands>
run_lftp() {
    local cmds="$1"
    lftp \
        -e "${FTP_CONNECT_STR} ${cmds}; quit" \
        -u "${FTP_USER}","${FTP_PASS}" \
        "${FTP_HOST}:${FTP_PORT}" 2>&1
}

# ============================================================
# SECTION 10 — FTP FILE LISTING
# ============================================================

get_ftp_file_list() {
    log "INFO" "Starting recursive FTP file listing from: ${FTP_REMOTE_DIR}"

    local listing_file="${TEMP_DIR}/ftp_listing.txt"
    local raw_file="${TEMP_DIR}/ftp_mirror_raw.txt"
    local paths_file="${TEMP_DIR}/ftp_paths.txt"
    local dirs_file="${TEMP_DIR}/ftp_dirs.txt"
    local ls_tmp="${TEMP_DIR}/ftp_ls.tmp"

    # ----------------------------------------------------------------
    # Step 1: Get recursive file list via mirror --dry-run
    # Parse "Transferring file `relative/path'" lines → full FTP paths
    # ----------------------------------------------------------------
    log "DEBUG" "Retrieving recursive file listing via mirror --dry-run ..."

    local mirror_output
    mirror_output=$(lftp \
        -e "${FTP_CONNECT_STR} mirror --dry-run --verbose=3 ${FTP_REMOTE_DIR} ${TEMP_DIR}/mirror_dummy; quit" \
        -u "${FTP_USER}","${FTP_PASS}" \
        "${FTP_HOST}:${FTP_PORT}" 2>&1)
    local mirror_exit=$?

    printf '%s\n' "${mirror_output}" > "${raw_file}"

    if (( mirror_exit != 0 )); then
        log "ERROR" "FTP mirror --dry-run failed (exit ${mirror_exit})"
        log "ERROR" "lftp output: ${mirror_output}"
        exit 1
    fi

    # Parse full FTP paths from mirror output
    true > "${paths_file}"
    while IFS= read -r line; do
        if [[ "${line}" =~ ^"Transferring file "\`([^\']*)\' ]]; then
            local relpath="${BASH_REMATCH[1]}"
            if [[ "${FTP_REMOTE_DIR}" == "/" ]]; then
                printf '/%s\n' "${relpath}" >> "${paths_file}"
            else
                printf '%s/%s\n' "${FTP_REMOTE_DIR}" "${relpath}" >> "${paths_file}"
            fi
        fi
    done < "${raw_file}"

    local total_paths
    total_paths=$(wc -l < "${paths_file}")

    if (( total_paths == 0 )); then
        log "WARN" "FTP listing returned 0 files. Nothing to transfer."
        log "DEBUG" "Mirror output sample: $(head -10 "${raw_file}" | tr '\n' '|')"
        true > "${listing_file}"
        cp "${listing_file}" "${TEMP_DIR}/work_queue.txt"
        return 0
    fi

    log "INFO" "Found ${total_paths} file path(s) on FTP. Retrieving file metadata..."

    # ----------------------------------------------------------------
    # Step 2: Get size + mtime via "ls <dir>" per unique directory.
    # cls --format is NOT supported on this server.
    # ls output format: perms links owner group SIZE MON DD TIME/YEAR NAME
    # e.g: -rw-r--r-- 1 100 ftpgroup 52428800 Jan 05 2025 helium_rewards_20250105.sql.bz2
    # run_lftp output is saved to a temp file before parsing (not piped).
    # ----------------------------------------------------------------
    true > "${listing_file}"

    # Collect unique parent directories from paths_file via dirname.
    # mirror --dry-run --verbose=3 outputs full relative paths including
    # subdirectory prefixes (e.g. "slim/file.sql.bz2"), so dirname correctly
    # extracts the parent directory for each file.
    true > "${dirs_file}"
    while IFS= read -r ftp_path; do
        [[ -z "${ftp_path}" ]] && continue
        dirname "${ftp_path}"
    done < "${paths_file}" | sort -u >> "${dirs_file}" || true

    local dir_count
    dir_count=$(wc -l < "${dirs_file}")
    log "DEBUG" "Directories to ls (${dir_count}): $(cat "${dirs_file}" | tr '\n' '|')"

    while IFS= read -r dir_path; do
        [[ -z "${dir_path}" ]] && continue

        # Use "ls DIR" — lftp sends LIST <dir> to the FTP server.
        # This correctly lists directory contents when the path is passed
        # directly (not via cd). The "cd DIR; ls" approach was incorrect
        # as it caused ls to list an unexpected working directory.
        true > "${ls_tmp}"
        run_lftp "ls ${dir_path}" > "${ls_tmp}" 2>/dev/null || true

        log "DEBUG" "ls ${dir_path} — sample: $(head -10 "${ls_tmp}" | tr '\n' '|')"

        # Parse each file line (starts with -)
        while IFS= read -r ls_line; do
            [[ -z "${ls_line}" ]]      && continue
            [[ "${ls_line}" != -* ]]   && continue

            # Parse ls columns: perms links owner group size mon day timeyr name
            # Use IFS=' ' locally so read splits on spaces (global IFS=$'\n\t')
            local size mon day timeyr name filepath epoch current_year
            IFS=' ' read -r _ _ _ _ size mon day timeyr name <<< "${ls_line}"

            [[ -z "${name}" ]]   && continue
            [[ -z "${size}" ]]   && continue
            [[ -z "${timeyr}" ]] && continue

            # Build full FTP path
            if [[ "${dir_path}" == "/" ]]; then
                filepath="/${name}"
            else
                filepath="${dir_path}/${name}"
            fi

            # Convert ls date to Unix epoch
            # timeyr = HH:MM (recent file, use current year) or YYYY (older file)
            current_year=$(date +%Y)
            if [[ "${timeyr}" =~ ^[0-9]{4}$ ]]; then
                epoch=$(date -d "${mon} ${day} ${timeyr} 00:00:00" +%s 2>/dev/null || echo 0)
            else
                epoch=$(date -d "${mon} ${day} ${current_year} ${timeyr}" +%s 2>/dev/null || echo 0)
            fi

            printf '%s %s %s\n' "${size}" "${epoch}" "${filepath}" >> "${listing_file}"

        done < "${ls_tmp}"

        log "DEBUG" "listing_file after ls ${dir_path}: $(wc -l < "${listing_file}") lines, sample: $(head -3 "${listing_file}" | tr '\n' '|')"

    done < "${dirs_file}"

    rm -f "${ls_tmp}"

    # Filter out any malformed lines (size must start with a digit)
    local clean_file="${listing_file}.clean"
    true > "${clean_file}"
    while IFS= read -r line; do
        [[ "${line}" =~ ^[0-9] ]] && printf '%s\n' "${line}" >> "${clean_file}" || true
    done < "${listing_file}"
    mv "${clean_file}" "${listing_file}"

    local final_count
    final_count=$(wc -l < "${listing_file}")

    if (( final_count == 0 )); then
        log "WARN" "File metadata retrieval returned 0 results."
        log "DEBUG" "paths_file sample: $(head -500 "${paths_file}" 2>/dev/null | tr '\n' '|')"
        log "DEBUG" "dirs_file contents: $(cat "${dirs_file}" 2>/dev/null | tr '\n' '|')"
    else
        log "INFO" "FTP metadata retrieved for ${final_count} file(s)"
    fi

    # Populate the work queue
    cp "${listing_file}" "${TEMP_DIR}/work_queue.txt"
}

# ============================================================
# SECTION 11 — SFTP HELPERS
# ============================================================

# Check if a file exists on SFTP and return its size (or "NOT_FOUND")
# Usage: sftp_get_size "remote/path/file.gz"
sftp_get_size() {
    local remote_path="$1"
    local result

    result=$(SSHPASS="${SFTP_PASS}" sshpass -e sftp \
        -P "${SFTP_PORT}" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=no \
        -o ConnectTimeout=15 \
        -o LogLevel=ERROR \
        -b <(printf 'ls -l %s\n' "${remote_path}") \
        "${SFTP_USER}@${SFTP_HOST}" 2>/dev/null \
        | awk 'NF>=9 && /^[-]/ {print $5}' \
        | head -1)

    if [[ -z "${result}" ]]; then
        echo "NOT_FOUND"
    else
        echo "${result}"
    fi
}

# Create a directory path recursively on SFTP
# Usage: sftp_mkdir_p "/ihub-db-backups/db/2024"
sftp_mkdir_p() {
    local full_path="$1"
    local batch_cmds=""
    local current=""

    # Build mkdir commands for every path component
    IFS='/' read -ra parts <<< "${full_path}"
    for part in "${parts[@]}"; do
        [[ -z "${part}" ]] && continue
        current="${current}/${part}"
        batch_cmds+="-mkdir ${current}"$'\n'
    done

    # -mkdir is an sftp extension that ignores "already exists" errors
    # If not supported, fallback to regular mkdir (errors suppressed)
    SSHPASS="${SFTP_PASS}" sshpass -e sftp \
        -P "${SFTP_PORT}" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=no \
        -o ConnectTimeout=15 \
        -o LogLevel=ERROR \
        -b <(printf '%s' "${batch_cmds}") \
        "${SFTP_USER}@${SFTP_HOST}" &>/dev/null || true
}

# ============================================================
# SECTION 12 — FILE TRANSFER FUNCTION
# ============================================================

# Transfer a single file from FTP to SFTP
# Usage: transfer_file WORKER_ID FTP_PATH FTP_SIZE FTP_MTIME_EPOCH
# Returns: 0 on success, 1 on failure
# Sets global-scope result via worker result file
transfer_file() {
    local worker_id="$1"
    local ftp_path="$2"
    local ftp_size="$3"

    local basename_file
    basename_file=$(basename "${ftp_path}")

    # Build mirrored SFTP destination path
    # FTP path is already relative to root "/"
    local rel_path="${ftp_path}"
    local sftp_dest_path="${SFTP_REMOTE_DIR}${rel_path}"
    local sftp_dest_dir
    sftp_dest_dir=$(dirname "${sftp_dest_path}")

    # Staging area for this worker
    local staging_dir="${TEMP_DIR}/staging/worker_${worker_id}"
    mkdir -p "${staging_dir}"
    local local_file="${staging_dir}/${basename_file}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "INFO" "[DRY-RUN] Would transfer: ${ftp_path} → ${sftp_dest_path} (${ftp_size} bytes)"
        return 0
    fi

    # Step 1: Download from FTP to local staging
    log "DEBUG" "[W${worker_id}] Downloading: ${ftp_path} → ${local_file}"
    if ! run_lftp "get ${ftp_path} -o ${local_file}" &>/dev/null; then
        log "ERROR" "[W${worker_id}] FTP download failed: ${ftp_path}"
        rm -f "${local_file}"
        return 1
    fi

    # Step 2: Verify downloaded file size
    if [[ ! -f "${local_file}" ]]; then
        log "ERROR" "[W${worker_id}] Downloaded file not found at staging path: ${local_file}"
        return 1
    fi

    local local_size
    local_size=$(stat -c '%s' "${local_file}")
    if [[ "${local_size}" != "${ftp_size}" ]]; then
        log "ERROR" "[W${worker_id}] Download size mismatch (expected=${ftp_size}, got=${local_size}): ${ftp_path}"
        rm -f "${local_file}"
        return 1
    fi

    # Step 3: Ensure SFTP destination directory exists
    log "DEBUG" "[W${worker_id}] Ensuring SFTP directory exists: ${sftp_dest_dir}"
    sftp_mkdir_p "${sftp_dest_dir}"

    # Step 4: Upload to SFTP
    log "DEBUG" "[W${worker_id}] Uploading to SFTP: ${sftp_dest_path}"
    if ! SSHPASS="${SFTP_PASS}" sshpass -e sftp \
            -P "${SFTP_PORT}" \
            -o StrictHostKeyChecking=no \
            -o BatchMode=no \
            -o ConnectTimeout=30 \
            -o LogLevel=ERROR \
            -b <(printf 'put %s %s\n' "${local_file}" "${sftp_dest_path}") \
            "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
        log "ERROR" "[W${worker_id}] SFTP upload failed: ${sftp_dest_path}"
        rm -f "${local_file}"
        return 1
    fi

    # Step 5: Verify upload by re-checking SFTP file size
    local post_size
    post_size=$(sftp_get_size "${sftp_dest_path}")
    if [[ "${post_size}" != "${ftp_size}" ]]; then
        log "ERROR" "[W${worker_id}] Upload verification failed (expected=${ftp_size}, sftp_reported=${post_size}): ${sftp_dest_path}"
        rm -f "${local_file}"
        return 1
    fi

    log "INFO" "[W${worker_id}] Transferred OK [${ftp_size} bytes]: ${ftp_path} → ${sftp_dest_path}"
    rm -f "${local_file}"
    return 0
}

# ============================================================
# SECTION 13 — FTP DELETION
# ============================================================

delete_ftp_file() {
    local ftp_path="$1"
    local worker_id="${2:-0}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "INFO" "[DRY-RUN] Would delete from FTP: ${ftp_path}"
        return 0
    fi

    if [[ "${DELETE_FROM_FTP}" != "true" ]]; then
        log "DEBUG" "FTP deletion disabled — skipping: ${ftp_path}"
        return 0
    fi

    if run_lftp "rm ${ftp_path}" &>/dev/null; then
        log "INFO" "[W${worker_id}] Deleted from FTP (age ≥ ${RETENTION_DAYS}d, confirmed on SFTP): ${ftp_path}"
        return 0
    else
        log "ERROR" "[W${worker_id}] Failed to delete from FTP: ${ftp_path}"
        return 1
    fi
}

# ============================================================
# SECTION 14 — PER-FILE PROCESSING LOGIC
# ============================================================

process_file() {
    local worker_id="$1"
    local ftp_size="$2"
    local ftp_mtime="$3"
    local ftp_path="$4"

    local result_file="${TEMP_DIR}/workers/worker_${worker_id}.result"

    # Helper to increment worker counters
    inc_counter() {
        local counter="$1"
        local current
        current=$(grep "^${counter}=" "${result_file}" 2>/dev/null | cut -d= -f2 || echo 0)
        local new_val=$(( current + 1 ))
        if grep -q "^${counter}=" "${result_file}" 2>/dev/null; then
            sed -i "s/^${counter}=.*/${counter}=${new_val}/" "${result_file}"
        else
            echo "${counter}=${new_val}" >> "${result_file}"
        fi
    }

    inc_counter "SCANNED"

    local basename_file
    basename_file=$(basename "${ftp_path}")

    # 1. Skip dot files
    if [[ "${basename_file}" == .* ]]; then
        log "DEBUG" "[W${worker_id}] Skipping dot file: ${ftp_path}"
        inc_counter "SKIPPED"
        return 0
    fi

    # 2. Skip excluded files
    if is_excluded "${basename_file}"; then
        log "DEBUG" "[W${worker_id}] Skipping excluded file: ${ftp_path}"
        inc_counter "SKIPPED"
        return 0
    fi

    # 3. Build mirrored SFTP path
    local sftp_dest_path="${SFTP_REMOTE_DIR}${ftp_path}"

    # 4. Check current SFTP state
    local sftp_size
    sftp_size=$(sftp_get_size "${sftp_dest_path}")

    local transfer_needed=false
    local transfer_reason=""
    local is_overwrite=false

    if [[ "${sftp_size}" == "NOT_FOUND" ]]; then
        transfer_needed=true
        transfer_reason="new file (not on SFTP)"
    elif [[ "${sftp_size}" != "${ftp_size}" ]]; then
        if [[ "${OVERWRITE_ON_SIZE_DIFF}" == "true" ]]; then
            transfer_needed=true
            is_overwrite=true
            transfer_reason="size mismatch (FTP=${ftp_size}, SFTP=${sftp_size})"
        else
            log "WARN" "[W${worker_id}] Size mismatch, overwrite disabled — skipping: ${ftp_path} (FTP=${ftp_size}, SFTP=${sftp_size})"
            inc_counter "SKIPPED"
            return 0
        fi
    else
        log "DEBUG" "[W${worker_id}] Already synced with matching size — skipping: ${ftp_path}"
        inc_counter "SKIPPED"
        # Still fall through to retention check below
    fi

    # 5. Transfer if needed
    local transfer_success=false
    if [[ "${transfer_needed}" == true ]]; then
        log "INFO" "[W${worker_id}] Transferring (${transfer_reason}): ${ftp_path}"
        if transfer_file "${worker_id}" "${ftp_path}" "${ftp_size}" "${ftp_mtime}"; then
            transfer_success=true
            if [[ "${is_overwrite}" == true ]]; then
                inc_counter "OVERWRITTEN"
            else
                inc_counter "TRANSFERRED"
            fi
        else
            inc_counter "ERRORS"
            # Do not attempt FTP deletion if transfer failed
            return 0
        fi
    fi

    # 6. FTP Retention — mtime-based age check
    local now_epoch
    now_epoch=$(date +%s)
    local age_seconds=$(( now_epoch - ftp_mtime ))
    local age_days=$(( age_seconds / 86400 ))

    if (( age_days >= RETENTION_DAYS )) && [[ "${DELETE_FROM_FTP}" == "true" ]]; then
        # Only delete if we can confirm file exists on SFTP with correct size
        local confirmed_on_sftp=false

        if [[ "${transfer_success}" == true ]]; then
            confirmed_on_sftp=true
        elif [[ "${transfer_needed}" == false ]] && [[ "${sftp_size}" == "${ftp_size}" ]]; then
            # Was already synced correctly before this run
            confirmed_on_sftp=true
        fi

        if [[ "${confirmed_on_sftp}" == true ]]; then
            if delete_ftp_file "${ftp_path}" "${worker_id}"; then
                inc_counter "DELETED"
            else
                inc_counter "ERRORS"
            fi
        else
            log "WARN" "[W${worker_id}] File is ${age_days}d old but NOT confirmed on SFTP — skipping FTP deletion: ${ftp_path}"
        fi
    fi
}

# ============================================================
# SECTION 15 — PARALLEL WORKER MODEL
# ============================================================

# Worker process — reads lines from work queue atomically and processes them
worker_process() {
    local worker_id="$1"
    local result_file="${TEMP_DIR}/workers/worker_${worker_id}.result"
    local queue_file="${TEMP_DIR}/work_queue.txt"
    local lock_file="${TEMP_DIR}/work_queue.lock"

    # Initialise result counters
    cat > "${result_file}" <<EOF
SCANNED=0
TRANSFERRED=0
OVERWRITTEN=0
SKIPPED=0
DELETED=0
ERRORS=0
EOF

    log "DEBUG" "Worker ${worker_id} started (PID $$)"

    while true; do
        local line=""

        # Atomically read and remove the next line from the work queue
        (
            flock -x 200
            line=$(head -1 "${queue_file}" 2>/dev/null || true)
            if [[ -n "${line}" ]]; then
                # Remove the first line (sed -i '1d')
                sed -i '1d' "${queue_file}"
            fi
            echo "${line}"
        ) 200>"${lock_file}" > "${TEMP_DIR}/workers/worker_${worker_id}.next_line"

        line=$(cat "${TEMP_DIR}/workers/worker_${worker_id}.next_line")

        if [[ -z "${line}" ]]; then
            log "DEBUG" "Worker ${worker_id} — queue empty, exiting"
            break
        fi

        # Parse line: SIZE MTIME_EPOCH FILEPATH
        local ftp_size ftp_mtime ftp_path
        ftp_size=$(echo "${line}" | awk '{print $1}')
        ftp_mtime=$(echo "${line}" | awk '{print $2}')
        ftp_path=$(echo "${line}" | awk '{for(i=3;i<=NF;i++) printf "%s%s",$i,(i==NF?"\n":" ")}')

        if [[ -z "${ftp_size}" ]] || [[ -z "${ftp_mtime}" ]] || [[ -z "${ftp_path}" ]]; then
            log "WARN" "Worker ${worker_id} — malformed queue entry, skipping: '${line}'"
            continue
        fi

        process_file "${worker_id}" "${ftp_size}" "${ftp_mtime}" "${ftp_path}"
    done

    log "DEBUG" "Worker ${worker_id} finished"
}

run_parallel_workers() {
    local queue_size
    queue_size=$(wc -l < "${TEMP_DIR}/work_queue.txt")

    if (( queue_size == 0 )); then
        log "INFO" "Work queue is empty — nothing to process"
        return 0
    fi

    log "INFO" "Starting ${MAX_PARALLEL} parallel worker(s) to process ${queue_size} file(s)..."

    mkdir -p "${TEMP_DIR}/workers"

    local worker_pids=()
    for (( i=1; i<=MAX_PARALLEL; i++ )); do
        worker_process "${i}" &
        worker_pids+=($!)
        log "DEBUG" "Spawned worker ${i} (PID ${!})"
    done

    # Wait for all workers and capture exit codes
    local any_error=false
    for pid in "${worker_pids[@]}"; do
        if ! wait "${pid}"; then
            log "ERROR" "Worker process (PID ${pid}) exited with an error"
            any_error=true
        fi
    done

    if [[ "${any_error}" == true ]]; then
        log "WARN" "One or more worker processes encountered errors (see error log)"
    fi

    # Merge worker result files into global counters
    merge_worker_results
}

merge_worker_results() {
    for result_file in "${TEMP_DIR}/workers"/worker_*.result; do
        [[ -f "${result_file}" ]] || continue
        while IFS='=' read -r key value; do
            [[ -z "${key}" ]] && continue
            case "${key}" in
                SCANNED)     CNT_SCANNED=$(( CNT_SCANNED + value )) ;;
                TRANSFERRED) CNT_TRANSFERRED=$(( CNT_TRANSFERRED + value )) ;;
                OVERWRITTEN) CNT_OVERWRITTEN=$(( CNT_OVERWRITTEN + value )) ;;
                SKIPPED)     CNT_SKIPPED=$(( CNT_SKIPPED + value )) ;;
                DELETED)     CNT_DELETED=$(( CNT_DELETED + value )) ;;
                ERRORS)      CNT_ERRORS=$(( CNT_ERRORS + value )) ;;
            esac
        done < "${result_file}"
    done
}

# ============================================================
# SECTION 16 — RUN SUMMARY
# ============================================================

print_summary() {
    local end_epoch
    end_epoch=$(date +%s)
    local end_time
    end_time=$(date '+%Y-%m-%d %H:%M:%S')
    local duration=$(( end_epoch - RUN_START_EPOCH ))
    local duration_str
    if (( duration < 60 )); then
        duration_str="${duration}s"
    else
        duration_str="$(( duration / 60 ))m $(( duration % 60 ))s"
    fi

    local dry_run_label=""
    [[ "${DRY_RUN}" == "true" ]] && dry_run_label=" [DRY-RUN]"

    local summary
    summary=$(cat <<EOF

╔══════════════════════════════════════════╗
║         Transfer Run Summary${dry_run_label}
╠══════════════════════════════════════════╣
║  Started      : ${RUN_START_TIME}
║  Finished     : ${end_time}
║  Duration     : ${duration_str}
║  Workers used : ${MAX_PARALLEL}
╠══════════════════════════════════════════╣
║  Files Scanned      : ${CNT_SCANNED}
║  Files Transferred  : ${CNT_TRANSFERRED}
║  Files Overwritten  : ${CNT_OVERWRITTEN}
║  Files Skipped      : ${CNT_SKIPPED}
║  FTP Files Deleted  : ${CNT_DELETED}
║  Errors             : ${CNT_ERRORS}
╚══════════════════════════════════════════╝
EOF
)

    echo "${summary}"
    echo "${summary}" >> "${LOG_FILE}"

    if (( CNT_ERRORS > 0 )); then
        log "WARN" "Run completed with ${CNT_ERRORS} error(s). Check: ${ERROR_LOG_FILE}"
    else
        log "INFO" "Run completed successfully with no errors."
    fi
}

# ============================================================
# SECTION 17 — SIGNAL TRAPS & CLEANUP
# ============================================================

# Trap for unexpected exits (Ctrl+C, kill, errors)
trap_cleanup() {
    local exit_code=$?
    log "WARN" "Script interrupted or exited unexpectedly (exit code: ${exit_code}). Cleaning up..."
    cleanup_temp
    release_lock
    exit "${exit_code}"
}

trap trap_cleanup INT TERM EXIT

# ============================================================
# SECTION 18 — MAIN ENTRYPOINT
# ============================================================

main() {
    RUN_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    RUN_START_EPOCH=$(date +%s)

    # 1. Parse CLI flags
    parse_args "$@"

    # 2. Load and validate configuration
    load_config

    # 3. Setup logging (needs LOG_DIR from config)
    setup_logging

    log "INFO" "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} — Transfer run started (PID $$) ==="
    [[ "${DRY_RUN}" == "true" ]] && log "INFO" "*** DRY-RUN MODE ENABLED — No files will be moved or deleted ***"

    # 4. Check required dependencies (with interactive install prompt)
    check_dependencies

    # 5. Acquire PID lock (prevent overlapping cron runs)
    acquire_lock
    log "DEBUG" "Acquired PID lock: ${LOCK_FILE}"

    # 6. Setup temp/staging directory
    setup_temp_dir

    # 7. Load exclusion patterns
    load_exclusions

    # 8. Setup and verify FTP connection
    setup_ftp_connection

    # 9. Retrieve recursive FTP file listing → work queue
    get_ftp_file_list

    local queue_size
    queue_size=$(wc -l < "${TEMP_DIR}/work_queue.txt")
    log "INFO" "Work queue populated: ${queue_size} file(s) to evaluate"

    # 10. Run parallel workers
    run_parallel_workers

    # 11. Rotate old general logs
    rotate_logs

    # 12. Clean up temp directory
    cleanup_temp

    # 13. Release PID lock
    # (trap will also call this on exit, but explicit call is fine — release_lock is idempotent)
    release_lock

    # Remove the trap now that we're doing a clean exit
    trap - INT TERM EXIT

    # 14. Print and log run summary
    print_summary
}

# ============================================================
# ENTRYPOINT
# ============================================================
main "$@"