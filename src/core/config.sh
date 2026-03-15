#!/usr/bin/env bash
# ============================================================
# src/core/config.sh — Configuration Loading & Validation
#
# Provides two functions:
#
#   load_config()    — sources the config file, applies CLI overrides,
#                      then sets safe defaults for every optional variable
#                      that was not provided by the config file.
#
#   validate_config() — checks that all required variables are non-empty
#                       and that all numeric variables contain valid numbers.
#                       Exits with a clear error list if anything is wrong.
#
# The nested helper check_var() is defined inside validate_config() so it
# is scoped to that function and does not pollute the global namespace.
#
# Dependency order:
#   Must be sourced after src/core/constants.sh (needs SCRIPT_DIR, DEFAULT_CONFIG)
#   and src/core/args.sh (needs CLI_* override variables).
# ============================================================

load_config() {
    local config_file="${CLI_CONFIG:-${DEFAULT_CONFIG}}"
    local sftp_only="${2:-false}"   # pass "sftp-only" as $2 to skip FTP validation

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
    # REUPLOAD_LOG: persistent file listing FTP paths that must be force-reuploaded
    # on the next run due to a previous checksum failure.  Survives temp dir
    # cleanup.  Default is alongside the script; override in config if needed.
    : "${REUPLOAD_LOG:=${SCRIPT_DIR}/reupload.log}"

    validate_config "${sftp_only}"
}

validate_config() {
    local sftp_only="${1:-false}"
    local errors=0

    # Only credentials and server addresses have no safe default —
    # everything else was already defaulted in load_config.
    # check_var is nested here so it can increment the local errors counter
    # via the closure and does not leak into the global function namespace.
    check_var() {
        local var_name="$1"
        local var_value="${!var_name:-}"
        if [[ -z "${var_value}" ]]; then
            echo "ERROR: Required config variable '${var_name}' is not set." >&2
            (( errors++ )) || true
        fi
    }

    if [[ "${sftp_only}" != "sftp-only" ]]; then
        check_var "FTP_HOST"
        check_var "FTP_PORT"
        check_var "FTP_USER"
        check_var "FTP_PASS"
        check_var "FTP_REMOTE_DIR"
    fi
    check_var "SFTP_HOST"
    check_var "SFTP_PORT"
    check_var "SFTP_USER"
    check_var "SFTP_PASS"
    check_var "SFTP_REMOTE_DIR"

    # Validate that numeric vars (whether from config or defaults) are actually numbers.
    # These checks catch the case where a user sets a variable to a non-numeric value.
    if [[ "${sftp_only}" != "sftp-only" ]]; then
        if ! [[ "${FTP_PORT}" =~ ^[0-9]+$ ]]; then
            echo "ERROR: FTP_PORT must be a number, got: '${FTP_PORT}'" >&2
            (( errors++ )) || true
        fi
    fi
    if ! [[ "${SFTP_PORT}"             =~ ^[0-9]+$ ]]; then
        echo "ERROR: SFTP_PORT must be a number, got: '${SFTP_PORT}'" >&2
        (( errors++ )) || true
    fi
    if ! [[ "${RETENTION_DAYS}"        =~ ^[0-9]+$ ]]; then
        echo "ERROR: RETENTION_DAYS must be a non-negative integer, got: '${RETENTION_DAYS}'" >&2
        (( errors++ )) || true
    fi
    if [[ "${sftp_only}" != "sftp-only" ]]; then
        if ! [[ "${FTP_MAX_WORKERS}" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: FTP_MAX_WORKERS must be a positive integer, got: '${FTP_MAX_WORKERS}'" >&2
            (( errors++ )) || true
        fi
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