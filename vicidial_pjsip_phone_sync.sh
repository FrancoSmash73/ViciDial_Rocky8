#!/bin/bash
################################################################################
# vicidial_pjsip_phone_sync.sh
#
# Generates PJSIP endpoint/auth/aor blocks in pjsip-webrtc-agents.conf from the
# ViciDial `phones` table.
#
# WHY THIS EXISTS
# ---------------
# ViciDial auto-generates sip-vicidial.conf, iax-vicidial.conf and the dialplan
# from the `phones` table -- but it NEVER generates PJSIP endpoint blocks for
# phones. `pjsip-vicidial.conf` only ever receives carrier/trunk blocks. So
# every PJSIP webphone has to be hand-written into a conf file, and it is
# trivially easy to (a) forget one, or (b) paste the wrong password.
#
# THE PASSWORD TRAP
# -----------------
# Admin -> Phones has TWO password fields, backed by two different columns
# (see ViciDial's own admin.php: `name=conf_secret` and `name=pass`):
#
#   Admin UI field          DB column             Used for
#   ----------------------  --------------------  -----------------------------
#   Registration Password   phones.conf_secret    the SIP secret -> conf `auth`
#   Login Password          phones.pass           agent's web login
#
# The webphone authenticates with conf_secret (agc/vicidial.php does
# `base64_encode($conf_secret)`), so the conf `auth` block MUST use conf_secret.
#
# On many installs `pass` and `conf_secret` hold the same value, so using the
# wrong one silently works -- until one phone diverges, and then that phone
# fails to authenticate for reasons that look inexplicable. This script always
# uses conf_secret.
#
# USAGE
#   ./vicidial_pjsip_phone_sync.sh --check    # read-only audit, exit 1 on drift
#   ./vicidial_pjsip_phone_sync.sh --apply    # write conf, backup, pjsip reload
#
# Only the region between the BEGIN/END MANAGED markers is rewritten; anything
# you add outside them is preserved.
################################################################################

set -euo pipefail

CONF="${PJSIP_AGENTS_CONF:-/etc/asterisk/pjsip-webrtc-agents.conf}"
ASTCONF="/etc/astguiclient.conf"
BEGIN="; >>> BEGIN MANAGED BY vicidial_pjsip_phone_sync.sh -- DO NOT EDIT BELOW"
END="; <<< END MANAGED BY vicidial_pjsip_phone_sync.sh"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; NC=$'\033[0m'
ok()   { echo "  ${GRN}OK${NC}   $*"; }
warn() { echo "  ${YEL}WARN${NC} $*"; }
die()  { echo "  ${RED}FAIL${NC} $*" >&2; exit 1; }

MODE="${1:---check}"
case "$MODE" in
  --check|--apply) ;;
  *) die "usage: $0 [--check|--apply]" ;;
esac

[ -r "$ASTCONF" ] || die "cannot read $ASTCONF"
DB_HOST=$(awk -F'=>' '/^VARDB_server/   {print $2}' "$ASTCONF" | xargs)
DB_NAME=$(awk -F'=>' '/^VARDB_database/ {print $2}' "$ASTCONF" | xargs)
DB_USER=$(awk -F'=>' '/^VARDB_user/     {print $2}' "$ASTCONF" | xargs)
DB_PASS=$(awk -F'=>' '/^VARDB_pass/     {print $2}' "$ASTCONF" | xargs)
[ -n "${DB_PASS:-}" ] || die "no VARDB_pass in $ASTCONF"

q() { mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -D"$DB_NAME" -N -B -e "$1" 2>/dev/null; }

# ---------------------------------------------------------------- sanity checks
# A phone with an empty conf_secret can never register. Catch it here rather
# than in the Asterisk log at 3am.
BAD=$(q "SELECT GROUP_CONCAT(extension)
         FROM phones
         WHERE protocol='PJSIP' AND active='Y'
           AND (conf_secret IS NULL OR conf_secret='' OR conf_secret='test');")
[ -z "$BAD" ] || [ "$BAD" = "NULL" ] || warn "phones with empty/default conf_secret (cannot register): $BAD"

# Extensions where the two password columns disagree. Not an error -- it is the
# normal case -- but it is exactly where copying `pass` would break the phone.
DIVERGED=$(q "SELECT GROUP_CONCAT(extension)
              FROM phones
              WHERE protocol='PJSIP' AND active='Y' AND pass <> conf_secret;")
[ -z "$DIVERGED" ] || [ "$DIVERGED" = "NULL" ] || \
  echo "  note: pass != conf_secret on: $DIVERGED (conf_secret is the correct one)"

# ------------------------------------------------------------------- generation
GENERATED=$(mktemp); trap 'rm -f "$GENERATED"' EXIT
{
  echo "$BEGIN"
  echo "; Generated $(date -u '+%Y-%m-%d %H:%M:%S UTC') from the ViciDial phones table."
  echo "; Passwords come from phones.conf_secret (Registration Password), never phones.pass."
  echo ""
  q "SELECT extension, conf_secret, COALESCE(NULLIF(fullname,''), CONCAT('Agent ', extension))
     FROM phones
     WHERE protocol='PJSIP' AND active='Y' AND is_webphone='Y'
       AND conf_secret IS NOT NULL AND conf_secret <> ''
     ORDER BY extension;" |
  while IFS=$'\t' read -r ext secret cname; do
    [ -n "$ext" ] || continue
    cat <<BLOCK
[${ext}](webrtc_template)
auth=auth${ext}
aors=${ext}
callerid="${cname}" <${ext}>
context=default

[auth${ext}]
type=auth
auth_type=userpass
username=${ext}
password=${secret}

[${ext}]
type=aor
max_contacts=1
remove_existing=yes

BLOCK
  done
  echo "$END"
} > "$GENERATED"

COUNT=$(grep -c '^\[auth' "$GENERATED" || true)

# ----------------------------------------------------------------------- check
if [ ! -f "$CONF" ]; then
    [ "$MODE" = "--check" ] && die "$CONF does not exist"
else
    CURRENT=$(mktemp); trap 'rm -f "$GENERATED" "$CURRENT"' EXIT
    if grep -qF "$BEGIN" "$CONF"; then
        sed -n "/^${BEGIN//\//\\/}\$/,/^${END//\//\\/}\$/p" "$CONF" > "$CURRENT"
    else
        : > "$CURRENT"
    fi
    if diff -q "$CURRENT" "$GENERATED" >/dev/null 2>&1; then
        ok "$CONF is in sync with the phones table ($COUNT endpoints)"
        exit 0
    fi
    echo "  drift detected between the phones table and $CONF:"
    diff "$CURRENT" "$GENERATED" | grep -E "^[<>] \[(auth)?[0-9]" | sort -u | sed 's/^/    /' || true
fi

if [ "$MODE" = "--check" ]; then
    echo
    warn "run with --apply to regenerate ($COUNT endpoints would be written)"
    exit 1
fi

# ----------------------------------------------------------------------- apply
BACKUP="${CONF}.bak.$(date +%Y%m%d-%H%M%S)"
if [ -f "$CONF" ]; then
    cp -a "$CONF" "$BACKUP"
    ok "backed up -> $BACKUP"
    # Drop the old managed region, keep everything the operator added by hand.
    if grep -qF "$BEGIN" "$CONF"; then
        sed -i "/^${BEGIN//\//\\/}\$/,/^${END//\//\\/}\$/d" "$CONF"
    fi
else
    printf '; PJSIP WebRTC agent endpoints\n\n' > "$CONF"
fi

cat "$GENERATED" >> "$CONF"
chown asterisk:asterisk "$CONF" 2>/dev/null || true
chmod 640 "$CONF" 2>/dev/null || true
ok "wrote $COUNT endpoints to $CONF"

if command -v asterisk >/dev/null && asterisk -rx "core show version" >/dev/null 2>&1; then
    asterisk -rx "pjsip reload" >/dev/null 2>&1
    sleep 1
    LOADED=$(asterisk -rx "pjsip show endpoints" 2>/dev/null | grep -cE "^ Endpoint:" || true)
    ok "pjsip reloaded (${LOADED} endpoint lines reported)"
    # An endpoint that exists but never registers is the normal state until the
    # agent opens the webphone; "Unable to find object" is the real failure.
    MISSING=0
    while read -r ext; do
        [ -n "$ext" ] || continue
        asterisk -rx "pjsip show endpoint $ext" 2>/dev/null | grep -q "Unable to find object" && {
            warn "endpoint $ext did not load"; MISSING=1; }
    done < <(q "SELECT extension FROM phones WHERE protocol='PJSIP' AND active='Y' AND is_webphone='Y';")
    [ "$MISSING" -eq 0 ] && ok "all endpoints resolve in Asterisk"
else
    warn "asterisk not running — reload skipped"
fi

echo
echo "  Reminder: agents must fully log OUT and back IN for"
echo "  vicidial_live_agents.extension to pick up PJSIP/<ext>."
