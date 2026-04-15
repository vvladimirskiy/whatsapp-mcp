#!/bin/bash
# run-bridge.sh — Canonical launcher for the WhatsApp bridge.
# Ensures only ONE bridge process runs at a time, then exec's the binary
# so launchd can manage the process lifecycle directly.
#
# Usage:
#   Manual:  ./run-bridge.sh          (runs in foreground, Ctrl-C to stop)
#   launchd: ProgramArguments points here; KeepAlive restarts on exit
#
# The script:
#   1. Kills any existing bridge processes (PID file + pgrep sweep)
#   2. Writes a PID file for external tooling
#   3. exec's the binary (replaces this shell — launchd sees the real process)

set -euo pipefail

PIDFILE="/tmp/whatsapp-bridge.pid"
BRIDGE_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE_BIN="${BRIDGE_DIR}/whatsapp-bridge"
BRIDGE_PORT=8080
LOG_TAG="[run-bridge]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_TAG} $*"; }

# ── Step 1: Kill any existing bridge processes ──────────────────────────

# 1a. Kill process from PID file (graceful SIGTERM first)
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "Sending SIGTERM to existing bridge PID $OLD_PID"
        kill "$OLD_PID" 2>/dev/null || true
        # Wait up to 5 seconds for graceful shutdown
        for i in $(seq 1 10); do
            kill -0 "$OLD_PID" 2>/dev/null || break
            sleep 0.5
        done
        # Force kill if still alive
        if kill -0 "$OLD_PID" 2>/dev/null; then
            log "PID $OLD_PID did not exit gracefully, sending SIGKILL"
            kill -9 "$OLD_PID" 2>/dev/null || true
            sleep 1
        fi
    fi
    rm -f "$PIDFILE"
fi

# 1b. Sweep for any orphaned bridge processes (by binary path)
STALE_PIDS=$(pgrep -f "${BRIDGE_BIN}" 2>/dev/null || true)
if [ -n "$STALE_PIDS" ]; then
    for PID in $STALE_PIDS; do
        # Don't kill ourselves
        if [ "$PID" != "$$" ]; then
            log "Killing orphaned bridge process PID $PID"
            kill "$PID" 2>/dev/null || true
        fi
    done
    sleep 2
    # Force-kill any survivors
    STALE_PIDS=$(pgrep -f "${BRIDGE_BIN}" 2>/dev/null || true)
    for PID in $STALE_PIDS; do
        if [ "$PID" != "$$" ]; then
            log "Force-killing stubborn bridge process PID $PID"
            kill -9 "$PID" 2>/dev/null || true
        fi
    done
    sleep 1
fi

# Also kill anything listening on the bridge port (belt and suspenders)
PORT_PID=$(lsof -ti :${BRIDGE_PORT} 2>/dev/null || true)
if [ -n "$PORT_PID" ]; then
    for PID in $PORT_PID; do
        if [ "$PID" != "$$" ]; then
            log "Killing process PID $PID holding port ${BRIDGE_PORT}"
            kill "$PID" 2>/dev/null || true
        fi
    done
    sleep 1
fi

log "All existing bridge processes cleared"

# ── Step 2: Write PID file (will be our PID, then replaced by exec) ────

cd "$BRIDGE_DIR"

# Write a PID file. After exec, this PID stays the same (exec replaces
# the process image but keeps the PID).
echo $$ > "$PIDFILE"
log "Starting bridge (PID $$)"

# ── Step 3: Trap to clean up PID file on exit ──────────────────────────

cleanup() {
    rm -f "$PIDFILE"
    log "Bridge exited, PID file removed"
}
trap cleanup EXIT

# ── Step 4: exec the bridge binary ─────────────────────────────────────
# exec replaces this shell process with the bridge binary.
# This means:
#   - launchd sees the real bridge process (not a wrapper shell)
#   - The PID file remains valid
#   - SIGTERM from launchd goes directly to the bridge
#   - The bridge's own signal handler (SIGINT/SIGTERM -> clean disconnect) works

exec "$BRIDGE_BIN"
