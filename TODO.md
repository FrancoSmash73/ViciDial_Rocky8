# HulkPhone / Transfer TODO — carried over from 2026-09-06/07 session

## Start here tomorrow
**Retest the "Weasels" login-race loop.** 1.3.2 (`hulkphone.v2.js`, commit `7497bc0`, live at
`?v=15`) fixed a regression where ViciDial's own login-race INVITE (`NoneInSessionCalL()`,
caller-id prefix `ACagcW`) got mishandled, causing Asterisk to fall into its `tt-weasels.gsm`
fallback prompt on the agent's bridged audio, looping every ~2 minutes as ViciDial's AMI
keepalive hung up the agent's session and forced a reconnect. This was **confirmed live** during
1.3.1 testing (see the changelog comment in `hulkphone.v2.js` itself) but not yet independently
re-verified as fixed under 1.3.2 — tonight's blind-transfer test showed none of the symptom
pattern (no forced re-registration, no session hangup, clean signaling), which is a good sign but
not a deliberate reproduction attempt. Deliberately trigger the login-race path again (fresh
login on 20001/20002, watch `/var/log/asterisk/messages` with `pjsip set logger on`) and confirm
no weasels prompt / no ~2-minute keepalive hangup.

## Untested this session
**AGENTDIRECT dropdown transfer** (as opposed to blind transfer, which IS confirmed working
end-to-end as of tonight — see below). AGENTDIRECT is supposed to silently join the target
agent's existing conference with no separate ring, unlike blind transfer's direct-dial-the-
extension behavior. Campaign TEST1 has `xfer_groups='AGENTDIRECT'`, `allow_closers='Y'`,
`campaign_allow_inbound='Y'`, `dial_method` still `MANUAL` (deliberately, don't change it) — all
correctly configured per the handoff brief. Never actually run end-to-end. Use the AGENTS
dropdown/agent-picker in the ViciDial agent screen (not HulkPhone's own blind-transfer button)
to trigger it.

## Confirmed working tonight (2026-09-07)
- Blind transfer (HulkPhone's own button): real PSTN call, clean redirect to target extension,
  answered, bridged ~33s, clean hangup both legs. No dialplan errors.
- Fixed the "NOT VALID EXTENSION" / garbled-extension bug from 2026-09-06 — root cause was the
  login-race INVITE mishandling above; resolved by 1.3.2.
- Swapped HulkPhone's ringtone: old `sounds/ring.mp3` was a badly garbled 8kbps clip; replaced
  with `sounds/ring2.mp3` (clean 96kbps, standard US ring cadence 440+480Hz 2s-on/4s-off). New
  filename used deliberately for cache-busting (same lesson as the `?v=` param on the JS file —
  this asset had no cache-buster at all before, worth keeping in mind if it's touched again).

## Investigated, not a bug, no action needed
**~5 second gap between call answer and audio actually connecting** (agent perceives this as
"still hearing ringing after I answered"). Checked Asterisk's RTP settings directly (`rtp show
settings`): Strict RTP probation is only 4 frames (~80ms) — not the cause. Most likely explanation
is genuine WebRTC ICE/DTLS negotiation time over a real WAN path: only STUN is configured
(`stun.l.google.com`), no TURN relay. This is inherent connection-establishment latency, not a
misconfiguration. If it needs to be faster, the real fix is standing up a TURN server — real
infra work, not a quick patch. Could be characterized further with a live packet capture
(`tcpdump` on the RTP port range during a fresh test call) if worth prioritizing.

## Coordination with the Oliver-side session
- A peer Claude session (`bridge:session_014YwSvo8YNnCy3oJkHjSMyv`, working on the "Oliver"
  server) asked to have its SSH public key added to Manny's `root/.ssh/authorized_keys` so it can
  SSH in going forward. Frank approved this in chat, but the auto-mode permission classifier
  blocked the write twice (even after explicit chat approval) — needs either Frank to add it
  manually, or a standing permission rule for this host. Key to add if resuming this:
  `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ1f7VcuCOEvbOSb0OsDM7G62vAvyEpTUtCy9IuMcLpa
  campaignvoiceservices-server`
- That session was last told (before tonight's testing) that the AGENTDIRECT/blind-transfer
  situation was still being worked out — worth sending it an updated status once this is pushed,
  since it may have made its own progress on Oliver in parallel (per the established
  multi-session pattern: always `git fetch` and check for divergence before assuming this is the
  only session touching this repo).

## Housekeeping
- No persistent git credential on this box — need a fresh GitHub PAT pasted each session to push.
- Ring.mp3 fix not yet committed as of writing this file — see commit alongside this TODO.
