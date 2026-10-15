# ViciDial Rocky Linux 10 Install Scripts

**Asterisk:** 18.21.0-vici | **ViciDial:** SVN trunk | **OS:** Rocky Linux 10.x / AlmaLinux 10.x
**PHP:** 8.3 | **MariaDB:** 10.11 | **Perl:** 5.40

---


## PJSIP-only posture (✅ validated)

This repo is moving toward PJSIP-only: chan_sip is deprecated in Asterisk 18/20
and **removed in Asterisk 21**, it is the largest attack surface on a ViciDial
box (udp/5060), and ViciDial's webphone path is PJSIP/WebRTC anyway.

Two helpers:

| Script | Purpose |
|---|---|
| `vicidial_pjsip_phone_sync.sh` | Generate PJSIP endpoint/auth/aor blocks from the `phones` table. ViciDial never generates these itself. Uses `phones.conf_secret` (Registration Password) — never `phones.pass`. |
| `vicidial_chan_sip_remove.sh` | Audit whether chan_sip still has a dependency; remove it only if clean. Regenerates the dialplan first so `Dial(SIP/x)` becomes `Dial(PJSIP/x)`. |

Both default to a read-only `--check`. See
[docs/PJSIP-WEBPHONE-TROUBLESHOOTING.md](docs/PJSIP-WEBPHONE-TROUBLESHOOTING.md).

> ✅ **Validated end-to-end on the reference box (CVS).** Endpoints load,
> passwords match `conf_secret`, WSS is bound on 8089 with a valid cert, the
> dialplan resolves to `PJSIP/` — and a browser webphone has now completed a
> WebRTC registration and placed test calls successfully. PJSIP-only is
> confirmed working, not just plumbed. Roll back by re-activating chan_sip and
> setting `phones.protocol='SIP'`, then `servers.rebuild_conf_files='Y'` to
> regenerate the dialplan.


## Scripts

| Script | Purpose |
|--------|---------|
| `vicidial_rocky10_part1_install.sh` | Base OS packages, Asterisk build, ViciDial SVN checkout, Perl modules |
| `vicidial_rocky10_part2_install.sh` | ViciDial database setup, Asterisk config, ConfBridge, process management |
| `vicidial_rocky10_part3_process_mgmt.sh` | **Standalone addon** — process management only, safe to run on any existing ViciDial install |
| `vicidial_rocky10_part4_webrtc.sh` | **Standalone addon** — WebRTC/WSS (Asterisk http.conf + pjsip transport-wss), Let's Encrypt SSL, HulkPhone softphone deploy. Run after Parts 1–3. |

## Documentation

| File | Contents |
|------|----------|
| `vicidial_rocky10_integration_guide.md` | Architecture overview, scenarios, troubleshooting |
| `vicidial_rocky10_postinstall_fix_guide_p1.md` | Post-install fixes: `/run/screen` permissions, SIP bracket, firewall RTP, pjsip modules |
| `vicidial_rocky10_postinstall_fix_guide_p2.md` | Rocky Linux 10 compatibility fixes: `Switch.pm`, `ps` truncation, daemon architecture, process monitor bugs |
| `vicidial_rocky10_postinstall_fix_guide_p3.md` | Production runtime fixes: dual Asterisk instance, CDR permissions, remote agent WSS, VICIPHONE_SETTINGS conflict, dynamiclist audit |

---

## Quick Start

```bash
# Part 1 — Base install (Asterisk + ViciDial source)
chmod +x vicidial_rocky10_part1_install.sh
./vicidial_rocky10_part1_install.sh

# Part 2 — Configuration + process management
chmod +x vicidial_rocky10_part2_install.sh
./vicidial_rocky10_part2_install.sh

# Part 3 — Standalone process management addon (run on any existing install)
chmod +x vicidial_rocky10_part3_process_mgmt.sh
./vicidial_rocky10_part3_process_mgmt.sh

# Part 4 — WebRTC/WSS, Let's Encrypt SSL, HulkPhone softphone (optional, run after Parts 1-3)
chmod +x vicidial_rocky10_part4_webrtc.sh
./vicidial_rocky10_part4_webrtc.sh --domain yourdomain.example.com
# add --skip-audit to skip the automatic post-install audit at the end
```

All scripts are **idempotent** — safe to re-run. Parts 1 and 2 track progress in
`/root/.vicidial_part1_progress` and `/root/.vicidial_part2_progress` and will
prompt skip/re-run/quit for each completed step. Parts 3 and 4 achieve idempotency
by checking real on-disk/system state before each step (e.g. "is this file already
deployed?") rather than a separate progress file — also safe to re-run.

### Version configuration

`configs/versions.conf` holds the versions Part 1 and Part 2 actually target
(PHP via the Remi module stream, and the Asterisk-vici / fallback plain-Asterisk
tarball versions). Edit it before running the installer to change these. Not
every version string in this project is independently pinnable this way — see
the notes inside `versions.conf` (MariaDB, for instance, comes from Rocky 10's
native default module stream and isn't selected by these scripts today).

### Post-install audit

`vicidial_rocky10_audit.sh` runs automatically at the end of Part 4 (unless
`--skip-audit` is passed) and checks screen sessions, DB schema, the keepalive
timer, crontab, Perl modules, core services, and WebRTC/PJSIP config. **On a
multi-server cluster, read its output in context of that node's role** — it
checks for mariadb/httpd/asterisk/process-monitor together, so a FAIL for a
service that doesn't belong on this particular node (e.g. `mariadb` on an
Asterisk-only box) is expected, not a real problem. You can also run it by
hand any time: `bash vicidial_rocky10_audit.sh`.

### HulkPhone deployment

Part 4 deploys the [HulkPhone](https://github.com/FrancoSmash73/Hulk-) WebRTC
softphone as a **live git clone** at `/var/www/html/hulkphone` — not a
one-time copy. Re-running Part 4 later (or `git -C /var/www/html/hulkphone
pull` by hand) picks up upstream fixes without a full reinstall. The clone
brings its own `deploy/` hardening along with it, applied automatically:
`.git` denied from the web, directory listing off, a fail2ban loopback
exemption (so the health check below can't ban your own server), and
`deploy/verify.sh` run once against loopback as a non-fatal post-deploy
check. `config.local.php` (SIP/TURN settings) is seeded from `--domain` on
first run and never touched again on re-runs, so manual edits survive.
Falls back to a bare-bones inline PHP shell (no working dialer — see the
in-script note) only if the clone can't reach GitHub at all; re-running
once network access is restored deploys the real thing automatically.

---

## Rocky Linux 10 Compatibility Notes

These issues are unique to Rocky Linux 10 and are automatically fixed by the scripts:

| Issue | Root Cause |
|-------|-----------|
| `Can't locate Switch.pm` | Perl 5.40 removed `Switch` from default distribution |
| Keepalive never detects running daemons | `procps-ng 4.0.4` truncates `ps -o "%p %a"` paths — fixed to `ps -o "pid,args"` |
| Persistent daemons killed every 3 minutes | Process monitor `MAX_RUNTIME` incorrectly included screen-session daemons |
| Duplicate processes — wrong one killed | `pgrep -f "script.pl"` matches SCREEN wrapper command — fixed to `pgrep -f "perl.*script.pl"` |

See `vicidial_rocky10_postinstall_fix_guide_p2.md` for full technical details.

### Re-running install.pl reverts these patches — that's handled automatically

`install.pl` redeploys fresh, unpatched files every time it runs, silently undoing the
DBI:MariaDB, ps-truncation, `Asterisk::AGI.pm`, `sip.conf`, and `pjsip.conf` fixes above.
Part 2 installs `/usr/local/sbin/vicidial-rocky10-repatch` plus a systemd `.path` unit
(`vicidial-rocky10-repatch.path`) that watches every file/directory `install.pl` touches
and re-applies all of these patches automatically within seconds — no manual re-patch
step needed after a manual `install.pl` re-run or a future ViciDial upgrade.

Run it by hand any time with: `/usr/local/sbin/vicidial-rocky10-repatch` (idempotent,
safe to run repeatedly). Check `systemctl status vicidial-rocky10-repatch.path` if a
patch ever seems to not have re-applied.

### Call-time guard — no outbound dialing past the legal window (all new installs)

Stock ViciDial lets any admin widen a campaign's calling window (e.g. `24hours`) and never rechecks a lead's
local time once it is in the hopper — which is how a campaign ended up auto-dialing past 9 pm local. Part 2 now
installs three independent layers (dial-time hard stop for auto *and* manual dialing, DB triggers that refuse
widening the settings, and a per-minute watcher that e-mails root). Rules: 09:00–21:00 lead-local, stricter state
windows, bad/implausible timezones blocked. Details, tests and the one site-specific knob (the exempt test
campaign) are in [`calltime-guard/README.md`](calltime-guard/README.md).

---

## Architecture: Daemons vs Cron Jobs

ViciDial uses two categories of processes — **do not mix them**:

**Persistent screen-session daemons** (managed by `ADMIN_keepalive_ALL.pl` via systemd timer):
- `ASTupdate` → `AST_update_AMI2.pl`
- `ASTlisten` → `AST_manager_listen_AMI2.pl` ← master AMI listener
- `ASTsend` → `AST_manager_send.pl`
- `ASTVDauto` → `AST_VDauto_dial.pl`
- `ASTVDadapt` → `AST_VDadapt.pl`
- `ASTVDremote` → `AST_VDremote_agents.pl`
- `ASTfastlog`, `ASTSIPlogger`, `ASTConfUpdater`, `ASTemail`, `ASTconf3way`

**One-shot cron scripts** (run briefly and exit — appropriate for cron/flock wrapper):
- `AST_VDhopper.pl`, `AST_VDauto_dial_FILL.pl`, `AST_flush_DBqueue.pl`
- `AST_manager_kill_hung_congested.pl`, `AST_vm_update.pl`, `AST_conf_update.pl`
- Audio recording: `AST_CRON_audio_1_move_mix.pl`, `AST_CRON_audio_2_compress.pl`

---

## Process Management Services

After Part 2 or Part 3 install, these systemd units are active:

```bash
systemctl status vicidial-keepalive.timer     # Fires ADMIN_keepalive_ALL.pl every 60s
systemctl status vicidial-process-monitor     # Daemon: kills duplicates + runaway cron scripts
```

Log files:
- `/var/log/astguiclient/process_monitor.log` — monitor daemon activity
- `/var/log/astguiclient/ADMIN_keepalive_ALL_wrapper.log` — keepalive run history
