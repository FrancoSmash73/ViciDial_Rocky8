# ViciDial ULTIMATE - Integration Guide
## Process Management Addon + Modular Architecture

**Version:** 1.0  
**Date:** February 16, 2026  
**Author:** Striker24x7 + Claude (Anthropic)  
**Target:** Rocky Linux 10.x / AlmaLinux 10.x

---

## Overview

The ViciDial installation is split into modular components that can be used together **or independently**. This guide explains how they relate and how to use them in different scenarios.

---

## 📦 What's In This Package

| File | Lines | Purpose |
|------|-------|---------|
| `ViciDial_ULTIMATE_Part2_FINAL.sh` | 3,117 | Complete Part 2 install (v11.0) — includes process locking as Step 22 |
| `STEP_23_Process_Management.sh` | ~450 | **Standalone** addon — run this on *any existing* ViciDial install |
| `INSTALLATION_GUIDE.md` | — | Quick start guide |
| `INTEGRATION_GUIDE.md` | — | This file |

---

## 🗺️ Integration Strategy

The approach is **additive, not destructive**:

```
Your existing Part 2 (steps 1-22)        ←  Unchanged / already excellent
              +
STEP_23: Process Management              ←  Added on top
              =
Bug-free ViciDial system                 ←  Result
```

### What Gets Modified in Part 2:
| Section | Change |
|---------|--------|
| Step 22 (Crontab) | `ADMIN_keepalive_ALL.pl` **removed** from raw cron |
| Step 22 (Crontab) | High-frequency scripts **wrapped** with flock wrapper |
| Step 23 (NEW) | Full process management infrastructure deployed |

### What NEVER Gets Touched:
- DAHDI installation (Steps 1)
- LibPRI (Step 2)
- Asterisk build and config (Steps 3-4)
- ViciDial SVN download (Step 5)
- Database setup (Steps 6-7)
- ConfBridge configuration (Steps 8-16)
- RC.local / startup scripts (Step 17)
- Asterisk startup (Step 18)
- Area codes / test leads (Steps 19-20)
- Server IP update (Step 21)

---

## 🚀 Scenario 1: Fresh Install on 2 Servers Simultaneously

Use `ViciDial_ULTIMATE_Part2_FINAL.sh` — it includes everything.

```bash
# On BOTH servers simultaneously:
chmod +x ViciDial_ULTIMATE_Part2_FINAL.sh
./ViciDial_ULTIMATE_Part2_FINAL.sh
```

**What you get:** All 23 steps, including process locking deployed as Step 22
before the crontab step. The keepalive runs via systemd timer from day one.

### Simultaneous Install Tips (tmux recommended):

```bash
# On your local machine - open a tmux session split across 2 panes

# Install tmux if needed:
dnf install -y tmux

# Start tmux and split horizontally
tmux new-session -d -s deploy
tmux split-window -h -t deploy
tmux send-keys -t deploy:0.0 'ssh root@SERVER1_IP' Enter
tmux send-keys -t deploy:0.1 'ssh root@SERVER2_IP' Enter
tmux attach -t deploy

# Then in each pane, run the script:
./ViciDial_ULTIMATE_Part2_FINAL.sh
```

---

## 🔧 Scenario 2: Existing ViciDial Install (Add Process Management Only)

If you already have a working ViciDial server and just want to fix the
duplicate process bug, use the standalone addon:

```bash
# Upload to your server, then:
chmod +x STEP_23_Process_Management.sh
./STEP_23_Process_Management.sh
```

**What it does:**
1. Immediately kills any currently-running duplicate processes
2. Installs the flock wrapper
3. Installs and starts the process monitor daemon
4. Installs and activates the systemd keepalive timer
5. Migrates your existing crontab (removes raw keepalive, wraps scripts)
6. Verifies everything is working

**Safe to run:** Idempotent — running it twice won't break anything.
Existing backups are created before any file modifications.

---

## 🔁 Scenario 3: Resume an Interrupted Install

Both scripts track progress in marker files. If an install is interrupted:

```bash
# ViciDial_ULTIMATE_Part2_FINAL.sh tracks progress in:
cat /root/.vicidial_part2_progress

# STEP_23_Process_Management.sh has no resume tracking
# (it runs in full each time - takes < 60 seconds)

# To resume the main script, just re-run it:
./ViciDial_ULTIMATE_Part2_FINAL.sh
# It will prompt: [S]kip / [R]e-run / [Q]uit for each completed step
```

---

## ⚙️ How Process Locking Works

### The Root Cause: Raw Cron Entries
```
# OLD (broken) - raw cron fires every minute regardless:
* * * * * /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --cu3way

# If one run takes > 60 seconds, a second starts while first is running.
# Third starts. Fourth starts. You end up with 5-10 overlapping processes.
```

### The Fix: systemd Timer + flock Wrapper

**Layer 1 — systemd Timer** (prevents accumulation):
```
# systemd timer with OnUnitActiveSec=1min:
# Next run starts 60 seconds AFTER the previous run FINISHED
# → If previous run takes 90s, next starts at 90+60=150s
# → Impossible to accumulate multiple instances
```

**Layer 2 — flock Wrapper** (belt-and-suspenders):
```bash
# Even if somehow two instances start simultaneously,
# the second immediately exits when it can't acquire the lock:
flock -n 200 || { wlog "Skipping: previous instance still running"; exit 0; }
```

**Layer 3 — Process Monitor Daemon** (active enforcement):
```
# Runs every 60 seconds
# If it finds > 1 instance of any watched script:
#   → Keeps the oldest (most stable)
#   → SIGTERM + SIGKILL all others
# Also kills runaway processes that exceed their max runtime
```

### Architecture Diagram:
```
┌─────────────────────────────────────────────────────┐
│                   EVERY 60 SECONDS                   │
│                                                      │
│  systemd timer fires                                 │
│        │                                             │
│        ▼                                             │
│  vicidial_cron_wrapper.sh (flock gate)               │
│        │                                             │
│        ├── Lock available? ──YES──▶ Run script       │
│        │                                             │
│        └── Lock taken? ────NO───▶ Exit quietly       │
│                                                      │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│              PROCESS MONITOR (every 60s)            │
│                                                      │
│  Scans all watched scripts                           │
│        │                                             │
│        ├── >1 instance? ──▶ Kill duplicates         │
│        └── Runtime > max? ─▶ Kill runaway           │
│                                                      │
└─────────────────────────────────────────────────────┘
```

---

## 📁 File Reference

### Files Deployed by Process Management

| File/Service | Location | Purpose |
|---|---|---|
| `vicidial_cron_wrapper.sh` | `/usr/local/bin/` | flock-based wrapper for all high-freq scripts |
| `vicidial_process_monitor.sh` | `/usr/local/bin/` | Daemon that actively kills duplicates |
| `vicidial-process-monitor.service` | `/etc/systemd/system/` | Keeps monitor daemon always running |
| `vicidial-keepalive.service` | `/etc/systemd/system/` | One-shot unit that runs keepalive |
| `vicidial-keepalive.timer` | `/etc/systemd/system/` | Fires the keepalive service every 60s |

### Log Files

| Log | Contents |
|---|---|
| `/var/log/vicidial_step23_process_mgmt.log` | Step 23 standalone install log |
| `/var/log/astguiclient/process_monitor.log` | Monitor daemon activity |
| `/var/log/astguiclient/ADMIN_keepalive_ALL_wrapper.log` | Keepalive runs via wrapper |
| `/var/log/astguiclient/{script}_wrapper.log` | Per-script wrapper logs |

---

## ✅ Verification Commands

Run these after installation to confirm everything is working:

```bash
# 1. Check systemd timer is active and when it fires next
systemctl status vicidial-keepalive.timer
systemctl list-timers vicidial-keepalive.timer

# 2. Check process monitor is running
systemctl status vicidial-process-monitor
journalctl -u vicidial-process-monitor -f

# 3. Confirm NO duplicate keepalive processes
ps aux | grep ADMIN_keepalive | grep -v grep
# Expected: 0 lines (if not currently running) or 1 line (if mid-run)
# NOT OK: 5-10 lines

# 4. Confirm crontab has NO raw keepalive
crontab -l | grep keepalive
# Expected: no output (or only wrapped versions)

# 5. Confirm crontab scripts are wrapped
crontab -l | grep "vicidial_cron_wrapper"
# Expected: several lines showing wrapped scripts

# 6. Watch the monitor log live
tail -f /var/log/astguiclient/process_monitor.log

# 7. Confirm flock wrapper is installed and executable
ls -la /usr/local/bin/vicidial_cron_wrapper.sh
```

---

## 🩺 Troubleshooting

### Timer not activating
```bash
systemctl daemon-reload
systemctl enable vicidial-keepalive.timer
systemctl start vicidial-keepalive.timer
journalctl -u vicidial-keepalive.timer -n 30
```

### Monitor daemon keeps crashing
```bash
journalctl -u vicidial-process-monitor -n 50
# Check for permission issues or missing directories
ls -la /var/log/astguiclient/
ls -la /var/run/
```

### Script still running as duplicate after install
```bash
# The monitor cleans up within 60 seconds. If you want immediate cleanup:
pkill -f "ADMIN_keepalive_ALL.pl" || true
# Then let the timer restart it cleanly on next 60s tick
systemctl list-timers vicidial-keepalive.timer
```

### Want to manually trigger the keepalive once
```bash
systemctl start vicidial-keepalive.service
journalctl -u vicidial-keepalive.service -f
```

### Roll back to raw cron (NOT recommended)
```bash
# Stop the timer
systemctl stop vicidial-keepalive.timer
systemctl disable vicidial-keepalive.timer

# Add back to crontab
(crontab -l; echo "* * * * * /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --cu3way") | crontab -
```

---

## 📋 Crontab: Before vs After

### Before (raw cron — the broken way):
```cron
* * * * * /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --cu3way    ← REMOVED
* * * * * /usr/share/astguiclient/AST_VDhopper.pl --debug             ← UNWRAPPED
* * * * * /usr/share/astguiclient/AST_VDauto_dial.pl --debug          ← UNWRAPPED
```

### After (fixed):
```cron
# ADMIN_keepalive_ALL.pl is now managed by: vicidial-keepalive.timer
# (no cron entry - controlled by systemd)

* * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_VDhopper.pl --debug
* * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_VDauto_dial.pl --debug
```

---

## 🏗️ Making It Maintainable

The modular design means future updates are easy:

- **Update the monitor's watched scripts** → edit `vicidial_process_monitor.sh`, `systemctl restart vicidial-process-monitor`
- **Change keepalive interval** → edit `vicidial-keepalive.timer` `OnUnitActiveSec=`, run `systemctl daemon-reload && systemctl restart vicidial-keepalive.timer`
- **Add a new script to flock wrapping** → just prefix it with `vicidial_cron_wrapper.sh` in crontab
- **Check health** → `systemctl status vicidial-*` shows all at once

---

*For questions or issues, check logs first: `/var/log/astguiclient/process_monitor.log`*
