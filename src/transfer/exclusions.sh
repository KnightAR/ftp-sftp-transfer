#!/usr/bin/env bash
# ============================================================
# src/transfer/exclusions.sh — File Exclusion Pattern Matching
#
# Manages the optional exclusion list that lets operators skip
# specific filenames or glob patterns during a transfer run.
#
#   EXCLUSION_PATTERNS  — module-level array populated by
#                         load_exclusions(); read by is_excluded().
#
#   load_exclusions()   — reads EXCLUDE_LIST (a plain-text file,
#                         one pattern per line) into EXCLUSION_PATTERNS.
#                         Blank lines and # comments are stripped.
#                         Proceeds silently with an empty pattern set
#                         if EXCLUDE_LIST is unset or the file is absent.
#
#   is_excluded()       — tests a single filename against every pattern
#                         in EXCLUSION_PATTERNS using bash glob matching
#                         (the unquoted RHS of [[ == ]] enables wildcards).
#                         Returns 0 if the file should be skipped,
#                         1 if it should be transferred.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()).
#   EXCLUDE_LIST must be set before load_exclusions() is called;
#   load_config() in src/core/config.sh sets it from the config file
#   or the -e CLI flag.
# ============================================================

# Array of patterns loaded from the exclusion list file.
# Declared here so it is visible to both load_exclusions() and is_excluded().
EXCLUSION_PATTERNS=()

load_exclusions() {
    if [[ -z "${EXCLUDE_LIST:-}" ]] || [[ ! -f "${EXCLUDE_LIST}" ]]; then
        log "WARN" "Exclusion list not found or not set: '${EXCLUDE_LIST:-}' — proceeding without exclusions"
        return 0
    fi

    local count=0
    while IFS= read -r line; do
        # Strip inline comments (everything from # onwards)
        line="${line%%#*}"
        # Strip leading whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        # Strip trailing whitespace
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" ]] && continue
        EXCLUSION_PATTERNS+=("${line}")
        (( count++ )) || true
    done < "${EXCLUDE_LIST}"

    log "INFO" "Loaded ${count} exclusion pattern(s) from: ${EXCLUDE_LIST}"
}

is_excluded() {
    local filename="$1"
    local pattern
    for pattern in "${EXCLUSION_PATTERNS[@]}"; do
        # SC2053: unquoted RHS is intentional — enables glob/wildcard pattern matching
        # shellcheck disable=SC2053
        if [[ "${filename}" == ${pattern} ]]; then
            return 0  # excluded
        fi
    done
    return 1  # not excluded
}