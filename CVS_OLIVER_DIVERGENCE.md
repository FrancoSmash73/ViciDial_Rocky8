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

### 2. HulkPhone deployment mechanism

| | `vicidial-rocky10` Part 4 script | Oliver (live) |
|---|---|---|
| Method | Copies a **vendored static snapshot** at `configs/hulkphone/` | **Live `git clone`** of `github.com/FrancoSmash73/Hulk-` |
| Currency | Confirmed ~2 months stale (May 9 snapshot vs. Hulk-'s July 9 tip) — missing 6 real upstream fixes, including a ring-before-answer behavior change and a tab-flash notification feature | Current, plus a `deploy/` hardening layer not present anywhere in the vendored copy: `deny-git.conf`, `hulkphone-noindex.conf`, a fail2ban loopback exemption, and a `verify.sh` health check (confirmed 8/8 passing against `wss://dialengine.ddns.net:8089/ws`) |

The vendored copy went stale because there's no mechanism keeping it in sync
with the real repo — every fix landed on Oliver (or wherever it was actually
developed) never flows back into what Part 4 ships to a fresh install.

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

**2. Change Part 4 to deploy HulkPhone via git-clone instead of vendoring?**
This one's lower-stakes and the evidence already points one way: Oliver's
approach is proven (8/8 verify checks) and self-updating in a way the
vendored copy structurally can't be. Recommend adopting it — port
`deploy/verify.sh` and the three hardening configs into Part 4 as the new
standard, and drop the static `configs/hulkphone/` vendoring once that's done.

---

## Recommended next steps

1. ~~Re-run version/module checks on both boxes fresh~~ — done 2026-07-20, see
   the correction above. Re-verify again if picking this doc back up later.
2. Decide on the Part 4 deployment-mechanism change (lower risk, do this first).
3. Treat the Oliver Asterisk-20 migration as its own separate, deliberately
   scheduled project — not a follow-on to tonight's session.
