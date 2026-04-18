#!/usr/bin/env bash
# ============================================================
# src/mysql/mysql_dump_ops.sh — MySQL Dump, Upload, and Health Operations
#
# Provides:
#
#   check_mysql_health
#       Pings MySQL with mysqladmin, retrying DUMP_MYSQL_PING_RETRIES
#       times with DUMP_MYSQL_PING_SLEEP seconds between attempts.
#       Aborts (exit 1) if MySQL is unreachable after all retries.
#
#   list_databases OUT_ARRAY_NAME
#       Populates the named array with databases to back up.
#       If MYSQL_DATABASES[] is non-empty, uses that list (minus
#       MYSQL_IGNORE_DATABASES[]). Otherwise queries SHOW DATABASES.
#
#   setup_mc_alias
#       Checks whether MC_ALIAS exists in mc's config. If not, runs
#       mc alias set using S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY,
#       and --insecure if S3_INSECURE is set.
#
#   dump_database DB_NAME RUN_DIR OUT_SQL_FILE
#       Dumps DB_NAME to RUN_DIR/<db>/<db>_YYYYMMDD_HHMM.sql via
#       mysqldump, computing sha256 of the raw stream via tee.
#       Sets OUT_SQL_FILE to the path of the written .sql file.
#       Returns 0 on success, 1 on failure.
#
#   dump_grants RUN_DIR OUT_SQL_FILE
#       Dumps all user grants via SHOW GRANTS FOR each user to
#       RUN_DIR/_grants/_grants_YYYYMMDD_HHMM.sql.
#       Sets OUT_SQL_FILE to the path of the written .sql file.
#       Returns 0 on success, 1 on failure.
#
#   upload_xz_to_s3 SQL_FILE DB_NAME TIMESTAMP
#       Compresses SQL_FILE with xz and pipes directly to mc pipe.
#       Also uploads the .sha256 sidecar. Verifies the remote object
#       exists via mc stat after upload.
#       Returns 0 on success, 1 on failure.
#
#   check_dump_disk_space RUN_DIR DB_LIST_ARRAY_NAME
#       Estimates total space needed for all databases and checks
#       against available space on DUMP_TMPDIR filesystem.
#       Logs WARN at DUMP_SPACE_WARN_PCT, aborts at DUMP_SPACE_ABORT_PCT.
#       Returns 0 if safe to proceed, 1 if should abort.
#
#   load_size_history HISTORY_FILE OUT_ASSOC_ARRAY_NAME
#       Reads per-db size estimates from a key=value history file.
#
#   save_size_history HISTORY_FILE ASSOC_ARRAY_NAME
#       Writes per-db sizes to the history file.
#
# Globals consumed:
#   MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASS
#   MYSQL_IGNORE_DATABASES[], MYSQL_DATABASES[]
#   DUMP_MYSQL_PING_RETRIES, DUMP_MYSQL_PING_SLEEP
#   MC_ALIAS, S3_BUCKET, S3_MYSQL_PREFIX
#   S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY, S3_INSECURE
#   DUMP_XZ_LEVEL, DUMP_XZ_THREADS
#   DUMP_TMPDIR, DUMP_SPACE_ESTIMATE_GB
#   DUMP_SPACE_WARN_PCT, DUMP_SPACE_ABORT_PCT
#   CLI_DRY_RUN, CLI_VERBOSE
#   LOG_FILE, ERROR_LOG_FILE  (from logging.sh)
#
# Dependency:
#   Must be sourced after src/core/logging.sh
# ============================================================

# ---------------------------------------------------------------------------
# _mysql_args — build common mysql client argument array
# ---------------------------------------------------------------------------
_mysql_args() {
    local -n _args_ref="$1"
    _args_ref=(
        -h"${MYSQL_HOST}"
        -P"${MYSQL_PORT}"
        -u"${MYSQL_USER}"
        -p"${MYSQL_PASS}"
        --connect-timeout=10
    )
}

# ---------------------------------------------------------------------------
# check_mysql_health
# ---------------------------------------------------------------------------
check_mysql_health() {
    local retries="${DUMP_MYSQL_PING_RETRIES:-5}"
    local sleep_sec="${DUMP_MYSQL_PING_SLEEP:-10}"
    local attempt=1

    log "INFO" "check_mysql_health: pinging ${MYSQL_HOST}:${MYSQL_PORT} (max ${retries} attempts)"

    while (( attempt <= retries )); do
        if mysqladmin ping \
                -h"${MYSQL_HOST}" \
                -P"${MYSQL_PORT}" \
                -u"${MYSQL_USER}" \
                -p"${MYSQL_PASS}" \
                --connect-timeout=5 \
                --silent 2>/dev/null; then
            log "INFO" "check_mysql_health: MySQL is reachable (attempt ${attempt})"
            return 0
        fi
        log "WARN" "check_mysql_health: attempt ${attempt}/${retries} failed — waiting ${sleep_sec}s"
        sleep "${sleep_sec}"
        (( attempt++ )) || true
    done

    log "ERROR" "check_mysql_health: MySQL unreachable after ${retries} attempt(s) — aborting"
    return 1
}

# ---------------------------------------------------------------------------
# list_databases OUT_ARRAY_NAME
# Populates named array with databases to back up.
# ---------------------------------------------------------------------------
list_databases() {
    local -n _db_list_ref="$1"
    _db_list_ref=()

    local -a mysql_args=()
    _mysql_args mysql_args

    # Build ignore set for fast lookup
    local -A _ignore=()
    local _ign
    if [[ -v MYSQL_IGNORE_DATABASES ]] && (( ${#MYSQL_IGNORE_DATABASES[@]} > 0 )); then
        for _ign in "${MYSQL_IGNORE_DATABASES[@]}"; do
            [[ -n "${_ign}" ]] && _ignore["${_ign}"]=1
        done
    fi

    if [[ -v MYSQL_DATABASES ]] && (( ${#MYSQL_DATABASES[@]} > 0 )); then
        # Use explicitly specified list, minus ignored ones
        local _db
        for _db in "${MYSQL_DATABASES[@]}"; do
            if [[ -n "${_ignore[${_db}]:-}" ]]; then
                log "DEBUG" "list_databases: skipping ignored db: ${_db}"
                continue
            fi
            _db_list_ref+=("${_db}")
        done
        log "INFO" "list_databases: using explicit list: ${_db_list_ref[*]:-<none>}"
    else
        # Query server
        local _raw_list
        if ! _raw_list=$(mysql "${mysql_args[@]}" \
                --batch --skip-column-names \
                -e "SHOW DATABASES;" 2>/dev/null); then
            log "ERROR" "list_databases: SHOW DATABASES failed"
            return 1
        fi

        local _db
        while IFS= read -r _db; do
            [[ -z "${_db}" ]] && continue
            if [[ -n "${_ignore[${_db}]:-}" ]]; then
                log "DEBUG" "list_databases: skipping ignored db: ${_db}"
                continue
            fi
            _db_list_ref+=("${_db}")
        done <<< "${_raw_list}"

        log "INFO" "list_databases: found ${#_db_list_ref[@]} database(s) to back up"
    fi

    if (( ${#_db_list_ref[@]} == 0 )); then
        log "WARN" "list_databases: no databases to back up after filtering"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# setup_mc_alias
# Check if MC_ALIAS exists; create it if not.
# ---------------------------------------------------------------------------
setup_mc_alias() {
    log "INFO" "setup_mc_alias: checking alias '${MC_ALIAS}'"

    # mc alias ls <name> exits 0 if the alias exists
    if mc alias ls "${MC_ALIAS}" &>/dev/null; then
        log "INFO" "setup_mc_alias: alias '${MC_ALIAS}' already configured"
        return 0
    fi

    log "INFO" "setup_mc_alias: alias not found — creating"

    if [[ "${CLI_DRY_RUN}" == true ]]; then
        log "INFO" "setup_mc_alias: DRY-RUN — would create alias '${MC_ALIAS}' → ${S3_ENDPOINT}"
        return 0
    fi

    local _insecure_flag=""
    [[ -n "${S3_INSECURE:-}" ]] && _insecure_flag="--insecure"

    local _mc_alias_out _mc_alias_rc=0
    _mc_alias_out=$(mc alias set "${MC_ALIAS}" \
            "${S3_ENDPOINT}" \
            "${S3_ACCESS_KEY}" \
            "${S3_SECRET_KEY}" \
            ${_insecure_flag} 2>&1) || _mc_alias_rc=$?
    while IFS= read -r _line; do
        log "DEBUG" "mc alias set: ${_line}"
    done <<< "${_mc_alias_out}"
    if (( _mc_alias_rc != 0 )); then
        log "ERROR" "setup_mc_alias: failed to create mc alias '${MC_ALIAS}' (rc=${_mc_alias_rc})"
        return 1
    fi
    log "INFO" "setup_mc_alias: alias '${MC_ALIAS}' created successfully"

    # Verify it now exists
    if ! mc alias ls "${MC_ALIAS}" &>/dev/null; then
        log "ERROR" "setup_mc_alias: alias '${MC_ALIAS}' not found after creation"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# dump_database DB_NAME RUN_DIR TIMESTAMP OUT_VAR_SQL OUT_VAR_SHA256
#
# Dumps DB_NAME to RUN_DIR/<db>/<db>_<TIMESTAMP>.sql
# Computes sha256 of raw dump stream via tee, writes to .sha256 sidecar.
# Sets OUT_VAR_SQL and OUT_VAR_SHA256 to the output file paths.
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
dump_database() {
    local db_name="$1"
    local run_dir="$2"
    local timestamp="$3"
    local -n _out_sql_ref="$4"
    local -n _out_sha_ref="$5"

    local db_dir="${run_dir}/${db_name}"
    mkdir -p "${db_dir}"

    local sql_file="${db_dir}/${db_name}_${timestamp}.sql"
    local sha_file="${sql_file}.sha256"

    _out_sql_ref="${sql_file}"
    _out_sha_ref="${sha_file}"

    log "INFO" "dump_database: [${db_name}] → ${sql_file}"

    if [[ "${CLI_DRY_RUN}" == true ]]; then
        log "INFO" "dump_database: DRY-RUN — would dump ${db_name}"
        # Create empty placeholder files so downstream code can reference them
        touch "${sql_file}" "${sha_file}"
        return 0
    fi

    local -a mysql_dump_args=(
        -h"${MYSQL_HOST}"
        -P"${MYSQL_PORT}"
        -u"${MYSQL_USER}"
        -p"${MYSQL_PASS}"
        --single-transaction
        --routines
        --triggers
        --events
        --set-gtid-purged=OFF
        --default-character-set=utf8mb4
        "${db_name}"
    )

    # Dump: pipe through tee to capture sha256 of raw stream while writing to disk
    # The sha256sum process substitution writes the hash to the .sha256 file
    local dump_rc=0
    nice -n19 ionice -c3 \
        mysqldump "${mysql_dump_args[@]}" \
        2>>"${ERROR_LOG_FILE:-/dev/stderr}" \
        | tee >(sha256sum | awk '{print $1}' > "${sha_file}") \
        > "${sql_file}" \
        || dump_rc=$?

    # Wait briefly for the process substitution to finish writing sha_file
    local _wait=0
    while [[ ! -s "${sha_file}" ]] && (( _wait < 10 )); do
        sleep 0.2
        (( _wait++ )) || true
    done

    if (( dump_rc != 0 )); then
        log "ERROR" "dump_database: [${db_name}] mysqldump failed (rc=${dump_rc})"
        rm -f "${sql_file}" "${sha_file}"
        return 1
    fi

    if [[ ! -f "${sql_file}" ]] || [[ ! -s "${sql_file}" ]]; then
        log "ERROR" "dump_database: [${db_name}] output file missing or empty: ${sql_file}"
        rm -f "${sql_file}" "${sha_file}"
        return 1
    fi

    local sql_size
    sql_size=$(stat -c "%s" "${sql_file}")
    local sha_val
    sha_val=$(cat "${sha_file}" 2>/dev/null || echo "unknown")

    log "INFO" "dump_database: [${db_name}] OK — size=$(( sql_size / 1024 / 1024 ))MB sha256=${sha_val:0:16}..."
    return 0
}

# ---------------------------------------------------------------------------
# dump_grants RUN_DIR TIMESTAMP OUT_VAR_SQL OUT_VAR_SHA256
#
# Dumps all user grants to RUN_DIR/_grants/_grants_<TIMESTAMP>.sql
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
dump_grants() {
    local run_dir="$1"
    local timestamp="$2"
    local -n _out_sql_grants_ref="$3"
    local -n _out_sha_grants_ref="$4"

    local grants_dir="${run_dir}/_grants"
    mkdir -p "${grants_dir}"

    local sql_file="${grants_dir}/_grants_${timestamp}.sql"
    local sha_file="${sql_file}.sha256"

    _out_sql_grants_ref="${sql_file}"
    _out_sha_grants_ref="${sha_file}"

    log "INFO" "dump_grants: → ${sql_file}"

    if [[ "${CLI_DRY_RUN}" == true ]]; then
        log "INFO" "dump_grants: DRY-RUN — would dump grants"
        touch "${sql_file}" "${sha_file}"
        return 0
    fi

    local -a mysql_args=()
    _mysql_args mysql_args

    # Get list of user@host pairs
    local user_list
    if ! user_list=$(mysql "${mysql_args[@]}" \
            --batch --skip-column-names \
            -e "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user ORDER BY user, host;" \
            2>/dev/null); then
        log "ERROR" "dump_grants: failed to query mysql.user"
        return 1
    fi

    if [[ -z "${user_list}" ]]; then
        log "WARN" "dump_grants: no users found — writing empty grants file"
        echo "-- No users found at ${timestamp}" > "${sql_file}"
        echo "" | sha256sum | awk '{print $1}' > "${sha_file}"
        return 0
    fi

    {
        echo "-- MySQL Grants Dump"
        echo "-- Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "-- Host: ${MYSQL_HOST}:${MYSQL_PORT}"
        echo ""

        local user_host
        while IFS= read -r user_host; do
            [[ -z "${user_host}" ]] && continue
            echo "-- Grants for ${user_host}"
            mysql "${mysql_args[@]}" \
                --batch --skip-column-names \
                -e "SHOW GRANTS FOR ${user_host};" \
                2>/dev/null \
            | sed "s/$/;/"
            echo ""
        done <<< "${user_list}"

        echo "FLUSH PRIVILEGES;"
    } | tee >(sha256sum | awk '{print $1}' > "${sha_file}") \
      > "${sql_file}"

    # Wait for sha256 process substitution
    local _wait=0
    while [[ ! -s "${sha_file}" ]] && (( _wait < 10 )); do
        sleep 0.2
        (( _wait++ )) || true
    done

    if [[ ! -f "${sql_file}" ]] || [[ ! -s "${sql_file}" ]]; then
        log "ERROR" "dump_grants: output file missing or empty"
        return 1
    fi

    local sql_size
    sql_size=$(stat -c "%s" "${sql_file}")
    log "INFO" "dump_grants: OK — size=$(( sql_size / 1024 ))KB"
    return 0
}

# ---------------------------------------------------------------------------
# upload_xz_to_s3 SQL_FILE DB_NAME TIMESTAMP
#
# xz-compresses SQL_FILE and pipes to mc pipe.
# Also uploads the .sha256 sidecar.
# Verifies the remote xz object via mc stat after upload.
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
upload_xz_to_s3() {
    local sql_file="$1"
    local db_name="$2"
    local timestamp="$3"

    local sql_base
    sql_base=$(basename "${sql_file}")          # db_YYYYMMDD_HHMM.sql
    local xz_name="${sql_base}.xz"              # db_YYYYMMDD_HHMM.sql.xz
    local sha_name="${sql_base}.sha256"         # db_YYYYMMDD_HHMM.sql.sha256
    local sha_file="${sql_file}.sha256"

    local s3_xz_path="${MC_ALIAS}/${S3_BUCKET}/${S3_MYSQL_PREFIX}/${db_name}/${xz_name}"
    local s3_sha_path="${MC_ALIAS}/${S3_BUCKET}/${S3_MYSQL_PREFIX}/${db_name}/${sha_name}"

    log "INFO" "upload_xz_to_s3: [${db_name}] → ${s3_xz_path}"

    if [[ "${CLI_DRY_RUN}" == true ]]; then
        log "INFO" "upload_xz_to_s3: DRY-RUN — would compress and upload ${sql_file}"
        return 0
    fi

    # Phase 2: xz compress → mc pipe (streaming, no local xz file)
    local upload_rc=0
    nice -n19 ionice -c3 \
        xz "-${DUMP_XZ_LEVEL:-6}" -T"${DUMP_XZ_THREADS:-1}" -c "${sql_file}" \
        2>>"${ERROR_LOG_FILE:-/dev/stderr}" \
        | mc pipe "${s3_xz_path}" \
        || upload_rc=$?

    if (( upload_rc != 0 )); then
        log "ERROR" "upload_xz_to_s3: [${db_name}] xz+mc pipe failed (rc=${upload_rc})"
        return 1
    fi

    # Verify xz object exists on S3 with non-zero size
    if ! verify_s3_object "${s3_xz_path}"; then
        log "ERROR" "upload_xz_to_s3: [${db_name}] S3 verify failed for ${s3_xz_path}"
        return 1
    fi

    # Upload sha256 sidecar
    if [[ -f "${sha_file}" ]]; then
        if ! mc cp "${sha_file}" "${s3_sha_path}" &>/dev/null; then
            log "WARN" "upload_xz_to_s3: [${db_name}] sha256 sidecar upload failed (non-fatal)"
        else
            log "DEBUG" "upload_xz_to_s3: [${db_name}] sha256 sidecar uploaded"
        fi
    else
        log "WARN" "upload_xz_to_s3: [${db_name}] sha256 sidecar not found: ${sha_file}"
    fi

    log "INFO" "upload_xz_to_s3: [${db_name}] upload OK"
    return 0
}

# ---------------------------------------------------------------------------
# verify_s3_object S3_PATH
#
# Uses mc stat to confirm an object exists with size > 0.
# Returns 0 if verified, 1 if missing or zero-size.
# ---------------------------------------------------------------------------
verify_s3_object() {
    local s3_path="$1"

    local stat_output
    if ! stat_output=$(mc stat "${s3_path}" 2>/dev/null); then
        log "ERROR" "verify_s3_object: object not found: ${s3_path}"
        return 1
    fi

    # Extract size from mc stat output (line: "Size      : 12345 B")
    local obj_size
    obj_size=$(echo "${stat_output}" | grep -i "^Size" | grep -oP '\d+' | head -1 || echo "0")

    if (( obj_size == 0 )); then
        log "ERROR" "verify_s3_object: object has zero size: ${s3_path}"
        return 1
    fi

    log "DEBUG" "verify_s3_object: OK — ${s3_path} (${obj_size} bytes)"
    return 0
}

# ---------------------------------------------------------------------------
# check_dump_disk_space RUN_DIR DB_LIST_ARRAY_NAME SIZE_HISTORY_ASSOC_NAME
#
# Estimates total space needed and checks df on DUMP_TMPDIR.
# Returns 0 if safe, 1 if should abort.
# ---------------------------------------------------------------------------
check_dump_disk_space() {
    local run_dir="$1"
    local -n _db_list_sp_ref="$2"
    local -n _size_hist_ref="$3"

    local warn_pct="${DUMP_SPACE_WARN_PCT:-80}"
    local abort_pct="${DUMP_SPACE_ABORT_PCT:-95}"
    local estimate_bytes_default=$(( ${DUMP_SPACE_ESTIMATE_GB:-10} * 1073741824 ))

    # Sum estimates across all databases (+ 1 for _grants)
    local total_estimated=0
    local db
    for db in "${_db_list_sp_ref[@]}" "_grants"; do
        local db_estimate="${_size_hist_ref[${db}]:-0}"
        if (( db_estimate == 0 )); then
            # No history: use per-db share of the global default estimate
            local n_dbs=$(( ${#_db_list_sp_ref[@]} + 1 ))
            db_estimate=$(( estimate_bytes_default / n_dbs ))
        fi
        total_estimated=$(( total_estimated + db_estimate ))
    done

    # Apply 20% safety factor
    local total_with_headroom
    total_with_headroom=$(awk -v b="${total_estimated}" \
        'BEGIN { printf "%d", int(b * 1.20) }')

    # Get filesystem stats for DUMP_TMPDIR
    local avail_bytes used_pct
    avail_bytes=$(df --output=avail -B1 "${DUMP_TMPDIR}" 2>/dev/null \
        | tail -1 | tr -d '[:space:]')
    used_pct=$(df --output=pcent "${DUMP_TMPDIR}" 2>/dev/null \
        | tail -1 | tr -d ' %')

    local est_gb avail_gb
    est_gb=$(awk -v b="${total_with_headroom}" 'BEGIN { printf "%.1f", b/1073741824 }')
    avail_gb=$(awk -v b="${avail_bytes}" 'BEGIN { printf "%.1f", b/1073741824 }')

    log "INFO" "check_dump_disk_space: estimated=${est_gb}GB available=${avail_gb}GB used=${used_pct}%"

    if (( used_pct >= abort_pct )); then
        log "ERROR" "check_dump_disk_space: filesystem ${used_pct}% full (abort threshold=${abort_pct}%) — aborting"
        return 1
    fi

    if (( used_pct >= warn_pct )); then
        log "WARN" "check_dump_disk_space: filesystem ${used_pct}% full (warn threshold=${warn_pct}%)"
    fi

    if (( avail_bytes < total_with_headroom )); then
        log "WARN" "check_dump_disk_space: estimated need ${est_gb}GB but only ${avail_gb}GB available — proceeding with caution"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# load_size_history HISTORY_FILE OUT_ASSOC_ARRAY_NAME
#
# Reads key=value pairs from HISTORY_FILE into the named associative array.
# File format: db_name=bytes_as_integer (one per line, # comments ignored)
# ---------------------------------------------------------------------------
load_size_history() {
    local history_file="$1"
    local -n _hist_load_ref="$2"

    _hist_load_ref=()

    [[ ! -f "${history_file}" ]] && return 0

    local line key val
    while IFS= read -r line; do
        # Skip blanks and comments
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        if [[ -n "${key}" ]] && [[ "${val}" =~ ^[0-9]+$ ]]; then
            _hist_load_ref["${key}"]="${val}"
        fi
    done < "${history_file}"

    log "DEBUG" "load_size_history: loaded ${#_hist_load_ref[@]} entries from ${history_file}"
    return 0
}

# ---------------------------------------------------------------------------
# save_size_history HISTORY_FILE ASSOC_ARRAY_NAME
#
# Writes all key=value pairs from the named associative array to HISTORY_FILE.
# ---------------------------------------------------------------------------
save_size_history() {
    local history_file="$1"
    local -n _hist_save_ref="$2"

    {
        echo "# mysql_dump_zpaq size history — updated $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "# Format: database_name=uncompressed_bytes"
        local key
        for key in "${!_hist_save_ref[@]}"; do
            echo "${key}=${_hist_save_ref[${key}]}"
        done
    } > "${history_file}"

    log "DEBUG" "save_size_history: wrote ${#_hist_save_ref[@]} entries to ${history_file}"
    return 0
}