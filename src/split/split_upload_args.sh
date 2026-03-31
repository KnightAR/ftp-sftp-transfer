#!/usr/bin/env bash
# ============================================================
# src/split/split_upload_args.sh — CLI Flag Parsing for split_upload.sh
#
# Defines all CLI override variables and the two functions that
# handle argument processing for split_upload.sh:
#
#   split_upload_usage()       — prints the help text and exits
#   split_upload_parse_args()  — processes positional arg + getopts flags
#                                and populates UPLOAD_CLI_* override variables
#
# Usage:
#   split_upload.sh <source_file> [OPTIONS]
#
# Positional:
#   source_file  Local file path to split and upload (required, first argument)
#
# Flags:
#   -r PATH   Remote SFTP subpath (relative to SFTP_REMOTE_DIR)
#   -c FILE   Config file path
#   -s SIZE   Part size (split -b syntax, e.g. 500m, 2g)
#   -p N      Parallel upload workers
#   -t DIR    Staging directory override
#   -d        Delete source file after successful upload + verification
#   -v        Verbose / DEBUG output
#   -h        Help
#
# Dependency order:
#   Must be sourced after src/core/constants.sh (uses SCRIPT_NAME,
#   SCRIPT_VERSION).
# ============================================================

# ---- CLI override variables ----
# shellcheck disable=SC2034  # all vars consumed by split_upload.sh after sourcing
UPLOAD_CLI_SOURCE_FILE=""     # positional arg 1: local source file path
UPLOAD_CLI_CONFIG=""          # -c  path to transfer.conf
UPLOAD_CLI_REMOTE_PATH=""     # -r  remote SFTP subpath override
UPLOAD_CLI_SIZE=""            # -s  part size override
UPLOAD_CLI_WORKERS=""         # -p  parallel upload worker count override
UPLOAD_CLI_HASH_WORKERS=""    # -H  parallel hash worker count override
UPLOAD_CLI_TEMP_DIR=""        # -t  staging directory override
UPLOAD_CLI_DELETE=false       # -d  delete source file after successful upload
UPLOAD_CLI_VERBOSE=false      # -v  verbose / DEBUG output

split_upload_usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — Local File Split Upload

Splits a local file into fixed-size parts, uploads all parts to SFTP
in parallel with per-part checksum verification, and writes a manifest
file alongside the parts for later restoration via split_restore.sh.

The source file is NOT deleted by default — pass -d to delete it after
a successful upload and verification.

Usage: ${SCRIPT_NAME} <source_file> [OPTIONS]

Positional:
  source_file   Path to the local file to split and upload

Optional:
  -r PATH   Remote SFTP subpath relative to SFTP_REMOTE_DIR
            (default: / — file stored at SFTP bucket root)
            Example: -r /backups/2024 stores under SFTP_REMOTE_DIR/backups/2024/
  -c FILE   Config file                     (default: ./transfer.conf)
  -s SIZE   Part size (split -b syntax)     (default: 1g)
            Examples: 500m, 2g, 1073741824
  -p N      Parallel SFTP upload workers    (default: 10)
  -H N      Parallel sha256 hash workers    (default: nproc-1)
            Hashing and uploading overlap — upload workers start immediately
            and consume parts from the queue as hashing completes.
  -t DIR    Override staging/temp dir       (this run only)
  -d        Delete source file after successful upload + verification
  -v        Verbose output (DEBUG level)    (stdout + log)
  -h        Show this help message

SFTP output layout:
  <SFTP_REMOTE_DIR><remote_path>/<filename>.manifest
  <SFTP_REMOTE_DIR><remote_path>/split/<filename>.part.00001
  <SFTP_REMOTE_DIR><remote_path>/split/<filename>.part.00002
  ...

Examples:
  ${SCRIPT_NAME} /mnt/data/blockchain.tar.xz
  ${SCRIPT_NAME} /mnt/data/blockchain.tar.xz -r /backups/2024
  ${SCRIPT_NAME} /mnt/data/blockchain.tar.xz -s 2g -p 5
  ${SCRIPT_NAME} /mnt/data/blockchain.tar.xz -s 2g -p 5 -H 7
  ${SCRIPT_NAME} /mnt/data/blockchain.tar.xz -d
  ${SCRIPT_NAME} /mnt/data/blockchain.tar.xz -r /backups -d -v
EOF
    exit 0
}

split_upload_parse_args() {
    if (( $# == 0 )); then
        split_upload_usage
    fi

    # First argument is the required positional source file path
    UPLOAD_CLI_SOURCE_FILE="$1"
    shift

    # Treat a lone -h before the positional arg gracefully
    if [[ "${UPLOAD_CLI_SOURCE_FILE}" == "-h" || "${UPLOAD_CLI_SOURCE_FILE}" == "--help" ]]; then
        split_upload_usage
    fi

    while getopts ":r:c:s:p:H:t:dvh" opt; do
        case "${opt}" in
            r) UPLOAD_CLI_REMOTE_PATH="${OPTARG}" ;;
            c) UPLOAD_CLI_CONFIG="${OPTARG}" ;;
            s) UPLOAD_CLI_SIZE="${OPTARG}" ;;
            p) UPLOAD_CLI_WORKERS="${OPTARG}" ;;
            H) UPLOAD_CLI_HASH_WORKERS="${OPTARG}" ;;
            t) UPLOAD_CLI_TEMP_DIR="${OPTARG}" ;;
            d) UPLOAD_CLI_DELETE=true ;;
            v) UPLOAD_CLI_VERBOSE=true ;;
            h) split_upload_usage ;;
            :) echo "ERROR: Option -${OPTARG} requires an argument." >&2; exit 1 ;;
            \?) echo "ERROR: Unknown option -${OPTARG}." >&2; exit 1 ;;
        esac
    done

    # Validate positional arg
    if [[ -z "${UPLOAD_CLI_SOURCE_FILE}" ]]; then
        echo "ERROR: source_file is required." >&2
        echo "       Run ${SCRIPT_NAME} -h for usage." >&2
        exit 1
    fi

    # Propagate CLI overrides into the variables that load_config / split_config read.
    # All target vars are consumed by other sourced modules — not unused.
    # shellcheck disable=SC2034
    [[ -n "${UPLOAD_CLI_CONFIG}" ]]        && DEFAULT_CONFIG="${UPLOAD_CLI_CONFIG}"
    # shellcheck disable=SC2034
    [[ -n "${UPLOAD_CLI_SIZE}" ]]          && SPLIT_SIZE="${UPLOAD_CLI_SIZE}"
    # shellcheck disable=SC2034
    [[ -n "${UPLOAD_CLI_WORKERS}" ]]       && SPLIT_PART_WORKERS="${UPLOAD_CLI_WORKERS}"
    # shellcheck disable=SC2034
    [[ "${UPLOAD_CLI_VERBOSE}" == true ]]  && CLI_VERBOSE=true || true
    # UPLOAD_CLI_REMOTE_PATH, UPLOAD_CLI_TEMP_DIR, UPLOAD_CLI_DELETE,
    # UPLOAD_CLI_HASH_WORKERS are read directly by split_upload_main() in
    # split_upload.sh — not propagated here.
}