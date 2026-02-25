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

# ── Detect DB password from /etc/astguiclient.conf ───────────
DB_PASS=$(grep -oP '(?<=VARDB_pass => )[^\s]+' /etc/astguiclient.conf 2>/dev/null | head -1)
if [ -z "$DB_PASS" ]; then
  echo -e "  ${WARN} Could not detect DB password from /etc/astguiclient.conf"
  read -rsp "  Enter MariaDB root password manually: " DB_PASS
  echo
fi

# Helper: query a table count silently
check_table() {
  mysql -uroot asterisk -p"$DB_PASS" -se "SELECT COUNT(*) FROM $1;" 2>/dev/null
}

# ── 1. Screen sockets ────────────────────────────────────────
echo -e "\n── 1. Screen Sockets ──"
SCREENS=$(screen -ls 2>/dev/null | grep -c "Detached\|Attached")
echo "  Found: $SCREENS sockets"
screen -ls 2>/dev/null | grep -E "Detached|Attached" | awk '{print "  "$0}'
EXPECTED="ASTupdate ASTsend ASTlisten ASTVDauto ASTSIPlogger ASTConfUpdater ASTVDremote ASTVDadapt ASTfastlog ASTemail ASTconf3way asterisk"
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
  AK=$(mysql -uroot asterisk -p"$DB_PASS" \
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

echo -e "\n============================================================"
echo " Audit complete — $(date)"
echo "============================================================"
