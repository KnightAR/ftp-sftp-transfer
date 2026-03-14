#!/usr/bin/env bash
# ============================================================
# transfer.sh — FTP to SFTP Transfer Script
#
# Purpose : Mirror files from an FTP server to an SFTP server,
#           with size-based overwrite detection, decoupled
#           parallel FTP download + SFTP upload workers,
#           disk-space guarding, mtime-based FTP retention/
#           deletion, checksum verification, and structured
#           logging.
#
# Version : 2.1.0
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
# Source layout:
#   src/core/        — constants, CLI args, config loading, logging
#   src/system/      — dependency check, PID lock, temp dir, signal traps
#   src/transfer/    — FTP listing, SFTP I/O, exclusions, reupload tracking,
#                      FTP deletion
#   src/workers/     — atomic counters/queues, disk guard, download & upload workers
#   src/pipeline/    — deletion stage, pipeline orchestrator, summary, main()
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# Resolve the directory containing this script so all source paths are
# absolute and work regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ============================================================
# Source all modules in strict dependency order.
# Each group depends on the groups above it — do not reorder.
# ============================================================

# -- Core: must load first (no inter-module dependencies) --
source "${SCRIPT_DIR}/src/core/constants.sh"
source "${SCRIPT_DIR}/src/core/args.sh"
source "${SCRIPT_DIR}/src/core/config.sh"
source "${SCRIPT_DIR}/src/core/logging.sh"

# -- System: depends on core --
source "${SCRIPT_DIR}/src/system/dependencies.sh"
source "${SCRIPT_DIR}/src/system/lock.sh"
source "${SCRIPT_DIR}/src/system/temp.sh"
source "${SCRIPT_DIR}/src/system/trap.sh"       # registers trap at source time

# -- Transfer: depends on core + system --
source "${SCRIPT_DIR}/src/transfer/exclusions.sh"
source "${SCRIPT_DIR}/src/transfer/ftp.sh"
source "${SCRIPT_DIR}/src/transfer/sftp.sh"
source "${SCRIPT_DIR}/src/transfer/reupload.sh"
source "${SCRIPT_DIR}/src/transfer/ftp_delete.sh"

# -- Workers: depends on core + system + transfer --
source "${SCRIPT_DIR}/src/workers/counters.sh"
source "${SCRIPT_DIR}/src/workers/disk_guard.sh"
source "${SCRIPT_DIR}/src/workers/download_worker.sh"
source "${SCRIPT_DIR}/src/workers/upload_worker.sh"

# -- Pipeline: depends on everything above --
source "${SCRIPT_DIR}/src/pipeline/deletion_stage.sh"
source "${SCRIPT_DIR}/src/pipeline/pipeline.sh"
source "${SCRIPT_DIR}/src/pipeline/summary.sh"
source "${SCRIPT_DIR}/src/pipeline/main.sh"     # defines main()

# ============================================================
# ENTRYPOINT
# ============================================================

main "$@"