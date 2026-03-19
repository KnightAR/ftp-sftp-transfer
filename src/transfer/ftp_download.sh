#!/usr/bin/env bash
# ============================================================
# src/transfer/ftp_download.sh — FTP Download Worker for zpaq_archive.sh
#
# Downloads one or more files from an FTP source URL into a local
# staging directory, preserving the subpath relative to the source
# root so that zpaq_archive.sh can reconstruct internal names.
#
#   ftp_parse_url URL
#       Parses an ftp://host[:port]/path URL and sets:
#         FTP_DL_HOST   — hostname
#         FTP_DL_PORT   — port (default 21)
#         FTP_DL_PATH   — remote path (file or directory)
#       Returns 1 if the URL is not a valid ftp:// URL.
#
#   ftp_download_path HOST PORT REMOTE_PATH USER PASS DEST_DIR [SUBPATH_PREFIX]
#       Downloads REMOTE_PATH from the FTP server into DEST_DIR.
#       If REMOTE_PATH is a directory, downloads all files recursively.
#       If REMOTE_PATH is a single file, downloads that file only.
#       SUBPATH_PREFIX (optional) is prepended to the relative path
#       when constructing the destination subdirectory under DEST_DIR,
#       allowing callers to preserve source-root-relative structure.
#       Sets FTP_DOWNLOADED_FILES (array) to the list of local paths.
#       Returns 0 on success, 1 on error.
#
#   ftp_download_url URL USER PASS DEST_DIR
#       Convenience wrapper: calls ftp_parse_url then ftp_download_path.
#       Sets FTP_DOWNLOADED_FILES (array) to the list of local paths.
#       Returns 0 on success, 1 on error.
#
# Environment / globals consumed:
#   None beyond the function arguments — this module is self-contained
#   so it can be sourced independently of transfer.conf settings.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()).
#   Requires lftp to be installed.
# ============================================================

# Array populated by ftp_download_path / ftp_download_url — readable by callers.
FTP_DOWNLOADED_FILES=()

# Variables set by ftp_parse_url — readable by callers.
FTP_DL_HOST=""
FTP_DL_PORT="21"
FTP_DL_PATH=""

# ---------------------------------------------------------------------------
# ftp_parse_url URL
#
# Parses an ftp://[user:pass@]host[:port]/path URL.
# Sets FTP_DL_HOST, FTP_DL_PORT, FTP_DL_PATH.
# Embedded credentials in the URL are intentionally ignored — callers must
# pass USER and PASS explicitly to avoid leaking them in process listings.
# Returns 0 on success, 1 on parse failure.
# ---------------------------------------------------------------------------
ftp_parse_url() {
    local url="$1"

    FTP_DL_HOST=""
    FTP_DL_PORT="21"
    FTP_DL_PATH=""

    if [[ "${url}" != ftp://* ]]; then
        log "ERROR" "ftp_parse_url: not an ftp:// URL: ${url}"
        return 1
    fi

    # Strip scheme
    local rest="${url#ftp://}"

    # Strip optional user:pass@ prefix
    if [[ "${rest}" == *@* ]]; then
        rest="${rest#*@}"
    fi

    # Split host[:port] from /path
    local hostport="${rest%%/*}"
    FTP_DL_PATH="/${rest#*/}"

    # Split host and optional port
    if [[ "${hostport}" == *:* ]]; then
        FTP_DL_HOST="${hostport%%:*}"
        FTP_DL_PORT="${hostport##*:}"
    else
        FTP_DL_HOST="${hostport}"
        FTP_DL_PORT="21"
    fi

    if [[ -z "${FTP_DL_HOST}" ]]; then
        log "ERROR" "ftp_parse_url: could not extract host from: ${url}"
        return 1
    fi

    log "DEBUG" "ftp_parse_url: host=${FTP_DL_HOST} port=${FTP_DL_PORT} path=${FTP_DL_PATH}"
    return 0
}

# ---------------------------------------------------------------------------
# ftp_download_path HOST PORT REMOTE_PATH USER PASS DEST_DIR [SUBPATH_PREFIX]
#
# Downloads REMOTE_PATH (file or directory tree) from FTP into DEST_DIR.
# Preserves relative structure under DEST_DIR/<SUBPATH_PREFIX>/.
# Populates FTP_DOWNLOADED_FILES array with downloaded local file paths.
# Returns 0 on success, 1 on error.
# ---------------------------------------------------------------------------
ftp_download_path() {
    local host="$1"
    local port="$2"
    local remote_path="$3"
    local user="$4"
    local pass="$5"
    local dest_dir="$6"
    local subpath_prefix="${7:-}"

    FTP_DOWNLOADED_FILES=()

    if ! command -v lftp &>/dev/null; then
        log "ERROR" "ftp_download_path: lftp is required but not found on PATH"
        return 1
    fi

    local connect_str="set ftp:ssl-allow no; set net:timeout 30; set net:max-retries 3;"

    # Determine destination subdirectory
    local target_dir="${dest_dir}"
    if [[ -n "${subpath_prefix}" ]]; then
        target_dir="${dest_dir}/${subpath_prefix}"
    fi
    mkdir -p "${target_dir}"

    log "INFO" "ftp_download_path: downloading ${host}:${port}${remote_path} → ${target_dir}"

    # Use lftp mirror for directories, get for individual files.
    # We probe with 'ls' first to distinguish file vs directory.
    local ls_output rc=0
    ls_output=$(lftp \
        -e "${connect_str} ls ${remote_path}; quit" \
        -u "${user}","${pass}" \
        "${host}:${port}" 2>&1) || rc=$?

    if (( rc != 0 )); then
        log "ERROR" "ftp_download_path: FTP ls failed (rc=${rc}): ${remote_path}"
        log "ERROR" "  lftp output: ${ls_output}"
        return 1
    fi

    # If ls output has only one line and it's a file entry (starts with -)
    # treat it as a single file download; otherwise mirror the directory.
    local line_count
    line_count=$(printf '%s\n' "${ls_output}" | grep -c '^' || true)
    local first_char
    first_char=$(printf '%s\n' "${ls_output}" | head -1 | cut -c1)

    if [[ "${line_count}" -eq 1 && "${first_char}" == "-" ]]; then
        # Single file download
        local filename
        filename=$(basename "${remote_path}")
        local local_file="${target_dir}/${filename}"

        log "DEBUG" "ftp_download_path: single file download → ${local_file}"
        rc=0
        lftp \
            -e "${connect_str} get ${remote_path} -o ${local_file}; quit" \
            -u "${user}","${pass}" \
            "${host}:${port}" 2>&1 | while IFS= read -r line; do
                log "DEBUG" "lftp: ${line}"
            done || rc=$?

        if (( rc != 0 )); then
            log "ERROR" "ftp_download_path: single file get failed (rc=${rc}): ${remote_path}"
            return 1
        fi

        if [[ -f "${local_file}" ]]; then
            FTP_DOWNLOADED_FILES+=("${local_file}")
            log "INFO" "ftp_download_path: downloaded ${local_file}"
        else
            log "ERROR" "ftp_download_path: expected output file not found: ${local_file}"
            return 1
        fi
    else
        # Directory mirror
        log "DEBUG" "ftp_download_path: mirroring directory ${remote_path}"
        rc=0
        lftp \
            -e "${connect_str} mirror ${remote_path} ${target_dir}; quit" \
            -u "${user}","${pass}" \
            "${host}:${port}" 2>&1 | while IFS= read -r line; do
                log "DEBUG" "lftp mirror: ${line}"
            done || rc=$?

        if (( rc != 0 )); then
            log "ERROR" "ftp_download_path: mirror failed (rc=${rc}): ${remote_path}"
            return 1
        fi

        # Collect all downloaded files
        local f
        while IFS= read -r f; do
            FTP_DOWNLOADED_FILES+=("${f}")
        done < <(find "${target_dir}" -type f | sort)

        log "INFO" "ftp_download_path: mirrored ${#FTP_DOWNLOADED_FILES[@]} file(s) to ${target_dir}"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# ftp_download_url URL USER PASS DEST_DIR
#
# Convenience wrapper: parses URL, derives SUBPATH_PREFIX from the remote
# path (everything except the final component becomes the prefix), and
# calls ftp_download_path.
#
# Populates FTP_DOWNLOADED_FILES array.
# Returns 0 on success, 1 on error.
# ---------------------------------------------------------------------------
ftp_download_url() {
    local url="$1"
    local user="$2"
    local pass="$3"
    local dest_dir="$4"

    if ! ftp_parse_url "${url}"; then
        return 1
    fi

    # Derive subpath prefix: dirname of the remote path, stripped of leading /
    local subpath_prefix=""
    local remote_dir
    remote_dir=$(dirname "${FTP_DL_PATH}")
    if [[ "${remote_dir}" != "/" && "${remote_dir}" != "." ]]; then
        subpath_prefix="${remote_dir#/}"
    fi

    ftp_download_path \
        "${FTP_DL_HOST}" \
        "${FTP_DL_PORT}" \
        "${FTP_DL_PATH}" \
        "${user}" \
        "${pass}" \
        "${dest_dir}" \
        "${subpath_prefix}"
}