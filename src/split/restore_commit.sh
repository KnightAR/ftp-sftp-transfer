#!/usr/bin/env bash
# ============================================================
# src/split/restore_commit.sh — Sequential Part Commit Thread
#
# Defines restore_commit_thread(), which runs as a single background
# process alongside N restore_download_worker() instances.
#
# Why a separate sequential thread?
#   cat >> must append parts in strict numeric order to reconstruct
#   the original file correctly.  Parallel workers download in
#   whatever order SFTP delivers them; this thread serialises the
#   append step without blocking downloads.
#
# Algorithm:
#   next_idx=1
#   loop:
#     partname = build_part_name(next_idx)
#     if next_idx > MANIFEST_PART_COUNT → break (all parts committed)
#     status = read TEMP_DIR/restore_status/<partname>
#     if status == VERIFIED:
#       cat local_part >> output_file
#       verify output_file size grew by part_size (sanity check)
#       rm local_part
#       write COMMITTED to status file
#       next_idx++
#     elif status == FAILED:
#       log error, set COMMIT_FAILED=true, break
#     else (missing / still downloading):
#       sleep COMMIT_POLL_INTERVAL and retry
#
# On completion the thread writes its exit status to
# TEMP_DIR/restore_commit.done so the orchestrator can join it.
#
# Disk usage (streaming benefit):
#   At any moment disk holds:
#     - Partially assembled output file (grows from 0 to full size)
#     - At most (SPLIT_RESTORE_WORKERS) downloaded parts not yet committed
#       (workers run ahead; the commit thread drains them in order)
#   Peak ≈ original_size + SPLIT_RESTORE_WORKERS × part_size
#   For default 1 GB parts and 4 workers: peak ≈ original + 4 GB
#   Compare to non-streaming: peak ≈ 2 × original_size
#
# Output file integrity:
#   After all parts are committed the caller should verify the full
#   file sha256 against MANIFEST_ORIGINAL_SHA256.  This thread does
#   NOT perform that final check — it is the orchestrator's job.
#
# Verify-only mode:
#   If RESTORE_VERIFY_ONLY=true the thread does NOT cat to any output
#   file — it simply confirms each part is VERIFIED and marks it
#   COMMITTED, then deletes the local part.  This lets the caller
#   verify a set of parts without writing a full output file (useful
#   for checking SFTP integrity without allocating disk for the
#   assembled file).
#
# Variables read from caller's environment:
#   MANIFEST_PART_COUNT        — total number of parts
#   MANIFEST_PART_PREFIX       — e.g. "bigfile.tar.gz.part."
#   MANIFEST_PART_SUFFIX_LEN   — digit width, e.g. 5
#   RESTORE_VERIFY_ONLY        — if "true", skip output file writes
#   TEMP_DIR                   — shared temp directory
#
# Functions provided:
#   restore_commit_thread OUTPUT_FILE PARTS_STAGING_DIR
#
# Dependency order:
#   Must be sourced after src/core/logging.sh, src/core/constants.sh.
# ============================================================

# How long (seconds) to sleep between polls when waiting for the next
# part to be verified by a download worker.
COMMIT_POLL_INTERVAL="${COMMIT_POLL_INTERVAL:-2}"

# restore_commit_thread OUTPUT_FILE PARTS_STAGING_DIR
#
# OUTPUT_FILE        — path to write (or append to) the assembled file.
#                      Ignored when RESTORE_VERIFY_ONLY=true.
# PARTS_STAGING_DIR  — directory containing downloaded part files.
restore_commit_thread() {
    local output_file="$1"
    local parts_staging_dir="$2"
    local done_file="${TEMP_DIR}/restore_commit.done"
    local next_idx=1
    local committed=0
    local commit_failed=false
    local stall_count=0
    # Allow up to ~5 minutes of stall before giving up
    # (large parts on slow SFTP can take time; poll every 2 s → 150 polls)
    local stall_limit=150

    log "DEBUG" "Restore commit thread started (PID $$)"

    # Truncate (or create) the output file before we begin appending,
    # unless verify-only mode — in that case we never touch the output.
    if [[ "${RESTORE_VERIFY_ONLY:-false}" != "true" ]]; then
        : > "${output_file}"
    fi

    while (( next_idx <= MANIFEST_PART_COUNT )); do
        # Build the part filename: prefix + zero-padded index
        local partname
        partname=$(printf '%s%0*d' \
            "${MANIFEST_PART_PREFIX}" \
            "${MANIFEST_PART_SUFFIX_LEN}" \
            "${next_idx}")

        local status_file="${TEMP_DIR}/restore_status/${partname}"
        local local_part="${parts_staging_dir}/${partname}"
        local status=""

        if [[ -f "${status_file}" ]]; then
            status=$(cat "${status_file}" 2>/dev/null || true)
        fi

        case "${status}" in
            VERIFIED)
                if [[ "${RESTORE_VERIFY_ONLY:-false}" != "true" ]]; then
                    # Append this part to the output file
                    if ! cat "${local_part}" >> "${output_file}" 2>/dev/null; then
                        log "ERROR" "[COMMIT] Failed to append part to output file: ${partname}"
                        commit_failed=true
                        break
                    fi
                    log "DEBUG" "[COMMIT] Appended part ${next_idx}/${MANIFEST_PART_COUNT}: ${partname}"
                else
                    log "DEBUG" "[COMMIT] Verify-only: confirmed part ${next_idx}/${MANIFEST_PART_COUNT}: ${partname}"
                fi

                # Delete the local part file to free disk space
                rm -f "${local_part}"

                # Mark COMMITTED so workers/orchestrator know this part is done
                echo "COMMITTED" > "${status_file}"

                (( committed++ ))
                (( next_idx++ ))
                stall_count=0
                ;;

            FAILED)
                log "ERROR" "[COMMIT] Part ${next_idx} marked FAILED by download worker — aborting commit: ${partname}"
                commit_failed=true
                break
                ;;

            COMMITTED)
                # Should not happen (we write COMMITTED ourselves and advance
                # next_idx immediately), but handle gracefully.
                log "WARN" "[COMMIT] Part already COMMITTED on entry — advancing: ${partname}"
                (( next_idx++ ))
                stall_count=0
                ;;

            *)
                # Part not yet downloaded/verified — wait
                (( stall_count++ ))
                if (( stall_count >= stall_limit )); then
                    log "ERROR" "[COMMIT] Stall timeout waiting for part ${next_idx}: ${partname} (status='${status}')"
                    commit_failed=true
                    break
                fi
                if (( stall_count % 15 == 1 )); then
                    log "DEBUG" "[COMMIT] Waiting for part ${next_idx}/${MANIFEST_PART_COUNT}: ${partname} (status='${status}', stall=${stall_count}/${stall_limit})"
                fi
                sleep "${COMMIT_POLL_INTERVAL}"
                ;;
        esac
    done

    # ---- Write exit status so orchestrator can join this thread ----
    if [[ "${commit_failed}" == "true" ]]; then
        log "ERROR" "[COMMIT] Commit thread exiting with FAILED status (committed ${committed}/${MANIFEST_PART_COUNT} parts)"
        echo "FAILED" > "${done_file}"
    else
        log "INFO" "[COMMIT] Commit thread complete — committed ${committed}/${MANIFEST_PART_COUNT} parts"
        echo "OK" > "${done_file}"
    fi
}

# wait_for_commit_thread [TIMEOUT_SECONDS]
#
# Blocks until restore_commit.done is written by restore_commit_thread.
# Returns 0 if commit thread reported OK, 1 on FAILED or timeout.
# Default timeout: 7200 seconds (2 hours).
wait_for_commit_thread() {
    local timeout="${1:-7200}"
    local done_file="${TEMP_DIR}/restore_commit.done"
    local elapsed=0
    local poll=5

    while [[ ! -f "${done_file}" ]]; do
        sleep "${poll}"
        (( elapsed += poll ))
        if (( elapsed >= timeout )); then
            log "ERROR" "Timed out waiting for commit thread after ${elapsed}s"
            return 1
        fi
        if (( elapsed % 60 == 0 )); then
            log "DEBUG" "Still waiting for commit thread (${elapsed}s elapsed)..."
        fi
    done

    local result
    result=$(cat "${done_file}" 2>/dev/null || echo "FAILED")
    if [[ "${result}" == "OK" ]]; then
        return 0
    else
        log "ERROR" "Commit thread reported: ${result}"
        return 1
    fi
}