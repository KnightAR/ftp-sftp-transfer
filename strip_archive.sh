#!/usr/bin/env bash
# ============================================================
# strip_archive.sh — Strip Directories from Compressed Tar Archives
#
# Decompresses a .tar.bz2 / .tar.gz / .tar.xz (and aliases
# .tgz / .tbz2 / .txz) to a raw tar in TEMP_DIR staging,
# removes the specified directories using tar --delete, then
# recompresses to .tar.xz.
#
# Supports resume: if a staging .tar already exists in TEMP_DIR,
# decompression is skipped. Use -C to skip tar --delete entirely
# and go straight to recompression.
#
# Requires bsdtar (libarchive-tools) for clean block reclamation
# after tar --delete. Install with: apt-get install libarchive-tools
#
# Usage:
#   ./strip_archive.sh <archive> [dirs] [OPTIONS]
#
#   archive         Input archive file (required)
#   dirs            Comma-separated dirs to remove (required unless -C)
#
#   -o <file>   Output path (default: <basename>-stripped.tar.xz
#               in same dir as input)
#   -p <prefix> Path prefix to prepend to each dir (default: none)
#   -d          Delete original archive after successful output
#   -O          Overwrite existing output file (clobber)
#   -C          Continue/compress-only — skip tar --delete step
#   -l <1-9>    XZ compression level (default: 9)
#   -E          Disable --extreme (default: on at level 9)
#   -T <n>      XZ thread count (default: nproc-1, min 1)
#   -v          Verbose mode (script + xz -v)
#   -c <file>   Config file (default: ./transfer.conf)
#   -h          Help
# ============================================================

# shellcheck disable=SC2034  # OPT_VERBOSE, OPT_CONFIG, OPT_XZ_* used by compress_utils.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=src/compress/compress_utils.sh
source "${SCRIPT_DIR}/src/compress/compress_utils.sh"

# ---- Defaults ----
OPT_ARCHIVE=""
OPT_DIRS=""
OPT_OUTPUT=""
OPT_PREFIX=""
OPT_DELETE=false
OPT_CLOBBER=false
OPT_CONTINUE=false
OPT_XZ_LEVEL=9
OPT_XZ_EXTREME=true
OPT_XZ_THREADS=32
OPT_VERBOSE=false
OPT_CONFIG="${SCRIPT_DIR}/transfer.conf"

# ---- Staging paths (set after load_temp_dir) ----
STAGING_TAR=""
STAGING_XZ=""

# ---- Resume mode flag (set during main) ----
RESUME_MODE=false

# ============================================================
# usage
# ============================================================
usage() {
    cat <<EOF
strip_archive.sh — Strip Directories from Compressed Tar Archives

Decompresses a tar archive, removes listed directories via
tar --delete, then recompresses to .tar.xz. Staging is
performed in TEMP_DIR. Supports resume if staging .tar exists.

Usage: $(basename "$0") <archive> [dir1,dir2,...] [OPTIONS]

Positional:
  archive         Input archive (.tar.bz2 .tar.gz .tar.xz .tgz .tbz2 .txz)
  dir1,dir2,...   Comma-separated directories to remove (required unless -C)

Options:
  -o <file>       Output path (default: <basename>-stripped.tar.xz)
  -p <prefix>     Prefix to prepend to each dir (e.g. myapp)
  -d              Delete original after successful output
  -O              Overwrite existing output file
  -C              Continue/compress-only — skip tar --delete
  -l <1-9>        XZ compression level         (default: 9)
  -E              Disable --extreme             (default: on at level 9)
  -T <n>          XZ thread count              (default: nproc-1)
  -v              Verbose mode (script + xz -v)
  -c <file>       Config file                  (default: ./transfer.conf)
  -h              Show this help

Examples:
  $(basename "$0") release.tar.bz2 vendor,node_modules
  $(basename "$0") release.tar.gz  vendor,node_modules -p myapp -o release-clean.tar.xz
  $(basename "$0") release.tar.xz  vendor -d -O -l 6 -E -T 4
  $(basename "$0") release.tar.bz2 --continue
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

    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        usage
    fi

    OPT_ARCHIVE="$1"
    shift

    # Second positional: dirs (optional if -C will be passed)
    if (( $# > 0 )) && [[ "$1" != -* ]] && [[ "$1" != "--continue" ]]; then
        OPT_DIRS="$1"
        shift
    fi

    # Handle --continue as a long option before getopts
    local remaining_args=()
    for arg in "$@"; do
        if [[ "${arg}" == "--continue" ]]; then
            OPT_CONTINUE=true
        else
            remaining_args+=("${arg}")
        fi
    done
    set -- "${remaining_args[@]+"${remaining_args[@]}"}"

    while getopts ":o:p:dOCl:ET:vc:h" opt; do
        case "${opt}" in
            o) OPT_OUTPUT="${OPTARG}" ;;
            p) OPT_PREFIX="${OPTARG}" ;;
            d) OPT_DELETE=true ;;
            O) OPT_CLOBBER=true ;;
            C) OPT_CONTINUE=true ;;
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

    # Validate archive exists
    if [[ ! -f "${OPT_ARCHIVE}" ]]; then
        echo "ERROR: Archive not found: ${OPT_ARCHIVE}" >&2
        exit 2
    fi

    # Validate archive extension
    case "${OPT_ARCHIVE}" in
        *.tar.bz2|*.tar.gz|*.tar.xz|*.tgz|*.tbz2|*.txz) : ;;
        *)
            echo "ERROR: Unsupported archive format: ${OPT_ARCHIVE}" >&2
            echo "       Supported: .tar.bz2 .tar.gz .tar.xz .tgz .tbz2 .txz" >&2
            exit 2
            ;;
    esac

    # Dirs required unless -C
    if [[ "${OPT_CONTINUE}" != true ]] && [[ -z "${OPT_DIRS}" ]]; then
        echo "ERROR: Directory list is required (or pass -C to skip deletions)." >&2
        exit 2
    fi

    # Validate -l level
    if ! [[ "${OPT_XZ_LEVEL}" =~ ^[1-9]$ ]]; then
        echo "ERROR: -l must be a number between 1 and 9 (got: '${OPT_XZ_LEVEL}')" >&2
        exit 2
    fi

    # --extreme only valid at level 9
    if [[ "${OPT_XZ_LEVEL}" != "9" ]]; then
        OPT_XZ_EXTREME=false
    fi

    # Validate and cap -T threads
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

    # Strip leading/trailing slashes from prefix; treat bare / as no prefix
    if [[ -n "${OPT_PREFIX}" ]]; then
        OPT_PREFIX="${OPT_PREFIX#/}"
        OPT_PREFIX="${OPT_PREFIX%/}"
    fi
}

# ============================================================
# resolve_output_path
# Sets OPT_OUTPUT if not already set by -o flag.
# ============================================================
resolve_output_path() {
    if [[ -n "${OPT_OUTPUT}" ]]; then
        return 0
    fi

    local source_dir
    source_dir=$(dirname "${OPT_ARCHIVE}")
    local filename
    filename=$(basename "${OPT_ARCHIVE}")

    local base
    case "${filename}" in
        *.tar.bz2) base="${filename%.tar.bz2}" ;;
        *.tar.gz)  base="${filename%.tar.gz}"  ;;
        *.tar.xz)  base="${filename%.tar.xz}"  ;;
        *.tbz2)    base="${filename%.tbz2}"     ;;
        *.tgz)     base="${filename%.tgz}"      ;;
        *.txz)     base="${filename%.txz}"      ;;
        *)         base="${filename}"           ;;
    esac

    OPT_OUTPUT="${source_dir}/${base}-stripped.tar.xz"
}

# ============================================================
# resolve_staging_paths
# Sets STAGING_TAR and STAGING_XZ based on TEMP_DIR.
# ============================================================
resolve_staging_paths() {
    local filename
    filename=$(basename "${OPT_ARCHIVE}")

    local base
    case "${filename}" in
        *.tar.bz2) base="${filename%.tar.bz2}" ;;
        *.tar.gz)  base="${filename%.tar.gz}"  ;;
        *.tar.xz)  base="${filename%.tar.xz}"  ;;
        *.tbz2)    base="${filename%.tbz2}"     ;;
        *.tgz)     base="${filename%.tgz}"      ;;
        *.txz)     base="${filename%.txz}"      ;;
        *)         base="${filename}"           ;;
    esac

    STAGING_TAR="${TEMP_DIR}/${base}.tar"
    STAGING_XZ="${TEMP_DIR}/$(basename "${OPT_OUTPUT}")"
}

# ============================================================
# build_dir_list NAMEREF_ARRAY
# Converts comma-separated OPT_DIRS + optional prefix into
# an array of paths for tar --delete.
# ============================================================
build_dir_list() {
    local -n _out_dirs=$1

    local IFS=','
    read -ra raw_dirs <<< "${OPT_DIRS}"

    local dir entry
    for dir in "${raw_dirs[@]}"; do
        # Trim whitespace
        dir="${dir#"${dir%%[![:space:]]*}"}"
        dir="${dir%"${dir##*[![:space:]]}"}"
        # Strip any leading/trailing slash
        dir="${dir#/}"
        dir="${dir%/}"

        if [[ -z "${dir}" ]]; then
            continue
        fi

        if [[ -n "${OPT_PREFIX}" ]]; then
            entry="${OPT_PREFIX}/${dir}"
        else
            entry="${dir}"
        fi

        _out_dirs+=("${entry}")
    done
}

# ============================================================
# cleanup_staging
# Removes staging files — called on failure paths.
# ============================================================
cleanup_staging() {
    [[ -n "${STAGING_TAR}" && -f "${STAGING_TAR}" ]] && rm -f "${STAGING_TAR}"
    [[ -n "${STAGING_XZ}"  && -f "${STAGING_XZ}"  ]] && rm -f "${STAGING_XZ}"
}

# ============================================================
# decompress_to_tar
# Decompresses OPT_ARCHIVE to STAGING_TAR.
# ============================================================
decompress_to_tar() {
    log "INFO" "Decompressing: ${OPT_ARCHIVE} → ${STAGING_TAR}"

    local rc=0

    case "${OPT_ARCHIVE}" in
        *.tar.bz2|*.tbz2)
            if [[ "${HAS_PBZIP2}" == true ]]; then
                log "DEBUG" "Using pbzip2"
                pbzip2 -d -k -c "${OPT_ARCHIVE}" > "${STAGING_TAR}" || rc=$?
            elif [[ "${HAS_BZIP2}" == true ]]; then
                log "DEBUG" "Using bzip2"
                bzip2 -d -k -c "${OPT_ARCHIVE}" > "${STAGING_TAR}" || rc=$?
            elif [[ "${HAS_7Z}" == true ]]; then
                log "DEBUG" "Using 7z fallback"
                7z e -so "${OPT_ARCHIVE}" > "${STAGING_TAR}" || rc=$?
            else
                log "ERROR" "No tool available to decompress bz2: ${OPT_ARCHIVE}"
                return 1
            fi
            ;;
        *.tar.gz|*.tgz)
            if [[ "${HAS_GZIP}" == true ]]; then
                log "DEBUG" "Using gzip"
                gzip -d -k -c "${OPT_ARCHIVE}" > "${STAGING_TAR}" || rc=$?
            elif [[ "${HAS_7Z}" == true ]]; then
                log "DEBUG" "Using 7z fallback"
                7z e -so "${OPT_ARCHIVE}" > "${STAGING_TAR}" || rc=$?
            else
                log "ERROR" "No tool available to decompress gz: ${OPT_ARCHIVE}"
                return 1
            fi
            ;;
        *.tar.xz|*.txz)
            log "DEBUG" "Using xz"
            xz -d -k -c "${OPT_ARCHIVE}" > "${STAGING_TAR}" || rc=$?
            ;;
    esac

    if (( rc != 0 )); then
        log "ERROR" "Decompression failed (rc=${rc}): ${OPT_ARCHIVE}"
        return 1
    fi

    log "DEBUG" "Decompression complete: $(du -sh "${STAGING_TAR}" 2>/dev/null | cut -f1) raw tar"
    return 0
}

# ============================================================
# delete_dirs_from_tar DIR_ARRAY...
# Runs tar --delete for each dir, completing the full loop
# before exiting so all failures are reported in one pass.
# Fresh run: missing path is a fatal error (collected).
# Resume run: missing path is INFO (may already be deleted).
# Other tar errors are always fatal (collected).
# Returns 1 if any errors were recorded, 0 if all succeeded.
# ============================================================
delete_dirs_from_tar() {
    local dirs=("$@")

    local dir rc tar_stderr
    local had_error=false

    for dir in "${dirs[@]}"; do
        log "INFO" "Deleting from tar: ${dir}"
        rc=0
        tar_stderr=$(tar --delete -f "${STAGING_TAR}" "${dir}" 2>&1) || rc=$?

        if (( rc == 0 )); then
            log "INFO" "Deleted: ${dir}"
        else
            if echo "${tar_stderr}" | grep -q "Not found in archive"; then
                if [[ "${RESUME_MODE}" == true ]]; then
                    log "INFO" "Not found in archive (may already be deleted on previous run): ${dir}"
                else
                    log "ERROR" "Path not found in archive — correct the path and re-run: ${dir}"
                    had_error=true
                fi
            else
                log "ERROR" "tar --delete failed (rc=${rc}): ${dir}"
                [[ -n "${tar_stderr}" ]] && log "ERROR" "tar output: ${tar_stderr}"
                had_error=true
            fi
        fi
    done

    if [[ "${had_error}" == true ]]; then
        return 1
    fi

    return 0
}

# ============================================================
# compress_tar_to_xz
# Repacks STAGING_TAR through bsdtar to reclaim dead blocks
# left behind by tar --delete, then pipes clean stream to xz.
# bsdtar's @archive syntax re-emits only live entries without
# writing a second .tar to disk.
# Always repacks — guarantees clean output in all modes.
# ============================================================
compress_tar_to_xz() {
    local xz_opts
    xz_opts=$(build_xz_opts)

    log "INFO" "Repacking and compressing: ${STAGING_TAR} → ${STAGING_XZ}"

    local rc=0

    # shellcheck disable=SC2086
    if [[ "${HAS_PV}" == true ]]; then
        bsdtar -cf - "@${STAGING_TAR}" | pv | xz ${xz_opts} > "${STAGING_XZ}" || rc=$?
    else
        bsdtar -cf - "@${STAGING_TAR}" | xz ${xz_opts} > "${STAGING_XZ}" || rc=$?
    fi

    if (( rc != 0 )); then
        log "ERROR" "Repack/compression failed (rc=${rc})"
        return 1
    fi

    log "DEBUG" "Compression complete: $(du -sh "${STAGING_XZ}" 2>/dev/null | cut -f1)"
    return 0
}

# ============================================================
# main
# ============================================================
main() {
    parse_args "$@"
    load_temp_dir
    detect_tools
    resolve_output_path
    resolve_staging_paths

    # ---- Require tar for --delete ----
    if [[ "${HAS_TAR}" != true ]]; then
        echo "ERROR: tar is required but not found." >&2
        exit 2
    fi

    # ---- Require bsdtar for clean block reclamation after tar --delete ----
    if [[ "${HAS_BSDTAR}" != true ]]; then
        echo "ERROR: bsdtar is required but not found." >&2
        echo "       Install with: apt-get install libarchive-tools" >&2
        exit 2
    fi

    # ---- Clobber check ----
    if [[ -f "${OPT_OUTPUT}" ]] && [[ "${OPT_CLOBBER}" != true ]]; then
        echo "ERROR: Output already exists (use -O to overwrite): ${OPT_OUTPUT}" >&2
        exit 2
    fi

    # ---- Detect resume mode ----
    if [[ -f "${STAGING_TAR}" ]]; then
        RESUME_MODE=true
        log "INFO" "Staging tar found — resuming: ${STAGING_TAR}"
    fi

    # ---- Build directory list (unless -C) ----
    local dir_list=()
    if [[ "${OPT_CONTINUE}" != true ]] && [[ -n "${OPT_DIRS}" ]]; then
        build_dir_list dir_list
        if (( ${#dir_list[@]} == 0 )); then
            echo "ERROR: No valid directories parsed from: ${OPT_DIRS}" >&2
            exit 2
        fi
    fi

    log "INFO" "strip_archive.sh starting"
    log "INFO" "  Archive   : ${OPT_ARCHIVE}"
    log "INFO" "  Dirs      : ${dir_list[*]:-<none — compress-only>}"
    log "INFO" "  Prefix    : ${OPT_PREFIX:-<none>}"
    log "INFO" "  Output    : ${OPT_OUTPUT}"
    log "INFO" "  Resume    : ${RESUME_MODE}"
    log "INFO" "  Continue  : ${OPT_CONTINUE}"
    log "INFO" "  XZ level  : ${OPT_XZ_LEVEL}$([[ "${OPT_XZ_EXTREME}" == true ]] && echo " --extreme" || true)"
    log "INFO" "  Threads   : ${OPT_XZ_THREADS}"
    log "INFO" "  Clobber   : ${OPT_CLOBBER}"
    log "INFO" "  Delete    : ${OPT_DELETE}"
    log "INFO" "  Staging   : ${TEMP_DIR}"

    # ---- Step 1: Decompress (skip if staging tar exists) ----
    if [[ ! -f "${STAGING_TAR}" ]]; then
        if ! decompress_to_tar; then
            cleanup_staging
            exit 1
        fi
    else
        log "INFO" "Skipping decompression — using existing staging tar"
    fi

    # ---- Step 2: Delete directories (skip if -C) ----
    if [[ "${OPT_CONTINUE}" != true ]] && (( ${#dir_list[@]} > 0 )); then
        if ! delete_dirs_from_tar "${dir_list[@]}"; then
            # Preserve staging tar so the user can correct paths and resume
            log "INFO" "Staging tar preserved for resume: ${STAGING_TAR}"
            log "INFO" "Correct the path(s) above and re-run the same command to resume."
            exit 1
        fi
    else
        log "INFO" "Skipping tar --delete (compress-only mode)"
    fi

    # ---- Step 3: Compress raw tar to .tar.xz ----
    if ! compress_tar_to_xz; then
        cleanup_staging
        exit 1
    fi

    # ---- Step 4: Remove raw staging tar ----
    rm -f "${STAGING_TAR}"
    STAGING_TAR=""

    # ---- Step 5: Move output to destination ----
    log "INFO" "Moving to destination: ${OPT_OUTPUT}"
    mv "${STAGING_XZ}" "${OPT_OUTPUT}"
    STAGING_XZ=""

    # ---- Step 6: Optionally delete original ----
    if [[ "${OPT_DELETE}" == true ]]; then
        log "INFO" "Deleting original: ${OPT_ARCHIVE}"
        rm -f "${OPT_ARCHIVE}"
    fi

    log "INFO" "Done: ${OPT_ARCHIVE} → ${OPT_OUTPUT}"
}

main "$@"