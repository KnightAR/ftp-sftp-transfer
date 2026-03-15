#!/usr/bin/env bash
# ============================================================
# src/split/restore_args.sh — CLI Flag Parsing for split_restore.sh
#
# Defines all CLI override variables and the two functions that
# handle argument processing for split_restore.sh:
#
#   restore_usage()       — prints the help text and exits
#   restore_parse_args()  — processes getopts flags and populates
#                           RESTORE_CLI_* override variables
#
# Flags:
#   -f PATH   SFTP manifest path (required)
#   -o PATH   Local output file path (required)
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
RESTORE_CLI_MANIFEST=""     # -f  required: SFTP manifest path
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

Usage: ${SCRIPT_NAME} [OPTIONS]

Required:
  -f PATH   SFTP manifest path
            e.g. /backups/blockchain-etl-20211222.tar.bz2.manifest
  -o PATH   Local output file path             (required unless -V)
            e.g. /data/blockchain-etl-20211222.tar.bz2

Optional:
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
  ${SCRIPT_NAME} -f /backups/blockchain-etl-20211222.tar.bz2.manifest \\
                 -o /data/blockchain-etl-20211222.tar.bz2
  ${SCRIPT_NAME} -f /backups/blockchain-etl-20211222.tar.bz2.manifest -V
  ${SCRIPT_NAME} -f /backups/blockchain-etl-20211222.tar.bz2.manifest \\
                 -o /data/blockchain-etl-20211222.tar.bz2 -p 5 -v
EOF
    exit 0
}

restore_parse_args() {
    if (( $# == 0 )); then
        restore_usage
    fi

    while getopts ":f:o:c:p:t:Vvh" opt; do
        case "${opt}" in
            f) RESTORE_CLI_MANIFEST="${OPTARG}" ;;
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

    # -f is always required
    if [[ -z "${RESTORE_CLI_MANIFEST}" ]]; then
        echo "ERROR: -f MANIFEST_PATH is required." >&2
        echo "       Run ${SCRIPT_NAME} -h for usage." >&2
        exit 1
    fi

    # -o is required unless -V (verify-only)
    if [[ -z "${RESTORE_CLI_OUTPUT}" ]] && [[ "${RESTORE_CLI_VERIFY}" != true ]]; then
        echo "ERROR: -o OUTPUT_PATH is required unless using -V (verify-only mode)." >&2
        echo "       Run ${SCRIPT_NAME} -h for usage." >&2
        exit 1
    fi

    # Propagate CLI overrides into the variables that load_config / split_config read
    [[ -n "${RESTORE_CLI_CONFIG}" ]]   && DEFAULT_CONFIG="${RESTORE_CLI_CONFIG}"
    [[ -n "${RESTORE_CLI_WORKERS}" ]]  && SPLIT_RESTORE_WORKERS="${RESTORE_CLI_WORKERS}"
    [[ -n "${RESTORE_CLI_TEMP_DIR}" ]] && TEMP_DIR="${RESTORE_CLI_TEMP_DIR}"
    [[ "${RESTORE_CLI_VERBOSE}" == true ]] && CLI_VERBOSE=true
}