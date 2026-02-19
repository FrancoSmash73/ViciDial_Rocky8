# ViciDial Post-Install FIX GUIDE — Part 3
**Server:** 172.236.243.149
**OS:** Rocky Linux 10.x
**Asterisk:** 18.21.0-vici
**Date:** 2026-02-19

---

## Overview

This guide documents issues encountered during live production operation after Part 1 and Part 2
installs were completed. These are runtime/operational issues rather than install-time issues.

---

## FIX 12 — Dual Asterisk Instance Fighting Over UDP 5060

### Symptom
- `__sip_reliable_xmit` network errors in Asterisk log
- SIP peers going `UNREACHABLE`
- Calls failing intermittently
- `ps aux | grep asterisk` shows two Asterisk processes

### Root Cause
`asterisk.service` (systemd) restarted alongside ViciDial's screen-managed Asterisk instance.
Both tried to bind UDP 5060, causing a port conflict. `systemctl disable` alone is not sufficient
— systemd can still start the service via dependency or manual trigger.

### Fix
```bash
systemctl stop asterisk
systemctl disable asterisk
systemctl mask asterisk    # Critical — hard-blocks it, even from dependency starts
```

> **Note:** `mask` symlinks the unit to `/dev/null`, preventing any start method from working.
> `disable` only prevents boot-time starts. Always use `mask` on ViciDial servers.

### Verify
```bash
ps aux | grep asterisk | grep -v grep   # Should show exactly ONE process (screen-managed)
ss -ulnp | grep 5060                    # Should show only one owner
systemctl is-active asterisk            # Should return: inactive
```

---

## FIX 13 — CDR Permission Denied on Agent CSV Files

### Symptom
- CDR not logging for specific agents
- `Permission denied` errors in `/var/log/asterisk/full` referencing `/var/log/asterisk/cdr-csv/`
- Files like `10001.csv` owned by `root:root` instead of `asterisk:asterisk`

### Root Cause
The systemd `asterisk.service` runs as `root`, while ViciDial's screen-managed Asterisk runs
as the `asterisk` user. When the dual-instance issue (FIX 12) occurs, CDR files get created
with `root` ownership, which the `asterisk` user cannot subsequently write to.

### Fix
```bash
chown -R asterisk:asterisk /var/log/asterisk/cdr-csv/
chmod -R 664 /var/log/asterisk/cdr-csv/
```

### Prevention
Applying FIX 12 (`systemctl mask asterisk`) prevents this from recurring since only the
`asterisk`-user screen-managed instance will ever run.

---

## FIX 14 — ViciDial Daemon Sessions Lost ("No one is in your session")

### Symptom
- Agents logging in receive: `No one is in your session: 9600000`
- Agents cannot get into the conference bridge
- System was otherwise running

### Root Cause
ViciDial daemon screen sessions (ASTemail, ASTsend, ASTlisten, etc.) had died and not
been restarted. This is commonly triggered by the dual-instance issue (FIX 12) or a
system restart without proper ViciDial startup sequence.

### Fix
```bash
/usr/share/astguiclient/ADMIN_keepalive_ALL.pl
```

### Verify
```bash
screen -ls   # Should show 13 screen sessions including: asterisk, ASTemail,
             # ASTsend, ASTlisten, ASTSIPlogger, ASTConfUpdater, ASTupdate, etc.
```

---

## FIX 15 — Remote Agent VICIphone Not Registering (WSS Port Blocked)

### Symptom
- Local agents register fine; remote agents get `UNKNOWN` on `sip show peer`
- Remote agent sees "No one is in your session" on login
- `sip show peer XXXXX` shows `Expire: -1`, `Addr->IP: (null)`
- Agent IS reaching the web portal (visible in Apache access logs) but VICIphone never connects

### Root Cause
Remote agent's ISP or network was blocking outbound connections to non-standard ports.
The agent could reach port 443 (HTTPS) but not port 8089 (Asterisk WSS/WebSocket).

Additionally, the remote agent's IP was not in the `dynamiclist` firewall ipset, which
controls access to Asterisk ports (5060, 8088, 8089, RTP range).

### Diagnosis
```bash
# Check if peer is registered
asterisk -rx "sip show peer XXXXX"

# Check which IPs are allowed in firewall
firewall-cmd --ipset=dynamiclist --get-entries

# Watch for connection attempts from agent IP
conntrack -L 2>/dev/null | grep "<AGENT_IP>"

# Verify agent's IP is reaching port 8089 specifically
ss -tnp | grep 8089
```

### Fix — Add Agent IP to Firewall
```bash
firewall-cmd --permanent --ipset=dynamiclist --add-entry=<AGENT_PUBLIC_IP>
firewall-cmd --reload
```

> **Note:** The `dynamiclist` ipset is managed by ViciDial's portal scripts and may be
> overwritten periodically. Verify the entry persists after a few minutes:
> ```bash
> firewall-cmd --ipset=dynamiclist --get-entries
> ```

### Fix — If Port 8089 Is Blocked by Agent's ISP
The agent can test port 8089 accessibility by visiting:
```
https://callbakz.ddns.net:8089/httpstatus
```
If this times out, their ISP/router/VPN is blocking outbound port 8089. Options:
1. Agent switches to a different network (mobile hotspot, different ISP)
2. Have agent disable VPN if one is active
3. Contact ISP to unblock port 8089

---

## FIX 16 — VICIPHONE_SETTINGS Container WEBSOCKETURL Conflict

### Symptom
- All agents (local and remote) suddenly unable to connect VICIphone
- Peers show `UNREACHABLE` or `UNKNOWN`
- Active WebSocket connections drop and cannot re-establish

### Root Cause
The `WEBSOCKETURL` setting exists in **two places** in ViciDial:
1. `servers` table → `web_socket_url` column (correct place)
2. `vicidial_settings_containers` → `VICIPHONE_SETTINGS` entry (causes conflict)

When `WEBSOCKETURL` appears in the `VICIPHONE_SETTINGS` container, ViciDial's
`viciphone.php` iterates through all `--` delimited options and overwrites the valid URL
with a garbage string from the `--SETTINGS` block, breaking WebSocket for all agents.

### Fix
```bash
mysql -u cron -p<PASSWORD> asterisk -e "
UPDATE vicidial_settings_containers
SET container_entry = TRIM(TRAILING '\nWEBSOCKETURL wss://YOUR_DOMAIN:8089/ws' FROM container_entry)
WHERE container_id='VICIPHONE_SETTINGS';"
```

### Verify No Conflict
```bash
mysql -u cron -p<PASSWORD> asterisk -e \
  "SELECT container_entry FROM vicidial_settings_containers WHERE container_id='VICIPHONE_SETTINGS';" \
  | grep -i websocket
# Should return nothing
```

The WebSocket URL lives exclusively here:
```bash
mysql -u cron -p<PASSWORD> asterisk -e \
  "SELECT server_ip, web_socket_url FROM servers;"
# Should show: wss://YOUR_DOMAIN:8089/ws
```

> **IMPORTANT:** Never add `WEBSOCKETURL` to the `VICIPHONE_SETTINGS` container.
> The `servers.web_socket_url` field is the only authoritative source for this value.

---

## FIX 17 — Auditing the dynamiclist Firewall Ipset

### Background
The `dynamiclist` ipset grants full access to Asterisk ports (SIP 5060, WSS 8089, RTP).
Unknown IPs in this list are a security risk. Audit it periodically.

### Audit Procedure
```bash
# List all IPs currently allowed
firewall-cmd --ipset=dynamiclist --get-entries

# Cross-reference with currently registered SIP peers
asterisk -rx "sip show peers" | grep -v UNKNOWN

# Any IP in dynamiclist not matching a known registered peer should be investigated
```

### Remove Unknown IP
```bash
firewall-cmd --permanent --ipset=dynamiclist --remove-entry=<UNKNOWN_IP>
firewall-cmd --reload
```

---

## Key Files Modified (Part 3)

| File/Location | Change |
|---|---|
| `systemctl mask asterisk` | Prevents dual-instance conflicts permanently |
| `/var/log/asterisk/cdr-csv/` | Ownership corrected to `asterisk:asterisk` |
| `servers.web_socket_url` (DB) | Must be set to `wss://YOUR_DOMAIN:8089/ws` |
| `VICIPHONE_SETTINGS` container (DB) | Must NOT contain `WEBSOCKETURL` |
| `dynamiclist` ipset | Remote agent IPs added; unknown IPs removed |

---

## Root Causes Summary

| Fix | Root Cause Category |
|---|---|
| FIX 12 — Dual Asterisk instance | `systemctl disable` insufficient; need `mask` |
| FIX 13 — CDR permissions | Side effect of dual-instance root-owned files |
| FIX 14 — Daemon sessions lost | Dual-instance crash kills ViciDial screen sessions |
| FIX 15 — Remote agent WSS blocked | ISP blocking port 8089; agent IP not in dynamiclist |
| FIX 16 — WEBSOCKETURL conflict | Duplicate setting in VICIPHONE_SETTINGS container |
| FIX 17 — Unknown IP in dynamiclist | Stale/unknown IP accumulation in firewall ipset |

---

*Part 3 completed 2026-02-19. System verified stable with both local and remote agents
registered and dialing.*
