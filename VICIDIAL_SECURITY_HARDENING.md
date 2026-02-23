# ViciDial Asterisk Server — Security Hardening Guide
# Server: 172.235.34.224 | Created: 2026-02-22

---

## Overview

This document captures the hardened security configuration applied to this
ViciDial Asterisk server. Apply these steps on all future installs BEFORE
going live.

---

## 1. Firewall — firewalld Only (No nftables Service Conflict)

**Critical Rule:** Use firewalld as the SOLE firewall manager.
The nftables service conflicts with firewalld and can create hidden DROP rules
that override your whitelist.

### Disable the nftables service
```bash
systemctl stop nftables
systemctl disable nftables
# Flush any manually-loaded nftables tables
nft flush table inet filter 2>/dev/null
nft delete table inet filter 2>/dev/null
firewall-cmd --complete-reload
```

### Verify only firewalld is managing nftables
```bash
nft list ruleset | grep "saddr !="   # Must return nothing
```

---

## 2. Port 5060 (SIP) — Whitelist-Only Access

**Never** use blanket `port 5060 drop` rules. The public zone default-deny
already blocks unmatched traffic. Only use source-specific ACCEPT rules.

### Install custom service definitions
```bash
# /etc/firewalld/services/asterisk.xml  — ports 5060,5061,4569,8088,8089
# /etc/firewalld/services/rtp.xml       — UDP 9000-35000
# /etc/firewalld/services/viciportal-ssl.xml — TCP 446
```

### Add carrier IPs (one per carrier IP/subnet)
```bash
# Specific IP
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="X.X.X.X" port port="5060" protocol="udp" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="X.X.X.X" port port="5060" protocol="tcp" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="X.X.X.X" service name="rtp" accept'

# Entire /24 subnet (preferred when carrier uses multiple gateways)
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="X.X.X.0/24" port port="5060" protocol="udp" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="X.X.X.0/24" port port="5060" protocol="tcp" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="X.X.X.0/24" service name="rtp" accept'

firewall-cmd --reload
```

### This server's carrier whitelist (66.209.76.0/24 = DID4Sale, 88.151.128.22 = TBI-OUT)
```
66.209.76.0/24  — DID4Sale (all gateways: .70, .72, .101, .102, etc.)
88.151.128.22   — TBI-OUT outbound carrier
```

### Verify SIP rules (must show ONLY source-specific accepts — no "!= X.X.X.X" drops)
```bash
nft list ruleset | grep 5060
```

---

## 3. Dynamic Agent Whitelist — vicidial-dynportal

Agents self-whitelist their IPs via a portal. VB-firewall syncs the DB list
to the firewalld `dynamiclist` ipset every minute.

### Install
```bash
cd /tmp/vicidial-dynportal
bash install.sh --domain <your.domain.com> --carrier-ip <primary_carrier_ip>
```

### Add additional carrier IPs post-install
```bash
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="X.X.X.X" service name="asterisk" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="X.X.X.X" service name="rtp" accept'
firewall-cmd --reload
```

### Verify ipset and cron
```bash
firewall-cmd --ipset=dynamiclist --get-entries
crontab -l | grep VB-firewall
```

---

## 4. fail2ban — nftables-Compatible Configuration

**Critical:** Use `nftables-allports` action, NOT `iptables-allports`.
On Rocky Linux 10 / RHEL 10, iptables-based actions may not integrate
correctly with the nftables backend.

### /etc/fail2ban/jail.local
```ini
[DEFAULT]
bantime  = 86400        ; 24 hours
findtime = 30           ; 30-second window
maxretry = 3            ; 3 failures = ban
banaction = nftables-allports
ignoreip = 127.0.0.0/8 ::1 <asterisk_server_ip> <db_server_ip> <carrier_subnet/24> <outbound_carrier_ip>

[asterisk]
enabled  = true
filter   = asterisk
action   = nftables-allports[name=asterisk]
           nftables-allports[name=asterisk-udp, protocol=udp]
logpath  = /var/log/asterisk/messages
maxretry = 3
findtime = 30
bantime  = 86400
backend  = auto

[sshd]
enabled  = true
port     = <custom_ssh_port>
filter   = sshd
logpath  = /var/log/secure
maxretry = 3
findtime = 30
bantime  = 86400
backend  = auto
```

### This server's ignoreip
```
127.0.0.0/8       — Loopback
::1               — IPv6 loopback
172.235.34.224    — This Asterisk server
172.239.67.94     — DB/Web server
66.209.76.0/24    — DID4Sale carrier subnet (never ban)
88.151.128.22     — TBI-OUT carrier
```

### Apply and verify
```bash
systemctl restart fail2ban
fail2ban-client get asterisk ignoreip
fail2ban-client get asterisk banip
```

---

## 5. Asterisk SIP — allowguest=no

Ensure `/etc/asterisk/sip.conf` has:
```ini
allowguest=no
```

Every inbound SIP carrier must have a corresponding `[peer]` entry in
`sip-vicidial.conf` (managed via ViciDial Admin > Carriers).

### For providers with multiple gateway IPs in same subnet
Add one carrier entry per known gateway IP in ViciDial DB:
```sql
INSERT INTO vicidial_server_carriers (carrier_id, carrier_name, template_id,
  account_entry, protocol, server_ip, active)
VALUES ('CARRIER_NAME', 'carrier_name', 'CUSTOM',
  '[carrier_name]\nhost=X.X.X.X\ntype=peer\ncontext=trunkinbound\n
  disallow=all\nallow=ulaw\nallow=alaw\ninsecure=port,invite\n
  dtmfmode=rfc2833\nnat=force_rport,comedia\ndirectmedia=no\n
  qualify=yes\nport=5060',
  'SIP', '<asterisk_server_ip>', 'Y', 'Carrier description', '---ALL---');

UPDATE servers SET rebuild_conf_files='Y' WHERE server_ip='<asterisk_server_ip>';
```
Then run: `perl /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --force`

---

## 6. Known Attack IPs — Permanent Firewalld DROP

Permanently block known scanners and brute-forcers:
```bash
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="X.X.X.X" drop'
firewall-cmd --reload
```

### Currently blocked on this server
```
207.180.248.233   — SIP brute force (also in fail2ban)
51.38.144.6       — SIP scanner (also in fail2ban)
51.77.105.125     — SIP scanner (also in fail2ban)
15.204.40.18      — Known scanner
117.103.80.0/24   — Known scanner subnet
117.103.80.90     — Known scanner
```

---

## 7. SSH Hardening

- Custom SSH port: **1951** (not 22)
- Remove default SSH service from public zone (it opens port 22):
```bash
firewall-cmd --permanent --remove-service=ssh
firewall-cmd --reload
firewall-cmd --list-services   # Must NOT include "ssh"
```
- fail2ban sshd jail active on port 1951
- Key-based auth preferred; password auth only with strong passwords

---

## 8. Perl Module Path — Asterisk::AGI (Rocky Linux 10 / RHEL 10)

**Critical — Do this on every new install or AGI scripts will silently fail.**

ViciDial installs its Perl modules to `/usr/share/astguiclient/libs/` but does
NOT add that path to the system Perl `@INC`. Asterisk spawns AGI scripts without
`PERL5LIB` set, so `use Asterisk::AGI` fails at compile time. The script exits
immediately with no error visible in Asterisk logs — the call just falls through
to `Hangup()`. Every single AGI call will fail: DID routing, IVR logic, everything.

### Symptom
```
-- AGI Script agi-DID_route.agi completed, returning 0
-- Executing [16088091363@trunkinbound:2] Hangup(...)
```
No `SET CONTEXT`, no `SET EXTENSION` ever sent. `vicidial_did_log` stays empty.

### Fix — install modules into system Perl path
```bash
# Find your Perl version
perl -e "print $]"    # e.g. 5.040 = 5.40

# Copy all astguiclient Perl modules to the system path
mkdir -p /usr/local/share/perl5/5.40/Asterisk
cp /usr/share/astguiclient/libs/Asterisk/*.pm /usr/local/share/perl5/5.40/Asterisk/
cp /usr/share/astguiclient/libs/Asterisk.pm   /usr/local/share/perl5/5.40/
cp /usr/share/astguiclient/libs/viciagi.pm    /usr/local/share/perl5/5.40/
cp /usr/share/astguiclient/libs/vicidial.pm   /usr/local/share/perl5/5.40/
```

### Verify
```bash
perl -e "use Asterisk::AGI; print 'OK\n'"
perl -c /var/lib/asterisk/agi-bin/agi-DID_route.agi   # Must say "syntax OK"

# Syntax-check ALL AGI scripts at once
for f in /var/lib/asterisk/agi-bin/*.agi; do
  perl -c "$f" 2>&1 | grep -v "syntax OK" && echo "FAIL: $f"
done
# No output = all clean
```

**Note:** If ViciDial is later updated and new modules are added to
`/usr/share/astguiclient/libs/`, re-run the `cp` commands above.

---

## 9. Quick Verification Checklist (Post-Install)

```bash
# Firewall status
systemctl status firewalld
firewall-cmd --list-rich-rules
nft list ruleset | grep "saddr !="     # Must be empty

# nftables service must be OFF
systemctl status nftables              # Must show disabled/inactive

# Port 22 must NOT be open
firewall-cmd --list-services           # Must NOT include "ssh"
firewall-cmd --list-ports              # Must NOT include "22/tcp"

# SIP peers all REACHABLE
asterisk -rx "sip show peers"

# AGI Perl modules installed
perl -e "use Asterisk::AGI; print 'OK\n'"
perl -c /var/lib/asterisk/agi-bin/agi-DID_route.agi

# fail2ban active with TCP + UDP banning
fail2ban-client status
nft list table inet f2b-table          # Must show addr-set-asterisk AND addr-set-asterisk-udp

# Dynportal ipset populated
firewall-cmd --ipset=dynamiclist --get-entries
```

---

## Lessons Learned (This Install)

1. **nftables service + firewalld conflict**: The nftables service loaded
   `/etc/nftables/main.nft` with `ip saddr != 88.151.128.22 drop` rules that
   silently blocked all DID4Sale SIP traffic. Fix: disable nftables service.

2. **Blanket port 5060 DROP rich rules**: Having both source-specific ACCEPT
   and blanket DROP for port 5060 created ordering issues in nftables chains.
   Fix: remove blanket DROP rules entirely; rely on zone default-deny.

3. **fail2ban iptables-allports on nftables system**: Bans were not effective.
   Fix: switch to `nftables-allports` action. Also: do NOT use `protocol=all`
   with nftables-allports — it generates `meta l4proto { all }` which is invalid
   nftables syntax. Use two action lines instead (one for tcp, one for udp).

4. **fail2ban only blocks TCP by default**: The `nftables-allports` action without
   a protocol parameter defaults to TCP only. SIP attacks use UDP. Add a second
   action line with `protocol=udp` to block both:
   ```
   action = nftables-allports[name=asterisk]
            nftables-allports[name=asterisk-udp, protocol=udp]
   ```

5. **Remove default SSH service from public zone**: firewalld's public zone includes
   `ssh` service (port 22) by default. If SSH is on a custom port, remove it:
   `firewall-cmd --permanent --remove-service=ssh && firewall-cmd --reload`

6. **DID4Sale multiple gateway IPs**: Each gateway IP needs its own SIP peer
   entry in ViciDial AND firewall whitelist. Whitelist the entire /24 to
   future-proof against new gateway IPs.

7. **allowguest=no requires peer for every inbound IP**: Without a peer entry,
   Asterisk rejects the INVITE even if the firewall allows it.

8. **Asterisk::AGI Perl module missing from system path on Rocky Linux 10**:
   Every AGI script silently failed at compile time — DID routing, IVR, everything.
   The symptom was `agi-DID_route.agi completed, returning 0` with no SET CONTEXT
   ever sent and `vicidial_did_log` staying empty. Root cause: ViciDial puts modules
   in `/usr/share/astguiclient/libs/` but Asterisk's subprocess environment has no
   `PERL5LIB`. See **Section 8** for the full fix.
