# Ecosystem Overview

This is the doc `ARCHITECTURE_VISION.md` should have been from the start —
that one covered a single repo's internal direction. This one is the map of
everything: which projects exist, how they relate, and what's actually
running where. Update this as things change; it goes stale the moment a repo
gets renamed or a server gets rebuilt, same as everything else in this family
of docs.

**Status as of 2026-07-20.**

---

## The projects

| Project | Visibility | What it is |
|---|---|---|
| [`vicidial-rocky10`](https://github.com/FrancoSmash73/vicidial-rocky10) | Private | Current production reference: Rocky Linux 10 + Asterisk (18.21.0-vici today, moving toward 20/PJSIP-only via the `pjsip-fail2ban-hardening` branch). Hosts this doc and `ARCHITECTURE_VISION.md`. |
| [`vicidial-installer`](https://github.com/FrancoSmash73/vicidial-installer) | Private | Separate installer lineage: Asterisk 20 + chan_sip. Originally the designated "future builds" target. Had a leaked-then-rotated DB credential in git history, since made private. |
| [`Hulk-`](https://github.com/FrancoSmash73/Hulk-) | Public | The actual HulkPhone WebRTC softphone source — the agent-facing browser dialer embedded in ViciDial's UI. Consumed the same way everywhere as of 2026-07-20: a **live git clone** left in place at `/var/www/html/hulkphone` on CVS, Oliver, and (now) `vicidial-rocky10`'s Part 4 installer — no more vendored static snapshot anywhere. `configs/hulkphone/` (the old vendored copy, which had already gone ~2 months stale once) was deleted from `vicidial-rocky10` the same day. See `CVS_OLIVER_DIVERGENCE.md`. |
| [`vicidial-skin`](https://github.com/FrancoSmash73/vicidial-skin) | Private | Dark-theme skin/theming for ViciDial's admin and agent panels on CVS. Currently on Step 9 (Polish & Refinement) per its own project notes. |
| `AI-AMD-project` | *(visibility TBD)* | Self-hosted ML classifier replacing ViciDial's native heuristic AMD, across both dialers (CVS + Oliver). 4-class output (HUMAN/MACHINE/**CALLGUARD**/UNCERTAIN) — CALLGUARD is the standout addition, handling call-screening services (iOS Call Screening, Google Call Screen, carrier filters) that stock binary AMD mishandles. Audio never leaves the private network. AudioSocket/EAGI integration with Asterisk; TensorFlow/Keras classifier (YAMNet transfer learning) exported to TFLite/ONNX for CPU inference; deployed on a parallel test extension so it never touches the live 8369/8373/8375 AMD lines. Phased rollout (Phase 0 baseline measurement → Phase 4 full deployment across both dialers); brief dated 2026-07-10, v2. |
| [`vicidial-dynportal`](https://github.com/FrancoSmash73/vicidial-dynportal) | Public | Self-service web portal (`valid8.php`) letting remote agents whitelist their own dynamic IP without admin intervention. Agents log in with ViciDial credentials; their public IP gets written to the `ViciWhite` list in `vicidial_ip_list_entries`, which VB-firewall's cron picks up into firewalld's `dynamiclist` ipset within ~60s. Reads DB credentials straight from `/etc/astguiclient.conf` — no separate config needed. Runs on its own SSL-only port (446, with an HTTP→HTTPS redirect listener on 81). |

---

## Servers

| Server | Role | Key facts |
|---|---|---|
| **CVS** (campaignvoiceservices) | Internal/reference server | Asterisk 20, PJSIP-only, validated via HulkPhone (real WebRTC registration + test calls). Home of the skin project. Where `vicidial-installer` was found checked out locally. |
| **Oliver** (dialengine.ddns.net) | Second production server | Asterisk 18.21.0-vici, also PJSIP-only — chan_sip fully removed 2026-07-09 (noloaded, 0 SIP phones, dialplan regenerated, udp/5060 closed; re-verified live 2026-07-20). Live HulkPhone git-clone deployment with its own hardening layer. Had 9 months of real, unpushed fixes recovered from a broken git-credentials file. |

---

## How the pieces fit together

```
                    ┌─────────────────────────┐
                    │   vicidial-rocky10 /     │   ← OS + Asterisk + ViciDial
                    │   vicidial-installer     │     core layer (two competing
                    │   (installer scripts)    │     lineages, see repo notes)
                    └───────────┬─────────────┘
                                │ deploys
                    ┌───────────▼─────────────┐
                    │         Hulk-            │   ← agent-facing webphone,
                    │   (HulkPhone webphone)    │     embedded in ViciDial's UI
                    └───────────┬─────────────┘
                                │ rendered inside
                    ┌───────────▼─────────────┐
                    │      vicidial-skin       │   ← visual theme layer over
                    │   (admin/agent theming)   │     ViciDial's own admin panel
                    └──────────────────────────┘

     ┌──────────────────────────┐
     │      AI-AMD-project       │  ← independent layer: an AudioSocket/EAGI
     │  (ML-based AMD classifier)│    tap on the Asterisk call leg itself,
     └──────────────────────────┘    parallel to (not routed through) HulkPhone
                                      or the skin/theming layer above

     ┌──────────────────────────┐
     │    vicidial-dynportal     │  ← access-control layer: agents self-serve
     │  (agent IP whitelisting)  │    firewall access BEFORE they ever reach
     └──────────────────────────┘    the dialer/webphone/admin UI above
```

---

## Open threads across the whole ecosystem

- Oliver → Asterisk 20 migration decision (see `CVS_OLIVER_DIVERGENCE.md`) —
  deliberately deferred, needs its own planned session.
- ~~`vicidial-rocky10` Part 4 HulkPhone deployment mechanism~~ — **done,
  2026-07-20**: implemented (git-clone in place + hardening, matching
  Oliver's proven approach), verified in an isolated test, run for real
  against both CVS and Oliver with no lingering issues, and the old
  `configs/hulkphone/` vendored copy deleted outright. See
  `CVS_OLIVER_DIVERGENCE.md`. Nothing open on this thread anymore.
- `pjsip-fail2ban-hardening` branch — validated, cleaned up, ready for a real
  merge review into `main`.
- `vicidial-installer`'s leaked-credential git history — repo is private now
  and the credential's dead, so this is optional cleanup (`git filter-repo`/
  BFG), not urgent.
- `AI-AMD-project` is currently at Phase 0/1 per its own brief (baseline
  measurement / shadow mode) — worth a status check next time it comes up.
