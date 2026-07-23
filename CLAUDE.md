# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Server: Oliver — single combined box, not a cluster

Despite the section name below ("Cluster build repo"), this is **one server doing everything**
(Asterisk + MariaDB + Apache), not a split Asterisk/DB-Web pair. Verified 2026-07-21: no `172.x`
interface exists on this box, and `mariadbd`/`httpd`/Asterisk all run locally on the same host.
The stale claim this replaced (`Asterisk 172.235.34.224` / `DB-Web 172.239.67.94`) appears to have
been aspirational/copy-pasted and never matched reality here — if a real split deployment exists
elsewhere, it isn't this server.

| Role | Value | Notes |
|------|----|-------|
| **Public IP** | `104.207.140.83` | Asterisk + MariaDB + Apache/PHP all on this one host |
| **DDNS hostnames** | `dialengine.ddns.net`, `callbakz.ddns.net` | Both resolve here — two aliases for the same box, not two servers |

- **Asterisk version:** `18.21.0-vici`
- **OS:** Rocky Linux 10
- **SSH port:** `1951` (not 22) — sshd only binds 1951; firewalld's `ssh` service (port 22) was dead weight and removed 2026-07-21
- **ViciDial config:** `/etc/astguiclient.conf`
- **DB credentials:** user `cron`, pass in `/etc/astguiclient.conf` (`VARDB_pass`)
- **AMI credentials:** `/etc/asterisk/manager.conf` has six stock ViciDial accounts (`cron`,
  `updatecron`, `listencron`, `sendcron`, `sipcron`, `confcron`) that all share **one** secret,
  driven by a single DB column (`servers.ASTmgrSECRET`, `varchar(20)`) — not six independent
  passwords. Rotated 2026-07-22 (was the stock default `1234`); to rotate again, update that DB
  column *and* all six `secret =` lines in `manager.conf` together, `asterisk -rx "manager
  reload"`, then bounce the persistent AMI daemons (`AST_manager_send.pl`,
  `AST_manager_listen_AMI2.pl`, `AST_conf_update_screen.pl`) via `systemctl start
  vicidial-keepalive.service` so they pick up the new value — they cache it in-process and won't
  reconnect with it otherwise. Not internet-exposed: firewalld's `asterisk` service covers
  5060/5061/4569/8088/8089, not AMI's 5038, and the zone default-denies.
- **Cluster build repo:** `https://github.com/FrancoSmash73/vicidial-rocky10` (local: `/usr/src/vicidial-rocky10/`)
  - `vicidial_rocky10_part1_install.sh` — system deps, Perl modules, DBD::mysql 4.052, PHP UTC timezone
  - `vicidial_rocky10_part2_install.sh` — Asterisk build, ViciDial SVN, DB schema, AGI.pm patch, sip.conf websocket fix, VARactive_keepalives flags
  - `vicidial_rocky10_part3_process_mgmt.sh` — systemd services, keepalive, process management, ps truncation fix (4 scripts)
  - `vicidial_rocky10_part4_webrtc.sh` — WebRTC/WSS (Asterisk http.conf + pjsip transport-wss), Let's Encrypt SSL, HulkPhone softphone deploy

---

## Key Paths

| Purpose | Path |
|---------|------|
| ViciDial Perl scripts | `/usr/share/astguiclient/` |
| AGI scripts | `/var/lib/asterisk/agi-bin/` |
| Audio files | `/var/lib/asterisk/sounds/` |
| Empire IVR audio (EN) | `/var/lib/asterisk/sounds/empire/` |
| Empire IVR audio (ES) | `/var/lib/asterisk/sounds/empire/es/` |
| Asterisk dialplan | `/etc/asterisk/extensions.conf` |
| ViciDial dialplan include | `/etc/asterisk/extensions-vicidial.conf` |
| Empire IVR dialplan | `/etc/asterisk/extensions-empire-ivr.conf` |
| ViciDial logs | `/var/log/astguiclient/` |
| Asterisk full log | `/var/log/asterisk/full` |

---

## Common Operational Commands

### Asterisk
```bash
# Live CLI with verbose logging
asterisk -rvvvvv

# Non-interactive commands
asterisk -rx "core show channels"
asterisk -rx "sip show peers"
asterisk -rx "dialplan reload"
asterisk -rx "dialplan show <context>"

# Monitor live calls for a campaign or audio file
tail -f /var/log/asterisk/full
```

### ViciDial DB queries (MariaDB runs locally on this same box)
```bash
mysql -u cron -p'<pass>' asterisk -e "<query>"

# Campaign call stats
SELECT status, count(*) FROM vicidial_log WHERE campaign_id='XXXX' GROUP BY status;

# Answered calls with duration
SELECT phone_number, status, length_in_sec, call_date FROM vicidial_log
  WHERE campaign_id='XXXX' AND status NOT IN ('NA','PDROP') ORDER BY call_date DESC LIMIT 20;

# Live agents in campaign
SELECT user, campaign_id, status FROM vicidial_live_agents WHERE campaign_id='XXXX';

# Campaign broadcast settings
SELECT campaign_id, dial_method, survey_method, survey_first_audio_file,
  am_message_exten, cpd_amd_action, dial_prefix FROM vicidial_campaigns;
```

### Force ViciDial config rebuild (after carrier/SIP changes)
```bash
perl /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --force
```

---

## Audio Files (Broadcast/IVR)

All audio files must be:
- **Format:** PCM WAV, 8000 Hz, 16-bit, mono
- **Owner:** `asterisk:asterisk`
- **Permissions:** `644`

```bash
# Verify format
soxi /var/lib/asterisk/sounds/yourfile.wav    # must show 8000 Hz, 1 channel, 16-bit

# Convert any WAV to correct format
sox input.wav -r 8000 -c 1 -e signed-integer -b 16 /var/lib/asterisk/sounds/output.wav

# Fix ownership
chown asterisk:asterisk /var/lib/asterisk/sounds/yourfile.wav

# In a cluster, copy to ALL Asterisk servers — calls route to any dial node
```

### Broadcast campaign flow
- `dial_method` = `RATIO` (requires at least one agent logged in to dial)
- `survey_first_audio_file` = filename without `.wav` extension
- `survey_method` = `HANGUP` (play then hang up) or `AGENT_XFER`
- `cpd_amd_action` = `DISABLED` (plays to everyone who answers)
- `survey_dtmf_digits` = **must not be empty** — empty string causes `STREAM FILE` to be sent without escape_digits, Asterisk returns `520 Invalid command syntax`, audio is never played (calls log as `SVYHU` with `length_in_sec=0`). Set to any non-empty value e.g. `0123456789*#`.
- Test from bottom of campaign page = **manual agent dial**, does NOT trigger survey audio
- `length_in_sec` in `vicidial_log` only counts for answered calls; `NA` calls always show `0`

### Survey campaign debugging
```bash
# AGI execution log — shows every DB query and stream_file result per call
tail -f /var/log/astguiclient/agiout.$(date +%Y-%m-%d)

# Symptom: survey audio not playing, calls log SVYHU with length_in_sec=0
# Diagnostic: grep for interrupt_digit in AGI log
grep "interrupt_digit" /var/log/astguiclient/agiout.$(date +%Y-%m-%d)
# "interrupt_digit ||" = stream_file returned undef (520 error or channel dead)
# "interrupt_digit |0|" = file played successfully, no key pressed
# "interrupt_digit |-1|" = channel hung up during playback

# Asterisk log: "Playing 'filename'" only appears if Asterisk actually starts the file
grep "Playing\|SVYHU\|AGI Script" /var/log/asterisk/full | tail -30
```

---

## Perl / AGI — Critical: Module Paths and Drivers

### DBD::mysql vs DBD::MariaDB
ViciDial main scripts (vdautodial, remoteagent, etc.) use `DBI:MariaDB:` — requires `DBD::MariaDB` (installed).
AGI scripts (agi-VDAD_local_optimize.agi, etc.) still use `DBI:mysql:` — requires `DBD::mysql`.
On Rocky Linux 10, only `DBD::MariaDB` is installed by default. AGI scripts fail silently at the DB connect line.
Fix: `cpanm --notest DVEEDEN/DBD-mysql-4.052.tar.gz` (v5.x fails to compile against MariaDB headers).
Both modules coexist safely.

### Asterisk::AGI.pm — empty digits bug (patched on this server)
Stock ViciDial ships `Asterisk::AGI.pm` with a bug: `stream_file($file, "")` (empty string digits) sends
`STREAM FILE filename ` without escape_digits. Asterisk returns `520 Invalid command syntax` and the file
never plays. Patched in both locations:
- `/usr/local/share/perl5/5.40/Asterisk/AGI.pm`
- `/usr/share/astguiclient/libs/Asterisk/AGI.pm`

```bash
# One-liner to apply patch (all 4 affected functions):
sed -i "s/\$digits = '\"\"' if (!defined(\$digits));/\$digits = '\"\"' if (!defined(\$digits) || \$digits eq '');/g" \
    /usr/local/share/perl5/5.40/Asterisk/AGI.pm \
    /usr/share/astguiclient/libs/Asterisk/AGI.pm

# Verify (should show 4 lines):
grep -c "eq ''" /usr/local/share/perl5/5.40/Asterisk/AGI.pm
```

### chan_sip + res_pjsip WebSocket conflict — websocket_enabled must be false

ViciDial install.pl sets `websocket_enabled=true` in `sip.conf` by default. This causes `chan_sip.so`
to register the `"sip"` WebSocket sub-protocol during module load. When `res_pjsip_transport_websocket.so`
then tries to register the same sub-protocol, it fails with `AST_MODULE_LOAD_DECLINE` — the module shows
"Not Running" and **WebRTC softphones can never register**.

Fix (one line in `/etc/asterisk/sip.conf`):
```
websocket_enabled=false  ; Required when using res_pjsip — see comment in sip.conf
```

The comment already in ViciDial's sip.conf template says exactly this. Part 2 install script now applies
it automatically post-install.pl.

```bash
# Verify the module loaded:
asterisk -rx "module show like res_pjsip_transport_websocket"
# Must show: Running
```

### ps truncation on Rocky Linux 10 — 4 ViciDial scripts affected

`procps-ng 4.0.4` (Rocky Linux 10) truncates output of `ps -o "%p %a"` to ~30 chars, cutting off full
Perl script paths. Four ViciDial scripts use this format to detect running processes — when the path is
truncated, they think their sibling processes are dead and either exit or spawn duplicates:

- `ADMIN_keepalive_ALL.pl`
- `AST_manager_send.pl`
- `AST_VDremote_agents.pl`
- `AST_VDauto_dial.pl`

Fix: swap to `ps -f --no-headers -A` (or `ps -o "pid,args" --no-headers -A`). Part 3 script patches all
four automatically.

### Asterisk runs in a detached `screen`, launched by rc.local — NOT `asterisk.service`
Verified on Oliver 2026-07-21: `asterisk.service` is **masked** and `vicidial-asterisk.service`
reports inactive — **by design**, not drift. The real, only running instance is inside a detached
`screen -L -S asterisk` session (PID chain: `rc-local.service` → `SCREEN -S astshell...` → `sh` →
`screen -L -S asterisk` → `asterisk -vvvvvvvvvvvvvvvvvvvvvgcT`), running as root as ViciDial's AGI
scripts, log files, and directories all expect (running as the `asterisk` user causes permission
denied errors in action_process logs, CDR logs, and ViciDial astguiclient logs).

**`systemctl status asterisk` will always show masked/inactive here even when Asterisk is healthy
— that is expected, not a fault.** Don't "fix" it by unmasking and starting `asterisk.service`;
that would spawn a **second** instance alongside the screen-managed one. Two instances both bind
UDP 5060 and SIP 200 OK responses go to the wrong process — all carriers show UNREACHABLE.

```bash
ss -ulnp | grep 5060       # Must show only 1 process (root) — the real liveness check
screen -ls                 # Should show "asterisk" (and the astshell wrapper) attached/detached
screen -r asterisk         # Attach to the live console (Ctrl-A D to detach without killing it)
asterisk -r                # Connect a second read-only CLI session, safe alongside the console
```

### Module Path

ViciDial puts Perl modules in `/usr/share/astguiclient/libs/` but Asterisk spawns AGI scripts without `PERL5LIB` set. On Rocky Linux 10, modules must be manually copied to the system Perl path or **every AGI call silently fails**.

```bash
# Symptom: "AGI Script completed, returning 0" with no actual routing happening
# Fix:
perl -e "print $]"    # get Perl version, e.g. 5.040
mkdir -p /usr/local/share/perl5/5.40/Asterisk
cp /usr/share/astguiclient/libs/Asterisk/*.pm /usr/local/share/perl5/5.40/Asterisk/
cp /usr/share/astguiclient/libs/Asterisk.pm   /usr/local/share/perl5/5.40/
cp /usr/share/astguiclient/libs/viciagi.pm    /usr/local/share/perl5/5.40/
cp /usr/share/astguiclient/libs/vicidial.pm   /usr/local/share/perl5/5.40/

# Verify
perl -e "use Asterisk::AGI; print 'OK\n'"
perl -c /var/lib/asterisk/agi-bin/agi-DID_route.agi
```

---

## Firewall (firewalld)

**Use firewalld exclusively — never enable the nftables service (it creates hidden DROP rules that override firewalld).**

```bash
systemctl status nftables       # Must be disabled/inactive
nft list ruleset | grep "saddr !="   # Must return nothing

# Carriers whitelisted on this server:
# 88.151.128.22   — TBI-OUT (outbound SIP trunk; no explicit firewall rule needed —
#                   outbound-initiated, return traffic rides conntrack established state)
#
# DID4Sale (66.209.76.0/24) — decommissioned as of 2026-07-21, no longer in use.
# Confirmed no trace anywhere (no firewall rule, no PJSIP config, no DB carrier entry).
# Same audit also found and removed a stray, unexplained 5060/udp allow for a
# DigitalOcean IP (167.99.243.205) that matched no configured carrier — if a similar
# unrecognized rule turns up again, treat it as suspicious and verify before keeping it.
#
# 2026-07-21: also removed the public-zone `ssh` service entry (port 22) — sshd only
# ever listens on 1951 (see SSH port note above), so the port-22 allow was dead weight
# with nothing behind it. 1951/tcp stays explicitly allowed via the ports= list.
#
# 2026-07-21: full rule re-audit turned up two more dead/overbroad entries, both removed:
# - `1984/tcp` was world-open with nothing listening behind it (no systemd socket, no
#   cockpit/ViciDial config referencing it — just IANA's registered "bb" name, unused here).
# - A standalone unscoped `187.191.49.142 accept` rich rule granted that IP EVERY port/
#   protocol on the box, well beyond what it actually uses. That IP is legitimate (it's
#   in ViciDial's own ViciWhite list, 2026-07-13) and still gets full SIP/RTP access via
#   the dynamiclist ipset like any other whitelisted agent, plus whatever's globally open
#   (http/https/cockpit/1951/446/81) — the blanket rule added nothing beyond that except
#   exposure (e.g. AMI 5038/tcp) that was never observed in use. If real AMI/other access
#   from that IP turns out to be needed, add a scoped rich rule for just that port.

# Add a new carrier IP
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="X.X.X.X" port port="5060" protocol="udp" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="X.X.X.X" service name="rtp" accept'
firewall-cmd --reload
```

fail2ban uses `nftables-allports` action (NOT iptables). Two action lines required — one for TCP, one for UDP:
```ini
action = nftables-allports[name=asterisk]
         nftables-allports[name=asterisk-udp, protocol=udp]
```

---

## Empire IVR

- **DID:** `6088091363` → context `empire-ivr` in `/etc/asterisk/extensions-empire-ivr.conf`
- English audio: `/var/lib/asterisk/sounds/empire/`
- Spanish audio: `/var/lib/asterisk/sounds/empire/es/`
- After any dialplan change: `asterisk -rx "dialplan reload"` then `asterisk -rx "dialplan show empire-ivr"`

---

## Carrier SIP Config

`allowguest=no` is set in `sip.conf` — every inbound carrier IP needs a peer entry in ViciDial DB. For carriers with multiple gateway IPs, add one DB entry per IP and whitelist the full `/24` in firewall.

```sql
-- After inserting carrier, trigger config rebuild:
UPDATE servers SET rebuild_conf_files='Y' WHERE server_ip='104.207.140.83';
-- Then run: perl /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --force
```
