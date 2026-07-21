# PJSIP Webphone Registration Troubleshooting

Field-tested runbook for ViciDial on Rocky Linux 10 with PJSIP webphones.
Every finding below was verified on a live server; the traps are the ones that
cost real hours because they fail *silently*.

Server names, IPs and credentials have been redacted for publication.

Covers two ViciDial servers with confirmed static (non-realtime) PJSIP configs:
- **Server A** (Rocky Linux 10, Apache, custom dark theme skin project)
- **Server B** (<your-domain>)

Both servers share the same root cause pattern: **ViciDial's admin UI does not automatically regenerate PJSIP conf files when a phone is added or edited.** Every new phone requires manual conf file edits. Use this doc to triage quickly instead of re-diagnosing from scratch.

> 🔒 **No secrets in this file.** `<DB_PASS>` is a placeholder — read the real value from
> `/etc/astguiclient.conf` (`VARDB_pass`) at the time you run a command. Do not paste passwords,
> `conf_secret` values, or TLS keys back into this doc; it is intended to be shareable.

---

## Quick Diagnostic Checklist

Run in order — stop at the first failure, it's usually your root cause.

### 1. Does the endpoint exist at all?
```bash
asterisk -rx "pjsip show endpoint <EXTENSION>"
```
- `Unable to find object <EXTENSION>` → endpoint was never added to the static conf file. Go to **Section A**.
- Endpoint shows but state is `Unavailable` → endpoint exists, hasn't registered yet. Continue to step 2.
- Endpoint shows `Not in use` or `In use` → already registered, problem is elsewhere (session/dialplan). Go to **Section D**.

### 2. Is PJSIP realtime or static on this server?
```bash
grep -A5 "\[res_pjsip\]" /etc/asterisk/sorcery.conf
```
Both Server A and Server B have this **commented out** (`;endpoint=realtime,...`). This means:
- No database-driven endpoint creation — everything must be in flat conf files
- ViciDial's `phones` table is just data storage; nothing auto-syncs it to PJSIP conf

### 3. Which conf file holds phone endpoints on this server?
```bash
grep -n "^#include\|^#tryinclude" /etc/asterisk/pjsip.conf
```
| Server | Conf file for webphones | Style |
|---|---|---|
| Server A | `pjsip-<agents>.conf` | Fully spelled-out blocks (no template) |
| Server B | `pjsip-webrtc-agents.conf` | Template inheritance via `[webrtc_template](!)` defined in `pjsip.conf` |

**Do not mix styles between servers** — copying one server's block format onto the other will still load, but won't match the established pattern and makes future maintenance harder.

### 4. Check the actual REGISTER attempt in the logs
| Server | Log file |
|---|---|
| Server A | `/var/log/asterisk/full` |
| Server B | `/var/log/asterisk/messages` |

```bash
tail -f <log file> | grep -i <EXTENSION>
```
Common messages and what they mean:
- `No matching endpoint found` → endpoint doesn't exist in static conf (Section A)
- `Failed to authenticate` (after endpoint IS found) → password mismatch (Section B)
- No log entries at all when webphone tries → WebSocket/transport/tunnel issue (Section C)
- Log is gigabytes and drowning in `chan_sip.c: Registration from ... Wrong password` → SIP
  brute-force flood, and fail2ban is almost certainly not banning (Section E)

---

## Section A — Missing Endpoint (most common issue)

**Symptom:** `Unable to find object <EXT>` and/or `No matching endpoint found` in logs.

**Root cause:** Phone was created in ViciDial Admin → Phones (exists in the `phones` table) but no corresponding PJSIP block was ever written to the conf file.

**Fix:**
1. Confirm the phone record exists and pull its registration password:
   ```bash
   mysql -u cron -p'<DB_PASS>' -D asterisk -e \
     "SELECT extension, protocol, active, is_webphone, conf_secret FROM phones WHERE extension='<EXT>';"
   ```
   ⚠️ **Use `conf_secret`, NOT `pass`.** `conf_secret` is the SIP registration password; `pass` is the
   agent's login password. Putting `pass` in a conf file will break authentication. See Section B.

2. Find a working sibling endpoint to use as a template:
   ```bash
   grep -n "^\[<WORKING_EXT>\]" -A 20 <conf file>
   ```

3. Append a matching block for the missing extension (adjust to whichever style the server uses — see table above).

4. Reload and verify:
   ```bash
   asterisk -rx "pjsip reload"
   asterisk -rx "pjsip show endpoint <EXT>"
   ```
   Should show `Unavailable` (not "Unable to find object") — this is expected until the phone actually registers.

**Bulk check — find ALL missing endpoints on a server:**
```bash
# Every PJSIP phone that SHOULD exist:
mysql -u cron -p'<DB_PASS>' -D asterisk -e \
  "SELECT extension, protocol, active, is_webphone, conf_secret FROM phones WHERE protocol='PJSIP' AND active='Y';"

# Every extension already defined in conf:
grep -oP "^\[\K[0-9]+(?=\]$)" <conf file> | sort -u
```
Diff the two lists — anything in the DB list but missing from the conf list needs a block added.

---

## Section B — Failed to Authenticate (endpoint exists, wrong password)

**Symptom:** `pjsip show endpoint` finds the object, but logs show `Failed to authenticate` on REGISTER.

**Root cause — check this FIRST:**
ViciDial's Admin → Phones screen has **two separate password fields**, and they map to two
different DB columns. Confirmed by reading the field definitions in ViciDial's own `admin.php`
(`name=conf_secret` and `name=pass` respectively), so this holds on any ViciDial install:

| Admin → Phones field | DB column | Used for |
|---|---|---|
| **Registration Password** | `phones.conf_secret` | the SIP/PJSIP secret — **this is what goes in the conf `auth` block** |
| **Login Password** | `phones.pass` | the human agent logging into the ViciDial agent web screen |

Using `pass` in the PJSIP `auth` block will always fail authentication.

You do **not** need the UI to read it — `conf_secret` is queryable directly:
```bash
mysql -u cron -p'<DB_PASS>' -D asterisk -e \
  "SELECT extension, conf_secret FROM phones WHERE extension='<EXT>';"
```

> Why this bites: on many phones `pass` and `conf_secret` happen to hold the *same* value, so a
> wrong copy silently works. The trap only springs where they differ. On one live server, a single extension was
> exactly that case — its `pass` is a human-chosen login password while its `conf_secret` is a
> generated SIP secret — so copying `pass` there breaks a working webphone. Verify per-extension:
> ```bash
> mysql -u cron -p'<DB_PASS>' -D asterisk -e \
>   "SELECT extension, (pass = conf_secret) AS same FROM phones WHERE protocol='PJSIP' AND active='Y';"
> ```
> Any row with `same = 0` is one where using `pass` will silently fail authentication.

Confirmed on **both sides** of the REGISTER, so the two must agree on `conf_secret`:
- **Server side:** the conf `auth<EXT>` block is what Asterisk checks against.
- **Client side:** the agent screen hands the webphone `conf_secret`, not `pass` —
  `agc/vicidial.php:5264` → `$b64_phone_pass = base64_encode($conf_secret);`

**Fix:**
1. Pull `conf_secret` for the extension (query above), or read "Registration Password" in the UI.
2. Update the conf file's auth block:
   ```bash
   grep -n "^\[<EXT>-auth\]\|^\[auth<EXT>\]" -A 5 <conf file>
   # then edit the password= line to match the registration password
   ```
3. Reload: `asterisk -rx "pjsip reload"`
4. Refresh the webphone browser tab and retry.

**Other things to check if password is confirmed correct:**
- Missing `realm=` line in the auth block — add `realm=<your domain>` to match other working endpoints on the same server
- `endpoint_identifier_order` in `pjsip.conf` general section should include `username` (both servers confirmed to have this correctly set)

---

## Section C — No Log Entry at All / WebSocket Never Connects

**Symptom:** Webphone shows "NOT REGISTERED", timer stuck at `00:00`, and nothing shows in Asterisk logs when it tries.

**Check:**
1. Cloudflare Tunnel / reverse proxy health (Server A specifically runs behind Cloudflare Tunnel + WireGuard, CGNAT):
   ```bash
   systemctl status cloudflared
   ```
   Known issue: Error 1033 silent-drop — fixed previously via `systemctl restart cloudflared` with `Restart=on-failure` hardening in the unit file.
2. Confirm the WSS transport is bound and listening:
   ```bash
   asterisk -rx "http show status"     # <-- this is the one that matters for WSS
   asterisk -rx "pjsip show transports"
   ```
   ⚠️ **`pjsip show transports` does NOT tell you the WSS port.** WebSocket transport is served by
   Asterisk's built-in HTTP server, not by the PJSIP transport's bind address. If `[transport-wss]`
   in `pjsip.conf` has `bind = 0.0.0.0` with no port, `pjsip show transports` just prints the
   default `:5060` — it is cosmetic and means nothing.

   The real WSS listener is `tlsbindaddr` in `/etc/asterisk/http.conf` (conventionally `:8089`),
   and the URL the webphone actually dials is `servers.web_socket_url` in the DB:
   ```bash
   grep -E "tlsenable|tlsbindaddr" /etc/asterisk/http.conf
   mysql -u cron -p'<DB_PASS>' -D asterisk -e "SELECT server_ip, web_socket_url FROM servers;"
   ```
   These two must agree, and `http show status` must show `/ws` under "Enabled URI's".
3. Browser console / DevTools Network tab on the webphone page — look for WebSocket connection errors (Server A note: CLI curl is unreliable for this vhost, always use browser DevTools instead).

---

## Section D — Endpoint Registers Fine, But Agent Screen Shows Session/Bridge Errors

**Symptom:** e.g. "No one is in your session: <bridge number>" even though the phone is registered and answering calls.

**Root cause — CONFIRMED on Server B:**
`vicidial_live_agents.extension` gets written at **login time** based on the phone's `protocol` column. If `phones.protocol` is still set to `SIP` (even though a working PJSIP conf block exists), ViciDial will track the session as `SIP/<EXT>` instead of `PJSIP/<EXT>` — causing a mismatch between the bridge the phone actually joined and the bridge ViciDial's UI expects.

**Fix:**
1. Confirm the mismatch:
   ```bash
   mysql -u cron -p'<DB_PASS>' -D asterisk -e \
     "SELECT user, extension, conf_exten, status FROM vicidial_live_agents;"
   ```
   If `extension` shows `SIP/<EXT>` instead of `PJSIP/<EXT>`, that's the bug.

2. If `PJSIP` isn't selectable in the Admin → Phones protocol dropdown at all, check the system setting that gates it:
   ```bash
   mysql -u cron -p'<DB_PASS>' -D asterisk -e "DESCRIBE system_settings;"
   # find the sip-stack related field, then:
   # value should be 'SIP_and_PJSIP' not just 'SIP'
   ```
   This is controlled by **`allowed_sip_stacks`** — confirmed on Server B it was locked to `SIP` only, hiding PJSIP from the dropdown entirely regardless of what the `phones` table enum allows. Change to `SIP_and_PJSIP` via Admin → System Settings.

3. Set the phone's protocol to PJSIP (via UI dropdown once unlocked, or directly):
   ```bash
   mysql -u cron -p'<DB_PASS>' -D asterisk -e "UPDATE phones SET protocol='PJSIP' WHERE extension='<EXT>';"
   ```

4. **Fully log the agent out and back in** — this field only refreshes at login time, an existing session won't self-correct.

5. Re-verify:
   ```bash
   mysql -u cron -p'<DB_PASS>' -D asterisk -e \
     "SELECT user, extension, conf_exten, status FROM vicidial_live_agents;"
   ```
   Should now show `PJSIP/<EXT>`.

---

## Section E — Asterisk Log Growing Huge / fail2ban Bans Nothing

**Symptom:** `/var/log/asterisk/messages` (or `full`) is gigabytes, `df` climbs, and grepping it for a
real problem is unusable. `fail2ban-client status asterisk` reports `Total banned: 0` even though the
log is full of failed registrations.

**Root cause — CONFIRMED on Server B 2026-07-09:**
The log is almost never "debug left on." It is a **chan_sip REGISTER brute-force flood** — ordinary
`NOTICE`-level lines that Asterisk emits at default log settings:
```
NOTICE[...] chan_sip.c: Registration from '"8" <sip:8@<your-ip>>' failed for '<attacker-ip>:5060' - Wrong password
```
On Server B this ran Jul 5 → Jul 9 unchecked and produced a **6.9 GB** log (~1.8 GB/day), ~99% of lines,
from four IPs spraying guessed extensions.

### ⚠️ The trap: `backend` silently overrides `logpath`

fail2ban's `asterisk` jail was `enabled = true` with a **correct** `logpath`, a **working** filter, and
still banned nobody for four days. Cause: the distro drop-in
`/etc/fail2ban/jail.d/00-systemd.conf` sets `backend=systemd` in `[DEFAULT]`, which applies to every
jail. **When the backend is systemd, fail2ban reads journald and ignores `logpath` entirely.**
Asterisk logs to its own file, not journald, so the jail tailed an empty stream.

This fails *silently* — no error, no warning, jail reports healthy.

**Diagnose (the one command that reveals it):**
```bash
fail2ban-client status asterisk
```
- Shows `Journal matches: _SYSTEMD_UNIT=asterisk.service` → **broken**, it is reading journald.
- Shows `File list: /var/log/asterisk/messages` → correct, it is reading the file.

Corroborate:
```bash
journalctl -u asterisk --since "-1d" | grep -c "Registration from"   # 0 = asterisk isn't in the journal
fail2ban-regex /var/log/asterisk/messages /etc/fail2ban/filter.d/asterisk.conf | grep -E "^Lines:"
```
If `fail2ban-regex` matches lines but the jail's `Total failed` is 0, the filter is fine and the
backend is the problem.

**Fix** — set `backend` *per jail* (jail-level beats the `[DEFAULT]` drop-in). In
`/etc/fail2ban/jail.d/zz-vicidial.local`:

> ⚠️ **The file extension decides who wins.** fail2ban reads, in order
> (`fail2ban/client/configreader.py`):
> `jail.conf` → `sorted(jail.d/*.conf)` → `jail.local` → `sorted(jail.d/*.local)`
>
> So **every `.local` overrides every `.conf`**, and among `.local` files the alphabetically last one
> wins. A `jail.d/vicidial.conf` is silently overridden by any `asterisk.local` a distro, package or
> admin drops in — your settings are present, parsed, and ignored. Use a `.local` that sorts last.
> Confirm what actually took effect — never by reading the file you wrote:
> ```bash
> fail2ban-client get asterisk actions   # e.g. "nftables-multiport-tcp, nftables-multiport-udp"
> nft list tables                        # expect: table inet f2b-table
> ```
```ini
[DEFAULT]
# See "second trap" below — required on any firewalld host.
banaction          = nftables-multiport
banaction_allports = nftables-allports

[asterisk]
enabled  = true
backend  = polling      # <-- overrides backend=systemd from 00-systemd.conf
maxretry = 5
bantime  = 86400
findtime = 600
logpath  = /var/log/asterisk/messages
```

### ⚠️ Second trap: `firewall-cmd --reload` silently wipes fail2ban's bans

Distro default is `banaction = iptables-multiport` (and `iptables-allports`). On a **firewalld** host
with `FirewallBackend=nftables`, those rules live in a table firewalld flushes whenever it reloads.
Running `firewall-cmd --reload` — or `--permanent` anything followed by a reload — deletes every ban,
while `fail2ban-client status` **keeps reporting the IPs as banned**. Detection keeps working;
enforcement is silently gone. Hit on Server B 2026-07-09.

```bash
fail2ban-client status asterisk | grep "Currently banned"   # says 4
nft list ruleset | grep -c "<banned-ip>"                    # says 0   <-- the tell
```
Fix by using fail2ban's own nft table (`inet f2b-table`), which firewalld does not manage — set the
`[DEFAULT]` banaction shown above, `systemctl restart fail2ban` (it re-applies bans from
`fail2ban.sqlite3`), then **prove it**:
```bash
nft list tables                    # expect: table inet f2b-table
firewall-cmd --reload
nft list ruleset | grep -c "<banned-ip>"   # must still be > 0
```
Do not trust `Currently banned` alone. `nft list ruleset` is the only source of truth for enforcement.
Then:
```bash
fail2ban-client -t                       # validate config BEFORE restarting
systemctl restart fail2ban
fail2ban-client status asterisk          # must now show "File list:", not "Journal matches:"
```

**Check every file-based jail, not just asterisk.** Any jail whose service logs to a file rather than
journald is equally blind. On Server B `apache-auth` had the same defect and needed the same line.
`sshd` genuinely does log to journald, so it must be **left on the systemd backend** — do not blanket-
change every jail.

### Verifying the fix for real

`File list:` only proves the jail is *reading* the right file. A jail can parse failures correctly and
still fail to ban if the firewall action is broken. Drive the whole path with a synthetic failure from
a reserved documentation IP (`198.51.100.7`, TEST-NET-3 — never a real host):
```bash
TS=$(date '+%b %e %H:%M:%S')
LINE="[$TS] NOTICE[9999] chan_sip.c: Registration from '\"100\" <sip:100@<server-ip>>' failed for '198.51.100.7:5060' - Wrong password"
for i in $(seq 5); do echo "$LINE" >> /var/log/asterisk/messages; sleep 1; done
sleep 5

fail2ban-client status asterisk | grep -E "Currently banned|Banned IP"
nft list ruleset | grep -c 198.51.100.7      # MUST be > 0 — this is the step that proves enforcement
fail2ban-client set asterisk unbanip 198.51.100.7
```
One injected line should raise `Currently failed: 1`; five should trigger a ban **and** insert nftables
rules. If the jail says "banned" but `nft list ruleset` shows 0 rules, the action is broken, not the filter.

### Cleanup notes
- Confirm nothing holds the rotated log open before deleting, or the space is not reclaimed:
  ```bash
  lsof /var/log/asterisk/messages.<rotated-suffix>   # expect no output
  rm -f /var/log/asterisk/messages.<rotated-suffix>
  df -h /                                            # verify space actually returned
  ```
- **Never** `sed -i` the *live* log — Asterisk holds an open file descriptor on it; rewriting it in
  place risks corrupting the file or losing writes. Let test lines rotate out.
- Banning known attackers is not retroactive; fail2ban only acts on lines arriving after it starts
  watching. Pre-ban them if desired: `fail2ban-client set asterisk banip <IP>`.
- `bantime = 86400` means bans **expire after 24h**. Use `bantime -1` for a permanent ban. Bans survive
  restart/reboot via `dbfile = /var/lib/fail2ban/fail2ban.sqlite3`.
- The real exposure remains: chan_sip listens on `0.0.0.0:5060`. Scanners keep arriving; fail2ban just
  stops them at attempt 5. If chan_sip is unused, unloading it removes the attack surface entirely.

---

## Prevention / Future Phone Setup

Since neither server auto-generates PJSIP conf from the `phones` table, **every new phone needs this manual process**:

1. Create phone in Admin → Phones (protocol PJSIP, active Y, is_webphone Y)
2. Read the registration password from `phones.conf_secret` (**not** `phones.pass` — see Section B)
3. Add a matching endpoint/auth/aor block to the server's PJSIP conf file, cloned from a working sibling
4. `asterisk -rx "pjsip reload"`
5. Verify with `pjsip show endpoint <EXT>`
6. Have agent log out/in fresh once to refresh `vicidial_live_agents.extension`

Consider building a small script that reads new/changed rows in `phones` and auto-generates the missing blocks, to avoid repeating this by hand each time.
