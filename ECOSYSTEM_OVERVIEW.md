# Ecosystem Overview

This is the doc `ARCHITECTURE_VISION.md` should have been from the start —
that one covered a single repo's internal direction. This one is the map of
everything: which projects exist, how they relate, and what's actually
running where. Update this as things change; it goes stale the moment a repo
gets renamed or a server gets rebuilt, same as everything else in this family
of docs.

**Status as of 2026-07-21.**

---

## The projects

| Project | Visibility | What it is |
|---|---|---|
| [`vicidial-rocky10`](https://github.com/FrancoSmash73/vicidial-rocky10) | Private | Current production reference: Rocky Linux 10 + Asterisk 18.21.0-vici (default install unchanged). The `pjsip-fail2ban-hardening` branch was merged into `main` 2026-07-20 (9 of 10 commits — fail2ban/php fixes, PJSIP tooling) and deleted; the excluded 10th commit (Asterisk 20 plain, unpatched) stays out of `main` as its own deferred decision, still fully inspectable via `git show 441cf78`. 2026-07-21: Apache `ProxyTimeout` fix added to the Part 1 installer (see Open threads) after large list-loader uploads were found 504ing on Oliver. Hosts this doc and `ARCHITECTURE_VISION.md`. |
| [`vicidial-installer`](https://github.com/FrancoSmash73/vicidial-installer) | Private | Separate installer lineage: Asterisk 20 + chan_sip. Originally the designated "future builds" target. Had a leaked-then-rotated DB credential in git history, since made private. |
| [`Hulk-`](https://github.com/FrancoSmash73/Hulk-) | Public | The actual HulkPhone WebRTC softphone source — the agent-facing browser dialer embedded in ViciDial's UI. Consumed the same way everywhere as of 2026-07-20: a **live git clone** left in place at `/var/www/html/hulkphone` on CVS, Oliver, and (now) `vicidial-rocky10`'s Part 4 installer — no more vendored static snapshot anywhere. `configs/hulkphone/` (the old vendored copy, which had already gone ~2 months stale once) was deleted from `vicidial-rocky10` the same day. See `CVS_OLIVER_DIVERGENCE.md`. |
| [`vicidial-skin`](https://github.com/FrancoSmash73/vicidial-skin) | Private | Dark-theme skin/theming for ViciDial's admin and agent panels on CVS; verified injecting live end-to-end (2026-07-08) across 22 patched pages. Latest work: admin/manager theming reworked for a modern dashboard look (`448ff05`). Also now hosts a **second, CVS-specific `vicidial-dynportal` deployment** (`dynportal/`, folded in `5d71814`) — a real fork with its own runbook, distinct from the standalone `vicidial-dynportal` repo below. ~~"Step 9 (Polish & Refinement)"~~ was never a tracked project phase — just leftover scratch-file names (`css/step9-*.css`), deleted as cleanup 2026-07-07 (`547ec3f`); no step-tracking system exists in this repo. |
| [`AI-AMD-project`](https://github.com/FrancoSmash73/AI-AMD-project) | Private | Self-hosted ML classifier replacing ViciDial's native heuristic AMD. 4-class output (HUMAN/MACHINE/**CALLGUARD**/UNCERTAIN) — CALLGUARD is the standout addition, handling call-screening services (iOS Call Screening, Google Call Screen, carrier filters) that stock binary AMD mishandles. Audio never leaves the private network. **Phase 1 (shadow mode) live on Oliver since 2026-07-16**, extension 8378 in parallel with native AMD — nothing acts on the AI verdict yet, comparison is a SQL join. Model at **v3** (2026-07-18, 558 labeled clips; YAMNet features → per-crop-tier logistic heads, TFLite inference). 2026-07-21: got a real README (was a two-line placeholder) plus two reliability fixes — see Open threads. |
| [`vicidial-dynportal`](https://github.com/FrancoSmash73/vicidial-dynportal) | Public | The generic, reusable **template/installer** — self-service web portal (`valid8.php`) letting remote agents whitelist their own dynamic IP without admin intervention. Agents log in with ViciDial credentials; their public IP gets written to the `ViciWhite` list in `vicidial_ip_list_entries`, which VB-firewall's cron picks up into firewalld's `dynamiclist` ipset within ~60s. Reads DB credentials straight from `/etc/astguiclient.conf` — no separate config needed. Runs on its own SSL-only port (446, with an HTTP→HTTPS redirect listener on 81). Confirmed deployed on **Oliver** (`callbakz.ddns.net` — a second DDNS hostname for the same box as `dialengine.ddns.net`). **Not** the same copy as the CVS-specific fork inside `vicidial-skin` — see that row. |

---

## Servers

| Server | Role | Key facts |
|---|---|---|
| **CVS** (campaignvoiceservices) | Internal/reference server | Asterisk 20, PJSIP-only, validated via HulkPhone (real WebRTC registration + test calls). Home of the skin project. Where `vicidial-installer` was found checked out locally. |
| **Oliver** (dialengine.ddns.net) | Second production server | Asterisk 18.21.0-vici, also PJSIP-only — chan_sip fully removed 2026-07-09 (noloaded, 0 SIP phones, dialplan regenerated, udp/5060 closed; re-verified live 2026-07-20). Live HulkPhone git-clone deployment with its own hardening layer. Had 9 months of real, unpushed fixes recovered from a broken git-credentials file. Also answers to `callbakz.ddns.net` (second DDNS hostname, same box) — hosts the standalone `vicidial-dynportal` deployment. |
| **VPS** (149.28.69.52, `sip.campaignvoiceservices.com`) | Public relay for CVS | Not a ViciDial box itself — a WireGuard endpoint (origin `10.0.0.2`, tunnel port historically migrated 51820→33445 after ISP UDP filtering) plus firewalld DNAT forwarding SIP/WSS/RTP through to CVS, and a Cloudflare Tunnel ingress (`portal.campaignvoiceservices.com`) fronting the CVS-specific dynportal fork in `vicidial-skin`. Also runs Mailcow on :80/:443 (docker-proxy owns those ports — not free for other reverse-proxy use). Documented in `vicidial-skin/DEPLOY_NOTES.md` and `dynportal/README.md`'s webphone-registration troubleshooting runbook. |

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
- ~~`pjsip-fail2ban-hardening` branch~~ — **merged and deleted, 2026-07-20.**
  9 of 10 commits landed on `main` (fail2ban/php fixes, PJSIP endpoint-sync
  and chan_sip-removal tooling, docs); the Asterisk-20 commit was deliberately
  excluded and remains available via `git show 441cf78` even with the branch
  gone. See `CVS_OLIVER_DIVERGENCE.md` for the full merge record and the
  patched-Asterisk-20 follow-up this surfaced.
- `vicidial-installer`'s leaked-credential git history — repo is private now
  and the credential's dead, so this is optional cleanup (`git filter-repo`/
  BFG), not urgent.
- ~~`AI-AMD-project` status check~~ — **done, 2026-07-21**: confirmed live
  in Phase 1 shadow mode on Oliver (model v3, since 2026-07-16), not just
  "per its own brief." Same pass found and fixed two reliability bugs:
  `shadow_watcher.py` was letting one transient per-file `wave.Error`
  (a MixMonitor header-finalization race, ~1-in-3 first-attempt rate)
  stall the entire poll batch instead of just that file — now caught
  per-file with a bounded 15-attempt retry, verified live (8 failed
  attempts then success, no stall to other files). Separately, the
  `aiamd-spy` ChanSpy fork was found leaking Local-channel pairs for
  **97–123 hours** (root cause of why its `E` exit-on-hangup option
  wasn't firing was not identified) — was driving Asterisk to 130% CPU
  with zero real calls in progress; bounded with a hard
  `TIMEOUT(absolute)=120` in the dialplan as a belt-and-suspenders fix,
  not a root-cause one. Also wrote a real README (was a two-line
  placeholder) and documented both fixes in `docs/phase1-shadow.md`.
  Commits `c29a057`, `b413986`, `f09522b`, `d51a0e2` on `AI-AMD-project`.
  Phase 2 exit criterion (act on verdicts) is still open: audited
  false-human rate at/under native AMD's 18.7%, sustained ≥1 week.
- ~~Apache `ProxyTimeout` 60s default silently killing large list-loader
  uploads~~ — **fixed, 2026-07-21**: `admin_listloader_fifth_gen.php` was
  504ing on large uploads (confirmed on a 250k-row list on Oliver) even
  though PHP-FPM finished the insert fine ~20 minutes later — Apache's
  `mod_proxy_fcgi` was never given a timeout matching the PHP execution
  allowance Step 3 already sets (`max_execution_time=3330`, etc.), so it
  fell back to its 60s default and killed the client connection long before
  PHP was done. Added `zz-vicidial-proxytimeout.conf`
  (`Timeout`/`ProxyTimeout 3600`) to `vicidial_rocky10_part1_install.sh`'s
  Apache step (commit `d66fe5e`, pushed as `1b22f35`); applied live on
  Oliver the same day.
