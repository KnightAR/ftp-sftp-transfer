#!/usr/bin/env bash
# ============================================================
# src/transfer/archive_verify.sh — Archive Integrity Verification
#
# Provides verify_archive_integrity() — tests whether a downloaded
# file is a structurally valid archive.
#
# Return values:
#   0 — archive tested and passed
#   1 — archive tested and FAILED (corrupt or truncated)
#   2 — file extension not a known archive format; skip silently
#
# Supported formats:
#   .xz / .tar.xz        xz --test
#   .gz / .tgz / .tar.gz gzip -t
#   .bz2 / .tar.bz2      bzip2 -t
#   .zip                 zip -T
#   .tar                 tar -tf (list only, no extract)
#
# Unknown extensions return 2 so callers treat the file as a
# plain non-archive and continue normally.
#
# Usage:
#   verify_archive_integrity "/path/to/file.tar.xz"
#   rc=$?
#   # 0=ok  1=corrupt  2=not an archive
#
# Controlled by:
#   VERIFY_ARCHIVE_INTEGRITY=true  (default) — set to false to skip all checks
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()).
# ============================================================

verify_archive_integrity() {
    local file="${1:-}"

    if [[ -z "${file}" ]]; then
        log "WARN" "verify_archive_integrity: no file path provided"
        return 2
    fi

    if [[ ! -f "${file}" ]]; then
        log "WARN" "verify_archive_integrity: file not found: ${file}"
        return 2
    fi

    # Respect the global kill-switch
    if [[ "${VERIFY_ARCHIVE_INTEGRITY:-true}" != "true" ]]; then
        return 2
    fi

    local filename
    filename=$(basename "${file}")

    # Detect format by extension (longest match first)
    local fmt=""
    case "${filename}" in
        *.tar.xz)  fmt="tar.xz"  ;;
        *.tar.gz)  fmt="tar.gz"  ;;
        *.tar.bz2) fmt="tar.bz2" ;;
        *.tgz)     fmt="tar.gz"  ;;
        *.xz)      fmt="xz"      ;;
        *.gz)      fmt="gz"      ;;
        *.bz2)     fmt="bz2"     ;;
        *.zip)     fmt="zip"     ;;
        *.tar)     fmt="tar"     ;;
        *)
            log "DEBUG" "Archive integrity: not a known archive format — skipping: ${filename}"
            return 2
            ;;
    esac

    log "INFO" "Archive integrity: testing ${fmt} archive: ${filename}"

    local rc=0
    case "${fmt}" in
        tar.xz)
            xz --test "${file}" 2>/dev/null; rc=$?
            ;;
        tar.gz|gz)
            gzip -t "${file}" 2>/dev/null; rc=$?
            ;;
        tar.bz2|bz2)
            bzip2 -t "${file}" 2>/dev/null; rc=$?
            ;;
        xz)
            xz --test "${file}" 2>/dev/null; rc=$?
            ;;
        zip)
            zip -T "${file}" &>/dev/null; rc=$?
            ;;
        tar)
            tar -tf "${file}" > /dev/null 2>&1; rc=$?
            ;;
    esac

    if (( rc == 0 )); then
        log "INFO" "Archive integrity: OK — ${filename}"
        return 0
    else
        log "ERROR" "Archive integrity: FAILED (corrupt or truncated ${fmt} archive): ${filename}"
        return 1
    fi
}