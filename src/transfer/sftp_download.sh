#!/usr/bin/env bash
# ============================================================
# src/transfer/sftp_download.sh — SFTP Download Worker for zpaq_archive.sh
#
# Downloads one or more files from an SFTP source URL into a local
# staging directory, preserving the subpath relative to the source
# root so that zpaq_archive.sh can reconstruct internal names.
#
#   sftp_dl_parse_url URL
#       Parses an sftp://host[:port]/path URL and sets:
#         SFTP_DL_HOST   — hostname
#         SFTP_DL_PORT   — port (default 22)
#         SFTP_DL_PATH   — remote path (file or directory)
#       Returns 1 if the URL is not a valid sftp:// URL.
#
#   sftp_download_path HOST PORT REMOTE_PATH USER PASS DEST_DIR [SUBPATH_PREFIX]
#       Downloads REMOTE_PATH from the SFTP server into DEST_DIR.
#       If REMOTE_PATH is a directory, downloads all files recursively
#       by listing and fetching each file individually (SFTP has no
#       native recursive get; we avoid introducing rsync/scp).
#       SUBPATH_PREFIX (optional) is prepended to the relative path
#       when constructing the destination subdirectory under DEST_DIR.
#       Sets SFTP_DOWNLOADED_FILES (array) to the list of local paths.
#       Returns 0 on success, 1 on error.
#
#   sftp_download_url URL USER PASS DEST_DIR
#       Convenience wrapper: calls sftp_dl_parse_url then sftp_download_path.
#       Sets SFTP_DOWNLOADED_FILES (array) to the list of local paths.
#       Returns 0 on success, 1 on error.
#
# Environment / globals consumed:
#   None beyond the function arguments — this module is self-contained
#   so it can be sourced independently of transfer.conf settings.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()).
#   Requires sshpass to be installed.
# ============================================================

# Array populated by sftp_download_path / sftp_download_url — readable by callers.
SFTP_DOWNLOADED_FILES=()

# Variables set by sftp_dl_parse_url — readable by callers.
SFTP_DL_HOST=""
SFTP_DL_PORT="22"
SFTP_DL_PATH=""

# ---------------------------------------------------------------------------
# _sftp_dl_run HOST PORT USER PASS BATCH_CMDS
#
# Internal helper: runs sshpass+sftp in batch mode.
# Returns the sftp exit code.
# Stdout is passed through (callers capture it when needed).
# ---------------------------------------------------------------------------
_sftp_dl_run() {
    local host="$1"
    local port="$2"
    local user="$3"
    local pass="$4"
    local batch_cmds="$5"

    SSHPASS="${pass}" sshpass -e sftp \
        -o StrictHostKeyChecking=no \
        -o BatchMode=no \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -P "${port}" \
        "${user}@${host}" \
        -b <(printf '%s\n' "${batch_cmds}") \
        2>/dev/null
}

# ---------------------------------------------------------------------------
# sftp_dl_parse_url URL
#
# Parses an sftp://[user:pass@]host[:port]/path URL.
# Sets SFTP_DL_HOST, SFTP_DL_PORT, SFTP_DL_PATH.
# Embedded credentials in the URL are intentionally ignored — callers must
# pass USER and PASS explicitly to avoid leaking them in process listings.
# Returns 0 on success, 1 on parse failure.
# ---------------------------------------------------------------------------
sftp_dl_parse_url() {
    local url="$1"

    SFTP_DL_HOST=""
    SFTP_DL_PORT="22"
    SFTP_DL_PATH=""

    if [[ "${url}" != sftp://* ]]; then
        log "ERROR" "sftp_dl_parse_url: not an sftp:// URL: ${url}"
        return 1
    fi

    # Strip scheme
    local rest="${url#sftp://}"

    # Strip optional user:pass@ prefix
    if [[ "${rest}" == *@* ]]; then
        rest="${rest#*@}"
    fi

    # Split host[:port] from /path
    local hostport="${rest%%/*}"
    SFTP_DL_PATH="/${rest#*/}"

    # Split host and optional port
    if [[ "${hostport}" == *:* ]]; then
        SFTP_DL_HOST="${hostport%%:*}"
        SFTP_DL_PORT="${hostport##*:}"
    else
        SFTP_DL_HOST="${hostport}"
        SFTP_DL_PORT="22"
    fi

    if [[ -z "${SFTP_DL_HOST}" ]]; then
        log "ERROR" "sftp_dl_parse_url: could not extract host from: ${url}"
        return 1
    fi

    log "DEBUG" "sftp_dl_parse_url: host=${SFTP_DL_HOST} port=${SFTP_DL_PORT} path=${SFTP_DL_PATH}"
    return 0
}

# ---------------------------------------------------------------------------
# _sftp_dl_list_recursive HOST PORT USER PASS REMOTE_DIR
#
# Lists all files under REMOTE_DIR on the SFTP server recursively.
# Echoes one remote file path per line (absolute paths).
# Uses a BFS queue implemented with a bash array — avoids subshells.
# ---------------------------------------------------------------------------
_sftp_dl_list_recursive() {
    local host="$1"
    local port="$2"
    local user="$3"
    local pass="$4"
    local remote_dir="$5"

    # BFS queue of directories to explore
    local -a queue=("${remote_dir}")
    local current

    while (( ${#queue[@]} > 0 )); do
        current="${queue[0]}"
        queue=("${queue[@]:1}")

        # List current directory; capture output
        local listing rc=0
        listing=$(_sftp_dl_run "${host}" "${port}" "${user}" "${pass}" \
                    "ls -l ${current}") || rc=$?

        if (( rc != 0 )); then
            log "WARN" "_sftp_dl_list_recursive: ls failed for ${current} (rc=${rc})"
            continue
        fi

        # Parse ls -l output: lines starting with - are files, d are dirs
        local line
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            local type="${line:0:1}"
            local name
            name=$(printf '%s' "${line}" | awk '{print $NF}')
            [[ -z "${name}" || "${name}" == "." || "${name}" == ".." ]] && continue

            # Build full remote path
            local full_path
            if [[ "${current}" == */ ]]; then
                full_path="${current}${name}"
            else
                full_path="${current}/${name}"
            fi

            if [[ "${type}" == "-" ]]; then
                # Regular file — emit it
                printf '%s\n' "${full_path}"
            elif [[ "${type}" == "d" ]]; then
                # Directory — enqueue for further exploration
                queue+=("${full_path}")
            fi
        done <<< "${listing}"
    done
}

# ---------------------------------------------------------------------------
# sftp_download_path HOST PORT REMOTE_PATH USER PASS DEST_DIR [SUBPATH_PREFIX]
#
# Downloads REMOTE_PATH (file or directory tree) from SFTP into DEST_DIR.
# Populates SFTP_DOWNLOADED_FILES array with downloaded local file paths.
# Returns 0 on success, 1 on any error.
# ---------------------------------------------------------------------------
sftp_download_path() {
    local host="$1"
    local port="$2"
    local remote_path="$3"
    local user="$4"
    local pass="$5"
    local dest_dir="$6"
    local subpath_prefix="${7:-}"

    SFTP_DOWNLOADED_FILES=()

    if ! command -v sshpass &>/dev/null; then
        log "ERROR" "sftp_download_path: sshpass is required but not found on PATH"
        return 1
    fi

    # Determine destination subdirectory
    local target_dir="${dest_dir}"
    if [[ -n "${subpath_prefix}" ]]; then
        target_dir="${dest_dir}/${subpath_prefix}"
    fi
    mkdir -p "${target_dir}"

    log "INFO" "sftp_download_path: ${user}@${host}:${port}${remote_path} → ${target_dir}"

    # Probe whether REMOTE_PATH is a file or a directory
    local ls_output rc=0
    ls_output=$(_sftp_dl_run "${host}" "${port}" "${user}" "${pass}" \
                    "ls -l ${remote_path}") || rc=$?

    if (( rc != 0 )); then
        log "ERROR" "sftp_download_path: ls failed for ${remote_path} (rc=${rc})"
        return 1
    fi

    # Count non-empty lines; first char of first line tells us file vs dir
    local first_char line_count
    first_char=$(printf '%s\n' "${ls_output}" | grep -v '^$' | head -1 | cut -c1)
    line_count=$(printf '%s\n' "${ls_output}" | grep -c '[^[:space:]]' || true)

    if [[ "${first_char}" == "-" && "${line_count}" -eq 1 ]]; then
        # Single file
        local filename
        filename=$(basename "${remote_path}")
        local local_file="${target_dir}/${filename}"

        log "DEBUG" "sftp_download_path: single file get → ${local_file}"
        rc=0
        _sftp_dl_run "${host}" "${port}" "${user}" "${pass}" \
            "get ${remote_path} ${local_file}" || rc=$?

        if (( rc != 0 )) || [[ ! -f "${local_file}" ]]; then
            log "ERROR" "sftp_download_path: get failed (rc=${rc}): ${remote_path}"
            return 1
        fi

        SFTP_DOWNLOADED_FILES+=("${local_file}")
        log "INFO" "sftp_download_path: downloaded ${local_file}"
    else
        # Directory — recursive listing then individual gets
        log "DEBUG" "sftp_download_path: recursive download of directory ${remote_path}"

        local -a remote_files=()
        local f
        while IFS= read -r f; do
            [[ -n "${f}" ]] && remote_files+=("${f}")
        done < <(_sftp_dl_list_recursive "${host}" "${port}" "${user}" "${pass}" "${remote_path}")

        if (( ${#remote_files[@]} == 0 )); then
            log "WARN" "sftp_download_path: no files found under ${remote_path}"
            return 0
        fi

        log "DEBUG" "sftp_download_path: found ${#remote_files[@]} remote file(s)"

        local overall_rc=0
        for f in "${remote_files[@]}"; do
            # Compute relative path from remote_path root
            local rel="${f#"${remote_path}"}"
            rel="${rel#/}"

            local local_dest_file="${target_dir}/${rel}"
            local local_dest_dir
            local_dest_dir=$(dirname "${local_dest_file}")
            mkdir -p "${local_dest_dir}"

            log "DEBUG" "sftp_download_path: get ${f} → ${local_dest_file}"
            rc=0
            _sftp_dl_run "${host}" "${port}" "${user}" "${pass}" \
                "get ${f} ${local_dest_file}" || rc=$?

            if (( rc != 0 )) || [[ ! -f "${local_dest_file}" ]]; then
                log "ERROR" "sftp_download_path: get failed (rc=${rc}): ${f}"
                overall_rc=1
                continue
            fi

            SFTP_DOWNLOADED_FILES+=("${local_dest_file}")
        done

        log "INFO" "sftp_download_path: downloaded ${#SFTP_DOWNLOADED_FILES[@]} file(s) to ${target_dir}"

        if (( overall_rc != 0 )); then
            log "ERROR" "sftp_download_path: one or more files failed to download"
            return 1
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# sftp_download_url URL USER PASS DEST_DIR
#
# Convenience wrapper: parses URL, derives SUBPATH_PREFIX from the remote
# path (everything except the final component becomes the prefix), and
# calls sftp_download_path.
#
# Populates SFTP_DOWNLOADED_FILES array.
# Returns 0 on success, 1 on error.
# ---------------------------------------------------------------------------
sftp_download_url() {
    local url="$1"
    local user="$2"
    local pass="$3"
    local dest_dir="$4"

    if ! sftp_dl_parse_url "${url}"; then
        return 1
    fi

    # Derive subpath prefix: dirname of the remote path, stripped of leading /
    local subpath_prefix=""
    local remote_dir
    remote_dir=$(dirname "${SFTP_DL_PATH}")
    if [[ "${remote_dir}" != "/" && "${remote_dir}" != "." ]]; then
        subpath_prefix="${remote_dir#/}"
    fi

    sftp_download_path \
        "${SFTP_DL_HOST}" \
        "${SFTP_DL_PORT}" \
        "${SFTP_DL_PATH}" \
        "${user}" \
        "${pass}" \
        "${dest_dir}" \
        "${subpath_prefix}"
}