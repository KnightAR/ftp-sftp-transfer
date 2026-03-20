#!/usr/bin/env bash
# ============================================================
# src/zpaq/zpaq_archive_ops.sh — Archive Format Detection & zpaqfranz Add Loop
#
# Handles the per-file processing pipeline used by zpaq_archive.sh:
#
#   detect_archive_format FILEPATH
#       Sets ARCHIVE_FORMAT to one of:
#           gz bz2 xz zst tar_gz tar_bz2 tar_xz tar_zst zip 7z plain
#       Returns 1 if the file does not exist or cannot be identified.
#       Always called outside $(...) — uses log().
#
#   decompress_to_stdout FILEPATH FORMAT
#       Streams the decompressed content of FILEPATH to stdout.
#       For plain files the raw bytes are passed through unchanged.
#       For container formats (zip, 7z) with multiple members, each
#       member is extracted to a temp file and callers must use
#       zpaq_add_local_file() instead — see zpaq_add_container().
#       Returns 0 on success, 1 on error.
#
#   zpaq_add_stdin ARCHIVE INTERNAL_NAME
#       Reads from stdin and adds the content to ARCHIVE as INTERNAL_NAME
#       using zpaqfranz a ... -stdin.  Returns 0 on success, 1 on error.
#       MUST NOT be called from inside $(...) — uses log().
#
#   zpaq_add_local_file ARCHIVE INTERNAL_NAME LOCAL_FILE
#       Adds LOCAL_FILE to ARCHIVE as INTERNAL_NAME by piping through
#       zpaqfranz a ... -stdin.  Returns 0 on success, 1 on error.
#
#   zpaq_add_container ARCHIVE INTERNAL_PREFIX FILEPATH FORMAT TEMP_DIR
#       Extracts a multi-member container (zip, 7z) to TEMP_DIR/members/,
#       then calls zpaq_add_local_file for each extracted member, preserving
#       relative member paths under INTERNAL_PREFIX.
#       Returns 0 when all members succeed, 1 on any error.
#
#   zpaq_add_source ARCHIVE INTERNAL_PREFIX FILEPATH
#       Top-level dispatcher: detects format, decides whether to use
#       decompress_to_stdout+zpaq_add_stdin (simple compressed files) or
#       zpaq_add_container (multi-member containers), and calls zpaq_file_exists
#       to skip already-archived files.
#       Returns 0 on success (including already-exists skip), 1 on error.
#
# zpaqfranz add invocation used throughout:
#   zpaqfranz a <archive> <internal_name> -stdin -m5 -ssd -threads N
#
# Thread count N is read from ZPAQFRANZ_THREADS (set by zpaq_calc_threads()
# in zpaq_utils.sh). Default: 25% of nproc, minimum 1, maximum 8.
#
# Dependency order:
#   Must be sourced after:
#     src/core/logging.sh      (uses log())
#     src/zpaq/zpaq_utils.sh   (uses ZPAQFRANZ_BIN, zpaq_file_exists())
# ============================================================

# ARCHIVE_FORMAT is set by detect_archive_format() — readable by callers.
ARCHIVE_FORMAT=""

# ---------------------------------------------------------------------------
# detect_archive_format FILEPATH
#
# Identifies the compression/archive format of FILEPATH by reading its magic
# bytes via the `file` command (not just the extension) and sets ARCHIVE_FORMAT.
#
# Supported values of ARCHIVE_FORMAT:
#   gz       — gzip-compressed, no tar wrapper
#   bz2      — bzip2-compressed, no tar wrapper
#   xz       — xz-compressed, no tar wrapper
#   zst      — zstd-compressed, no tar wrapper
#   tar_gz   — gzip-compressed tar archive
#   tar_bz2  — bzip2-compressed tar archive
#   tar_xz   — xz-compressed tar archive
#   tar_zst  — zstd-compressed tar archive
#   tar      — uncompressed tar archive
#   zip      — ZIP archive (may contain multiple members)
#   7z       — 7-Zip archive (may contain multiple members)
#   plain    — no recognised compression/archive format (raw file)
#
# Returns 0 on success, 1 if the file is missing.
# ---------------------------------------------------------------------------
detect_archive_format() {
    local filepath="$1"
    ARCHIVE_FORMAT=""

    if [[ ! -f "${filepath}" ]]; then
        log "ERROR" "detect_archive_format: file not found: ${filepath}"
        return 1
    fi

    local file_output
    file_output=$(file -b "${filepath}" 2>/dev/null)

    case "${file_output}" in
        *"POSIX tar archive"*|*"GNU tar archive"*|*"tar archive"*)
            ARCHIVE_FORMAT="tar" ;;
        *"gzip compressed"*"tar data"*|*"gzip compressed"*" (tar)")
            ARCHIVE_FORMAT="tar_gz" ;;
        *"bzip2 compressed"*"tar data"*|*"bzip2 compressed"*" (tar)")
            ARCHIVE_FORMAT="tar_bz2" ;;
        *"XZ compressed"*"tar"*|*"xz compressed"*"tar"*)
            ARCHIVE_FORMAT="tar_xz" ;;
        *"Zstandard compressed"*"tar"*)
            ARCHIVE_FORMAT="tar_zst" ;;
        *"gzip compressed"*)
            ARCHIVE_FORMAT="gz" ;;
        *"bzip2 compressed"*)
            ARCHIVE_FORMAT="bz2" ;;
        *"XZ compressed"*)
            ARCHIVE_FORMAT="xz" ;;
        *"Zstandard compressed"*)
            ARCHIVE_FORMAT="zst" ;;
        *"Zip archive"*|*"ZIP archive"*)
            ARCHIVE_FORMAT="zip" ;;
        *"7-zip archive"*|*"7z archive"*)
            ARCHIVE_FORMAT="7z" ;;
        *)
            # Fall back to extension as a secondary heuristic
            case "${filepath,,}" in
                *.tar.gz|*.tgz)   ARCHIVE_FORMAT="tar_gz"  ;;
                *.tar.bz2|*.tbz2) ARCHIVE_FORMAT="tar_bz2" ;;
                *.tar.xz|*.txz)   ARCHIVE_FORMAT="tar_xz"  ;;
                *.tar.zst)        ARCHIVE_FORMAT="tar_zst"  ;;
                *.tar)            ARCHIVE_FORMAT="tar"      ;;
                *.gz)             ARCHIVE_FORMAT="gz"       ;;
                *.bz2)            ARCHIVE_FORMAT="bz2"      ;;
                *.xz)             ARCHIVE_FORMAT="xz"       ;;
                *.zst)            ARCHIVE_FORMAT="zst"      ;;
                *.zip)            ARCHIVE_FORMAT="zip"      ;;
                *.7z)             ARCHIVE_FORMAT="7z"       ;;
                *)                ARCHIVE_FORMAT="plain"    ;;
            esac
            ;;
    esac

    log "DEBUG" "detect_archive_format: ${filepath} → ${ARCHIVE_FORMAT} (file: ${file_output})"
    return 0
}

# ---------------------------------------------------------------------------
# decompress_to_stdout FILEPATH FORMAT
#
# Streams the decompressed content of FILEPATH to stdout.
# For FORMAT=plain, passes the raw bytes through unchanged (cat).
# For tar/zip/7z multi-member containers this function is NOT appropriate —
# use zpaq_add_container() instead.
#
# Returns 0 on success, 1 on error.
# ---------------------------------------------------------------------------
decompress_to_stdout() {
    local filepath="$1"
    local format="$2"

    case "${format}" in
        gz)
            gzip  -dc "${filepath}"  ;;
        bz2)
            bzip2 -dc "${filepath}"  ;;
        xz)
            xz    -dc "${filepath}"  ;;
        zst)
            zstd  -dc "${filepath}"  ;;
        tar|tar_gz|tar_bz2|tar_xz|tar_zst|zip|7z)
            # Multi-member containers: caller must use zpaq_add_container()
            log "ERROR" "decompress_to_stdout: format '${format}' is a container — use zpaq_add_container()"
            return 1
            ;;
        plain|*)
            cat "${filepath}" ;;
    esac
    return "${PIPESTATUS[0]:-$?}"
}

# ---------------------------------------------------------------------------
# zpaq_add_stdin ARCHIVE INTERNAL_NAME
#
# Reads from stdin and adds it to ARCHIVE as INTERNAL_NAME.
# Uses: zpaqfranz a <archive> <internal_name> -stdin -m5 -ssd -threads N
#
# -m5         compression level 5 (balanced)
# -ssd        SSD-optimised I/O scheduler
# -threads N  thread count from ZPAQFRANZ_THREADS (set by zpaq_calc_threads())
#
# Returns 0 on success, 1 on error.
# MUST NOT be called from inside $(...) — uses log().
# ---------------------------------------------------------------------------
zpaq_add_stdin() {
    local archive="$1"
    local internal_name="$2"

    # Use ZPAQFRANZ_THREADS if set; fall back to 1 if not yet initialised
    local threads="${ZPAQFRANZ_THREADS:-1}"

    log "INFO" "zpaq_add_stdin: adding '${internal_name}' → ${archive} (threads=${threads})"

    # zpaqfranz writes progress to stderr (terminal) and may write to stdout.
    # Stdout is tee'd to LOG_FILE so it appears in the log and on the terminal.
    # Stderr goes directly to the terminal for live progress display.
    # PIPESTATUS[0] captures zpaqfranz's exit code across the tee pipe.
    local rc=0
    "${ZPAQFRANZ_BIN}" a "${archive}" "${internal_name}" \
        -stdin -m5 -ssd -threads "${threads}" \
        | tee -a "${LOG_FILE:-/dev/null}"
    rc="${PIPESTATUS[0]}"

    if (( rc != 0 )); then
        log "ERROR" "zpaq_add_stdin: zpaqfranz a failed (rc=${rc}) for '${internal_name}'"
        return 1
    fi

    log "INFO" "zpaq_add_stdin: OK '${internal_name}'"
    return 0
}

# ---------------------------------------------------------------------------
# zpaq_add_local_file ARCHIVE INTERNAL_NAME LOCAL_FILE
#
# Adds LOCAL_FILE to ARCHIVE as INTERNAL_NAME by piping its content through
# zpaqfranz a ... -stdin.
#
# Returns 0 on success, 1 on error.
# ---------------------------------------------------------------------------
zpaq_add_local_file() {
    local archive="$1"
    local internal_name="$2"
    local local_file="$3"

    if [[ ! -f "${local_file}" ]]; then
        log "ERROR" "zpaq_add_local_file: source not found: ${local_file}"
        return 1
    fi

    log "DEBUG" "zpaq_add_local_file: piping '${local_file}' as '${internal_name}'"
    cat "${local_file}" | zpaq_add_stdin "${archive}" "${internal_name}"
}

# ---------------------------------------------------------------------------
# zpaq_add_container ARCHIVE INTERNAL_PREFIX FILEPATH FORMAT TEMP_DIR
#
# Extracts a multi-member container (tar, tar_gz, tar_bz2, tar_xz, tar_zst,
# zip, 7z) to TEMP_DIR/members/, then calls zpaq_add_local_file for each
# extracted member, preserving relative paths under INTERNAL_PREFIX.
#
# Already-archived members (checked via zpaq_file_exists) are skipped.
#
# Returns 0 when all members succeed, 1 on any error.
# ---------------------------------------------------------------------------
zpaq_add_container() {
    local archive="$1"
    local internal_prefix="$2"
    local filepath="$3"
    local format="$4"
    local temp_dir="$5"

    local extract_dir="${temp_dir}/members"
    mkdir -p "${extract_dir}"

    log "INFO" "zpaq_add_container: extracting '${filepath}' (${format}) to ${extract_dir}"

    # Extract depending on format
    local rc=0
    case "${format}" in
        tar)
            tar -xf  "${filepath}" -C "${extract_dir}" || rc=$? ;;
        tar_gz)
            tar -xzf "${filepath}" -C "${extract_dir}" || rc=$? ;;
        tar_bz2)
            tar -xjf "${filepath}" -C "${extract_dir}" || rc=$? ;;
        tar_xz)
            tar -xJf "${filepath}" -C "${extract_dir}" || rc=$? ;;
        tar_zst)
            tar --use-compress-program=zstd -xf "${filepath}" -C "${extract_dir}" || rc=$? ;;
        zip)
            if ! command -v unzip &>/dev/null; then
                log "ERROR" "zpaq_add_container: unzip is required for ZIP files but not found"
                return 1
            fi
            unzip -q "${filepath}" -d "${extract_dir}" || rc=$? ;;
        7z)
            if ! command -v 7z &>/dev/null && ! command -v 7za &>/dev/null; then
                log "ERROR" "zpaq_add_container: 7z/7za is required for 7-Zip files but not found"
                return 1
            fi
            local sevenz_bin
            sevenz_bin=$(command -v 7z 2>/dev/null || command -v 7za 2>/dev/null)
            "${sevenz_bin}" x "${filepath}" -o"${extract_dir}" -y >/dev/null || rc=$? ;;
        *)
            log "ERROR" "zpaq_add_container: unsupported container format '${format}'"
            return 1 ;;
    esac

    if (( rc != 0 )); then
        log "ERROR" "zpaq_add_container: extraction failed (rc=${rc}): ${filepath}"
        return 1
    fi

    # Walk the extracted members and add each to the zpaq archive
    local member_path internal_name overall_rc=0
    while IFS= read -r member_path; do
        # member_path is absolute; make it relative to extract_dir
        local rel_path="${member_path#"${extract_dir}"/}"

        if [[ -n "${internal_prefix}" ]]; then
            internal_name="${internal_prefix}/${rel_path}"
        else
            internal_name="${rel_path}"
        fi

        # Skip already-archived members
        if zpaq_file_exists "${archive}" "${internal_name}"; then
            log "INFO" "zpaq_add_container: already in archive, skipping: ${internal_name}"
            continue
        fi

        if ! zpaq_add_local_file "${archive}" "${internal_name}" "${member_path}"; then
            log "ERROR" "zpaq_add_container: failed to add member: ${internal_name}"
            overall_rc=1
        fi
    done < <(find "${extract_dir}" -type f | sort)

    return "${overall_rc}"
}

# ---------------------------------------------------------------------------
# zpaq_add_source ARCHIVE INTERNAL_PREFIX FILEPATH
#
# Top-level dispatcher called by zpaq_archive.sh for each staged/downloaded
# file. Workflow:
#
#   1. detect_archive_format
#   2. For container formats  → zpaq_add_container
#      For plain/compressed   → decompress_to_stdout | zpaq_add_stdin
#      (checking zpaq_file_exists for plain/compressed single files first)
#
# INTERNAL_PREFIX is the subpath prefix derived from the source URL/path
# (e.g. "slim" when the source root is ftp://host/slim/).
#
# Returns 0 on success (including skip), 1 on error.
# ---------------------------------------------------------------------------
zpaq_add_source() {
    local archive="$1"
    local internal_prefix="$2"
    local filepath="$3"
    local temp_dir="${4:-/tmp}"

    local basename_file
    basename_file=$(basename "${filepath}")

    # Build the internal name: strip compression extension for single-file
    # compressed sources so the stored name is human-readable.
    local stripped_name
    case "${basename_file,,}" in
        *.tar.gz|*.tgz)    stripped_name="${basename_file%.*}"   ;;  # keep .tar
        *.tar.bz2|*.tbz2)  stripped_name="${basename_file%.*}"   ;;
        *.tar.xz|*.txz)    stripped_name="${basename_file%.*}"   ;;
        *.tar.zst)         stripped_name="${basename_file%.*}"   ;;
        *.gz)              stripped_name="${basename_file%.gz}"  ;;
        *.bz2)             stripped_name="${basename_file%.bz2}" ;;
        *.xz)              stripped_name="${basename_file%.xz}"  ;;
        *.zst)             stripped_name="${basename_file%.zst}" ;;
        *)                 stripped_name="${basename_file}"      ;;
    esac

    local internal_name
    if [[ -n "${internal_prefix}" ]]; then
        internal_name="${internal_prefix}/${stripped_name}"
    else
        internal_name="${stripped_name}"
    fi

    if ! detect_archive_format "${filepath}"; then
        log "ERROR" "zpaq_add_source: could not detect format of: ${filepath}"
        return 1
    fi

    case "${ARCHIVE_FORMAT}" in
        tar|tar_gz|tar_bz2|tar_xz|tar_zst|zip|7z)
            # Multi-member container: extract and add members individually
            zpaq_add_container "${archive}" "${internal_prefix}" \
                               "${filepath}" "${ARCHIVE_FORMAT}" "${temp_dir}"
            ;;
        gz|bz2|xz|zst)
            # Single compressed file: check existence, then decompress → add
            if zpaq_file_exists "${archive}" "${internal_name}"; then
                log "INFO" "zpaq_add_source: already in archive, skipping: ${internal_name}"
                return 0
            fi
            decompress_to_stdout "${filepath}" "${ARCHIVE_FORMAT}" \
                | zpaq_add_stdin "${archive}" "${internal_name}"
            ;;
        plain|*)
            # Raw file: check existence, then pipe directly
            if zpaq_file_exists "${archive}" "${internal_name}"; then
                log "INFO" "zpaq_add_source: already in archive, skipping: ${internal_name}"
                return 0
            fi
            zpaq_add_local_file "${archive}" "${internal_name}" "${filepath}"
            ;;
    esac
}