#!/usr/bin/env bash
# ============================================================
# src/zpaq/zpaq_grouping.sh — Date Grouping, Wildcard Expansion,
#                              Space Checking & Decompression
#
# Provides:
#
#   expand_sftp_wildcard   SFTP_URL RESULT_VAR
#       Lists the remote SFTP directory and filters filenames
#       matching the glob pattern in SFTP_URL.  Stores a
#       newline-separated sorted list in RESULT_VAR.
#
#   expand_local_wildcard  PATTERN RESULT_VAR
#       Expands a local shell glob pattern into a sorted list
#       stored in RESULT_VAR.
#
#   extract_date_from_filename  FILENAME
#       Echoes the YYYYMMDD date string found in FILENAME, or
#       "undated" if no 8-digit date sequence is present.
#
#   group_files_by_date    FILE_LIST_VAR GROUPS_VAR
#       Reads a newline-separated file list from FILE_LIST_VAR
#       and populates the associative array named by GROUPS_VAR
#       mapping date → space-separated list of files.
#
#   detect_decompressor
#       Probes for parallel decompressor binaries and sets:
#         BZ2_DECOMPRESS_BIN   (lbzip2 | pbzip2 | bzip2)
#         GZ_DECOMPRESS_BIN    (pigz | gzip)
#       Called once at startup.
#
#   xz_list_uncompressed_size  FILE...
#       Echoes the total uncompressed byte count for one or more
#       .xz files using "xz --list --robot".
#
#   gz_list_uncompressed_size  FILE
#       Echoes the uncompressed byte count reported by "gzip -l"
#       for a single .gz file.  Returns 1 and echoes 0 if the
#       reported size appears unreliable (>4 GB wraparound heuristic).
#
#   zip_list_uncompressed_size FILE
#       Echoes the total uncompressed byte count for a .zip file
#       using "unzip -l".
#
#   bz2_estimate_uncompressed_size  FILE  HISTORY_FILE
#       Estimates the uncompressed byte count for a .bz2 file
#       using the historical average ratio from HISTORY_FILE.
#       Falls back to BZ2_DEFAULT_RATIO if no history exists.
#
#   estimate_group_uncompressed_size  FILE_LIST  HISTORY_FILE
#       Estimates the total uncompressed size for a list of files
#       (space-separated), dispatching per format.  Echoes total bytes.
#
#   update_size_history  COMPRESSED_FILE  UNCOMPRESSED_BYTES  HISTORY_FILE
#       Appends a compressed/uncompressed size record to HISTORY_FILE.
#
#   check_space  NEEDED_BYTES  AVAILABLE_BYTES  HEADROOM_RATIO
#       Returns 0 if space is sufficient, 1 if not.  Logs details.
#
#   decompress_file  COMPRESSED_FILE  DEST_DIR
#       Decompresses COMPRESSED_FILE into DEST_DIR, preserving any
#       source subdirectory structure relative to a base path.
#       Source file is deleted on success (no -k flag).
#       Returns 0 on success, 1 on error.
#
#   check_filename_collision  DEST_PATH
#       Returns 0 if DEST_PATH does not already exist (safe).
#       Logs an error and returns 1 if it does (collision).
#
# Dependency order:
#   Must be sourced after:
#     src/core/logging.sh         (uses log())
#     src/zpaq/zpaq_utils.sh      (uses ZPAQFRANZ_BIN, ZPAQFRANZ_THREADS)
# ============================================================

# ---------------------------------------------------------------------------
# Decompressor binary selections — set by detect_decompressor()
# ---------------------------------------------------------------------------
BZ2_DECOMPRESS_BIN=""
GZ_DECOMPRESS_BIN=""

# ---------------------------------------------------------------------------
# detect_decompressor
#
# Probes for parallel decompressor binaries and sets BZ2_DECOMPRESS_BIN
# and GZ_DECOMPRESS_BIN.  Called once at startup.
# ---------------------------------------------------------------------------
detect_decompressor() {
    # bzip2: prefer lbzip2 (fastest parallel), then pbzip2, then bzip2
    if command -v lbzip2 &>/dev/null; then
        BZ2_DECOMPRESS_BIN="lbzip2"
    elif command -v pbzip2 &>/dev/null; then
        BZ2_DECOMPRESS_BIN="pbzip2"
    elif command -v bzip2 &>/dev/null; then
        BZ2_DECOMPRESS_BIN="bzip2"
    else
        BZ2_DECOMPRESS_BIN=""
        log "WARN" "detect_decompressor: no bzip2 decompressor found (lbzip2/pbzip2/bzip2) — .bz2 files will fail"
    fi

    # gzip: prefer pigz (parallel), then gzip
    if command -v pigz &>/dev/null; then
        GZ_DECOMPRESS_BIN="pigz"
    elif command -v gzip &>/dev/null; then
        GZ_DECOMPRESS_BIN="gzip"
    else
        GZ_DECOMPRESS_BIN=""
        log "WARN" "detect_decompressor: no gzip decompressor found (pigz/gzip) — .gz files will fail"
    fi

    log "DEBUG" "detect_decompressor: bz2=${BZ2_DECOMPRESS_BIN:-none} gz=${GZ_DECOMPRESS_BIN:-none}"
}

# ---------------------------------------------------------------------------
# extract_date_from_filename FILENAME
#
# Echoes the first YYYYMMDD (8-digit) sequence found in the basename
# of FILENAME, or "undated" if none is found.
# ---------------------------------------------------------------------------
extract_date_from_filename() {
    local filename
    filename=$(basename "$1")
    local date_str
    # Match exactly 8 consecutive digits; validate loosely (year 19xx-20xx)
    date_str=$(grep -oP '(?<![0-9])(19|20)[0-9]{6}(?![0-9])' <<< "${filename}" | head -1 || true)
    if [[ -n "${date_str}" ]]; then
        echo "${date_str}"
    else
        echo "undated"
    fi
}

# ---------------------------------------------------------------------------
# group_files_by_date FILE_LIST ASSOC_ARRAY_NAME
#
# FILE_LIST is a newline-separated list of file paths (local or SFTP URLs).
# Populates the associative array named ASSOC_ARRAY_NAME with:
#   date_string → space-separated list of file paths
#
# Usage:
#   declare -A MY_GROUPS
#   group_files_by_date "${file_list}" MY_GROUPS
# ---------------------------------------------------------------------------
group_files_by_date() {
    local file_list="$1"
    local -n _groups_ref="$2"

    local file date_key
    while IFS= read -r file; do
        [[ -z "${file}" ]] && continue
        date_key=$(extract_date_from_filename "${file}")
        if [[ -n "${_groups_ref[${date_key}]+set}" ]]; then
            _groups_ref["${date_key}"]+=" ${file}"
        else
            _groups_ref["${date_key}"]="${file}"
        fi
    done <<< "${file_list}"

    log "DEBUG" "group_files_by_date: found ${#_groups_ref[@]} date group(s)"
}

# ---------------------------------------------------------------------------
# expand_sftp_wildcard SFTP_URL RESULT_VAR
#
# Parses SFTP_URL (sftp://host/dir/pattern) to extract host, dir, and
# glob pattern.  Lists the remote directory via SFTP and filters matching
# filenames.  Stores a sorted newline-separated list of full SFTP URLs
# in the variable named by RESULT_VAR.
#
# Requires SFTP_HOST, SFTP_PORT, SFTP_USER, SFTP_PASS to be set.
# ---------------------------------------------------------------------------
expand_sftp_wildcard() {
    local sftp_url="$1"
    local -n _result_ref="$2"

    # Parse sftp://host/dir/pattern
    local url_path="${sftp_url#sftp://*/}"
    # Get just the path portion after host
    local host_and_path="${sftp_url#sftp://}"
    local remote_path="/${host_and_path#*/}"
    local remote_dir
    remote_dir=$(dirname "${remote_path}")
    local pattern
    pattern=$(basename "${remote_path}")

    log "DEBUG" "expand_sftp_wildcard: dir=${remote_dir} pattern=${pattern}"

    # List remote directory
    local listing rc=0
    listing=$(SSHPASS="${SFTP_PASS}" sshpass -e sftp \
                -o StrictHostKeyChecking=no \
                -o BatchMode=no \
                -b <(printf 'ls -1 %s\n' "${remote_dir}") \
                -P "${SFTP_PORT}" \
                "${SFTP_USER}@${SFTP_HOST}" \
                2>/dev/null) || rc=$?

    if (( rc != 0 )); then
        log "ERROR" "expand_sftp_wildcard: could not list remote dir (rc=${rc}): ${remote_dir}"
        _result_ref=""
        return 1
    fi

    # Filter to lines matching the glob pattern, build full URLs
    local result=""
    local fname
    while IFS= read -r fname; do
        fname="${fname##*/}"   # strip any leading path sftp might echo
        [[ -z "${fname}" ]] && continue
        # Use bash glob match
        # shellcheck disable=SC2053  — intentional glob match against pattern variable
        if [[ "${fname}" == ${pattern} ]]; then
            result+="sftp://${SFTP_HOST}${remote_dir}/${fname}"$'\n'
        fi
    done <<< "${listing}"

    _result_ref="$(sort <<< "${result}")"
    log "DEBUG" "expand_sftp_wildcard: matched $(grep -c . <<< "${_result_ref}" || echo 0) file(s)"
}

# ---------------------------------------------------------------------------
# expand_local_wildcard PATTERN RESULT_VAR
#
# Expands a local path glob PATTERN into a sorted newline-separated list
# stored in RESULT_VAR.
# ---------------------------------------------------------------------------
expand_local_wildcard() {
    local pattern="$1"
    local -n _local_result_ref="$2"

    local dir
    dir=$(dirname "${pattern}")
    local glob
    glob=$(basename "${pattern}")

    local result=""
    local f
    while IFS= read -r -d $'\0' f; do
        result+="${f}"$'\n'
    done < <(find "${dir}" -maxdepth 1 -name "${glob}" -print0 2>/dev/null | sort -z)

    _local_result_ref="${result}"
    log "DEBUG" "expand_local_wildcard: pattern=${pattern} matched $(grep -c . <<< "${result}" || echo 0) file(s)"
}

# ---------------------------------------------------------------------------
# xz_list_uncompressed_size FILE...
#
# Echoes the total uncompressed byte count for one or more .xz files.
# Uses "xz --list --robot" for exact metadata (no decompression needed).
# ---------------------------------------------------------------------------
xz_list_uncompressed_size() {
    local total=0
    local line uncompressed
    while IFS= read -r line; do
        # Robot format: file <tab> blocks <tab> compressed <tab> uncompressed ...
        if [[ "${line}" =~ ^file ]]; then
            uncompressed=$(awk -F'\t' '{print $4}' <<< "${line}" || echo 0)
            uncompressed="${uncompressed//[[:space:]]/}"
            [[ "${uncompressed}" =~ ^[0-9]+$ ]] && total=$(( total + uncompressed ))
        fi
    done < <(xz --list --robot "$@" 2>/dev/null)
    echo "${total}"
}

# ---------------------------------------------------------------------------
# gz_list_uncompressed_size FILE
#
# Echoes the uncompressed byte count for a .gz file from gzip -l header.
# gzip stores uncompressed size as a 32-bit modulo value — files >4 GB
# wrap around.  If the reported uncompressed size is less than the
# compressed size (clearly impossible), returns 1 and echoes 0, signalling
# that the caller should fall back to history-based estimation.
# ---------------------------------------------------------------------------
gz_list_uncompressed_size() {
    local file="$1"
    local compressed_size uncompressed_size

    compressed_size=$(stat -c "%s" "${file}" 2>/dev/null || echo 0)

    # gzip -l output: compressed  uncompressed  ratio  uncompressed_name
    # Use awk to grab the second column of the data row (skip header)
    uncompressed_size=$(gzip -l "${file}" 2>/dev/null \
        | awk 'NR==2{print $2}' || echo 0)
    uncompressed_size="${uncompressed_size//[[:space:]]/}"

    if ! [[ "${uncompressed_size}" =~ ^[0-9]+$ ]]; then
        echo 0; return 1
    fi

    # Heuristic: if reported uncompressed < compressed, the 32-bit value wrapped
    if (( uncompressed_size < compressed_size && compressed_size > 0 )); then
        log "WARN" "gz_list_uncompressed_size: ${file}: reported size ${uncompressed_size} < compressed ${compressed_size} — likely >4 GB wraparound; will use history estimate"
        echo 0; return 1
    fi

    echo "${uncompressed_size}"
    return 0
}

# ---------------------------------------------------------------------------
# zip_list_uncompressed_size FILE
#
# Echoes the total uncompressed byte count for all members in a .zip file
# using "unzip -l".
# ---------------------------------------------------------------------------
zip_list_uncompressed_size() {
    local file="$1"
    local total=0 size

    # unzip -l output ends with a summary line: "NNN files, BYTES bytes uncompressed"
    # Extract the last "Length" column from each file entry (skip header/footer)
    while IFS= read -r line; do
        size=$(awk '{print $1}' <<< "${line}" || echo 0)
        [[ "${size}" =~ ^[0-9]+$ ]] && total=$(( total + size ))
    done < <(unzip -l "${file}" 2>/dev/null | awk 'NR>3{print $0}' | head -n -2)

    echo "${total}"
}

# ---------------------------------------------------------------------------
# _bz2_average_ratio HISTORY_FILE PATTERN
#
# Internal: computes the average uncompressed/compressed ratio from the
# last SIZE_HISTORY_SAMPLES entries in HISTORY_FILE matching PATTERN.
# Echoes the ratio as a decimal (awk float).
# Falls back to BZ2_DEFAULT_RATIO if insufficient history.
# ---------------------------------------------------------------------------
_bz2_average_ratio() {
    local history_file="$1"
    local pattern="$2"
    local samples="${SIZE_HISTORY_SAMPLES:-5}"
    local default_ratio="${BZ2_DEFAULT_RATIO:-3.5}"

    if [[ ! -f "${history_file}" ]]; then
        echo "${default_ratio}"
        return 0
    fi

    # History line format: compressed_bytes  uncompressed_bytes  date  pattern
    local ratio
    ratio=$(grep -F "${pattern}" "${history_file}" 2>/dev/null \
        | tail -n "${samples}" \
        | awk '
            BEGIN { sum=0; n=0 }
            $1>0 && $2>0 { sum += $2/$1; n++ }
            END { if (n>0) printf "%.4f", sum/n; else print "'"${default_ratio}"'" }
        ')

    echo "${ratio:-${default_ratio}}"
}

# ---------------------------------------------------------------------------
# bz2_estimate_uncompressed_size FILE HISTORY_FILE
#
# Estimates the uncompressed byte count for FILE using historical ratio.
# Echoes the estimated bytes (integer, with safety multiplier applied).
# ---------------------------------------------------------------------------
bz2_estimate_uncompressed_size() {
    local file="$1"
    local history_file="$2"
    local safety="${SIZE_ESTIMATE_SAFETY_FACTOR:-1.20}"

    local compressed_size
    compressed_size=$(stat -c "%s" "${file}" 2>/dev/null || echo 0)

    # Use basename prefix (strip date and extension) as the history pattern key
    local pattern
    pattern=$(basename "${file}" | sed -E 's/_?[0-9]{8}.*$//')

    local ratio
    ratio=$(_bz2_average_ratio "${history_file}" "${pattern}")

    # estimated = compressed × ratio × safety  (awk for float arithmetic)
    local estimated
    estimated=$(awk -v c="${compressed_size}" -v r="${ratio}" -v s="${safety}" \
        'BEGIN { printf "%d", int(c * r * s) }')

    log "DEBUG" "bz2_estimate_uncompressed_size: ${file} compressed=${compressed_size} ratio=${ratio} safety=${safety} estimated=${estimated}"
    echo "${estimated}"
}

# ---------------------------------------------------------------------------
# estimate_group_uncompressed_size FILE_LIST HISTORY_FILE
#
# FILE_LIST is a space-separated list of compressed source file paths.
# Echoes the total estimated uncompressed bytes for the group.
# Dispatches per format: xz→exact, zip→exact, gz→header/history, bz2→history.
# Also handles plain .sql (uncompressed) using actual file size.
# ---------------------------------------------------------------------------
estimate_group_uncompressed_size() {
    local file_list="$1"
    local history_file="$2"

    local total=0
    local xz_files=() gz_files=() bz2_files=() zip_files=()
    local file

    for file in ${file_list}; do
        # Detect format from extension (magic-byte fallback handled in decompress_file)
        case "${file,,}" in
            *.xz)       xz_files+=("${file}") ;;
            *.bz2)      bz2_files+=("${file}") ;;
            *.gz)       gz_files+=("${file}") ;;
            *.zip)      zip_files+=("${file}") ;;
            *.sql|*.txt|*.csv)
                # Plain uncompressed — use actual file size
                local plain_size
                plain_size=$(stat -c "%s" "${file}" 2>/dev/null || echo 0)
                total=$(( total + plain_size ))
                ;;
            *)
                # Unknown — use actual file size as conservative estimate
                local unk_size
                unk_size=$(stat -c "%s" "${file}" 2>/dev/null || echo 0)
                total=$(( total + unk_size ))
                ;;
        esac
    done

    # XZ: exact
    if (( ${#xz_files[@]} > 0 )); then
        local xz_total
        xz_total=$(xz_list_uncompressed_size "${xz_files[@]}")
        total=$(( total + xz_total ))
        log "DEBUG" "estimate_group_uncompressed_size: xz exact=${xz_total}"
    fi

    # ZIP: exact
    for file in "${zip_files[@]+"${zip_files[@]}"}"; do
        local zip_sz
        zip_sz=$(zip_list_uncompressed_size "${file}")
        total=$(( total + zip_sz ))
        log "DEBUG" "estimate_group_uncompressed_size: zip ${file} exact=${zip_sz}"
    done

    # GZ: header or history fallback
    for file in "${gz_files[@]+"${gz_files[@]}"}"; do
        local gz_sz=0
        if gz_list_uncompressed_size "${file}" > /dev/null 2>&1; then
            gz_sz=$(gz_list_uncompressed_size "${file}")
        fi
        if (( gz_sz == 0 )); then
            # Fallback: treat as bz2 estimation using same history
            gz_sz=$(bz2_estimate_uncompressed_size "${file}" "${history_file}")
            log "DEBUG" "estimate_group_uncompressed_size: gz ${file} fallback estimate=${gz_sz}"
        else
            log "DEBUG" "estimate_group_uncompressed_size: gz ${file} header=${gz_sz}"
        fi
        total=$(( total + gz_sz ))
    done

    # BZ2: history-based estimate
    for file in "${bz2_files[@]+"${bz2_files[@]}"}"; do
        local bz2_sz
        bz2_sz=$(bz2_estimate_uncompressed_size "${file}" "${history_file}")
        total=$(( total + bz2_sz ))
        log "DEBUG" "estimate_group_uncompressed_size: bz2 ${file} estimated=${bz2_sz}"
    done

    echo "${total}"
}

# ---------------------------------------------------------------------------
# update_size_history COMPRESSED_FILE UNCOMPRESSED_BYTES HISTORY_FILE
#
# Appends a record to HISTORY_FILE:
#   <compressed_bytes>  <uncompressed_bytes>  <date>  <pattern>
#
# Called after each successful decompression to refine future estimates.
# ---------------------------------------------------------------------------
update_size_history() {
    local compressed_file="$1"
    local uncompressed_bytes="$2"
    local history_file="$3"

    local compressed_size
    compressed_size=$(stat -c "%s" "${compressed_file}" 2>/dev/null || echo 0)
    local date_str
    date_str=$(date +"%Y%m%d")
    local pattern
    pattern=$(basename "${compressed_file}" | sed -E 's/_?[0-9]{8}.*$//')

    echo "${compressed_size}  ${uncompressed_bytes}  ${date_str}  ${pattern}" >> "${history_file}"
    log "DEBUG" "update_size_history: ${pattern} compressed=${compressed_size} uncompressed=${uncompressed_bytes}"
}

# ---------------------------------------------------------------------------
# check_space NEEDED_BYTES AVAILABLE_BYTES HEADROOM_RATIO
#
# Returns 0 if available space (minus headroom) is sufficient for needed bytes.
# Returns 1 if insufficient.  Logs details.
#
# HEADROOM_RATIO is the fraction of NEEDED_BYTES reserved for zpaq output.
# Total required = NEEDED_BYTES × (1 + HEADROOM_RATIO).
# ---------------------------------------------------------------------------
check_space() {
    local needed="$1"
    local available="$2"
    local headroom_ratio="${3:-${ZPAQ_HEADROOM_RATIO:-0.30}}"

    local total_required
    total_required=$(awk -v n="${needed}" -v h="${headroom_ratio}" \
        'BEGIN { printf "%d", int(n * (1 + h)) }')

    local needed_gb available_gb required_gb
    needed_gb=$(awk -v b="${needed}"         'BEGIN { printf "%.2f", b/1073741824 }')
    available_gb=$(awk -v b="${available}"   'BEGIN { printf "%.2f", b/1073741824 }')
    required_gb=$(awk -v b="${total_required}" 'BEGIN { printf "%.2f", b/1073741824 }')

    if (( available >= total_required )); then
        log "DEBUG" "check_space: OK — need ${required_gb} GB (${needed_gb} + ${headroom_ratio} headroom), have ${available_gb} GB"
        return 0
    fi

    log "ERROR" "check_space: INSUFFICIENT — need ${required_gb} GB (${needed_gb} + ${headroom_ratio} headroom), have ${available_gb} GB"
    return 1
}

# ---------------------------------------------------------------------------
# check_filename_collision DEST_PATH
#
# Returns 0 if DEST_PATH does not exist (safe to proceed).
# Returns 1 if it already exists (collision — aborts).
# ---------------------------------------------------------------------------
check_filename_collision() {
    local dest_path="$1"
    if [[ -e "${dest_path}" ]]; then
        log "ERROR" "check_filename_collision: destination already exists: ${dest_path}"
        log "ERROR" "  This indicates an unexpected duplicate filename in the source set."
        log "ERROR" "  Manual investigation required before proceeding."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# decompress_file COMPRESSED_FILE DEST_DIR SOURCE_BASE_DIR HISTORY_FILE
#
# Decompresses COMPRESSED_FILE into DEST_DIR, preserving the relative
# subdirectory path of COMPRESSED_FILE relative to SOURCE_BASE_DIR.
#
# Examples:
#   decompress_file /sftp_dl/vxtl_helium_20240115.sql.xz  /tmp/work /sftp_dl history
#     → /tmp/work/vxtl_helium_20240115.sql
#
#   decompress_file /sftp_dl/slim/vxtl_helium_20240115.sql.bz2  /tmp/work /sftp_dl history
#     → /tmp/work/slim/vxtl_helium_20240115.sql
#
# Source file is deleted on success (decompressors called without -k).
# Returns 0 on success, 1 on error.
# ---------------------------------------------------------------------------
decompress_file() {
    local compressed_file="$1"
    local dest_dir="$2"
    local source_base_dir="$3"
    local history_file="$4"

    if [[ ! -f "${compressed_file}" ]]; then
        log "ERROR" "decompress_file: file not found: ${compressed_file}"
        return 1
    fi

    # Determine relative path from source_base_dir to preserve subdir structure
    local rel_path
    rel_path="${compressed_file#${source_base_dir}/}"

    # Determine decompressed output filename (strip compression extension)
    local decompressed_name
    case "${compressed_file,,}" in
        *.sql.xz)  decompressed_name="${rel_path%.xz}"  ;;
        *.sql.bz2) decompressed_name="${rel_path%.bz2}" ;;
        *.sql.gz)  decompressed_name="${rel_path%.gz}"  ;;
        *.sql.zip) decompressed_name="${rel_path%.zip}" ;;
        *.xz)      decompressed_name="${rel_path%.xz}"  ;;
        *.bz2)     decompressed_name="${rel_path%.bz2}" ;;
        *.gz)      decompressed_name="${rel_path%.gz}"  ;;
        *.zip)     decompressed_name="${rel_path%.zip}" ;;
        *.sql)     decompressed_name="${rel_path}"      ;;  # already plain
        *)
            # Magic-byte fallback via detect_archive_format from zpaq_archive_ops.sh
            detect_archive_format "${compressed_file}"
            case "${ARCHIVE_FORMAT}" in
                xz)  decompressed_name="${rel_path}.decompressed" ;;
                bz2) decompressed_name="${rel_path}.decompressed" ;;
                gz)  decompressed_name="${rel_path}.decompressed" ;;
                zip) decompressed_name="${rel_path}.decompressed" ;;
                *)   decompressed_name="${rel_path}" ;;
            esac
            ;;
    esac

    local dest_path="${dest_dir}/${decompressed_name}"
    local dest_subdir
    dest_subdir=$(dirname "${dest_path}")

    # Create destination subdirectory if needed
    mkdir -p "${dest_subdir}"

    # Collision check
    if ! check_filename_collision "${dest_path}"; then
        return 1
    fi

    # Record compressed size before decompression (for history update)
    local compressed_size
    compressed_size=$(stat -c "%s" "${compressed_file}" 2>/dev/null || echo 0)

    log "INFO" "decompress_file: ${compressed_file} → ${dest_path}"

    local rc=0
    case "${compressed_file,,}" in
        *.xz)
            local xz_threads="${XZ_DECOMPRESS_THREADS:-4}"
            # xz -d decompresses in place; we need output in dest_dir
            # Copy to dest_dir first (preserving subdir), then decompress there
            local staging="${dest_dir}/${rel_path}"
            local staging_subdir
            staging_subdir=$(dirname "${staging}")
            mkdir -p "${staging_subdir}"
            cp "${compressed_file}" "${staging}"
            xz -d -T "${xz_threads}" "${staging}" || rc=$?
            if (( rc != 0 )); then
                log "ERROR" "decompress_file: xz -d failed (rc=${rc}): ${compressed_file}"
                rm -f "${staging}"
                return 1
            fi
            # xz removes the .xz and produces the plain file
            rm -f "${compressed_file}"
            ;;
        *.bz2)
            if [[ -z "${BZ2_DECOMPRESS_BIN}" ]]; then
                log "ERROR" "decompress_file: no bzip2 decompressor available"
                return 1
            fi
            local bz2_staging="${dest_dir}/${rel_path}"
            local bz2_staging_subdir
            bz2_staging_subdir=$(dirname "${bz2_staging}")
            mkdir -p "${bz2_staging_subdir}"
            cp "${compressed_file}" "${bz2_staging}"
            "${BZ2_DECOMPRESS_BIN}" -d "${bz2_staging}" || rc=$?
            if (( rc != 0 )); then
                log "ERROR" "decompress_file: ${BZ2_DECOMPRESS_BIN} -d failed (rc=${rc}): ${compressed_file}"
                rm -f "${bz2_staging}"
                return 1
            fi
            rm -f "${compressed_file}"
            ;;
        *.gz)
            if [[ -z "${GZ_DECOMPRESS_BIN}" ]]; then
                log "ERROR" "decompress_file: no gzip decompressor available"
                return 1
            fi
            local gz_staging="${dest_dir}/${rel_path}"
            local gz_staging_subdir
            gz_staging_subdir=$(dirname "${gz_staging}")
            mkdir -p "${gz_staging_subdir}"
            cp "${compressed_file}" "${gz_staging}"
            "${GZ_DECOMPRESS_BIN}" -d "${gz_staging}" || rc=$?
            if (( rc != 0 )); then
                log "ERROR" "decompress_file: ${GZ_DECOMPRESS_BIN} -d failed (rc=${rc}): ${compressed_file}"
                rm -f "${gz_staging}"
                return 1
            fi
            rm -f "${compressed_file}"
            ;;
        *.zip)
            unzip -o "${compressed_file}" -d "${dest_subdir}" || rc=$?
            if (( rc != 0 )); then
                log "ERROR" "decompress_file: unzip failed (rc=${rc}): ${compressed_file}"
                return 1
            fi
            rm -f "${compressed_file}"
            ;;
        *.sql|*.txt|*.csv)
            # Already uncompressed — just move to dest
            mv "${compressed_file}" "${dest_path}" || rc=$?
            if (( rc != 0 )); then
                log "ERROR" "decompress_file: mv failed (rc=${rc}): ${compressed_file} → ${dest_path}"
                return 1
            fi
            ;;
        *)
            log "WARN" "decompress_file: unknown format for ${compressed_file} — passing through as-is"
            mv "${compressed_file}" "${dest_path}" || rc=$?
            ;;
    esac

    # Update size history for bz2/gz files (actual uncompressed size now known)
    case "${compressed_file,,}" in
        *.bz2|*.gz)
            local actual_size=0
            [[ -f "${dest_path}" ]] && actual_size=$(stat -c "%s" "${dest_path}" 2>/dev/null || echo 0)
            # Use original compressed file path for history (already deleted, use recorded size)
            update_size_history_raw "${compressed_size}" "${actual_size}" \
                "$(basename "${compressed_file}" | sed -E 's/_?[0-9]{8}.*$//')" \
                "${history_file}"
            ;;
    esac

    log "INFO" "decompress_file: OK → ${dest_path}"
    return 0
}

# ---------------------------------------------------------------------------
# update_size_history_raw COMPRESSED_BYTES UNCOMPRESSED_BYTES PATTERN HISTORY_FILE
#
# Low-level history writer used by decompress_file after the compressed
# source is already gone (size recorded before decompression).
# ---------------------------------------------------------------------------
update_size_history_raw() {
    local compressed_bytes="$1"
    local uncompressed_bytes="$2"
    local pattern="$3"
    local history_file="$4"

    local date_str
    date_str=$(date +"%Y%m%d")
    echo "${compressed_bytes}  ${uncompressed_bytes}  ${date_str}  ${pattern}" >> "${history_file}"
    log "DEBUG" "update_size_history_raw: ${pattern} compressed=${compressed_bytes} uncompressed=${uncompressed_bytes}"
}