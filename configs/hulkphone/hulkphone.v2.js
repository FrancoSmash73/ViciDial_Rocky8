/**
 * HulkPhone.js — SIP.js WebRTC Core
 * Version: 1.0.0
 *
 * Architecture:
 *   - Uses SIP.js 0.20.x SimpleUser (high-level API)
 *   - Registers with Asterisk via WebSocket (wss)
 *   - Auto-calls conference extension on registration (ViciDial pattern)
 *   - Full DTMF, Mute, Hold, Blind/Warm Transfer support
 *   - Timer, status, and ViciDial parent window communication
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
    let warmXferSess  = null;   // Second leg for warm transfer
    let timerInterval = null;
    let callSeconds   = 0;

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
    //  SESSION EVENT HANDLING
    // ════════════════════════════════════════════════════════════

    function attachSessionHandlers(sess) {
        session = sess;

        // Session state changes
        sess.stateChange.addListener(function(state) {
            console.log('HulkPhone session state:', state);

            switch (state) {
                case SIP.SessionState.Establishing:
                    setStatus('CONN');
                    startRing();
                    break;

                case SIP.SessionState.Established:
                    stopRing();
                    setStatus('CALL');
                    setCallBtnCallMode();
                    startTimer();
                    connectRemoteAudio(sess);
                    // Notify ViciDial parent window
                    notifyParent('CALL_CONNECTED');
                    break;

                case SIP.SessionState.Terminating:
                case SIP.SessionState.Terminated:
                    stopRing();
                    stopTimer();
                    setStatus('REG');
                    setCallBtnIdleMode();
                    disconnectRemoteAudio();
                    isMuted = false;
                    isOnHold = false;
                    UI.muteBtn.classList.remove('active');
                    UI.holdBtn.classList.remove('active');
                    UI.muteLabel.textContent = CFG.lang.btn_mute;
                    UI.holdLabel.textContent = CFG.lang.btn_hold;
                    session = null;
                    notifyParent('CALL_ENDED');
                    break;
            }
        });
    }

    // ════════════════════════════════════════════════════════════
    //  AUDIO HANDLING
    // ════════════════════════════════════════════════════════════

    function connectRemoteAudio(sess) {
        try {
            const remoteStream = new MediaStream();
            const receivers = sess.sessionDescriptionHandler.peerConnection.getReceivers();
            receivers.forEach(function(receiver) {
                if (receiver.track) remoteStream.addTrack(receiver.track);
            });
            UI.remoteAudio.srcObject = remoteStream;
            UI.remoteAudio.volume = parseFloat(UI.volume.value);
        } catch(e) {
            console.warn('HulkPhone: audio connect error', e);
        }
    }

    function disconnectRemoteAudio() {
        try {
            UI.remoteAudio.srcObject = null;
        } catch(e) {}
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
                    audio: {
                        echoCancellation: true,
                        noiseSuppression: true,
                        autoGainControl:  true,
                    },
                    video: false,
                },
                remote: { audio: UI.remoteAudio },
            },
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
                // returning 486 Busy exactly as it did before.
                onCallReceived: function() {
                    const from = (ua.session && ua.session.remoteIdentity)
                        ? ua.session.remoteIdentity.uri.user : '';
                    console.log('HulkPhone: Incoming call from ' + from);

                    // A call *from* the conference extension is machine-driven,
                    // not a human calling the agent, so it still picks up on its
                    // own. Kept as a guard in case ViciDial is ever reconfigured
                    // to originate toward the phone (webphone_call_seconds > 0).
                    if (CFG.auto_answer && CFG.conf_exten && from === CFG.conf_exten) {
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
                },
                onRegistered: function() {
                    setStatus('REG');
                    toast('REGISTERED ✓', 2000);
                    console.log('HulkPhone: Registered as ' + aor);
                    // Auto-call conference extension on register.
                    // dialRegExten_enabled=1 in ViciDial suppresses NoneInSession dialog.
                    if (CFG.auto_answer && CFG.conf_exten) {
                        console.log('HulkPhone: Auto-calling conference ' + CFG.conf_exten);
                        setTimeout(function() { placeCall(CFG.conf_exten); }, 800);
                    }
                    },
                onUnregistered: function() {
                    setStatus('UNREG');
                },
                onServerDisconnect: function() {
                    setStatus('UNREG');
                    toast('DISCONNECTED — Reconnecting...', 3000);
                },
            },
        };

        try {
            ua = new SIP.Web.SimpleUser(CFG.ws_url, simpleUserOptions);
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
                constraints: { audio: true, video: false },
            },
        }).then(function() {
            // session is managed by SimpleUser delegate
            toast('CALLING ' + target, 2000);
            setCallBtnCallMode();
        }).catch(function(err) {
            console.error('HulkPhone call error:', err);
            setStatus('REG');
            setCallBtnIdleMode();
            toast('CALL FAILED', 2000);
        });
    }

    function hangup() {
        if (!ua) return;
        // An unanswered inbound call must be declined (486), not hung up —
        // there is no established dialog to send BYE on.
        if (pendingInvite) {
            pendingInvite = false;
            ua.decline().catch(function() {});
        } else {
            ua.hangup().catch(function() {});
        }
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

    function blindTransfer() {
        const target = UI.xferInput.value.trim();
        if (!target) { toast('ENTER XFER NUMBER', 2000); return; }
        if (!ua) return;

        const targetURI = SIP.UserAgent.makeURI('sip:' + target + '@' + CFG.server_ip);
        ua.refer(targetURI).then(function() {
            toast('TRANSFERRED ✓', 2000);
            stopTimer();
            setStatus('REG');
            setCallBtnIdleMode();
            session = null;
        }).catch(function(err) {
            toast('XFER FAILED', 2000);
            console.error('Transfer error:', err);
        });
    }

    function warmTransfer() {
        const target = UI.xferInput.value.trim();
        if (!target) { toast('ENTER XFER NUMBER', 2000); return; }
        // Put current call on hold, dial transfer target
        ua.hold().then(function() {
            setStatus('HOLD');
            isOnHold = true;
            UI.holdBtn.classList.add('active');
            UI.holdLabel.textContent = CFG.lang.btn_unhold;
            placeCall(target);
            toast('WARM XFER: Dialing ' + target, 2500);
        }).catch(function() {
            toast('HOLD FAILED', 2000);
        });
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
        if (pendingInvite) {
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
        blindTransfer:  blindTransfer,
        warmTransfer:   warmTransfer,
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
