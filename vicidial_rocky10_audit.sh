#!/bin/bash
# ============================================================
# ViciDial Rocky 10 Post-Install Audit Script
# Run as root on each server
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS="${GREEN}[PASS]${NC}"; FAIL="${RED}[FAIL]${NC}"; WARN="${YELLOW}[WARN]${NC}"

SERVER_IP=$(hostname -I | awk '{print $1}')
echo "============================================================"
echo " ViciDial Rocky 10 Audit — $(hostname) / $SERVER_IP"
echo " $(date)"
echo "============================================================"

# ── Detect DB connection from /etc/astguiclient.conf ─────────
DB_HOST=$(grep -oP '(?<=VARDB_server => )[^\s]+' /etc/astguiclient.conf 2>/dev/null | head -1)
DB_HOST=${DB_HOST:-127.0.0.1}
DB_NAME=$(grep -oP '(?<=VARDB_database => )[^\s]+' /etc/astguiclient.conf 2>/dev/null | head -1)
DB_NAME=${DB_NAME:-asterisk}
DB_USER=$(grep -oP '(?<=VARDB_user => )[^\s]+' /etc/astguiclient.conf 2>/dev/null | head -1)
DB_USER=${DB_USER:-cron}
DB_PASS=$(grep -oP '(?<=VARDB_pass => )[^\s]+' /etc/astguiclient.conf 2>/dev/null | head -1)
if [ -z "$DB_PASS" ]; then
  echo -e "  ${WARN} Could not detect DB password from /etc/astguiclient.conf"
  read -rsp "  Enter DB password manually: " DB_PASS
  echo
fi

# Helper: query a table count silently (uses VARDB_* credentials, works local or remote)
check_table() {
  mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -se "SELECT COUNT(*) FROM $1;" 2>/dev/null
}

# ── 1. Screen sockets ────────────────────────────────────────
echo -e "\n── 1. Screen Sockets ──"
SCREENS=$(screen -ls 2>/dev/null | grep -c "Detached\|Attached")
echo "  Found: $SCREENS sockets"
screen -ls 2>/dev/null | grep -E "Detached|Attached" | awk '{print "  "$0}'
KEEPALIVES=$(grep -oP '(?<=VARactive_keepalives => )[^\s]+' /etc/astguiclient.conf 2>/dev/null | head -1)
EXPECTED="ASTupdate ASTsend ASTlisten ASTVDauto ASTSIPlogger ASTConfUpdater ASTVDremote ASTfastlog ASTemail ASTconf3way asterisk"
# ASTVDadapt only runs on the server with code 5 in VARactive_keepalives
[[ "$KEEPALIVES" == *5* ]] && EXPECTED="$EXPECTED ASTVDadapt"
for s in $EXPECTED; do
  screen -ls 2>/dev/null | grep -q "$s" \
    && echo -e "  $PASS $s" \
    || echo -e "  $FAIL $s MISSING"
done

# ── 2. Database Schema ───────────────────────────────────────
echo -e "\n── 2. Database Schema ──"

VS=$(check_table "vicidial_settings")
if [ -z "$VS" ]; then
  echo -e "  $FAIL vicidial_settings — TABLE MISSING (run MySQL_AST_CREATE_tables.sql)"
elif [ "$VS" -eq 0 ]; then
  echo -e "  $FAIL vicidial_settings — exists but EMPTY (run first_server_install.sql)"
else
  AK=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" \
    -se "SELECT active_keepalives FROM vicidial_settings LIMIT 1;" 2>/dev/null)
  echo -e "  $PASS vicidial_settings — $VS row(s), active_keepalives=$AK"
fi

VV=$(check_table "vicidial_version")
[ -z "$VV" ] \
  && echo -e "  $WARN vicidial_version — missing (schema may be partial)" \
  || echo -e "  $PASS vicidial_version — present"

SS=$(check_table "system_settings")
[ -z "$SS" ] \
  && echo -e "  $FAIL system_settings — MISSING" \
  || echo -e "  $PASS system_settings — present"

# ── 3. Timer unit ────────────────────────────────────────────
echo -e "\n── 3. Systemd Timer Unit ──"
TIMER=/etc/systemd/system/vicidial-keepalive.timer
if [ ! -f "$TIMER" ]; then
  echo -e "  $FAIL vicidial-keepalive.timer — FILE MISSING"
else
  grep -q "OnUnitActiveSec" "$TIMER" \
    && echo -e "  $FAIL OnUnitActiveSec found — causes double-fire, change to OnUnitInactiveSec" \
    || echo -e "  $PASS No OnUnitActiveSec"

  grep -q "^Requires=vicidial-keepalive.service" "$TIMER" \
    && echo -e "  $FAIL Requires=vicidial-keepalive.service found — remove it" \
    || echo -e "  $PASS No Requires= in timer unit"

  grep -q "OnUnitInactiveSec" "$TIMER" \
    && echo -e "  $PASS OnUnitInactiveSec=1min present" \
    || echo -e "  $WARN OnUnitInactiveSec not found — check timer interval"
fi

systemctl is-active vicidial-keepalive.timer &>/dev/null \
  && echo -e "  $PASS vicidial-keepalive.timer is active" \
  || echo -e "  $FAIL vicidial-keepalive.timer is NOT active"

DOUBLE=$(journalctl -u vicidial-keepalive.service --since "5 minutes ago" \
  --no-pager 2>/dev/null | grep -c "Starting vicidial-keepalive")
if [ "$DOUBLE" -gt 6 ]; then
  echo -e "  $FAIL Timer firing ~${DOUBLE}x in last 5 min — double-fire detected"
elif [ "$DOUBLE" -gt 0 ]; then
  echo -e "  $PASS Timer fired ${DOUBLE}x in last 5 min (expected ~5)"
else
  echo -e "  $WARN No timer fires in last 5 min — timer may not be running"
fi

# ── 4. Crontab ───────────────────────────────────────────────
echo -e "\n── 4. Crontab ──"
HOPPER_COUNT=$(crontab -l 2>/dev/null | grep -c "AST_VDhopper")
if [ "$HOPPER_COUNT" -eq 0 ]; then
  echo -e "  $FAIL Crontab missing — ViciDial cron jobs not installed"
elif [ "$HOPPER_COUNT" -gt 1 ]; then
  echo -e "  $FAIL Crontab DUPLICATED (${HOPPER_COUNT}x AST_VDhopper) — dedup required"
else
  echo -e "  $PASS Crontab clean — single copy of each job"
fi
TOTAL=$(crontab -l 2>/dev/null | grep -vc "^#\|^$")
echo "  Total active cron entries: $TOTAL"

# ── 5. Perl modules ──────────────────────────────────────────
echo -e "\n── 5. Perl Modules ──"
perl -e "use Switch;" 2>/dev/null \
  && echo -e "  $PASS Switch.pm available" \
  || echo -e "  $FAIL Switch.pm MISSING — AST_VDadapt.pl will crash (run: cpan Switch)"
perl -e "use DBI;" 2>/dev/null \
  && echo -e "  $PASS DBI available" \
  || echo -e "  $FAIL DBI MISSING"
perl -e "use DBD::MariaDB;" 2>/dev/null \
  && echo -e "  $PASS DBD::MariaDB available" \
  || echo -e "  $FAIL DBD::MariaDB MISSING"

# ── 6. Asterisk ──────────────────────────────────────────────
echo -e "\n── 6. Asterisk ──"
systemctl is-active vicidial-asterisk.service &>/dev/null \
  && echo -e "  $PASS vicidial-asterisk.service active" \
  || pgrep -x asterisk &>/dev/null \
    && echo -e "  ${PASS} Asterisk running in screen session (correct for ViciDial)" \
    || echo -e "  $FAIL Asterisk NOT running"

# ── 7. Core services ─────────────────────────────────────────
echo -e "\n── 7. Core Services ──"
for svc in mariadb httpd php-fpm; do
  systemctl is-active $svc &>/dev/null \
    && echo -e "  $PASS $svc" \
    || echo -e "  $FAIL $svc NOT running"
done

# ── 8. Process monitor ───────────────────────────────────────
echo -e "\n── 8. Process Monitor ──"
systemctl is-active vicidial-process-monitor &>/dev/null \
  && echo -e "  $PASS vicidial-process-monitor active" \
  || echo -e "  $FAIL vicidial-process-monitor NOT active"

# ── 9. Health page freshness (server_updater / AST_update_AMI2.pl) ──
# The "ASTupdate" screen check in section 1 only proves a screen SOCKET
# exists — it does not prove AST_update_AMI2.pl is still alive inside it
# (a wrapper can survive after the inner perl process has died) or that
# it's actually writing fresh heartbeats. This directly checks the data
# the admin Health page reads, since a stale value here means every agent
# sees a red Health row and a frozen server TIME column.
echo -e "\n── 9. Health Page Freshness ──"
if pgrep -f "AST_update_AMI2.pl" &>/dev/null || pgrep -f "AST_update.pl" &>/dev/null; then
  echo -e "  $PASS AST_update process is running"
else
  echo -e "  $FAIL AST_update_AMI2.pl / AST_update.pl NOT running — Health page will go red and TIME will freeze"
  echo -e "        Fix: screen -d -m -S ASTupdate /usr/share/astguiclient/AST_update_AMI2.pl"
fi
LAST_UPDATE_AGE=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" \
  -se "SELECT TIMESTAMPDIFF(SECOND, last_update, NOW()) FROM server_updater WHERE server_ip='$SERVER_IP';" 2>/dev/null)
if [ -z "$LAST_UPDATE_AGE" ]; then
  echo -e "  $WARN server_updater — no row for $SERVER_IP (fresh install or IP mismatch)"
elif [ "$LAST_UPDATE_AGE" -gt 60 ]; then
  echo -e "  $FAIL server_updater.last_update is ${LAST_UPDATE_AGE}s stale — AST_update_AMI2.pl is dead or stuck"
else
  echo -e "  $PASS server_updater.last_update is ${LAST_UPDATE_AGE}s old (fresh)"
fi

# ── 10. WebRTC / PJSIP config sanity ─────────────────────────
echo -e "\n── 10. WebRTC / PJSIP Config ──"
PJSIP_CONF="/etc/asterisk/pjsip.conf"
if [ -f "$PJSIP_CONF" ]; then
  grep -q "SERVER_EXTERNAL_IP" "$PJSIP_CONF" \
    && echo -e "  $FAIL SERVER_EXTERNAL_IP placeholder still in pjsip.conf — never replaced with real IP (causes recurring getaddrinfo errors in the Asterisk CLI)" \
    || echo -e "  $PASS No SERVER_EXTERNAL_IP placeholder in pjsip.conf"

  if grep -q '^\[webrtc_template\]' "$PJSIP_CONF"; then
    if grep -A20 '^\[webrtc_template\]' "$PJSIP_CONF" | grep -q '^webrtc=yes'; then
      echo -e "  $PASS webrtc_template has webrtc=yes"
    else
      echo -e "  $FAIL webrtc_template missing webrtc=yes / dtls_auto_generate_cert=yes — WebRTC agents will show 'webrtc: no' and never negotiate DTLS-SRTP media"
    fi
  else
    echo -e "  $WARN No [webrtc_template] found — WebRTC not configured yet (run Part 4)"
  fi
else
  echo -e "  $WARN pjsip.conf not found"
fi

WEBPHONE_URL=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" \
  -se "SELECT webphone_url FROM system_settings LIMIT 1;" 2>/dev/null)
if [ -z "$WEBPHONE_URL" ]; then
  echo -e "  $FAIL system_settings.webphone_url is empty — agent screen webphone iframe will not render for any webphone agent"
  echo -e "        Fix: UPDATE system_settings SET webphone_url='https://YOUR_DOMAIN/hulkphone/hulkphone.php';"
else
  echo -e "  $PASS system_settings.webphone_url = $WEBPHONE_URL"
fi

echo -e "\n============================================================"
echo " Audit complete — $(date)"
echo "============================================================"
