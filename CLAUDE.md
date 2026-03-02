# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

A modular, idempotent installation framework for deploying **ViciDial** (open-source call center / auto-dialer) on **Rocky Linux 10 / AlmaLinux 10**. It also ships a three-layer process management system that eliminates the duplicate-daemon bug inherent in vanilla ViciDial installations.

Core stack after install: Asterisk 18.21.0-vici · DAHDI 3.4.0 · LibPRI 1.6.1 · MariaDB 10.11 · Apache + PHP 8.3 · Perl 5.40.

---

## Installation Commands

The three parts are independent and idempotent — safe to re-run; each step prompts **[S]kip / [R]e-run / [Q]uit** based on progress markers in `/root/`.

```bash
# Part 1 — MariaDB, Apache, PHP 8.3, Perl modules, ViciDial schema
chmod +x vicidial_rocky10_part1_install.sh && ./vicidial_rocky10_part1_install.sh

# Part 2 — DAHDI, LibPRI, Asterisk, ViciDial core, systemd services, process management
chmod +x vicidial_rocky10_part2_install.sh && ./vicidial_rocky10_part2_install.sh

# Part 3 — Process management only (can run standalone on any existing ViciDial install)
chmod +x vicidial_rocky10_part3_process_mgmt.sh && ./vicidial_rocky10_part3_process_mgmt.sh
```

**Logs:**
- Part 1: `/var/log/vicidial_ultimate_part1.log`
- Part 2: `/var/log/vicidial_install_part2.log`
- Part 3: `/var/log/vicidial_step23_process_mgmt.log`

---

## Verification & Diagnostics

```bash
# Post-install health check (screens, DB, timers, DBI patch verification)
./vicidial_rocky10_audit.sh

# Multi-server cluster audit
python3 vicidial_rocky10_audit.py

# Show currently running duplicate processes
./vicidial_duplicate_checker.sh

# Watch process monitor live
systemctl status vicidial-process-monitor
tail -f /var/log/astguiclient/process_monitor.log

# Check Asterisk SIP peers / active calls
asterisk -rx "sip show peers"
asterisk -rx "sip show registry"
asterisk -rx "core show channels"

# Live SIP debug for a specific trunk
asterisk -rx "sip set debug peer <trunk-name>"
tail -f /var/log/asterisk/messages
```

---

## Architecture: Three-Layer Process Management

The core innovation of this project. ViciDial's `ADMIN_keepalive_ALL.pl` (which spawns ~10 screen-session daemons) was historically run via raw cron — causing 5–10 overlapping instances when any run exceeded 60 seconds.

**Layer 1 — systemd timer** (`vicidial-keepalive.timer`):
Uses `OnUnitInactiveSec=1min` (not `OnCalendar`), so the next run starts 60 seconds **after the previous completes**, never while it's still running.

**Layer 2 — flock wrapper** (`/usr/local/bin/vicidial_cron_wrapper.sh`):
Belt-and-suspenders. A second invocation exits immediately if the lock file is held.

**Layer 3 — process monitor daemon** (`vicidial_process_monitor.sh`):
Runs every 60 seconds. Finds any process with >1 instance, keeps the oldest (longest-running), SIGTERMs then SIGKILLs the rest. Also kills runaway processes exceeding `MAX_RUNTIME`.

---

## Critical Rocky Linux 10 Compatibility Patches

These are applied automatically by the install scripts but matter when editing ViciDial scripts manually:

**DBD::mysql → DBD::MariaDB** — Rocky 10 ships Perl 5.40 which has no `DBD::mysql`. Every `.agi` and `.pl` in ViciDial must use `DBI:MariaDB` instead:
```bash
sed -i 's/DBI:mysql/DBI:MariaDB/g' /var/lib/asterisk/agi-bin/*.agi
sed -i 's/DBI:mysql/DBI:MariaDB/g' /usr/share/astguiclient/*.pl
```
If inbound calls fail silently, this patch missing is the first thing to check.

**Switch.pm removed** — Perl 5.40 dropped `Switch.pm`. Any ViciDial script using `use Switch;` must be patched to use `if/elsif` chains.

**`ps` truncation** — `procps-ng 4.0.4` truncates `ps` output at 4096 chars. The process monitor queries `/proc/<pid>/cmdline` directly instead of parsing `ps aux`.

---

## ViciDial Screen Daemons

`ADMIN_keepalive_ALL.pl --cu3way` manages these persistent `screen` sessions:

| Screen Name | Script |
|---|---|
| ASTupdate | AST_update_AMI2.pl |
| ASTlisten | AST_manager_listen_AMI2.pl |
| ASTsend | AST_manager_send.pl |
| ASTVDauto | AST_VDauto_dial.pl |
| ASTVDadapt | AST_VDadapt.pl |
| ASTVDremote | AST_VDremote_agents.pl |
| ASTfastlog, ASTSIPlogger, ASTConfUpdater, ASTemail, ASTconf3way | (various) |

Access a daemon: `screen -r ASTupdate`
List all: `screen -ls`

---

## Dialplan & Asterisk Config Locations

- ViciDial auto-generates `/etc/asterisk/sip-vicidial.conf` and `/etc/asterisk/extensions-vicidial.conf` — **edits to these files are overwritten** on every VICIdial admin save or reload.
- Carrier trunk config and dialplan entries survive in the **ViciDial admin UI** (Carriers → Account Entry / DialEntry fields), which is the authoritative source.
- Custom dialplan that must survive reloads goes in `/etc/asterisk/extensions_custom.conf` included via `extensions.conf`.
- RTP port range: **9000–35000** (see `configs/rtp.conf`).
- Asterisk logs: `/var/log/asterisk/messages` (primary), `/var/log/asterisk/full` (verbose/debug).

---

## Deployment Scenarios

Documented in `INTEGRATION_GUIDE.md`:
1. **Standalone** — all components on one server (run all three parts)
2. **Dual-server** — DB/Web on Server 1, Asterisk on Server 2 (Part 1 on S1, Parts 2–3 on S2)
3. **Add-on to existing ViciDial** — Part 3 only, drops process management onto any existing install

The `EMPIRE_SESSION_NOTES.md` file contains a full production case study of the dual-server deployment.
