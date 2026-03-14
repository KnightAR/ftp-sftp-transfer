#!/usr/bin/env bash
# ============================================================
# src/core/constants.sh — Global Constants & Runtime State
#
# Declares every global variable used across the entire script.
# This file must be sourced first — all other modules depend on
# the variables defined here.  No functions are defined here;
# this file is purely declarations and default assignments that
# do not require the config file to be loaded yet.
#
# Globals defined here fall into four groups:
#   1. Script identity  — name, directory, version
#   2. Runtime paths    — lock file, log files, FTP connection string
#   3. Worker state     — PID array, reupload log path
#   4. Run counters     — CNT_* totals merged from worker result files
# ============================================================

# ---- Script identity ----
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
# SCRIPT_DIR is set and declared readonly by transfer.sh (the orchestrator)
# before this file is sourced, so we do not re-declare it here.
# It always points to the project root directory (where transfer.sh lives).
readonly SCRIPT_VERSION="2.1.0"

# Default config path (overridden by -c flag)
DEFAULT_CONFIG="${SCRIPT_DIR}/transfer.conf"

# ---- PID lock file ----
# Prevents two instances of the script running simultaneously (e.g. overlapping cron jobs).
# The lock file lives in /tmp so it is automatically cleared on reboot.
LOCK_FILE="/tmp/ftp_sftp_transfer.lock"
LOCK_FD=9

# ---- Runtime state ----
TEMP_DIR_CREATED=false   # true when mktemp created TEMP_DIR (cleanup_temp removes it entirely)
LOG_FILE=""              # Set by setup_logging() once LOG_DIR is known from config
ERROR_LOG_FILE=""        # Set by setup_logging(); errors are mirrored here in addition to LOG_FILE
FTP_CONNECT_STR=""       # Assembled lftp connection string; set by setup_ftp_connection()

# ---- Worker PID tracking ----
# Populated by run_pipeline(), read by trap_cleanup().
# Ensures Ctrl+C / SIGTERM kills all worker sub-processes before staging is deleted,
# preventing workers from writing to paths that cleanup_temp is about to remove.
WORKER_PIDS=()

# ---- Persistent re-upload flag file ----
# Survives across runs and temp-dir cleanups.
# Any FTP path written here is force-reuploaded on the next run regardless
# of whether the file already exists on SFTP.  Entries are written on
# checksum failure and cleared after a verified-clean successful upload.
# Path defaults to SCRIPT_DIR; can be overridden in config via REUPLOAD_LOG.
REUPLOAD_LOG="${SCRIPT_DIR}/reupload.log"

# ---- Run counters ----
# These are initialised to zero here.  Each worker writes per-worker result
# files; merge_worker_results() sums them into these globals at the end of
# run_pipeline() so print_summary() can report totals across all workers.
CNT_SCANNED=0
CNT_TRANSFERRED=0
CNT_OVERWRITTEN=0
CNT_SKIPPED=0
CNT_DELETED=0
CNT_ERRORS=0

# ---- Run timing ----
RUN_START_TIME=""    # Human-readable timestamp set at the top of main()
RUN_START_EPOCH=0    # Unix epoch set at the top of main(); used to compute duration