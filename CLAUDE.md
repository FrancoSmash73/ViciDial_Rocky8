# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Cluster Architecture

| Role | IP | Notes |
|------|----|-------|
| **Asterisk (this server)** | `172.235.34.224` | Handles all SIP/RTP, AGI scripts, audio playback |
| **DB / Web (ViciDial Admin)** | `172.239.67.94` | MariaDB + Apache + ViciDial PHP frontend |

- **Asterisk version:** `18.21.0-vici`
- **OS:** Rocky Linux 10
- **SSH port:** `1951` (not 22)
- **ViciDial config:** `/etc/astguiclient.conf`
- **DB credentials:** user `cron`, pass in `/etc/astguiclient.conf` (`VARDB_pass`)
- **Cluster build repo:** `https://github.com/FrancoSmash73/vicidial-rocky10` (local: `/usr/src/vicidial-rocky10/`)
  - `vicidial_rocky10_part1_install.sh` — system deps, Perl modules, DBD::mysql 4.052
  - `vicidial_rocky10_part2_install.sh` — Asterisk build, ViciDial SVN, DB schema, AGI.pm patch
  - `vicidial_rocky10_part3_process_mgmt.sh` — systemd services, keepalive, process management

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

### ViciDial DB queries (run on DB server 172.239.67.94)
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

### Asterisk systemd service — runs as root, never run a second console instance
Asterisk runs as a **systemd service** configured as `User=root` (see `/etc/systemd/system/asterisk.service`).
ViciDial's AGI scripts, log files, and directories all expect root ownership. Running as `asterisk` user
causes permission denied errors in action_process logs, CDR logs, and ViciDial astguiclient logs.
Never start a second instance with `asterisk -vvvgcT`. If two instances run, both bind to UDP 5060 and
SIP 200 OK responses go to the wrong process — all carriers show UNREACHABLE.
```bash
ss -ulnp | grep 5060    # Must show only 1 process (root)
systemctl status asterisk   # Use this to check status
asterisk -r             # Connect to running service for CLI
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
# 66.209.76.0/24  — DID4Sale (inbound DIDs)
# 88.151.128.22   — TBI-OUT (outbound SIP trunk)

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
UPDATE servers SET rebuild_conf_files='Y' WHERE server_ip='172.235.34.224';
-- Then run: perl /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --force
```
