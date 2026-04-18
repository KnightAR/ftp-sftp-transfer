#!/usr/bin/env bash
# ============================================================
# src/mysql/mysql_retention.sh — GFS S3 Retention Policy
#
# Implements a Grandfather-Father-Son (GFS) retention policy
# applied entirely on S3 via mc ls / mc rm.  No local files
# are involved.
#
# Tiers (applied per database prefix, most-recent kept per window):
#
#   age < DUMP_RETENTION_DAILY_DAYS (default 7)
#       → keep ALL backups  (daily window)
#
#   DAILY_DAYS ≤ age < 30 days
#       → keep ONE per ISO week  (most recent of that week)
#         Up to DUMP_RETENTION_WEEKLY_WEEKS weeks retained.
#
#   30 days ≤ age < 365 days
#       → keep ONE per calendar month (most recent of that month)
#         Up to DUMP_RETENTION_MONTHLY_MONTHS months retained.
#
#   age ≥ 365 days
#       → keep ONE per calendar year  (most recent of that year)
#         No maximum — kept indefinitely.
#
# When an .xz object is pruned its .sha256 sidecar is also removed.
#
# Provides:
#
#   run_gfs_retention DB_NAME
#       Main entry point.  Lists all .sql.xz objects under
#       S3_MYSQL_PREFIX/<db_name>/, classifies each, and prunes
#       objects that are superseded within their tier.
#
#   parse_backup_filename FILENAME OUT_DB OUT_DATE OUT_TIME
#       Extracts db name, YYYYMMDD date, and HHMM time from a
#       backup filename like db_20240115_0300.sql.xz
#       Returns 0 on success, 1 if the filename doesn't match.
#
#   gfs_classify AGE_DAYS OUT_TIER
#       Returns the tier name for a given age in days:
#       'daily', 'weekly', 'monthly', or 'yearly'.
#
# Globals consumed:
#   MC_ALIAS, S3_BUCKET, S3_MYSQL_PREFIX
#   DUMP_RETENTION_DAILY_DAYS   (default 7)
#   DUMP_RETENTION_WEEKLY_WEEKS (default 4)
#   DUMP_RETENTION_MONTHLY_MONTHS (default 12)
#   CLI_DRY_RUN
#   LOG_FILE, ERROR_LOG_FILE
#
# Dependency:
#   Must be sourced after src/core/logging.sh
# ============================================================

# ---------------------------------------------------------------------------
# parse_backup_filename FILENAME OUT_DB OUT_DATE OUT_TIME
#
# Parses filenames of the form:
#   <db>_YYYYMMDD_HHMM.sql.xz   (regular database)
#   _grants_YYYYMMDD_HHMM.sql.xz (grants pseudo-db)
#
# OUT_DB   → database name portion (may contain underscores)
# OUT_DATE → YYYYMMDD
# OUT_TIME → HHMM
# Returns 0 on success, 1 if format not recognised.
# ---------------------------------------------------------------------------
parse_backup_filename() {
    local filename="$1"        # basename only, e.g. mydb_20240115_0300.sql.xz
    local -n _out_db_ref="$2"
    local -n _out_date_ref="$3"
    local -n _out_time_ref="$4"

    # Strip .sql.xz extension
    local stem="${filename%.sql.xz}"
    # stem is now e.g. mydb_20240115_0300

    # The last two underscore-delimited tokens are HHMM and YYYYMMDD
    # Everything before is the db name (which may itself contain underscores)
    local _time="${stem##*_}"           # last token  → HHMM
    local _remainder="${stem%_*}"       # strip last token
    local _date="${_remainder##*_}"     # new last token → YYYYMMDD
    local _db="${_remainder%_*}"        # everything before → db name

    # Validate
    if [[ ! "${_date}" =~ ^[0-9]{8}$ ]] || [[ ! "${_time}" =~ ^[0-9]{4}$ ]]; then
        return 1
    fi

    _out_db_ref="${_db}"
    _out_date_ref="${_date}"
    _out_time_ref="${_time}"
    return 0
}

# ---------------------------------------------------------------------------
# _date_to_epoch YYYYMMDD → prints unix epoch seconds
# Uses GNU date.
# ---------------------------------------------------------------------------
_date_to_epoch() {
    local ymd="$1"
    local y="${ymd:0:4}"
    local m="${ymd:4:2}"
    local d="${ymd:6:2}"
    date -u -d "${y}-${m}-${d}" '+%s' 2>/dev/null || echo "0"
}

# ---------------------------------------------------------------------------
# _epoch_to_ymd EPOCH → prints YYYYMMDD
# ---------------------------------------------------------------------------
_epoch_to_ymd() {
    date -u -d "@$1" '+%Y%m%d' 2>/dev/null || echo "00000000"
}

# ---------------------------------------------------------------------------
# _iso_week YYYYMMDD → prints YYYY_WNN (ISO week key)
# ---------------------------------------------------------------------------
_iso_week() {
    local ymd="$1"
    local y="${ymd:0:4}" m="${ymd:4:2}" d="${ymd:6:2}"
    date -u -d "${y}-${m}-${d}" '+%G_W%V' 2>/dev/null || echo "0000_W00"
}

# ---------------------------------------------------------------------------
# _year_month YYYYMMDD → prints YYYYMM
# ---------------------------------------------------------------------------
_year_month() {
    echo "${1:0:6}"
}

# ---------------------------------------------------------------------------
# _year YYYYMMDD → prints YYYY
# ---------------------------------------------------------------------------
_year() {
    echo "${1:0:4}"
}

# ---------------------------------------------------------------------------
# gfs_classify AGE_DAYS OUT_TIER
#
# Sets OUT_TIER to: 'daily', 'weekly', 'monthly', or 'yearly'
# ---------------------------------------------------------------------------
gfs_classify() {
    local age_days="$1"
    local -n _tier_ref="$2"

    local daily_days="${DUMP_RETENTION_DAILY_DAYS:-7}"

    if (( age_days < daily_days )); then
        _tier_ref="daily"
    elif (( age_days < 30 )); then
        _tier_ref="weekly"
    elif (( age_days < 365 )); then
        _tier_ref="monthly"
    else
        _tier_ref="yearly"
    fi
}

# ---------------------------------------------------------------------------
# prune_s3_pair XZ_PATH
#
# Removes the .xz object and its .sha256 sidecar from S3.
# ---------------------------------------------------------------------------
prune_s3_pair() {
    local xz_s3_path="$1"
    local sha_s3_path="${xz_s3_path%.xz}.sha256"
    # sha path: strip .xz, the base is db_YYYYMMDD_HHMM.sql, append .sha256
    # Actually the sidecar is db_YYYYMMDD_HHMM.sql.sha256 (same base as sql)
    # xz_s3_path ends in .sql.xz, so sidecar is .sql.sha256
    local sha_s3_path2="${xz_s3_path%.xz}"          # → ...db_YYYYMMDD_HHMM.sql
    sha_s3_path2="${sha_s3_path2}.sha256"            # → ...db_YYYYMMDD_HHMM.sql.sha256

    if [[ "${CLI_DRY_RUN}" == true ]]; then
        log "INFO" "  GFS DRY-RUN: would prune ${xz_s3_path}"
        log "INFO" "  GFS DRY-RUN: would prune ${sha_s3_path2}"
        return 0
    fi

    log "INFO" "  GFS prune: ${xz_s3_path}"
    mc rm "${xz_s3_path}" 2>/dev/null || \
        log "WARN" "  GFS prune: failed to remove ${xz_s3_path} (may already be gone)"

    log "DEBUG" "  GFS prune sidecar: ${sha_s3_path2}"
    mc rm "${sha_s3_path2}" 2>/dev/null || true   # sidecar missing is non-fatal
}

# ---------------------------------------------------------------------------
# run_gfs_retention DB_NAME
#
# Main retention entry point for a single database (or _grants).
# Lists all .sql.xz objects, classifies by age, keeps most-recent
# per window, prunes the rest.
# ---------------------------------------------------------------------------
run_gfs_retention() {
    local db_name="$1"

    local daily_days="${DUMP_RETENTION_DAILY_DAYS:-7}"
    local weekly_weeks="${DUMP_RETENTION_WEEKLY_WEEKS:-4}"
    local monthly_months="${DUMP_RETENTION_MONTHLY_MONTHS:-12}"

    local s3_prefix="${MC_ALIAS}/${S3_BUCKET}/${S3_MYSQL_PREFIX}/${db_name}/"

    log "INFO" "run_gfs_retention: [${db_name}] listing objects at ${s3_prefix}"

    # List all .sql.xz objects; mc ls output format:
    #   [date] [time] [size] path/to/object.sql.xz
    local ls_output
    if ! ls_output=$(mc ls "${s3_prefix}" 2>/dev/null); then
        log "WARN" "run_gfs_retention: [${db_name}] could not list S3 prefix (may be empty) — skipping"
        return 0
    fi

    # Extract just .sql.xz filenames (basenames)
    local -a xz_files=()
    local _line _fname
    while IFS= read -r _line; do
        [[ -z "${_line}" ]] && continue
        _fname="${_line##* }"        # last whitespace-delimited token = object name
        _fname=$(basename "${_fname}")
        [[ "${_fname}" == *.sql.xz ]] || continue
        xz_files+=("${_fname}")
    done <<< "${ls_output}"

    if (( ${#xz_files[@]} == 0 )); then
        log "INFO" "run_gfs_retention: [${db_name}] no .sql.xz objects found — nothing to do"
        return 0
    fi

    log "INFO" "run_gfs_retention: [${db_name}] found ${#xz_files[@]} backup(s)"

    # Today's epoch for age calculation
    local today_epoch
    today_epoch=$(date -u '+%s')

    # Classify each file and collect into tier buckets
    # Each bucket maps window_key → "most_recent_datetime most_recent_fname"
    declare -A daily_keep=()    # date key YYYYMMDD → fname (all kept, just track)
    declare -A weekly_keep=()   # week key YYYY_WNN → YYYYMMDDHHMM:fname
    declare -A monthly_keep=()  # month key YYYYMM  → YYYYMMDDHHMM:fname
    declare -A yearly_keep=()   # year key YYYY     → YYYYMMDDHHMM:fname
    local -a to_prune=()

    local fname file_date file_time _db_unused
    for fname in "${xz_files[@]}"; do
        if ! parse_backup_filename "${fname}" _db_unused file_date file_time; then
            log "WARN" "run_gfs_retention: [${db_name}] unrecognised filename: ${fname} — skipping"
            continue
        fi

        local file_epoch
        file_epoch=$(_date_to_epoch "${file_date}")
        local age_days=$(( (today_epoch - file_epoch) / 86400 ))

        local tier
        gfs_classify "${age_days}" tier

        local datetime_key="${file_date}${file_time}"   # YYYYMMDDHHMM — lexicographic sort safe

        case "${tier}" in
            daily)
                # Keep all daily backups unconditionally
                daily_keep["${file_date}"]="${datetime_key}:${fname}"
                log "DEBUG" "run_gfs_retention: [${db_name}] KEEP daily age=${age_days}d ${fname}"
                ;;
            weekly)
                local week_key
                week_key=$(_iso_week "${file_date}")
                local max_weeks_ago=$(( daily_days + weekly_weeks * 7 ))
                if (( age_days > max_weeks_ago )); then
                    # Past the weekly retention window entirely — falls to monthly
                    # (shouldn't happen with proper tier boundaries, but guard anyway)
                    to_prune+=("${fname}")
                else
                    local current="${weekly_keep[${week_key}]:-}"
                    if [[ -z "${current}" ]] || [[ "${datetime_key}" > "${current%%:*}" ]]; then
                        # This file is more recent → it wins this week's slot
                        # The previous winner (if any) gets pruned
                        if [[ -n "${current}" ]]; then
                            to_prune+=("${current##*:}")
                            log "DEBUG" "run_gfs_retention: [${db_name}] week ${week_key} superseded: ${current##*:}"
                        fi
                        weekly_keep["${week_key}"]="${datetime_key}:${fname}"
                        log "DEBUG" "run_gfs_retention: [${db_name}] KEEP weekly ${week_key} ${fname}"
                    else
                        # Current winner is more recent — prune this file
                        to_prune+=("${fname}")
                        log "DEBUG" "run_gfs_retention: [${db_name}] week ${week_key} pruning older: ${fname}"
                    fi
                fi
                ;;
            monthly)
                local month_key
                month_key=$(_year_month "${file_date}")
                local max_months_ago=$(( monthly_months * 31 ))
                if (( age_days > max_months_ago )); then
                    # Past monthly window — falls to yearly
                    local year_key
                    year_key=$(_year "${file_date}")
                    local current="${yearly_keep[${year_key}]:-}"
                    if [[ -z "${current}" ]] || [[ "${datetime_key}" > "${current%%:*}" ]]; then
                        if [[ -n "${current}" ]]; then
                            to_prune+=("${current##*:}")
                        fi
                        yearly_keep["${year_key}"]="${datetime_key}:${fname}"
                        log "DEBUG" "run_gfs_retention: [${db_name}] KEEP yearly ${year_key} ${fname}"
                    else
                        to_prune+=("${fname}")
                    fi
                else
                    local current="${monthly_keep[${month_key}]:-}"
                    if [[ -z "${current}" ]] || [[ "${datetime_key}" > "${current%%:*}" ]]; then
                        if [[ -n "${current}" ]]; then
                            to_prune+=("${current##*:}")
                            log "DEBUG" "run_gfs_retention: [${db_name}] month ${month_key} superseded: ${current##*:}"
                        fi
                        monthly_keep["${month_key}"]="${datetime_key}:${fname}"
                        log "DEBUG" "run_gfs_retention: [${db_name}] KEEP monthly ${month_key} ${fname}"
                    else
                        to_prune+=("${fname}")
                        log "DEBUG" "run_gfs_retention: [${db_name}] month ${month_key} pruning older: ${fname}"
                    fi
                fi
                ;;
            yearly)
                local year_key
                year_key=$(_year "${file_date}")
                local current="${yearly_keep[${year_key}]:-}"
                if [[ -z "${current}" ]] || [[ "${datetime_key}" > "${current%%:*}" ]]; then
                    if [[ -n "${current}" ]]; then
                        to_prune+=("${current##*:}")
                        log "DEBUG" "run_gfs_retention: [${db_name}] year ${year_key} superseded: ${current##*:}"
                    fi
                    yearly_keep["${year_key}"]="${datetime_key}:${fname}"
                    log "DEBUG" "run_gfs_retention: [${db_name}] KEEP yearly ${year_key} ${fname}"
                else
                    to_prune+=("${fname}")
                    log "DEBUG" "run_gfs_retention: [${db_name}] year ${year_key} pruning older: ${fname}"
                fi
                ;;
        esac
    done

    # Summary before pruning
    local n_keep=$(( ${#xz_files[@]} - ${#to_prune[@]} ))
    log "INFO" "run_gfs_retention: [${db_name}] keeping=${n_keep} pruning=${#to_prune[@]}"

    if (( ${#to_prune[@]} == 0 )); then
        log "INFO" "run_gfs_retention: [${db_name}] nothing to prune"
        return 0
    fi

    # Prune
    local prune_fname
    for prune_fname in "${to_prune[@]}"; do
        prune_s3_pair "${s3_prefix}${prune_fname}"
    done

    log "INFO" "run_gfs_retention: [${db_name}] retention complete — pruned ${#to_prune[@]} backup(s)"
    return 0
}