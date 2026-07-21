#!/bin/bash
################################################################################
# vicidial_chan_sip_remove.sh
#
# Audits whether chan_sip is still needed, and only then removes it.
#
# chan_sip is deprecated in Asterisk 18/20 and REMOVED in Asterisk 21. On a
# PJSIP-only ViciDial box it usually has no live dependency at all -- but it
# still listens on udp/5060 and is the single largest attack surface on the
# server. On one live box it absorbed a 4-day REGISTER brute-force flood that
# wrote a 6.9 GB log at ~1.8 GB/day.
#
#   --check    audit only; report what still depends on chan_sip (default)
#   --apply    remove it, but ONLY if the audit is clean
#
# ORDER MATTERS. --apply does:
#   1. verify nothing depends on chan_sip
#   2. regenerate the ViciDial dialplan so Dial(SIP/x) becomes Dial(PJSIP/x)
#   3. noload chan_sip.so in modules.conf, then unload it
#   4. close udp/5060
#
# Step 2 is the one people skip. If phones.protocol is flipped to PJSIP with
# raw SQL, ViciDial's auto-generated dialplan still says Dial(SIP/<ext>), and
# direct-dial/transfer to those extensions breaks -- even though agent LOGIN
# keeps working, because vicidial.php originates "$protocol/$extension"
# straight from phones.protocol and never consults the dialplan.
################################################################################

set -euo pipefail

ASTCONF="/etc/astguiclient.conf"
MODULES="/etc/asterisk/modules.conf"
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; NC=$'\033[0m'
ok()   { echo -e "  ${GRN}OK${NC}   $*"; }
warn() { echo -e "  ${YEL}WARN${NC} $*"; }
die()  { echo -e "  ${RED}FAIL${NC} $*" >&2; exit 1; }

MODE="${1:---check}"
[ "$MODE" = "--check" ] || [ "$MODE" = "--apply" ] || die "usage: $0 [--check|--apply]"

DB_HOST=$(awk -F'=>' '/^VARDB_server/   {print $2}' "$ASTCONF" | xargs)
DB_NAME=$(awk -F'=>' '/^VARDB_database/ {print $2}' "$ASTCONF" | xargs)
DB_USER=$(awk -F'=>' '/^VARDB_user/     {print $2}' "$ASTCONF" | xargs)
DB_PASS=$(awk -F'=>' '/^VARDB_pass/     {print $2}' "$ASTCONF" | xargs)
SERVER_IP=$(awk -F'=>' '/^VARserver_ip/ {print $2}' "$ASTCONF" | xargs)
q() { mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -D"$DB_NAME" -N -B -e "$1" 2>/dev/null; }

echo "=== chan_sip dependency audit ==="
BLOCKERS=0

PHONES=$(q "SELECT GROUP_CONCAT(extension) FROM phones WHERE protocol='SIP' AND active='Y';")
if [ -n "$PHONES" ] && [ "$PHONES" != "NULL" ]; then
    warn "active phones still on protocol='SIP': $PHONES"
    BLOCKERS=$((BLOCKERS+1))
else
    ok "no active phones on chan_sip"
fi

CARRIERS=$(q "SELECT GROUP_CONCAT(carrier_id) FROM vicidial_server_carriers WHERE active='Y' AND protocol IN ('SIP','IAX2');")
if [ -n "$CARRIERS" ] && [ "$CARRIERS" != "NULL" ]; then
    warn "active SIP/IAX2 carriers: $CARRIERS"
    BLOCKERS=$((BLOCKERS+1))
else
    ok "no active chan_sip carriers (PJSIP trunks are unaffected)"
fi

if asterisk -rx "core show version" >/dev/null 2>&1; then
    # chan_sip may already be unloaded; every probe below must tolerate that.
    # (grep finding nothing under `set -o pipefail` would otherwise abort here.)
    LOADED=$(asterisk -rx "module show like chan_sip" 2>/dev/null | awk '/^chan_sip\.so/{print $NF}' || true)
    if [ -z "${LOADED:-}" ]; then
        ok "chan_sip is not loaded"
    else
        REG=$(asterisk -rx "sip show registry" 2>/dev/null | awk '/SIP registrations/{print $1}' || true)
        if [ "${REG:-0}" = "0" ]; then
            ok "0 outbound chan_sip registrations"
        else
            warn "chan_sip has ${REG} outbound registrations"; BLOCKERS=$((BLOCKERS+1))
        fi

        USE=$(asterisk -rx "module show like chan_sip" 2>/dev/null | awk '/^chan_sip\.so/{print $(NF-2)}' || true)
        if [ -n "${USE:-}" ] && [ "$USE" != "0" ]; then
            warn "chan_sip use count is $USE (live channels) — retry when idle"
            BLOCKERS=$((BLOCKERS+1))
        else
            ok "chan_sip use count is 0"
        fi
    fi
fi

if [ "$BLOCKERS" -ne 0 ]; then
    echo; die "$BLOCKERS blocker(s). chan_sip is still in use — not safe to remove."
fi
echo; ok "no live dependency on chan_sip"

if [ "$MODE" = "--check" ]; then
    echo; echo "  run with --apply to remove chan_sip"
    exit 0
fi

# ------------------------------------------------------------------ apply
CHAN=$(asterisk -rx "core show channels count" 2>/dev/null | head -1 | awk '{print $1}')
[ "${CHAN:-0}" = "0" ] || die "there are ${CHAN} active channels — run this in a maintenance window"

BK="/root/chan_sip-removal-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"; chmod 700 "$BK"
cp -a "$MODULES" /etc/asterisk/extensions-vicidial.conf /etc/asterisk/sip-vicidial.conf "$BK/" 2>/dev/null || true
ok "backup -> $BK"

# 1. Regenerate the dialplan so Dial(SIP/x) becomes Dial(PJSIP/x).
#    ViciDial only rebuilds when all three flags are Y; rebuild_conf_files is a
#    dirty flag it sets on admin-UI edits, so raw SQL changes never trigger it.
echo; echo "=== regenerating ViciDial confs from the phones table ==="
q "UPDATE servers SET rebuild_conf_files='Y' WHERE server_ip='$SERVER_IP';"
for _ in $(seq 18); do
    sleep 5
    [ "$(q "SELECT rebuild_conf_files FROM servers WHERE server_ip='$SERVER_IP';")" = "N" ] && break
done
# grep -c prints "0" and exits 1 when there are no matches; `|| echo 0` would
# append a SECOND zero. Take the first line and default it instead.
LEFT=$(grep -c 'Dial(SIP/' /etc/asterisk/extensions-vicidial.conf 2>/dev/null | head -1 || true)
if [ "${LEFT:-0}" -eq 0 ]; then
    ok "dialplan has no Dial(SIP/...) left"
else
    warn "${LEFT} Dial(SIP/...) entries remain in the dialplan"
fi

# 2. noload + unload
if grep -qE '^\s*;\s*noload\s*=\s*chan_sip\.so' "$MODULES"; then
    sed -i 's/^\s*;\s*noload\s*=\s*chan_sip\.so.*/noload = chan_sip.so/' "$MODULES"
elif ! grep -qE '^noload\s*=\s*chan_sip\.so' "$MODULES"; then
    sed -i '/^\[modules\]/a noload = chan_sip.so' "$MODULES"
fi
# A bare `cmd && ok ...` evaluates to non-zero when cmd fails, which under
# `set -e` would abort mid-removal. Guard both.
if grep -qE '^noload = chan_sip.so' "$MODULES"; then ok "modules.conf: noload = chan_sip.so"
else warn "could not set noload = chan_sip.so in $MODULES"; fi
if asterisk -rx "module unload chan_sip.so" >/dev/null 2>&1; then ok "chan_sip unloaded"
else warn "chan_sip unload failed (already unloaded?)"; fi

# 3. close the port chan_sip owned
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port=5060/udp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "closed udp/5060"
    # firewalld's reload flushes iptables-based fail2ban bans. If the jails use
    # banaction=nftables-* (as this repo now configures) they survive; verify.
    if command -v fail2ban-client >/dev/null; then
        B=$(fail2ban-client status asterisk 2>/dev/null | awk '/Currently banned:/{print $NF}' || true)
        if [ "${B:-0}" -gt 0 ] && ! nft list ruleset 2>/dev/null | grep -q "f2b"; then
            warn "fail2ban reports ${B} bans but no f2b nft rules — banaction is iptables-based and firewalld wiped them"
        fi
    fi
fi

if ss -lnup 2>/dev/null | grep -q ':5060'; then
    warn "something still listens on udp/5060"
else
    ok "nothing on udp/5060"
fi

echo
echo "  NOTE: 'noload' only takes effect at Asterisk restart. Verify with:"
echo "        asterisk -rx \"core restart now\" && asterisk -rx \"module show like chan_sip\""
echo "  If Asterisk runs under GNU screen (ViciDial default) do NOT use systemctl;"
echo "  recovery: screen -d -m -S asterisk /usr/sbin/asterisk -vvvvvvvvvvvvvvvvvvvvvgcT"
