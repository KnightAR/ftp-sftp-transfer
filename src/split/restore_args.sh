#!/usr/bin/env bash
# ============================================================
# src/split/restore_args.sh — CLI Flag Parsing for split_restore.sh
#
# Defines all CLI override variables and the two functions that
# handle argument processing for split_restore.sh:
#
#   restore_usage()       — prints the help text and exits
#   restore_parse_args()  — processes positional arg + getopts flags
#                           and populates RESTORE_CLI_* override variables
#
# Usage:
#   split_restore.sh <manifest_path> [OPTIONS]
#
# Positional:
#   manifest_path  SFTP path of the .manifest file (required, first argument)
#
# Flags:
#   -o PATH   Local output file path (default: <cwd>/<original_filename>)
#   -c FILE   Config file path
#   -p N      Parallel download workers
#   -t DIR    Staging directory override
#   -V        Verify parts on SFTP only (no download, no reassembly)
#   -v        Verbose / DEBUG output
#   -h        Help
#
# Dependency order:
#   Must be sourced after src/core/constants.sh (uses SCRIPT_NAME,
#   SCRIPT_VERSION).
# ============================================================

# ---- CLI override variables ----
RESTORE_CLI_MANIFEST=""     # positional arg 1: SFTP manifest path
RESTORE_CLI_OUTPUT=""       # -o  required (unless -V): local output file path
RESTORE_CLI_CONFIG=""       # -c  path to transfer.conf
RESTORE_CLI_WORKERS=""      # -p  parallel worker count override
RESTORE_CLI_TEMP_DIR=""     # -t  staging directory override
RESTORE_CLI_VERIFY=false    # -V  verify-only mode (no download)
RESTORE_CLI_VERBOSE=false   # -v  verbose / DEBUG output

restore_usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — Split File Restore

Downloads split parts from SFTP, verifies each part against its
manifest hash, reassembles them in order via streaming concat
(parts are appended and deleted as they arrive to minimise disk
usage), then verifies the final file sha256 against the manifest.

Usage: ${SCRIPT_NAME} <manifest_path> [OPTIONS]

Positional:
  manifest_path  SFTP path of the .manifest file
                 e.g. /backups/blockchain-etl-20211222.tar.bz2.manifest

Optional:
  -o PATH   Local output file path
            (default: <cwd>/<original_filename>, e.g. ./blockchain.tar.xz)
            e.g. /data/blockchain-etl-20211222.tar.bz2
  -c FILE   Config file                        (default: ./transfer.conf)
  -p N      Parallel SFTP download workers     (default: 10)
  -t DIR    Override staging/temp dir          (this run only)
  -V        Verify mode: check all parts exist on SFTP with correct
            sizes and hashes — no download, no reassembly
  -v        Verbose output (DEBUG level)       (stdout + log)
  -h        Show this help message

Disk usage note:
  Peak disk at output path  ≈ original file size
  Peak disk at staging dir  ≈ N_workers × part_size (parts deleted as committed)

Examples:
  ${SCRIPT_NAME} /backups/blockchain-etl-20211222.tar.bz2.manifest \\
                 -o /data/blockchain-etl-20211222.tar.bz2
  ${SCRIPT_NAME} /backups/blockchain-etl-20211222.tar.bz2.manifest -V
  ${SCRIPT_NAME} /backups/blockchain-etl-20211222.tar.bz2.manifest \\
                 -o /data/blockchain-etl-20211222.tar.bz2 -p 5 -v
EOF
    exit 0
}

restore_parse_args() {
    if (( $# == 0 )); then
        restore_usage
    fi

    # First argument is the required positional manifest path
    RESTORE_CLI_MANIFEST="$1"
    shift

    # Treat a lone -h before the positional arg gracefully
    if [[ "${RESTORE_CLI_MANIFEST}" == "-h" || "${RESTORE_CLI_MANIFEST}" == "--help" ]]; then
        restore_usage
    fi

    # RESTORE_CLI_OUTPUT and RESTORE_CLI_VERIFY are read by restore_main() in split_restore.sh
    # shellcheck disable=SC2034
    while getopts ":o:c:p:t:Vvh" opt; do
        case "${opt}" in
            o) RESTORE_CLI_OUTPUT="${OPTARG}" ;;
            c) RESTORE_CLI_CONFIG="${OPTARG}" ;;
            p) RESTORE_CLI_WORKERS="${OPTARG}" ;;
            t) RESTORE_CLI_TEMP_DIR="${OPTARG}" ;;
            V) RESTORE_CLI_VERIFY=true ;;
            v) RESTORE_CLI_VERBOSE=true ;;
            h) restore_usage ;;
            :) echo "ERROR: Option -${OPTARG} requires an argument." >&2; exit 1 ;;
            \?) echo "ERROR: Unknown option -${OPTARG}." >&2; exit 1 ;;
        esac
    done

    # Validate positional arg
    if [[ -z "${RESTORE_CLI_MANIFEST}" ]]; then
        echo "ERROR: manifest_path is required." >&2
        echo "       Run ${SCRIPT_NAME} -h for usage." >&2
        exit 1
    fi

    # -o defaults to <cwd>/<manifest_basename minus .manifest suffix>
    # Resolution happens in restore_main() once we know the manifest path;
    # no error here — an empty RESTORE_CLI_OUTPUT is valid.

    # Propagate CLI overrides into the variables that load_config / split_config read.
    # All target vars are consumed by other sourced modules — not unused.
    # shellcheck disable=SC2034
    [[ -n "${RESTORE_CLI_CONFIG}" ]]        && DEFAULT_CONFIG="${RESTORE_CLI_CONFIG}"
    # shellcheck disable=SC2034
    [[ -n "${RESTORE_CLI_WORKERS}" ]]       && SPLIT_RESTORE_WORKERS="${RESTORE_CLI_WORKERS}"
    # shellcheck disable=SC2034
    [[ -n "${RESTORE_CLI_TEMP_DIR}" ]]      && TEMP_DIR="${RESTORE_CLI_TEMP_DIR}"
    # shellcheck disable=SC2034
    [[ "${RESTORE_CLI_VERBOSE}" == true ]]  && CLI_VERBOSE=true
}