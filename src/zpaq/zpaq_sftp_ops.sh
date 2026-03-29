#!/usr/bin/env bash
# ============================================================
# src/zpaq/zpaq_sftp_ops.sh — SFTP Upload Workflow for storezpaq.sh
#
# Implements the full upload pipeline for a .zpaq archive:
#
#   zpaq_sftp_upload_workflow ZPAQ_FILE REMOTE_DIR KEEP_COUNT TEMP_DIR
#       Full end-to-end upload:
#         1. Upload archive to <remote_dir>/<base>.zpaq.tmp_upload
#         2. Re-download the uploaded file and verify sha256 matches
#         3. Rename .tmp_upload → <base>.zpaq  (atomic on same filesystem)
#         4. Rename current <base>.zpaq → <base>.<YYYYMMDDHHMMSS>.zpaq
#            using the uploaded= timestamp from the *remote* manifest
#            (preserves provenance of when that version was uploaded)
#         5. Prune old timestamped backups, keeping last KEEP_COUNT
#         6. Upload the updated local manifest as <base>.manifest
#       Returns 0 on success, 1 on any failure.
#
#   zpaq_sftp_download_manifest REMOTE_DIR ZPAQ_FILE LOCAL_DEST
#       Downloads <remote_dir>/<base>.manifest to LOCAL_DEST.
#       Returns 0 on success, 1 if not found or on error.
#
#   zpaq_sftp_upload_manifest ZPAQ_FILE REMOTE_DIR
#       Uploads the local <base>.manifest next to ZPAQ_FILE to
#       <remote_dir>/<base>.manifest.
#       Returns 0 on success, 1 on error.
#
#   zpaq_sftp_prune_backups REMOTE_DIR BASE KEEP_COUNT
#       Lists timestamped backup files matching <base>.<14digits>.zpaq
#       on the SFTP server, sorts them oldest-first, and removes any
#       beyond the KEEP_COUNT most recent.
#       Returns 0 on success (including no-op when count ≤ KEEP_COUNT).
#
# Remote path layout (all files in REMOTE_DIR):
#   <base>.zpaq                  — current live archive
#   <base>.manifest              — manifest for current live archive
#   <base>.YYYYMMDDHHMMSS.zpaq   — timestamped backups of prior versions
#
# Dependency order:
#   Must be sourced after:
#     src/core/logging.sh      (uses log(), LOG_FILE)
#     src/zpaq/zpaq_manifest.sh (uses manifest_path(), manifest_compute(),
#                                manifest_write(), manifest_read())
#   load_config() must have run so SFTP_HOST, SFTP_PORT, SFTP_USER,
#   SFTP_PASS are set.
# ============================================================

# ---------------------------------------------------------------------------
# _zpaq_sftp_run BATCH_COMMANDS_STRING
#
# Internal helper: runs sshpass+sftp in batch mode.
# Writes stdout+stderr to log at DEBUG level.
# Returns the sftp exit code.
# ---------------------------------------------------------------------------
_zpaq_sftp_run() {
    local batch_cmds="$1"

    # sshpass closes all non-standard file descriptors before exec-ing sftp
    # (security measure to prevent fd leakage). This means process substitution
    # fds (-b <(printf ...)) are closed before sftp can read them, causing sftp
    # to print its usage message. Use a real temp file instead.
    local batch_file rc=0
    batch_file=$(mktemp /tmp/_zpaq_sftp_batch.XXXXXX)
    printf '%s\n' "${batch_cmds}" > "${batch_file}"

    local output
    output=$(SSHPASS="${SFTP_PASS}" sshpass -e sftp \
                -o StrictHostKeyChecking=no \
                -o BatchMode=no \
                -P "${SFTP_PORT}" \
                "${SFTP_USER}@${SFTP_HOST}" \
                -b "${batch_file}" \
                2>&1) || rc=$?

    rm -f "${batch_file}"

    local line
    while IFS= read -r line; do
        log "DEBUG" "sftp: ${line}"
    done <<< "${output}"

    return "${rc}"
}

# ---------------------------------------------------------------------------
# zpaq_sftp_download_manifest REMOTE_DIR ZPAQ_FILE LOCAL_DEST
#
# Downloads <remote_dir>/<base>.manifest from the SFTP server to LOCAL_DEST.
# Returns 0 on success, 1 if the file does not exist or download fails.
# ---------------------------------------------------------------------------
zpaq_sftp_download_manifest() {
    local remote_dir="$1"
    local zpaq_file="$2"
    local local_dest="$3"

    local base
    base=$(basename "${zpaq_file}" .zpaq)
    local remote_manifest="${remote_dir}/${base}.manifest"

    log "DEBUG" "zpaq_sftp_download_manifest: ${remote_manifest} → ${local_dest}"

    local rc=0
    _zpaq_sftp_run "get ${remote_manifest} ${local_dest}" || rc=$?

    if (( rc != 0 )) || [[ ! -f "${local_dest}" ]]; then
        log "DEBUG" "zpaq_sftp_download_manifest: not found or download failed: ${remote_manifest}"
        rm -f "${local_dest}"
        return 1
    fi

    log "DEBUG" "zpaq_sftp_download_manifest: downloaded OK → ${local_dest}"
    return 0
}

# ---------------------------------------------------------------------------
# zpaq_sftp_upload_manifest ZPAQ_FILE REMOTE_DIR
#
# Uploads the local manifest for ZPAQ_FILE to REMOTE_DIR on the SFTP server.
# Returns 0 on success, 1 on error.
# ---------------------------------------------------------------------------
zpaq_sftp_upload_manifest() {
    local zpaq_file="$1"
    local remote_dir="$2"

    local local_manifest
    local_manifest=$(manifest_path "${zpaq_file}")

    if [[ ! -f "${local_manifest}" ]]; then
        log "ERROR" "zpaq_sftp_upload_manifest: local manifest not found: ${local_manifest}"
        return 1
    fi

    local base
    base=$(basename "${zpaq_file}" .zpaq)
    local remote_manifest="${remote_dir}/${base}.manifest"

    log "DEBUG" "zpaq_sftp_upload_manifest: ${local_manifest} → ${remote_manifest}"

    local rc=0
    _zpaq_sftp_run "put ${local_manifest} ${remote_manifest}" || rc=$?

    if (( rc != 0 )); then
        log "ERROR" "zpaq_sftp_upload_manifest: upload failed (rc=${rc}): ${remote_manifest}"
        return 1
    fi

    log "DEBUG" "zpaq_sftp_upload_manifest: OK"
    return 0
}

# ---------------------------------------------------------------------------
# zpaq_sftp_prune_backups REMOTE_DIR BASE KEEP_COUNT
#
# Lists all timestamped backup files matching <BASE>.<14digits>.zpaq on the
# SFTP server, sorts them oldest-first by timestamp, and removes any beyond
# the KEEP_COUNT most recent.
#
# Returns 0 always (prune failures are logged but non-fatal).
# ---------------------------------------------------------------------------
zpaq_sftp_prune_backups() {
    local remote_dir="$1"
    local base="$2"
    local keep_count="$3"

    log "DEBUG" "zpaq_sftp_prune_backups: listing ${remote_dir}/${base}.*.zpaq (keep=${keep_count})"

    # List the remote directory and filter for timestamped backup names
    # Use a temp file for the batch command — sshpass closes all non-standard fds
    # before exec-ing sftp, which breaks -b <(printf ...) process substitutions.
    local batch_file listing rc=0
    batch_file=$(mktemp /tmp/_zpaq_sftp_batch.XXXXXX)
    printf 'ls -1 %s\n' "${remote_dir}" > "${batch_file}"
    listing=$(SSHPASS="${SFTP_PASS}" sshpass -e sftp \
                -o StrictHostKeyChecking=no \
                -o BatchMode=no \
                -P "${SFTP_PORT}" \
                "${SFTP_USER}@${SFTP_HOST}" \
                -b "${batch_file}" \
                2>/dev/null) || rc=$?
    rm -f "${batch_file}"

    if (( rc != 0 )); then
        log "WARN" "zpaq_sftp_prune_backups: could not list remote dir (rc=${rc}): ${remote_dir}"
        return 0
    fi

    # Extract only lines matching <base>.<14-digit-timestamp>.zpaq
    local backups
    mapfile -t backups < <(
        printf '%s\n' "${listing}" \
        | grep -E "^${base}\.[0-9]{14}\.zpaq$" \
        | sort
    )

    local total="${#backups[@]}"
    log "DEBUG" "zpaq_sftp_prune_backups: found ${total} backup(s)"

    if (( total <= keep_count )); then
        log "DEBUG" "zpaq_sftp_prune_backups: nothing to prune (${total} ≤ ${keep_count})"
        return 0
    fi

    local excess=$(( total - keep_count ))
    log "INFO" "zpaq_sftp_prune_backups: pruning ${excess} oldest backup(s) (keeping ${keep_count})"

    local i
    for (( i = 0; i < excess; i++ )); do
        local old_name="${backups[${i}]}"
        local old_path="${remote_dir}/${old_name}"
        log "INFO" "zpaq_sftp_prune_backups: removing ${old_path}"
        _zpaq_sftp_run "rm ${old_path}" || \
            log "WARN" "zpaq_sftp_prune_backups: failed to remove ${old_path} (non-fatal)"
    done

    return 0
}

# ---------------------------------------------------------------------------
# zpaq_sftp_upload_workflow ZPAQ_FILE REMOTE_DIR KEEP_COUNT TEMP_DIR
#
# Full upload pipeline:
#
#   Step 1  Upload ZPAQ_FILE to <remote_dir>/<base>.zpaq.tmp_upload
#   Step 2  Re-download to TEMP_DIR/<base>.verify and verify sha256
#   Step 3  Rename: .zpaq.tmp_upload → <base>.zpaq
#           (first, if a live .zpaq already exists, rename it to
#            <base>.<prior_uploaded_timestamp>.zpaq for backup)
#   Step 4  Prune old timestamped backups
#   Step 5  Upload the updated local manifest
#
# The local manifest is written/updated by the caller (storezpaq.sh)
# after this function returns successfully.
#
# Returns 0 on success, 1 on any failure.
# ---------------------------------------------------------------------------
zpaq_sftp_upload_workflow() {
    local zpaq_file="$1"
    local remote_dir="$2"
    local keep_count="${3:-7}"
    local temp_dir="${4:-/tmp}"

    local base
    base=$(basename "${zpaq_file}" .zpaq)

    local remote_live="${remote_dir}/${base}.zpaq"
    local remote_tmp="${remote_dir}/${base}.zpaq.tmp_upload"
    local verify_file="${temp_dir}/${base}.verify"

    # Compute local sha256 before upload (used to verify download)
    if ! manifest_compute "${zpaq_file}"; then
        log "ERROR" "zpaq_sftp_upload_workflow: failed to compute sha256 of ${zpaq_file}"
        return 1
    fi
    local expected_sha256="${COMPUTED_SHA256}"
    local expected_size="${COMPUTED_SIZE}"
    log "INFO" "zpaq_sftp_upload_workflow: local sha256=${expected_sha256} size=${expected_size}"

    # ------------------------------------------------------------------
    # Step 1: Upload to .tmp_upload
    # ------------------------------------------------------------------
    log "INFO" "zpaq_sftp_upload_workflow: uploading ${zpaq_file} → ${remote_tmp}"
    local rc=0
    _zpaq_sftp_run "put ${zpaq_file} ${remote_tmp}" || rc=$?
    if (( rc != 0 )); then
        log "ERROR" "zpaq_sftp_upload_workflow: upload to tmp failed (rc=${rc})"
        return 1
    fi
    log "INFO" "zpaq_sftp_upload_workflow: upload to tmp OK"

    # ------------------------------------------------------------------
    # Step 2: Re-download and verify sha256
    # ------------------------------------------------------------------
    rm -f "${verify_file}"
    log "INFO" "zpaq_sftp_upload_workflow: re-downloading for verification"
    rc=0
    _zpaq_sftp_run "get ${remote_tmp} ${verify_file}" || rc=$?
    if (( rc != 0 )) || [[ ! -f "${verify_file}" ]]; then
        log "ERROR" "zpaq_sftp_upload_workflow: re-download failed (rc=${rc})"
        _zpaq_sftp_run "rm ${remote_tmp}" || true
        rm -f "${verify_file}"
        return 1
    fi

    local verify_hash
    verify_hash=$(sha256sum "${verify_file}" 2>/dev/null | awk '{print $1}')
    rm -f "${verify_file}"

    if [[ "${verify_hash}" != "${expected_sha256}" ]]; then
        log "ERROR" "zpaq_sftp_upload_workflow: sha256 mismatch after upload"
        log "ERROR" "  expected: ${expected_sha256}"
        log "ERROR" "  got:      ${verify_hash}"
        _zpaq_sftp_run "rm ${remote_tmp}" || true
        return 1
    fi
    log "INFO" "zpaq_sftp_upload_workflow: sha256 verification OK"

    # ------------------------------------------------------------------
    # Step 3: Rotate current live → timestamped backup, then rename tmp
    # ------------------------------------------------------------------
    # Determine the timestamp for the backup name.
    # Prefer the uploaded= field from the *remote* manifest (provenance),
    # falling back to "now" if no remote manifest exists.
    local backup_ts=""
    local remote_manifest_tmp="${temp_dir}/${base}.remote_manifest.tmp"
    if zpaq_sftp_download_manifest "${remote_dir}" "${zpaq_file}" "${remote_manifest_tmp}"; then
        if manifest_read "${remote_manifest_tmp}"; then
            backup_ts="${MANIFEST_UPLOADED}"
            log "DEBUG" "zpaq_sftp_upload_workflow: backup timestamp from remote manifest: ${backup_ts}"
        fi
        rm -f "${remote_manifest_tmp}"
    fi

    # Validate timestamp format (14 digits); fall back to current time
    if [[ ! "${backup_ts}" =~ ^[0-9]{14}$ ]]; then
        backup_ts=$(date +"%Y%m%d%H%M%S")
        log "DEBUG" "zpaq_sftp_upload_workflow: using current time as backup timestamp: ${backup_ts}"
    fi

    local remote_backup="${remote_dir}/${base}.${backup_ts}.zpaq"

    # Rename commands: rename live → backup (if it exists), then tmp → live
    # We issue them as a single batch to minimise window of inconsistency.
    local rename_batch
    rename_batch=$(printf 'rename %s %s\nrename %s %s\n' \
        "${remote_live}" "${remote_backup}" \
        "${remote_tmp}"  "${remote_live}")

    rc=0
    _zpaq_sftp_run "${rename_batch}" || rc=$?
    if (( rc != 0 )); then
        log "WARN" "zpaq_sftp_upload_workflow: batch rename returned rc=${rc} — retrying tmp→live only"
        # If the live file didn't exist, the first rename failed; try just the second
        rc=0
        _zpaq_sftp_run "rename ${remote_tmp} ${remote_live}" || rc=$?
        if (( rc != 0 )); then
            log "ERROR" "zpaq_sftp_upload_workflow: rename tmp→live failed (rc=${rc})"
            _zpaq_sftp_run "rm ${remote_tmp}" || true
            return 1
        fi
    fi
    log "INFO" "zpaq_sftp_upload_workflow: live archive updated: ${remote_live}"

    # ------------------------------------------------------------------
    # Step 4: Prune old timestamped backups
    # ------------------------------------------------------------------
    zpaq_sftp_prune_backups "${remote_dir}" "${base}" "${keep_count}"

    # ------------------------------------------------------------------
    # Step 5: Upload updated manifest
    # ------------------------------------------------------------------
    local uploaded_ts
    uploaded_ts=$(date +"%Y%m%d%H%M%S")
    manifest_write "${zpaq_file}" "${expected_sha256}" "${expected_size}" "${uploaded_ts}"

    if ! zpaq_sftp_upload_manifest "${zpaq_file}" "${remote_dir}"; then
        log "WARN" "zpaq_sftp_upload_workflow: manifest upload failed (archive upload was successful)"
        # Non-fatal: the archive is already live; manifest will be corrected on next run
    fi

    log "INFO" "zpaq_sftp_upload_workflow: complete — ${remote_live} (sha256=${expected_sha256})"
    return 0
}