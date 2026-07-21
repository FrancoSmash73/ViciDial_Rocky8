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

**2. ~~Change Part 4 to deploy HulkPhone via git-clone instead of vendoring?~~**
Implemented and run for real on both CVS and Oliver, 2026-07-20 — see the
RESOLVED note above. **`configs/hulkphone/` dropped entirely, same day** —
it had no sync mechanism (already drifted ~2 months stale once) and only
covered a fully-offline-during-Part-4 scenario that Parts 1/2 wouldn't have
survived to reach anyway. The offline fallback now deploys a shell that's
honest about not working (both `<script>`/`<link>` tags 404) instead of a
vendored copy that silently rots.

---

## Recommended next steps

1. ~~Re-run version/module checks on both boxes fresh~~ — done 2026-07-20, see
   the correction above. Re-verify again if picking this doc back up later.
2. Decide on the Part 4 deployment-mechanism change (lower risk, do this first).
3. Treat the Oliver Asterisk-20 migration as its own separate, deliberately
   scheduled project — not a follow-on to tonight's session.
