#!/usr/bin/env bash
# ============================================================
# mysql_dump_zpaq.sh — MySQL Dump, S3 Upload, and zpaqfranz Archive
#
# Dumps all (or specified) MySQL databases, compresses each with xz
# and pipes directly to S3 via mc, then adds the raw .sql files to a
# persistent multipart zpaqfranz archive for long-term deduplicated
# storage.
#
# Backup flow (combined mode — default):
#   For each database:
#     1. mysqldump → <db>/<db>_YYYYMMDD_HHMM.sql   (raw, ZFS compresses on-disk)
#        tee → sha256 of raw stream → .sql.sha256
#     2. xz -6 -T1 | mc pipe → S3 mysql/<db>/<db>_YYYYMMDD_HHMM.sql.xz
#        mc cp sha256 sidecar → S3 mysql/<db>/<db>_YYYYMMDD_HHMM.sql.sha256
#   After ALL databases dumped + uploaded:
#     3. zpaqfranz a <hostname>??????? <all .sql files>
#        mc cp new .zpaq part → S3 zpaq/
#        delete all .sql files
#
# Backup flow (normal mode):
#   For each database: phases 1 → 2 → 3 individually, then next DB.
#
# Retention:
#   GFS policy applied to S3 xz objects after backup completes.
#   - Daily:   keep all for 7 days
#   - Weekly:  keep most-recent per ISO week for 4 weeks after daily window
#   - Monthly: keep most-recent per month for 12 months after weekly window
#   - Yearly:  keep most-recent per year, indefinitely
#
# Version : 1.0.0
# Requires: mysqldump, mysqladmin, xz, mc (MinIO client), zpaqfranz,
#           sha256sum, ionice, nice, python3
#
# Usage:
#   ./mysql_dump_zpaq.sh [OPTIONS]
#
# Options:
#   -c FILE      Config file                          (default: mysql_dump.conf)
#   -H HOST      MySQL host override
#   -P PORT      MySQL port override
#   -u USER      MySQL username override
#   -p PASS      MySQL password override
#   -d DB[,DB]   Comma-separated list of databases to dump (overrides config)
#   -m MODE      Backup mode: 'combined' or 'normal'  (default: combined)
#   -dry-run     Show what would happen; make no changes
#   -v           Verbose / DEBUG logging
#   -h           Show this help
#
# Config file: mysql_dump.conf (see mysql_dump.conf.example)
# Log file:    LOG_DIR/mysql_dump_YYYYMMDD_HHMMSS.log
#
# Environment variable overrides:
#   Any config variable can be set as an environment variable.
#   Environment variables take precedence over the config file.
#   This is the recommended approach for Docker deployments.
# ============================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ============================================================
# Source modules
# ============================================================
# shellcheck source=src/core/logging.sh
source "${SCRIPT_DIR}/src/core/logging.sh"
# shellcheck source=src/zpaq/zpaq_utils.sh
source "${SCRIPT_DIR}/src/zpaq/zpaq_utils.sh"
# shellcheck source=src/mysql/mysql_dump_ops.sh
source "${SCRIPT_DIR}/src/mysql/mysql_dump_ops.sh"
# shellcheck source=src/mysql/mysql_retention.sh
source "${SCRIPT_DIR}/src/mysql/mysql_retention.sh"
# shellcheck source=src/mysql/mysql_zpaq_ops.sh
source "${SCRIPT_DIR}/src/mysql/mysql_zpaq_ops.sh"

# ============================================================
# Script globals
# ============================================================
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# CLI options
CLI_CONFIG="${SCRIPT_DIR}/mysql_dump.conf"
CLI_MYSQL_HOST=""
CLI_MYSQL_PORT=""
CLI_MYSQL_USER=""
CLI_MYSQL_PASS=""
CLI_DATABASES=()      # -d DB[,DB,...] — may be comma-separated
CLI_MODE=""           # 'combined' or 'normal'
CLI_DRY_RUN=false
CLI_VERBOSE=false

# Runtime state
LOG_FILE=""
ERROR_LOG_FILE=""
LOG_DIR=""
RUN_TIMESTAMP=""
RUN_DIR=""            # DUMP_TMPDIR/<run_timestamp> — ephemeral per-run working dir
BACKUP_HOSTNAME=""    # resolved from config/env/hostname

# Per-run stats
STAT_DB_TOTAL=0
STAT_DB_DUMPED=0
STAT_DB_UPLOADED=0
STAT_DB_ZPAQD=0
STAT_DB_FAILED=0
STAT_DB_SKIPPED=0

# Per-db result tracking: associative array db_name → "OK"|"FAILED"|"SKIPPED"
declare -A DB_RESULTS=()

# Cached mysqldump --help output — populated once on first dump, reused for all
# subsequent databases to avoid re-probing the binary on every call.
_MYSQLDUMP_CAPS=""

# ============================================================
# usage
# ============================================================
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Dumps MySQL databases, compresses and uploads to S3, archives to zpaqfranz.

Options:
  -c FILE      Config file                          (default: mysql_dump.conf)
  -H HOST      MySQL host override
  -P PORT      MySQL port override
  -u USER      MySQL username override
  -p PASS      MySQL password override
  -d DB[,DB]   Comma-separated databases to dump    (default: all minus ignored)
  -m MODE      Backup mode: combined or normal       (default: combined)
  -dry-run     Show what would happen; make no changes
  -v           Verbose / DEBUG output
  -h           Show this help and exit

Config variables (mysql_dump.conf or environment):
  MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASS
  MYSQL_DATABASES         (bash array; empty = all databases)
  MYSQL_IGNORE_DATABASES  (bash array; default: system databases)
  DUMP_GRANTS             (true/false; default: true)
  MC_ALIAS, S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY
  S3_BUCKET, S3_INSECURE, S3_MYSQL_PREFIX, S3_ZPAQ_PREFIX
  ZPAQ_LOCAL_DIR, ZPAQ_METHOD, ZPAQ_FRAGMENT
  BACKUP_HOSTNAME         (zpaq archive basename; default: hostname)
  DUMP_TMPDIR, DUMP_MODE
  DUMP_XZ_LEVEL, DUMP_XZ_THREADS, DUMP_XZ_MAX_SIZE_GB
  LOG_DIR, LOG_RETENTION_DAYS

See mysql_dump.conf.example for full documentation.
EOF
}

# ============================================================
# Argument parsing
# ============================================================
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -c)         CLI_CONFIG="$2";        shift 2 ;;
            -H)         CLI_MYSQL_HOST="$2";    shift 2 ;;
            -P)         CLI_MYSQL_PORT="$2";    shift 2 ;;
            -u)         CLI_MYSQL_USER="$2";    shift 2 ;;
            -p)         CLI_MYSQL_PASS="$2";    shift 2 ;;
            -d)
                # Support comma-separated or repeated -d flags
                IFS=',' read -ra _dbs <<< "$2"
                CLI_DATABASES+=("${_dbs[@]}")
                shift 2
                ;;
            -m)         CLI_MODE="$2";          shift 2 ;;
            -dry-run)   CLI_DRY_RUN=true;       shift   ;;
            -v)         CLI_VERBOSE=true;        shift   ;;
            -h|--help)  usage; exit 0           ;;
            -*)
                echo "ERROR: Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
            *)
                echo "ERROR: Unexpected argument: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

# ============================================================
# Config loading
# ============================================================
load_dump_config() {
    # Source config file if present
    if [[ -f "${CLI_CONFIG}" ]]; then
        local perms
        perms=$(stat -c "%a" "${CLI_CONFIG}")
        if [[ "${perms}" != "600" && "${perms}" != "400" ]]; then
            echo "WARNING: Config file '${CLI_CONFIG}' has permissions ${perms}. Credentials may be exposed. Run: chmod 600 '${CLI_CONFIG}'" >&2
        fi
        # shellcheck source=/dev/null
        source "${CLI_CONFIG}"
    else
        echo "WARNING: Config file not found: ${CLI_CONFIG} — using environment variables and built-in defaults" >&2
    fi

    # CLI flags override config/env
    [[ -n "${CLI_MYSQL_HOST}" ]] && MYSQL_HOST="${CLI_MYSQL_HOST}"
    [[ -n "${CLI_MYSQL_PORT}" ]] && MYSQL_PORT="${CLI_MYSQL_PORT}"
    [[ -n "${CLI_MYSQL_USER}" ]] && MYSQL_USER="${CLI_MYSQL_USER}"
    [[ -n "${CLI_MYSQL_PASS}" ]] && MYSQL_PASS="${CLI_MYSQL_PASS}"
    if (( ${#CLI_DATABASES[@]} > 0 )); then
        MYSQL_DATABASES=("${CLI_DATABASES[@]}")
    fi
    [[ -n "${CLI_MODE}" ]] && DUMP_MODE="${CLI_MODE}"

    # MySQL connection
    : "${MYSQL_HOST:=127.0.0.1}"
    : "${MYSQL_PORT:=3306}"
    : "${MYSQL_USER:=}"
    : "${MYSQL_PASS:=}"

    # Database lists
    # MYSQL_DATABASES may already be set as a bash array in config or empty
    if [[ ! -v MYSQL_DATABASES ]]; then
        MYSQL_DATABASES=()
    fi
    if [[ ! -v MYSQL_IGNORE_DATABASES ]]; then
        MYSQL_IGNORE_DATABASES=(information_schema mysql performance_schema sys)
    fi

    # Grants
    : "${DUMP_GRANTS:=true}"

    # S3 / mc
    : "${MC_ALIAS:=ovh}"
    : "${S3_ENDPOINT:=}"
    : "${S3_ACCESS_KEY:=}"
    : "${S3_SECRET_KEY:=}"
    : "${S3_BUCKET:=}"
    : "${S3_INSECURE:=}"
    : "${S3_MYSQL_PREFIX:=mysql}"
    : "${S3_ZPAQ_PREFIX:=zpaq}"

    # zpaq
    : "${ZPAQ_LOCAL_DIR:=}"
    : "${ZPAQ_METHOD:=5}"
    : "${ZPAQ_FRAGMENT:=3}"
    : "${ZPAQ_MULTIPART_QUESTION_MARKS:=7}"

    # Hostname for zpaq basename
    if [[ -z "${BACKUP_HOSTNAME:-}" ]]; then
        BACKUP_HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
    fi

    # Temp dir
    : "${DUMP_TMPDIR:=/tmp/mysql_dump}"
    : "${DUMP_SPACE_ESTIMATE_GB:=10}"
    : "${DUMP_SPACE_WARN_PCT:=80}"
    : "${DUMP_SPACE_ABORT_PCT:=95}"

    # Compression
    : "${DUMP_XZ_LEVEL:=6}"
    : "${DUMP_XZ_THREADS:=1}"
    : "${DUMP_XZ_MAX_SIZE_GB:=50}"

    # Mode
    : "${DUMP_MODE:=combined}"

    # MySQL healthcheck
    : "${DUMP_MYSQL_PING_RETRIES:=5}"
    : "${DUMP_MYSQL_PING_SLEEP:=10}"

    # Retention
    : "${DUMP_RETENTION_DAILY_DAYS:=7}"
    : "${DUMP_RETENTION_WEEKLY_WEEKS:=4}"
    : "${DUMP_RETENTION_MONTHLY_MONTHS:=12}"

    # Logging
    : "${LOG_DIR:=}"
    : "${LOG_RETENTION_DAYS:=30}"

    # Sync MZDUMP manifest globals with resolved config
    MZDUMP_MANIFEST_FRAGMENT="${ZPAQ_FRAGMENT}"
    MZDUMP_MANIFEST_METHOD="${ZPAQ_METHOD}"
    MZDUMP_MANIFEST_QUESTION_MARKS="${ZPAQ_MULTIPART_QUESTION_MARKS}"
}

# ============================================================
# Config validation
# ============================================================
validate_dump_config() {
    local errors=0

    _require_var() {
        local var_name="$1"
        if [[ -z "${!var_name:-}" ]]; then
            echo "ERROR: Required variable '${var_name}' is not set." >&2
            (( errors++ )) || true
        fi
    }

    _require_var "MYSQL_HOST"
    _require_var "MYSQL_USER"
    _require_var "MYSQL_PASS"
    _require_var "S3_ENDPOINT"
    _require_var "S3_ACCESS_KEY"
    _require_var "S3_SECRET_KEY"
    _require_var "S3_BUCKET"
    _require_var "ZPAQ_LOCAL_DIR"
    _require_var "BACKUP_HOSTNAME"

    if (( errors > 0 )); then
        echo "ERROR: ${errors} required variable(s) missing. Check ${CLI_CONFIG} or environment." >&2
        exit 1
    fi

    if [[ "${DUMP_MODE}" != "combined" && "${DUMP_MODE}" != "normal" ]]; then
        echo "ERROR: DUMP_MODE must be 'combined' or 'normal', got: '${DUMP_MODE}'" >&2
        exit 1
    fi

    if ! [[ "${MYSQL_PORT}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: MYSQL_PORT must be a number, got: '${MYSQL_PORT}'" >&2
        exit 1
    fi

    if ! [[ "${DUMP_XZ_LEVEL}" =~ ^[1-9]$ ]]; then
        echo "ERROR: DUMP_XZ_LEVEL must be 1-9, got: '${DUMP_XZ_LEVEL}'" >&2
        exit 1
    fi
}

# ============================================================
# Logging setup
# ============================================================
setup_dump_logging() {
    local log_dir
    if [[ -n "${LOG_DIR}" ]]; then
        log_dir="${LOG_DIR}"
    else
        log_dir="${ZPAQ_LOCAL_DIR}/logs"
    fi
    mkdir -p "${log_dir}"
    LOG_DIR="${log_dir}"

    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    LOG_FILE="${log_dir}/mysql_dump_${ts}.log"
    ERROR_LOG_FILE="${log_dir}/mysql_dump_errors_$(date '+%Y%m%d').log"
    touch "${LOG_FILE}" "${ERROR_LOG_FILE}"

    # Rotate logs older than LOG_RETENTION_DAYS
    find "${log_dir}" -name "mysql_dump_*.log" \
        -mtime +"${LOG_RETENTION_DAYS:-30}" -delete 2>/dev/null || true

    log "DEBUG" "setup_dump_logging: log=${LOG_FILE}"
}

# ============================================================
# Working directory setup
# ============================================================
setup_run_dirs() {
    RUN_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
    RUN_DIR="${DUMP_TMPDIR}/${RUN_TIMESTAMP}"
    mkdir -p "${RUN_DIR}"
    log "INFO" "setup_run_dirs: run_dir=${RUN_DIR}"

    # Ensure zpaq local dir exists
    mkdir -p "${ZPAQ_LOCAL_DIR}"
}

# ============================================================
# Cleanup on exit / signal
# ============================================================
trap_cleanup() {
    local exit_code=$?
    log "DEBUG" "trap_cleanup: exit_code=${exit_code}"

    # Remove the per-run SQL dump directory (ZFS dataset — ephemeral)
    if [[ -n "${RUN_DIR}" && -d "${RUN_DIR}" ]]; then
        log "INFO" "trap_cleanup: removing run dir ${RUN_DIR}"
        rm -rf "${RUN_DIR}" 2>/dev/null || true
    fi
}

# ============================================================
# Dependency check
# ============================================================
check_dependencies() {
    local missing=0
    local dep
    for dep in mysqldump mysqladmin xz mc sha256sum ionice nice python3; do
        if ! command -v "${dep}" &>/dev/null; then
            log "ERROR" "Missing required dependency: ${dep}"
            (( missing++ )) || true
        fi
    done

    # zpaqfranz checked separately via detect_zpaqfranz()
    if (( missing > 0 )); then
        log "ERROR" "${missing} required dependency/dependencies missing — aborting"
        exit 2
    fi
}

# ============================================================
# Run timestamp for filenames (set once per run)
# ============================================================
dump_timestamp() {
    # Format: YYYYMMDD_HHMM — date + hour + minute only.
    # Multiple backups on the same day get different filenames.
    # Seconds deliberately omitted so retention date parsing is unambiguous.
    date '+%Y%m%d_%H%M'
}

# ============================================================
# process_one_db — dump + upload one database (both modes)
#
# Populates DB_RESULTS[db_name] with "DUMPED_OK" or "FAILED".
# SQL file left on disk; caller decides when to run zpaq/delete.
# Returns 0 if both dump and upload succeeded, 1 otherwise.
# ============================================================
process_one_db() {
    local db_name="$1"
    local ts="$2"

    (( STAT_DB_TOTAL++ )) || true

    log "INFO" "===== [${db_name}] Starting backup ====="

    # Phase 1: Dump
    # NOTE: variable names here must NOT match any 'local' variable inside
    # dump_database() or dump_grants() — bash nameref resolves to the nearest
    # scope with that name, causing a circular reference if names collide.
    # dump_database/dump_grants both use internal locals named 'sql_file' and
    # 'sha_file', so we use distinct names here.
    local _db_sql_out="" _db_sha_out=""
    local dump_rc=0

    if [[ "${db_name}" == "_grants" ]]; then
        dump_grants "${RUN_DIR}" "${ts}" _db_sql_out _db_sha_out || dump_rc=$?
    else
        dump_database "${db_name}" "${RUN_DIR}" "${ts}" _db_sql_out _db_sha_out || dump_rc=$?
    fi

    if (( dump_rc != 0 )); then
        log "ERROR" "[${db_name}] Dump failed"
        DB_RESULTS["${db_name}"]="FAILED:dump"
        (( STAT_DB_FAILED++ )) || true
        return 1
    fi

    (( STAT_DB_DUMPED++ )) || true

    # Record size in history for future disk space estimates
    if [[ "${CLI_DRY_RUN}" == false && -f "${_db_sql_out}" ]]; then
        local sql_size
        sql_size=$(stat -c "%s" "${_db_sql_out}" 2>/dev/null || echo 0)
        _DUMP_SIZE_HISTORY["${db_name}"]="${sql_size}"
    fi

    # Phase 2: xz → S3
    local upload_rc=0
    upload_xz_to_s3 "${_db_sql_out}" "${db_name}" "${ts}" || upload_rc=$?

    if (( upload_rc != 0 )); then
        log "ERROR" "[${db_name}] S3 upload failed"
        DB_RESULTS["${db_name}"]="FAILED:upload"
        (( STAT_DB_FAILED++ )) || true
        return 1
    fi

    (( STAT_DB_UPLOADED++ )) || true
    DB_RESULTS["${db_name}"]="DUMPED_OK"
    log "INFO" "===== [${db_name}] Dump + upload complete ====="
    return 0
}

# ============================================================
# run_zpaq_phase — Phase 3: zpaqfranz add + upload new part
#
# Adds all SQL files for databases in GOOD_DBS_ARRAY to the archive.
# ============================================================
run_zpaq_phase() {
    local -n _good_dbs_ref="$1"

    if (( ${#_good_dbs_ref[@]} == 0 )); then
        log "WARN" "run_zpaq_phase: no successfully dumped databases — skipping zpaq"
        return 0
    fi

    # Collect SQL file paths
    local -a sql_files=()
    local db
    for db in "${_good_dbs_ref[@]}"; do
        # Find the .sql file for this db under RUN_DIR
        local found
        found=$(find "${RUN_DIR}/${db}" -maxdepth 1 -name "*.sql" 2>/dev/null | head -1)
        if [[ -z "${found}" ]]; then
            log "WARN" "run_zpaq_phase: .sql file not found for ${db} — skipping from zpaq"
            continue
        fi
        sql_files+=("${found}")
        log "DEBUG" "run_zpaq_phase: queuing ${found}"
    done

    if (( ${#sql_files[@]} == 0 )); then
        log "WARN" "run_zpaq_phase: no .sql files found — skipping zpaq add"
        return 0
    fi

    log "INFO" "run_zpaq_phase: adding ${#sql_files[@]} file(s) to zpaq archive"

    # Phase 3a: zpaqfranz add
    local add_rc=0
    mysql_zpaq_add "${RUN_DIR}" sql_files || add_rc=$?

    if (( add_rc != 0 )); then
        log "ERROR" "run_zpaq_phase: zpaqfranz add failed"
        return 1
    fi

    if [[ "${CLI_DRY_RUN}" == true ]]; then
        log "INFO" "run_zpaq_phase: DRY-RUN — skipping part upload and manifest update"
        return 0
    fi

    # Phase 3b: Find new part
    local new_part=""
    if ! mysql_zpaq_find_new_part new_part; then
        log "ERROR" "run_zpaq_phase: could not locate new .zpaq part"
        return 1
    fi

    local part_name
    part_name=$(basename "${new_part}")
    local part_size
    part_size=$(stat -c "%s" "${new_part}")
    local part_sha256
    part_sha256=$(sha256sum "${new_part}" | awk '{print $1}')

    log "INFO" "run_zpaq_phase: new part: ${part_name} ($(( part_size / 1024 / 1024 ))MB)"

    # Phase 3c: Upload part to S3
    local upload_rc=0
    mysql_zpaq_upload_part "${new_part}" || upload_rc=$?

    if (( upload_rc != 0 )); then
        log "ERROR" "run_zpaq_phase: part upload failed — part retained locally: ${new_part}"
        return 1
    fi

    # Phase 3d: Update manifest
    (( MZDUMP_MANIFEST_TOTAL_PARTS++ )) || true
    MZDUMP_MANIFEST_TOTAL_SIZE=$(( MZDUMP_MANIFEST_TOTAL_SIZE + part_size ))

    local manifest_path
    manifest_path="${ZPAQ_LOCAL_DIR}/${BACKUP_HOSTNAME}.manifest.json"

    mysql_zpaq_write_manifest \
        "${manifest_path}" \
        "${part_name}" \
        "${part_size}" \
        "${part_sha256}"

    # Phase 3e: Upload manifest to S3 (non-fatal)
    mysql_zpaq_upload_manifest "${manifest_path}" || true

    (( STAT_DB_ZPAQD += ${#sql_files[@]} )) || true

    log "INFO" "run_zpaq_phase: zpaq phase complete — total parts: ${MZDUMP_MANIFEST_TOTAL_PARTS}"
    return 0
}

# ============================================================
# cleanup_sql_files — delete all .sql files from RUN_DIR
# ============================================================
cleanup_sql_files() {
    local -n _dbs_cleanup_ref="$1"
    local db
    for db in "${_dbs_cleanup_ref[@]}"; do
        local db_dir="${RUN_DIR}/${db}"
        if [[ -d "${db_dir}" ]]; then
            find "${db_dir}" -maxdepth 1 -name "*.sql" -delete 2>/dev/null || true
            log "DEBUG" "cleanup_sql_files: removed .sql files for ${db}"
        fi
    done
}

# ============================================================
# run_combined_mode
# ============================================================
run_combined_mode() {
    local -n _db_list_comb_ref="$1"
    local ts="$2"

    log "INFO" "===== COMBINED MODE: dumping ${#_db_list_comb_ref[@]} database(s) ====="

    local -a good_dbs=()
    local db
    for db in "${_db_list_comb_ref[@]}"; do
        local db_rc=0
        process_one_db "${db}" "${ts}" || db_rc=$?
        if (( db_rc == 0 )); then
            good_dbs+=("${db}")
        fi
        # Continue regardless of per-db failure
    done

    if (( ${#good_dbs[@]} == 0 )); then
        log "ERROR" "run_combined_mode: all database backups failed — skipping zpaq phase"
        return 1
    fi

    log "INFO" "run_combined_mode: ${#good_dbs[@]}/${#_db_list_comb_ref[@]} database(s) ready for zpaq"

    # Single combined zpaqfranz add for all good databases
    local zpaq_rc=0
    run_zpaq_phase good_dbs || zpaq_rc=$?

    # Clean up SQL files regardless of zpaq result
    cleanup_sql_files good_dbs

    if (( zpaq_rc != 0 )); then
        log "ERROR" "run_combined_mode: zpaq phase failed"
        # Mark all good_dbs as zpaq-failed
        local _db
        for _db in "${good_dbs[@]}"; do
            DB_RESULTS["${_db}"]="FAILED:zpaq"
            (( STAT_DB_FAILED++ )) || true
        done
        return 1
    fi

    # Mark all successfully zpaq'd databases as OK
    local _db
    for _db in "${good_dbs[@]}"; do
        DB_RESULTS["${_db}"]="OK"
    done

    return 0
}

# ============================================================
# run_normal_mode
# ============================================================
run_normal_mode() {
    local -n _db_list_norm_ref="$1"
    local ts="$2"

    log "INFO" "===== NORMAL MODE: processing ${#_db_list_norm_ref[@]} database(s) one by one ====="

    local db
    for db in "${_db_list_norm_ref[@]}"; do
        local db_rc=0
        process_one_db "${db}" "${ts}" || db_rc=$?

        if (( db_rc != 0 )); then
            log "WARN" "run_normal_mode: [${db}] dump/upload failed — skipping zpaq for this db"
            continue
        fi

        # zpaq each db individually
        local -a single_db=("${db}")
        local zpaq_rc=0
        run_zpaq_phase single_db || zpaq_rc=$?

        # Always clean sql file after attempting zpaq
        cleanup_sql_files single_db

        if (( zpaq_rc != 0 )); then
            log "ERROR" "run_normal_mode: [${db}] zpaq phase failed"
            DB_RESULTS["${db}"]="FAILED:zpaq"
            (( STAT_DB_FAILED++ )) || true
        else
            DB_RESULTS["${db}"]="OK"
        fi
    done
}

# ============================================================
# run_retention — run GFS retention for all databases
# ============================================================
run_retention() {
    local -n _db_list_ret_ref="$1"

    log "INFO" "===== Running GFS S3 retention ====="

    local db
    for db in "${_db_list_ret_ref[@]}"; do
        local ret_rc=0
        run_gfs_retention "${db}" || ret_rc=$?
        if (( ret_rc != 0 )); then
            log "WARN" "run_retention: [${db}] retention encountered errors (non-fatal)"
        fi
    done

    log "INFO" "===== Retention complete ====="
}

# ============================================================
# print_summary
# ============================================================
print_summary() {
    local -n _db_list_sum_ref="$1"
    local start_epoch="$2"

    local end_epoch
    end_epoch=$(date '+%s')
    local elapsed=$(( end_epoch - start_epoch ))
    local elapsed_fmt
    elapsed_fmt=$(printf '%02d:%02d:%02d' \
        $(( elapsed / 3600 )) \
        $(( (elapsed % 3600) / 60 )) \
        $(( elapsed % 60 )))

    log "INFO" "=========================================="
    log "INFO" "  ${SCRIPT_NAME} summary"
    log "INFO" "=========================================="
    log "INFO" "  Host:               ${BACKUP_HOSTNAME}"
    log "INFO" "  Mode:               ${DUMP_MODE}"
    log "INFO" "  Elapsed:            ${elapsed_fmt}"
    log "INFO" "  Databases total:    ${STAT_DB_TOTAL}"
    log "INFO" "  Dumped OK:          ${STAT_DB_DUMPED}"
    log "INFO" "  Uploaded to S3:     ${STAT_DB_UPLOADED}"
    log "INFO" "  Added to zpaq:      ${STAT_DB_ZPAQD}"
    log "INFO" "  Failed:             ${STAT_DB_FAILED}"
    log "INFO" "  zpaq parts total:   ${MZDUMP_MANIFEST_TOTAL_PARTS}"
    log "INFO" "  zpaq archive size:  $(awk -v b="${MZDUMP_MANIFEST_TOTAL_SIZE}" \
        'BEGIN { printf "%.1f GB", b/1073741824 }')"
    log "INFO" "------------------------------------------"

    if (( ${#_db_list_sum_ref[@]} > 0 )); then
        log "INFO" "  Per-database results:"
        local db
        for db in "${_db_list_sum_ref[@]}"; do
            local result="${DB_RESULTS[${db}]:-UNKNOWN}"
            log "INFO" "    ${db}: ${result}"
        done
        log "INFO" "------------------------------------------"
    fi

    if (( STAT_DB_FAILED > 0 )); then
        log "ERROR" "  ${STAT_DB_FAILED} database(s) FAILED — check log: ${LOG_FILE}"
    else
        log "INFO" "  All databases completed successfully"
    fi
    log "INFO" "=========================================="
}

# ============================================================
# Main
# ============================================================

# Global size history for disk space estimation
declare -gA _DUMP_SIZE_HISTORY=()

main() {
    parse_args "$@"
    load_dump_config

    # Setup dirs early so logging has somewhere to write
    mkdir -p "${DUMP_TMPDIR}"
    mkdir -p "${ZPAQ_LOCAL_DIR}"
    setup_dump_logging

    local start_epoch
    start_epoch=$(date '+%s')

    log "INFO" "===== ${SCRIPT_NAME} starting ====="
    log "INFO" "host=${BACKUP_HOSTNAME} mode=${DUMP_MODE} dry-run=${CLI_DRY_RUN}"
    log "INFO" "mysql=${MYSQL_USER}@${MYSQL_HOST}:${MYSQL_PORT}"
    log "INFO" "s3=${MC_ALIAS}/${S3_BUCKET} mysql_prefix=${S3_MYSQL_PREFIX} zpaq_prefix=${S3_ZPAQ_PREFIX}"
    log "INFO" "xz: level=${DUMP_XZ_LEVEL} threads=${DUMP_XZ_THREADS}"
    log "INFO" "zpaq: method=${ZPAQ_METHOD} fragment=${ZPAQ_FRAGMENT} local=${ZPAQ_LOCAL_DIR}"

    validate_dump_config
    check_dependencies
    detect_zpaqfranz

    setup_run_dirs
    trap 'trap_cleanup' EXIT INT TERM

    # Load size history for disk space estimation
    local history_file="${ZPAQ_LOCAL_DIR}/${BACKUP_HOSTNAME}.size_history"
    load_size_history "${history_file}" _DUMP_SIZE_HISTORY

    # Load zpaq manifest
    mysql_zpaq_load_manifest

    # MySQL health check
    check_mysql_health

    # Setup mc alias
    setup_mc_alias

    # List databases to back up
    local -a db_list=()
    list_databases db_list

    if (( ${#db_list[@]} == 0 )); then
        log "WARN" "No databases to back up — exiting"
        exit 0
    fi

    # Add grants as pseudo-database if enabled
    if [[ "${DUMP_GRANTS:-true}" == "true" ]]; then
        db_list+=("_grants")
        log "INFO" "Grants backup enabled — added _grants to backup list"
    fi

    log "INFO" "Databases to back up (${#db_list[@]}): ${db_list[*]}"

    # Disk space check (combined mode needs all files simultaneously)
    check_dump_disk_space "${RUN_DIR}" db_list _DUMP_SIZE_HISTORY

    # RUN_TIMESTAMP is set in setup_run_dirs; use it for all filenames this run
    local ts
    ts=$(dump_timestamp)

    # Execute backup pipeline
    if [[ "${DUMP_MODE}" == "combined" ]]; then
        local combined_rc=0
        run_combined_mode db_list "${ts}" || combined_rc=$?
        if (( combined_rc != 0 )); then
            log "ERROR" "Combined mode encountered errors"
        fi
    else
        run_normal_mode db_list "${ts}"
    fi

    # Save updated size history
    save_size_history "${history_file}" _DUMP_SIZE_HISTORY

    # Run retention on S3 for all databases
    run_retention db_list

    # Print summary
    print_summary db_list "${start_epoch}"

    # Exit with error if any database failed
    if (( STAT_DB_FAILED > 0 )); then
        exit 1
    fi

    log "INFO" "===== ${SCRIPT_NAME} finished OK ====="
}

main "$@"