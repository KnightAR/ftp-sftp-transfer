#!/usr/bin/env bash
# ============================================================
# src/zpaq/zpaq_utils.sh — zpaqfranz Tool Detection & Core Utilities
#
# Provides low-level zpaqfranz helpers used by both zpaq_archive.sh
# and storezpaq.sh:
#
#   detect_zpaqfranz()          — checks that zpaqfranz is on PATH and
#                                 sets ZPAQFRANZ_BIN. Fatal if not found.
#
#   zpaq_file_exists()          — checks whether a given internal name
#                                 already exists in a .zpaq archive.
#                                 Returns 0 if found, 1 if not.
#                                 MUST be called outside $(...) — uses log().
#
#   zpaq_test_archive()         — runs "zpaqfranz t <archive>" and returns
#                                 0 on success, 1 on failure.
#                                 Streams output to log at DEBUG level.
#
# Convention: all functions use log() from src/core/logging.sh.
# ZPAQFRANZ_BIN is the resolved binary path set by detect_zpaqfranz().
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()).
# ============================================================

# Resolved path to zpaqfranz binary — set by detect_zpaqfranz().
ZPAQFRANZ_BIN=""

# Thread count used by zpaqfranz — set by zpaq_calc_threads().
# Callers (zpaq_archive_ops.sh, zpaq_archive.sh) may override this after
# calling zpaq_calc_threads() by assigning ZPAQFRANZ_THREADS directly.
ZPAQFRANZ_THREADS=1

# detect_zpaqfranz
#
# Locates the zpaqfranz binary, sets ZPAQFRANZ_BIN, and checks the version.
# If the installed binary is older than v64.7 (the first upstream release that
# includes -stdinsize), ZPAQ_STDINSIZE_HINT is forced to "false" and a warning
# is logged so the operator knows why progress % is not shown.
# Exits with a clear install hint if zpaqfranz is not found at all.
detect_zpaqfranz() {
    if ! command -v zpaqfranz &>/dev/null; then
        echo "ERROR: zpaqfranz is required but not found on PATH." >&2
        echo "       Build from source:" >&2
        echo "         wget https://github.com/fcorbelli/zpaqfranz/archive/refs/tags/64.7.tar.gz" >&2
        echo "         tar xzf 64.7.tar.gz && cd zpaqfranz-64.7/NONWINDOWS" >&2
        echo "         make && sudo cp zpaqfranz /usr/local/bin/" >&2
        echo "       Or on Debian 13+: sudo apt-get install zpaqfranz" >&2
        exit 2
    fi

    ZPAQFRANZ_BIN=$(command -v zpaqfranz)
    log "DEBUG" "zpaqfranz found: ${ZPAQFRANZ_BIN}"

    # Parse the version from the first line of "zpaqfranz" with no arguments.
    # Example: "zpaqfranz v64.7g-JIT,SFTP-L,HW SHA1/2,4,(2026-03-24)"
    # Extract the major.minor digits immediately after "v" and compare as an
    # integer (major*1000 + minor) against 64007 (== v64.7).
    local ver_string ver_num
    ver_string=$("${ZPAQFRANZ_BIN}" 2>&1 | awk 'NR==1 { s = $0; sub(/.*v/, "", s); sub(/[^0-9.].*/, "", s); print s; exit }')
    ver_num=$(awk -v v="${ver_string}" 'BEGIN {
        split(v, p, ".")
        print (p[1] != "" ? p[1]*1000 + p[2] : 0)
    }')

    log "DEBUG" "zpaqfranz version string: ${ver_string}  (numeric: ${ver_num})"

    if (( ver_num > 0 && ver_num < 64007 )); then
        log "WARN" "zpaqfranz ${ver_string} is older than v64.7; -stdinsize is not supported. Forcing ZPAQ_STDINSIZE_HINT=false."
        # shellcheck disable=SC2034  # ZPAQ_STDINSIZE_HINT is read by zpaq_archive_ops.sh
        ZPAQ_STDINSIZE_HINT="false"
    fi
}

# zpaq_file_exists ARCHIVE INTERNAL_NAME
#
# Returns 0 if INTERNAL_NAME is already present in ARCHIVE, 1 if not.
# Uses "zpaqfranz l" and greps for "+ INTERNAL_NAME" (the listing prefix
# for stored files as seen in the official archive.sh pattern).
#
# Usage:
#   if zpaq_file_exists "backup.zpaq" "slim/mydb.sql"; then
#       log "INFO" "Already in archive — skipping"
#   fi
zpaq_file_exists() {
    local archive="$1"
    local internal_name="$2"

    # Archive does not exist yet — file cannot be in it
    if [[ ! -f "${archive}" ]]; then
        return 1
    fi

    local found
    found=$("${ZPAQFRANZ_BIN}" l "${archive}" 2>/dev/null \
            | grep -F "+ ${internal_name}" \
            | head -1)

    if [[ -n "${found}" ]]; then
        log "DEBUG" "zpaq_file_exists: found '${internal_name}' in ${archive}"
        return 0
    fi

    log "DEBUG" "zpaq_file_exists: '${internal_name}' not in ${archive}"
    return 1
}

# zpaq_test_archive ARCHIVE
#
# Runs "zpaqfranz t <archive>" to verify internal integrity.
# Streams stdout+stderr from zpaqfranz to log at DEBUG level line by line.
# Returns 0 on success, 1 on failure.
#
# Usage:
#   if ! zpaq_test_archive "backup.zpaq"; then
#       log "ERROR" "Archive integrity check failed — aborting upload"
#       exit 1
#   fi
zpaq_test_archive() {
    local archive="$1"

    if [[ ! -f "${archive}" ]]; then
        log "ERROR" "zpaq_test_archive: archive not found: ${archive}"
        return 1
    fi

    log "INFO" "Testing archive integrity: ${archive}"

    local threads="${ZPAQFRANZ_THREADS:-1}"

    # zpaqfranz writes progress to stderr (terminal) and may write to stdout.
    # Stdout is tee'd to LOG_FILE so it appears in the log and on the terminal.
    # Stderr goes directly to the terminal for live progress display.
    # PIPESTATUS[0] captures zpaqfranz's exit code across the tee pipe.
    local rc=0
    "${ZPAQFRANZ_BIN}" t "${archive}" -threads "${threads}" \
        | tee -a "${LOG_FILE:-/dev/null}"
    rc="${PIPESTATUS[0]}"

    # zpaqfranz t exits 0 on success, non-zero on any error
    if (( rc != 0 )); then
        log "ERROR" "zpaq_test_archive: integrity test FAILED (rc=${rc}): ${archive}"
        return 1
    fi

    log "INFO" "Archive integrity OK: ${archive}"
    return 0
}

# zpaq_calc_threads [REQUESTED]
#
# Calculates the number of threads to pass to zpaqfranz -threads and sets
# ZPAQFRANZ_THREADS.
#
# Rules:
#   - If REQUESTED is given and > 0, use it directly (CLI override).
#   - Otherwise, default to 25% of available nproc, minimum 1, maximum 8.
#
# The 25%/max-8 default is intentional: zpaqfranz compression is CPU-heavy;
# leaving headroom avoids starving other processes on shared servers.
#
# After calling this function, ZPAQFRANZ_THREADS is available globally.
# zpaq_add_stdin() reads ZPAQFRANZ_THREADS automatically — callers do not
# need to pass it explicitly.
#
# Usage:
#   zpaq_calc_threads          # auto: 25% of nproc, max 8
#   zpaq_calc_threads 4        # explicit: 4 threads
zpaq_calc_threads() {
    local requested="${1:-0}"

    if (( requested > 0 )); then
        ZPAQFRANZ_THREADS="${requested}"
        log "DEBUG" "zpaq_calc_threads: using requested thread count: ${ZPAQFRANZ_THREADS}"
        return 0
    fi

    # Detect available logical CPUs
    local total_cpus=1
    if command -v nproc &>/dev/null; then
        total_cpus=$(nproc 2>/dev/null || echo 1)
    elif [[ -r /proc/cpuinfo ]]; then
        total_cpus=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
    fi

    # 25% of total, rounded down, minimum 1, maximum 8
    local calculated=$(( total_cpus / 4 ))
    (( calculated < 1 )) && calculated=1
    (( calculated > 8 )) && calculated=8

    ZPAQFRANZ_THREADS="${calculated}"
    log "DEBUG" "zpaq_calc_threads: total_cpus=${total_cpus} -> threads=${ZPAQFRANZ_THREADS} (25% capped at 8)"
}