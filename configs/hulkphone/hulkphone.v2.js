/**
 * HulkPhone.js — SIP.js WebRTC Core
 * Version: 1.3.2
 *
 * Architecture:
 *   - Uses SIP.js 0.20.x SimpleUser (high-level API) for the primary call
 *   - Registers with Asterisk via WebSocket (wss), with auto-reconnect
 *   - Auto-calls conference extension on registration (ViciDial pattern) —
 *     also re-fires after a reconnect, to rejoin the conference automatically
 *   - Full DTMF, Mute, Hold support; real Blind and Warm transfer via
 *     Session.refer() (a second, manually-managed SIP.Inviter for the warm
 *     consult leg, since SimpleUser only ever tracks one session)
 *   - Timer, status, and ViciDial parent window communication
 *
 * 1.2.0 changes:
 *   - Fixed the intermittent "registers fine but agent hears no audio" race:
 *     ViciDial's own vicidial.php independently Originates a call into the
 *     SAME conference extension on agent login (its classic ring-a-hardphone-
 *     into-the-conference mechanism — confirmed live via vicidial_manager and
 *     Asterisk's pjsip logger), racing our own placeCall(CFG.conf_exten).
 *     SimpleUser only tracks one Session at a time: whichever INVITE claims
 *     it first wins. If ours wins (the common case), the second INVITE just
 *     hits SimpleUser's built-in clean reject path — harmless. If ViciDial's
 *     wins, our own placeCall() used to fail outright with "Session already
 *     exists" and silently give up, leaving the agent registered but never
 *     actually joined to the conference (no error the agent would notice —
 *     exactly the reported symptom). Fix: treat losing that race as another
 *     way of *winning* it — answering ViciDial's Originate joins the same
 *     conference, so the first incoming call before we've joined this
 *     registration cycle (confJoined) is now auto-answered like the existing
 *     from === CFG.conf_exten case, and placeCall() no longer surfaces
 *     "CALL FAILED" for the resulting harmless double-join race with itself.
 *     Also shortened the post-register dial delay (800ms → 150ms) to shrink
 *     the window in which ViciDial's Originate can win in the first place.
 *
 * 1.3.2 changes:
 *   - 1.3.1's confJoined timing gate wasn't enough: leaving the login-race
 *     INVITE (ViciDial's own vicidial.php NoneInSessionCalL() mechanism,
 *     see below) ringing unanswered turned out to be actively destructive,
 *     not just harmless — confirmed live: about 2 minutes after the base
 *     call joined the conference normally, ViciDial's own AMI ('sendcron')
 *     hung up the agent's entire working session, almost certainly a
 *     keepalive/health-check reacting to the stuck unanswered ringing
 *     channel — which then forced a reconnect, re-registration, and hit
 *     the same race again, looping ("Weasels" fallback prompt on repeat).
 *     Timing (confJoined) can't reliably tell "our own login mechanism"
 *     apart from "a real transfer" — both can arrive in either window.
 *     Fix: identify it directly instead, by caller-identity rather than
 *     timing. vicidial.php's NoneInSessionCalL() (the classic "ring agent
 *     into conference on login" JS, confirmed at vicidial.php:19066) always
 *     builds its Originate's caller-id as `"ACagcW" + epoch_sec + user_abb`
 *     — a stable, hardcoded prefix specific to that one mechanism, never
 *     used by an AGENTDIRECT transfer's Dial(). Any INVITE whose From
 *     carries that prefix is now always silently absorbed (auto-answered
 *     if we haven't joined our conference yet, cleanly declined if we
 *     already have — i.e. exactly v1.2.0's original behavior, unconditional
 *     on timing) — regardless of confJoined. Only an INVITE WITHOUT that
 *     prefix, arriving after confJoined, is treated as a genuine transfer.
 *
 * 1.3.1 changes:
 *   - Fixed a regression 1.3.0 introduced into the exact race 1.2.0 fixed:
 *     the onInvite interception gated on `ua.session` (truthy the instant
 *     placeCall() is called, before the call is answered), not `confJoined`
 *     (true only once it's answered) — so a redundant login-race INVITE
 *     arriving while our own self-dial was still in flight got wrongly
 *     rung as an incoming transfer instead of being absorbed the 1.2.0 way.
 *     Confirmed live: 20002 looped on Asterisk's "Weasels" fallback prompt
 *     on every login. Gate is now confJoined, see init() for the reasoning.
 *
 * 1.3.0 changes:
 *   - AGENTDIRECT transfers (now working server-side end to end) were still
 *     silently failing client-side: agi-VDAD_ALL_inbound.agi's real routing
 *     is a plain Dial() straight to the target agent's raw extension, but
 *     SimpleUser only ever tracks one Session and rejects any INVITE that
 *     arrives while one already exists — confirmed against the vendored
 *     sip.js source, this rejection happens at the UserAgent level, before
 *     onCallReceived is even called, so there was no delegate hook to react
 *     to it. The transferring call would ring briefly then drop to voicemail
 *     with the target agent never seeing anything.
 *     Fix: intercept ua.userAgent.delegate.onInvite directly (see init())
 *     to catch this specific case — a second INVITE while ua.session is
 *     already occupied — and ring the agent for it exactly like a normal
 *     incoming call (handleIncomingTransfer/answerTransfer/declineTransfer),
 *     rather than auto-answering it. Deliberately NOT an automatic swap:
 *     stray/duplicate INVITEs are a real, observed phenomenon in this
 *     system (it's what the 1.2.0 registration-race fix works around), so
 *     auto-answering any second call with no confirmation would risk
 *     silently dropping a live customer call with zero warning if a false
 *     positive ever occurred. The agent explicitly answers to accept the
 *     transfer (which then hangs up their base call first) or hangs up to
 *     decline it (their base call is left untouched). After a transfer
 *     call ends, automatically re-joins CFG.conf_exten (same as after
 *     registering) so the agent isn't left with no active call at all.
 *
 * 1.1.0 changes:
 *   - Fixed blind transfer: old code called ua.refer(), which doesn't exist
 *     on SimpleUser — every blind transfer attempt threw immediately.
 *   - Fixed warm transfer: old code called placeCall() for the consult leg,
 *     which SimpleUser rejects outright ("Session already exists") since it
 *     only tracks one session, held or not — the consult call never actually
 *     dialed. Now uses a manually-managed second Session plus REFER-with-
 *     Replaces to complete the transfer.
 *   - Added reconnectionAttempts/reconnectionDelay so a dropped WebSocket
 *     recovers automatically instead of leaving the agent stuck unregistered.
 *   - Removed attachSessionHandlers()/connectRemoteAudio() — dead code, never
 *     called (SimpleUser already attaches the primary call's remote audio via
 *     the media.remote.audio config).
 *
 * ViciDial Integration Notes:
 *   ViciDial opens this phone in a popup window, passing credentials
 *   as URL parameters. When the phone registers and auto-calls the
 *   conference extension, the agent is joined to the call conference.
 *   This mirrors the behavior of ViciPhone / CyburPhone.
 */

(function(window, document) {
    'use strict';

    // ── Safety: ensure SIP.js is loaded ──────────────────────────
    if (typeof SIP === 'undefined') {
        console.error('HulkPhone: SIP.js not loaded!');
        return;
    }

    const CFG = window.HP_CONFIG || {};

    // Shared mic constraints for every session this UserAgent originates —
    // the primary call (via simpleUserOptions.media below) and any warm-transfer
    // consult leg (via warmTransfer's Inviter), so they don't drift apart.
    const AUDIO_CONSTRAINTS = {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl:  true,
    };

    // ── DOM Refs ─────────────────────────────────────────────────
    const $ = id => document.getElementById(id);

    const UI = {
        statusDot:   $('hp-status-dot'),
        statusText:  $('hp-status-text'),
        dialInput:   $('hp-dial-input'),
        callBtn:     $('hp-call-btn'),
        callLabel:   $('hp-call-label'),
        muteBtn:     $('hp-mute-btn'),
        muteLabel:   $('hp-mute-label'),
        holdBtn:     $('hp-hold-btn'),
        holdLabel:   $('hp-hold-label'),
        xferInput:   $('hp-xfer-input'),
        timer:       $('hp-timer'),
        remoteAudio: $('hp-remote-audio'),
        ringAudio:   $('hp-ring-audio'),
        volume:      $('hp-volume'),
        wrapper:     $('hulkphone-wrapper'),
    };

    // ── State ─────────────────────────────────────────────────────
    let ua            = null;   // SIP UserAgent
    let session       = null;   // Active call session (Inviter | Invitation)
    let isMuted       = false;
    let isOnHold      = false;
    let callActive    = false;
    let pendingInvite = false;  // Inbound call ringing, not yet answered
    let warmXferSess  = null;   // Second (consult) leg during a warm transfer
    let warmAudioEl   = null;   // <audio> element for the consult leg's remote stream
    let timerInterval = null;
    let callSeconds   = 0;
    let hasRegisteredOnce = false; // distinguishes first REGISTER from a post-drop reconnect
    let reconnectWatchdog = null;  // fires only if SimpleUser's own retries never recover
    let confJoined = false;   // have we joined CFG.conf_exten yet this registration cycle?
    let transferPending = false;         // a second call (see handleIncomingTransfer) is ringing
    let pendingTransferInvitation = null; // its raw sip.js Invitation, outside SimpleUser's own tracking
    let inTransferCall = false;          // current call replaced the base conference leg via a transfer

    // ════════════════════════════════════════════════════════════
    //  STATUS HELPERS
    // ════════════════════════════════════════════════════════════

    const STATUS = {
        UNREG:  { dot: 'unregistered', text: CFG.lang.status_unreg,  cls: '' },
        REG:    { dot: 'registered',   text: CFG.lang.status_reg,    cls: 'registered' },
        CONN:   { dot: 'ringing',      text: CFG.lang.status_conn,   cls: 'ringing' },
        RING:   { dot: 'ringing',      text: CFG.lang.status_ring,   cls: 'ringing' },
        CALL:   { dot: 'incall',       text: CFG.lang.status_call,   cls: 'incall' },
        HOLD:   { dot: 'onhold',       text: CFG.lang.status_hold,   cls: 'onhold' },
    };

    function setStatus(key) {
        const s = STATUS[key];
        if (!s) return;
        // Dot
        UI.statusDot.className = 'status-dot ' + s.dot;
        // Text
        UI.statusText.textContent = s.text;
        UI.statusText.className = s.cls;
    }

    function toast(msg, duration) {
        duration = duration || 2000;
        let el = document.getElementById('hp-toast');
        if (!el) {
            el = document.createElement('div');
            el.id = 'hp-toast';
            document.getElementById('hulkphone-wrapper').appendChild(el);
        }
        el.textContent = msg;
        el.classList.add('show');
        clearTimeout(el._t);
        el._t = setTimeout(() => el.classList.remove('show'), duration);
    }

    // ════════════════════════════════════════════════════════════
    //  TIMER
    // ════════════════════════════════════════════════════════════

    function startTimer() {
        callSeconds = 0;
        clearInterval(timerInterval);
        timerInterval = setInterval(function() {
            callSeconds++;
            const m = Math.floor(callSeconds / 60).toString().padStart(2, '0');
            const s = (callSeconds % 60).toString().padStart(2, '0');
            UI.timer.textContent = m + ':' + s;
        }, 1000);
    }

    function stopTimer() {
        clearInterval(timerInterval);
        UI.timer.textContent = '00:00';
        callSeconds = 0;
    }

    // ════════════════════════════════════════════════════════════
    //  INCOMING CALL FLASH
    // ════════════════════════════════════════════════════════════
    //
    // Inbound calls only ring when the agent is idle (a logged-in ViciDial
    // agent holds the conference leg, so SimpleUser rejects the INVITE with
    // 486). Idle means they are almost certainly looking at something other
    // than this panel, so the signal has to leave the page: the tab title
    // blinks the caller's number and the favicon alternates green/red, which
    // a background or minimised tab shows in the taskbar.
    //
    // Inside ViciDial's iframe the parent owns the title and favicon, so those
    // writes are harmless no-ops there — and this path cannot fire in that
    // context anyway.

    const flash = {
        active:     false,
        timer:      null,
        phase:      false,
        savedTitle: '',
        link:       null,   // <link rel="icon">
        savedHref:  null,   // null when we created the element ourselves
        icons:      null,   // { green, red } data URIs, built once
    };

    function prefersReducedMotion() {
        return !!(window.matchMedia &&
                  window.matchMedia('(prefers-reduced-motion: reduce)').matches);
    }

    // 32x32 filled dot as a data URI. Built once and reused; redrawing a canvas
    // on every blink would churn a bitmap twice a second for no reason.
    function dotIcon(color) {
        const c = document.createElement('canvas');
        c.width = c.height = 32;
        const g = c.getContext('2d');
        g.beginPath();
        g.arc(16, 16, 13, 0, Math.PI * 2);
        g.fillStyle = color;
        g.fill();
        return c.toDataURL('image/png');
    }

    function faviconLink() {
        let el = document.querySelector('link[rel~="icon"]');
        if (el) {
            flash.savedHref = el.getAttribute('href');
        } else {
            el = document.createElement('link');
            el.rel = 'icon';
            document.head.appendChild(el);
            flash.savedHref = null;   // we own it; remove it on stop
        }
        return el;
    }

    function startFlash(from) {
        if (flash.active) return;
        flash.active = true;

        if (UI.wrapper) UI.wrapper.classList.add('hp-incoming');

        if (!flash.icons) {
            try {
                flash.icons = { green: dotIcon('#39ff14'), red: dotIcon('#ff2d2d') };
            } catch (e) {
                flash.icons = null;   // canvas blocked; title flash still works
            }
        }

        const label = '☎ ' + (from || 'CALL') + ' CALLING';
        flash.savedTitle = document.title;
        flash.link = flash.icons ? faviconLink() : null;

        document.title = label;
        if (flash.link) flash.link.href = flash.icons.green;

        // Reduced motion: hold the lit state. The call must still be obvious,
        // it just must not strobe.
        if (prefersReducedMotion()) {
            if (flash.link) flash.link.href = flash.icons.red;
            return;
        }

        flash.phase = false;
        flash.timer = setInterval(function() {
            flash.phase = !flash.phase;
            document.title = flash.phase ? flash.savedTitle : label;
            if (flash.link) {
                flash.link.href = flash.phase ? flash.icons.red : flash.icons.green;
            }
        }, 900);
    }

    function stopFlash() {
        if (!flash.active) return;
        flash.active = false;

        clearInterval(flash.timer);
        flash.timer = null;

        if (UI.wrapper) UI.wrapper.classList.remove('hp-incoming');
        document.title = flash.savedTitle;

        if (flash.link) {
            if (flash.savedHref === null) {
                flash.link.remove();          // we added it
            } else {
                flash.link.href = flash.savedHref;
            }
            flash.link = null;
        }
    }

    // ════════════════════════════════════════════════════════════
    //  RING AUDIO
    // ════════════════════════════════════════════════════════════

    function startRing() {
        try { UI.ringAudio.play(); } catch(e) {}
    }
    // Every path that silences the ring also ends the call's ringing state, so
    // clearing the flash here means it can never be left stuck on. Outbound
    // ringback calls startRing without startFlash; stopFlash is a no-op then.
    function stopRing() {
        try { UI.ringAudio.pause(); UI.ringAudio.currentTime = 0; } catch(e) {}
        stopFlash();
    }

    // ════════════════════════════════════════════════════════════
    //  CALL BUTTON UI
    // ════════════════════════════════════════════════════════════

    function setCallBtnCallMode() {
        callActive = true;
        UI.callBtn.classList.add('active-call');
        UI.callLabel.textContent = CFG.lang.btn_hangup;
    }

    function setCallBtnIdleMode() {
        callActive = false;
        UI.callBtn.classList.remove('active-call');
        UI.callBtn.classList.remove('answer-call');
        UI.callLabel.textContent = CFG.lang.btn_call;
    }

    function setCallBtnAnswerMode() {
        callActive = false;
        UI.callBtn.classList.remove('active-call');
        UI.callBtn.classList.add('answer-call');
        UI.callLabel.textContent = CFG.lang.btn_answer || 'ANSWER';
    }

    // ════════════════════════════════════════════════════════════
    //  CONSULT-LEG AUDIO (warm transfer)
    // ════════════════════════════════════════════════════════════
    //
    // The primary call's remote audio is attached automatically by SimpleUser
    // itself (see the `media.remote.audio` config in init()). A warm-transfer
    // consult leg is a second, independent SIP.js Session built directly against
    // the raw UserAgent (see warmTransfer below) — SimpleUser knows nothing about
    // it, so its audio has to be wired up by hand, into its own <audio> element.

    function connectWarmAudio(sess) {
        try {
            warmAudioEl = document.createElement('audio');
            warmAudioEl.autoplay = true;
            warmAudioEl.id = 'hp-warm-audio';
            document.body.appendChild(warmAudioEl);
            const remoteStream = new MediaStream();
            sess.sessionDescriptionHandler.peerConnection.getReceivers().forEach(function(receiver) {
                if (receiver.track) remoteStream.addTrack(receiver.track);
            });
            warmAudioEl.srcObject = remoteStream;
            warmAudioEl.volume = parseFloat(UI.volume.value);
        } catch(e) {
            console.warn('HulkPhone: consult audio connect error', e);
        }
    }

    function disconnectWarmAudio() {
        if (!warmAudioEl) return;
        try { warmAudioEl.srcObject = null; warmAudioEl.remove(); } catch(e) {}
        warmAudioEl = null;
    }

    // ════════════════════════════════════════════════════════════
    //  VICIDIAL PARENT WINDOW COMMUNICATION
    // ════════════════════════════════════════════════════════════

    function notifyParent(event) {
        try {
            if (window.opener && !window.opener.closed) {
                // ViciDial listens for webphone events on the opener window
                if (typeof window.opener.HulkPhoneEvent === 'function') {
                    window.opener.HulkPhoneEvent(event);
                }
                // Generic postMessage for broader compatibility
                window.opener.postMessage({ source: 'hulkphone', event: event }, '*');
            }
        } catch(e) {
            // Cross-origin — ignore
        }
    }

    // ════════════════════════════════════════════════════════════
    //  INITIALIZATION — BUILD SIP USER AGENT
    // ════════════════════════════════════════════════════════════

    function init() {
        if (!CFG.server_ip || !CFG.ext) {
            setStatus('UNREG');
            toast('No SIP credentials', 3000);
            console.warn('HulkPhone: Missing server_ip or ext in config');
            return;
        }

        const aor = 'sip:' + CFG.ext + '@' + CFG.server_ip;

        const simpleUserOptions = {
            aor: aor,
            media: {
                constraints: {
                    audio: AUDIO_CONSTRAINTS,
                    video: false,
                },
                remote: { audio: UI.remoteAudio },
            },
            // SimpleUser already retries + re-registers on its own when the
            // transport drops (see onDisconnect/attemptReconnection in sip.js);
            // it just defaults to giving up after 3 tries (~16s). Give it enough
            // runway to survive a brief Asterisk restart, not just a network blip.
            reconnectionAttempts: 20,
            reconnectionDelay: 5,
            userAgentOptions: {
                authorizationUsername: CFG.ext,
                authorizationPassword: CFG.pass,
                transportOptions: {
                    server: CFG.ws_url,
                },
                uri: SIP.UserAgent.makeURI(aor),
                displayName: CFG.callerid || CFG.ext,
                sessionDescriptionHandlerFactoryOptions: {
                    iceGatheringTimeout: 3000,      // Cap ICE gather at 3s (fixes 10-12s delay)
                    peerConnectionConfiguration: {
                        iceServers: (CFG.iceServers && CFG.iceServers.length)
                            ? CFG.iceServers
                            : [{ urls: 'stun:stun.l.google.com:19302' }],
                        iceTransportPolicy: 'all',
                        rtcpMuxPolicy: 'require',   // Required for CyburPhone compat
                    },
                },
                logLevel: 'warn',
            },
            delegate: {
                // Inbound INVITE. Note SimpleUser rejects any INVITE arriving
                // while a session already exists, so this never fires while the
                // agent holds the ViciDial conference leg — that path keeps
                // returning a clean rejection exactly as it did before.
                onCallReceived: function() {
                    const from = (ua.session && ua.session.remoteIdentity)
                        ? ua.session.remoteIdentity.uri.user : '';
                    console.log('HulkPhone: Incoming call from ' + from);

                    // A call *from* the conference extension is machine-driven,
                    // not a human calling the agent, so it still picks up on its
                    // own. Also auto-answer the first call of any kind before
                    // we've joined the conference this registration cycle: that
                    // is ViciDial's own vicidial.php independently Originating a
                    // call into this same extension on login (see placeCall()/
                    // onRegistered below) — answering it joins the conference
                    // just as our own placeCall() would have, so treat losing
                    // that race as another way of winning it rather than
                    // ringing the agent for a call nobody actually placed to
                    // them. A genuine inbound customer call can't land here —
                    // ViciDial routes those through the dialer/queue, never as
                    // a direct ring to the raw extension moments after login.
                    if (CFG.auto_answer && CFG.conf_exten && (from === CFG.conf_exten || !confJoined)) {
                        confJoined = true;
                        setStatus('RING');
                        setCallBtnCallMode();
                        try { ua.answer(); } catch(e) { console.error('HulkPhone auto-answer failed:', e); }
                        setTimeout(function() { if (ua.session) session = ua.session; }, 300);
                        return;
                    }

                    // Everything else is a person calling this extension: ring
                    // and wait for the agent, the way X-Lite/EyeBeam behave.
                    pendingInvite = true;
                    setStatus('RING');
                    startRing();
                    startFlash(from);
                    setCallBtnAnswerMode();
                    if (from) {
                        UI.dialInput.value = from;
                        toast('INCOMING: ' + from, 4000);
                    }
                    if (ua.session) session = ua.session;
                },
                onCallAnswered: function() {
                    pendingInvite = false;
                    stopRing();
                    setStatus('CALL');
                    setCallBtnCallMode();
                    startTimer();
                    if (ua.session) session = ua.session;
                },
                // Also fires when the caller gives up before the agent answers.
                onCallHangup: function() {
                    pendingInvite = false;
                    stopRing();
                    stopTimer();
                    setStatus('REG');
                    setCallBtnIdleMode();
                    session = null;
                    confJoined = false; // conference leg is gone; a later rejoin attempt shouldn't be blocked
                    endWarmTransfer(); // don't leave a consult leg dangling if the primary call ends first
                    // A transfer call replaces the base conference leg (see answerTransfer) —
                    // once it ends there's no active call left at all, so rejoin the
                    // conference the same way registration does rather than leaving the
                    // agent stranded with nothing.
                    if (inTransferCall) {
                        inTransferCall = false;
                        if (CFG.auto_answer && CFG.conf_exten) {
                            setTimeout(function() { if (!confJoined) placeCall(CFG.conf_exten); }, 150);
                        }
                    }
                },
                onRegistered: function() {
                    clearReconnectWatchdog();
                    setStatus('REG');
                    toast(hasRegisteredOnce ? 'RECONNECTED ✓' : 'REGISTERED ✓', 2000);
                    console.log('HulkPhone: Registered as ' + aor);
                    hasRegisteredOnce = true;
                    confJoined = false; // fresh registration cycle, haven't joined yet
                    // Auto-call conference extension on register (including after a
                    // reconnect — the agent's prior conference leg is gone by then,
                    // since onDisconnect above already tore down any active session).
                    // dialRegExten_enabled=1 in ViciDial suppresses NoneInSession dialog.
                    // Delay shortened from 800ms: the sooner we place this call, the
                    // more likely we claim SimpleUser's session slot before ViciDial's
                    // own redundant server-side Originate does (see onCallReceived) —
                    // though we no longer depend on winning that race either way.
                    if (CFG.auto_answer && CFG.conf_exten) {
                        console.log('HulkPhone: Auto-calling conference ' + CFG.conf_exten);
                        setTimeout(function() { if (!confJoined) placeCall(CFG.conf_exten); }, 150);
                    }
                    },
                onUnregistered: function() {
                    setStatus('UNREG');
                },
                onServerDisconnect: function() {
                    setStatus('UNREG');
                    toast('DISCONNECTED — Reconnecting...', 3000);
                    startReconnectWatchdog();
                },
            },
        };

        try {
            ua = new SIP.Web.SimpleUser(CFG.ws_url, simpleUserOptions);

            // SimpleUser's own onInvite (set on ua.userAgent.delegate at
            // construction) rejects any INVITE that arrives while ua.session
            // is already occupied, before onCallReceived is ever called —
            // confirmed against the vendored sip.js source. A genuine
            // AGENTDIRECT transfer hits exactly this: the target agent's own
            // base conference call occupies the only session slot SimpleUser
            // tracks, so the transfer's INVITE always got silently rejected.
            // Wrap it here, underneath SimpleUser's public API, so a second
            // call can ring the agent (handleIncomingTransfer) instead of
            // being auto-rejected.
            //
            // Identify ViciDial's own login-race INVITE by caller-identity,
            // not timing (1.3.1's confJoined gate wasn't enough — leaving
            // that specific INVITE unanswered turned out to make ViciDial's
            // own keepalive hang up the agent's whole session, see the
            // 1.3.2 changelog). vicidial.php's NoneInSessionCalL() — the
            // classic "ring agent into conference on login" mechanism —
            // always builds its Originate's caller-id as "ACagcW"+epoch+
            // user_abb (vicidial.php:19066), a prefix no real transfer's
            // Dial() would ever carry. Anything with that prefix is always
            // silently absorbed, exactly like v1.2.0 did, regardless of
            // confJoined; only something WITHOUT it, arriving after
            // confJoined is genuinely true, is treated as an actual
            // incoming transfer.
            const simpleUserOnInvite = ua.userAgent.delegate.onInvite;
            ua.userAgent.delegate.onInvite = function(invitation) {
                const fromName = (invitation.remoteIdentity && invitation.remoteIdentity.friendlyName) || '';
                if (/^ACagcW/.test(fromName)) {
                    if (ua.session) {
                        try { invitation.reject(); } catch(e) {}
                    } else {
                        absorbLoginRaceInvite(invitation);
                    }
                } else if (confJoined) {
                    handleIncomingTransfer(invitation);
                } else {
                    simpleUserOnInvite.call(ua.userAgent, invitation);
                }
            };

            ua.connect().then(function() {
                return ua.register();
            }).catch(function(err) {
                console.error('HulkPhone connect/register error:', err);
                toast('CONNECT FAILED', 3000);
            });
        } catch(e) {
            console.error('HulkPhone init error:', e);
        }
    }

    // ════════════════════════════════════════════════════════════
    //  INCOMING TRANSFER (second call while the base session is active)
    // ════════════════════════════════════════════════════════════
    //
    // Reached only via the ua.userAgent.delegate.onInvite wrapper above.
    // Deliberately rings the agent rather than auto-answering: stray/
    // duplicate INVITEs are a real, observed phenomenon in this system
    // (see the 1.2.0 registration-race fix), so silently swapping into any
    // second call with no confirmation risks dropping a live customer call
    // with zero warning on a false positive. The agent explicitly answers
    // to accept (dropping their base call first) or hangs up to decline
    // (base call left untouched).

    // ViciDial's own NoneInSessionCalL() login-race Originate (identified
    // by its "ACagcW"-prefixed caller-id, see init()) is never a transfer —
    // silently join it exactly like v1.2.0 always did. Leaving it unanswered
    // isn't just a missed call: ViciDial's own keepalive eventually hangs up
    // the agent's entire session to clean up the stuck ringing channel.
    function absorbLoginRaceInvite(invitation) {
        confJoined = true;
        ua.initSession(invitation);
        ua.answer({
            sessionDescriptionHandlerOptions: {
                constraints: { audio: AUDIO_CONSTRAINTS, video: false },
            },
        }).catch(function(err) {
            console.error('HulkPhone: failed to absorb login-race invite', err);
        });
        setStatus('RING');
        setCallBtnCallMode();
        setTimeout(function() { if (ua.session) session = ua.session; }, 300);
    }

    function handleIncomingTransfer(invitation) {
        if (transferPending) {
            // Already ringing one transfer; decline a second stacked one
            // outright rather than silently replacing the first.
            try { invitation.reject(); } catch(e) {}
            return;
        }
        const from = (invitation.remoteIdentity && invitation.remoteIdentity.uri)
            ? invitation.remoteIdentity.uri.user : '';
        console.log('HulkPhone: Incoming transfer from ' + from);
        try { invitation.progress(); } catch(e) {}
        pendingTransferInvitation = invitation;
        transferPending = true;
        setStatus('RING');
        startRing();
        startFlash('XFER: ' + (from || 'CALL'));
        setCallBtnAnswerMode();
        toast('INCOMING TRANSFER', 4000);
    }

    function answerTransfer() {
        if (!ua || !transferPending || !pendingTransferInvitation) return;
        const incoming = pendingTransferInvitation;
        transferPending = false;
        pendingTransferInvitation = null;
        stopRing();
        setStatus('CONN');
        setCallBtnCallMode();
        // Accepting a transfer means leaving whatever the base call was —
        // same as a real phone, taking a second call ends the first.
        const dropBase = ua.session ? ua.hangup().catch(function() {}) : Promise.resolve();
        dropBase.then(function() {
            inTransferCall = true;
            // initSession is SimpleUser's own (not underscore-private)
            // session setup — wires the state-change listener that drives
            // media setup and onCallAnswered/onCallHangup, same as it does
            // internally for every other call. Calling it directly here is
            // the same level of "underneath the public API" as the warm
            // transfer consult leg already does elsewhere in this file.
            ua.initSession(incoming);
            return ua.answer({
                sessionDescriptionHandlerOptions: {
                    constraints: { audio: AUDIO_CONSTRAINTS, video: false },
                },
            });
        }).catch(function(err) {
            console.error('HulkPhone: failed to answer transfer', err);
            inTransferCall = false;
            setStatus('REG');
            setCallBtnIdleMode();
            toast('TRANSFER ANSWER FAILED', 3000);
        });
    }

    function declineTransfer() {
        if (!transferPending || !pendingTransferInvitation) return;
        const incoming = pendingTransferInvitation;
        transferPending = false;
        pendingTransferInvitation = null;
        stopRing();
        setCallBtnIdleMode();
        // Base call was never touched — restore its in-call visual state.
        if (ua && ua.session) { setStatus('CONN'); setCallBtnCallMode(); }
        else { setStatus('REG'); }
        try { incoming.reject(); } catch(e) {}
    }

    // ════════════════════════════════════════════════════════════
    //  RECONNECTION WATCHDOG
    // ════════════════════════════════════════════════════════════
    //
    // SimpleUser retries the transport + re-register on its own (reconnectionAttempts/
    // reconnectionDelay above), but never tells us if it ultimately gives up — there's
    // no delegate hook for that. This watches for the case where it never recovers, so
    // the agent isn't left staring at "DISCONNECTED" indefinitely with no next step.

    function startReconnectWatchdog() {
        clearReconnectWatchdog();
        // Comfortably past reconnectionAttempts * reconnectionDelay (20 * 5s = 100s)
        // so this only fires once SimpleUser has actually exhausted its own retries.
        reconnectWatchdog = setTimeout(function() {
            toast('CONNECTION LOST — please reload this window', 24 * 60 * 60 * 1000);
        }, 130000);
    }

    function clearReconnectWatchdog() {
        if (reconnectWatchdog) {
            clearTimeout(reconnectWatchdog);
            reconnectWatchdog = null;
        }
    }

    // ════════════════════════════════════════════════════════════
    //  CALL MANAGEMENT
    // ════════════════════════════════════════════════════════════

    function placeCall(target) {
        if (!ua) { toast('NOT READY', 2000); return; }
        if (!target) { toast('ENTER NUMBER', 2000); return; }

        // Strip spaces/dashes
        target = target.replace(/[\s\-]/g, '');

        const targetAOR = 'sip:' + target + '@' + CFG.server_ip;
        setStatus('CONN');

        ua.call(targetAOR, {
            sessionDescriptionHandlerOptions: {
                constraints: { audio: AUDIO_CONSTRAINTS, video: false },
            },
        }).then(function() {
            confJoined = true;
            // session is managed by SimpleUser delegate
            toast('CALLING ' + target, 2000);
            setCallBtnCallMode();
        }).catch(function(err) {
            // "Session already exists" while dialing our own conference extension
            // means ViciDial's redundant server-side Originate (see onCallReceived)
            // won the race and we already auto-answered our way into the same
            // conference — a harmless double-join with ourselves, not a real
            // failure, so don't alarm the agent over it.
            if (target === CFG.conf_exten && err && /Session already exists/.test(err.message || '')) {
                console.log('HulkPhone: conference already joined via incoming call, skipping duplicate dial');
                confJoined = true;
                setCallBtnCallMode();
                return;
            }
            console.error('HulkPhone call error:', err);
            setStatus('REG');
            setCallBtnIdleMode();
            toast('CALL FAILED', 2000);
        });
    }

    function hangup() {
        if (!ua) return;
        if (transferPending) {
            declineTransfer();
            return;
        }
        // An unanswered inbound call must be declined (486), not hung up —
        // there is no established dialog to send BYE on.
        if (pendingInvite) {
            pendingInvite = false;
            ua.decline().catch(function() {});
        } else {
            ua.hangup().catch(function() {});
        }
        endWarmTransfer();
        stopRing();
        stopTimer();
        setStatus('REG');
        setCallBtnIdleMode();
        session = null;
    }

    // ════════════════════════════════════════════════════════════
    //  MUTE
    // ════════════════════════════════════════════════════════════

    function toggleMute() {
        if (!ua) return;
        isMuted = !isMuted;
        if (isMuted) {
            ua.mute();
            UI.muteBtn.classList.add('active');
            UI.muteLabel.textContent = CFG.lang.btn_unmute;
            toast('MUTED 🔇', 1500);
        } else {
            ua.unmute();
            UI.muteBtn.classList.remove('active');
            UI.muteLabel.textContent = CFG.lang.btn_mute;
            toast('UNMUTED 🎙', 1500);
        }
    }

    // ════════════════════════════════════════════════════════════
    //  HOLD
    // ════════════════════════════════════════════════════════════

    function toggleHold() {
        if (!ua) return;
        isOnHold = !isOnHold;
        if (isOnHold) {
            ua.hold().then(function() {
                setStatus('HOLD');
                UI.holdBtn.classList.add('active');
                UI.holdLabel.textContent = CFG.lang.btn_unhold;
                toast('ON HOLD ⏸', 1500);
            }).catch(function() {
                isOnHold = false;
                toast('HOLD FAILED', 2000);
            });
        } else {
            ua.unhold().then(function() {
                setStatus('CALL');
                UI.holdBtn.classList.remove('active');
                UI.holdLabel.textContent = CFG.lang.btn_hold;
                toast('RESUMED ▶', 1500);
            }).catch(function() {
                isOnHold = true;
                toast('RESUME FAILED', 2000);
            });
        }
    }

    // ════════════════════════════════════════════════════════════
    //  DTMF
    // ════════════════════════════════════════════════════════════

    function sendDTMF(digit) {
        if (!ua) return;
        try {
            ua.sendDTMF(digit);
        } catch(e) {
            console.warn('DTMF error:', e);
        }
    }

    // ════════════════════════════════════════════════════════════
    //  TRANSFER
    // ════════════════════════════════════════════════════════════
    //
    // SimpleUser has no refer() method at all — `ua.refer(...)` (the old blind-
    // transfer code) was a guaranteed TypeError. REFER lives on the Session
    // itself (`ua.session.refer(...)`), which also accepts another Session as
    // its target to send REFER-with-Replaces — that's what attended/warm
    // transfer needs.
    //
    // SimpleUser also tracks exactly one session and refuses a second: `call()`
    // rejects with "Session already exists" the instant `ua.session` is set,
    // even while that session is only on hold. So a warm transfer's consult
    // leg can't be placed via `ua.call()`/placeCall() — it's built directly as
    // a SIP.Inviter against the raw UserAgent (`ua.userAgent`), entirely
    // outside SimpleUser's bookkeeping, so the original call stays put as
    // `ua.session` throughout the consult.

    function blindTransfer() {
        const target = UI.xferInput.value.trim();
        if (!target) { toast('ENTER XFER NUMBER', 2000); return; }
        if (!ua || !ua.session) { toast('NO ACTIVE CALL', 2000); return; }

        const targetURI = SIP.UserAgent.makeURI('sip:' + target + '@' + CFG.server_ip);
        if (!targetURI) { toast('INVALID XFER NUMBER', 2000); return; }

        ua.session.refer(targetURI, {
            onNotify: function(notification) {
                notification.accept();
                if (/^SIP\/2\.0 2\d\d/.test(notification.request.body || '')) {
                    toast('TRANSFERRED ✓', 2000);
                    // Asterisk drops our leg once the transfer actually completes;
                    // onCallHangup (already wired) resets state when that BYE arrives.
                } else {
                    toast('XFER FAILED', 2500);
                }
            },
        }).catch(function(err) {
            toast('XFER FAILED', 2000);
            console.error('Transfer error:', err);
        });
    }

    function warmTransfer() {
        const target = UI.xferInput.value.trim();
        if (!target) { toast('ENTER XFER NUMBER', 2000); return; }
        if (!ua || !ua.session) { toast('NO ACTIVE CALL', 2000); return; }
        if (warmXferSess) { toast('CONSULT CALL ALREADY ACTIVE', 2000); return; }

        const targetURI = SIP.UserAgent.makeURI('sip:' + target + '@' + CFG.server_ip);
        if (!targetURI) { toast('INVALID XFER NUMBER', 2000); return; }

        ua.hold().then(function() {
            setStatus('HOLD');
            isOnHold = true;
            UI.holdBtn.classList.add('active');
            UI.holdLabel.textContent = CFG.lang.btn_unhold;

            const inviter = new SIP.Inviter(ua.userAgent, targetURI, {
                sessionDescriptionHandlerOptions: {
                    constraints: { audio: AUDIO_CONSTRAINTS, video: false },
                },
            });
            warmXferSess = inviter;
            if (UI.wrapper) UI.wrapper.classList.add('hp-consulting');

            inviter.stateChange.addListener(function(state) {
                if (warmXferSess !== inviter) return; // superseded by cancel/complete
                switch (state) {
                    case SIP.SessionState.Established:
                        connectWarmAudio(inviter);
                        toast('CONSULT CONNECTED', 2500);
                        break;
                    case SIP.SessionState.Terminated:
                        disconnectWarmAudio();
                        warmXferSess = null;
                        if (UI.wrapper) UI.wrapper.classList.remove('hp-consulting');
                        break;
                }
            });

            inviter.invite().then(function() {
                toast('WARM XFER: Dialing ' + target, 2500);
            }).catch(function(err) {
                console.error('Warm transfer dial error:', err);
                toast('XFER DIAL FAILED', 2000);
                warmXferSess = null;
                if (UI.wrapper) UI.wrapper.classList.remove('hp-consulting');
                ua.unhold().catch(function() {});
            });
        }).catch(function() {
            toast('HOLD FAILED', 2000);
        });
    }

    // Merges the held caller with the consult leg via REFER-with-Replaces and
    // drops the agent out. Only reachable once the consult leg has answered.
    function completeWarmTransfer() {
        if (!warmXferSess || warmXferSess.state !== SIP.SessionState.Established) {
            toast('NO CONSULT CALL', 2000);
            return;
        }
        if (!ua || !ua.session) { toast('NO ACTIVE CALL', 2000); return; }

        const consultSess = warmXferSess;
        ua.session.refer(consultSess, {
            onNotify: function(notification) {
                notification.accept();
                if (/^SIP\/2\.0 2\d\d/.test(notification.request.body || '')) {
                    toast('TRANSFER COMPLETE ✓', 2000);
                    // Both parties are bridged by Asterisk now; drop our leg of
                    // the consult call. onCallHangup cleans up ua.session once
                    // Asterisk sends BYE for it.
                    try { consultSess.bye(); } catch(e) {}
                } else {
                    toast('TRANSFER FAILED', 2500);
                }
            },
        }).catch(function(err) {
            console.error('Warm transfer complete error:', err);
            toast('XFER FAILED', 2000);
        });
    }

    // Agent-initiated abandon of an in-progress consult: ends the consult leg
    // and brings the original caller back off hold.
    function cancelWarmTransfer() {
        if (!warmXferSess) return;
        endWarmTransfer();

        if (ua && ua.session) {
            ua.unhold().then(function() {
                setStatus('CALL');
                isOnHold = false;
                UI.holdBtn.classList.remove('active');
                UI.holdLabel.textContent = CFG.lang.btn_hold;
                toast('BACK TO CALLER', 1500);
            }).catch(function() {
                toast('RESUME FAILED', 2000);
            });
        }
    }

    // Tears down a consult leg without touching the primary call — used by
    // cancelWarmTransfer (agent choice) and by onCallHangup/hangup() (primary
    // call ended first) so a consult call is never left dangling with no way
    // to reach it from the UI.
    function endWarmTransfer() {
        if (!warmXferSess) return;
        const consultSess = warmXferSess;
        warmXferSess = null;
        disconnectWarmAudio();
        if (UI.wrapper) UI.wrapper.classList.remove('hp-consulting');
        try {
            if (consultSess.state === SIP.SessionState.Established) {
                consultSess.bye();
            } else {
                consultSess.cancel();
            }
        } catch(e) {}
    }

    // ════════════════════════════════════════════════════════════
    //  VOLUME
    // ════════════════════════════════════════════════════════════

    function setVolume(val) {
        UI.remoteAudio.volume = parseFloat(val);
        // Update slider gradient
        const pct = (val * 100) + '%';
        UI.volume.style.background =
            'linear-gradient(90deg, var(--hulk-green) ' + pct + ', var(--bg-panel-2) ' + pct + ')';
    }

    // ════════════════════════════════════════════════════════════
    //  DIAL PAD HELPERS
    // ════════════════════════════════════════════════════════════

    function dialKey(digit) {
        UI.dialInput.value += digit;
        // Send DTMF if in a call
        if (callActive) sendDTMF(digit);
    }

    function clearInput() {
        UI.dialInput.value = UI.dialInput.value.slice(0, -1);
    }

    // ════════════════════════════════════════════════════════════
    //  CALL ACTION (toggle: call / hangup)
    // ════════════════════════════════════════════════════════════

    function callAction() {
        if (transferPending) {
            answerTransfer();
        } else if (pendingInvite) {
            answerCall();
        } else if (callActive) {
            hangup();
        } else {
            const target = UI.dialInput.value.trim();
            placeCall(target);
        }
    }

    function answerCall() {
        if (!ua || !pendingInvite) return;
        // Commit to the call before accept() resolves. Clearing pendingInvite
        // alone would leave the button in its idle branch during the accept
        // round-trip, so a second click would dial the caller back instead of
        // ending the call; flipping to call mode makes it hang up. onCallAnswered
        // then confirms the state once the dialog is established.
        pendingInvite = false;
        stopRing();
        setStatus('CONN');
        setCallBtnCallMode();
        ua.answer().catch(function(err) {
            console.error('HulkPhone answer error:', err);
            setStatus('REG');
            setCallBtnIdleMode();
            toast('ANSWER FAILED', 2000);
        });
    }

    // ════════════════════════════════════════════════════════════
    //  KEYBOARD SUPPORT
    // ════════════════════════════════════════════════════════════

    document.addEventListener('keydown', function(e) {
        // Only react when dial input is NOT focused (to avoid double input)
        if (document.activeElement === UI.dialInput) return;

        if (e.key >= '0' && e.key <= '9') dialKey(e.key);
        if (e.key === '*') dialKey('*');
        if (e.key === '#') dialKey('#');
        if (e.key === 'Enter') callAction();
        if (e.key === 'Escape') hangup();
        if (e.key === 'Backspace') clearInput();
        if (e.key === 'm' || e.key === 'M') toggleMute();
        if (e.key === 'h' || e.key === 'H') toggleHold();
    });

    // ════════════════════════════════════════════════════════════
    //  PUBLIC API (exposed to window as HulkPhone)
    // ════════════════════════════════════════════════════════════

    window.HulkPhone = {
        callAction:     callAction,
        answerCall:     answerCall,
        hangup:         hangup,
        toggleMute:     toggleMute,
        toggleHold:     toggleHold,
        dialKey:        dialKey,
        clearInput:     clearInput,
        blindTransfer:      blindTransfer,
        warmTransfer:       warmTransfer,
        completeWarmTransfer: completeWarmTransfer,
        cancelWarmTransfer:   cancelWarmTransfer,
        setVolume:      setVolume,
        placeCall:      placeCall,
        sendDTMF:       sendDTMF,
        getStatus:      function() { return callActive ? 'INCALL' : 'IDLE'; },
    };

    // ════════════════════════════════════════════════════════════
    //  BOOT
    // ════════════════════════════════════════════════════════════

    // Wait for DOM ready, then init
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

})(window, document);
