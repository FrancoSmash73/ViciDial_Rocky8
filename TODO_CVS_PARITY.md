# TODO — bring CVS up to date with work done on Oliver (2026-07-21)

Everything below came out of one long session on **Oliver** (104.207.140.83). I had no access
to CVS in that session, so nothing here has been checked against CVS's actual state — treat
every item as "go verify," not "just apply." Don't assume Oliver's specific findings (a stale
firewall rule, a leaked credential, etc.) also exist on CVS; the *methodology* is portable, the
*specific fixes* may not be needed at all if CVS is already clean.

## 1. Apache `ProxyTimeout` — large uploads 504ing

**What we found on Oliver**: `admin_listloader_fifth_gen.php` was 504ing on large list uploads
(confirmed on a 250k-row list) because `mod_proxy_fcgi`'s `ProxyTimeout` defaults to 60s, while
PHP itself was already configured for ~55 min execution — Apache was killing the client
connection long before PHP finished (PHP kept working in the background; the upload actually
succeeded, the browser just never found out).

**Fix applied**: `/etc/httpd/conf.d/zz-vicidial-proxytimeout.conf` (`Timeout 3600` /
`ProxyTimeout 3600`), also added to `vicidial_rocky10_part1_install.sh`'s Apache step (commit
`d66fe5e`) so future installs from that script get it automatically.

**⚠️ Before applying to CVS**: check which installer lineage CVS was actually built from —
`vicidial-rocky10` or the separate `vicidial-installer` repo (ECOSYSTEM_OVERVIEW.md notes
`vicidial-installer` was found checked out locally on CVS). The baked-in installer fix only
helps if CVS gets rebuilt from `vicidial-rocky10`; if CVS runs `vicidial-installer` or was
built by hand, the same 60s-default gap may exist there and needs the same `zz-vicidial-
proxytimeout.conf` file added directly, independent of which installer "owns" it.

- [ ] Confirm CVS's `mod_proxy_fcgi`/Apache `Timeout` setting (`httpd -t -D DUMP_RUN_CFG` or
      grep conf.d for an existing override)
- [ ] If no override exists, add `zz-vicidial-proxytimeout.conf` there too
- [ ] Confirm which installer lineage CVS actually uses; port the Part 1 installer change there
      if it's `vicidial-installer`, not just `vicidial-rocky10`

## 2. Firewall audit

**What we found on Oliver** (all confirmed removed): a decommissioned DID4Sale carrier rule
(`66.209.76.0/24`) with zero trace in DB/PJSIP config; an unexplained `5060/udp` allow for a
DigitalOcean IP matching no configured carrier; a dead `ssh` service entry (world-open port 22,
nothing listening — sshd only binds 1951); a dead `1984/tcp` world-open port with nothing behind
it; a standalone unscoped `accept` rule granting one IP every port/protocol instead of just the
SIP/RTP access it actually uses.

**The methodology, reusable on CVS**: cross-check `firewall-cmd --list-all` (both runtime and
`--permanent`) against `ss -tlnp`/`ss -ulnp` (is anything actually listening on each world-open
port?) and against the DB (`vicidial_server_carriers`, PJSIP config) for whether each rule maps
to something real. Don't trust "it's documented as intentional" — verify against current state.

- [ ] Run the same audit on CVS: `firewall-cmd --list-all` + `--permanent --list-all`, diff for
      drift, cross-check every world-open port/service against `ss -tlnp`/`ss -ulnp`
- [ ] Cross-check every accept rule's source IP against `vicidial_server_carriers` / PJSIP
      identify blocks — anything not traceable to a real, currently-used carrier is suspect
- [ ] Check for any blanket unscoped `accept` rules (vs. properly service-scoped ones) that
      could be narrowed

## 3. `check_miner_malware_V6_Final.sh`

Patched with 6 fixes this session (all pushed, repo:
`github.com/FrancoSmash73/check_miner_malware_V6_Final.sh`, commits `39f2789` → `36fba15`):
a `--fix`-mode bug that would've deleted `/usr/bin/VB-firewall`, three real systemd units
`--fix` would've stopped/disabled, a `DROP USER cron@'%'` that would've broken DB connectivity
for every Perl/AGI script, plus false positives in the MySQL bind-address check, a cron
fd-redirect pattern, and an `rpm -Vf` config-file check.

- [ ] Pull the updated script onto CVS (from the repo, or copy from Oliver's
      `/usr/src/check_miner_malware_V6_Final.sh`)
- [ ] Run it in **scan mode only** first (no `--fix`/`--harden`) — review output before
      considering remediation
- [ ] If `--fix` is ever run there, the whitelists in the script (`VICIDIAL_FILE_WHITELIST`,
      `LOCAL_SERVICE_WHITELIST`, `DB_USER_WHITELIST`) are tuned to Oliver's specific service
      names (`aiamd-shadow-watcher.service` etc.) and DB accounts — verify they match what's
      actually legitimate on CVS before trusting `--fix` there; don't assume Oliver's whitelist
      is complete for a different box

## 4. AI-AMD-project reliability fixes

Two bugs fixed in `shadow_watcher.py` and `extensions-ai-amd-spy.conf` (repo:
`github.com/FrancoSmash73/AI-AMD-project`, commits `c29a057`, `b413986`) — a per-file
`wave.Error` race that could stall the whole classification batch, and a ChanSpy leak that left
zombie channels alive for up to 123 hours, driving Asterisk to 130% CPU with zero real calls.

**Not urgent for CVS specifically** — per the project's own `docs/phase1-shadow.md`, Phase 1
shadow mode is only deployed on Oliver so far; "same stack on dialer 2 (CVS) when access lands"
is still an open next-step in the project's own roadmap, not something already running there.

- [ ] No action needed until AI-AMD actually gets deployed on CVS — at that point, deploying
      from the current repo state means these two fixes are already included, nothing to
      manually port

## 5. Leaked GitHub PAT

Found a live-format (already-dead) GitHub personal access token embedded in plaintext in
`/root/vicidial-skin/.git/config`'s remote URL on Oliver. Stripped it (`git remote set-url` to
the plain SSH form).

- [x] Check any CVS-side git clones (`vicidial-skin` or others) for the same
      `https://user:ghp_...@github.com/...` pattern in `.git/config` — `grep -r "ghp_" ~/*/.git/config`
      or similar across whatever repos are checked out there
      **Done 2026-07-22**: system-wide scan of every `.git/config` on CVS for credentials
      embedded in remote URLs (`https://user:TOKEN@github.com/...`, all GitHub token prefixes)
      — clean, nothing found.

## 6. Documentation corrections (already fixed centrally, verify CVS-specific bits)

`vicidial-rocky10-work/CLAUDE.md` and `ECOSYSTEM_OVERVIEW.md` both got corrected this session
(stale 172.x cluster-IP table, Asterisk service-management description, stale `vicidial-skin`
row) — these are single-source-of-truth docs, already pushed, nothing to "port." But:

- [x] Verify CVS's own Asterisk service-management pattern. **Done 2026-07-22**: CVS genuinely
      runs Asterisk under `asterisk.service` (systemd) — a real, confirmed divergence from
      Oliver's detached-screen/rc.local pattern, not a doc error. Oliver's own classification
      was re-verified live the same day and stands unchanged. See CVS_OLIVER_DIVERGENCE.md
      section 4 for the full writeup and the operational implication (what "restart Asterisk"
      means differs per box).

## 7. Hardcoded `confcron` AMI secret (found/fixed 2026-07-22, Oliver only)

Oliver's `manager.conf` had **six** AMI accounts (`cron`, `updatecron`, `listencron`, `sendcron`,
`sipcron`, `confcron`) all sharing one secret — `1234` — driven by a single DB column
(`servers.ASTmgrSECRET`, `varchar(20)`). `confcron` specifically was hardcoded to `1234` in
`vicidial_rocky10_part2_install.sh`'s manager.conf heredoc; the rest inherited the same value
via that shared DB column, which is stock ViciDial's own default, not unique to this installer.
Not internet-reachable (firewalld's `asterisk` service covers 5060/5061/4569/8088/8089, not
5038, and the zone default-denies) — but a full-privilege (`system`,`originate`) AMI account
sitting on a well-known default is a real gap if that firewall rule ever drifts.

**Fixed on Oliver, 2026-07-22**: rotated `servers.ASTmgrSECRET` + all six `manager.conf` `secret =`
lines to a fresh 20-char value, reloaded Asterisk's manager config, and restarted the three
persistent AMI daemons (`AST_manager_send.pl`, `AST_manager_listen_AMI2.pl`,
`AST_conf_update_screen.pl`) via `vicidial-keepalive.service` so they picked up the new secret.
Verified clean logons in `/var/log/asterisk/messages` for all six accounts post-rotation, zero
auth failures since, no dropped calls (1 active call stayed up throughout).

**Installer fixed too** (commit `db62674`, pushed): `vicidial_rocky10_part1_install.sh` now
generates `CONFCRON_SECRET` alongside the DB passwords and stores it in the credentials file;
`vicidial_rocky10_part2_install.sh` loads it (self-healing fallback for older Part 1 runs)
instead of hardcoding `1234`.

- [ ] Check CVS's `/etc/asterisk/manager.conf` for the same pattern (all six stock ViciDial AMI
      account names sharing one weak/default secret) — `grep -A1 '^\[.*cron\]' manager.conf`
- [ ] If found, rotate the same way: update `servers.ASTmgrSECRET` in the DB, update all matching
      `secret =` lines in `manager.conf` to match, `asterisk -rx "manager reload"`, then bounce
      any persistent AMI-consumer daemons so they pick up the new value (don't just restart
      `asterisk.service` on CVS — remember CVS's Asterisk is systemd-managed per item 6, so the
      restart mechanics differ from Oliver's screen/keepalive pattern)
- [ ] Confirm CVS's firewall doesn't expose port 5038 externally either (same check as item 2:
      cross-reference `firewall-cmd --list-all` against `ss -tlnp`)
- [ ] If CVS ever gets rebuilt from `vicidial-rocky10`, the installer fix is already in `main` —
      nothing to manually port, same caveat as item 1 about confirming which installer lineage
      CVS actually uses

---

*Written 2026-07-21 after an Oliver-focused session (firewall audit, `check_miner_malware`
hardening, AI-AMD reliability fixes, doc corrections). See `ECOSYSTEM_OVERVIEW.md`'s Open
Threads for the running cross-project log this was distilled from.*
