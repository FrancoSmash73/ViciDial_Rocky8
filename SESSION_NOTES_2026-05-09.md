# ViciDial Rocky Linux 10 — Session Notes
**Date:** 2026-05-09  
**Server:** `45.77.77.127` / `callbakz.ddns.net` (standalone, not cluster)

---

## What We Accomplished

### 1. Fixed WebRTC — HulkPhone Now Registers

**Problem:** `res_pjsip_transport_websocket.so` showed "Not Running" on every Asterisk restart.  
Agents saw **NOT REGISTERED** in HulkPhone no matter what.

**Root cause:** ViciDial's `install.pl` sets `websocket_enabled=true` in `sip.conf` by default.  
`chan_sip.so` loads first and registers the `"sip"` WebSocket sub-protocol.  
When `res_pjsip_transport_websocket.so` tries to register the same name, it fails with  
`AST_MODULE_LOAD_DECLINE` and never loads.

**Fix — one line in `/etc/asterisk/sip.conf`:**
```
websocket_enabled=false   ; the comment in the file literally says to do this
```

**Verify:**
```bash
asterisk -rx "module show like res_pjsip_transport_websocket"
# Must show: Running
```

---

### 2. Fixed 11 Screen Sessions (Clean, Non-Repetitive)

**Problem:** 7 screens — 3 duplicate `ASTemail`, 2 stale timestamp shells, missing 6 processes.  
`ASTsend` and `ASTVDremote` were crash-looping on startup and never appeared.

**Root cause:** `procps-ng 4.0.4` (Rocky Linux 10) truncates `ps -o "%p %a"` output to ~30 chars.  
Four ViciDial scripts use this format to detect running sibling processes. Truncation means  
the full Perl path never matches, so processes think their siblings are dead and exit.

**Affected scripts (all patched):**
- `ADMIN_keepalive_ALL.pl`
- `AST_manager_send.pl`
- `AST_VDremote_agents.pl`
- `AST_VDauto_dial.pl`

**Fix:** Swapped `ps -o "%p %a" --no-headers -A` → `ps -f --no-headers -A` in all four.

**Also fixed:** Added flag `7` to `VARactive_keepalives` in `/etc/astguiclient.conf`  
(enables `ASTVDadFILL` screen — was running as orphan, not managed by keepalive).

**Final 11 screens:**

| Screen | Process |
|--------|---------|
| `asterisk` | Asterisk PBX |
| `ASTupdate` | AMI server state updater |
| `ASTlisten` | AMI event listener |
| `ASTsend` | AMI command sender |
| `ASTVDauto` | Auto-dialer |
| `ASTVDadFILL` | Hopper fill (leads → dial queue) |
| `ASTVDremote` | Remote agents handler |
| `ASTVDadapt` | Adaptive dial rate controller |
| `ASTfastlog` | FastAGI log processor |
| `ASTConfUpdater` | ConfBridge room updater |
| `ASTemail` | Inbound email handler |

---

### 3. Bulk Created 10 Agents + 10 WebRTC Phones

Extensions **8301–8310**, paired with ViciDial users **agent01–agent10**.  
All phones configured as `is_webphone=Y`, `VICIDIAL_web_URL` pointing to HulkPhone.

| User | Password | Extension | SIP Password |
|------|----------|-----------|--------------|
| agent01 | `6278d39ac3b8e6da` | 8301 | `6278d39ac3b8e6da` |
| agent02 | `4317f5b42b106d25` | 8302 | `4317f5b42b106d25` |
| agent03 | `b1185fa206764f2f` | 8303 | `b1185fa206764f2f` |
| agent04 | `bf181108f38cf9e2` | 8304 | `bf181108f38cf9e2` |
| agent05 | `be5a2851a72e9069` | 8305 | `be5a2851a72e9069` |
| agent06 | `bb284d91f379ccb7` | 8306 | `bb284d91f379ccb7` |
| agent07 | `1f257f48815a6ad9` | 8307 | `1f257f48815a6ad9` |
| agent08 | `270dce040d97413f` | 8308 | `270dce040d97413f` |
| agent09 | `fcd1a81a7577239a` | 8309 | `fcd1a81a7577239a` |
| agent10 | `674aa0a379c4d4db` | 8310 | `674aa0a379c4d4db` |

PJSIP config: `/etc/asterisk/pjsip-webrtc-agents.conf`  
Test any agent: `https://callbakz.ddns.net/hulkphone/hulkphone.php?ext=8301&pass=6278d39ac3b8e6da&server_ip=callbakz.ddns.net`

---

### 4. Pushed All Fixes to GitHub

**Repo:** `FrancoSmash73/vicidial-rocky10` (private)  
**Commit:** `d34749c` — *"fix: eliminate all manual post-install workarounds for Rocky Linux 10"*

Changes pushed so the **next clean install needs zero manual intervention:**

| Script | What Changed |
|--------|-------------|
| **Part 1** | `date.timezone = UTC` (was `America/New_York`) |
| **Part 2** | `websocket_enabled=false` applied post-`install.pl`; VARactive_keepalives gets both `C` and `7` flags |
| **Part 3** | ps truncation fix now covers all 4 affected scripts (was only 3) |
| **Part 4** *(new)* | Full WebRTC setup: Asterisk http.conf WSS, pjsip transport-wss, certbot, Let's Encrypt renewal hook, Apache ssl.conf, HulkPhone deploy, firewall 8088/8089 |
| **configs/hulkphone/** | `hulkphone.v2.js` + `hulkphone.css` committed — Part 4 auto-deploys them |
| **CLAUDE.md** | Documented both Rocky Linux 10 bugs + Part 4 in script index |

---

## What's Left (Next Session)

- [ ] **Inbound DID routing** — DID4Sale carrier is up (2/3 peers registering), `trunkinbound` context wired to `agi-DID_route.agi`. Need to assign actual phone numbers and route to inbound group or campaign.
- [ ] Set `did4sale_inb3` peer to resolve (currently `UNREACHABLE`)

---

## Current System State

```
Server:    45.77.77.127  /  callbakz.ddns.net
Asterisk:  18.21.0-vici  (running in screen)
SSL Cert:  Let's Encrypt  /etc/letsencrypt/live/callbakz.ddns.net/
HulkPhone: https://callbakz.ddns.net/hulkphone/hulkphone.php

Outbound carrier:  tbi-out  →  88.151.128.22  (OK, 92ms)
Inbound carriers:  did4sale_inb1/inb2 (OK), inb3 (UNREACHABLE)
WebRTC transport:  res_pjsip_transport_websocket.so  →  Running
Active screens:    11 (all clean, no duplicates)
Agents:            agent01–agent10 (ext 8301–8310) + admin test ext 8300
```
