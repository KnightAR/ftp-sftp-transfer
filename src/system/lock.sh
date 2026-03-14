#!/usr/bin/env bash
# ============================================================
# src/system/lock.sh — PID Lock File Management
#
# Prevents two instances of transfer.sh from running at the same
# time (e.g. overlapping cron jobs on a slow transfer day).
#
# Uses a file descriptor lock (flock) rather than a simple PID
# file so the lock is automatically released by the OS if the
# process is killed without reaching release_lock() — no stale
# lock files left behind after a crash.
#
#   acquire_lock() — opens LOCK_FD on LOCK_FILE and acquires an
#                    exclusive non-blocking flock.  Exits with an
#                    informative error if another instance holds it.
#
#   release_lock() — unlocks LOCK_FD and removes LOCK_FILE.
#                    Called both by trap_cleanup() (abnormal exit)
#                    and the clean-exit path in main().
#
# Dependency order:
#   Must be sourced after src/core/constants.sh (needs LOCK_FILE,
#   LOCK_FD, SCRIPT_NAME).
# ============================================================

acquire_lock() {
    # Open LOCK_FD pointing at LOCK_FILE; flock -n fails immediately
    # if another process already holds the exclusive lock.
    eval "exec ${LOCK_FD}>'${LOCK_FILE}'"
    if ! flock -n "${LOCK_FD}"; then
        local existing_pid
        existing_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "unknown")
        echo "ERROR: Another instance of ${SCRIPT_NAME} is already running (PID: ${existing_pid})." >&2
        echo "       If this is incorrect, remove the lock file: ${LOCK_FILE}" >&2
        exit 1
    fi
    # Write our PID into the lock file so operators can identify the running instance
    echo $$ > "${LOCK_FILE}"
}

release_lock() {
    flock -u "${LOCK_FD}" 2>/dev/null || true
    rm -f "${LOCK_FILE}"
}