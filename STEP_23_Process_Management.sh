#!/bin/bash
################################################################################
# STEP 23: ViciDial Process Management Infrastructure
# Modular Addon Script - Standalone / Run After Any Part 2 Install
#
# Version:  1.0
# Created:  2026-02-16
# Author:   Striker24x7 + Claude (Anthropic)
# Target:   Rocky Linux 10.x / AlmaLinux 10.x
#
# PURPOSE:
#   This script can be run independently AFTER any ViciDial Part 2 install.
#   It deploys the full process locking infrastructure to eliminate the
#   ADMIN_keepalive_ALL.pl duplicate process bug.
#
# WHAT IT DOES:
#   1. Deploys /usr/local/bin/vicidial_cron_wrapper.sh (flock-based wrapper)
#   2. Deploys /usr/local/bin/vicidial_process_monitor.sh (monitor daemon)
#   3. Installs vicidial-process-monitor.service (systemd service)
#   4. Installs vicidial-keepalive.timer (systemd timer - replaces raw cron)
#   5. Migrates existing crontab: removes raw keepalive, wraps high-freq jobs
#   6. Kills any currently-running duplicate processes
#   7. Verifies everything is working
#
# USAGE:
#   chmod +x STEP_23_Process_Management.sh
#   ./STEP_23_Process_Management.sh
#
# SAFE TO RE-RUN:  Yes - all steps are idempotent
################################################################################

set -euo pipefail

trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

handle_error() {
    echo -e "\n${RED}╔═════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ERROR on line $1${NC}"
    echo -e "${RED}║  Command: $2${NC}"
    echo -e "${RED}╚═════════════════════════════════════════╝${NC}\n"
    echo "Check log: $LOG_FILE"
    exit 1
}

# ---------------------------------------------------------------------------
# COLORS & LOGGING
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOG_FILE="/var/log/vicidial_step23_process_mgmt.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()     { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
section() {
    echo -e "\n${BLUE}${BOLD}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║ $1${NC}"
    echo -e "${BLUE}${BOLD}╚═══════════════════════════════════════════╝${NC}\n"
}

# ---------------------------------------------------------------------------
# BANNER
# ---------------------------------------------------------------------------
clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║      ViciDial - STEP 23: Process Management v1.0            ║"
echo "║      Modular Addon - Run After Any Part 2 Install            ║"
echo "║                                                              ║"
echo "║  Fixes: Duplicate ADMIN_keepalive_ALL.pl processes           ║"
echo "║  Uses:  systemd timers + flock wrappers + monitor daemon     ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ---------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# ---------------------------------------------------------------------------
section "PRE-FLIGHT CHECKS"

[ "$EUID" -ne 0 ] && error "Run as root (sudo su -)"

# OS check - Rocky or AlmaLinux
if [ -f /etc/rocky-release ]; then
    OS_NAME="Rocky Linux"
elif [ -f /etc/almalinux-release ]; then
    OS_NAME="AlmaLinux"
else
    error "Requires Rocky Linux 10.x or AlmaLinux 10.x"
fi
success "OS: $OS_NAME detected"

# ViciDial must be installed
if [ ! -d /usr/share/astguiclient ]; then
    error "/usr/share/astguiclient not found - run ViciDial Part 2 install first"
fi
success "ViciDial installation found: /usr/share/astguiclient"

# Critical script must exist
if [ ! -f /usr/share/astguiclient/ADMIN_keepalive_ALL.pl ]; then
    error "ADMIN_keepalive_ALL.pl not found - Part 2 may not be complete"
fi
success "ADMIN_keepalive_ALL.pl found"

# systemd must be running
if ! systemctl is-system-running --quiet 2>/dev/null | grep -qE "running|degraded"; then
    warning "systemd may not be fully operational - continuing anyway"
fi
success "systemd is available"

START_TIME=$(date +%s)
log "Starting Step 23 - logging to $LOG_FILE"

# ---------------------------------------------------------------------------
# STEP A: KILL ANY CURRENTLY-RUNNING DUPLICATES (immediate relief)
# ---------------------------------------------------------------------------
section "STEP A: IMMEDIATE DUPLICATE PROCESS CLEANUP"

log "Checking for currently-running duplicate ViciDial processes..."

for script in ADMIN_keepalive_ALL.pl AST_VDhopper.pl AST_VDauto_dial.pl; do
    PIDS=$(pgrep -f "$script" 2>/dev/null || true)
    if [ -z "$PIDS" ]; then
        info "$script: not running"
        continue
    fi
    COUNT=$(echo "$PIDS" | wc -l)
    if [ "$COUNT" -gt 1 ]; then
        warning "Found $COUNT instances of $script - killing duplicates now"
        # Keep oldest (first started), kill the rest
        SORTED=$(for p in $PIDS; do
            echo "$(ps -p $p -o lstart= 2>/dev/null | date +%s -f - 2>/dev/null || echo 0) $p"
        done | sort -n | awk '{print $2}')
        KEEP=$(echo "$SORTED" | head -1)
        KILL=$(echo "$SORTED" | tail -n +2)
        log "  Keeping PID $KEEP (oldest)"
        for pid in $KILL; do
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
            log "  Killed duplicate PID $pid"
        done
        success "$script duplicates eliminated"
    else
        success "$script: $COUNT instance running (OK)"
    fi
done

# ---------------------------------------------------------------------------
# STEP B: DEPLOY flock-BASED CRON WRAPPER
# ---------------------------------------------------------------------------
section "STEP B: DEPLOY flock CRON WRAPPER"

log "Installing /usr/local/bin/vicidial_cron_wrapper.sh..."

# Backup existing if present
if [ -f /usr/local/bin/vicidial_cron_wrapper.sh ]; then
    cp /usr/local/bin/vicidial_cron_wrapper.sh \
        "/usr/local/bin/vicidial_cron_wrapper.sh.backup-$(date +%Y%m%d-%H%M%S)"
    info "Backed up existing wrapper"
fi

mkdir -p /var/lock/vicidial /var/log/astguiclient
chmod 755 /var/lock/vicidial

cat > /usr/local/bin/vicidial_cron_wrapper.sh << 'WRAPPER_EOF'
#!/bin/bash
# ViciDial flock-based process wrapper v1.0
# Prevents duplicate instances of any wrapped script
# Usage: vicidial_cron_wrapper.sh /path/to/script.pl [args...]
set -euo pipefail

LOCK_DIR="/var/lock/vicidial"
LOG_DIR="/var/log/astguiclient"
MAX_LOCK_AGE=300    # Consider lock stale after 5 minutes
SCRIPT_TIMEOUT=240  # Kill script if it runs longer than 4 minutes

mkdir -p "$LOCK_DIR" "$LOG_DIR"

[ $# -eq 0 ] && { echo "Usage: $0 /path/to/script.pl [args...]"; exit 1; }

SCRIPT="$1"; shift; ARGS="${*:-}"
SCRIPT_NAME=$(basename "$SCRIPT" .pl)
LOCKFILE="${LOCK_DIR}/${SCRIPT_NAME}.lock"
LOGFILE="${LOG_DIR}/${SCRIPT_NAME}_wrapper.log"
PIDFILE="${LOCK_DIR}/${SCRIPT_NAME}.pid"

wlog() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$$] $1" >> "$LOGFILE"; }

# Remove stale locks
if [ -f "$LOCKFILE" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0) ))
    if [ "$LOCK_AGE" -gt "$MAX_LOCK_AGE" ]; then
        wlog "Removing stale lock (${LOCK_AGE}s old)"
        rm -f "$LOCKFILE" "$PIDFILE"
    fi
fi

# Acquire exclusive non-blocking lock - skip if already locked
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    wlog "Skipping: previous instance still running"
    exit 0
fi

wlog "Lock acquired - running: $SCRIPT $ARGS"
echo $$ > "$PIDFILE"

cleanup() {
    local EC=$?
    wlog "Exiting (code: $EC)"
    rm -f "$PIDFILE"
}
trap cleanup EXIT INT TERM

# Run with timeout - prevents runaway processes
if [ -n "$ARGS" ]; then
    timeout "$SCRIPT_TIMEOUT" "$SCRIPT" $ARGS >> "$LOGFILE" 2>&1
else
    timeout "$SCRIPT_TIMEOUT" "$SCRIPT" >> "$LOGFILE" 2>&1
fi

EXIT_CODE=$?
wlog "Completed (exit: $EXIT_CODE)"
exit $EXIT_CODE
WRAPPER_EOF

chmod +x /usr/local/bin/vicidial_cron_wrapper.sh
success "flock wrapper installed: /usr/local/bin/vicidial_cron_wrapper.sh"

# Quick smoke test
if /usr/local/bin/vicidial_cron_wrapper.sh 2>&1 | grep -q "Usage:"; then
    success "Wrapper smoke test: usage message returned correctly"
fi

# ---------------------------------------------------------------------------
# STEP C: DEPLOY PROCESS MONITOR DAEMON
# ---------------------------------------------------------------------------
section "STEP C: DEPLOY PROCESS MONITOR DAEMON"

log "Installing /usr/local/bin/vicidial_process_monitor.sh..."

if [ -f /usr/local/bin/vicidial_process_monitor.sh ]; then
    cp /usr/local/bin/vicidial_process_monitor.sh \
        "/usr/local/bin/vicidial_process_monitor.sh.backup-$(date +%Y%m%d-%H%M%S)"
    info "Backed up existing monitor"
fi

cat > /usr/local/bin/vicidial_process_monitor.sh << 'MONITOR_EOF'
#!/bin/bash
# ViciDial Process Monitor Daemon v1.0
# Actively scans for and eliminates duplicate/runaway ViciDial processes
set -euo pipefail

MONITOR_INTERVAL=60  # Seconds between scans
LOG_FILE="/var/log/astguiclient/process_monitor.log"
PID_FILE="/var/run/vicidial_process_monitor.pid"

# Maximum allowed runtime per script (seconds) before force-kill
declare -A MAX_RUNTIME=(
    ["ADMIN_keepalive_ALL.pl"]=240
    ["AST_VDhopper.pl"]=180
    ["AST_VDauto_dial.pl"]=180
    ["AST_VDauto_dial_FILL.pl"]=180
    ["AST_flush_DBqueue.pl"]=120
    ["AST_VDremote_agents.pl"]=180
    ["AST_VDadapt.pl"]=180
    ["AST_CRON_audio_1_move_mix.pl"]=120
    ["AST_CRON_audio_2_compress.pl"]=180
    ["keepalive_AST_VDauto_dial.pl"]=60
    ["keepalive_AST_send_listen.pl"]=60
    ["keepalive_AST_VDadapt.pl"]=60
)

# Scripts monitored for duplicate instances
declare -a WATCHED_SCRIPTS=(
    "ADMIN_keepalive_ALL.pl"
    "AST_VDhopper.pl"
    "AST_VDauto_dial.pl"
    "AST_VDauto_dial_FILL.pl"
    "AST_flush_DBqueue.pl"
    "AST_VDremote_agents.pl"
    "AST_VDadapt.pl"
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
mlog "ViciDial Process Monitor started (PID: $$)"
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

    # ---- Check for duplicate instances ----
    for script in "${WATCHED_SCRIPTS[@]}"; do
        PIDS=$(pgrep -f "$script" 2>/dev/null || true)
        [ -z "$PIDS" ] && continue

        COUNT=$(echo "$PIDS" | wc -l)
        if [ "$COUNT" -gt 1 ]; then
            mlog "WARN: $COUNT instances of $script found"
            # Sort by start time ascending, keep oldest (most stable)
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

    # ---- Check for runaway processes exceeding max runtime ----
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
MONITOR_EOF

chmod +x /usr/local/bin/vicidial_process_monitor.sh
success "Process monitor installed: /usr/local/bin/vicidial_process_monitor.sh"

# ---------------------------------------------------------------------------
# STEP D: INSTALL AND START SYSTEMD SERVICE (monitor daemon)
# ---------------------------------------------------------------------------
section "STEP D: SYSTEMD SERVICE - PROCESS MONITOR"

cat > /etc/systemd/system/vicidial-process-monitor.service << 'SERVICE_EOF'
[Unit]
Description=ViciDial Process Monitor Daemon
Documentation=file:///usr/local/bin/vicidial_process_monitor.sh
After=mariadb.service network.target
Wants=mariadb.service

[Service]
Type=simple
ExecStart=/usr/local/bin/vicidial_process_monitor.sh
Restart=always
RestartSec=10
User=root
StandardOutput=journal
StandardError=journal
# Give it time to shut down cleanly
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable vicidial-process-monitor.service

# Stop existing instance if running (for idempotent re-runs)
systemctl stop vicidial-process-monitor.service 2>/dev/null || true
sleep 1
systemctl start vicidial-process-monitor.service
sleep 2

if systemctl is-active --quiet vicidial-process-monitor; then
    success "vicidial-process-monitor.service is RUNNING"
else
    warning "Monitor service failed to start"
    journalctl -u vicidial-process-monitor --no-pager -n 20 || true
fi

# ---------------------------------------------------------------------------
# STEP E: INSTALL SYSTEMD TIMER FOR ADMIN_keepalive_ALL.pl
# ---------------------------------------------------------------------------
section "STEP E: SYSTEMD TIMER - KEEPALIVE (replaces raw cron)"

cat > /etc/systemd/system/vicidial-keepalive.service << 'KEEPALIVE_SVC'
[Unit]
Description=ViciDial Master Keepalive (single-shot via systemd timer)
Documentation=file:///usr/share/astguiclient/ADMIN_keepalive_ALL.pl
After=mariadb.service
Requires=mariadb.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vicidial_cron_wrapper.sh \
    /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --cu3way
User=root
TimeoutStartSec=240
Restart=no
RemainAfterExit=no
StandardOutput=journal
StandardError=journal
KEEPALIVE_SVC

cat > /etc/systemd/system/vicidial-keepalive.timer << 'KEEPALIVE_TMR'
[Unit]
Description=ViciDial Keepalive Timer (every 60 seconds)
Documentation=man:systemd.timer(5)
Requires=vicidial-keepalive.service

[Timer]
# Delay first run to allow system to settle after boot
OnBootSec=2min
# Subsequent runs: 60 seconds after the previous run ACTIVATED
OnUnitActiveSec=1min
# Tight accuracy - don't batch/delay
AccuracySec=1s
# Don't try to catch up missed runs after downtime
Persistent=false

[Install]
WantedBy=timers.target
KEEPALIVE_TMR

systemctl daemon-reload
systemctl enable vicidial-keepalive.timer

# Stop then start for idempotent re-runs
systemctl stop vicidial-keepalive.timer 2>/dev/null || true
sleep 1
systemctl start vicidial-keepalive.timer
sleep 2

if systemctl is-active --quiet vicidial-keepalive.timer; then
    success "vicidial-keepalive.timer is ACTIVE"
    NEXT_RUN=$(systemctl list-timers vicidial-keepalive.timer --no-pager 2>/dev/null \
        | grep vicidial | awk '{print $1, $2}' || echo "check systemctl list-timers")
    info "Next run: $NEXT_RUN"
else
    warning "Keepalive timer failed to activate"
    systemctl status vicidial-keepalive.timer --no-pager || true
fi

# ---------------------------------------------------------------------------
# STEP F: MIGRATE CRONTAB
#   - Remove any raw ADMIN_keepalive_ALL.pl cron entry
#   - Wrap high-frequency scripts with vicidial_cron_wrapper.sh
# ---------------------------------------------------------------------------
section "STEP F: CRONTAB MIGRATION"

log "Reading current crontab..."
CRONTAB_CURRENT=$(crontab -l 2>/dev/null || echo "")

if [ -z "$CRONTAB_CURRENT" ]; then
    info "No existing crontab found - installing fresh ViciDial crontab"
    CRONTAB_BASE=""
else
    log "Existing crontab has $(echo "$CRONTAB_CURRENT" | wc -l) lines"
    # Backup
    echo "$CRONTAB_CURRENT" > /tmp/crontab_pre_step23.backup
    info "Crontab backed up to: /tmp/crontab_pre_step23.backup"
    CRONTAB_BASE="$CRONTAB_CURRENT"
fi

# Remove raw ADMIN_keepalive_ALL.pl entries (now managed by systemd timer)
CRONTAB_CLEANED=$(echo "$CRONTAB_BASE" | grep -v "ADMIN_keepalive_ALL" || true)
if [ "$CRONTAB_CLEANED" != "$CRONTAB_BASE" ]; then
    REMOVED=$(echo "$CRONTAB_BASE" | grep "ADMIN_keepalive_ALL" | wc -l)
    success "Removed $REMOVED raw ADMIN_keepalive_ALL.pl cron entry(ies) (now via systemd timer)"
else
    info "No raw ADMIN_keepalive_ALL.pl cron entries found (already clean)"
fi

# Wrap any remaining unwrapped high-frequency scripts
HIGH_FREQ_SCRIPTS=(
    "AST_VDhopper.pl"
    "AST_VDauto_dial.pl"
    "AST_VDauto_dial_FILL.pl"
    "AST_flush_DBqueue.pl"
    "AST_VDremote_agents.pl"
    "AST_VDadapt.pl"
    "AST_CRON_audio_1_move_mix.pl"
    "AST_CRON_audio_2_compress.pl"
    "keepalive_AST_VDauto_dial.pl"
    "keepalive_AST_send_listen.pl"
    "keepalive_AST_VDadapt.pl"
)

WRAPPER_PATH="/usr/local/bin/vicidial_cron_wrapper.sh"
WRAPPED_COUNT=0

for script in "${HIGH_FREQ_SCRIPTS[@]}"; do
    # Check if this script appears in crontab WITHOUT the wrapper
    if echo "$CRONTAB_CLEANED" | grep -q "$script" && \
       ! echo "$CRONTAB_CLEANED" | grep "$script" | grep -q "vicidial_cron_wrapper"; then
        # Wrap it: replace the path with wrapper + path
        CRONTAB_CLEANED=$(echo "$CRONTAB_CLEANED" | \
            sed "s|/usr/share/astguiclient/${script}|${WRAPPER_PATH} /usr/share/astguiclient/${script}|g")
        WRAPPED_COUNT=$((WRAPPED_COUNT + 1))
        info "Wrapped: $script"
    fi
done

if [ "$WRAPPED_COUNT" -gt 0 ]; then
    success "Wrapped $WRAPPED_COUNT high-frequency script(s) with flock wrapper"
else
    info "All high-frequency scripts already wrapped (or not in crontab)"
fi

# Install the updated crontab
echo "$CRONTAB_CLEANED" | crontab -
CRON_COUNT=$(crontab -l | grep -c "astguiclient" || echo "0")
success "Crontab updated ($CRON_COUNT ViciDial job(s) installed)"
info "ADMIN_keepalive_ALL.pl removed from cron - now runs via: vicidial-keepalive.timer"

# ---------------------------------------------------------------------------
# STEP G: VERIFICATION
# ---------------------------------------------------------------------------
section "STEP G: FINAL VERIFICATION"

ERRORS=0
WARNINGS=0

# flock wrapper
if [ -x /usr/local/bin/vicidial_cron_wrapper.sh ]; then
    success "✅ flock wrapper: /usr/local/bin/vicidial_cron_wrapper.sh"
else
    echo -e "${RED}[FAIL]${NC} flock wrapper not installed or not executable"
    ERRORS=$((ERRORS + 1))
fi

# Process monitor daemon
if [ -x /usr/local/bin/vicidial_process_monitor.sh ]; then
    success "✅ Process monitor: /usr/local/bin/vicidial_process_monitor.sh"
else
    echo -e "${RED}[FAIL]${NC} Process monitor not installed"
    ERRORS=$((ERRORS + 1))
fi

# Monitor service running
if systemctl is-active --quiet vicidial-process-monitor; then
    success "✅ vicidial-process-monitor.service: RUNNING"
else
    warning "⚠️  vicidial-process-monitor.service: NOT RUNNING"
    WARNINGS=$((WARNINGS + 1))
fi

# Keepalive timer active
if systemctl is-active --quiet vicidial-keepalive.timer; then
    success "✅ vicidial-keepalive.timer: ACTIVE"
else
    warning "⚠️  vicidial-keepalive.timer: NOT ACTIVE"
    WARNINGS=$((WARNINGS + 1))
fi

# No raw keepalive in crontab
if crontab -l 2>/dev/null | grep -q "ADMIN_keepalive_ALL"; then
    warning "⚠️  Raw ADMIN_keepalive_ALL.pl still in crontab - remove manually"
    WARNINGS=$((WARNINGS + 1))
else
    success "✅ Crontab: no raw keepalive entry (managed by timer)"
fi

# No current duplicate keepalive processes
KA_COUNT=$( { pgrep -f "ADMIN_keepalive_ALL.pl" 2>/dev/null || true; } | wc -l )
KA_COUNT="${KA_COUNT//[[:space:]]/}"
if [ "$KA_COUNT" -le 1 ]; then
    success "✅ Duplicate process check: $KA_COUNT keepalive instance(s) - OK"
else
    warning "⚠️  $KA_COUNT keepalive instances found (monitor will kill duplicates within 60s)"
    WARNINGS=$((WARNINGS + 1))
fi

# Completion
END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

echo ""
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅  STEP 23 COMPLETE - ZERO ISSUES                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠️   STEP 23 COMPLETE - $WARNINGS WARNING(S)               ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
else
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ❌  STEP 23 COMPLETE - $ERRORS ERROR(S), $WARNINGS WARNING(S)   ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
fi

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  WHAT WAS DEPLOYED                                       ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}flock Wrapper   :${NC} /usr/local/bin/vicidial_cron_wrapper.sh"
echo -e "  ${GREEN}Process Monitor :${NC} /usr/local/bin/vicidial_process_monitor.sh"
echo -e "  ${GREEN}Monitor Service :${NC} vicidial-process-monitor.service (systemd)"
echo -e "  ${GREEN}Keepalive Timer :${NC} vicidial-keepalive.timer (every 60s)"
echo -e "  ${GREEN}Crontab         :${NC} Migrated - keepalive removed, scripts wrapped"
echo -e "  ${GREEN}Log File        :${NC} $LOG_FILE"
echo -e "  ${GREEN}Run Time        :${NC} ${DURATION}s"
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  MONITORING COMMANDS                                     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}systemctl status vicidial-process-monitor${NC}"
echo -e "  ${GREEN}systemctl status vicidial-keepalive.timer${NC}"
echo -e "  ${GREEN}systemctl list-timers vicidial-keepalive.timer${NC}"
echo -e "  ${GREEN}ps aux | grep ADMIN_keepalive | grep -v grep${NC}"
echo -e "     # Should show 0-1 processes - never 5-10!"
echo -e "  ${GREEN}tail -f /var/log/astguiclient/process_monitor.log${NC}"
echo -e "  ${GREEN}tail -f /var/log/astguiclient/ADMIN_keepalive_ALL_wrapper.log${NC}"
echo ""
echo -e "  To check timer health anytime:"
echo -e "  ${CYAN}journalctl -u vicidial-keepalive.service -f${NC}"
echo ""

exit 0
