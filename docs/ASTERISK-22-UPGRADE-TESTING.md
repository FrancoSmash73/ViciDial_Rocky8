# Asterisk 20.18.2 → 22.11.0 Upgrade Testing Plan

**Status:** Not started — waiting on a brand-new server/installation for staging.
Do not run this against `campaignvoiceservices.com` (production) or as a VM/container
on that box — it's the live PBX with only ~282MB RAM free out of 3.5GB total.

---

## Why we're doing this

- Asterisk 20.x (current, LTS) full support ends **2026-10-19**; security-only after that
  until 2027-10-19. Need to be off it or have a plan before then.
- Asterisk 22.x is the current LTS: full support to **2028-10-16**, security to 2029-10-16.
  (Not a short-term release — some old forum posts claim otherwise, that's stale/wrong;
  confirmed against docs.asterisk.org.)
- Triggered by reading https://www.asterisk.org/manager-event-queueing-improvement/ —
  AMI moved from one shared linked-list of manager events to **per-session queues**
  (alert-pipe wakeup, earlier event filtering, ~30-40% cut in manager taskprocessor queue
  depth). Confirmed in the **22.11.0 changelog** ("manager: Move away from shared linked
  list for events") — this is already backported into 22.11.0, not master/23-only.
  Relevant to us because astguiclient's Perl daemons + the realtime agent screen are
  heavy, long-lived AMI consumers.

## Why this box is a good candidate (already de-risked)

- **chan_sip is fully unloaded already** (`module show like chan_sip` → 0 modules loaded).
  chan_sip's removal (Asterisk 21+) is the single biggest historical ViciDial/Asterisk
  breakage, and we're already PJSIP-only for both WebRTC agent endpoints and carrier
  trunks (see `PJSIP-VICIDIAL-BUILD-GUIDE.md`).
- The running `asterisk-20.18.2` source tree has **no C-level patches applied** (no git,
  no `.orig` files). The "ViciDial-patched Asterisk" language in the old install scripts
  refers to a legacy Asterisk-18-era chan_sip patch set from download.vicidial.com that
  doesn't apply to our PJSIP-based setup.
- Our real ViciDial-specific patches are application-layer and Asterisk-version-independent:
  `Asterisk::AGI.pm` empty `survey_dtmf_digits` fix, and agi-bin script patches. These just
  need reapplying post-install, same as any fresh build.
- `app_meetme.so` (used by 2 dialplan entries — agent whisper/monitor, `extensions-vicidial.conf`
  lines ~98-99, ~123) was slated for removal in 21, that plan was walked back
  (ASTERISK-29548), and it's confirmed still shipping in 22.x. Won't break on this upgrade,
  but no committed removal date exists anymore either — worth migrating those 2 entries to
  the `extras/ConfBridge/` variant already in `astguiclient/trunk` at some point, not urgent.
- Nothing in astguiclient references the now-removed `manager show eventq` CLI command
  (grepped `astguiclient/trunk` — no hits). Non-issue.

## Open/unverified items to check ON the new box

- PJSIP moved from threadpool API to taskpool API in 22.0 — internal detail, shouldn't need
  config changes, but verify PJSIP registration behavior under load anyway.
- No official ViciDial project statement endorsing Asterisk 22 yet (their ViciBox ISO still
  defaults to 18) — we're ahead of the "officially validated" curve, consistent with how
  this box already runs (hand-rolled PJSIP on 20.18.2), not a new category of risk, but
  means no upstream test suite to lean on.
- IAX2: `chan_iax2.so` is loaded on the current box (confirmed core-supported in 22) —
  confirm still needed/used before or after the move.

---

## Staging setup (when the new server exists)

1. Provision the new server (OS: match current, Rocky Linux 10).
2. Build using the same pipeline already proven on production:
   - `vicidial_rocky10_part1_install.sh` → `part4_webrtc.sh`
   - `PJSIP-VICIDIAL-BUILD-GUIDE.md` for the PJSIP-specific config (chan_sip noload,
     transport, WebRTC, carrier trunks, ConfBridge)
   - Pull Asterisk **22.11.0** source instead of 20.18.2 in the build step.
3. Reapply application-layer patches: `Asterisk::AGI.pm` empty-digits fix, agi-bin patches
   (see `vicidial_rocky10_part2_install.sh` "PATCH: Asterisk::AGI.pm" section for the
   exact steps/verification lines).
4. Point staging at a **copy** of the production DB (or a scratch DB with one test
   campaign) — never the live schema.

## Test checklist before any cutover

- [ ] Compile clean, `core show version` reports 22.11.0
- [ ] `module show like chan_sip` → 0 (confirm still unloaded — noload line carries over)
- [ ] `module show like app_meetme` and `app_confbridge` → both load
- [ ] `module show like chan_iax2` → loads if still needed
- [ ] PJSIP carrier trunk registers and holds registration
- [ ] PJSIP WebRTC (HulkPhone) registers over wss
- [ ] AMI: astguiclient connects, Originate-based dialing works
- [ ] AMI: queue events (AgentCalled/QueueMemberStatus/etc.) correctly drive the live
      agent screen
- [ ] MeetMe whisper/barge dialplan entries still function
- [ ] websocket_enabled=false still set in sip.conf (the chan_sip/res_pjsip websocket
      subprotocol conflict documented in `vicidial-rocky10/CLAUDE.md` — should be moot
      with chan_sip unloaded, but verify)
- [ ] Load/soak test AMI under realistic event volume — this is the thing the 22.11.0
      per-session-queue change is supposed to help with; worth actually measuring
      manager taskprocessor queue depth / load average before vs after if possible
- [ ] Run for a period on a low-traffic/test campaign before moving real agents over

---
*Created 2026-09-02, continuing conversation about upgrading from Asterisk 20.18.2 to
22.11.0 for the campaignvoiceservices.com ViciDial deployment.*
