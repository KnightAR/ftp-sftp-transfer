#!/usr/bin/env bash
# ============================================================
# compress_utils.sh — Shared Compression Utilities
#
# Sourced by recompress.sh and strip_archive.sh.
# Provides: log(), load_temp_dir(), detect_tools(), build_xz_opts()
#
# Expected variables set by caller before sourcing:
#   OPT_VERBOSE   — true/false
#   OPT_CONFIG    — path to transfer.conf
#   OPT_XZ_LEVEL  — 1-9
#   OPT_XZ_EXTREME — true/false
#   OPT_XZ_THREADS — integer
# ============================================================

# ---- Tool flags (set by detect_tools) ----
HAS_PBZIP2=false
HAS_BZIP2=false
HAS_GZIP=false
HAS_UNZIP=false
HAS_7Z=false
HAS_PV=false
HAS_TAR=false

# ============================================================
# log LEVEL MESSAGE
# ============================================================
log() {
    local level="$1"
    local msg="$2"
    if [[ "${level}" == "DEBUG" ]] && [[ "${OPT_VERBOSE:-false}" != true ]]; then
        return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}]  ${msg}" >&2
}

# ============================================================
# load_temp_dir
# Sources OPT_CONFIG to get TEMP_DIR.
# Falls back to mktemp with EXIT trap if not set.
# ============================================================
load_temp_dir() {
    TEMP_DIR=""

    if [[ -f "${OPT_CONFIG:-}" ]]; then
        # shellcheck disable=SC1090
        source "${OPT_CONFIG}" 2>/dev/null || true
        log "DEBUG" "Loaded config: ${OPT_CONFIG}"
    else
        log "WARN" "Config file not found: ${OPT_CONFIG:-<unset>} — will use mktemp"
    fi

    if [[ -z "${TEMP_DIR:-}" ]]; then
        TEMP_DIR=$(mktemp -d -t compress_XXXXXXXXXX)
        log "WARN" "TEMP_DIR not set in config — using mktemp: ${TEMP_DIR}"
        trap 'rm -rf "${TEMP_DIR}"' EXIT
    else
        log "DEBUG" "Using TEMP_DIR from config: ${TEMP_DIR}"
    fi

    mkdir -p "${TEMP_DIR}"
}

# ============================================================
# detect_tools
# Sets HAS_* flags for available tools.
# Exits fatally if xz or tar are missing.
# ============================================================
detect_tools() {
    command -v pbzip2 &>/dev/null && HAS_PBZIP2=true
    command -v bzip2  &>/dev/null && HAS_BZIP2=true
    command -v gzip   &>/dev/null && HAS_GZIP=true
    command -v unzip  &>/dev/null && HAS_UNZIP=true
    command -v 7z     &>/dev/null && HAS_7Z=true
    command -v pv     &>/dev/null && HAS_PV=true
    command -v tar    &>/dev/null && HAS_TAR=true

    if ! command -v xz &>/dev/null; then
        echo "ERROR: xz is required but not found." >&2
        exit 2
    fi

    log "DEBUG" "Tools: pbzip2=${HAS_PBZIP2} bzip2=${HAS_BZIP2} gzip=${HAS_GZIP} unzip=${HAS_UNZIP} 7z=${HAS_7Z} pv=${HAS_PV} tar=${HAS_TAR}"
}

# ============================================================
# build_xz_opts
# Prints xz option string based on OPT_XZ_* vars.
# ============================================================
build_xz_opts() {
    local opts="-${OPT_XZ_LEVEL:-9}"
    [[ "${OPT_XZ_EXTREME:-true}" == true ]] && opts="${opts} --extreme"
    opts="${opts} -z -T ${OPT_XZ_THREADS:-1} -c"
    [[ "${OPT_VERBOSE:-false}" == true ]] && opts="${opts} -v"
    echo "${opts}"
}