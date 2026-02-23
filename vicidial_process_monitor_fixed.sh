#!/bin/bash
# ViciDial Process Monitor Daemon v1.1
# FIX: Removed persistent screen daemons from MAX_RUNTIME
#      (AST_VDauto_dial.pl, AST_VDremote_agents.pl, AST_VDadapt.pl are
#       long-running daemons — NOT cron jobs — and must never be runtime-killed)
set -euo pipefail

MONITOR_INTERVAL=60  # Seconds between scans
LOG_FILE="/var/log/astguiclient/process_monitor.log"
PID_FILE="/var/run/vicidial_process_monitor.pid"

# Maximum allowed runtime per script (seconds) before force-kill
# IMPORTANT: Only include ONE-SHOT cron scripts here, never persistent daemons
declare -A MAX_RUNTIME=(
    ["ADMIN_keepalive_ALL.pl"]=240
    ["AST_VDhopper.pl"]=180
    ["AST_VDauto_dial_FILL.pl"]=180
    ["AST_flush_DBqueue.pl"]=120
    ["AST_CRON_audio_1_move_mix.pl"]=120
    ["AST_CRON_audio_2_compress.pl"]=180
    # REMOVED - these are persistent screen daemons, NOT cron jobs:
    # ["AST_VDauto_dial.pl"]=180
    # ["AST_VDremote_agents.pl"]=180
    # ["AST_VDadapt.pl"]=180
    # REMOVED - these scripts don't exist in this install:
    # ["keepalive_AST_VDauto_dial.pl"]=60
    # ["keepalive_AST_send_listen.pl"]=60
    # ["keepalive_AST_VDadapt.pl"]=60
)

# Scripts monitored for duplicate instances (cron jobs only)
# Persistent daemons are excluded — keepalive handles them
declare -a WATCHED_SCRIPTS=(
    "ADMIN_keepalive_ALL.pl"
    "AST_VDhopper.pl"
    "AST_VDauto_dial_FILL.pl"
    "AST_flush_DBqueue.pl"
    # REMOVED from duplicate-checking — these are persistent daemons:
    # "AST_VDauto_dial.pl"
    # "AST_VDremote_agents.pl"
    # "AST_VDadapt.pl"
)

mkdir -p "$(dirname "$LOG_FILE")"

mlog() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

# Singleton: only one monitor runs at a time
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "0")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Monitor already running (PID: $OLD_PID) - exiting"
        exit 0
    fi
    rm -f "$PID_FILE"
fi

echo $$ > "$PID_FILE"

cleanup() {
    mlog "Monitor shutting down (PID: $$)"
    rm -f "$PID_FILE"
    exit 0
}
trap cleanup EXIT INT TERM

mlog "=========================================="
mlog "ViciDial Process Monitor started v1.1 (PID: $$)"
mlog "Scan interval: ${MONITOR_INTERVAL}s"
mlog "Watching: ${#WATCHED_SCRIPTS[@]} scripts"
mlog "=========================================="

get_runtime() {
    ps -p "$1" -o etimes= 2>/dev/null | tr -d ' ' || echo "0"
}

kill_proc() {
    local pid=$1 name=$2 reason=$3
    mlog "ACTION: Terminating $name (PID: $pid) - $reason"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        mlog "ACTION: SIGTERM ignored, sending SIGKILL to $pid"
        kill -KILL "$pid" 2>/dev/null || true
    fi
    mlog "ACTION: $name PID $pid terminated"
}

SCAN_COUNT=0
while true; do
    SCAN_COUNT=$((SCAN_COUNT + 1))
    mlog "--- Scan #$SCAN_COUNT ---"
    KILLED_THIS_SCAN=0

    # ---- Check for duplicate instances (cron jobs only) ----
    for script in "${WATCHED_SCRIPTS[@]}"; do
        PIDS=$(pgrep -f "$script" 2>/dev/null || true)
        [ -z "$PIDS" ] && continue

        COUNT=$(echo "$PIDS" | wc -l)
        if [ "$COUNT" -gt 1 ]; then
            mlog "WARN: $COUNT instances of $script found"
            SORTED=$(for p in $PIDS; do
                START=$(ps -p $p -o lstart= 2>/dev/null || echo "")
                EPOCH=$(date +%s -d "$START" 2>/dev/null || echo "0")
                echo "$EPOCH $p"
            done | sort -n | awk '{print $2}')
            KEEP=$(echo "$SORTED" | head -1)
            KILL_LIST=$(echo "$SORTED" | tail -n +2)
            mlog "INFO: Keeping oldest PID $KEEP"
            for pid in $KILL_LIST; do
                kill_proc "$pid" "$script" "Duplicate instance #$((KILLED_THIS_SCAN+1))"
                KILLED_THIS_SCAN=$((KILLED_THIS_SCAN + 1))
            done
        fi
    done

    # ---- Check for runaway cron processes exceeding max runtime ----
    for script in "${!MAX_RUNTIME[@]}"; do
        MAX_SEC=${MAX_RUNTIME[$script]}
        PIDS=$(pgrep -f "$script" 2>/dev/null || true)
        [ -z "$PIDS" ] && continue
        for pid in $PIDS; do
            RT=$(get_runtime "$pid")
            if [ "$RT" -gt "$MAX_SEC" ]; then
                kill_proc "$pid" "$script" \
                    "Runtime exceeded: ${RT}s > ${MAX_SEC}s max"
                KILLED_THIS_SCAN=$((KILLED_THIS_SCAN + 1))
            fi
        done
    done

    if [ "$KILLED_THIS_SCAN" -eq 0 ]; then
        mlog "INFO: All processes healthy (0 actions taken)"
    else
        mlog "SUMMARY: Killed $KILLED_THIS_SCAN process(es) this scan"
    fi

    sleep "$MONITOR_INTERVAL"
done
