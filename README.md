# ViciDial Rocky Linux 10 Install Scripts

**Asterisk:** 18.21.0-vici | **ViciDial:** SVN trunk | **OS:** Rocky Linux 10.x / AlmaLinux 10.x
**PHP:** 8.3 | **MariaDB:** 10.11 | **Perl:** 5.40

---


## PJSIP-only posture (⚠️ NEEDS VALIDATION)

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

> ⚠️ **Not yet validated end-to-end.** Every layer has been verified on a live
> Rocky 10 box — endpoints load, passwords match `conf_secret`, WSS is bound on
> 8089 with a valid cert, the dialplan resolves to `PJSIP/` — but **no browser
> webphone has been observed completing a WebRTC registration** on that box yet.
> Treat PJSIP-only as recommended-but-unproven until someone confirms an agent
> login. Roll back by re-activating chan_sip and setting `phones.protocol='SIP'`,
> then `servers.rebuild_conf_files='Y'` to regenerate the dialplan.


## Scripts

| Script | Purpose |
|--------|---------|
| `vicidial_rocky10_part1_install.sh` | Base OS packages, Asterisk build, ViciDial SVN checkout, Perl modules |
| `vicidial_rocky10_part2_install.sh` | ViciDial database setup, Asterisk config, ConfBridge, process management |
| `vicidial_rocky10_part3_process_mgmt.sh` | **Standalone addon** — process management only, safe to run on any existing ViciDial install |

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
```

All scripts are **idempotent** — safe to re-run. Parts 1 and 2 track progress in
`/root/.vicidial_part1_progress` and `/root/.vicidial_part2_progress` and will
prompt skip/re-run/quit for each completed step.

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
