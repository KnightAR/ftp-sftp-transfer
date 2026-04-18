#!/usr/bin/env bash
# ============================================================
# src/mysql/mysql_zpaq_ops.sh — zpaqfranz Add and S3 Upload Operations
#
# Manages the zpaqfranz multipart archive for MySQL dumps.
# The archive is named <BACKUP_HOSTNAME>??????? and parts are
# stored locally in ZPAQ_LOCAL_DIR forever (never auto-pruned).
# Each new part is uploaded to S3 via mc cp after creation.
# A JSON manifest tracks all parts (sha256, size, fragment).
#
# Provides:
#
#   mysql_zpaq_load_manifest
#       Reads the local manifest file into in-memory state vars
#       MZDUMP_MANIFEST_*. Initialises fresh state if no manifest
#       exists yet.
#
#   mysql_zpaq_write_manifest MANIFEST_PATH
#       Writes current MZDUMP_MANIFEST_* state to MANIFEST_PATH.
#
#   mysql_zpaq_add RUN_DIR SQL_FILES_ARRAY_NAME
#       Runs zpaqfranz a on all SQL files in SQL_FILES_ARRAY_NAME,
#       working from RUN_DIR so internal archive paths are relative
#       (db/db_YYYYMMDD_HHMM.sql).
#       Applies nice/ionice. Returns 0 on success, 1 on failure.
#
#   mysql_zpaq_find_new_part OUT_VAR
#       Sets OUT_VAR to the full path of the highest-numbered .zpaq
#       part in ZPAQ_LOCAL_DIR for basename BACKUP_HOSTNAME.
#
#   mysql_zpaq_upload_part PART_FILE
#       Uploads PART_FILE to S3_ZPAQ_PREFIX/ via mc cp.
#       Returns 0 on success, 1 on failure.
#
#   mysql_zpaq_upload_manifest MANIFEST_PATH
#       Uploads MANIFEST_PATH to S3_ZPAQ_PREFIX/ via mc cp.
#       Returns 0 on success, non-fatal warning on failure.
#
# Manifest format (JSON, written by mysql_zpaq_write_manifest):
#   {
#     "basename":    "myserver",
#     "fragment":    3,
#     "method":      5,
#     "question_marks": 7,
#     "total_parts": N,
#     "total_size":  bytes,
#     "parts": [
#       { "name": "myserver0000001.zpaq", "size": bytes, "sha256": "..." },
#       ...
#     ]
#   }
#
# In-memory state globals (all prefixed MZDUMP_MANIFEST_):
#   MZDUMP_MANIFEST_BASENAME
#   MZDUMP_MANIFEST_FRAGMENT
#   MZDUMP_MANIFEST_METHOD
#   MZDUMP_MANIFEST_QUESTION_MARKS
#   MZDUMP_MANIFEST_TOTAL_PARTS
#   MZDUMP_MANIFEST_TOTAL_SIZE
#   MZDUMP_MANIFEST_PARTS_JSON   (raw JSON array string for reuse)
#
# Globals consumed:
#   BACKUP_HOSTNAME, ZPAQ_LOCAL_DIR
#   ZPAQ_METHOD, ZPAQ_FRAGMENT, ZPAQ_MULTIPART_QUESTION_MARKS
#   MC_ALIAS, S3_BUCKET, S3_ZPAQ_PREFIX
#   CLI_DRY_RUN, CLI_VERBOSE
#   LOG_FILE, ERROR_LOG_FILE
#   ZPAQFRANZ_BIN   (set by detect_zpaqfranz() from zpaq_utils.sh)
#
# Dependency:
#   Must be sourced after src/core/logging.sh and src/zpaq/zpaq_utils.sh
# ============================================================

# ---------------------------------------------------------------------------
# In-memory manifest state
# ---------------------------------------------------------------------------
MZDUMP_MANIFEST_BASENAME=""
MZDUMP_MANIFEST_FRAGMENT="${ZPAQ_FRAGMENT:-3}"
MZDUMP_MANIFEST_METHOD="${ZPAQ_METHOD:-5}"
MZDUMP_MANIFEST_QUESTION_MARKS="${ZPAQ_MULTIPART_QUESTION_MARKS:-7}"
MZDUMP_MANIFEST_TOTAL_PARTS=0
MZDUMP_MANIFEST_TOTAL_SIZE=0
MZDUMP_MANIFEST_PARTS_JSON="[]"

# ---------------------------------------------------------------------------
# _mzdump_archive_pattern
# Returns the full glob pattern for the multipart archive.
# ---------------------------------------------------------------------------
_mzdump_archive_pattern() {
    local qmarks
    qmarks=$(printf '%0.s?' $(seq 1 "${MZDUMP_MANIFEST_QUESTION_MARKS:-7}"))
    echo "${ZPAQ_LOCAL_DIR}/${BACKUP_HOSTNAME}${qmarks}"
}

# ---------------------------------------------------------------------------
# _mzdump_manifest_path
# Returns the canonical path for the local manifest file.
# ---------------------------------------------------------------------------
_mzdump_manifest_path() {
    echo "${ZPAQ_LOCAL_DIR}/${BACKUP_HOSTNAME}.manifest.json"
}

# ---------------------------------------------------------------------------
# mysql_zpaq_load_manifest
#
# Reads the manifest JSON from disk into MZDUMP_MANIFEST_* globals.
# If no manifest exists, initialises fresh state.
# ---------------------------------------------------------------------------
mysql_zpaq_load_manifest() {
    local manifest_path
    manifest_path=$(_mzdump_manifest_path)

    # Set basename always
    MZDUMP_MANIFEST_BASENAME="${BACKUP_HOSTNAME}"
    MZDUMP_MANIFEST_FRAGMENT="${ZPAQ_FRAGMENT:-3}"
    MZDUMP_MANIFEST_METHOD="${ZPAQ_METHOD:-5}"
    MZDUMP_MANIFEST_QUESTION_MARKS="${ZPAQ_MULTIPART_QUESTION_MARKS:-7}"

    if [[ ! -f "${manifest_path}" ]]; then
        log "INFO" "mysql_zpaq_load_manifest: no manifest found — starting fresh archive"
        MZDUMP_MANIFEST_TOTAL_PARTS=0
        MZDUMP_MANIFEST_TOTAL_SIZE=0
        MZDUMP_MANIFEST_PARTS_JSON="[]"
        return 0
    fi

    log "DEBUG" "mysql_zpaq_load_manifest: reading ${manifest_path}"

    # Parse with python3 (guaranteed available in our Docker image; jq optional)
    local parsed
    if ! parsed=$(python3 -c "
import json, sys
with open('${manifest_path}') as f:
    m = json.load(f)
print(m.get('total_parts', 0))
print(m.get('total_size', 0))
print(m.get('fragment', ${ZPAQ_FRAGMENT:-3}))
print(m.get('method', ${ZPAQ_METHOD:-5}))
print(m.get('question_marks', ${ZPAQ_MULTIPART_QUESTION_MARKS:-7}))
" 2>/dev/null); then
        log "WARN" "mysql_zpaq_load_manifest: could not parse manifest — treating as fresh"
        MZDUMP_MANIFEST_TOTAL_PARTS=0
        MZDUMP_MANIFEST_TOTAL_SIZE=0
        MZDUMP_MANIFEST_PARTS_JSON="[]"
        return 0
    fi

    MZDUMP_MANIFEST_TOTAL_PARTS=$(sed -n '1p' <<< "${parsed}")
    MZDUMP_MANIFEST_TOTAL_SIZE=$(sed -n '2p' <<< "${parsed}")
    MZDUMP_MANIFEST_FRAGMENT=$(sed -n '3p' <<< "${parsed}")
    MZDUMP_MANIFEST_METHOD=$(sed -n '4p' <<< "${parsed}")
    MZDUMP_MANIFEST_QUESTION_MARKS=$(sed -n '5p' <<< "${parsed}")

    # Preserve the parts array as-is for later re-serialisation
    MZDUMP_MANIFEST_PARTS_JSON=$(python3 -c "
import json, sys
with open('${manifest_path}') as f:
    m = json.load(f)
print(json.dumps(m.get('parts', [])))
" 2>/dev/null || echo "[]")

    log "INFO" "mysql_zpaq_load_manifest: loaded — parts=${MZDUMP_MANIFEST_TOTAL_PARTS} size=${MZDUMP_MANIFEST_TOTAL_SIZE}"

    # Warn if method in manifest differs from config (can't change after first add)
    if [[ "${MZDUMP_MANIFEST_METHOD}" != "${ZPAQ_METHOD:-5}" ]]; then
        log "WARN" "mysql_zpaq_load_manifest: ZPAQ_METHOD in config (${ZPAQ_METHOD:-5}) differs from archive (${MZDUMP_MANIFEST_METHOD}) — using archive value ${MZDUMP_MANIFEST_METHOD}"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# mysql_zpaq_write_manifest MANIFEST_PATH [NEW_PART_NAME NEW_PART_SIZE NEW_PART_SHA256]
#
# Writes the current MZDUMP_MANIFEST_* state to disk.
# If the optional new part arguments are supplied, appends that part
# to the parts array before writing.
# ---------------------------------------------------------------------------
mysql_zpaq_write_manifest() {
    local manifest_path="$1"
    local new_part_name="${2:-}"
    local new_part_size="${3:-0}"
    local new_part_sha256="${4:-}"

    # Append new part to parts JSON if provided
    if [[ -n "${new_part_name}" ]]; then
        MZDUMP_MANIFEST_PARTS_JSON=$(python3 -c "
import json, sys
parts = json.loads('''${MZDUMP_MANIFEST_PARTS_JSON}''')
parts.append({
    'name':   '${new_part_name}',
    'size':   ${new_part_size},
    'sha256': '${new_part_sha256}'
})
print(json.dumps(parts, indent=2))
" 2>/dev/null || echo "${MZDUMP_MANIFEST_PARTS_JSON}")
    fi

    python3 -c "
import json, sys
parts = json.loads(sys.stdin.read())
manifest = {
    'basename':       '${MZDUMP_MANIFEST_BASENAME}',
    'fragment':       ${MZDUMP_MANIFEST_FRAGMENT},
    'method':         ${MZDUMP_MANIFEST_METHOD},
    'question_marks': ${MZDUMP_MANIFEST_QUESTION_MARKS},
    'total_parts':    ${MZDUMP_MANIFEST_TOTAL_PARTS},
    'total_size':     ${MZDUMP_MANIFEST_TOTAL_SIZE},
    'parts':          parts
}
with open('${manifest_path}', 'w') as f:
    json.dump(manifest, f, indent=2)
    f.write('\n')
print('ok')
" <<< "${MZDUMP_MANIFEST_PARTS_JSON}" >/dev/null

    log "DEBUG" "mysql_zpaq_write_manifest: wrote ${manifest_path} (parts=${MZDUMP_MANIFEST_TOTAL_PARTS})"
    return 0
}

# ---------------------------------------------------------------------------
# mysql_zpaq_add RUN_DIR SQL_FILES_ARRAY_NAME
#
# Adds all SQL files to the zpaqfranz multipart archive.
# Runs from RUN_DIR so paths inside the archive are relative:
#   db1/db1_20240115_0300.sql
#   db2/db2_20240115_0300.sql
#   _grants/_grants_20240115_0300.sql
#
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
mysql_zpaq_add() {
    local run_dir="$1"
    local -n _sql_files_ref="$2"

    if (( ${#_sql_files_ref[@]} == 0 )); then
        log "WARN" "mysql_zpaq_add: no SQL files to add"
        return 1
    fi

    local archive_pat
    archive_pat=$(_mzdump_archive_pattern)

    # Build relative paths from run_dir
    local -a rel_paths=()
    local f
    for f in "${_sql_files_ref[@]}"; do
        local rel="${f#${run_dir}/}"
        rel="${rel#/}"
        if [[ -z "${rel}" ]] || [[ "${rel}" == "${f}" ]]; then
            log "ERROR" "mysql_zpaq_add: file not under run_dir: ${f}"
            return 1
        fi
        rel_paths+=("${rel}")
        log "DEBUG" "mysql_zpaq_add: queuing ${rel}"
    done

    log "INFO" "mysql_zpaq_add: adding ${#rel_paths[@]} file(s) to ${archive_pat}"
    log "INFO" "mysql_zpaq_add: method=${MZDUMP_MANIFEST_METHOD} fragment=${MZDUMP_MANIFEST_FRAGMENT} threads=1"

    if [[ "${CLI_DRY_RUN}" == true ]]; then
        log "INFO" "mysql_zpaq_add: DRY-RUN — would run zpaqfranz a on:"
        for f in "${rel_paths[@]}"; do
            log "INFO" "  + ${f}"
        done
        return 0
    fi

    # Ensure ZPAQ_LOCAL_DIR exists
    mkdir -p "${ZPAQ_LOCAL_DIR}"

    # Run zpaqfranz from run_dir so internal names are relative
    local add_rc=0
    pushd "${run_dir}" >/dev/null

    local _zpaq_out
    _zpaq_out=$(nice -n19 ionice -c3 \
        "${ZPAQFRANZ_BIN}" a "${archive_pat}" \
            "${rel_paths[@]}" \
            -method "${MZDUMP_MANIFEST_METHOD}" \
            -fragment "${MZDUMP_MANIFEST_FRAGMENT}" \
            -threads 1 \
            2>&1) || add_rc=$?

    popd >/dev/null

    # Log zpaqfranz output line by line
    while IFS= read -r _zpaq_line; do
        log "DEBUG" "zpaqfranz: ${_zpaq_line}"
    done <<< "${_zpaq_out}"

    if (( add_rc != 0 )); then
        log "ERROR" "mysql_zpaq_add: zpaqfranz a failed (rc=${add_rc})"
        return 1
    fi

    log "INFO" "mysql_zpaq_add: zpaqfranz add complete"
    return 0
}

# ---------------------------------------------------------------------------
# mysql_zpaq_find_new_part OUT_VAR
#
# Sets OUT_VAR to the full path of the highest-numbered .zpaq part
# for this archive in ZPAQ_LOCAL_DIR.
# Returns 0 if found, 1 if not found.
# ---------------------------------------------------------------------------
mysql_zpaq_find_new_part() {
    local -n _out_part_ref="$1"
    _out_part_ref=""

    local qmarks
    qmarks=$(printf '%0.s?' $(seq 1 "${MZDUMP_MANIFEST_QUESTION_MARKS:-7}"))

    # Find the highest-numbered part
    local latest_part
    latest_part=$(find "${ZPAQ_LOCAL_DIR}" -maxdepth 1 \
        -name "${BACKUP_HOSTNAME}[0-9][0-9][0-9][0-9][0-9][0-9][0-9].zpaq" \
        2>/dev/null | sort | tail -1)

    if [[ -z "${latest_part}" ]]; then
        log "ERROR" "mysql_zpaq_find_new_part: no .zpaq part found in ${ZPAQ_LOCAL_DIR}"
        return 1
    fi

    # Verify this part is newer than what the manifest already tracks
    local latest_basename
    latest_basename=$(basename "${latest_part}")
    local already_known=false

    if python3 -c "
import json, sys
parts = json.loads(sys.stdin.read())
names = {p['name'] for p in parts}
sys.exit(0 if '${latest_basename}' in names else 1)
" <<< "${MZDUMP_MANIFEST_PARTS_JSON}" 2>/dev/null; then
        already_known=true
    fi

    if [[ "${already_known}" == true ]]; then
        log "ERROR" "mysql_zpaq_find_new_part: latest part ${latest_basename} is already in manifest — no new part was created?"
        return 1
    fi

    _out_part_ref="${latest_part}"
    log "DEBUG" "mysql_zpaq_find_new_part: found new part: ${latest_basename}"
    return 0
}

# ---------------------------------------------------------------------------
# mysql_zpaq_upload_part PART_FILE
#
# Uploads a single .zpaq part file to S3 via mc cp.
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
mysql_zpaq_upload_part() {
    local part_file="$1"
    local part_name
    part_name=$(basename "${part_file}")

    local s3_dest="${MC_ALIAS}/${S3_BUCKET}/${S3_ZPAQ_PREFIX}/${part_name}"

    log "INFO" "mysql_zpaq_upload_part: ${part_name} → ${s3_dest}"

    if [[ "${CLI_DRY_RUN}" == true ]]; then
        log "INFO" "mysql_zpaq_upload_part: DRY-RUN — would upload ${part_name}"
        return 0
    fi

    local upload_rc=0
    local _cp_out
    _cp_out=$(mc cp "${part_file}" "${s3_dest}" 2>&1) || upload_rc=$?
    while IFS= read -r _line; do
        log "DEBUG" "mc cp: ${_line}"
    done <<< "${_cp_out}"

    if (( upload_rc != 0 )); then
        log "ERROR" "mysql_zpaq_upload_part: mc cp failed for ${part_name} (rc=${upload_rc})"
        return 1
    fi

    # Verify upload
    if ! mc stat "${s3_dest}" &>/dev/null; then
        log "ERROR" "mysql_zpaq_upload_part: S3 object not found after upload: ${s3_dest}"
        return 1
    fi

    log "INFO" "mysql_zpaq_upload_part: upload OK — ${part_name}"
    return 0
}

# ---------------------------------------------------------------------------
# mysql_zpaq_upload_manifest MANIFEST_PATH
#
# Uploads the manifest JSON to S3.
# Failure is logged as WARN (non-fatal) — local manifest is source of truth.
# ---------------------------------------------------------------------------
mysql_zpaq_upload_manifest() {
    local manifest_path="$1"
    local manifest_name
    manifest_name=$(basename "${manifest_path}")

    local s3_dest="${MC_ALIAS}/${S3_BUCKET}/${S3_ZPAQ_PREFIX}/${manifest_name}"

    log "DEBUG" "mysql_zpaq_upload_manifest: ${manifest_name} → ${s3_dest}"

    if [[ "${CLI_DRY_RUN}" == true ]]; then
        log "INFO" "mysql_zpaq_upload_manifest: DRY-RUN — would upload manifest"
        return 0
    fi

    if ! mc cp "${manifest_path}" "${s3_dest}" &>/dev/null; then
        log "WARN" "mysql_zpaq_upload_manifest: manifest upload failed (non-fatal) — local copy is authoritative"
        return 1
    fi

    log "DEBUG" "mysql_zpaq_upload_manifest: manifest upload OK"
    return 0
}