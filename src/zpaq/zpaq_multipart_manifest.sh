#!/usr/bin/env bash
# ============================================================
# src/zpaq/zpaq_multipart_manifest.sh — Multipart zpaq Manifest Management
#
# Manages the manifest file for a multipart zpaqfranz archive set.
# One manifest governs the entire set; it is named:
#
#   <ZPAQ_LOCAL_DIR>/<basename>.zpaq.manifest
#
# Manifest format (plain text):
#
#   # zpaq multipart manifest — managed by storezpaq_multi.sh — do not edit manually
#   archive_type=multipart
#   basename=vxtl_helium
#   question_mark_count=7
#   fragment=3
#   total_parts=3
#   total_size=4831838208
#   last_updated=20240115143022
#
#   [parts]
#   vxtl_helium0000001.zpaq  size=1610612736  sha256=a3f8c2...  added=20240113120045
#   vxtl_helium0000002.zpaq  size=1543503872  sha256=b7d1e9...  added=20240114093112
#   vxtl_helium0000003.zpaq  size=1677721600  sha256=c4a2f7...  added=20240115143001
#
# Global state variables populated by multipart_manifest_read():
#   MP_MANIFEST_BASENAME          — archive base name
#   MP_MANIFEST_QUESTION_MARKS    — number of ? digits
#   MP_MANIFEST_FRAGMENT          — locked -fragment N value
#   MP_MANIFEST_TOTAL_PARTS       — count of known parts
#   MP_MANIFEST_TOTAL_SIZE        — sum of all part sizes (bytes)
#   MP_MANIFEST_LAST_UPDATED      — YYYYMMDDHHMMSS of last write
#   MP_MANIFEST_PART_SHA256[]     — associative array: partname → sha256
#   MP_MANIFEST_PART_SIZE[]       — associative array: partname → size bytes
#   MP_MANIFEST_PART_ADDED[]      — associative array: partname → added timestamp
#
# Functions:
#   multipart_manifest_path       BASENAME LOCAL_DIR
#   multipart_manifest_read       MANIFEST_PATH
#   multipart_manifest_write      MANIFEST_PATH
#   multipart_manifest_add_part   PART_FILENAME SIZE SHA256
#   multipart_manifest_part_known PART_FILENAME
#   multipart_manifest_get_fragment     MANIFEST_PATH
#   multipart_manifest_check_fragment   MANIFEST_PATH CONFIG_FRAGMENT
#   multipart_manifest_remote_diverged  LOCAL_PATH REMOTE_PATH
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()).
# ============================================================

# ---------------------------------------------------------------------------
# Global state — populated by multipart_manifest_read(), consumed by
# multipart_manifest_write() and multipart_manifest_add_part().
# ---------------------------------------------------------------------------
MP_MANIFEST_BASENAME=""
MP_MANIFEST_QUESTION_MARKS="${ZPAQ_MULTIPART_QUESTION_MARKS:-7}"
MP_MANIFEST_FRAGMENT="${ZPAQ_FRAGMENT:-3}"
MP_MANIFEST_TOTAL_PARTS=0
MP_MANIFEST_TOTAL_SIZE=0
MP_MANIFEST_LAST_UPDATED=""

declare -gA MP_MANIFEST_PART_SHA256=()
declare -gA MP_MANIFEST_PART_SIZE=()
declare -gA MP_MANIFEST_PART_ADDED=()

# ---------------------------------------------------------------------------
# multipart_manifest_path BASENAME LOCAL_DIR
#
# Echoes the canonical manifest file path:
#   <LOCAL_DIR>/<basename>.zpaq.manifest
# ---------------------------------------------------------------------------
multipart_manifest_path() {
    local basename="$1"
    local local_dir="$2"
    echo "${local_dir}/${basename}.zpaq.manifest"
}

# ---------------------------------------------------------------------------
# multipart_manifest_read MANIFEST_PATH
#
# Parses the manifest at MANIFEST_PATH into the MP_MANIFEST_* globals.
# Returns 0 on success, 1 if the file does not exist or is missing
# required fields.
# ---------------------------------------------------------------------------
multipart_manifest_read() {
    local manifest_path="$1"

    # Reset state
    MP_MANIFEST_BASENAME=""
    MP_MANIFEST_QUESTION_MARKS="${ZPAQ_MULTIPART_QUESTION_MARKS:-7}"
    MP_MANIFEST_FRAGMENT="${ZPAQ_FRAGMENT:-3}"
    MP_MANIFEST_TOTAL_PARTS=0
    MP_MANIFEST_TOTAL_SIZE=0
    MP_MANIFEST_LAST_UPDATED=""
    MP_MANIFEST_PART_SHA256=()
    MP_MANIFEST_PART_SIZE=()
    MP_MANIFEST_PART_ADDED=()

    if [[ ! -f "${manifest_path}" ]]; then
        log "DEBUG" "multipart_manifest_read: not found: ${manifest_path}"
        return 1
    fi

    local in_parts=0
    local line key val
    while IFS= read -r line; do
        # Skip comment lines and blank lines
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Section header
        if [[ "${line}" == "[parts]" ]]; then
            in_parts=1
            continue
        fi

        if (( in_parts == 0 )); then
            # Header key=value pairs
            key="${line%%=*}"
            val="${line#*=}"
            case "${key}" in
                basename)              MP_MANIFEST_BASENAME="${val}"           ;;
                question_mark_count)   MP_MANIFEST_QUESTION_MARKS="${val}"     ;;
                fragment)              MP_MANIFEST_FRAGMENT="${val}"           ;;
                total_parts)           MP_MANIFEST_TOTAL_PARTS="${val}"        ;;
                total_size)            MP_MANIFEST_TOTAL_SIZE="${val}"         ;;
                last_updated)          MP_MANIFEST_LAST_UPDATED="${val}"       ;;
            esac
        else
            # Parts lines: <partname>  size=<bytes>  sha256=<hex>  added=<ts>
            # Extract each field by pattern
            local partname size_val sha256_val added_val
            partname=$(awk '{print $1}' <<< "${line}")
            size_val=$(grep -oP 'size=\K[0-9]+' <<< "${line}" || true)
            sha256_val=$(grep -oP 'sha256=\K[0-9a-f]+' <<< "${line}" || true)
            added_val=$(grep -oP 'added=\K[0-9]+' <<< "${line}" || true)

            if [[ -n "${partname}" && -n "${sha256_val}" ]]; then
                MP_MANIFEST_PART_SHA256["${partname}"]="${sha256_val}"
                MP_MANIFEST_PART_SIZE["${partname}"]="${size_val:-0}"
                MP_MANIFEST_PART_ADDED["${partname}"]="${added_val:-}"
            fi
        fi
    done < "${manifest_path}"

    if [[ -z "${MP_MANIFEST_BASENAME}" ]]; then
        log "WARN" "multipart_manifest_read: missing basename field: ${manifest_path}"
        return 1
    fi

    log "DEBUG" "multipart_manifest_read: ${manifest_path} basename=${MP_MANIFEST_BASENAME} parts=${MP_MANIFEST_TOTAL_PARTS} fragment=${MP_MANIFEST_FRAGMENT}"
    return 0
}

# ---------------------------------------------------------------------------
# multipart_manifest_write MANIFEST_PATH
#
# Writes the current MP_MANIFEST_* state to MANIFEST_PATH.
# Overwrites the file directly (no temp+mv needed — atomicity is handled
# at the .zpaq part level).
# ---------------------------------------------------------------------------
multipart_manifest_write() {
    local manifest_path="$1"
    local now
    now=$(date +"%Y%m%d%H%M%S")
    MP_MANIFEST_LAST_UPDATED="${now}"

    {
        echo "# zpaq multipart manifest — managed by storezpaq_multi.sh — do not edit manually"
        echo "archive_type=multipart"
        echo "basename=${MP_MANIFEST_BASENAME}"
        echo "question_mark_count=${MP_MANIFEST_QUESTION_MARKS}"
        echo "fragment=${MP_MANIFEST_FRAGMENT}"
        echo "total_parts=${MP_MANIFEST_TOTAL_PARTS}"
        echo "total_size=${MP_MANIFEST_TOTAL_SIZE}"
        echo "last_updated=${now}"
        echo ""
        echo "[parts]"
        # Emit parts in sorted order by filename (lexicographic = numeric for 0-padded names)
        local partname
        for partname in $(printf '%s\n' "${!MP_MANIFEST_PART_SHA256[@]}" | sort); do
            printf '%-40s  size=%-15s  sha256=%s  added=%s\n' \
                "${partname}" \
                "${MP_MANIFEST_PART_SIZE[${partname}]:-0}" \
                "${MP_MANIFEST_PART_SHA256[${partname}]}" \
                "${MP_MANIFEST_PART_ADDED[${partname}]:-}"
        done
    } > "${manifest_path}"

    log "DEBUG" "multipart_manifest_write: wrote ${manifest_path} (parts=${MP_MANIFEST_TOTAL_PARTS} total_size=${MP_MANIFEST_TOTAL_SIZE})"
}

# ---------------------------------------------------------------------------
# multipart_manifest_add_part PART_FILENAME SIZE SHA256
#
# Adds a new part entry to the in-memory MP_MANIFEST_* state.
# Updates total_parts and total_size.
# Call multipart_manifest_write() afterwards to persist.
# ---------------------------------------------------------------------------
multipart_manifest_add_part() {
    local part_filename="$1"
    local size="$2"
    local sha256="$3"
    local now
    now=$(date +"%Y%m%d%H%M%S")

    MP_MANIFEST_PART_SHA256["${part_filename}"]="${sha256}"
    MP_MANIFEST_PART_SIZE["${part_filename}"]="${size}"
    MP_MANIFEST_PART_ADDED["${part_filename}"]="${now}"

    MP_MANIFEST_TOTAL_PARTS=$(( MP_MANIFEST_TOTAL_PARTS + 1 ))
    MP_MANIFEST_TOTAL_SIZE=$(( MP_MANIFEST_TOTAL_SIZE + size ))

    log "DEBUG" "multipart_manifest_add_part: ${part_filename} size=${size} sha256=${sha256} total_parts=${MP_MANIFEST_TOTAL_PARTS}"
}

# ---------------------------------------------------------------------------
# multipart_manifest_part_known PART_FILENAME
#
# Returns 0 if PART_FILENAME is already in the in-memory manifest state.
# Returns 1 if unknown.
# ---------------------------------------------------------------------------
multipart_manifest_part_known() {
    local part_filename="$1"
    if [[ -n "${MP_MANIFEST_PART_SHA256[${part_filename}]+set}" ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# multipart_manifest_get_fragment MANIFEST_PATH
#
# Echoes the locked fragment value from MANIFEST_PATH without altering
# global state.  Returns 1 if the manifest does not exist.
# ---------------------------------------------------------------------------
multipart_manifest_get_fragment() {
    local manifest_path="$1"

    if [[ ! -f "${manifest_path}" ]]; then
        return 1
    fi

    local frag
    frag=$(grep -m1 '^fragment=' "${manifest_path}" | cut -d= -f2)
    echo "${frag}"
}

# ---------------------------------------------------------------------------
# multipart_manifest_check_fragment MANIFEST_PATH CONFIG_FRAGMENT
#
# Validates that the fragment value locked in the manifest matches
# CONFIG_FRAGMENT (the current ZPAQ_FRAGMENT config value).
#
# If the manifest does not yet exist (first run), returns 0 — no check
# needed; CONFIG_FRAGMENT will be used and locked on the first add.
#
# Returns 0 if consistent (or manifest absent).
# Returns 1 if there is a mismatch — logs a clear error.
# ---------------------------------------------------------------------------
multipart_manifest_check_fragment() {
    local manifest_path="$1"
    local config_fragment="$2"

    if [[ ! -f "${manifest_path}" ]]; then
        log "DEBUG" "multipart_manifest_check_fragment: no manifest yet — will lock fragment=${config_fragment} on first add"
        return 0
    fi

    local locked_fragment
    locked_fragment=$(multipart_manifest_get_fragment "${manifest_path}")

    if [[ "${locked_fragment}" != "${config_fragment}" ]]; then
        log "ERROR" "multipart_manifest_check_fragment: fragment mismatch!"
        log "ERROR" "  Config ZPAQ_FRAGMENT=${config_fragment} does not match archive fragment=${locked_fragment}."
        log "ERROR" "  The fragment size cannot be changed for an existing multipart archive."
        log "ERROR" "  Aborting to prevent archive corruption."
        return 1
    fi

    log "DEBUG" "multipart_manifest_check_fragment: fragment=${locked_fragment} OK"
    return 0
}

# ---------------------------------------------------------------------------
# multipart_manifest_remote_diverged LOCAL_PATH REMOTE_PATH
#
# Compares total_parts from the local and remote manifests.
# Returns 0 (diverged) if remote total_parts > local total_parts.
# Returns 1 (not diverged) if equal or if remote does not exist.
# Returns 2 if remote has FEWER parts than local (unexpected — upload gap).
# ---------------------------------------------------------------------------
multipart_manifest_remote_diverged() {
    local local_path="$1"
    local remote_path="$2"

    if [[ ! -f "${remote_path}" ]]; then
        log "DEBUG" "multipart_manifest_remote_diverged: no remote manifest — first run"
        return 1
    fi

    local local_parts=0
    local remote_parts=0

    if [[ -f "${local_path}" ]]; then
        local_parts=$(grep -m1 '^total_parts=' "${local_path}" | cut -d= -f2 || echo 0)
    fi
    remote_parts=$(grep -m1 '^total_parts=' "${remote_path}" | cut -d= -f2 || echo 0)

    # Strip whitespace
    local_parts="${local_parts//[[:space:]]/}"
    remote_parts="${remote_parts//[[:space:]]/}"

    log "DEBUG" "multipart_manifest_remote_diverged: local_parts=${local_parts} remote_parts=${remote_parts}"

    if (( remote_parts > local_parts )); then
        return 0   # Remote has more — need to sync down
    elif (( remote_parts < local_parts )); then
        return 2   # Local has more — upload gap from prior run
    fi

    return 1   # Equal — in sync
}