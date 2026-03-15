#!/usr/bin/env bash
# ============================================================
# src/system/trap.sh — Signal Traps & Interrupt Cleanup
#
# Defines trap_cleanup() and registers it as the handler for
# INT, TERM, and EXIT signals.
#
# trap_cleanup() is invoked automatically by bash whenever the
# script exits — whether cleanly, via Ctrl+C, or via SIGTERM
# (e.g. from kill or a process supervisor).  It:
#
#   1. Sends SIGTERM to all tracked worker PIDs (WORKER_PIDS[]).
#      Workers are tracked so that SIGTERM (which does NOT
#      automatically broadcast to a process group the way SIGINT
#      does) still reaches every background sub-process.
#   2. Waits up to 5 seconds for workers to exit cleanly.
#   3. Force-kills (SIGKILL) any workers still running after the
#      grace period, preventing orphaned processes writing to
#      paths that cleanup_temp() is about to delete.
#   4. Calls cleanup_temp() to remove the staging area.
#   5. Calls release_lock() to remove the PID lock file.
#
# The trap is intentionally removed at the end of a clean run
# in main() (via "trap - INT TERM EXIT") so that the final
# cleanup_temp() / release_lock() calls in main() do not trigger
# a second cleanup pass through this handler.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()),
#   src/system/temp.sh (uses cleanup_temp()),
#   src/system/lock.sh (uses release_lock()), and
#   src/core/constants.sh (reads WORKER_PIDS[]).
#   The trap registration line at the bottom of this file fires
#   at source time, so all dependencies must be sourced first.
# ============================================================

trap_cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        log "WARN" "Script interrupted or exited unexpectedly (exit code: ${exit_code}). Cleaning up..."
    fi

    # Kill all tracked worker processes before wiping staging.
    # This prevents workers writing to paths that cleanup_temp is about to delete,
    # and ensures SIGTERM (e.g. from "kill <pid>") propagates to workers even though
    # SIGTERM does not automatically broadcast to the whole process group like SIGINT does.
    if (( ${#WORKER_PIDS[@]} > 0 )); then
        log "WARN" "Sending SIGTERM to ${#WORKER_PIDS[@]} worker process(es)..."
        kill "${WORKER_PIDS[@]}" 2>/dev/null || true

        # Give workers up to 5 seconds to exit cleanly before cleanup proceeds
        local wait_tries=0
        while (( wait_tries < 5 )); do
            local still_running=0
            local pid
            for pid in "${WORKER_PIDS[@]}"; do
                kill -0 "${pid}" 2>/dev/null && (( still_running++ )) || true
            done
            (( still_running == 0 )) && break
            sleep 1
            (( wait_tries++ )) || true
        done

        # Force-kill any workers that didn't exit in time
        kill -9 "${WORKER_PIDS[@]}" 2>/dev/null || true
    fi

    cleanup_temp
    release_lock
    exit "${exit_code}"
}

# Register the cleanup handler for all exit paths.
# This line fires at source time — all dependency modules must be sourced before this file.
trap trap_cleanup INT TERM EXIT