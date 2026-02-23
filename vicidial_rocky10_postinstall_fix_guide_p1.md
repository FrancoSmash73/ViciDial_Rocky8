# ViciDial Post-Install FIX GUIDE
**Server:** 172.236.243.149
**OS:** Rocky Linux 10.x
**Asterisk:** 18.21.0-vici
**Date:** 2026-02-17

---

## Overview

This guide documents every issue found and fixed during the post-install production-readiness review of a ViciDial scratch installation built from:
- `vicidial_part1_GOLDEN_Vici_Rocky10.sh`
- `ViciDial_ULTIMATE_Part2_FINAL.sh`
- `STEP_23_Process_Management.sh`

---

## FIX 1 — STEP_23 Script Crash (Bash `set -e` + Arithmetic Bugs)

### Symptom
Running `STEP_23_Process_Management.sh` crashed mid-execution:
```
[OK] ✅ Crontab: no raw keepalive entry (managed by timer)
./STEP_23_Process_Management.sh: line 627: [: 0\n0: integer expression expected
[WARNING] ⚠️  0\n0 keepalive instances found (monitor will kill duplicates within 60s)
║  ERROR on line 631
║  Command: ((WARNINGS++))
```

### Root Cause — Two separate bugs

**Bug 1 — `pgrep | wc -l` under `set -euo pipefail`**

When `pgrep` finds no matching processes it exits with code `1`. With `pipefail` active, that exit code propagates through the pipe. `wc -l` has already written `0` to stdout, then the `|| echo "0"` fallback also fires — so the command substitution captures both outputs: `"0\n0"`. The subsequent `[ "$KA_COUNT" -le 1 ]` test fails because `"0\n0"` is not a valid integer.

```bash
# BROKEN — pipefail causes pgrep exit-1 to trigger || echo "0"
# resulting in KA_COUNT="0\n0"
KA_COUNT=$(pgrep -f "ADMIN_keepalive_ALL.pl" | wc -l || echo "0")
```

**Bug 2 — `((VAR++))` returns falsy when VAR=0 under `set -e`**

In bash arithmetic context, `((expr))` returns exit code `1` when the expression evaluates to `0` (which is falsy). With `set -e` active, this triggers the ERR trap and kills the script — even though incrementing from 0 to 1 is perfectly valid logic.

```bash
# BROKEN — ((WARNINGS++)) when WARNINGS=0 evaluates to 0 (falsy)
# set -e treats that as an error and fires the ERR trap
((WARNINGS++))
```

### Fix — File: `/root/STEP_23_Process_Management.sh`

**Bug 1 fix** — wrap pgrep with `|| true` inside a subshell so pipefail never sees exit code 1:
```bash
# FIXED
KA_COUNT=$( { pgrep -f "ADMIN_keepalive_ALL.pl" 2>/dev/null || true; } | wc -l )
KA_COUNT="${KA_COUNT//[[:space:]]/}"
```

**Bug 2 fix** — replace all `((VAR++))` with safe arithmetic assignment (applied to 6 locations in the verification block):
```bash
# FIXED — safe under set -e regardless of current value
ERRORS=$((ERRORS + 1))
WARNINGS=$((WARNINGS + 1))
```

### Verification
Re-running the script produces: `✅ STEP 23 COMPLETE - ZERO ISSUES`

---

## FIX 2 — Asterisk Not Running After Reboot (`/run/screen` Wrong Permissions)

### Symptom
After reboot, Asterisk was not running. `screen -ls` returned:
```
Directory '/run/screen' must have mode 775.
```
`/var/run/asterisk/` was empty (no socket, no PID file).

### Root Cause
The install script's Step 18 ran:
```bash
chmod 777 /run/screen && chmod +t /run/screen
```
This set `/run/screen` to mode `1777`. GNU screen requires **exactly** `0775` — with any other mode it silently refuses to create socket files. `start_asterisk_boot.pl` ran at boot, called `screen` commands that returned exit code 0 (no visible error), but no screen sessions or Asterisk process were actually created.

### Why It's Persistent After Fix
`systemd-tmpfiles.d` manages `/run/screen` via:
```
/usr/lib/tmpfiles.d/screen.conf  →  d /run/screen 0775 root screen
```
On every subsequent reboot, `tmpfiles.d` recreates `/run/screen` at `0775` automatically. The Step 18 code that caused this is marked `COMPLETE` in `.vicidial_part2_progress` and will never re-run.

### Fix
```bash
chmod 0775 /run/screen
```

Then restart Asterisk:
```bash
killall -9 asterisk 2>/dev/null || true
screen -wipe 2>/dev/null || true
rm -f /var/run/asterisk/asterisk.ctl /var/run/asterisk/asterisk.pid
/usr/share/astguiclient/start_asterisk_boot.pl
```

### Verification
```
There are screens on:
    51576.astershell...  (Detached)
    51578.astshell...    (Attached)
    51615.asterisk       (Attached)
3 Sockets in /run/screen/S-root.

srwxr-xr-x 1 root root 0 asterisk.ctl
Asterisk 18.21.0-vici built by root @ localhost on a x86_64
```

---

## FIX 3 — SIP Carrier `[tbi-out]` Missing Closing Bracket

### Symptom
Asterisk logged `chan_sip` parse warnings at startup. `sip-vicidial.conf` contained:
```ini
; VICIDIAL Carrier: TBI-OUT - tbi-out
[tbi-out          ← missing ]
type=friend
```

### Root Cause
The ViciDial database `vicidial_server_carriers` table had a malformed `account_entry` field for carrier `TBI-OUT` — the section header was stored as `[tbi-out` without the closing bracket. Since ViciDial writes this field **verbatim** into `sip-vicidial.conf` on every keepalive cycle, any manual edit to the file was overwritten within 60 seconds.

### Fix — Database Level
```sql
UPDATE vicidial_server_carriers
SET account_entry = REPLACE(account_entry, '[tbi-out\n', '[tbi-out]\n')
WHERE carrier_id = 'TBI-OUT';
```

Then trigger a forced config regeneration:
```sql
UPDATE servers SET rebuild_conf_files='Y' WHERE server_ip='172.236.243.149';
```

Then run the keepalive to pick up the change:
```bash
/usr/share/astguiclient/ADMIN_keepalive_ALL.pl --debug
```

ViciDial regenerates `sip-vicidial.conf`, detects the difference, copies the fixed file, and issues `sip reload` to Asterisk — all automatically.

### Verification
```bash
head -6 /etc/asterisk/sip-vicidial.conf
# ; VICIDIAL Carrier: TBI-OUT - tbi-out
# [tbi-out]        ← bracket present
# type=friend
```

---

## FIX 4 — Firewall RTP Port Range Mismatch

### Symptom
Agents on arbitrary IPs would experience one-way or no audio on calls.

### Root Cause
`/etc/asterisk/rtp.conf` defines:
```ini
rtpstart=9000
rtpend=35000
```
But the firewall only opened `10000-20000/udp` publicly. Asterisk could assign RTP ports anywhere in `9000–35000`, but ports `9000–9999` and `20001–35000` were firewalled for all IPs except the SIP carrier (`88.151.128.22`), which already had `9000-35000/udp` via a specific rule.

### Fix
```bash
firewall-cmd --permanent --remove-port=10000-20000/udp
firewall-cmd --permanent --add-port=9000-35000/udp
firewall-cmd --reload
```

### Verification
```bash
firewall-cmd --list-ports
# 5060/udp  9000-35000/udp
```

---

## FIX 5 — pjsip Sub-Modules Generating Startup Errors

### Symptom
Every Asterisk startup logged 40+ ERROR lines:
```
ERROR loader.c: Error loading module 'res_pjsip_nat.so', missing dependencies: res_pjsip, res_pjsip_session
ERROR loader.c: Error loading module 'func_pjsip_endpoint.so', missing dependency: res_pjsip
ERROR loader.c: Error loading module 'res_prometheus.so', missing dependency: res_pjsip
ERROR loader.c: Failed to open /dev/dahdi/transcode: No such file or directory
...
```

### Root Cause
`modules.conf` had `noload` directives for the core pjsip modules (`res_pjsip.so`, `res_pjsip_session.so`, `chan_pjsip.so`) but **not** for the 40+ dependent sub-modules (`res_pjsip_nat.so`, `res_pjsip_stir_shaken.so`, etc.), `func_pjsip_*` functions, `res_prometheus.so` (which depends on pjsip), and `codec_dahdi.so` (hardware transcoder, absent on VoIP-only installs).

### Fix — File: `/etc/asterisk/modules.conf`
Added complete noload block for all pjsip-dependent modules:

```ini
;Add these lines to prevent PJSIP from loading (chan_sip is used instead):
noload => res_pjsip.so
noload => res_pjsip_session.so
noload => chan_pjsip.so
noload => res_pjsip_pubsub.so
noload => res_pjsip_exten_state.so
noload => res_pjsip_log_forwarder.so
noload => res_pjsip_acl.so
noload => res_pjsip_aoc.so
noload => res_pjsip_authenticator_digest.so
noload => res_pjsip_caller_id.so
noload => res_pjsip_config_wizard.so
noload => res_pjsip_dialog_info_body_generator.so
noload => res_pjsip_diversion.so
noload => res_pjsip_dlg_options.so
noload => res_pjsip_dtmf_info.so
noload => res_pjsip_empty_info.so
noload => res_pjsip_endpoint_identifier_anonymous.so
noload => res_pjsip_endpoint_identifier_ip.so
noload => res_pjsip_endpoint_identifier_user.so
noload => res_pjsip_geolocation.so
noload => res_pjsip_header_funcs.so
noload => res_pjsip_history.so
noload => res_pjsip_logger.so
noload => res_pjsip_messaging.so
noload => res_pjsip_mwi.so
noload => res_pjsip_mwi_body_generator.so
noload => res_pjsip_nat.so
noload => res_pjsip_notify.so
noload => res_pjsip_one_touch_record_info.so
noload => res_pjsip_outbound_authenticator_digest.so
noload => res_pjsip_outbound_publish.so
noload => res_pjsip_outbound_registration.so
noload => res_pjsip_path.so
noload => res_pjsip_phoneprov_provider.so
noload => res_pjsip_pidf_body_generator.so
noload => res_pjsip_pidf_digium_body_supplement.so
noload => res_pjsip_pidf_eyebeam_body_supplement.so
noload => res_pjsip_publish_asterisk.so
noload => res_pjsip_refer.so
noload => res_pjsip_registrar.so
noload => res_pjsip_rfc3326.so
noload => res_pjsip_rfc3329.so
noload => res_pjsip_sdp_rtp.so
noload => res_pjsip_send_to_voicemail.so
noload => res_pjsip_sips_contact.so
noload => res_pjsip_stir_shaken.so
noload => res_pjsip_t38.so
noload => res_pjsip_transport_websocket.so
noload => res_pjsip_xpidf_body_generator.so
noload => func_pjsip_aor.so
noload => func_pjsip_contact.so
noload => func_pjsip_endpoint.so
noload => res_prometheus.so
noload => codec_dahdi.so
```

### Verification
After restart, zero `res_pjsip_*`, `func_pjsip_*`, `res_prometheus`, or `codec_dahdi` errors in `/var/log/asterisk/messages`.

---

## FIX 6 — Unused Protocol Modules Opening Unnecessary UDP Ports

### Symptom
Three unexpected UDP ports open on a standalone ViciDial SIP+WebRTC install:

```
UNCONN  0.0.0.0:2727   asterisk   ← MGCP (Media Gateway Control Protocol)
UNCONN  0.0.0.0:4520   asterisk   ← DUNDi (Distributed Universal Number Discovery)
UNCONN  0.0.0.0:5000   asterisk   ← UNISTIM (Nortel/Avaya desk phones)
```

### Root Cause
`autoload=yes` in `modules.conf` causes Asterisk to load every module it finds, including legacy protocol drivers that serve no purpose on a SIP+chan_sip standalone system:

| Module | Protocol | Default Port | Used by ViciDial? |
|--------|----------|-------------|-------------------|
| `chan_mgcp.so` | MGCP | 2727/UDP | No — analog gateway protocol |
| `chan_unistim.so` | UNISTIM | 5000/UDP | No — Nortel/Aastra IP phones only |
| `pbx_dundi.so` | DUNDi | 4520/UDP | No — multi-server dial plan lookup only |

### Fix — File: `/etc/asterisk/modules.conf`
Add to the existing `noload` block alongside `chan_iax2.so` and `chan_skinny.so`:

```
noload => chan_mgcp.so
noload => chan_unistim.so
noload => pbx_dundi.so
```

To unload live without restarting Asterisk:
```bash
asterisk -rx "module unload chan_mgcp.so"
asterisk -rx "module unload chan_unistim.so"
asterisk -rx "module unload pbx_dundi.so"
```
> **Note:** The DUNDi module name in the running instance is `pbx_dundi.so` (not `res_dundi.so`).

### Verification
```bash
ss -ulnp | grep asterisk
# Expected: only 0.0.0.0:5060 (SIP)
```

---

## Post-Fix System State

| Component | Status |
|-----------|--------|
| Asterisk 18.21.0-vici | Running (PID rotates on each restart) |
| `app_confbridge.so` | Running |
| `/run/screen` permissions | `0775 root:screen` (enforced by tmpfiles.d on boot) |
| Screen sessions (idle) | 3 sockets: `astershell`, `astshell`, `asterisk` |
| Screen sessions (production) | 10–11 sockets (additional ViciDial daemons) |
| `conf_engine` in DB | `CONFBRIDGE` |
| `vicidial_confbridges` count | 300 entries for `172.236.243.149` |
| `VARactive_keepalives` | `1234568CES` (includes `C` = ConfBridge flag) |
| ADMIN_keepalive_ALL.pl | Running every 60s via systemd timer, exit 0 |
| Process monitor | `vicidial-process-monitor` active |
| Cron workers | flock-wrapped `VDauto_dial`, `send_listen`, `VDadapt` |
| Firewall SIP | `5060/udp` open |
| Asterisk UDP (unused protocols) | Ports 2727/4520/5000 closed — `chan_mgcp`, `chan_unistim`, `pbx_dundi` noloaded |
| Firewall RTP | `9000-35000/udp` open (matches `rtp.conf`) |
| MariaDB | Active, 400 max connections, 3GB InnoDB pool |
| Apache/PHP 8.3 | Active, `/agc/vicidial.php` → HTTP 200 |
| `sip-vicidial.conf` | `[tbi-out]` correct (fixed at DB source) |
| Asterisk startup ERRORs | Only expected backend-not-installed declines (PostgreSQL, LDAP, TDS) |

---

## Expected Remaining Log Noise (Non-Actionable)

These entries appear at every Asterisk startup and are **harmless** — they reflect optional backends not installed on a standard ViciDial/MariaDB system:

| Error | Reason | Action |
|-------|--------|--------|
| `res_config_pgsql: Failed to connect` | PostgreSQL not installed | None needed |
| `res_config_ldap: No directory URL` | LDAP not configured | None needed |
| `ari/config.c: No configured users for ARI` | ARI not used by ViciDial | None needed |
| `cdr_pgsql declined to load` | PostgreSQL CDR backend absent | None needed |
| `cel_sqlite3_custom declined to load` | SQLite CEL backend absent | None needed |
| `cdr_tds / cel_tds declined to load` | TDS/MSSQL backend absent | None needed |
| `chan_sip deprecation WARNING` | chan_sip is deprecated upstream but required by ViciDial | None needed (ViciDial-vici patch) |

---

## Key Files Modified

| File | Change |
|------|--------|
| `/root/STEP_23_Process_Management.sh` | Fixed `pgrep\|wc -l` pipefail bug + `((VAR++))` arithmetic bug |
| `/etc/asterisk/modules.conf` | Added 50+ `noload` entries for pjsip sub-modules, func_pjsip, prometheus, codec_dahdi; added `noload` for unused protocol drivers: `chan_mgcp`, `chan_unistim`, `pbx_dundi` |
| `/etc/asterisk/sip-vicidial.conf` | Auto-regenerated correctly after DB fix (do not edit manually) |

## Key Database Changes

| Table | Field | Change |
|-------|-------|--------|
| `vicidial_server_carriers` | `account_entry` WHERE `carrier_id='TBI-OUT'` | `[tbi-out` → `[tbi-out]` |

## Key System Changes

| Setting | Before | After |
|---------|--------|-------|
| `/run/screen` permissions | `0777` (set by install Step 18) | `0775` (correct; auto-enforced by tmpfiles.d on reboot) |
| Firewall public UDP | `10000-20000/udp` | `9000-35000/udp` (matches `rtp.conf`) |
