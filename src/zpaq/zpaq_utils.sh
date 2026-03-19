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

# detect_zpaqfranz
#
# Locates the zpaqfranz binary and sets ZPAQFRANZ_BIN.
# Exits with a clear install hint if not found.
detect_zpaqfranz() {
    if command -v zpaqfranz &>/dev/null; then
        ZPAQFRANZ_BIN=$(command -v zpaqfranz)
        log "DEBUG" "zpaqfranz found: ${ZPAQFRANZ_BIN}"
        return 0
    fi

    echo "ERROR: zpaqfranz is required but not found on PATH." >&2
    echo "       Build from source:" >&2
    echo "         wget https://github.com/fcorbelli/zpaqfranz/archive/refs/tags/64.6.tar.gz" >&2
    echo "         tar xzf 64.6.tar.gz && cd zpaqfranz-64.6/NONWINDOWS" >&2
    echo "         make && sudo cp zpaqfranz /usr/local/bin/" >&2
    echo "       Or on Debian 13+: sudo apt-get install zpaqfranz" >&2
    exit 2
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

    local rc=0
    local line
    while IFS= read -r line; do
        log "DEBUG" "zpaqfranz t: ${line}"
    done < <("${ZPAQFRANZ_BIN}" t "${archive}" 2>&1) || rc=$?

    # zpaqfranz t exits 0 on success, non-zero on any error
    if (( rc != 0 )); then
        log "ERROR" "zpaq_test_archive: integrity test FAILED (rc=${rc}): ${archive}"
        return 1
    fi

    log "INFO" "Archive integrity OK: ${archive}"
    return 0
}