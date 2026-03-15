#!/usr/bin/env bash
# ============================================================
# src/transfer/ftp.sh — FTP Connection & File Listing
#
# Handles all interaction with the source FTP server via lftp.
# Plain FTP only (TLS disabled) — the server does not support FTPS.
#
#   setup_ftp_connection() — assembles FTP_CONNECT_STR (the lftp
#                            settings prefix used by every lftp call)
#                            and performs a connectivity test.  Exits
#                            immediately if the FTP server is unreachable.
#
#   run_lftp()             — thin wrapper that runs a single lftp command
#                            string against the configured FTP server.
#                            All callers use this instead of duplicating
#                            the lftp invocation boilerplate.
#
#   get_ftp_file_list()    — retrieves the full recursive file listing
#                            from FTP_REMOTE_DIR and writes it to
#                            TEMP_DIR/work_queue.txt in the format
#                            expected by download workers:
#                              SIZE EPOCH FILEPATH  (space-separated)
#
#                            Two-pass approach:
#                              Pass 1 — "mirror --dry-run" to get all
#                                       relative file paths recursively.
#                              Pass 2 — "ls <dir>" per unique parent
#                                       directory to get size + mtime,
#                                       because cls --format is not
#                                       supported on this server.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()) and
#   src/core/constants.sh (uses FTP_CONNECT_STR, TEMP_DIR).
#   load_config() must have run so FTP_HOST, FTP_PORT, FTP_USER,
#   FTP_PASS, and FTP_REMOTE_DIR are set.
# ============================================================

setup_ftp_connection() {
    FTP_CONNECT_STR="set ftp:ssl-allow no; set net:timeout 30; set net:max-retries 3;"

    log "INFO" "FTP connection configured — plain FTP (TLS disabled) to ${FTP_HOST}:${FTP_PORT}"

    local test_result
    test_result=$(lftp \
        -e "${FTP_CONNECT_STR} ls; quit" \
        -u "${FTP_USER}","${FTP_PASS}" \
        "${FTP_HOST}:${FTP_PORT}" 2>&1) \
        && local ftp_ok=true || local ftp_ok=false

    if [[ "${ftp_ok}" == true ]]; then
        log "INFO" "FTP connection successful"
    else
        log "ERROR" "FTP connection failed to ${FTP_HOST}:${FTP_PORT}"
        log "ERROR" "lftp output: ${test_result}"
        exit 1
    fi
}

# Run an lftp command against the FTP server.
# Usage: run_lftp <lftp_commands>
# All lftp calls in this script go through this wrapper to avoid
# duplicating the connection string, credentials, and host on every call.
run_lftp() {
    local cmds="$1"
    lftp \
        -e "${FTP_CONNECT_STR} ${cmds}; quit" \
        -u "${FTP_USER}","${FTP_PASS}" \
        "${FTP_HOST}:${FTP_PORT}" 2>&1
}

get_ftp_file_list() {
    log "INFO" "Starting recursive FTP file listing from: ${FTP_REMOTE_DIR}"

    local listing_file="${TEMP_DIR}/ftp_listing.txt"
    local raw_file="${TEMP_DIR}/ftp_mirror_raw.txt"
    local paths_file="${TEMP_DIR}/ftp_paths.txt"
    local dirs_file="${TEMP_DIR}/ftp_dirs.txt"
    local ls_tmp="${TEMP_DIR}/ftp_ls.tmp"

    # ----------------------------------------------------------------
    # Step 1: Get recursive file list via mirror --dry-run
    # Parse "Transferring file `relative/path'" lines → full FTP paths
    # ----------------------------------------------------------------
    log "DEBUG" "Retrieving recursive file listing via mirror --dry-run ..."

    local mirror_output
    mirror_output=$(lftp \
        -e "${FTP_CONNECT_STR} mirror --dry-run --verbose=3 ${FTP_REMOTE_DIR} ${TEMP_DIR}/mirror_dummy; quit" \
        -u "${FTP_USER}","${FTP_PASS}" \
        "${FTP_HOST}:${FTP_PORT}" 2>&1)
    local mirror_exit=$?

    printf '%s\n' "${mirror_output}" > "${raw_file}"

    if (( mirror_exit != 0 )); then
        log "ERROR" "FTP mirror --dry-run failed (exit ${mirror_exit})"
        log "ERROR" "lftp output: ${mirror_output}"
        exit 1
    fi

    # Parse full FTP paths from mirror output
    true > "${paths_file}"
    while IFS= read -r line; do
        if [[ "${line}" =~ ^"Transferring file "\`([^\']*)\' ]]; then
            local relpath="${BASH_REMATCH[1]}"
            if [[ "${FTP_REMOTE_DIR}" == "/" ]]; then
                printf '/%s\n' "${relpath}" >> "${paths_file}"
            else
                printf '%s/%s\n' "${FTP_REMOTE_DIR}" "${relpath}" >> "${paths_file}"
            fi
        fi
    done < "${raw_file}"

    local total_paths
    total_paths=$(wc -l < "${paths_file}")

    if (( total_paths == 0 )); then
        log "WARN" "FTP listing returned 0 files. Nothing to transfer."
        log "DEBUG" "Mirror output sample: $(head -10 "${raw_file}" | tr '\n' '|')"
        true > "${listing_file}"
        cp "${listing_file}" "${TEMP_DIR}/work_queue.txt"
        return 0
    fi

    log "INFO" "Found ${total_paths} file path(s) on FTP. Retrieving file metadata..."

    # ----------------------------------------------------------------
    # Step 2: Get size + mtime via "ls <dir>" per unique directory.
    # cls --format is NOT supported on this server.
    # ls output format: perms links owner group SIZE MON DD TIME/YEAR NAME
    # e.g: -rw-r--r-- 1 100 ftpgroup 52428800 Jan 05 2025 helium_rewards_20250105.sql.bz2
    # run_lftp output is saved to a temp file before parsing (not piped).
    # NOTE: IFS=' ' is set locally on each read call because the global
    #       IFS=$'\n\t' does not split on spaces.
    # ----------------------------------------------------------------
    true > "${listing_file}"

    # Collect unique parent directories from paths_file via dirname.
    true > "${dirs_file}"
    while IFS= read -r ftp_path; do
        [[ -z "${ftp_path}" ]] && continue
        dirname "${ftp_path}"
    done < "${paths_file}" | sort -u >> "${dirs_file}" || true

    local dir_count
    dir_count=$(wc -l < "${dirs_file}")
    log "DEBUG" "Directories to ls (${dir_count}): $(cat "${dirs_file}" | tr '\n' '|')"

    while IFS= read -r dir_path; do
        [[ -z "${dir_path}" ]] && continue

        true > "${ls_tmp}"
        run_lftp "ls ${dir_path}" > "${ls_tmp}" 2>/dev/null || true

        log "DEBUG" "ls ${dir_path} — sample: $(head -10 "${ls_tmp}" | tr '\n' '|')"

        while IFS= read -r ls_line; do
            [[ -z "${ls_line}" ]]    && continue
            [[ "${ls_line}" != -* ]] && continue

            # Parse ls columns: perms links owner group size mon day timeyr name
            # IFS=' ' locally overrides global IFS=$'\n\t' for space-based splitting
            local size mon day timeyr name filepath epoch current_year
            IFS=' ' read -r _ _ _ _ size mon day timeyr name <<< "${ls_line}"

            [[ -z "${name}" ]]   && continue
            [[ -z "${size}" ]]   && continue
            [[ -z "${timeyr}" ]] && continue

            if [[ "${dir_path}" == "/" ]]; then
                filepath="/${name}"
            else
                filepath="${dir_path}/${name}"
            fi

            # Convert ls date to Unix epoch.
            # ls date format has two cases:
            #   YYYY  - file is older than ~6 months; use the year as-is.
            #   HH:MM - file is recent; ls omits the year and shows time instead.
            #           We use the current year as a first guess, but if that
            #           produces a future timestamp (e.g. "Sep 21 14:30" parsed
            #           in March 2026 becomes Sep 21 2026) we subtract one year.
            #           This correctly handles files from the past 12 months
            #           regardless of which month the script is run in.
            current_year=$(date +%Y)
            if [[ "${timeyr}" =~ ^[0-9]{4}$ ]]; then
                epoch=$(date -d "${mon} ${day} ${timeyr} 00:00:00" +%s 2>/dev/null || echo 0)
            else
                epoch=$(date -d "${mon} ${day} ${current_year} ${timeyr}" +%s 2>/dev/null || echo 0)
                # If the resulting epoch is in the future, the month/day has not
                # occurred yet this calendar year -- it belongs to last year.
                local now_epoch
                now_epoch=$(date +%s)
                if (( epoch > now_epoch )); then
                    epoch=$(date -d "${mon} ${day} $(( current_year - 1 )) ${timeyr}" +%s 2>/dev/null || echo 0)
                fi
            fi

            printf '%s %s %s\n' "${size}" "${epoch}" "${filepath}" >> "${listing_file}"

        done < "${ls_tmp}"

        log "DEBUG" "listing_file after ls ${dir_path}: $(wc -l < "${listing_file}") lines, sample: $(head -3 "${listing_file}" | tr '\n' '|')"

    done < "${dirs_file}"

    rm -f "${ls_tmp}"

    # Filter out any malformed lines (size must start with a digit)
    local clean_file="${listing_file}.clean"
    true > "${clean_file}"
    while IFS= read -r line; do
        [[ "${line}" =~ ^[0-9] ]] && printf '%s\n' "${line}" >> "${clean_file}" || true
    done < "${listing_file}"
    mv "${clean_file}" "${listing_file}"

    local final_count
    final_count=$(wc -l < "${listing_file}")

    if (( final_count == 0 )); then
        log "WARN" "File metadata retrieval returned 0 results."
        log "DEBUG" "paths_file sample: $(head -500 "${paths_file}" 2>/dev/null | tr '\n' '|')"
        log "DEBUG" "dirs_file contents: $(cat "${dirs_file}" 2>/dev/null | tr '\n' '|')"
    else
        log "INFO" "FTP metadata retrieved for ${final_count} file(s)"
    fi

    cp "${listing_file}" "${TEMP_DIR}/work_queue.txt"
}