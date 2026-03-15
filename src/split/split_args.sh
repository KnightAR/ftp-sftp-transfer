#!/usr/bin/env bash
# ============================================================
# src/split/split_args.sh — CLI Flag Parsing for split_transfer.sh
#
# Defines all CLI override variables and the two functions that
# handle argument processing for split_transfer.sh:
#
#   split_usage()       — prints the help text and exits
#   split_parse_args()  — processes getopts flags and populates
#                         SPLIT_CLI_* override variables
#
# Flags:
#   -f PATH   FTP source file path (required)
#   -c FILE   Config file path
#   -s SIZE   Part size (split -b syntax, e.g. 500m, 2g)
#   -p N      Parallel upload workers
#   -t DIR    Staging directory override
#   -n        Skip FTP source deletion after upload
#   -v        Verbose / DEBUG output
#   -h        Help
#
# Dependency order:
#   Must be sourced after src/core/constants.sh (uses SCRIPT_NAME,
#   SCRIPT_VERSION).
# ============================================================

# ---- CLI override variables ----
SPLIT_CLI_FTP_PATH=""       # -f  required: FTP source file path
SPLIT_CLI_CONFIG=""         # -c  path to transfer.conf
SPLIT_CLI_SIZE=""           # -s  part size override
SPLIT_CLI_WORKERS=""        # -p  parallel worker count override
SPLIT_CLI_TEMP_DIR=""       # -t  staging directory override
SPLIT_CLI_NO_DELETE=false   # -n  skip FTP source deletion
SPLIT_CLI_VERBOSE=false     # -v  verbose / DEBUG output

split_usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — FTP Split Transfer

Downloads a single large file from FTP, splits it into parts,
uploads all parts to SFTP in parallel with per-part checksum
verification, then deletes the FTP source.

Usage: ${SCRIPT_NAME} [OPTIONS]

Required:
  -f PATH   FTP source file path
            e.g. /blockchain-etl-20211222.tar.bz2

Optional:
  -c FILE   Config file                     (default: ./transfer.conf)
  -s SIZE   Part size (split -b syntax)     (default: 1g)
            Examples: 500m, 2g, 1073741824
  -p N      Parallel SFTP upload workers    (default: 10)
  -t DIR    Override staging/temp dir       (this run only)
  -n        Skip FTP source deletion        (upload only, no delete)
  -v        Verbose output (DEBUG level)    (stdout + log)
  -h        Show this help message

SFTP output layout:
  <SFTP_REMOTE_DIR><ftp_dir>/<filename>.manifest
  <SFTP_REMOTE_DIR><ftp_dir>/split/<filename>.part.00001
  <SFTP_REMOTE_DIR><ftp_dir>/split/<filename>.part.00002
  ...

Examples:
  ${SCRIPT_NAME} -f /blockchain-etl-20211222.tar.bz2
  ${SCRIPT_NAME} -f /blockchain-etl-20211222.tar.bz2 -s 2g -p 5
  ${SCRIPT_NAME} -f /www/htdocs.tar.bz2 -n
  ${SCRIPT_NAME} -f /large-backup.tar.bz2 -v
EOF
    exit 0
}

split_parse_args() {
    if (( $# == 0 )); then
        split_usage
    fi

    while getopts ":f:c:s:p:t:nvh" opt; do
        case "${opt}" in
            f) SPLIT_CLI_FTP_PATH="${OPTARG}" ;;
            c) SPLIT_CLI_CONFIG="${OPTARG}" ;;
            s) SPLIT_CLI_SIZE="${OPTARG}" ;;
            p) SPLIT_CLI_WORKERS="${OPTARG}" ;;
            t) SPLIT_CLI_TEMP_DIR="${OPTARG}" ;;
            n) SPLIT_CLI_NO_DELETE=true ;;
            v) SPLIT_CLI_VERBOSE=true ;;
            h) split_usage ;;
            :) echo "ERROR: Option -${OPTARG} requires an argument." >&2; exit 1 ;;
            \?) echo "ERROR: Unknown option -${OPTARG}." >&2; exit 1 ;;
        esac
    done

    # -f is required
    if [[ -z "${SPLIT_CLI_FTP_PATH}" ]]; then
        echo "ERROR: -f FTP_PATH is required." >&2
        echo "       Run ${SCRIPT_NAME} -h for usage." >&2
        exit 1
    fi

    # Propagate CLI overrides into the variables that load_config / split_config read
    [[ -n "${SPLIT_CLI_CONFIG}" ]]  && DEFAULT_CONFIG="${SPLIT_CLI_CONFIG}"
    [[ -n "${SPLIT_CLI_SIZE}" ]]    && SPLIT_SIZE="${SPLIT_CLI_SIZE}"
    [[ -n "${SPLIT_CLI_WORKERS}" ]] && SPLIT_PART_WORKERS="${SPLIT_CLI_WORKERS}"
    [[ -n "${SPLIT_CLI_TEMP_DIR}" ]] && TEMP_DIR="${SPLIT_CLI_TEMP_DIR}"
    [[ "${SPLIT_CLI_VERBOSE}" == true ]] && CLI_VERBOSE=true
}