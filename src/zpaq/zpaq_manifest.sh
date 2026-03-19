#!/usr/bin/env bash
# ============================================================
# src/zpaq/zpaq_manifest.sh — .zpaq Manifest File Management
#
# A manifest is a small text file co-located with each .zpaq archive
# (locally and on the SFTP server). It records the sha256, byte size,
# and timestamp of the last successfully uploaded version, enabling
# storezpaq.sh to:
#
#   - Skip upload when nothing has changed (no-op detection)
#   - Detect when the remote file was modified outside storezpaq.sh
#   - Name timestamped backups after the upload date stored in the
#     manifest rather than "now" (preserves provenance)
#
# Manifest format (plain text, one key=value per line):
#
#   # zpaq manifest — managed by storezpaq.sh — do not edit manually
#   zpaq_file=backup.zpaq
#   sha256=<hex>
#   size=<bytes>
#   uploaded=<YYYYMMDDHHMMSS>
#
# Functions:
#
#   manifest_path ZPAQ_FILE        — echoes the expected local manifest
#                                    path for a given .zpaq file path.
#
#   manifest_write ZPAQ_FILE SHA256 SIZE UPLOADED
#                                  — writes a manifest file next to
#                                    ZPAQ_FILE with the given fields.
#
#   manifest_read  MANIFEST_FILE   — sources a manifest into variables
#                                    MANIFEST_SHA256, MANIFEST_SIZE,
#                                    MANIFEST_UPLOADED, MANIFEST_ZPAQ_FILE.
#                                    Returns 1 if file not found.
#
#   manifest_compute ZPAQ_FILE     — computes sha256 + size of ZPAQ_FILE
#                                    into COMPUTED_SHA256 and COMPUTED_SIZE.
#                                    Returns 1 on failure.
#
#   manifest_changed ZPAQ_FILE     — returns 0 if the archive has changed
#                                    since the local manifest was written
#                                    (or if no local manifest exists).
#                                    Returns 1 if nothing has changed.
#
#   manifest_remote_diverged LOCAL_MANIFEST REMOTE_MANIFEST
#                                  — returns 0 if the remote manifest
#                                    differs from the local manifest
#                                    (indicating external modification).
#                                    Returns 1 if they match (or remote
#                                    does not exist — first run).
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()).
# ============================================================

# Computed values set by manifest_compute() — readable by callers.
COMPUTED_SHA256=""
COMPUTED_SIZE=""

# Values populated by manifest_read() — readable by callers.
MANIFEST_ZPAQ_FILE=""
MANIFEST_SHA256=""
MANIFEST_SIZE=""
MANIFEST_UPLOADED=""

# manifest_path ZPAQ_FILE
#
# Echoes the manifest file path for a given .zpaq file.
# Convention: <archive>.manifest in the same directory.
#
# Example:
#   path=$(manifest_path "/backups/db.zpaq")
#   # → /backups/db.manifest
manifest_path() {
    local zpaq_file="$1"
    local dir base
    dir=$(dirname "${zpaq_file}")
    base=$(basename "${zpaq_file}" .zpaq)
    echo "${dir}/${base}.manifest"
}

# manifest_write ZPAQ_FILE SHA256 SIZE UPLOADED
#
# Writes a manifest file next to ZPAQ_FILE.
# UPLOADED must be in YYYYMMDDHHMMSS format.
# Overwrites any existing manifest atomically via a temp file + mv.
manifest_write() {
    local zpaq_file="$1"
    local sha256="$2"
    local size="$3"
    local uploaded="$4"

    local mpath
    mpath=$(manifest_path "${zpaq_file}")

    local base
    base=$(basename "${zpaq_file}")

    local tmp_mpath="${mpath}.tmp$$"

    cat > "${tmp_mpath}" <<EOF
# zpaq manifest — managed by storezpaq.sh — do not edit manually
zpaq_file=${base}
sha256=${sha256}
size=${size}
uploaded=${uploaded}
EOF

    mv "${tmp_mpath}" "${mpath}"
    log "DEBUG" "manifest_write: wrote ${mpath} (sha256=${sha256} size=${size} uploaded=${uploaded})"
}

# manifest_read MANIFEST_FILE
#
# Reads a manifest file and populates the MANIFEST_* variables.
# Returns 0 on success, 1 if the file does not exist or is unreadable.
#
# After a successful call:
#   MANIFEST_ZPAQ_FILE  — value of zpaq_file= field
#   MANIFEST_SHA256     — value of sha256= field
#   MANIFEST_SIZE       — value of size= field
#   MANIFEST_UPLOADED   — value of uploaded= field (YYYYMMDDHHMMSS)
manifest_read() {
    local manifest_file="$1"

    # Reset output variables
    MANIFEST_ZPAQ_FILE=""
    MANIFEST_SHA256=""
    MANIFEST_SIZE=""
    MANIFEST_UPLOADED=""

    if [[ ! -f "${manifest_file}" ]]; then
        log "DEBUG" "manifest_read: not found: ${manifest_file}"
        return 1
    fi

    local key val line
    while IFS= read -r line; do
        # Skip comment lines and blank lines
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        key="${line%%=*}"
        val="${line#*=}"

        # shellcheck disable=SC2034  # MANIFEST_ZPAQ_FILE is read by callers after manifest_read()
        case "${key}" in
            zpaq_file) MANIFEST_ZPAQ_FILE="${val}" ;;
            sha256)    MANIFEST_SHA256="${val}"     ;;
            size)      MANIFEST_SIZE="${val}"       ;;
            uploaded)  MANIFEST_UPLOADED="${val}"   ;;
        esac
    done < "${manifest_file}"

    if [[ -z "${MANIFEST_SHA256}" ]] || [[ -z "${MANIFEST_SIZE}" ]]; then
        log "WARN" "manifest_read: manifest missing required fields: ${manifest_file}"
        return 1
    fi

    log "DEBUG" "manifest_read: ${manifest_file} sha256=${MANIFEST_SHA256} size=${MANIFEST_SIZE} uploaded=${MANIFEST_UPLOADED}"
    return 0
}

# manifest_compute ZPAQ_FILE
#
# Computes sha256 and byte size of ZPAQ_FILE.
# Sets COMPUTED_SHA256 and COMPUTED_SIZE.
# Returns 0 on success, 1 on failure.
manifest_compute() {
    local zpaq_file="$1"

    COMPUTED_SHA256=""
    COMPUTED_SIZE=""

    if [[ ! -f "${zpaq_file}" ]]; then
        log "ERROR" "manifest_compute: file not found: ${zpaq_file}"
        return 1
    fi

    local hash_line
    hash_line=$(sha256sum "${zpaq_file}" 2>/dev/null) || {
        log "ERROR" "manifest_compute: sha256sum failed: ${zpaq_file}"
        return 1
    }
    COMPUTED_SHA256="${hash_line%% *}"

    COMPUTED_SIZE=$(wc -c < "${zpaq_file}" 2>/dev/null) || {
        log "ERROR" "manifest_compute: wc -c failed: ${zpaq_file}"
        return 1
    }
    # Trim whitespace that wc -c may add
    COMPUTED_SIZE="${COMPUTED_SIZE// /}"

    log "DEBUG" "manifest_compute: ${zpaq_file} sha256=${COMPUTED_SHA256} size=${COMPUTED_SIZE}"
    return 0
}

# manifest_changed ZPAQ_FILE
#
# Returns 0 (true) if the archive has changed since the local manifest
# was last written — i.e., upload is needed.
# Returns 1 (false) if the archive matches the local manifest exactly.
#
# A missing local manifest is treated as "changed" (first run).
manifest_changed() {
    local zpaq_file="$1"

    local mpath
    mpath=$(manifest_path "${zpaq_file}")

    # No local manifest → treat as changed (first run)
    if ! manifest_read "${mpath}"; then
        log "DEBUG" "manifest_changed: no local manifest → changed"
        return 0
    fi

    local saved_sha256="${MANIFEST_SHA256}"
    local saved_size="${MANIFEST_SIZE}"

    if ! manifest_compute "${zpaq_file}"; then
        log "ERROR" "manifest_changed: failed to compute current hash of ${zpaq_file}"
        return 0   # Treat as changed so upload is attempted
    fi

    if [[ "${COMPUTED_SHA256}" == "${saved_sha256}" ]] \
    && [[ "${COMPUTED_SIZE}"   == "${saved_size}"   ]]; then
        log "DEBUG" "manifest_changed: archive unchanged (sha256=${COMPUTED_SHA256})"
        return 1   # Not changed
    fi

    log "DEBUG" "manifest_changed: archive changed (was sha256=${saved_sha256} size=${saved_size}, now sha256=${COMPUTED_SHA256} size=${COMPUTED_SIZE})"
    return 0   # Changed
}

# manifest_remote_diverged LOCAL_MANIFEST REMOTE_MANIFEST
#
# Compares the sha256 and size fields of two manifest files.
# Returns 0 (true) if the remote manifest differs from the local one —
# indicating the remote .zpaq was modified outside storezpaq.sh.
# Returns 1 (false) if they match, or if the remote manifest does not
# exist (first-run case — no divergence, just no prior upload).
#
# Callers should check for the remote-does-not-exist case separately
# by testing whether the remote manifest file was successfully downloaded
# before calling this function.
manifest_remote_diverged() {
    local local_manifest="$1"
    local remote_manifest="$2"

    # Remote does not exist → first run, not a divergence
    if [[ ! -f "${remote_manifest}" ]]; then
        log "DEBUG" "manifest_remote_diverged: no remote manifest → first run"
        return 1
    fi

    # Read local manifest
    local local_sha256 local_size local_uploaded
    if ! manifest_read "${local_manifest}"; then
        # No local manifest → cannot compare → not diverged (first run locally)
        log "DEBUG" "manifest_remote_diverged: no local manifest → not diverged"
        return 1
    fi
    local_sha256="${MANIFEST_SHA256}"
    local_size="${MANIFEST_SIZE}"
    local_uploaded="${MANIFEST_UPLOADED}"

    # Read remote manifest into separate variables
    local remote_sha256 remote_size
    if ! manifest_read "${remote_manifest}"; then
        log "WARN" "manifest_remote_diverged: could not parse remote manifest: ${remote_manifest}"
        return 1
    fi
    remote_sha256="${MANIFEST_SHA256}"
    remote_size="${MANIFEST_SIZE}"

    # Restore local values that manifest_read overwrote
    MANIFEST_SHA256="${local_sha256}"
    MANIFEST_SIZE="${local_size}"
    MANIFEST_UPLOADED="${local_uploaded}"

    if [[ "${remote_sha256}" == "${local_sha256}" ]] \
    && [[ "${remote_size}"   == "${local_size}"   ]]; then
        log "DEBUG" "manifest_remote_diverged: manifests match — no divergence"
        return 1   # Not diverged
    fi

    log "DEBUG" "manifest_remote_diverged: remote sha256=${remote_sha256} size=${remote_size} differs from local sha256=${local_sha256} size=${local_size}"
    return 0   # Diverged
}