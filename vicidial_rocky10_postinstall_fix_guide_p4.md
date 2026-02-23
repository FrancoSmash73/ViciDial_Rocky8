# ViciDial Post-Install FIX GUIDE — Part 4
**Server:** Rocky Linux 10.x (Cluster or Standalone)
**Asterisk:** 18.21.0-vici
**Date:** 2026-02-23

---

## The Problem: Only 3 Screen Sessions After Re-Running Install Scripts

### Symptom
Running `screen -ls` shows only 3 sessions when there should be 13:
```
There are screens on:
    5716.astershell20260222234643   (Detached)
    5718.astshell20260222234643     (Attached)
    5723.asterisk                   (Attached)
3 Sockets in /run/screen/S-root.
```

The correct production state is **13 sessions**:
```
There are screens on:
    XXXX.astershell     (Detached)
    XXXX.astshell       (Attached)
    XXXX.asterisk       (Attached)
    XXXX.ASTupdate      (Detached)
    XXXX.ASTsend        (Detached)
    XXXX.ASTlisten      (Detached)
    XXXX.ASTConfUpdater (Detached)
    XXXX.ASTVDremote    (Detached)
    XXXX.ASTVDadapt     (Detached)
    XXXX.ASTfastlog     (Detached)
    XXXX.ASTemail       (Detached)
    + ASTVDauto         (only when campaigns/agents are active)
```

---

## Root Cause

Re-running `vicidial_rocky10_part3_process_mgmt.sh` (Step 23) or parts of
`vicidial_rocky10_part2_install.sh` **silently reverted** four previously-applied
post-install fixes:

| Reverted Fix | What Broke | Effect |
|---|---|---|
| FIX 7 — `ps -o "pid,args"` | `AST_manager_send.pl` & `AST_VDremote_agents.pl` reset to `%p %a` | `ASTsend` and `ASTVDremote` exit immediately — can't find the AMI listener |
| FIX 10 — pgrep pattern | Process monitor reset to `pgrep -f "$script"` | Monitor matches SCREEN wrapper + perl daemon = 2 hits → kills the perl daemon |
| FIX 11 — MAX_RUNTIME table | Process monitor reset with `AST_VDauto_dial.pl=180` etc. | Persistent daemons killed every 3 minutes |
| FIX 12 — `asterisk.service` masked | Part 2 re-enabled the service | Dual Asterisk instance fighting over UDP 5060 |

### Why Re-Running the Scripts Caused This

**Part 2, Step 4** (`make install` section) had:
```bash
if [ ! -f /etc/systemd/system/asterisk.service ]; then
    # ... write unit file ...
    systemctl enable asterisk   # ← RE-ENABLED the service we had masked
fi
```
A masked service is a **symlink** to `/dev/null`. The `-f` test returns `false` for a
symlink, so the condition was always `true` → the unit file was recreated as a real
file and enabled on every re-run.

**Part 3** deployed a fresh `vicidial_process_monitor.sh` from its heredoc on every run,
overwriting the manually-patched version with the original buggy content.

---

## The Fix (5-Minute Recovery)

Run these commands in order. Safe to run on a live system.

### Step 1 — Stop the process monitor
```bash
systemctl stop vicidial-process-monitor
```

### Step 2 — Apply the ps format fix (FIX 7)
```bash
python3 -c "
old = '/bin/ps -o \"%p %a\" --no-headers -A'
new = '/bin/ps -o \"pid,args\" --no-headers -A'
for f in ['/usr/share/astguiclient/AST_manager_send.pl',
          '/usr/share/astguiclient/AST_VDremote_agents.pl']:
    with open(f, 'r') as fh: c = fh.read()
    n = c.count(old)
    with open(f, 'w') as fh: fh.write(c.replace(old, new))
    print(f'{f}: replaced {n} occurrence(s)')
"
```

Expected output:
```
/usr/share/astguiclient/AST_manager_send.pl: replaced 1 occurrence(s)
/usr/share/astguiclient/AST_VDremote_agents.pl: replaced 1 occurrence(s)
```

> **Why Python and not sed?** The pattern contains both double-quotes and backticks.
> `sed -i` shell-expands the pattern and silently wipes the file to 0 bytes.
> Always use Python for this specific replacement (documented in FIX 7 Addendum,
> Part 2 fix guide).

### Step 3 — Fix the process monitor (FIX 10 + FIX 11)

Edit `/usr/local/bin/vicidial_process_monitor.sh`:

**MAX_RUNTIME** — remove all persistent daemons and phantom scripts. The correct
table contains **only one-shot/cron scripts**:
```bash
declare -A MAX_RUNTIME=(
    ["ADMIN_keepalive_ALL.pl"]=240
    ["AST_VDhopper.pl"]=180
    ["AST_VDauto_dial_FILL.pl"]=600
    ["AST_flush_DBqueue.pl"]=120
    ["AST_CRON_audio_1_move_mix.pl"]=120
    ["AST_CRON_audio_2_compress.pl"]=180
)
```

**pgrep pattern** — both loops must use `perl.*` prefix so the SCREEN wrapper is
not counted as a second instance:
```bash
# In the duplicate-detection loop (WATCHED_SCRIPTS):
PIDS=$( { pgrep -f "perl.*${script}" 2>/dev/null || true; } )

# In the max-runtime loop (MAX_RUNTIME):
PIDS=$( { pgrep -f "perl.*${script}" 2>/dev/null || true; } )
```

### Step 4 — Fix /run/screen permissions
```bash
# screen 5.0.1 on Rocky Linux 10 requires 1777, not 0775
chmod 1777 /run/screen

# Persist across reboots (tmpfiles.d would reset to 0775 otherwise)
cat > /etc/tmpfiles.d/screen-fix.conf << 'EOF'
# screen 5.0.1 on Rocky Linux 10 requires 1777 (not 0775 set by package default)
d /run/screen 1777 root root
EOF
```

### Step 5 — Mask asterisk.service (FIX 12)
```bash
systemctl stop asterisk 2>/dev/null || true
\rm -f /etc/systemd/system/asterisk.service
ln -sf /dev/null /etc/systemd/system/asterisk.service
systemctl daemon-reload
```

Verify:
```bash
systemctl status asterisk.service | head -3
# Expected: Loaded: masked (Reason: Unit asterisk.service is masked.)
```

### Step 6 — Launch all daemon sessions
```bash
screen -wipe 2>/dev/null || true
/usr/share/astguiclient/ADMIN_keepalive_ALL.pl
```

### Step 7 — Start process monitor and verify
```bash
systemctl start vicidial-process-monitor
sleep 5
screen -ls
```

Expected: **13 sockets** (11 on idle system — `ASTVDauto` only appears when
campaigns/agents are active, which is normal).

Wait 65 seconds for one full monitor scan cycle, then confirm it's not killing anything:
```bash
tail -5 /var/log/astguiclient/process_monitor.log
# Should end with: INFO: All processes healthy (0 actions taken)
```

---

## Verification Checklist

```bash
# 1. ps fix in place (should return 1 each)
grep -c 'pid,args' /usr/share/astguiclient/ADMIN_keepalive_ALL.pl
grep -c 'pid,args' /usr/share/astguiclient/AST_manager_send.pl
grep -c 'pid,args' /usr/share/astguiclient/AST_VDremote_agents.pl

# 2. Process monitor has no persistent daemons in MAX_RUNTIME (should return 0)
grep -c 'VDauto_dial\]\|VDadapt\]\|VDremote_agents\]' \
     /usr/local/bin/vicidial_process_monitor.sh

# 3. pgrep uses perl.* prefix (should return 2)
grep -c 'pgrep -f "perl\.\*' /usr/local/bin/vicidial_process_monitor.sh

# 4. asterisk.service is masked
ls -la /etc/systemd/system/asterisk.service
# Expected: ... -> /dev/null

# 5. /run/screen permissions
stat -c "%a" /run/screen
# Expected: 1777

# 6. systemd services active
systemctl is-active vicidial-keepalive.timer
systemctl is-active vicidial-process-monitor
# Both should return: active
```

---

## What Causes This (How to Avoid Re-Breaking It)

| Action | Risk | Mitigation |
|---|---|---|
| Re-running `vicidial_rocky10_part3_process_mgmt.sh` | Redeploys process monitor from script heredoc | Script now has correct heredoc — safe to re-run as of commit `cea3d5d` |
| Re-running `vicidial_rocky10_part2_install.sh` Step 4 | Previously re-created and enabled `asterisk.service` | Fixed in commit `cea3d5d` — now masks instead of enables |
| Using `sed -i` to edit ViciDial Perl files | Can silently wipe files to 0 bytes if pattern contains `"` and backticks | Always use Python `str.replace()` for these patterns |
| System reboot before tmpfiles.d override | `/run/screen` reset to 0775 by package default — screen 5.x refuses to create sessions | Fixed: `screen-fix.conf` override written by both Part 2 and Part 3 |

---

## Permanent Fix (Already Applied to Scripts)

As of commit `cea3d5d` on `github.com/FrancoSmash73/vicidial-rocky10`, both
install scripts are permanently hardened:

### `vicidial_rocky10_part2_install.sh`
- **Step 4:** Replaced `create + systemctl enable asterisk` with mask to `/dev/null`
- **Step 18:** Added mask after `systemctl disable asterisk`
- **Screen section:** Writes `/etc/tmpfiles.d/screen-fix.conf` (1777 on boot)

### `vicidial_rocky10_part3_process_mgmt.sh`
- **STEP G1 (new):** Masks `asterisk.service` before final verification
- **STEP G0:** Writes `screen-fix.conf` tmpfiles.d override
- **Monitor heredoc:** Already has correct `perl.*${script}` pgrep and pruned MAX_RUNTIME

Re-running either script after this commit is fully idempotent — no previously-applied
fix will be reverted.

---

## Key Files Reference

| File | Purpose | Notes |
|---|---|---|
| `/usr/share/astguiclient/ADMIN_keepalive_ALL.pl` | Launches and monitors all daemon screen sessions | Must have `ps -o "pid,args"` (3 locations) |
| `/usr/share/astguiclient/AST_manager_send.pl` | AMI command sender daemon | Must have `ps -o "pid,args"` (1 location, line ~316) |
| `/usr/share/astguiclient/AST_VDremote_agents.pl` | Remote agent handler daemon | Must have `ps -o "pid,args"` (1 location, line ~620) |
| `/usr/local/bin/vicidial_process_monitor.sh` | Kills duplicate/runaway cron scripts | MAX_RUNTIME = cron scripts only; pgrep = `perl.*` prefix |
| `/etc/systemd/system/asterisk.service` | Must be a symlink to `/dev/null` | Never a real unit file on ViciDial servers |
| `/etc/tmpfiles.d/screen-fix.conf` | Ensures `/run/screen` stays 1777 on boot | Required for screen 5.0.1 on Rocky Linux 10 |

---

## Background: ViciDial Daemon Architecture (Quick Reference)

### Category A — Persistent Screen Daemons (managed by `ADMIN_keepalive_ALL.pl`)
Never in cron. Never in MAX_RUNTIME. Run indefinitely.

| Screen Name | Script |
|---|---|
| `ASTupdate` | `AST_update_AMI2.pl` |
| `ASTlisten` | `AST_manager_listen_AMI2.pl` |
| `ASTsend` | `AST_manager_send.pl` |
| `ASTVDadapt` | `AST_VDadapt.pl` |
| `ASTVDauto` | `AST_VDauto_dial.pl` *(exits on idle — normal)* |
| `ASTVDremote` | `AST_VDremote_agents.pl` |
| `ASTfastlog` | `FastAGI_log.pl` |
| `ASTSIPlogger` | `AST_manager_sip_AMI2.pl` |
| `ASTConfUpdater` | `AST_conf_update_CONFBRIDGE.pl` |
| `ASTemail` | `VD_email_inbound.pl` |
| `ASTconf3way` | `AST_conf_update_3way.pl` |

### Category B — One-Shot Cron Scripts (flock-wrapped, MAX_RUNTIME enforced)
Run briefly, complete, and exit. Belong in cron only.

| Script | Schedule |
|---|---|
| `AST_VDhopper.pl` | Every minute |
| `AST_manager_kill_hung_congested.pl` | Every minute |
| `AST_vm_update.pl` | Every minute |
| `AST_conf_update.pl` | Every minute |
| `AST_inbound_email_parser.pl` | Every minute |
| `AST_VDauto_dial_FILL.pl` | Every 5 minutes |
| `AST_flush_DBqueue.pl` | Every 5 minutes |
| `AST_CRON_audio_1_move_mix.pl` | Every 3 minutes |
| `AST_CRON_audio_2_compress.pl` | Every 3 minutes |

---

*Part 4 completed 2026-02-23. Fixes baked into install scripts as of commit `cea3d5d`.*
