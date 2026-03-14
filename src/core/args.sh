#!/usr/bin/env bash
# ============================================================
# src/core/args.sh — CLI Flag Parsing
#
# Defines all CLI override variables and the two functions that
# handle command-line argument processing:
#
#   usage()      — prints the help text and exits
#   parse_args() — processes getopts flags and populates CLI_*
#                  override variables
#
# CLI_* variables are intentionally kept separate from the
# config-file variables they may override.  load_config() in
# src/core/config.sh applies them after sourcing the config,
# so a flag always wins over the config file value.
# ============================================================

# ---- CLI override variables ----
# Empty string means "use whatever the config file says".
# Boolean flags (dry-run, verbose, verify) default to false.
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