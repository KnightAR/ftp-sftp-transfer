#!/usr/bin/env bash
# ============================================================
# src/workers/disk_guard.sh — Disk Space Guard
#
# Provides wait_for_disk_space(), which blocks a download worker
# until there is enough free space in TEMP_DIR to safely stage
# one additional file download.
#
# Usable headroom formula:
#   usable = df_avail - in_flight_bytes - (total * DISK_SPACE_BUFFER_PCT / 100)
#
#   df_avail         — current free bytes reported by df
#   in_flight_bytes  — bytes already reserved by other active downloads
#                      (decremented when the download completes and the
#                      file lands on disk)
#   buffer           — a fixed percentage of the filesystem's total size
#                      kept in reserve to avoid filling the disk entirely
#
# Idle-exit:
#   If no download workers AND no upload workers are currently active,
#   nothing can free space — the function returns 1 immediately rather
#   than spinning until DISK_WAIT_TIMEOUT.  This prevents a deadlock
#   where the last worker is waiting for space that will never be freed.
#
# Returns:
#   0 — sufficient space is available (caller may proceed with download)
#   1 — timed out waiting for space, or went idle with no active workers
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()),
#   src/workers/counters.sh (uses _counter_get()),
#   and src/core/constants.sh (uses TEMP_DIR).
#   load_config() must have run so DISK_SPACE_BUFFER_PCT,
#   DISK_WAIT_TIMEOUT, and DISK_WAIT_INTERVAL are set.
# ============================================================

wait_for_disk_space() {
    local worker_id="$1"
    local file_size="$2"

    # Compute the fixed buffer once — it is based on total filesystem size
    # which does not change during the run
    local total_bytes
    total_bytes=$(df --output=size -B1 "${TEMP_DIR}" 2>/dev/null | tail -1 | tr -d ' ')
    local buffer_bytes=$(( total_bytes * DISK_SPACE_BUFFER_PCT / 100 ))

    local waited=0
    while true; do
        local avail_bytes in_flight usable
        avail_bytes=$(df --output=avail -B1 "${TEMP_DIR}" 2>/dev/null | tail -1 | tr -d ' ')
        in_flight=$(_counter_get "${TEMP_DIR}/in_flight_bytes.cnt")
        usable=$(( avail_bytes - in_flight - buffer_bytes ))

        if (( usable >= file_size )); then
            return 0
        fi

        # Nothing in flight that could free space — exit immediately to avoid
        # spinning until DISK_WAIT_TIMEOUT on a situation that cannot resolve itself
        local active_dl active_ul
        active_dl=$(_counter_get "${TEMP_DIR}/active_downloaders.cnt")
        active_ul=$(_counter_get "${TEMP_DIR}/active_uploaders.cnt")

        if (( active_dl == 0 && active_ul == 0 )); then
            log "WARN" "[DL${worker_id}] Disk space insufficient and no active workers — skipping (need ${file_size}B, usable ${usable}B)"
            return 1
        fi

        if (( waited >= DISK_WAIT_TIMEOUT )); then
            log "WARN" "[DL${worker_id}] Disk space wait timed out after ${waited}s — skipping (need ${file_size}B, usable ${usable}B)"
            return 1
        fi

        log "DEBUG" "[DL${worker_id}] Waiting for disk: need ${file_size}B, usable ${usable}B (avail=${avail_bytes}, in_flight=${in_flight}, buffer=${buffer_bytes}). Active: dl=${active_dl} ul=${active_ul}. Waited ${waited}s/${DISK_WAIT_TIMEOUT}s"
        sleep "${DISK_WAIT_INTERVAL}"
        (( waited += DISK_WAIT_INTERVAL )) || true
    done
}