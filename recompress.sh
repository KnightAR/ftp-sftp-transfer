#!/usr/bin/env bash
# ============================================================
# recompress.sh — Recompress Archives to XZ Format
#
# Recompresses supported archive formats into .xz, reading from
# the original location, staging output in TEMP_DIR, then moving
# the result to the same directory as the source file.
#
# Supported input formats:
#   .bz2 / .tar.bz2   — pbzip2 (preferred) or bzip2
#   .gz  / .tar.gz    — gzip
#   .zip              — unzip (or 7z fallback)
#   .7z               — 7z
#   .xz  / .tar.xz    — skipped
#
# Usage:
#   ./recompress.sh <file|dir> [OPTIONS]
#
#   -o          Overwrite existing .xz output file (default: no clobber)
#   -r          Recursive directory scan (default: flat)
#   -d          Delete original after successful recompression
#   -t          Force tar wrapping for multi-file zip/7z archives
#   -l <1-9>    XZ compression level (default: 9)
#   -E          Disable --extreme (default: on at level 9)
#   -T <n>      XZ thread count (default: 32, capped at nproc-1)
#   -v          Verbose mode (script + xz -v output)
#   -c <file>   Config file override (default: ./transfer.conf)
#   -h          Help
# ============================================================

# shellcheck disable=SC2034  # OPT_VERBOSE, OPT_CONFIG used by compress_utils.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=src/compress/compress_utils.sh
source "${SCRIPT_DIR}/src/compress/compress_utils.sh"

# ---- Defaults ----
OPT_CLOBBER=false
OPT_RECURSIVE=false
OPT_DELETE=false
OPT_TAR_MULTI=false
OPT_XZ_LEVEL=9
OPT_XZ_EXTREME=true
OPT_XZ_THREADS=32
# shellcheck disable=SC2034  # used by compress_utils.sh
OPT_VERBOSE=false
# shellcheck disable=SC2034  # used by compress_utils.sh
OPT_CONFIG="${SCRIPT_DIR}/transfer.conf"
OPT_PATH=""

# ---- Counters ----
# (Tool flags and shared functions provided by compress_utils.sh)
CNT_RECOMPRESSED=0
CNT_SKIPPED_FORMAT=0
CNT_SKIPPED_MULTI=0
CNT_SKIPPED_CLOBBER=0
CNT_FAILED=0

usage() {
    cat <<EOF
recompress.sh — Recompress Archives to XZ

Recompresses .bz2, .gz, .zip, .7z archives to .xz format.
XZ files are skipped. Output is written to the same directory
as the source file. Compression is staged in TEMP_DIR first.

Usage: $(basename "$0") <file|dir> [OPTIONS]

Positional:
  file|dir      File or directory to recompress

Options:
  -o            Overwrite existing .xz output (default: skip if exists)
  -r            Recursive directory scan (default: flat)
  -d            Delete original file after successful recompression
  -t            Force tar wrapping for multi-file zip/7z archives
  -l <1-9>      XZ compression level         (default: 9)
  -E            Disable --extreme             (default: on at level 9)
  -T <n>        XZ thread count              (default: 32, capped at nproc-1)
  -v            Verbose mode (script + xz -v)
  -c <file>     Config file                  (default: ./transfer.conf)
  -h            Show this help

Examples:
  $(basename "$0") /mnt/blockchain/archive.tar.bz2
  $(basename "$0") /mnt/blockchain/ -r -o -d
  $(basename "$0") /mnt/data/archive.zip -t
  $(basename "$0") /mnt/data/archive.tar.bz2 -l 6 -E -T 8
EOF
    exit 0
}

# ============================================================
# parse_args
# ============================================================
parse_args() {
    if (( $# == 0 )); then
        usage
    fi

    OPT_PATH="$1"
    shift

    if [[ "${OPT_PATH}" == "-h" || "${OPT_PATH}" == "--help" ]]; then
        usage
    fi

    while getopts ":ordtl:ET:vc:h" opt; do
        case "${opt}" in
            o) OPT_CLOBBER=true ;;
            r) OPT_RECURSIVE=true ;;
            d) OPT_DELETE=true ;;
            t) OPT_TAR_MULTI=true ;;
            l) OPT_XZ_LEVEL="${OPTARG}" ;;
            E) OPT_XZ_EXTREME=false ;;
            T) OPT_XZ_THREADS="${OPTARG}" ;;
            v) OPT_VERBOSE=true ;;
            c) OPT_CONFIG="${OPTARG}" ;;
            h) usage ;;
            :) echo "ERROR: Option -${OPTARG} requires an argument." >&2; exit 2 ;;
            \?) echo "ERROR: Unknown option -${OPTARG}." >&2; exit 2 ;;
        esac
    done

    # Validate -l level
    if ! [[ "${OPT_XZ_LEVEL}" =~ ^[1-9]$ ]]; then
        echo "ERROR: -l must be a number between 1 and 9 (got: '${OPT_XZ_LEVEL}')" >&2
        exit 2
    fi

    # --extreme only valid at level 9
    if [[ "${OPT_XZ_LEVEL}" != "9" ]]; then
        OPT_XZ_EXTREME=false
    fi

    # Validate -T threads — cap at nproc-1
    local max_threads
    max_threads=$(( $(nproc) - 1 ))
    if (( max_threads < 1 )); then
        max_threads=1
    fi
    if ! [[ "${OPT_XZ_THREADS}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: -T must be a positive integer (got: '${OPT_XZ_THREADS}')" >&2
        exit 2
    fi
    if (( OPT_XZ_THREADS > max_threads )); then
        log "WARN" "Requested -T ${OPT_XZ_THREADS} exceeds nproc-1 (${max_threads}) — capping"
        OPT_XZ_THREADS="${max_threads}"
    fi
    if (( OPT_XZ_THREADS < 1 )); then
        OPT_XZ_THREADS=1
    fi

    # Validate path exists
    if [[ ! -e "${OPT_PATH}" ]]; then
        echo "ERROR: Path not found: ${OPT_PATH}" >&2
        exit 2
    fi
}

# ============================================================
# get_output_name FILENAME IS_MULTI_TAR
# Prints the output filename (.xz or .tar.xz).
# ============================================================
get_output_name() {
    local filename="$1"
    local is_multi_tar="${2:-false}"

    # Strip known double extensions first
    local base
    case "${filename}" in
        *.tar.bz2) base="${filename%.tar.bz2}" ; echo "${base}.tar.xz" ;;
        *.tar.gz)  base="${filename%.tar.gz}"  ; echo "${base}.tar.xz" ;;
        *.tar.xz)  echo "${filename}" ;; # unchanged — caller should skip
        *.bz2)     base="${filename%.bz2}"     ; echo "${base}.xz" ;;
        *.gz)      base="${filename%.gz}"      ; echo "${base}.xz" ;;
        *.zip)
            base="${filename%.zip}"
            if [[ "${is_multi_tar}" == true ]]; then
                echo "${base}.tar.xz"
            else
                echo "${base}.xz"
            fi
            ;;
        *.7z)
            base="${filename%.7z}"
            if [[ "${is_multi_tar}" == true ]]; then
                echo "${base}.tar.xz"
            else
                echo "${base}.xz"
            fi
            ;;
        *) echo "${filename}" ;; # unknown — caller should skip
    esac
}

# ============================================================
# count_archive_files FILEPATH
# Returns the number of files inside a zip or 7z archive.
# ============================================================
count_archive_files() {
    local filepath="$1"
    local count=0

    case "${filepath}" in
        *.zip)
            if [[ "${HAS_UNZIP}" == true ]]; then
                count=$(unzip -l "${filepath}" 2>/dev/null | grep -c "^\s*[0-9]" || true)
                # unzip -l includes a header/footer line — subtract 2
                (( count = count > 2 ? count - 2 : 0 )) || true
            elif [[ "${HAS_7Z}" == true ]]; then
                count=$(7z l "${filepath}" 2>/dev/null | grep -c "^[0-9]\{4\}-" || true)
            fi
            ;;
        *.7z)
            if [[ "${HAS_7Z}" == true ]]; then
                count=$(7z l "${filepath}" 2>/dev/null | grep -c "^[0-9]\{4\}-" || true)
            fi
            ;;
    esac

    echo "${count}"
}

# ============================================================
# run_pipeline SOURCE_FILE STAGING_FILE
# Runs the decompress | [pv |] xz pipeline.
# Returns 0 on success, 1 on failure.
# ============================================================
run_pipeline() {
    local source_file="$1"
    local staging_file="$2"
    local xz_opts
    xz_opts=$(build_xz_opts)

    # Determine decompress command based on format + available tools
    local decomp_cmd=""

    case "${source_file}" in
        *.tar.bz2|*.bz2)
            if [[ "${HAS_PBZIP2}" == true ]]; then
                decomp_cmd="pbzip2 -d -k -c $(printf '%q' "${source_file}")"
            elif [[ "${HAS_BZIP2}" == true ]]; then
                decomp_cmd="bzip2 -d -k -c $(printf '%q' "${source_file}")"
            elif [[ "${HAS_7Z}" == true ]]; then
                decomp_cmd="7z e -so $(printf '%q' "${source_file}")"
            else
                log "ERROR" "No tool available to decompress bz2: ${source_file}"
                return 1
            fi
            ;;
        *.tar.gz|*.gz)
            if [[ "${HAS_GZIP}" == true ]]; then
                decomp_cmd="gzip -d -k -c $(printf '%q' "${source_file}")"
            elif [[ "${HAS_7Z}" == true ]]; then
                decomp_cmd="7z e -so $(printf '%q' "${source_file}")"
            else
                log "ERROR" "No tool available to decompress gz: ${source_file}"
                return 1
            fi
            ;;
        *.zip)
            if [[ "${HAS_UNZIP}" == true ]]; then
                decomp_cmd="unzip -p $(printf '%q' "${source_file}")"
            elif [[ "${HAS_7Z}" == true ]]; then
                decomp_cmd="7z e -so $(printf '%q' "${source_file}")"
            else
                log "ERROR" "No tool available to decompress zip: ${source_file}"
                return 1
            fi
            ;;
        *.7z)
            if [[ "${HAS_7Z}" == true ]]; then
                decomp_cmd="7z e -so $(printf '%q' "${source_file}")"
            else
                log "ERROR" "No tool available to decompress 7z: ${source_file}"
                return 1
            fi
            ;;
        *)
            log "ERROR" "Unsupported format: ${source_file}"
            return 1
            ;;
    esac

    log "DEBUG" "Decompress cmd: ${decomp_cmd}"
    log "DEBUG" "XZ opts: ${xz_opts}"
    log "DEBUG" "Staging: ${staging_file}"

    # Run pipeline — use eval to handle the composed command strings
    # shellcheck disable=SC2086
    if [[ "${HAS_PV}" == true ]]; then
        eval "${decomp_cmd}" | pv | xz ${xz_opts} > "${staging_file}"
    else
        eval "${decomp_cmd}" | xz ${xz_opts} > "${staging_file}"
    fi
}

# ============================================================
# run_pipeline_tar SOURCE_FILE STAGING_FILE
# For multi-file zip/7z with -t: extract to temp subdir,
# tar it, then compress.
# ============================================================
run_pipeline_tar() {
    local source_file="$1"
    local staging_file="$2"
    local xz_opts
    xz_opts=$(build_xz_opts)

    # Create a temp subdir for extraction
    local extract_dir
    extract_dir=$(mktemp -d "${TEMP_DIR}/recompress_extract_XXXXXXXXXX")

    log "DEBUG" "Extracting to temp subdir: ${extract_dir}"

    local rc=0

    # Extract to subdir
    case "${source_file}" in
        *.zip)
            if [[ "${HAS_UNZIP}" == true ]]; then
                unzip -q "${source_file}" -d "${extract_dir}" || rc=$?
            elif [[ "${HAS_7Z}" == true ]]; then
                7z e "${source_file}" -o"${extract_dir}" -y > /dev/null || rc=$?
            else
                log "ERROR" "No tool available to extract zip: ${source_file}"
                rm -rf "${extract_dir}"
                return 1
            fi
            ;;
        *.7z)
            if [[ "${HAS_7Z}" == true ]]; then
                7z e "${source_file}" -o"${extract_dir}" -y > /dev/null || rc=$?
            else
                log "ERROR" "No tool available to extract 7z: ${source_file}"
                rm -rf "${extract_dir}"
                return 1
            fi
            ;;
    esac

    if (( rc != 0 )); then
        log "ERROR" "Extraction failed (rc=${rc}): ${source_file}"
        rm -rf "${extract_dir}"
        return 1
    fi

    # Tar + xz pipeline
    # shellcheck disable=SC2086
    if [[ "${HAS_PV}" == true ]]; then
        tar -c -C "${extract_dir}" . | pv | xz ${xz_opts} > "${staging_file}" || rc=$?
    else
        tar -c -C "${extract_dir}" . | xz ${xz_opts} > "${staging_file}" || rc=$?
    fi

    rm -rf "${extract_dir}"

    if (( rc != 0 )); then
        return 1
    fi
}

# ============================================================
# recompress_file FILEPATH
# Main per-file recompression logic.
# ============================================================
recompress_file() {
    local filepath="$1"
    local filename
    filename=$(basename "${filepath}")
    local source_dir
    source_dir=$(dirname "${filepath}")

    # ---- Skip xz files ----
    case "${filename}" in
        *.tar.xz|*.xz)
            log "DEBUG" "Skipping (already xz): ${filepath}"
            (( CNT_SKIPPED_FORMAT++ )) || true
            return 0
            ;;
    esac

    # ---- Skip unsupported formats ----
    case "${filename}" in
        *.tar.bz2|*.bz2|*.tar.gz|*.gz|*.zip|*.7z)
            : # supported
            ;;
        *)
            log "DEBUG" "Skipping (unsupported format): ${filepath}"
            (( CNT_SKIPPED_FORMAT++ )) || true
            return 0
            ;;
    esac

    log "INFO" "Processing: ${filepath}"

    # ---- Handle multi-file zip/7z ----
    local is_multi=false
    local is_multi_tar=false

    case "${filename}" in
        *.zip|*.7z)
            local file_count
            file_count=$(count_archive_files "${filepath}")
            log "DEBUG" "Archive contains ${file_count} file(s): ${filename}"

            if (( file_count > 1 )); then
                if [[ "${OPT_TAR_MULTI}" == true ]]; then
                    log "INFO" "Multi-file archive — will tar+compress: ${filename}"
                    is_multi=true
                    is_multi_tar=true
                else
                    log "WARN" "Skipping multi-file archive (use -t to force tar): ${filepath}"
                    (( CNT_SKIPPED_MULTI++ )) || true
                    return 0
                fi
            fi
            ;;
    esac

    # ---- Determine output filename ----
    local output_name
    output_name=$(get_output_name "${filename}" "${is_multi_tar}")
    local output_path="${source_dir}/${output_name}"
    local staging_path="${TEMP_DIR}/${output_name}"

    # ---- No clobber check ----
    if [[ -f "${output_path}" ]] && [[ "${OPT_CLOBBER}" != true ]]; then
        log "WARN" "Output already exists (use -o to overwrite): ${output_path}"
        (( CNT_SKIPPED_CLOBBER++ )) || true
        return 0
    fi

    # ---- Run pipeline ----
    local rc=0
    rm -f "${staging_path}"

    if [[ "${is_multi}" == true ]]; then
        run_pipeline_tar "${filepath}" "${staging_path}" || rc=$?
    else
        run_pipeline "${filepath}" "${staging_path}" || rc=$?
    fi

    if (( rc != 0 )); then
        log "ERROR" "Recompression failed (rc=${rc}): ${filepath}"
        rm -f "${staging_path}"
        (( CNT_FAILED++ )) || true
        return 0  # continue batch — do not abort
    fi

    # ---- Move from staging to destination ----
    log "INFO" "Moving staging to destination: ${output_path}"
    mv "${staging_path}" "${output_path}"

    # ---- Optionally delete original ----
    if [[ "${OPT_DELETE}" == true ]]; then
        log "INFO" "Deleting original: ${filepath}"
        rm -f "${filepath}"
    fi

    log "INFO" "Done: ${filepath} → ${output_path}"
    (( CNT_RECOMPRESSED++ )) || true
}

# ============================================================
# print_summary
# ============================================================
print_summary() {
    log "INFO" "============================================================"
    log "INFO" "Recompress Summary"
    log "INFO" "============================================================"
    log "INFO" "  Recompressed      : ${CNT_RECOMPRESSED}"
    log "INFO" "  Skipped (format)  : ${CNT_SKIPPED_FORMAT}"
    log "INFO" "  Skipped (multi)   : ${CNT_SKIPPED_MULTI}"
    log "INFO" "  Skipped (exists)  : ${CNT_SKIPPED_CLOBBER}"
    log "INFO" "  Failed            : ${CNT_FAILED}"
    log "INFO" "============================================================"
}

# ============================================================
# main
# ============================================================
main() {
    parse_args "$@"
    load_temp_dir
    detect_tools

    log "INFO" "recompress.sh starting"
    log "INFO" "  Path      : ${OPT_PATH}"
    log "INFO" "  XZ level  : ${OPT_XZ_LEVEL}$([ "${OPT_XZ_EXTREME}" == true ] && echo " --extreme" || true)"
    log "INFO" "  Threads   : ${OPT_XZ_THREADS}"
    log "INFO" "  Clobber   : ${OPT_CLOBBER}"
    log "INFO" "  Delete    : ${OPT_DELETE}"
    log "INFO" "  Recursive : ${OPT_RECURSIVE}"
    log "INFO" "  Force tar : ${OPT_TAR_MULTI}"
    log "INFO" "  Staging   : ${TEMP_DIR}"

    if [[ -f "${OPT_PATH}" ]]; then
        # ---- Single file mode ----
        recompress_file "${OPT_PATH}"
    elif [[ -d "${OPT_PATH}" ]]; then
        # ---- Directory mode ----
        local find_opts="-maxdepth 1"
        [[ "${OPT_RECURSIVE}" == true ]] && find_opts=""

        local file
        while IFS= read -r file; do
            [[ -f "${file}" ]] || continue
            recompress_file "${file}"
        done < <(find "${OPT_PATH}" ${find_opts} -type f \
            \( -name "*.bz2" -o -name "*.gz" -o -name "*.zip" \
               -o -name "*.7z" -o -name "*.xz" \) | sort)
    else
        echo "ERROR: Path is neither a file nor a directory: ${OPT_PATH}" >&2
        exit 2
    fi

    print_summary

    if (( CNT_FAILED > 0 )); then
        exit 1
    fi
}

main "$@"