#!/usr/bin/env bash
# ============================================================
# src/core/logging.sh — Logging Setup & Log Functions
#
# Provides three functions:
#
#   setup_logging()  — creates the log directory and initialises LOG_FILE
#                      and ERROR_LOG_FILE with timestamped filenames.
#                      Must be called after load_config() so LOG_DIR is set.
#
#   log LEVEL MSG    — the primary logging function used everywhere in the
#                      script.  Writes atomically to LOG_FILE using flock
#                      so concurrent workers never interleave partial lines.
#                      ERROR level is also mirrored to ERROR_LOG_FILE.
#                      Levels INFO/WARN/ERROR always print to stdout/stderr;
#                      DEBUG only prints when CLI_VERBOSE=true.
#
#   rotate_logs()    — deletes transfer_*.log files older than
#                      LOG_RETENTION_DAYS from LOG_DIR.  errors_*.log files
#                      are intentionally never auto-deleted so the operator
#                      always has a full history of failures.
#
# IMPORTANT — functions called inside $(...) must NOT use log():
#   log() writes to stdout, and any stdout inside a $() subshell is captured
#   into the caller's variable instead of being printed.  Functions in this
#   category (sftp_get_size, sftp_get_size_retry) write debug output by
#   appending directly to ${LOG_FILE} and echoing to stderr, bypassing
#   stdout entirely.  See src/transfer/sftp.sh for the pattern.
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

    # If LOG_FILE is not yet initialised (early bootstrap before setup_logging
    # has run), fall back to stderr/stdout only — no file write attempted.
    if [[ -z "${LOG_FILE}" ]]; then
        if [[ "${print_stdout}" == true ]]; then
            if [[ "${level}" == "ERROR" ]]; then
                echo "${line}" >&2
            else
                echo "${line}"
            fi
        fi
        return 0
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