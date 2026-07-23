# CVS ↔ Oliver Divergence — Investigation & Fix Plan

Two live servers that started from the same architecture have drifted apart in
two separate ways. Neither is an emergency — both boxes work — but left alone
they'll keep drifting further, and one of them (Asterisk version) is the kind
of thing that gets expensive to reconcile the longer it's left. This doc is
the record of what's diverged, why, and what needs a real decision (not a
midnight one) before anything gets changed on a live call center.

**Status as of 2026-07-20. Re-verify current state before acting on this —
don't assume these numbers are still accurate by the time you read it.**

---

## What's diverged

### 1. Asterisk major version

| | CVS (campaignvoiceservices) | Oliver (dialengine.ddns.net) |
|---|---|---|
| Asterisk | **20** (plain, not vici-patched), PJSIP-only | **18.21.0-vici**, also PJSIP-only (see below) |
| Status | Manually built as the "reference box" for the `pjsip-fail2ban-hardening` branch; validated end-to-end — HulkPhone completed real WebRTC registration and test calls (branch commit `57aa02d`/`0684331`) | Stable, running the vici-patched build `vicidial-rocky10` was originally built around |

CVS became the Asterisk 20 testbed specifically to validate the
`pjsip-fail2ban-hardening` branch's PJSIP-only posture (the work motivated by
chan_sip absorbing a 4-day REGISTER brute-force flood with fail2ban catching
none of it — see that branch's commit history for the full story). That
validation succeeded. Oliver was never migrated to Asterisk 20 — deliberately,
per the branch's own commit `bdabbc5`, which self-flags as build-only and
"not yet build-validated... Build on a disposable VM before using in anger."

**Correction (re-verified 2026-07-20, live):** this doc originally described
Oliver as "pjsip+chan_sip coexisting per original architecture." That's wrong.
Live checks on Oliver show `noload = chan_sip.so` in `modules.conf` (comment:
"unloaded 2026-07-09: unused, all phones+carriers on PJSIP"), 13/13 active
phones on `protocol='PJSIP'`, the dialplan fully regenerated (0×
`Dial(SIP/...)`, 14× `Dial(PJSIP/...)`), and `udp/5060` neither listening nor
open in firewalld. Oliver went through the full chan_sip removal — audit,
dialplan regen, noload, port close — on **2026-07-09**, the same day `77c67f9`
was authored. No backup directory matching `vicidial_chan_sip_remove.sh`'s
naming convention was found, so this was most likely done by hand following
the same playbook rather than by running the script itself, but the end state
is identical and complete. **The only real remaining divergence in this
section is the Asterisk major version (20 plain vs. 18.21.0-vici) — chan_sip
is a settled fact on both boxes, not an open item.**

### 2. HulkPhone deployment mechanism — RESOLVED 2026-07-20

| | `vicidial-rocky10` Part 4 script (before) | Oliver (live) |
|---|---|---|
| Method | `git clone --depth 1` to a **temp dir**, `cp` the files out, then `rm -rf` the clone — so the result on disk had no `.git`, no update path, and none of the real repo's hardening | **Live `git clone`** of `github.com/FrancoSmash73/Hulk-`, left in place |
| Currency | The one true fallback path (`configs/hulkphone/`, used only if the clone itself failed) was confirmed ~2 months stale (May 9 vs. Hulk-'s July 9 tip) — already synced separately this session | Current, plus a `deploy/` hardening layer: `deny-git.conf`, `hulkphone-noindex.conf`, a fail2ban loopback exemption, and a `verify.sh` health check (confirmed 8/8 passing against `wss://dialengine.ddns.net:8089/ws`) |

**Fixed**: Part 4's Step 8 now clones `Hulk-` directly into
`/var/www/html/hulkphone` and leaves the `.git` in place (`git -C
/var/www/html/hulkphone pull` works afterward), ports in the same
`deploy/` hardening Oliver already proved (deny-git, noindex, fail2ban
loopback exemption, `verify.sh` run against loopback as a non-fatal
post-deploy check), and seeds `config.local.php` from the script's own
`--domain` flag on first run without touching it again on re-runs. Re-runs
detect the existing checkout by matching `git remote get-url origin` and
fast-forward via `fetch --depth 1 && reset --hard`; anything found on disk
that isn't that checkout (an old vendored-copy install, manual content) gets
moved aside to a timestamped backup rather than silently overwritten.
Verified in an isolated scratch directory first (fresh clone, idempotent
re-run, stale-checkout update, non-git-content preservation, and a real
permission bug this testing caught: the bulk `chmod 644` lockdown was
clobbering `config.local.php`'s `640 root:apache` permissions back to
world-readable on every re-run after the first — fixed by re-applying that
chmod unconditionally after the bulk pass).

**Run for real against CVS's live `/var/www/html/hulkphone` on 2026-07-20**,
which caught two more real issues before/during the run:
- CVS's existing checkout used the **SSH** remote (`git@github.com:...`)
  while `HULK_REPO` was hardcoded to the **HTTPS** form — an exact-string
  match would have treated it as "not ours," backed it up, and re-cloned
  fresh, silently losing `config.local.php`'s real TURN credentials
  (`turn_server`/`turn_user`/`turn_pass`) in the process, since the seeding
  logic only fills in `sip_domain`. Fixed to compare owner/repo identity
  instead of the raw URL, *before* running against CVS.
- The blanket `chmod 755`(dirs)/`644`(files)/`755`(`*.sh`) reset was fighting
  git's own tracked executable bit on several `Hulk-` files (`hulkphone.php`,
  `.css`, `.js`, `README.md`, etc. — all committed as mode `100755`),
  leaving the checkout permanently "dirty" (`git status` mode-only diff)
  after every run. Caught by actually running it, not by the isolated test
  (which never checked `git status` afterward). Fixed to `chmod -R go-w`
  instead — strips group/world write only, leaves read/execute exactly as
  git tracks them.

End state on CVS: `deploy/verify.sh` 8/8 passing, `git status` clean,
`config.local.php`'s real TURN credentials (`149.28.69.52:3478`) intact
throughout.

**Run for real against Oliver's live `/var/www/html/hulkphone` on
2026-07-20** with both fixes already in place — no new issues this time.
Oliver's remote was already the HTTPS form (the SSH-mismatch fix wasn't
even needed here), and `deploy/verify.sh` was 8/8 on the first try:
`config.local.php` untouched (`sip_domain=dialengine.ddns.net`,
`turn_server` still empty, matching Oliver's direct public IP / no CGNAT),
`git status` clean immediately, and ownership moved from a mixed
`apache:apache`/`root:root` state to fully `root:root` (except
`config.local.php`, `root:apache` as designed) with no group/world-writable
files anywhere. Both CVS and Oliver are now running the same,
fully-fixed deployment mechanism.

### 3. `pjsip-fail2ban-hardening` branch — merged and deleted, 2026-07-20

This branch (9 real commits of fail2ban/php fixes plus PJSIP tooling, authored
against CVS) never made it to GitHub until this session — see the "what's
diverged" history above for why. Once pushed, it went through a real merge
review rather than a blind merge:

- **Merged into `main`**: the 3 fail2ban fixes (blind jails, wrong logfile,
  `.conf`-overridden-by-`.local`), 2 php/php-fpm fixes, `php-error-signal.sh`
  monitoring, `vicidial_pjsip_phone_sync.sh` (DB-driven PJSIP endpoint
  generation), `vicidial_chan_sip_remove.sh` (audited chan_sip removal), and
  docs. Merge commit `ad20359`.
- **Deliberately excluded**: `441cf78` (build plain Asterisk 20.18.2, no
  patches). It was the *only* commit touching `vicidial_rocky10_part2_install.sh`
  and `CLAUDE.md` in the whole branch, so both were verified as exact-zero-diff
  against pre-merge `main` after the merge. `main`'s default install is
  unchanged: still Asterisk 18.21.0-vici.
- **Branch deleted** (GitHub, this sandbox, and Oliver's local checkout — Oliver's
  was still checked out on it) after confirming `441cf78` remains fully
  inspectable forever via `git show 441cf78`, since it's a permanent ancestor
  of the merge commit regardless of the branch ref existing.

**New finding this surfaced, worth its own follow-up**: ViciDial's 5
Asterisk-18 patches (`amd_stats`, `iax_peer_status`, `sip_peer_status`,
`timeout_reset_dial_app`, `timeout_reset_dial_core`) were dry-run tested
against real, freshly-downloaded Asterisk 20.18.2 source — **all 5 applied
cleanly**, no rejected hunks (one hunk needed minor fuzz, still succeeded).
Of the 5, only 3 are actually relevant to a PJSIP-only build (`amd_stats` and
the two `timeout_reset_*` patches — `sip_peer_status`/`iax_peer_status` patch
`chan_sip.c`/`chan_iax2.c`, neither of which loads once chan_sip is
noloaded). This means a genuinely **patched** Asterisk 20 — newer Asterisk,
real ViciDial feature patches retained — looks buildable, which would beat
both today's 18-vici default and `441cf78`'s unpatched-20 approach. Textual
patch-apply success isn't proof the code compiles or behaves correctly,
though — this needs an actual compile + functional smoke test on a disposable
VM before it's a real option, not just evidence it's worth attempting.

### 4. Asterisk service-management mechanism — CONFIRMED DIVERGENT, 2026-07-22

| | CVS (campaignvoiceservices) | Oliver (dialengine.ddns.net) |
|---|---|---|
| Mechanism | `asterisk.service` (systemd) | Detached `screen -S asterisk`, launched by `rc.local` → `start_asterisk_boot.pl` |

This came out of `TODO_CVS_PARITY.md` item 6, which flagged the open question
correctly: "don't assume CVS is the same [as Oliver] — check `systemctl status
asterisk` and `screen -ls` there directly." A CVS-side session did that check
and reported CVS genuinely runs Asterisk under `asterisk.service`.

**Re-verified live on Oliver 2026-07-22** (this session, not just trusting the
existing doc) before writing this section, prompted by the CVS finding raising
the question of whether Oliver's own classification might have been wrong:
- `systemctl status asterisk` → `Loaded: masked`, `Active: inactive (dead)`
- `systemctl status vicidial-asterisk` → unit not found
- `screen -ls` → `1923.asterisk (Attached)`, part of a `rc-local.service` →
  `SCREEN -S astshell...` → `screen -L -S asterisk` → `asterisk -vvv...gcT`
  process tree, PID 1933, running continuously since Jul 14 (9+ days uptime)
- `ss -ulnp`/`ss -tlnp` show no chan_sip-era `5060/udp`; PJSIP is on
  `transport-udp 0.0.0.0:5061` and `transport-wss 0.0.0.0:5060`, consistent
  with the chan_sip removal already recorded in section 1 above

Oliver's classification stands as originally documented — this session found
no error to correct there.

**CVS side independently re-verified live, 2026-07-22** (same four checks,
run directly on CVS in a separate session with box access, closing the loop
this section left open):
- `systemctl status asterisk` → `Loaded: loaded (/etc/rc.d/init.d/asterisk;
  generated)`, `Active: active (running)` since 2026-07-07, PID 3116, under
  real systemd/LSB-init supervision (not a wrapper around a screen)
- `systemctl status vicidial-asterisk` → `Unit vicidial-asterisk.service
  could not be found`
- `screen -ls` → 10 sessions, all `AST*` astguiclient Perl process names
  (`ASTupdate`, `ASTsend`, `ASTlisten`, `ASTVDauto`, `ASTVDremote`, etc.) —
  **none named `asterisk`**, confirming the Asterisk core itself is not
  running inside any of them on CVS, unlike Oliver's `1923.asterisk` screen
- `ss -ulnp | grep 5060` → `0.0.0.0:5060` bound directly to
  `("asterisk",pid=3116)` — the core process itself owns the port, not a
  screen-wrapped child

Both sides of this divergence are now independently confirmed from both
boxes, not one-sided. This closes the "not independently re-verified" gap
this section originally flagged. One nuance worth keeping in mind: CVS's
unit is LSB-init-wrapped (`generated` from `/etc/rc.d/init.d/asterisk`), not
a hand-written native systemd unit — `systemctl start/stop/status` all work
normally, but journald log capture, `Restart=` policy behavior, and
dependency ordering may not behave identically to a real native unit. Worth
checking the actual generated unit before relying on any of those specifics.

**Bonus divergence caught during the CVS cross-check — port assignment**:

| | CVS | Oliver |
|---|---|---|
| PJSIP `transport-udp` | `5060` | `5061` |
| PJSIP `transport-wss` | `8089` | `5060` |

Same functional setup (PJSIP-only, WSS for WebRTC), different port numbers
on both transports, not just one. CVS's `transport-udp` on `5060` is the
old chan_sip-era port now carrying PJSIP UDP, and its `transport-wss` on
`8089` is the conventional ViciDial/Asterisk `http.conf` default. Oliver's
`transport-wss` on `5060` is the deliberate `websocket_enabled=false` /
chan_sip-freed-port workaround already documented in CLAUDE.md, freeing
`5061` for its `transport-udp` — expected, not new drift. Flagging so no
firewall rule, runbook, or troubleshooting habit gets written assuming one
box's port numbers apply to the other.

**Why this matters going forward**: any future runbook step that assumes "restart
Asterisk" means the same thing on both boxes is wrong. On CVS that's
`systemctl restart asterisk`; on Oliver it's re-running (or reattaching and
restarting inside) the `screen`/`rc.local` flow — `systemctl restart asterisk`
on Oliver would do nothing to the real running process. `TODO_CVS_PARITY.md`
item 6 is closed with this section as the answer.

---

## Open decisions — not made here, need your call

**1. Migrate Oliver to Asterisk 20?**
CVS proves the PJSIP-only + Asterisk 20 combination works end-to-end. But
Oliver is a live production call center — rebuilding its Asterisk is
irreversible in the way a config change isn't. Don't do this without:
- A maintenance window, not an ad-hoc session
- A fresh re-verification that CVS's build is still stable under real
  production load, not just a validated test call
- A rollback plan (Oliver's current 18.21.0-vici build should stay recoverable
  until the 20 build has run clean for a real stretch of time)

Now a three-way choice, not two: stay on 18-vici, move to plain unpatched 20
(`441cf78`'s approach, excluded from `main`), or build a **patched** 20 (see
the branch-merge note above — the 3 relevant vici patches dry-run clean
against real 20.18.2 source, unvalidated by an actual compile yet). The third
option looks like the best outcome of the three if it holds up under a real
build test, but that test hasn't happened.

**2. ~~Change Part 4 to deploy HulkPhone via git-clone instead of vendoring?~~**
Implemented and run for real on both CVS and Oliver, 2026-07-20 — see the
RESOLVED note above. **`configs/hulkphone/` dropped entirely, same day** —
it had no sync mechanism (already drifted ~2 months stale once) and only
covered a fully-offline-during-Part-4 scenario that Parts 1/2 wouldn't have
survived to reach anyway. The offline fallback now deploys a shell that's
honest about not working (both `<script>`/`<link>` tags 404) instead of a
vendored copy that silently rots.

**3. Migrate Oliver from screen/rc.local to a systemd-managed Asterisk (CVS's pattern)?**
Opinion, not yet a decision: systemd is the better-suited pattern for a
production dialer, and it's not close. The screen/rc.local setup gives zero
crash supervision — if Asterisk dies mid-shift, nothing restarts it; recovery
depends on a human noticing dead calls, not on a `Restart=on-failure` policy.
It also has no standard tooling hooks (monitoring agents, `systemctl status`,
journald log correlation all expect a real unit), and it's the direct cause
of the double-instance/port-5060 foot-gun already documented in CLAUDE.md —
a single canonical start/stop path via systemd removes that whole class of
mistake.

The one legitimate reason Oliver ended up on screen/rc.local is the
root-permission requirement (ViciDial's AGI/CDR/log files expect Asterisk
running as root) — but that doesn't actually force the screen-over-systemd
tradeoff; a unit file can set `User=root` just as easily and keep every
current permission assumption intact.

The real cost is migration risk on a live production box: it changes *how
the process starts*, not what Asterisk itself does, so it's much lower-risk
than the Asterisk-20 version decision above — but it still needs a real
maintenance window, a tested unit file (`ExecStart` matching the current
`start_asterisk_boot.pl` invocation, `User=root`, a sane `Restart=` policy),
and a rollback path, not an ad-hoc swap mid-session. Treat as its own small,
deliberately scheduled item — don't bundle it into the Asterisk-20 migration
decision even though both touch the same box's Asterisk startup.

---

## Recommended next steps

1. ~~Re-run version/module checks on both boxes fresh~~ — done 2026-07-20, see
   the correction above. Re-verify again if picking this doc back up later.
2. ~~Decide on the Part 4 deployment-mechanism change~~ — done 2026-07-20.
3. ~~Merge the low-risk `pjsip-fail2ban-hardening` work~~ — done 2026-07-20;
   branch merged (9/10 commits) and deleted.
4. Treat the Oliver Asterisk-20 migration as its own separate, deliberately
   scheduled project — not a follow-on to tonight's session. If picked up,
   start with the patched-20 build test (3 vici patches, disposable VM)
   rather than assuming `441cf78`'s unpatched approach is the only option.
5. ~~Independently confirm CVS's `asterisk.service` finding~~ — done
   2026-07-22, see section 4. Also treat the Oliver
   screen/rc.local → systemd migration (open decision 3) as its own
   separate, deliberately scheduled item, same caution as the Asterisk-20
   migration — don't bundle the two even though both touch Asterisk startup
   on the same box.
