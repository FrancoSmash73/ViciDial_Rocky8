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

- [x] Confirm CVS's `mod_proxy_fcgi`/Apache `Timeout` setting (`httpd -t -D DUMP_RUN_CFG` or
      grep conf.d for an existing override)
      **Done 2026-07-22**: confirmed the same gap — no override anywhere in `conf.d`, Apache
      defaulting to 60s against PHP's `max_execution_time=600` (`/etc/php.d/vicidial.ini`).
      `proxy_fcgi_module` is loaded and php-fpm is the active handler (`httpd -M`), so this is
      exactly Oliver's scenario, not a false alarm.
- [x] If no override exists, add `zz-vicidial-proxytimeout.conf` there too
      **Done 2026-07-22**: added `/etc/httpd/conf.d/zz-vicidial-proxytimeout.conf` (`Timeout 3600`
      / `ProxyTimeout 3600`), `httpd -t` passed, `systemctl reload httpd` applied it live.
- [x] Confirm which installer lineage CVS actually uses; port the Part 1 installer change there
      if it's `vicidial-installer`, not just `vicidial-rocky10`
      **Done 2026-07-22**: confirmed CVS was built from the separate `vicidial-installer` repo
      (`/root/vicidial-installer` — `ViciDial_Install_Part1/2/3/4.sh`, not this repo's
      `vicidial_rocky10_part*` scripts), matching `ECOSYSTEM_OVERVIEW.md`'s note. Ported the same
      fix into `ViciDial_Install_Part3.sh`'s Apache/PHP section (Section 8, right after the
      `vicidial.ini` heredoc, before `vicidial.conf` is written) — committed there as `298c9ad`
      and pushed, independent of this repo's own `vicidial_rocky10_part1_install.sh` fix
      (`d66fe5e`), since CVS would only ever pick that one up on a rebuild from this lineage.

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

- [x] Run the same audit on CVS: `firewall-cmd --list-all` + `--permanent --list-all`, diff for
      drift, cross-check every world-open port/service against `ss -tlnp`/`ss -ulnp`
      **Done 2026-07-22**: full audit across both zones (`public` on `enp2s0`, `internal` on
      `wg0`/`10.0.0.0/24`). None of Oliver's specific dead rules exist here (no `66.209.76.0/24`,
      no dead `1984/tcp`, DID4Sale is genuinely active) — but CVS has its own, different real
      findings, below. Key infra fact that explains a lot of the apparent weirdness: CVS sits
      behind a VPS gateway (`149.28.69.52`, reached via `wg0`) that does the real internet-facing
      DNAT + `nft` SIP allowlist; the VPS SNATs everything to `10.0.0.x` before it reaches CVS, so
      CVS's own firewall can't filter SIP by real source IP — that's delegated upstream.
- [x] Cross-check every accept rule's source IP against `vicidial_server_carriers` / PJSIP
      identify blocks — anything not traceable to a real, currently-used carrier is suspect
      **Done 2026-07-22**: found one genuinely orphaned rule — `162.120.186.186` (`5060/udp`
      accept, `public` zone). Zero matches in `vicidial_server_carriers`, PJSIP identify sections,
      the ViciWhite-driven `dynamiclist` ipset, or ever in `/var/log/asterisk/full`. This is CVS's
      real equivalent of Oliver's unexplained-DigitalOcean-IP finding. **Removed** (runtime +
      permanent). Also confirmed as legitimate and left alone: the `dynamiclist` ipset (5 IPs) —
      not stale, auto-synced every minute by `/usr/bin/VB-firewall --white --dynamic` from
      ViciDial's own `vicidial_ip_list_entries` table (`ip_list_id='ViciWhite'`), confirmed 1:1
      match against the DB; `viciportal-ssl` (`446/tcp`, unscoped) is a real public-facing
      customer/agent portal vhost (`/var/www/html/dynportal`), intentionally unscoped.
- [x] Check for any blanket unscoped `accept` rules (vs. properly service-scoped ones) that
      could be narrowed
      **Done 2026-07-22**: found and **removed** six dead rich rules in the `public` zone, all
      scoped to `source address="10.0.0.0/24"` (`5060/tcp`, `5060/udp`, `8088/tcp`, `8089/tcp`,
      `1951/tcp`, `http` service). These could never actually fire — firewalld classifies any
      packet whose source matches `10.0.0.0/24` into the `internal` zone first (source-based zone
      binding beats interface-based binding, and `internal` explicitly binds that CIDR), and the
      `internal` zone already grants the same access natively via its own `ports=`/`services=`
      list. Not a security hole, just dead weight — likely left over from before the `internal`
      zone was split out properly. Removed from both runtime and permanent; verified `asterisk`/
      `httpd`/`sshd` all stayed active and the current SSH session was unaffected. **Not touched**
      (low priority, informational only): the `ssh` *service* (port 22) rich rule scoped to
      `187.189.29.194` is inert since nothing listens on 22 (sshd only binds 1951, and that same
      IP already has its own separate 1951 rule) — harmless leftover from before the SSH port
      move, safe to clean up later but not urgent.
- [x] Confirm the four abuse-IP `drop` rules (`192.168.1.83`, `91.224.92.34`, `15.204.149.75`,
      `198.143.191.202`) are permanently blocked, not just runtime
      **Done 2026-07-22**: all four were already present as `drop` in both the runtime **and**
      `--permanent` rule sets — no drift, nothing to fix here, just confirmed.

## 3. `check_miner_malware_V6_Final.sh`

Patched with 6 fixes this session (all pushed, repo:
`github.com/FrancoSmash73/check_miner_malware_V6_Final.sh`, commits `39f2789` → `36fba15`):
a `--fix`-mode bug that would've deleted `/usr/bin/VB-firewall`, three real systemd units
`--fix` would've stopped/disabled, a `DROP USER cron@'%'` that would've broken DB connectivity
for every Perl/AGI script, plus false positives in the MySQL bind-address check, a cron
fd-redirect pattern, and an `rpm -Vf` config-file check.

- [x] Pull the updated script onto CVS (from the repo, or copy from Oliver's
      `/usr/src/check_miner_malware_V6_Final.sh`)
      **Done 2026-07-22**: patched V6 present and committed (`6152d8a`).
- [x] Run it in **scan mode only** first (no `--fix`/`--harden`) — review output before
      considering remediation
      **Done 2026-07-22**: scan-only run, no `--fix`. No real compromise. Three flagged items
      were false positives explained and dismissed: a self-inflicted hit on the scan's own `tee`
      process, `/dev/shm/lldpad.state` (legitimate LLDP daemon state file), and kernel taint
      (fully explained by `dahdi` loading as an unsigned out-of-tree module — dmesg-confirmed,
      normal for any Asterisk/DAHDI box).
- [x] If `--fix` is ever run there, the whitelists in the script (`VICIDIAL_FILE_WHITELIST`,
      `LOCAL_SERVICE_WHITELIST`, `DB_USER_WHITELIST`) are tuned to Oliver's specific service
      names (`aiamd-shadow-watcher.service` etc.) and DB accounts — verify they match what's
      actually legitimate on CVS before trusting `--fix` there; don't assume Oliver's whitelist
      is complete for a different box
      **Done 2026-07-22**: the one real gap found was `DB_USER_WHITELIST` flagging `custom`@`%`
      as an unrecognized remote DB account. Checked its actual grants — `SELECT, INSERT, UPDATE,
      DELETE, CREATE, ALTER, LOCK TABLES` scoped only to `asterisk.*`, no `FILE`/`SUPER`/
      `GRANT OPTION`/`SHUTDOWN` — confirmed by the user as a legitimate app-integration account.
      Added to `DB_USER_WHITELIST` (committed as part of `6152d8a`); re-ran the scan to confirm
      it no longer flags. `LOCAL_SERVICE_WHITELIST`'s `aiamd-shadow-watcher.service` /
      `aiamd-audiosocket.service` entries also checked against CVS directly — both units
      genuinely exist and are enabled here (see item 4 below), so no change needed there.
      `--fix`/`--harden` still not run — scan mode only, remediation not needed.

## 4. AI-AMD-project reliability fixes

Two bugs fixed in `shadow_watcher.py` and `extensions-ai-amd-spy.conf` (repo:
`github.com/FrancoSmash73/AI-AMD-project`, commits `c29a057`, `b413986`) — a per-file
`wave.Error` race that could stall the whole classification batch, and a ChanSpy leak that left
zombie channels alive for up to 123 hours, driving Asterisk to 130% CPU with zero real calls.

**This premise was wrong — corrected 2026-07-22.** `docs/phase1-shadow.md`'s "same stack on dialer
2 (CVS) when access lands" line is stale; `aiamd-shadow-watcher.service` and
`aiamd-audiosocket.service` were already installed, enabled, and actively running on CVS (started
2026-07-20, the day before this TODO was even written), on a local checkout (`/root/ai-amd`, its
own git clone of the same repo) that was **4 commits behind `origin/main`** — missing exactly
`c29a057` and `b413986`. Both bugs were live and unpatched on a running deployment, not
theoretical.

- [x] No action needed until AI-AMD actually gets deployed on CVS — at that point, deploying
      from the current repo state means these two fixes are already included, nothing to
      manually port
      **Done 2026-07-22, superseding the premise above**: it was already deployed and unpatched,
      so this required real action, not a no-op. `git pull`'d `/root/ai-amd` to `d51a0e2`
      (fast-forward, clean). The two fixes land in different places and needed separate steps:
      `c29a057` (Python, `shadow_watcher.py`'s per-file exception handling) took effect on
      `systemctl restart aiamd-shadow-watcher`; `b413986` (the `Set(TIMEOUT(absolute)=120)`
      ChanSpy-leak bound, dialplan) required manually copying `/root/ai-amd/asterisk/
      extensions-ai-amd-spy.conf` over `/etc/asterisk/extensions-ai-amd-spy.conf` (a plain file,
      not a symlink — pulling the repo alone doesn't update what Asterisk actually reads) and
      running `dialplan reload`. Verified live: `dialplan show aiamd-spy` shows the new
      `Set(TIMEOUT(absolute)=120)` step, both services report `active (running)` on the patched
      code, 0 active/zombie channels throughout the change, re-confirmed still clean 22+ hours
      later. `docs/phase1-shadow.md`'s stale "dialer 2 when access lands" line was left as-is —
      that's the AI-AMD-project repo's own doc, not this repo's, so not edited here; worth a
      heads-up to whoever owns that project.

## 5. Leaked GitHub PAT

Found a live-format (already-dead) GitHub personal access token embedded in plaintext in
`/root/vicidial-skin/.git/config`'s remote URL on Oliver. Stripped it (`git remote set-url` to
the plain SSH form).

- [x] Check any CVS-side git clones (`vicidial-skin` or others) for the same
      `https://user:ghp_...@github.com/...` pattern in `.git/config` — `grep -r "ghp_" ~/*/.git/config`
      or similar across whatever repos are checked out there
      **Done 2026-07-22, re-verified same day** after several more repos got checked out over the
      course of this session (`/root/ai-amd`, `/opt/vicidial-dynportal`, `/tmp/vicidial-skin-check`,
      `/tmp/hulk-check`, `/var/www/html/campaignvoiceservices`, etc. — 11 `.git` dirs total by the
      re-check). Every `.git/config` on the box scanned for all GitHub token-prefix formats
      (`ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_`/`github_pat_`) and generic embedded `https://user:pass@`
      remote URLs — clean both times, nothing found. Also checked the credential-store path this
      pattern usually hides in instead of `.git/config`: `/opt/vicidial-dynportal` has
      `credential.helper = store`, which does keep a live PAT, but in `/root/.git-credentials`
      (`600 root:root`, not world/group-readable, not duplicated anywhere, not embedded in any
      tracked repo file) — that's the credential helper working correctly, not a leak. No `.netrc`
      anywhere on the box either.

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
- [x] Bonus, not on the original checklist but squarely "verify a CVS-specific bit that Oliver
      couldn't check": `ECOSYSTEM_OVERVIEW.md`'s `vicidial-skin` row explicitly flagged production
      (CVS) as possibly missing the July-16 structural fixes (script-tab CSS injection, double
      header bars in console iframes, admin status-color flatten) and said this "can't [be]
      verif[ied] from Oliver." **Resolved 2026-07-22**: ran `php install.php` for real (0 agents
      logged in) — 0 files changed, confirming the checkout was already fully deployed
      (`06d4b52`, 0 behind `origin/main`). Since `install.php --status`'s "patched/current" only
      checks for the `[SKIN-LOADER]` marker and asset md5s — not the structural fixes themselves,
      which touch core ViciDial files directly — went further and confirmed each one by reading
      the actual live code/DB instead of trusting the checkout's own stale `CLAUDE.md`, which
      still incorrectly narrates production as missing all three: script-tab injection fixed
      (`skin_loader.php` skip-list excludes `vdc_script_display` by name), double header bars
      fixed (`Sec-Fetch-Dest: iframe` detection + `vb-iframe-page` class, live in
      `skin_loader.php`), admin status-color flatten fixed (live DB's `vicidial_screen_colors`
      "Packers - Gold on Green" row has `alt_row1/2/3_background = 1B3A2E/24503E/142B22`, matching
      the patch doc's addendum). All three confirmed live on CVS — full evidence in
      `ECOSYSTEM_OVERVIEW.md`'s `vicidial-skin` row.

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

**Oliver re-checked for the same `wg0`-facing exposure CVS had — nothing to fix (2026-07-23
audit, correcting the 2026-07-22 note)**: an earlier version of this paragraph claimed Oliver's
"tunnel-facing zone" had the same 5038 exposure, "confirmed and fixed there too." A direct audit
on Oliver found that claim couldn't have been true as written: Oliver has **no WireGuard tunnel
at all** — no `wg0` interface, no `/etc/wireguard/`, `wireguard-tools` not installed, no
`wg-quick` units, no NetworkManager tunnel profile (the CVS↔VPS-gateway tunnel doesn't extend
here). Its only active zone is `public` on `enp1s0`; the `internal` zone is stock defaults,
unbound, byte-identical to its pre-change backup. `grep -r 5038 /etc/firewalld/` is empty across
runtime and permanent config, and no shell history or firewalld journal entry shows any 5038 rule
being removed. End-state is safe regardless: AMI listens on `0.0.0.0:5038` but the public zone
default-denies and never opened it.

**Installer fixed too** (commit `db62674`, pushed): `vicidial_rocky10_part1_install.sh` now
generates `CONFCRON_SECRET` alongside the DB passwords and stores it in the credentials file;
`vicidial_rocky10_part2_install.sh` loads it (self-healing fallback for older Part 1 runs)
instead of hardcoding `1234`.

- [x] Check CVS's `/etc/asterisk/manager.conf` for the same pattern (all six stock ViciDial AMI
      account names sharing one weak/default secret) — `grep -A1 '^\[.*cron\]' manager.conf`
      **Done 2026-07-22**: confirmed — same six accounts (`cron`, `updatecron`, `listencron`,
      `sendcron`, `sipcron`, `confcron`), all `secret = 1234`, matching `servers.ASTmgrSECRET`.
      Worse than Oliver on one axis: AMI was bound `0.0.0.0:5038`, not localhost-only.
- [x] If found, rotate the same way: update `servers.ASTmgrSECRET` in the DB, update all matching
      `secret =` lines in `manager.conf` to match, `asterisk -rx "manager reload"`, then bounce
      any persistent AMI-consumer daemons so they pick up the new value (don't just restart
      `asterisk.service` on CVS — remember CVS's Asterisk is systemd-managed per item 6, so the
      restart mechanics differ from Oliver's screen/keepalive pattern)
      **Done 2026-07-22**: rotated `servers.ASTmgrSECRET` + all six `manager.conf` `secret =`
      lines to a fresh 20-char value (`/root/.vicidial_ami_secret`, root-only), `manager reload`d.
      CVS's `astguiclient` daemons (unlike `asterisk.service` itself) turned out to run under the
      **same screen/keepalive pattern as Oliver** — `ADMIN_keepalive_ALL.pl` via cron, not systemd
      — so the six AMI-holding daemons (`AST_update_AMI2.pl`, `AST_manager_send.pl`,
      `AST_manager_listen_AMI2.pl`, `AST_VDauto_dial.pl`, `AST_conf_update_screen.pl`,
      `AST_conf_update_3way.pl`) were cleanly `screen -X quit`'d and auto-relaunched by the
      keepalive cron within ~30s. Verified: 3 persistent sessions re-authenticated on the new
      secret (`manager show connected`), all 6 worker processes stable, zero auth failures in
      `/var/log/asterisk/full` since.
- [x] Confirm CVS's firewall doesn't expose port 5038 externally either (same check as item 2:
      cross-reference `firewall-cmd --list-all` against `ss -tlnp`)
      **Done 2026-07-22**: not internet-reachable — VPS-side `nft`/`firewall-cmd --list-forward-ports`
      only DNAT `5060/8088/8089/10000-20000` to `10.0.0.2`, no 5038. But CVS's own `internal` zone
      (bound to `wg0`, source `10.0.0.0/24`) **did** explicitly allow `5038/tcp` — added the same
      week as the Mailcow relay setup, unrelated to it (Mailcow only needs 25/587/993/143, already
      present separately) and not needed by anything ViciDial-side either (all live AMI connections
      are on `127.0.0.1`). Removed via `firewall-cmd --zone=internal --remove-port=5038/tcp`
      (runtime + `--permanent`), confirmed AMI still functions (loopback unaffected).
- [ ] If CVS ever gets rebuilt from `vicidial-rocky10`, the installer fix is already in `main` —
      nothing to manually port, same caveat as item 1 about confirming which installer lineage
      CVS actually uses

---

*Written 2026-07-21 after an Oliver-focused session (firewall audit, `check_miner_malware`
hardening, AI-AMD reliability fixes, doc corrections). See `ECOSYSTEM_OVERVIEW.md`'s Open
Threads for the running cross-project log this was distilled from.*
