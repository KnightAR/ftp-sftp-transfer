#!/usr/bin/env bash
# ============================================================
# transfer.sh — FTP to SFTP Transfer Script
#
# Purpose : Mirror files from an FTP server to an SFTP server,
#           with size-based overwrite detection, decoupled
#           parallel FTP download + SFTP upload workers,
#           disk-space guarding, mtime-based FTP retention/
#           deletion, and structured logging.
#
# OS      : Ubuntu Linux
# Requires: lftp, sshpass, sftp (openssh-client)
#
# Usage   : ./transfer.sh [OPTIONS]
#   -c FILE   Path to config file           (default: ./transfer.conf)
#   -e FILE   Path to exclusion list        (default: value in config)
#   -t DIR    Override temp directory       (this run only)
#   -d        Enable dry-run mode           (this run only)
#   -n        Disable FTP deletion          (this run only)
#   -f N      Override FTP download workers (this run only)
#   -s N      Override SFTP upload workers  (this run only)
#   -v        Verbose / DEBUG to stdout     (this run only)
#   -V        Verify mode: re-download all FTP files, checksum-verify
#             every SFTP copy, then run retention deletions
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
readonly SCRIPT_VERSION="2.1.0"

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

# Worker PID tracking — populated by run_pipeline, read by trap_cleanup
# so that Ctrl+C / SIGTERM kills workers before staging is deleted
WORKER_PIDS=()

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
CLI_FTP_WORKERS=""
CLI_SFTP_WORKERS=""
CLI_VERBOSE=false
CLI_VERIFY_MODE=false   # -V / --verify: re-download all, checksum-verify, then delete

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — FTP to SFTP Transfer Script

Usage: ${SCRIPT_NAME} [OPTIONS]

Options:
  -c FILE   Path to config file               (default: ./transfer.conf)
  -e FILE   Path to exclusion list            (default: value in config)
  -t DIR    Override temp/staging dir         (this run only)
  -d        Enable dry-run mode               (no files moved or deleted)
  -n        Disable FTP deletion              (transfer only, no deletes)
  -f N      Override FTP download workers     (this run only)
  -s N      Override SFTP upload workers      (this run only)
  -v        Verbose output (DEBUG level)      (stdout + log)
  -V        Verify mode: re-download every FTP file regardless of SFTP
            state, checksum-verify the SFTP copy, then run retention
            deletions.  Use after a bulk upload to confirm all files
            before FTP deletion begins.
  -h        Show this help message

Examples:
  ${SCRIPT_NAME}                              # Normal run with ./transfer.conf
  ${SCRIPT_NAME} -d                           # Dry run (no changes made)
  ${SCRIPT_NAME} -d -v                        # Dry run with verbose output
  ${SCRIPT_NAME} -c /etc/transfer.conf        # Use alternate config file
  ${SCRIPT_NAME} -n -f 1                      # No FTP deletion, single download worker
  ${SCRIPT_NAME} -f 2 -s 10                   # 2 FTP downloaders, 10 SFTP uploaders
  ${SCRIPT_NAME} -V                           # Re-confirm all SFTP files via checksum
  ${SCRIPT_NAME} -V -n                        # Re-confirm without deleting from FTP
EOF
    exit 0
}

parse_args() {
    while getopts ":c:e:t:f:s:dnvVh" opt; do
        case "${opt}" in
            c) CLI_CONFIG="${OPTARG}" ;;
            e) CLI_EXCLUDE_LIST="${OPTARG}" ;;
            t) CLI_TEMP_DIR="${OPTARG}" ;;
            f) CLI_FTP_WORKERS="${OPTARG}" ;;
            s) CLI_SFTP_WORKERS="${OPTARG}" ;;
            d) CLI_DRY_RUN="true" ;;
            n) CLI_DELETE_FROM_FTP="false" ;;
            v) CLI_VERBOSE=true ;;
            V) CLI_VERIFY_MODE=true ;;
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
    [[ -n "${CLI_EXCLUDE_LIST}" ]]    && EXCLUDE_LIST="${CLI_EXCLUDE_LIST}"
    [[ -n "${CLI_TEMP_DIR}" ]]        && TEMP_DIR="${CLI_TEMP_DIR}"
    [[ -n "${CLI_DRY_RUN}" ]]         && DRY_RUN="${CLI_DRY_RUN}"
    [[ -n "${CLI_DELETE_FROM_FTP}" ]] && DELETE_FROM_FTP="${CLI_DELETE_FROM_FTP}"
    [[ -n "${CLI_FTP_WORKERS}" ]]     && FTP_MAX_WORKERS="${CLI_FTP_WORKERS}"
    [[ -n "${CLI_SFTP_WORKERS}" ]]    && SFTP_MAX_WORKERS="${CLI_SFTP_WORKERS}"
    # -V flag always wins — once set on the CLI it cannot be overridden by config
    [[ "${CLI_VERIFY_MODE}" == true ]] && VERIFY_MODE="true"

    # Apply defaults for optional variables not set in the config file.
    # Credentials and host/path values have no safe defaults and are
    # validated strictly in validate_config — everything else falls back silently.
    : "${RETENTION_DAYS:=7}"
    : "${FTP_MAX_WORKERS:=2}"
    : "${SFTP_MAX_WORKERS:=10}"
    : "${LOG_DIR:=./logs}"
    : "${LOG_RETENTION_DAYS:=30}"
    : "${DISK_SPACE_BUFFER_PCT:=10}"
    : "${DISK_WAIT_TIMEOUT:=300}"
    : "${DISK_WAIT_INTERVAL:=10}"
    : "${DRY_RUN:=false}"
    : "${DELETE_FROM_FTP:=true}"
    : "${OVERWRITE_ON_SIZE_DIFF:=true}"
    : "${EXCLUDE_LIST:=}"
    : "${TEMP_DIR:=}"
    # VERIFY_CHECKSUM: re-download the uploaded file from SFTP and compare sha256
    # against the local staged copy before deleting staging.  Defaults to true
    # because this is an intranet/uncapped connection — bandwidth is not a concern.
    : "${VERIFY_CHECKSUM:=true}"
    # VERIFY_MODE: set to true (or use -V) to re-download every FTP file even if
    # it already exists on SFTP, re-verify checksums, then run retention deletions.
    # Intended as a one-time bulk re-confirmation run after a prior upload session.
    : "${VERIFY_MODE:=false}"

    validate_config
}

validate_config() {
    local errors=0

    # Only credentials and server addresses have no safe default —
    # everything else was already defaulted in load_config.
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

    # Validate that numeric vars (whether from config or defaults) are actually numbers.
    # These checks catch the case where a user sets a variable to a non-numeric value.
    if ! [[ "${FTP_PORT}"              =~ ^[0-9]+$ ]]; then
        echo "ERROR: FTP_PORT must be a number, got: '${FTP_PORT}'" >&2
        (( errors++ )) || true
    fi
    if ! [[ "${SFTP_PORT}"             =~ ^[0-9]+$ ]]; then
        echo "ERROR: SFTP_PORT must be a number, got: '${SFTP_PORT}'" >&2
        (( errors++ )) || true
    fi
    if ! [[ "${RETENTION_DAYS}"        =~ ^[0-9]+$ ]]; then
        echo "ERROR: RETENTION_DAYS must be a non-negative integer, got: '${RETENTION_DAYS}'" >&2
        (( errors++ )) || true
    fi
    if ! [[ "${FTP_MAX_WORKERS}"       =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: FTP_MAX_WORKERS must be a positive integer, got: '${FTP_MAX_WORKERS}'" >&2
        (( errors++ )) || true
    fi
    if ! [[ "${SFTP_MAX_WORKERS}"      =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: SFTP_MAX_WORKERS must be a positive integer, got: '${SFTP_MAX_WORKERS}'" >&2
        (( errors++ )) || true
    fi
    if ! [[ "${LOG_RETENTION_DAYS}"    =~ ^[0-9]+$ ]]; then
        echo "ERROR: LOG_RETENTION_DAYS must be a non-negative integer, got: '${LOG_RETENTION_DAYS}'" >&2
        (( errors++ )) || true
    fi
    if ! [[ "${DISK_SPACE_BUFFER_PCT}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: DISK_SPACE_BUFFER_PCT must be an integer 0-99, got: '${DISK_SPACE_BUFFER_PCT}'" >&2
        (( errors++ )) || true
    fi
    if ! [[ "${DISK_WAIT_TIMEOUT}"     =~ ^[0-9]+$ ]]; then
        echo "ERROR: DISK_WAIT_TIMEOUT must be a non-negative integer, got: '${DISK_WAIT_TIMEOUT}'" >&2
        (( errors++ )) || true
    fi
    if ! [[ "${DISK_WAIT_INTERVAL}"    =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: DISK_WAIT_INTERVAL must be a positive integer, got: '${DISK_WAIT_INTERVAL}'" >&2
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
# Uses flock on the log file so that concurrent workers never interleave
# partial lines into the same log entry.  Each call is one atomic append.
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[${timestamp}] [${level}]  ${message}"

    # Determine stdout output before acquiring the lock (date call is already done)
    local print_stdout=false
    if [[ "${level}" == "ERROR" ]]; then
        print_stdout=true
    elif [[ "${level}" == "WARN" ]]; then
        print_stdout=true
    elif [[ "${level}" == "INFO" ]]; then
        print_stdout=true
    elif [[ "${level}" == "DEBUG" ]] && [[ "${CLI_VERBOSE}" == true ]]; then
        print_stdout=true
    fi

    # Atomic write: flock on the general log file descriptor
    (
        flock -x 200
        echo "${line}" >> "${LOG_FILE}"
        if [[ "${level}" == "ERROR" ]]; then
            echo "${line}" >> "${ERROR_LOG_FILE}"
        fi
        if [[ "${print_stdout}" == true ]]; then
            if [[ "${level}" == "ERROR" ]]; then
                echo "${line}" >&2
            else
                echo "${line}"
            fi
        fi
    ) 200>"${LOG_FILE}.lock"
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
        mkdir -p "${TEMP_DIR}"
        chmod 700 "${TEMP_DIR}"
        log "DEBUG" "Using custom temp directory: ${TEMP_DIR}"
    else
        TEMP_DIR=$(mktemp -d -t ftp_sftp_XXXXXXXXXX)
        chmod 700 "${TEMP_DIR}"
        TEMP_DIR_CREATED=true
        log "DEBUG" "Created temp directory: ${TEMP_DIR}"
    fi

    # Staging subdirectories for workers
    mkdir -p "${TEMP_DIR}/staging"
    mkdir -p "${TEMP_DIR}/workers"

    # ---- Queue files ----
    # work_queue.txt      : SIZE EPOCH PATH — files to download from FTP (space-separated)
    # ready_queue.txt     : LOCAL_PATH\tSFTP_DEST_PATH\tFTP_PATH\tFTP_SIZE\tFTP_MTIME
    #                       files downloaded and waiting for SFTP upload
    #                       LOCAL_PATH="SKIP"   — already on SFTP, retention check only
    #                       LOCAL_PATH="DRYRUN" — dry-run mode, log only
    # confirmed_queue.txt : FTP_PATH\tFTP_SIZE\tFTP_MTIME — uploads confirmed, check retention
    touch "${TEMP_DIR}/work_queue.txt"
    touch "${TEMP_DIR}/work_queue.lock"
    touch "${TEMP_DIR}/ready_queue.txt"
    touch "${TEMP_DIR}/ready_queue.lock"
    touch "${TEMP_DIR}/confirmed_queue.txt"
    touch "${TEMP_DIR}/confirmed_queue.lock"

    # ---- Shared atomic counter files ----
    # in_flight_bytes.cnt    : bytes currently reserved for active downloads
    # active_downloaders.cnt : number of running FTP download worker processes
    # active_uploaders.cnt   : number of running SFTP upload worker processes
    echo "0" > "${TEMP_DIR}/in_flight_bytes.cnt"
    echo "0" > "${TEMP_DIR}/active_downloaders.cnt"
    echo "0" > "${TEMP_DIR}/active_uploaders.cnt"
    touch "${TEMP_DIR}/counters.lock"

    # ---- Upload worker idle reporting state ----
    # idle_uploaders.cnt   : workers currently in the empty-queue wait loop
    # ul_idle_last_print.ts : epoch of the last printed idle summary line
    # ul_idle_report.lock  : ensures only one worker evaluates/prints at a time
    echo "0" > "${TEMP_DIR}/idle_uploaders.cnt"
    echo "0" > "${TEMP_DIR}/ul_idle_last_print.ts"
    touch "${TEMP_DIR}/ul_idle_report.lock"
}

cleanup_temp() {
    if [[ "${TEMP_DIR_CREATED}" == true ]] && [[ -d "${TEMP_DIR:-}" ]]; then
        rm -rf "${TEMP_DIR}"
        log "DEBUG" "Removed temp directory: ${TEMP_DIR}"
    else
        if [[ -d "${TEMP_DIR:-}" ]]; then
            rm -rf "${TEMP_DIR:?}/staging"
            rm -rf "${TEMP_DIR:?}/workers"
            rm -rf "${TEMP_DIR:?}/mirror_dummy"
            rm -f  "${TEMP_DIR}/work_queue.txt"      "${TEMP_DIR}/work_queue.lock"
            rm -f  "${TEMP_DIR}/ready_queue.txt"     "${TEMP_DIR}/ready_queue.lock"
            rm -f  "${TEMP_DIR}/confirmed_queue.txt" "${TEMP_DIR}/confirmed_queue.lock"
            rm -f  "${TEMP_DIR}/in_flight_bytes.cnt"
            rm -f  "${TEMP_DIR}/active_downloaders.cnt"
            rm -f  "${TEMP_DIR}/active_uploaders.cnt"
            rm -f  "${TEMP_DIR}/counters.lock"
            rm -f  "${TEMP_DIR}/idle_uploaders.cnt"
            rm -f  "${TEMP_DIR}/ul_idle_last_print.ts"
            rm -f  "${TEMP_DIR}/ul_idle_report.lock"
            rm -f  "${TEMP_DIR}/ftp_listing.txt"
            # Remove any leftover .verify temp files from checksum verification
            find "${TEMP_DIR}" -maxdepth 4 -name "*.verify" -delete 2>/dev/null || true
            log "DEBUG" "Cleaned contents of custom temp directory: ${TEMP_DIR}"
        fi
    fi
}

# ============================================================
# SECTION 8 — EXCLUSION LIST
# ============================================================

EXCLUSION_PATTERNS=()

load_exclusions() {
    if [[ -z "${EXCLUDE_LIST:-}" ]] || [[ ! -f "${EXCLUDE_LIST}" ]]; then
        log "WARN" "Exclusion list not found or not set: '${EXCLUDE_LIST:-}' — proceeding without exclusions"
        return 0
    fi

    local count=0
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
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
    FTP_CONNECT_STR="set ftp:ssl-allow no; set net:timeout 30; set net:max-retries 3;"

    log "INFO" "FTP connection configured — plain FTP (TLS disabled) to ${FTP_HOST}:${FTP_PORT}"

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
        if [[ "${line}" =~ ^"Transferring file "\`([^\']*)\'  ]]; then
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
    # NOTE: IFS=' ' is set locally on each read call because the global
    #       IFS=$'\n\t' does not split on spaces.
    # ----------------------------------------------------------------
    true > "${listing_file}"

    # Collect unique parent directories from paths_file via dirname.
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

        true > "${ls_tmp}"
        run_lftp "ls ${dir_path}" > "${ls_tmp}" 2>/dev/null || true

        log "DEBUG" "ls ${dir_path} — sample: $(head -10 "${ls_tmp}" | tr '\n' '|')"

        while IFS= read -r ls_line; do
            [[ -z "${ls_line}" ]]    && continue
            [[ "${ls_line}" != -* ]] && continue

            # Parse ls columns: perms links owner group size mon day timeyr name
            # IFS=' ' locally overrides global IFS=$'\n\t' for space-based splitting
            local size mon day timeyr name filepath epoch current_year
            IFS=' ' read -r _ _ _ _ size mon day timeyr name <<< "${ls_line}"

            [[ -z "${name}" ]]   && continue
            [[ -z "${size}" ]]   && continue
            [[ -z "${timeyr}" ]] && continue

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

    # Use "ls -l <path>" and anchor the awk match to the exact basename of the
    # remote path. Without this anchor, some SFTP servers respond to "ls -l
    # /dir/file" by listing the parent directory — causing awk to pick up the
    # first file line regardless of name, which returns the wrong size when two
    # files in different subdirectories share the same basename.
    local remote_basename
    remote_basename=$(basename "${remote_path}")

    # Capture raw SFTP output into a variable so we can both log it (in verbose
    # mode) and feed it to awk — avoids a second round-trip to the server.
    local raw_ls
    raw_ls=$(SSHPASS="${SFTP_PASS}" sshpass -e sftp \
        -P "${SFTP_PORT}" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=no \
        -o ConnectTimeout=15 \
        -o LogLevel=ERROR \
        -b <(printf 'ls -l %s\n' "${remote_path}") \
        "${SFTP_USER}@${SFTP_HOST}" 2>/dev/null || true)

    result=$(printf '%s\n' "${raw_ls}" \
        | awk -v name="${remote_basename}" \
            'NF>=9 && /^[-]/ && ($NF==name || substr($NF,length($NF)-length(name),1)=="/" && substr($NF,length($NF)-length(name)+1)==name) {print $5}' \
        | head -1)

    # In verbose mode: emit one single atomic log entry containing the query,
    # every raw ls line, and the matched result.
    # IMPORTANT: this function is always called inside $(...) by callers that
    # capture its return value via stdout.  log() writes to stdout, which means
    # any log() call here would be captured into the caller's variable instead
    # of being printed.  We therefore write directly to the log files and stderr
    # (bypassing stdout entirely) using the same flock pattern as log().
    if [[ "${CLI_VERBOSE}" == true ]]; then
        local dbg_msg
        dbg_msg="sftp_get_size: path=${remote_path} basename=${remote_basename} result='${result:-NOT_FOUND}'"
        if [[ -z "${raw_ls}" ]]; then
            dbg_msg+=" | raw=<empty>"
        else
            local raw_line
            while IFS= read -r raw_line; do
                dbg_msg+=" | ${raw_line}"
            done <<< "${raw_ls}"
        fi
        local dbg_line="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG]  ${dbg_msg}"
        (
            flock -x 200
            echo "${dbg_line}" >> "${LOG_FILE}"
            echo "${dbg_line}" >&2
        ) 200>"${LOG_FILE}.lock"
    fi

    if [[ -z "${result}" ]]; then
        echo "NOT_FOUND"
    else
        echo "${result}"
    fi
}

# sftp_get_size_retry REMOTE_PATH EXPECTED_SIZE [MAX_TRIES] [SLEEP_SECS]
#
# Calls sftp_get_size up to MAX_TRIES times (default 4), sleeping SLEEP_SECS
# (default 3) between attempts, until the returned size equals EXPECTED_SIZE.
#
# Returns the size once it matches, or the last value seen if it never matches.
#
# Rationale: some SFTP servers (especially object-storage backends) do not
# reflect the final file size in ls -l immediately after a put completes —
# they may return a partial/chunk size (e.g. 262144000 = 256 MiB) for a few
# seconds while the write is being committed.  Retrying avoids false-positive
# "Upload size verification failed" errors on large files.
sftp_get_size_retry() {
    local remote_path="$1"
    local expected_size="$2"
    local max_tries="${3:-4}"
    local sleep_secs="${4:-3}"

    local attempt=1
    local size
    while (( attempt <= max_tries )); do
        size=$(sftp_get_size "${remote_path}")
        if [[ "${size}" == "${expected_size}" ]]; then
            echo "${size}"
            return 0
        fi
        if (( attempt < max_tries )); then
            # Write directly to log file + stderr — same reason as sftp_get_size:
            # this function is called inside $(...) so log() stdout would be captured.
            local retry_line="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG]  sftp_get_size_retry: attempt ${attempt}/${max_tries} got '${size}', expected '${expected_size}' — retrying in ${sleep_secs}s (${remote_path})"
            (
                flock -x 200
                echo "${retry_line}" >> "${LOG_FILE}"
                [[ "${CLI_VERBOSE}" == true ]] && echo "${retry_line}" >&2
            ) 200>"${LOG_FILE}.lock"
            sleep "${sleep_secs}"
        fi
        (( attempt++ )) || true
    done
    # Return whatever we last got (caller decides if it's an error)
    echo "${size}"
}

# Create a directory path recursively on SFTP
# Usage: sftp_mkdir_p "/ihub-db-backups/db/2024"
sftp_mkdir_p() {
    local full_path="$1"
    local batch_cmds=""
    local current=""

    IFS='/' read -ra parts <<< "${full_path}"
    for part in "${parts[@]}"; do
        [[ -z "${part}" ]] && continue
        current="${current}/${part}"
        batch_cmds+="-mkdir ${current}"$'\n'
    done

    SSHPASS="${SFTP_PASS}" sshpass -e sftp \
        -P "${SFTP_PORT}" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=no \
        -o ConnectTimeout=15 \
        -o LogLevel=ERROR \
        -b <(printf '%s' "${batch_cmds}") \
        "${SFTP_USER}@${SFTP_HOST}" &>/dev/null || true
}

# sftp_download_verify LOCAL_STAGED_FILE SFTP_REMOTE_PATH WORKER_TAG
#
# Re-downloads SFTP_REMOTE_PATH to a temporary .verify file next to
# LOCAL_STAGED_FILE, computes sha256sum of both, and compares them.
#
# Returns:
#   0  — checksums match (SFTP copy is byte-identical to local staged file)
#   1  — checksum mismatch or download/hash failure
#
# The .verify temp file is always removed before returning, even on error.
#
# Design notes:
#   - Uses process-substitution batch mode (same pattern as sftp_get_size)
#     so no temp batch-command file is needed.
#   - The "get REMOTE LOCAL" sftp batch command writes the downloaded file
#     to the local path; sftp exits non-zero on transfer failure.
#   - sha256sum output format: "<hash>  <filename>" — only the hash field
#     is compared so the filename mismatch between .verify and staged is fine.
sftp_download_verify() {
    local local_staged="$1"
    local remote_path="$2"
    local worker_tag="${3:-UL?}"

    local verify_file="${local_staged}.verify"

    # Always clean up the temp verify file, even on early return
    # shellcheck disable=SC2064
    trap "rm -f '${verify_file}'" RETURN

    # Re-download the remote file to a local .verify temp file
    if ! SSHPASS="${SFTP_PASS}" sshpass -e sftp \
            -P "${SFTP_PORT}" \
            -o StrictHostKeyChecking=no \
            -o BatchMode=no \
            -o ConnectTimeout=30 \
            -o LogLevel=ERROR \
            -b <(printf 'get %s %s\n' "${remote_path}" "${verify_file}") \
            "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
        log "ERROR" "[${worker_tag}] Checksum verify: failed to re-download from SFTP: ${remote_path}"
        return 1
    fi

    if [[ ! -f "${verify_file}" ]]; then
        log "ERROR" "[${worker_tag}] Checksum verify: re-download produced no local file: ${verify_file}"
        return 1
    fi

    # Compute sha256 for both files; sha256sum output: "<hash>  <path>"
    local hash_staged hash_sftp
    hash_staged=$(sha256sum "${local_staged}" 2>/dev/null | awk '{print $1}')
    hash_sftp=$(sha256sum   "${verify_file}"  2>/dev/null | awk '{print $1}')

    if [[ -z "${hash_staged}" ]] || [[ -z "${hash_sftp}" ]]; then
        log "ERROR" "[${worker_tag}] Checksum verify: sha256sum failed (staged='${hash_staged}' sftp='${hash_sftp}'): ${remote_path}"
        return 1
    fi

    if [[ "${hash_staged}" != "${hash_sftp}" ]]; then
        log "ERROR" "[${worker_tag}] Checksum MISMATCH (staged=${hash_staged}, sftp=${hash_sftp}): ${remote_path}"
        return 1
    fi

    log "DEBUG" "[${worker_tag}] Checksum OK (sha256=${hash_staged}): ${remote_path}"
    return 0
}

# ============================================================
# SECTION 12 — ATOMIC COUNTER HELPERS
# ============================================================
# All counter operations use flock on counters.lock so concurrent
# workers never race on shared .cnt files.

# _counter_add FILE DELTA
# Atomically adds DELTA (positive or negative integer) to a counter file.
_counter_add() {
    local file="$1"
    local delta="$2"
    local lock="${TEMP_DIR}/counters.lock"
    (
        flock -x 200
        local current
        current=$(cat "${file}" 2>/dev/null || echo 0)
        local new_val=$(( current + delta ))
        (( new_val < 0 )) && new_val=0   # clamp — counters must never go negative
        echo "${new_val}" > "${file}"
    ) 200>"${lock}"
}

# _counter_get FILE — prints current value (read does not need a lock)
_counter_get() {
    cat "${1}" 2>/dev/null || echo 0
}

# ============================================================
# SECTION 13 — DISK SPACE GUARD
# ============================================================
#
# wait_for_disk_space WORKER_ID FILE_SIZE_BYTES
#
# Blocks until TEMP_DIR has enough free space to safely stage one more
# download.  The usable headroom formula is:
#
#   usable = df_avail - in_flight_bytes - (total * DISK_SPACE_BUFFER_PCT / 100)
#
# Idle-exit: if no downloaders AND no uploaders are active, nothing can
# free space — exit immediately regardless of DISK_WAIT_TIMEOUT.
#
# Returns 0 if space is available, 1 if it timed out or went idle.

wait_for_disk_space() {
    local worker_id="$1"
    local file_size="$2"

    local total_bytes
    total_bytes=$(df --output=size -B1 "${TEMP_DIR}" 2>/dev/null | tail -1 | tr -d ' ')
    local buffer_bytes=$(( total_bytes * DISK_SPACE_BUFFER_PCT / 100 ))

    local waited=0
    while true; do
        local avail_bytes in_flight usable
        avail_bytes=$(df --output=avail -B1 "${TEMP_DIR}" 2>/dev/null | tail -1 | tr -d ' ')
        in_flight=$(_counter_get "${TEMP_DIR}/in_flight_bytes.cnt")
        usable=$(( avail_bytes - in_flight - buffer_bytes ))

        if (( usable >= file_size )); then
            return 0
        fi

        # Nothing in flight that could free space — exit immediately
        local active_dl active_ul
        active_dl=$(_counter_get "${TEMP_DIR}/active_downloaders.cnt")
        active_ul=$(_counter_get "${TEMP_DIR}/active_uploaders.cnt")

        if (( active_dl == 0 && active_ul == 0 )); then
            log "WARN" "[DL${worker_id}] Disk space insufficient and no active workers — skipping (need ${file_size}B, usable ${usable}B)"
            return 1
        fi

        if (( waited >= DISK_WAIT_TIMEOUT )); then
            log "WARN" "[DL${worker_id}] Disk space wait timed out after ${waited}s — skipping (need ${file_size}B, usable ${usable}B)"
            return 1
        fi

        log "DEBUG" "[DL${worker_id}] Waiting for disk: need ${file_size}B, usable ${usable}B (avail=${avail_bytes}, in_flight=${in_flight}, buffer=${buffer_bytes}). Active: dl=${active_dl} ul=${active_ul}. Waited ${waited}s/${DISK_WAIT_TIMEOUT}s"
        sleep "${DISK_WAIT_INTERVAL}"
        (( waited += DISK_WAIT_INTERVAL )) || true
    done
}

# ============================================================
# SECTION 14 — FTP DELETION
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
        log "INFO" "[DEL${worker_id}] Deleted from FTP (age ≥ ${RETENTION_DAYS}d, confirmed on SFTP): ${ftp_path}"
        return 0
    else
        log "ERROR" "[DEL${worker_id}] Failed to delete from FTP: ${ftp_path}"
        return 1
    fi
}

# ============================================================
# SECTION 15 — QUEUE HELPER FUNCTIONS
# ============================================================

# _enqueue_ready LOCAL_PATH SFTP_DEST FTP_PATH FTP_SIZE FTP_MTIME
# Appends a tab-separated entry to ready_queue atomically.
_enqueue_ready() {
    local local_path="$1" sftp_dest="$2" ftp_path="$3" ftp_size="$4" ftp_mtime="$5"
    (
        flock -x 200
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${local_path}" "${sftp_dest}" "${ftp_path}" "${ftp_size}" "${ftp_mtime}" \
            >> "${TEMP_DIR}/ready_queue.txt"
    ) 200>"${TEMP_DIR}/ready_queue.lock"
}

# _enqueue_confirmed FTP_PATH FTP_SIZE FTP_MTIME
# Appends a tab-separated entry to confirmed_queue atomically.
_enqueue_confirmed() {
    local ftp_path="$1" ftp_size="$2" ftp_mtime="$3"
    (
        flock -x 200
        printf '%s\t%s\t%s\n' "${ftp_path}" "${ftp_size}" "${ftp_mtime}" \
            >> "${TEMP_DIR}/confirmed_queue.txt"
    ) 200>"${TEMP_DIR}/confirmed_queue.lock"
}

# _inc_result RESULT_FILE COUNTER_NAME
# Atomically increments a named counter in a worker result file.
_inc_result() {
    local result_file="$1" counter="$2"
    (
        flock -x 200
        local current new_val
        current=$(grep "^${counter}=" "${result_file}" 2>/dev/null | cut -d= -f2 || echo 0)
        new_val=$(( current + 1 ))
        if grep -q "^${counter}=" "${result_file}" 2>/dev/null; then
            sed -i "s/^${counter}=.*/${counter}=${new_val}/" "${result_file}"
        else
            echo "${counter}=${new_val}" >> "${result_file}"
        fi
    ) 200>"${result_file}.lock"
}

# _ul_report_idle IDLE_COUNT TOTAL_WORKERS
# Prints an aggregated "Upload Workers: X/Y idle" summary line at most once
# per DISK_WAIT_INTERVAL seconds across all upload workers combined.
# Time-only gate — no change-trigger — prevents flickering when the idle count
# oscillates by 1 as workers briefly deregister to retry the queue each second.
# Uses flock so only one worker evaluates and prints at a time.
_ul_report_idle() {
    local idle_count="$1"
    local total_workers="$2"
    (
        flock -x 200
        local last_print now elapsed
        last_print=$(cat "${TEMP_DIR}/ul_idle_last_print.ts" 2>/dev/null || echo 0)
        now=$(date +%s)
        elapsed=$(( now - last_print ))

        if (( elapsed >= DISK_WAIT_INTERVAL )); then
            log "DEBUG" "Upload Workers: ${idle_count}/${total_workers} thread(s) idle, waiting for downloads"
            echo "${now}" > "${TEMP_DIR}/ul_idle_last_print.ts"
        fi
    ) 200>"${TEMP_DIR}/ul_idle_report.lock"
}

# ============================================================
# SECTION 16 — STAGE 1: FTP DOWNLOAD WORKERS
# ============================================================
#
# Each download worker:
#   1. Pops a work_queue entry  (SIZE EPOCH FILEPATH — space-separated)
#   2. Applies dot-file and exclusion filters
#   3. Checks SFTP for existing file — if already synced correctly,
#      enqueues a SKIP entry for retention check and moves on
#   4. Calls wait_for_disk_space before reserving in-flight bytes
#   5. Downloads to per-worker staging directory, verifies local size
#   6. Appends a real entry to ready_queue for SFTP upload workers

download_worker() {
    local worker_id="$1"
    local result_file="${TEMP_DIR}/workers/dl_worker_${worker_id}.result"
    local queue_file="${TEMP_DIR}/work_queue.txt"
    local lock_file="${TEMP_DIR}/work_queue.lock"

    cat > "${result_file}" <<EOF
SCANNED=0
TRANSFERRED=0
OVERWRITTEN=0
SKIPPED=0
DELETED=0
ERRORS=0
EOF

    _counter_add "${TEMP_DIR}/active_downloaders.cnt" 1
    log "DEBUG" "Download worker ${worker_id} started (PID $$)"

    local staging_dir="${TEMP_DIR}/staging/dl_worker_${worker_id}"
    mkdir -p "${staging_dir}"

    while true; do
        # Atomically pop the next line from the work queue
        local line=""
        (
            flock -x 200
            local _line
            _line=$(head -1 "${queue_file}" 2>/dev/null || true)
            if [[ -n "${_line}" ]]; then
                sed -i '1d' "${queue_file}"
            fi
            echo "${_line}"
        ) 200>"${lock_file}" > "${TEMP_DIR}/workers/dl_worker_${worker_id}.next_line"

        line=$(cat "${TEMP_DIR}/workers/dl_worker_${worker_id}.next_line")

        if [[ -z "${line}" ]]; then
            log "DEBUG" "Download worker ${worker_id} — queue empty, exiting"
            break
        fi

        # Parse line: SIZE MTIME_EPOCH FILEPATH  (space-separated, path may contain spaces)
        local ftp_size ftp_mtime ftp_path
        ftp_size=$(echo  "${line}" | awk '{print $1}')
        ftp_mtime=$(echo "${line}" | awk '{print $2}')
        ftp_path=$(echo  "${line}" | awk '{for(i=3;i<=NF;i++) printf "%s%s",$i,(i==NF?"\n":" ")}')

        if [[ -z "${ftp_size}" ]] || [[ -z "${ftp_mtime}" ]] || [[ -z "${ftp_path}" ]]; then
            log "WARN" "Download worker ${worker_id} — malformed queue entry, skipping: '${line}'"
            continue
        fi

        _inc_result "${result_file}" "SCANNED"

        local basename_file
        basename_file=$(basename "${ftp_path}")

        # ---- 1. Skip dot files ----
        if [[ "${basename_file}" == .* ]]; then
            log "DEBUG" "[DL${worker_id}] Skipping dot file: ${ftp_path}"
            _inc_result "${result_file}" "SKIPPED"
            continue
        fi

        # ---- 2. Skip excluded files ----
        if is_excluded "${basename_file}"; then
            log "DEBUG" "[DL${worker_id}] Skipping excluded file: ${ftp_path}"
            _inc_result "${result_file}" "SKIPPED"
            continue
        fi

        # ---- 3. Build SFTP destination path ----
        local sftp_dest_path="${SFTP_REMOTE_DIR}${ftp_path}"

        # ---- 4. Check current SFTP state ----
        # In VERIFY_MODE every file must be re-downloaded from FTP so the upload
        # worker can re-confirm the SFTP copy via checksum — skip this block.
        local transfer_needed=false transfer_reason="" is_overwrite=false

        if [[ "${VERIFY_MODE}" == "true" ]]; then
            # Force transfer regardless of what is already on SFTP
            transfer_needed=true
            local sftp_size_vm
            sftp_size_vm=$(sftp_get_size "${sftp_dest_path}")
            if [[ "${sftp_size_vm}" == "NOT_FOUND" ]]; then
                transfer_reason="verify-mode: new file (not on SFTP)"
            else
                is_overwrite=true
                transfer_reason="verify-mode: re-downloading for checksum verification (SFTP size=${sftp_size_vm})"
            fi
        else
            local sftp_size
            sftp_size=$(sftp_get_size "${sftp_dest_path}")

            if [[ "${sftp_size}" == "NOT_FOUND" ]]; then
                transfer_needed=true
                transfer_reason="new file (not on SFTP)"
            elif [[ "${sftp_size}" != "${ftp_size}" ]]; then
                if [[ "${OVERWRITE_ON_SIZE_DIFF}" == "true" ]]; then
                    transfer_needed=true
                    is_overwrite=true
                    transfer_reason="size mismatch (FTP=${ftp_size}, SFTP=${sftp_size})"
                else
                    log "WARN" "[DL${worker_id}] Size mismatch, overwrite disabled — skipping: ${ftp_path}"
                    _inc_result "${result_file}" "SKIPPED"
                    # Still needs retention check — enqueue as SKIP
                    _enqueue_ready "SKIP" "SKIP" "${ftp_path}" "${ftp_size}" "${ftp_mtime}"
                    continue
                fi
            else
                log "DEBUG" "[DL${worker_id}] Already synced — queuing for retention check only: ${ftp_path}"
                _inc_result "${result_file}" "SKIPPED"
                _enqueue_ready "SKIP" "SKIP" "${ftp_path}" "${ftp_size}" "${ftp_mtime}"
                continue
            fi
        fi

        # ---- 5. Dry-run: log intent and enqueue as DRYRUN (no actual download) ----
        if [[ "${DRY_RUN}" == "true" ]]; then
            log "INFO" "[DRY-RUN] Would download: ${ftp_path} → staging (${ftp_size} bytes)"
            _enqueue_ready "DRYRUN" "${sftp_dest_path}" "${ftp_path}" "${ftp_size}" "${ftp_mtime}"
            if [[ "${is_overwrite}" == true ]]; then
                _inc_result "${result_file}" "OVERWRITTEN"
            else
                _inc_result "${result_file}" "TRANSFERRED"
            fi
            continue
        fi

        # ---- 6. Wait for sufficient disk space ----
        if ! wait_for_disk_space "${worker_id}" "${ftp_size}"; then
            log "WARN" "[DL${worker_id}] Skipping — insufficient disk space: ${ftp_path}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        # ---- 7. Reserve in-flight bytes (committed to download) ----
        _counter_add "${TEMP_DIR}/in_flight_bytes.cnt" "${ftp_size}"

        # ---- 8. Download from FTP to local staging ----
        # Preserve the FTP directory structure under the worker staging dir so that
        # identically-named files in different FTP subdirectories (e.g. /file.bz2 and
        # /slim/file.bz2) never collide at the same local path.
        local ftp_dir local_subdir local_file
        ftp_dir=$(dirname "${ftp_path}")
        # Avoid double-slash for root files: dirname("/file") = "/" so subdir = staging_dir
        if [[ "${ftp_dir}" == "/" ]]; then
            local_subdir="${staging_dir}"
        else
            local_subdir="${staging_dir}${ftp_dir}"
        fi
        mkdir -p "${local_subdir}"
        local_file="${local_subdir}/${basename_file}"
        log "INFO" "[DL${worker_id}] Downloading (${transfer_reason}): ${ftp_path} → ${local_file}"

        if ! run_lftp "get ${ftp_path} -o ${local_file}" &>/dev/null; then
            log "ERROR" "[DL${worker_id}] FTP download failed: ${ftp_path}"
            _counter_add "${TEMP_DIR}/in_flight_bytes.cnt" "$(( -ftp_size ))"
            rm -f "${local_file}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        # ---- 9. Release in-flight reservation (file is now on local disk) ----
        _counter_add "${TEMP_DIR}/in_flight_bytes.cnt" "$(( -ftp_size ))"

        # ---- 10. Verify downloaded file size ----
        if [[ ! -f "${local_file}" ]]; then
            log "ERROR" "[DL${worker_id}] Downloaded file missing at staging: ${local_file}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        local local_size
        local_size=$(stat -c '%s' "${local_file}")
        if [[ "${local_size}" != "${ftp_size}" ]]; then
            log "ERROR" "[DL${worker_id}] Size mismatch (expected=${ftp_size}, got=${local_size}): ${ftp_path}"
            rm -f "${local_file}"
            _inc_result "${result_file}" "ERRORS"
            continue
        fi

        log "DEBUG" "[DL${worker_id}] Download verified (${ftp_size} bytes): ${ftp_path}"

        # ---- 11. Count and enqueue for SFTP upload ----
        if [[ "${is_overwrite}" == true ]]; then
            _inc_result "${result_file}" "OVERWRITTEN"
        else
            _inc_result "${result_file}" "TRANSFERRED"
        fi
        _enqueue_ready "${local_file}" "${sftp_dest_path}" "${ftp_path}" "${ftp_size}" "${ftp_mtime}"

    done

    _counter_add "${TEMP_DIR}/active_downloaders.cnt" -1
    log "DEBUG" "Download worker ${worker_id} finished"
}

# ============================================================
# SECTION 17 — STAGE 2: SFTP UPLOAD WORKERS
# ============================================================
#
# Each upload worker:
#   1. Polls ready_queue for entries
#   2. Exits when queue is empty AND all download workers are done
#   3. SKIP entries  : retention check only (file already confirmed on SFTP)
#   4. DRYRUN entries: logs would-upload, marks confirmed for dry-run retention log
#   5. Real entries  : ensures SFTP dir exists, uploads file, verifies size on SFTP
#   6. On confirmed upload: appends to confirmed_queue for Stage 3 retention check
#   7. Deletes local staging file after confirmed upload

upload_worker() {
    local worker_id="$1"
    local result_file="${TEMP_DIR}/workers/ul_worker_${worker_id}.result"
    local queue_file="${TEMP_DIR}/ready_queue.txt"
    local lock_file="${TEMP_DIR}/ready_queue.lock"

    # Upload workers only track deletion errors from the retention phase;
    # transfer counts are already recorded by download workers.
    cat > "${result_file}" <<EOF
SCANNED=0
TRANSFERRED=0
OVERWRITTEN=0
SKIPPED=0
DELETED=0
ERRORS=0
EOF

    _counter_add "${TEMP_DIR}/active_uploaders.cnt" 1
    log "DEBUG" "Upload worker ${worker_id} started (PID $$)"

    while true; do
        # Atomically pop the next entry from the ready queue
        local line=""
        (
            flock -x 200
            local _line
            _line=$(head -1 "${queue_file}" 2>/dev/null || true)
            if [[ -n "${_line}" ]]; then
                sed -i '1d' "${queue_file}"
            fi
            echo "${_line}"
        ) 200>"${lock_file}" > "${TEMP_DIR}/workers/ul_worker_${worker_id}.next_line"

        line=$(cat "${TEMP_DIR}/workers/ul_worker_${worker_id}.next_line")

        if [[ -z "${line}" ]]; then
            # Queue is empty — only exit if all downloaders are also done
            local active_dl
            active_dl=$(_counter_get "${TEMP_DIR}/active_downloaders.cnt")
            if (( active_dl == 0 )); then
                log "DEBUG" "Upload worker ${worker_id} — queue empty and all downloaders finished, exiting"
                break
            fi
            # Register as idle, print aggregated summary (rate-limited), then wait.
            # idle_uploaders.cnt tracks workers genuinely waiting — distinct from
            # active_uploaders.cnt which counts all workers alive regardless of state.
            _counter_add "${TEMP_DIR}/idle_uploaders.cnt" 1
            local idle_count
            idle_count=$(_counter_get "${TEMP_DIR}/idle_uploaders.cnt")
            _ul_report_idle "${idle_count}" "${SFTP_MAX_WORKERS}"
            sleep 1
            # Deregister idle before looping back to try the queue again
            _counter_add "${TEMP_DIR}/idle_uploaders.cnt" -1
            continue
        fi

        # Parse tab-separated ready_queue entry:
        # LOCAL_PATH \t SFTP_DEST_PATH \t FTP_PATH \t FTP_SIZE \t FTP_MTIME
        local local_path sftp_dest_path ftp_path ftp_size ftp_mtime
        IFS=$'\t' read -r local_path sftp_dest_path ftp_path ftp_size ftp_mtime <<< "${line}"

        if [[ -z "${ftp_path}" ]] || [[ -z "${ftp_size}" ]] || [[ -z "${ftp_mtime}" ]]; then
            log "WARN" "Upload worker ${worker_id} — malformed ready_queue entry, skipping: '${line}'"
            continue
        fi

        local upload_confirmed=false

        # ---- SKIP: already confirmed on SFTP — retention check only ----
        if [[ "${local_path}" == "SKIP" ]]; then
            # In VERIFY_MODE download_worker forces re-download of every file,
            # so SKIP entries should not appear.  If one does (edge case), log it
            # so the operator knows this file was not re-verified via checksum.
            if [[ "${VERIFY_MODE}" == "true" ]]; then
                log "WARN" "[UL${worker_id}] VERIFY_MODE: unexpected SKIP entry — file not re-verified: ${ftp_path}"
            else
                log "DEBUG" "[UL${worker_id}] Already on SFTP — retention check only: ${ftp_path}"
            fi
            upload_confirmed=true

        # ---- DRYRUN: log intent only ----
        elif [[ "${local_path}" == "DRYRUN" ]]; then
            log "INFO" "[DRY-RUN] Would upload: ${ftp_path} → ${sftp_dest_path} (${ftp_size} bytes)"
            upload_confirmed=true

        # ---- Real upload ----
        else
            local sftp_dest_dir
            sftp_dest_dir=$(dirname "${sftp_dest_path}")

            if [[ "${VERIFY_MODE}" == "true" ]]; then
                # ---- VERIFY_MODE: skip re-uploading, verify the existing SFTP copy ----
                # download_worker already re-downloaded the file from FTP to staging so
                # we have a fresh local copy to checksum against.  We must NOT re-upload
                # because the file is expected to already be correct on SFTP — the whole
                # point of verify mode is to confirm the existing copy without overwriting.
                log "INFO" "[UL${worker_id}] [VERIFY] Skipping upload — verifying existing SFTP copy: ${sftp_dest_path}"

                # Size check first — if NOT_FOUND the file is genuinely missing on SFTP
                local verify_size
                verify_size=$(sftp_get_size "${sftp_dest_path}")
                if [[ "${verify_size}" == "NOT_FOUND" ]]; then
                    log "ERROR" "[UL${worker_id}] [VERIFY] File not found on SFTP — was never uploaded: ${sftp_dest_path}"
                    rm -f "${local_path}"
                    _inc_result "${result_file}" "ERRORS"
                    continue
                fi
                if [[ "${verify_size}" != "${ftp_size}" ]]; then
                    log "ERROR" "[UL${worker_id}] [VERIFY] Size mismatch on SFTP (expected=${ftp_size}, sftp_reported=${verify_size}): ${sftp_dest_path}"
                    rm -f "${local_path}"
                    _inc_result "${result_file}" "ERRORS"
                    continue
                fi

                # Checksum: re-download SFTP copy and compare against FTP-fresh staged file
                if ! sftp_download_verify "${local_path}" "${sftp_dest_path}" "UL${worker_id}"; then
                    log "ERROR" "[UL${worker_id}] [VERIFY] Checksum FAILED — SFTP copy does not match FTP source: ${sftp_dest_path}"
                    rm -f "${local_path}"
                    _inc_result "${result_file}" "ERRORS"
                    continue
                fi

                log "INFO" "[UL${worker_id}] [VERIFY] Verified OK [${ftp_size} bytes, checksum OK]: ${ftp_path} → ${sftp_dest_path}"
                rm -f "${local_path}"
                upload_confirmed=true

            else
                # ---- Normal mode: upload → size verify → checksum verify ----
                log "DEBUG" "[UL${worker_id}] Ensuring SFTP directory: ${sftp_dest_dir}"
                sftp_mkdir_p "${sftp_dest_dir}"

                log "DEBUG" "[UL${worker_id}] Uploading: ${local_path} → ${sftp_dest_path}"
                if ! SSHPASS="${SFTP_PASS}" sshpass -e sftp \
                        -P "${SFTP_PORT}" \
                        -o StrictHostKeyChecking=no \
                        -o BatchMode=no \
                        -o ConnectTimeout=30 \
                        -o LogLevel=ERROR \
                        -b <(printf 'put %s %s\n' "${local_path}" "${sftp_dest_path}") \
                        "${SFTP_USER}@${SFTP_HOST}" &>/dev/null; then
                    log "ERROR" "[UL${worker_id}] SFTP upload failed: ${sftp_dest_path}"
                    rm -f "${local_path}"
                    _inc_result "${result_file}" "ERRORS"
                    continue
                fi

                # Verify upload by re-checking size on SFTP.
                # Uses sftp_get_size_retry (up to 4 attempts, 3s apart) because some
                # object-storage SFTP backends report a partial/chunk size immediately
                # after put completes and need a moment to commit the final file size.
                local post_size
                post_size=$(sftp_get_size_retry "${sftp_dest_path}" "${ftp_size}")
                if [[ "${post_size}" != "${ftp_size}" ]]; then
                    log "ERROR" "[UL${worker_id}] Upload size verification failed (expected=${ftp_size}, sftp_reported=${post_size}): ${sftp_dest_path}"
                    rm -f "${local_path}"
                    _inc_result "${result_file}" "ERRORS"
                    continue
                fi

                # Checksum verification — re-download the SFTP copy and compare sha256
                # against the local staged file.  Always enabled on this intranet/uncapped
                # connection; controlled by VERIFY_CHECKSUM in the config.
                if [[ "${VERIFY_CHECKSUM}" == "true" ]]; then
                    if ! sftp_download_verify "${local_path}" "${sftp_dest_path}" "UL${worker_id}"; then
                        log "ERROR" "[UL${worker_id}] Checksum verification failed — upload may be corrupt: ${sftp_dest_path}"
                        rm -f "${local_path}"
                        _inc_result "${result_file}" "ERRORS"
                        continue
                    fi
                fi

                log "INFO" "[UL${worker_id}] Upload confirmed [${ftp_size} bytes, checksum OK]: ${ftp_path} → ${sftp_dest_path}"
                rm -f "${local_path}"
                upload_confirmed=true
            fi
        fi

        # Enqueue for Stage 3 retention check if upload was confirmed
        if [[ "${upload_confirmed}" == true ]]; then
            _enqueue_confirmed "${ftp_path}" "${ftp_size}" "${ftp_mtime}"
        fi

    done

    _counter_add "${TEMP_DIR}/active_uploaders.cnt" -1
    log "DEBUG" "Upload worker ${worker_id} finished"
}

# ============================================================
# SECTION 18 — STAGE 3: FTP DELETION
# ============================================================
#
# Runs after all upload workers have finished.
# Reads confirmed_queue, applies mtime-based retention policy.
# Uses up to FTP_MAX_WORKERS parallel deletions (respects FTP connection limit).

run_deletion_stage() {
    local confirmed_queue="${TEMP_DIR}/confirmed_queue.txt"
    local del_lock="${TEMP_DIR}/confirmed_queue.lock"
    local result_file="${TEMP_DIR}/workers/deletion_stage.result"

    cat > "${result_file}" <<EOF
SCANNED=0
TRANSFERRED=0
OVERWRITTEN=0
SKIPPED=0
DELETED=0
ERRORS=0
EOF

    local confirmed_count
    confirmed_count=$(wc -l < "${confirmed_queue}")
    log "INFO" "Deletion stage: evaluating ${confirmed_count} confirmed file(s) for FTP retention policy (≥ ${RETENTION_DAYS}d)"

    if (( confirmed_count == 0 )); then
        return 0
    fi

    local now_epoch
    now_epoch=$(date +%s)

    # Spawn up to FTP_MAX_WORKERS deletion sub-workers in parallel
    local del_pids=()
    for (( i=1; i<=FTP_MAX_WORKERS; i++ )); do
        (
            local my_id="${i}"
            while true; do
                local entry=""
                (
                    flock -x 200
                    local _entry
                    _entry=$(head -1 "${confirmed_queue}" 2>/dev/null || true)
                    if [[ -n "${_entry}" ]]; then
                        sed -i '1d' "${confirmed_queue}"
                    fi
                    echo "${_entry}"
                ) 200>"${del_lock}" > "${TEMP_DIR}/workers/del_worker_${my_id}.next"

                entry=$(cat "${TEMP_DIR}/workers/del_worker_${my_id}.next")
                [[ -z "${entry}" ]] && break

                # Parse: FTP_PATH \t FTP_SIZE \t FTP_MTIME
                local ftp_path ftp_size ftp_mtime
                IFS=$'\t' read -r ftp_path ftp_size ftp_mtime <<< "${entry}"

                local age_seconds=$(( now_epoch - ftp_mtime ))
                local age_days=$(( age_seconds / 86400 ))

                if (( age_days >= RETENTION_DAYS )) && [[ "${DELETE_FROM_FTP}" == "true" ]]; then
                    if delete_ftp_file "${ftp_path}" "${my_id}"; then
                        _inc_result "${result_file}" "DELETED"
                    else
                        _inc_result "${result_file}" "ERRORS"
                    fi
                else
                    if [[ "${DELETE_FROM_FTP}" != "true" ]]; then
                        log "DEBUG" "[DEL${my_id}] FTP deletion disabled — keeping: ${ftp_path}"
                    else
                        log "DEBUG" "[DEL${my_id}] File is ${age_days}d old (< ${RETENTION_DAYS}d) — keeping on FTP: ${ftp_path}"
                    fi
                fi
            done
        ) &
        del_pids+=($!)
    done

    for pid in "${del_pids[@]}"; do
        wait "${pid}" || true
    done

    log "DEBUG" "Deletion stage complete"
}

# ============================================================
# SECTION 19 — PIPELINE ORCHESTRATOR
# ============================================================

run_pipeline() {
    local queue_size
    queue_size=$(wc -l < "${TEMP_DIR}/work_queue.txt")

    if (( queue_size == 0 )); then
        log "INFO" "Work queue is empty — nothing to process"
        return 0
    fi

    log "INFO" "Starting pipeline: ${FTP_MAX_WORKERS} FTP download worker(s), ${SFTP_MAX_WORKERS} SFTP upload worker(s) — ${queue_size} file(s) queued"

    mkdir -p "${TEMP_DIR}/workers"

    # ---- Stage 1: Launch FTP download workers ----
    local dl_pids=()
    for (( i=1; i<=FTP_MAX_WORKERS; i++ )); do
        download_worker "${i}" &
        dl_pids+=($!)
        WORKER_PIDS+=($!)
        log "DEBUG" "Spawned download worker ${i} (PID ${!})"
    done

    # ---- Stage 2: Launch SFTP upload workers ----
    # Uploaders start immediately and poll ready_queue; they self-exit once
    # the queue is drained and all downloaders are confirmed done.
    local ul_pids=()
    for (( i=1; i<=SFTP_MAX_WORKERS; i++ )); do
        upload_worker "${i}" &
        ul_pids+=($!)
        WORKER_PIDS+=($!)
        log "DEBUG" "Spawned upload worker ${i} (PID ${!})"
    done

    # Wait for all download workers
    local any_error=false
    for pid in "${dl_pids[@]}"; do
        if ! wait "${pid}"; then
            log "ERROR" "Download worker (PID ${pid}) exited with an error"
            any_error=true
        fi
    done
    [[ "${any_error}" == true ]] && log "WARN" "One or more download workers encountered errors"

    # Wait for all upload workers
    any_error=false
    for pid in "${ul_pids[@]}"; do
        if ! wait "${pid}"; then
            log "ERROR" "Upload worker (PID ${pid}) exited with an error"
            any_error=true
        fi
    done
    [[ "${any_error}" == true ]] && log "WARN" "One or more upload workers encountered errors"

    # ---- Stage 3: FTP deletion (all uploads confirmed) ----
    run_deletion_stage

    # ---- Merge worker result files into global counters ----
    merge_worker_results
}

merge_worker_results() {
    for result_file in "${TEMP_DIR}/workers"/*.result; do
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
# SECTION 20 — RUN SUMMARY
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

╔══════════════════════════════════════════════╗
║         Transfer Run Summary${dry_run_label}
╠══════════════════════════════════════════════╣
║  Started        : ${RUN_START_TIME}
║  Finished       : ${end_time}
║  Duration       : ${duration_str}
║  DL Workers     : ${FTP_MAX_WORKERS}  (FTP → staging)
║  UL Workers     : ${SFTP_MAX_WORKERS}  (staging → SFTP)
╠══════════════════════════════════════════════╣
║  Files Scanned      : ${CNT_SCANNED}
║  Files Transferred  : ${CNT_TRANSFERRED}
║  Files Overwritten  : ${CNT_OVERWRITTEN}
║  Files Skipped      : ${CNT_SKIPPED}
║  FTP Files Deleted  : ${CNT_DELETED}
║  Errors             : ${CNT_ERRORS}
╚══════════════════════════════════════════════╝
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
# SECTION 21 — SIGNAL TRAPS & CLEANUP
# ============================================================

trap_cleanup() {
    local exit_code=$?
    log "WARN" "Script interrupted or exited unexpectedly (exit code: ${exit_code}). Cleaning up..."

    # Kill all tracked worker processes before wiping staging.
    # This prevents workers writing to paths that cleanup_temp is about to delete,
    # and ensures SIGTERM (e.g. from "kill <pid>") propagates to workers even though
    # SIGTERM does not automatically broadcast to the whole process group like SIGINT does.
    if (( ${#WORKER_PIDS[@]} > 0 )); then
        log "WARN" "Sending SIGTERM to ${#WORKER_PIDS[@]} worker process(es)..."
        kill "${WORKER_PIDS[@]}" 2>/dev/null || true
        # Give workers up to 5 seconds to exit cleanly before cleanup proceeds
        local wait_tries=0
        while (( wait_tries < 5 )); do
            local still_running=0
            local pid
            for pid in "${WORKER_PIDS[@]}"; do
                kill -0 "${pid}" 2>/dev/null && (( still_running++ )) || true
            done
            (( still_running == 0 )) && break
            sleep 1
            (( wait_tries++ )) || true
        done
        # Force-kill any workers that didn't exit in time
        kill -9 "${WORKER_PIDS[@]}" 2>/dev/null || true
    fi

    cleanup_temp
    release_lock
    exit "${exit_code}"
}

trap trap_cleanup INT TERM EXIT

# ============================================================
# SECTION 22 — MAIN ENTRYPOINT
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
    [[ "${DRY_RUN}"        == "true" ]] && log "INFO" "*** DRY-RUN MODE ENABLED — No files will be moved or deleted ***"
    [[ "${VERIFY_MODE}"    == "true" ]] && log "INFO" "*** VERIFY MODE ENABLED — All FTP files will be re-downloaded and SFTP copies checksum-verified ***"
    [[ "${VERIFY_CHECKSUM}" == "true" ]] && [[ "${VERIFY_MODE}" != "true" ]] && log "INFO" "Checksum verification enabled (VERIFY_CHECKSUM=true) — SFTP uploads will be re-downloaded and sha256-verified"

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

    # 10. Run decoupled download/upload pipeline
    run_pipeline

    # 11. Rotate old general logs
    rotate_logs

    # 12. Clean up temp directory
    cleanup_temp

    # 13. Release PID lock
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