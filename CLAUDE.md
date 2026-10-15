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
| **Public IP** | `187.189.34.192` (behind CGNAT — see note below) | Asterisk + MariaDB + Apache/PHP all on this one host. Old IP `104.207.140.83` is deleted/decommissioned as of 2026-09-06 — don't reference it anymore |
| **DDNS hostnames** | `dialengine.ddns.net`, `callbakz.ddns.net` | **Stale as of 2026-09-05 — neither resolves here anymore, both moved (both accounted for, see note below)** |

**2026-09-05 DNS drift:** Oliver's actual public-facing IP (per `curl -4 ifconfig.me` from this box)
is now `187.189.34.192`, not `104.207.140.83` — it sits behind CGNAT (private LAN IP
`192.168.100.14`), so its ISP-facing address was never directly reachable inbound anyway; the DDNS
hostnames were the real reachability path. Both have since moved off Oliver entirely:
- `dialengine.ddns.net` → `45.63.17.128` (the new vicidial-rocky10 server being built — intentional,
  confirmed by the user).
- **Update 2026-10-13:** the relay VPS moved again. The Vultr box (`149.28.64.211`) died and the
  relay was rebuilt 2026-10-12 on an InMotion Alma 9 VPS, **`216.194.173.220`** — which is what
  `callbakz.ddns.net` resolves to now and what `wg0` points at (`/etc/wireguard/wg0.conf`,
  `Endpoint = 216.194.173.220:33445`, handshake verified healthy after reboot).
  `sip.campaignvoiceservices.com` resolves (A record) to the relay `216.194.173.220` too — an earlier note here claiming Cloudflare was a `.com.com` search-domain artifact of `getent hosts`; use `dig +short` instead. The
  `149.28.64.211` references below are historical (as of 2026-09-05/06).
- **Relay nginx `/ws` proxy (added 2026-10-14) — WebRTC phones depend on it.** HulkPhone is
  configured (`/var/www/html/hulkphone/config.local.php`: `sip_domain=callbakz.ddns.net`,
  `ws_port=443`) to open `wss://callbakz.ddns.net:443/ws`. The Oct 12 relay rebuild recreated
  `callbakz.conf` with only a catch-all `location /` proxying to Apache (`10.0.0.2:80`), so `/ws`
  returned **404** and every WebRTC extension showed "NOT registered" with no error on the
  Asterisk side (nothing ever reached it). Fix, on the relay (`ssh vps`, port 1951): in
  `/opt/mailcow-dockerized/data/conf/nginx/callbakz.conf` (Mailcow's nginx owns host 443 via
  docker-proxy — there is no host-level nginx), a `location /ws` block in the `listen 443` server
  proxies to `http://10.0.0.2:8088` (Asterisk's plain-ws listener, over wg0) with `Upgrade`/
  `Connection "upgrade"` headers and 3600s timeouts. Original saved as
  `callbakz.conf.bak.20261014`; apply with `docker exec $(docker ps -qf name=nginx-mailcow) nginx -t`
  then `nginx -s reload` (graceful). Quick check from anywhere: a `curl -sk --http1.1` with
  `Upgrade: websocket` headers to `https://callbakz.ddns.net/ws` must return `101 Switching
  Protocols` (404 = this proxy rule is missing). **Re-apply it after any relay rebuild**, and
  note the relay's own port 8089 (`wss`, cert for `sip.campaignvoiceservices.com`) works as an
  alternative only for networks that allow it — 443 is what HulkPhone is set to use.
- **Credentials-in-URL log redaction (added 2026-10-14).** `vicidial.php` builds the HulkPhone iframe URL
  with `phone_pass=<base64 phones.conf_secret>` (plus stock `VD_pass`/`pp` GET params elsewhere), so the
  SIP secret landed in access logs and `Referer` headers. Now: Apache `vicidial.conf` logs requests whose
  query or Referer carries a `*pass*`/`*pw*`/`*secret*`/`pp` param with the `combined_redacted` format
  (path only), and sets `Referrer-Policy: no-referrer` on `/hulkphone`; the relay's `callbakz.conf` does the
  same via `map`/`log_format cb_redacted` (logs go to `docker logs` on the nginx-mailcow container, not a
  file). Backups: `/root/vicidial.conf.bak.20261014`, `callbakz.conf.bak2.20261014`. Logs written before
  this date still contain the old secrets, so rotate `phones.conf_secret`. **Re-apply on the relay after a rebuild.**
- **Phone SIP secrets live in TWO places (rotated 2026-10-14).** `phones.conf_secret` (DB; what `vicidial.php`
  hands HulkPhone) AND the hand-managed Asterisk files `pjsip-hulkagents.conf` (10001-10011, gs102) and
  `pjsip.conf` (40004, a Yealink that must also be updated on the handset). `rebuild_conf_files`/keepalive
  does NOT touch those, so changing only the DB breaks registration. Rotate both together; 20002/88888 are
  chan_sip (not loaded) and `callin` is EXTERNAL, so DB-only. The 2026-10-14 rotation working folder (old/new values) was deleted afterwards; current values are in the DB and those pjsip files.
- `callbakz.ddns.net` → `149.28.64.211`, a Vultr-hosted nginx box (historical, see update above). **Resolved, benign:** checked
  against the No-IP account that manages this hostname — "Oliver" was a previous install that used
  to sit behind this same DDNS name, and the same account later repointed it to this Vultr box. Same
  account, not a hijack/reused name — just this hostname being reassigned to newer infrastructure
  over time. No further action needed on this point.
- **`wg0` interface — resolved, not a discrepancy.** Oliver's live `wg0` WireGuard interface
  (`10.0.0.2/24`) contradicted this file's prior conclusion (commit `e93261f`) that no wg0 tunnel
  exists here. Since investigated and understood: it's a real, healthy WireGuard tunnel to a Vultr
  relay VPS (`149.28.64.211` at the time; now `216.194.173.220`, see update above), carrying SIP/RTP/WSS to Oliver via
  firewalld DNAT on the VPS side. Runs on UDP/33445 instead of WireGuard's default specifically
  because the office ISP (Mexican CGNAT) silently drops outbound UDP on common VPN ports and can
  change that filter list at any time — if this tunnel ever looks dead, check for renewed ISP
  port-blocking before anything else (`wg show wg0` for handshake/traffic, full troubleshooting
  path in the private `vicidial-skin` repo's `dynportal/README.md`). `e93261f`'s "no tunnel exists"
  conclusion was simply wrong at the time it was verified, or the tunnel was added afterward — the
  earlier check's own history is inconclusive, but the current live state is confirmed and healthy
  as of 2026-09-06.

- **Asterisk version:** `20.18.2` (plain upstream, built 2026-02-26; **not** `18.21.0-vici` as this file
  said until 2026-10-13). Verified live: `asterisk -rx "core show version"`. Source tree at
  `/usr/src/asterisk-20.18.2` was deleted once and restored 2026-09-28 from
  `/usr/src/asterisk-20-current.tar.gz` (see `RESTORATION-NOTES.txt` there) — original configure
  options, menuselect choices and local patches were **not** recoverable. **Build-repo mismatch:**
  `vicidial_rocky10_part2_install.sh` still builds Asterisk 18 (ViciDial-patched), so it will not
  reproduce this box; the box was built from `/root/ViciDial_Install_Part2.sh` (Asterisk 20.18.2).
  Check this before assuming a fresh install matches Oliver.
- **DAHDI:** source is not kept in `/usr/src` (it has vanished repeatedly) and no `dahdi.ko` exists for
  any installed kernel — DAHDI was built out-of-tree with no DKMS, so removing an old kernel via
  dnf deletes its `/lib/modules/<ver>/updates`. `dahdi.service` shows `active (exited)` regardless
  and means nothing. Nothing on this box needs it (ConfBridge/PJSIP). An auditd watch
  (`/etc/audit/rules.d/usrsrc.rules`, key `usrsrc`, added 2026-10-13) records whatever next deletes
  from `/usr/src`: `ausearch -k usrsrc -i | grep -B2 -A6 "nametype=DELETE"`.
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

### Call-time guard — hard 9pm / state / bad-timezone dial block (added 2026-10-14)

Why: on 2026-10-02 WASH auto-dialed 21:00-22:28 local because `local_call_time` had been saved as
`24hours` (9/30). ViciDial treats call time as an ordinary campaign field and `AST_VDauto_dial.pl`
never rechecks a lead's local time after it is in the hopper. `calltime-guard/Rocky10CallTime.pm`
(installed to `/usr/local/share/perl5/5.40/`) is a pure function `rocky10_calltime_block($gmt,$state,$epoch)`
that returns `''` (ok) or a reason. `AST_VDauto_dial.pl` calls it right after loading each lead from the
hopper (marker `ROCKY10-CALLTIME-GUARD-v1`); on a block it deletes the hopper row, skips the lead and
appends to `/var/log/astguiclient/VDAD_CALLTIME_BLOCK.<date>`. Rules live in CODE, not the admin UI:
- company window 09:00-21:00 local; a state's own stricter window is intersected, never widened
  (AL/FL/LA/MA/MD/MS/OK/WA/WY end 20:00, IN/NV/UT 09-20, ME 09-17, RI 09-18 + Sat 10-17, Sun closed in
  AL/LA/MS/SD/RI, TX Sun from 12:00, PA Sun from 13:30, KY opens 10:00 — copied from this box's
  `vicidial_state_call_times`);
- 2-minute safety margin off the end of every window (ringing follows the dial);
- `gmt_offset_now` outside -10..-4 (or non-numeric) = BAD_TZ, blocked;
- a lead with no/unknown state is NOT blocked: it gets the 09:00-21:00 default (~90k leads have no state).
Survives upgrades: `vicidial-rocky10-repatch` section 8 re-applies it (via `apply_vdauto_guard.py`),
`perl -c`s the result, restores the old file if that fails, and restarts the dialer; verified by
reverting the file by hand (re-patched within 10 s). Tests: `cd calltime-guard && perl -I. test_calltime.pl`
(40 cases, no DB); `perl -I. dryrun_hopper.pl` shows what would be blocked in the live hopper right now.
**Manual dialing is guarded too** (`agc/vdc_db_query.php`, same marker): `manual_rocky10_calltime_check()` runs
just before the stock `manual_dccl_check()` in both `manDiaLnextCaLL` and `manDiaLonly`, using a PHP port
of the same rules (fuzzed against the Perl version: 4000 cases, 0 mismatches). A block returns
`OUTSIDE LOCAL CALLING HOURS` (the agent screen already pops "outside of the local call time" for any reply
containing "OUTSIDE"), purges the manual-dial queue/`external_dial` like the stock DNC refusal, and logs
`ROCKY10-CALLTIME-GUARD manual BLOCK ...` via PHP `error_log` (php-fpm `www-error.log`). A lead_id that
doesn't exist is treated as BAD_TZ and blocked. **Campaign `TEST1` is exempt** from the manual cap
(`$r10_exempt` in that function) because it is the owner's own-number test campaign; auto-dial has no
exemption. Re-applied by repatch section 8b (`apply_vdc_guard.py`), and the guarded file is also the staged
copy in `agc-security-patches/vdc_db_query.php`, so an upgrade restore keeps it.

### Force ViciDial config rebuild (after carrier/SIP changes)
> **Does NOT apply to Oliver (verified 2026-10-14).** `servers.generate_vicidial_conf` is `N` here, so
> `ADMIN_keepalive_ALL.pl` skips its rebuild block entirely: `rebuild_conf_files='Y'` is never consumed or
> cleared (a stale `Y` just sits there; it was reset to `N`), and `--force` regenerates nothing. Live
> PJSIP/SIP config is hand-managed (`pjsip-hulkagents.conf`, `pjsip.conf`, `pjsip-carriers.conf`,
> `pjsip-hardware-phones.conf`): edit those and `asterisk -rx "module reload res_pjsip.so"`. Do not flip
> `generate_vicidial_conf` to `Y` without review: it would overwrite the immutable
> `extensions-vicidial.conf` and the generated pjsip/sip files. The snippet below is for boxes that do
> generate their config. The same caveat applies to the `rebuild_conf_files` steps in the WebRTC crackle and
> carrier sections.

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

### WebRTC agent phones — crackly audio from opus↔8kHz ConfBridge transcoding

Symptom: a `PJSIP_WEBRTC`-template agent phone (e.g. extension 20001, first hit on the
vicidial-rocky10 box "Manny" 2026-09-06) sounds clean while alone in the agent ConfBridge (hearing
the "you are the only participant" prompt) but goes crackly/choppy the moment a second leg
(customer call, PSTN test call, etc.) actually connects and real two-way audio starts.

Root cause: the `PJSIP_WEBRTC` template (`vicidial_conf_templates`) sets `allow=opus` before
`allow=ulaw`, so browsers (which offer Opus first) negotiate Opus at 48kHz — but ViciDial's
`vici_agent_bridge` ConfBridge mixes at 8kHz. That forces a double resample/transcode on every
frame in both directions (`opus@48k -> slin@48k -> slin@8k` and back). A static prompt file
tolerates the jitter this introduces; live conversational audio doesn't. Confirmed NOT the cause:
the HulkPhone JS itself (checked via diff — no audio/codec changes in the relevant commit), and NOT
network loss/jitter (RTCP on the WebRTC leg showed 0% loss, ~0.25ms jitter throughout a test call).

Fix — force `ulaw`-only on the affected extension via `phones.conf_override`, which is appended
*after* the template block during config generation and so wins over the template's `allow=opus`
without editing the shared template (safe to apply per-extension without affecting sibling
WebRTC phones):

```sql
UPDATE phones SET conf_override='endpoint/disallow=all\nendpoint/allow=ulaw' WHERE extension='20001';
UPDATE servers SET rebuild_conf_files='Y' WHERE server_ip='<this server's IP>';
```
```bash
perl /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --force
asterisk -rx "pjsip show endpoint 20001" | grep "^ allow"   # should show only (ulaw)
```

As of 2026-09-06 this fix is applied **only to extension 20001** on Manny. Extensions 20002–20010
(created the same day, same `PJSIP_WEBRTC` template) still allow `opus|ulaw` and will likely hit
the same crackle once they're used for real calls — deliberately left as-is per user request rather
than pre-emptively patched. If/when the same symptom shows up on any of them (or a new WebRTC
extension elsewhere built from this repo's install scripts), apply the same `conf_override` there.

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

### Asterisk launch mechanism — changed since original verification, re-verified 2026-09-05

**Superseded claim (verified 2026-07-21, no longer true):** this section used to say Asterisk ran
in a detached `screen -L -S asterisk` session launched by `rc.local`, with `asterisk.service`
masked by design. **That is not the current state of this box.** Re-verified 2026-09-05:

- `asterisk.service` (an LSB unit auto-generated by `systemd-sysv-generator` from
  `/etc/rc.d/init.d/asterisk`) is `enabled` and `active (running)` — it is now the real launcher.
  PID chain: `systemd(1)` → `safe_asterisk` → `asterisk -f -vvvg -c`, both running as **root**
  (`/etc/rc.d/init.d/asterisk` only adds `-U $AST_USER` if that var is set, which it isn't — same
  root-run behavior the old screen method relied on, so the permission-denied-as-`asterisk`-user
  rationale below still applies, just via a different launcher).
- `rc.local` is back to the stock, empty CentOS/RHEL-compat template (just `touch
  /var/lock/subsys/local`) — **no** Asterisk/astshell launch logic remains in it.
- `vicidial-asterisk.service` no longer exists at all (`systemctl status` reports "could not be
  found"), vs. the prior "exists but inactive" claim.
- `screen -ls` no longer lists an `asterisk` or `astshell` session — only the other ViciDial
  daemon screens (`ASTfastlog`, `ASTupdate`, `ASTsend`, `ASTlisten`, `ASTVDauto`,
  `ASTConfUpdater`, `ASTVDremote`, `ASTVDadapt`, `ASTconf3way`, `ASTemail`, etc.), which are
  unrelated and still normal.

No dual-instance conflict currently exists (confirmed only one process bound to 5060, and `rc.local`
no longer tries to launch Asterisk at all) — but the underlying lesson stands: **don't assume this
doc's launch-mechanism claim is still true without checking `ps --ppid $(pgrep -f safe_asterisk)`
and `systemctl is-enabled asterisk` first.** This exact box silently changed launch mechanism
between 07-21 and 09-05 (most likely cause: a `make config`/reinstall re-registered the LSB init
script and enabled it) with nobody deciding to do so — treat this as a live risk on any ViciDial
box, not a one-time fluke, and re-verify before trusting either this doc or your prior session's
memory of it.

```bash
ss -ulnp | grep 5060                  # Must show only 1 process (root) — the real liveness check
systemctl is-enabled asterisk         # Confirm which mechanism actually owns it
ps -o pid,ppid,cmd --ppid $(pgrep -f safe_asterisk)   # If safe_asterisk exists, this is the launcher
screen -ls                            # If an "asterisk"/"astshell" session exists instead, that's the old method
asterisk -r                           # Read-only CLI session, safe regardless of which launcher is active
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
#                   NOTE: a firewalld rich rule for 88.151.128.22:5060/udp does exist, but the
#                   rule that actually matters is TBI's own side — TBI authenticates by SOURCE
#                   IP, not password. Traffic to it routes via wg0 (`ip route get 88.151.128.22`)
#                   and leaves the relay, so TBI sees the relay's public IP. **Whenever the relay
#                   VPS changes, TBI must re-authorize the new IP** or every outbound INVITE gets an
#                   immediate `SIP/2.0 403 Not Authorized` from TBI's OpenSIPS (no 401/407
#                   challenge) while the OPTIONS qualify still shows the contact `Avail` — which
#                   makes "carrier looks healthy" misleading. Hit 2026-10-14 after the 2026-10-12
#                   relay rebuild (new IP 216.194.173.220): manual dials from agent 10001 failed
#                   with hangup cause 21 / CHANUNAVAIL; confirmed in `pjsip set logger host
#                   88.151.128.22` capture. **Resolved the same day:** TBI authorized
#                   216.194.173.220 between 14:32 and 14:38 on 2026-10-14; a manual dial from
#                   10001 at 14:38:45 then connected and ran 207 s (later test dials got
#                   `183 Session Progress` from TBI instead of 403). Still re-test an outbound
#                   dial after any future relay change — don't assume it carries over.
#
# DID4Sale (66.209.76.0/24) — CORRECTION 2026-10-14: the "decommissioned / no trace anywhere"
# claim previously written here (2026-07-21) is wrong for this box. Live state: PJSIP endpoints
# `did4sale_inb1/2/3` exist in /etc/asterisk/pjsip-carriers.conf (gateways 66.209.76.70/.72/.74),
# Asterisk qualifies them every few seconds (inb1/inb2 `Avail`, inb3 `Unavailable`), and the
# 2026-10-12 relay-rebuild notes list "DID4SALE repoint inbound" as a pending action. What the
# 07-21 audit actually found is narrower: no firewalld/nft allow rule for 66.209.76.0/24, and no
# row in `vicidial_server_carriers` (only TBI-OUT is active there — these endpoints are
# hand-managed in pjsip-carriers.conf, not ViciDial-generated). No inbound INVITEs from those
# IPs and zero `vicidial_closer_log` rows in 30 days, so inbound DID4Sale traffic is not
# currently arriving. Also: `telnyx` is a configured PJSIP endpoint (192.76.120.10, with outbound
# auth) and answers qualify. DID4Sale/Telnyx traffic goes straight out the office link
# (`ip route get` → enp2s0), NOT through the relay, so those carriers see the office public IP
# (187.189.34.192) as the source, unlike TBI.
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

**fail2ban can crash entirely at boot if the `[asterisk]` jail's log files don't exist yet
(fixed 2026-09-05):** Part 1 runs before Part 2 builds/starts Asterisk, so
`/var/log/asterisk/messages` and `/var/log/asterisk/full` (the jail's `logpath` entries) don't
exist at that point. fail2ban tolerates *some* missing `logpath` entries per jail, but if *all*
of a jail's entries are missing it throws `Have not found any log file for asterisk jail` and
`fail2ban-server` exits 255 — **taking down the entire service**, not just that jail, with no
auto-restart (hit on the 45.63.17.128 install: down for 4h45m until manually restarted; same
failure was hit earlier on Oliver during Part 1 and worked around ad hoc at the time). Part 1 now
`touch`es both placeholder files before fail2ban ever starts. If this ever resurfaces (e.g. a
manual fail2ban reinstall skips that step): `mkdir -p /var/log/asterisk && touch
/var/log/asterisk/messages /var/log/asterisk/full && systemctl restart fail2ban`.

**fail2ban's `[asterisk]` jail was silently blind without Asterisk's own security-event logging
(fixed 2026-09-06):** the stock filter's `SecurityEvent=` regex (line 28 of
`/etc/fail2ban/filter.d/asterisk.conf`) can only ever match if Asterisk actually emits
`SecurityEvent` lines to a log file — and by default it doesn't. Fix, applied on Oliver and needed
on every server:
```bash
grep -q "messages.*security" /etc/asterisk/logger.conf || \
  sed -i 's/^\(messages => .*\)$/\1,security/' /etc/asterisk/logger.conf
asterisk -rx "logger reload"
asterisk -rx "logger show channels"   # confirm SECURITY appears on the messages line
```

**Separately, the stock `[asterisk]` filter has a real regex gap for chan_sip (fixed 2026-09-06):**
its `failed to authenticate` patterns all expect `<HOST>` at the start of the message, so they
never match chan_sip's actual `Failed to authenticate device <sip:ext@<HOST>:port>` format —
letting that whole class of attacker through unbanned regardless of the security-logging fix above.
Confirmed the gap and the fix with `fail2ban-regex` (a synthetic line matching this exact format
went from `0 matched` to correctly extracting `<HOST>` from inside the `<sip:...@HOST:port>`
construct) and independently confirmed the pre-existing blank line before the `# FreePBX` block
doesn't break multi-line `failregex` parsing (checked directly via Python's `configparser`) before
trusting the fix:
```bash
grep -q 'Failed to authenticate device <sip' /etc/fail2ban/filter.d/asterisk.conf || \
  sed -i '/^# FreePBX/i\            ^Failed to authenticate device <sip:[^@]*@<HOST>(?::\\d+)?>.*$' \
    /etc/fail2ban/filter.d/asterisk.conf
fail2ban-client -t && systemctl restart fail2ban && fail2ban-client status asterisk
```
Note: on Oliver specifically, real inbound SIP scanning already arrives at Asterisk masqueraded as
`10.0.0.1` (the WireGuard relay VPS's DNAT gateway — see the wg0/relay-VPS note above), which is why
`10.0.0.0/24` is in fail2ban's `ignoreip` (decided 2026-08-25, unrelated to and not fixed by either
change above) — this jail still can't ban those specific scanners until the VPS preserves real
source IPs through the tunnel. Checked live on 2026-09-06: no *other*, non-masqueraded scanning
currently hitting Oliver worth manually blocking (`grep "Failed to authenticate" /var/log/asterisk/full`,
most recent unrelated match was 4+ days stale). Check each server's own current logs before assuming
any specific IP is worth blocking — don't copy IPs reactive to one server onto another.

**Cockpit — confirmed already closed on Oliver's firewall (2026-09-06):** `firewall-cmd --zone=public
--query-service=cockpit` returns `no`. The systemd `cockpit.socket` is still `active`/`enabled`
(bound locally, not firewall-exposed) — normal safe-by-default state, not something to additionally
disable without a reason, since a local/SSH-tunneled admin-access use case would have a real
downside if the service itself were stopped. The July 2026 firewall-audit note above lists cockpit
as part of what was "globally open" back then — that was accurate as of that date; it isn't now,
and nothing since has needed further action. If a fresh install or another server shows it actually
`query-service=yes`, remove it the same low-risk way: `firewall-cmd --permanent --zone=public
--remove-service=cockpit && firewall-cmd --reload`.

**`rc-local.service` showing `inactive (dead)` is not a failure** — same class of misleading
status as `asterisk.service` above. It's a oneshot unit with no `RemainAfterExit=yes`, so it
correctly shows `inactive (dead)` once its `ExecStart` (which launches the `screen`-wrapped
Asterisk console) has already run successfully. Don't diagnose it via `systemctl status`; use the
same real liveness check as the Asterisk screen session: `ss -ulnp | grep 5060` and `screen -ls`.

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

---

## agc web files — known applied fixes

`/var/www/html/agc/` (served via Apache's `Alias /agc`) and `/usr/src/astguiclient/trunk/www/agc/`
(the SVN checkout install.pl deploys it from) are ViciDial's stock PHP frontend files — the actual
`.php` files live outside this repo's git tree (they're vendor/upstream code, not ours to version),
so fixes to them are easy to lose track of, or get silently reverted the moment `install.pl` re-runs
(manual re-run, or a ViciDial upgrade) and redeploys pristine copies from SVN into both locations.

**As of 2026-09-05, the 13 files below are auto-patched by the installer itself**, not just
hand-fixed on Oliver: their corrected contents live in this repo under `agc-security-patches/`,
`vicidial_rocky10_part2_install.sh` stages them to `/usr/local/share/vicidial-rocky10/agc-security-patches/`
during install, and the existing `vicidial-rocky10-repatch` script/`.path` unit (see the "Perl / AGI"
patches below) now also whole-file-replaces any of these 13 that are missing the
`ROCKY10-AGC-SECURITY-PATCH-v1` marker comment — in both `trunk/www/agc` and `/var/www/html/agc`
(now both in the `.path` unit's watch list), preserving any `[SKIN-LOADER]` branding header already
present on the destination. This means a *fresh* install on a new server gets all of these fixes
automatically, with no manual re-patching step — verified by testing the exact extracted heredoc
against a simulated unpatched + skin-loader-branded copy before this was committed.

- **`agc/sse.php` — unvalidated `refresh_interval` echoed into SSE stream (fixed 2026-09-03):**
  Stock ViciDial echoes `$_GET['refresh_interval']` straight into the `retry:` field of the
  Server-Sent-Events response with no validation (`$refresh_interval=(array_key_exists(...) ?
  $_GET['refresh_interval'] : "-1");`). Fixed in both the live file and
  `trunk/www/agc/sse.php` (so a re-run of `install.pl` won't silently reintroduce it) using
  `filter_input(INPUT_GET, 'refresh_interval', FILTER_VALIDATE_INT, ['min_range'=>100,
  'max_range'=>3600000, 'default'=>1000])` — rejects non-integer input and range-bounds it,
  rather than a bare `(int)` cast which would still let out-of-range/garbage-coerced-to-0
  values through.

- **Reflected XSS in 7 files — request values echoed raw into HTML with only a partial
  quote-strip filter (fixed 2026-09-03):** A full manual sweep of all 39 `agc/` files that touch
  `$_GET`/`$_POST`/`$_REQUEST` (triggered by the `sse.php` fix above) found the same root defect
  repeated across the codebase: some fields are sanitized with `preg_replace("/\'|\"|\\\\|;/","",...)`
  — which strips quotes/backslash/semicolon but **not** `<`/`>` — then get echoed raw into the page.
  Since PHP's default `Content-Type` is `text/html`, a bare `<script>` payload needs no
  quote-breakout at all. ViciDial's own code already has the correct idiom elsewhere
  (`vdc_form_display.php` and `vicidial.php` use `/\<|\>|\'|\"|\\\\|;| /`) — the fix everywhere
  below just brings the weaker filters up to that existing stronger one, applied to both the live
  file and its `trunk/www/agc/` counterpart:
  - `manager_send.php` — **confirmed live regardless of any setting**: `$ACTION` (and sibling
    `$exten`/`$extenName`/`$parkedby`/`$stage`/`$CalLCID`/`$call_server_ip`) reach an
    `if ($format=='debug')` HTML-comment echo with only a valid login + active session required —
    no admin toggle gates it.
  - `call_log_display.php`, `live_exten_check.php`, `park_calls_display.php` — `$exten` had **zero**
    sanitization at all before the same kind of debug-comment echo.
  - `conf_exten_check.php` — `$exten`/`$clicks`/`$visibility`/`$xferchannel` likewise unsanitized.
  - `vdc_script_dispo_example.php`, `vdc_script_notes.php` — a ~20-field lead-data dump
    (`$title`/`$first_name`/`$last_name`/`$address1-3`/`$comments`/etc.) with the same weak filter.
  - The `call_log_display.php`/`live_exten_check.php`/`park_calls_display.php`/`conf_exten_check.php`
    debug branches are gated behind `system_settings.allow_web_debug` (confirmed `0` on this server
    as of the fix date — latent, not live, unless that setting is ever turned on for troubleshooting).
  - `vdc_db_query.php` (19k+ lines, fixed 2026-09-03 in a follow-up pass) — the same weak filter
    was applied to **66 fields** throughout this file (`$closer_choice`, `$campaign`, `$extension`,
    `$user_abb`, `$favorites_list`, `$url_ids`, the full lead-data set (`$first_name`/`$last_name`/
    `$address1-3`/`$email`/`$comments`/etc.), `$inbound_email_groups[$i]`/`$inbound_chat_groups[$i]`,
    and more) — all brought up to the same stronger filter, in both the live file and trunk.
  - **Third pass (2026-09-03), grep'd the exact weak-filter fingerprint across every `agc/` file**
    (not just the 39 touching `$_GET`/`$_POST`) to close out the sweep:
    - `phone_only.php` — `$browser` (`getenv("HTTP_USER_AGENT")`) echoed raw into an HTML comment.
      **This is the most exploitable finding of the whole sweep** — reachable with a crafted
      `User-Agent` header alone, no login and no `allow_web_debug` needed, unlike everything else
      found in this sweep.
    - `api.php` — `$stage` echoed raw in two plain-text status lines (needs valid login).
    - `vdc_form_display.php` — `$DB`/`$source_field_value`/`$user_custom_one..five`, all named in
      the `$only_field_query` string that gets echoed into a JS variable assignment; a literal
      `<`/`>` there also matters because of the browser's `</script>`-anywhere-terminates-the-block
      HTML-parsing quirk, not just quote-breakout.
    - Confirmed safe and left alone: `vdc_script_display.php` (identical field list to the two
      script-display files above, but `urlencode()`d before use — different from its siblings),
      `vdc_email_display.php` (superseded by a stricter later whitelist), `functions.php` and the
      `dispo_add_FPG.php`/`dispo_move_list.php`/`dispo_send_email.php` trio (values only reach
      `mysql_error_logging()`, never the HTTP response), `alt_display.php` (hardcoded override).
    - **`chat_db_query.php` stored XSS in agent/manager chat — traced and fixed 2026-09-05:**
      `$chat_message`/`$manager_message` are only `mysqli_real_escape_string()`'d (SQL-safe, not
      HTML-safe) before being `INSERT`ed into `vicidial_manager_chat_log`/`vicidial_chat_log`, then
      read back and echoed raw into an HTML `<font>` tag.
      - **Live, no click/link/debug-toggle needed** — the manager-chat path (`DisplayMgrAgentChat`
        action, `chat_db_query.php:365`) is consumed by `agc_agent_manager_chat_interface.php:412`
        via `.innerHTML=` on an auto-refresh timer (`MgrAgentAutoRefresh()`). Any chat participant
        posting `<img src=x onerror=...>` (or similar) executes it in every other participant's
        session the moment their view refreshes — including managers/supervisors, making this a
        viable agent-to-manager privilege-escalation path. This is the most severe finding across
        the whole `agc/` review.
      - The sibling agent↔customer chat path (`vicidial_chat_log`, `$row[2]`/`$row[5]` echoed at
        `chat_db_query.php:1045`) has the identical bug, but `agc_agent_manager_chat_interface.php`
        is the *only* file anywhere in this web root that calls `chat_db_query.php` at all — none of
        that path's actions (`update_agent_chat_window`, `agent_send_message`, `join_chat`, etc.)
        have a caller, so it isn't reachable through the current UI. Fixed anyway for defense in
        depth.
      - **Fix is `htmlspecialchars($var, ENT_QUOTES)` at the display point, not input filtering** —
        unlike every other fix in this section, chat messages are free-form prose (need to support
        quotes, punctuation, unicode), so blacklisting input characters would break legitimate
        messages. Escaping at render time is the correct control here.
