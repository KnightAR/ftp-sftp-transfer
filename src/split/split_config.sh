#!/usr/bin/env bash
# ============================================================
# src/split/split_config.sh — Split Transfer Configuration Defaults
#
# Defines default values for all split-specific configuration
# variables.  These are applied after the main transfer.conf is
# sourced by load_config(), using the same ":=" default pattern
# so any value already set in transfer.conf takes precedence.
#
# Variables defined here:
#   SPLIT_SIZE          — part size passed to "split -b".  Accepts
#                         any suffix that split understands: k, m, g,
#                         K, M, G.  Default: 1g (1 GiB).
#   SPLIT_PART_WORKERS  — number of parallel SFTP upload workers for
#                         part uploads.  Defaults to SFTP_MAX_WORKERS
#                         from the main config so no extra setting is
#                         needed in transfer.conf.
#   SPLIT_RESTORE_WORKERS — number of parallel SFTP download workers
#                         used by split_restore.sh.  Also defaults to
#                         SFTP_MAX_WORKERS.
#   SPLIT_SUFFIX_LENGTH — digit width for part suffixes (e.g. 5 gives
#                         .part.00001).  Default: 5 (supports up to
#                         99,999 parts — handles files up to ~100 TB
#                         at 1 GiB part size).
#   SPLIT_PARTS_SUBDIR  — name of the subdirectory created under the
#                         original file's parent directory on SFTP to
#                         hold the part files.  Default: "split".
#   SPLIT_VERIFY_SLOTS       — maximum number of upload workers that may
#                         re-download a part from SFTP simultaneously
#                         for post-upload hash verification.  Throttles
#                         concurrent re-downloads to avoid overloading
#                         object-storage SFTP connection limits while
#                         keeping uploads fully parallel.  Default: 3.
#   SPLIT_VERIFY_RETRIES      — number of times to retry a failed verify
#                         re-download before marking the part as an error.
#                         Handles transient SFTP connection rejections.
#                         Default: 4.
#   SPLIT_VERIFY_RETRY_SLEEP  — seconds to wait between verify retry attempts.
#                         Default: 10.
#   SPLIT_RESTORE_RETRIES     — number of times to retry a failed restore part
#                         download before marking it as an error.  Handles
#                         transient SFTP connection failures or empty listings.
#                         Default: 4.
#   SPLIT_RESTORE_RETRY_SLEEP — seconds to wait between restore download retry
#                         attempts.  Default: 10.
#   SPLIT_HASH_WORKERS  — number of parallel sha256 hash workers used during
#                         the per-part metadata collection phase in
#                         split_upload.sh.  Defaults to nproc-1 (at least 1).
#                         Has no effect on split_transfer.sh or
#                         split_restore.sh (those use sequential hashing).
#                         Can be overridden via -H on the split_upload.sh CLI.
#   SPLIT_TEMP_DIR      — required base temp directory for split_transfer.sh
#                         and split_restore.sh.  Must be set in transfer.conf
#                         or via -t on the CLI.  Unlike transfer.sh, split
#                         scripts do NOT fall back to mktemp — a static path
#                         is required so staging survives a failed run for
#                         resume.  Example: /mnt/helium/temp
#
# Dependency order:
#   Must be called from within load_config() or after it, so that
#   SFTP_MAX_WORKERS is already set from transfer.conf.
# ============================================================

apply_split_defaults() {
    # Part size — any suffix accepted by GNU split -b (k/m/g/K/M/G)
    : "${SPLIT_SIZE:=1g}"

    # Parallel workers for part uploads / downloads.
    # Fall back to SFTP_MAX_WORKERS so the operator only needs one setting.
    : "${SPLIT_PART_WORKERS:=${SFTP_MAX_WORKERS:-10}}"
    : "${SPLIT_RESTORE_WORKERS:=3}"

    # Suffix digit width — 5 digits = up to 99,999 parts
    : "${SPLIT_SUFFIX_LENGTH:=5}"

    # Subdirectory name under the original file's parent on SFTP
    : "${SPLIT_PARTS_SUBDIR:=split}"

    # Max concurrent SFTP re-downloads during post-upload hash verification
    : "${SPLIT_VERIFY_SLOTS:=3}"

    # Retry attempts + sleep for failed verify re-downloads
    : "${SPLIT_VERIFY_RETRIES:=4}"
    : "${SPLIT_VERIFY_RETRY_SLEEP:=10}"

    # Retry attempts + sleep for failed restore part downloads
    : "${SPLIT_RESTORE_RETRIES:=4}"
    : "${SPLIT_RESTORE_RETRY_SLEEP:=10}"

    # Parallel sha256 hash workers for per-part metadata collection (split_upload.sh only).
    # Defaults to nproc-1, clamped to at least 1.
    local _default_hash_workers=$(( $(nproc 2>/dev/null || echo 2) - 1 ))
    (( _default_hash_workers < 1 )) && _default_hash_workers=1
    : "${SPLIT_HASH_WORKERS:=${_default_hash_workers}}"

    # Static temp directory for split scripts — no mktemp fallback.
    # Required for resume: staging must survive a failed run.
    : "${SPLIT_TEMP_DIR:=}"

    # VERIFY_ARCHIVE_INTEGRITY: when true (default), test the downloaded file for
    # structural validity before splitting.  Non-archive files are silently skipped.
    # Set to false in transfer.conf to disable.
    : "${VERIFY_ARCHIVE_INTEGRITY:=true}"
}

# resolve_split_config
# Sets DEFAULT_CONFIG for split scripts using this priority order:
#   1. -c CLI override (already in CLI_CONFIG — load_config() handles this)
#   2. split.transfer.conf in SCRIPT_DIR (if it exists)
#   3. transfer.conf in SCRIPT_DIR (standard fallback)
#
# Must be called before load_config() so DEFAULT_CONFIG is set correctly.
resolve_split_config() {
    local split_conf="${SCRIPT_DIR}/split.transfer.conf"
    local base_conf="${SCRIPT_DIR}/transfer.conf"

    # DEFAULT_CONFIG is read by load_config() in config.sh — not unused.
    # Note: logging not yet set up at this point — use echo for visibility.
    if [[ -f "${split_conf}" ]]; then
        # shellcheck disable=SC2034
        DEFAULT_CONFIG="${split_conf}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG]  Using split config: ${split_conf}" >&2
    elif [[ -f "${base_conf}" ]]; then
        # shellcheck disable=SC2034
        DEFAULT_CONFIG="${base_conf}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG]  split.transfer.conf not found — using: ${base_conf}" >&2
    else
        # Neither exists — let load_config() emit the standard error
        # shellcheck disable=SC2034
        DEFAULT_CONFIG="${base_conf}"
    fi
}

validate_split_config() {
    local errors=0

    # Validate SPLIT_SIZE — must be a number followed by an optional valid suffix
    if ! [[ "${SPLIT_SIZE}" =~ ^[0-9]+[kKmMgG]?$ ]]; then
        echo "ERROR: SPLIT_SIZE must be a number with optional suffix k/m/g (got: '${SPLIT_SIZE}')" >&2
        (( errors++ )) || true
    fi

    # Validate SPLIT_PART_WORKERS — must be a positive integer
    if ! [[ "${SPLIT_PART_WORKERS}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: SPLIT_PART_WORKERS must be a positive integer (got: '${SPLIT_PART_WORKERS}')" >&2
        (( errors++ )) || true
    fi

    # Validate SPLIT_RESTORE_WORKERS — must be a positive integer
    if ! [[ "${SPLIT_RESTORE_WORKERS}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: SPLIT_RESTORE_WORKERS must be a positive integer (got: '${SPLIT_RESTORE_WORKERS}')" >&2
        (( errors++ )) || true
    fi

    # Validate SPLIT_HASH_WORKERS — must be a positive integer
    if ! [[ "${SPLIT_HASH_WORKERS}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: SPLIT_HASH_WORKERS must be a positive integer (got: '${SPLIT_HASH_WORKERS}')" >&2
        (( errors++ )) || true
    fi

    # Validate SPLIT_SUFFIX_LENGTH — must be a positive integer between 1 and 10
    if ! [[ "${SPLIT_SUFFIX_LENGTH}" =~ ^[1-9][0-9]*$ ]] || (( SPLIT_SUFFIX_LENGTH > 10 )); then
        echo "ERROR: SPLIT_SUFFIX_LENGTH must be an integer 1-10 (got: '${SPLIT_SUFFIX_LENGTH}')" >&2
        (( errors++ )) || true
    fi

    # Validate SPLIT_PARTS_SUBDIR — must be a simple directory name (no slashes)
    if [[ -z "${SPLIT_PARTS_SUBDIR}" ]] || [[ "${SPLIT_PARTS_SUBDIR}" == */* ]]; then
        echo "ERROR: SPLIT_PARTS_SUBDIR must be a simple directory name with no slashes (got: '${SPLIT_PARTS_SUBDIR}')" >&2
        (( errors++ )) || true
    fi

    # SPLIT_TEMP_DIR is validated in split_main()/restore_main() after CLI
    # overrides are applied — not here, because -t may not have been parsed yet
    # when validate_split_config() is first called.

    if (( errors > 0 )); then
        echo "ERROR: ${errors} split configuration error(s) found." >&2
        exit 1
    fi
}