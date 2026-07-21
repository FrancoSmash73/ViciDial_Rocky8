#!/bin/bash
###############################################################################
# php-error-signal.sh
#
# Surfaces REAL PHP errors from the php-fpm log by filtering out ViciDial's
# benign legacy boilerplate (~97% of the log is "Undefined variable" from
# upstream code that intentionally relies on PHP treating them as null/'').
#
# Prints NOTHING when there is no signal — so cron only mails you when it
# matters (MAILTO=root). Always appends a one-line summary to the digest log.
#
# Usage:  php-error-signal.sh          # incremental: only lines since last run
#         php-error-signal.sh --all    # scan the whole log, don't move the marker
#         php-error-signal.sh --status # show marker/log state and exit
###############################################################################
set -uo pipefail

LOG=${LOG:-/var/log/php-fpm/www-error.log}
STATE_DIR=/var/lib/php-error-signal
STATE="$STATE_DIR/offset"
DIGEST=/var/log/php-error-signal.log
MAX_GROUPS=25          # cap distinct messages listed per report

# --- NOISE ------------------------------------------------------------------
# ViciDial upstream legacy sloppiness. Benign: PHP evaluates these to null/''
# and the code depends on that. Do NOT "fix" them in the source — those files
# are stock upstream and get overwritten on every ViciDial upgrade.
# If some other message turns out to be chatty and harmless, add it HERE.
#
# "Trying to access array offset on null" is the same class — Oliver's TODO
# independently classified it as benign PHP8 legacy. It fires on every agent
# login (phone_only.php), so left unfiltered it would make this tool cry wolf.
NOISE='Undefined variable|Undefined array key|Undefined index|Undefined offset|Undefined property|Trying to access array offset'

# --- CRITICAL ---------------------------------------------------------------
# Never suppressed, always shouted. A parse/fatal error means a page is DEAD.
# (This is exactly the class of bug that left 9 agent files broken for 6 days.)
CRITICAL='PHP Parse error|PHP Fatal error'

SCAN_ALL=0
case "${1:-}" in
    --all)    SCAN_ALL=1 ;;
    --status) ;;
    "")       ;;
    *) echo "usage: $(basename "$0") [--all|--status]" >&2; exit 2 ;;
esac

mkdir -p "$STATE_DIR"
[ -r "$LOG" ] || { echo "php-error-signal: cannot read $LOG" >&2; exit 1; }

SIZE=$(stat -c%s "$LOG")
OFFSET=$(cat "$STATE" 2>/dev/null || echo 0)
case "$OFFSET" in ''|*[!0-9]*) OFFSET=0 ;; esac

if [ "${1:-}" = "--status" ]; then
    echo "log:    $LOG ($SIZE bytes)"
    echo "marker: $OFFSET  ($((SIZE - OFFSET)) bytes unread)"
    echo "digest: $DIGEST"
    exit 0
fi

# Log truncated or rotated out from under us -> restart from the top of the new file.
ROTATED=""
if [ "$OFFSET" -gt "$SIZE" ]; then
    ROTATED=" [log rotated/truncated since last run — resumed from start]"
    OFFSET=0
fi
[ "$SCAN_ALL" -eq 1 ] && OFFSET=0

NEW=$(tail -c "+$((OFFSET + 1))" "$LOG" 2>/dev/null)

# Advance the marker immediately, so a crash mid-report can't cause a re-mail loop.
# --all is a read-only inspection: it must not move the marker.
[ "$SCAN_ALL" -eq 1 ] || printf '%s\n' "$SIZE" > "$STATE"

[ -n "$NEW" ] || exit 0

ALL_PHP=$(printf '%s\n' "$NEW" | grep 'PHP ' || true)

# CRITICAL is extracted from ALL_PHP *before* the NOISE filter is applied, so a
# parse/fatal error can never be suppressed by a NOISE pattern that happens to
# appear in its text. NOISE only ever filters non-critical lines.
CRIT=$( printf '%s\n' "$ALL_PHP" | grep -E  "$CRITICAL" || true)
OTHER=$(printf '%s\n' "$ALL_PHP" | grep -Ev "$CRITICAL" | grep -Ev "$NOISE" || true)

n_all=$( printf '%s\n' "$ALL_PHP" | grep -c . || echo 0)
n_crit=$(printf '%s\n' "$CRIT"    | grep -c . || echo 0)
n_other=$(printf '%s\n' "$OTHER"  | grep -c . || echo 0)
[ -n "$CRIT"  ] || n_crit=0
[ -n "$OTHER" ] || n_other=0
n_noise=$((n_all - n_crit - n_other))

if [ "$n_crit" -eq 0 ] && [ "$n_other" -eq 0 ]; then
    # Nothing but boilerplate. Record it, stay silent.
    printf '%s  quiet — %s boilerplate lines, 0 signal%s\n' \
        "$(date '+%F %T')" "$n_all" "$ROTATED" >> "$DIGEST"
    exit 0
fi

# Collapse identical messages (drop the leading [timestamp]) and count them.
group() { sed 's/^\[[^]]*\] *//' | sort | uniq -c | sort -rn | head -"$MAX_GROUPS"; }

{
    echo "PHP error signal — $(hostname) — $(date '+%F %T')"
    echo "New PHP log lines: $n_all   (suppressed as ViciDial boilerplate: $n_noise)$ROTATED"
    echo

    if [ "$n_crit" -gt 0 ]; then
        echo "!! CRITICAL ($n_crit) — parse/fatal errors. These pages are DEAD, not just noisy:"
        printf '%s\n' "$CRIT" | group | sed 's/^/   /'
        echo
        echo "   If these are 'unexpected token \"<\"' on line 2, suspect a double <?php from a"
        echo "   skin re-install. Gate: for f in /var/www/html/{agc,vicidial}/*.php; do php -l \"\$f\"; done"
        echo
    fi

    if [ "$n_other" -gt 0 ]; then
        echo "Signal ($n_other) — non-boilerplate warnings worth a look:"
        printf '%s\n' "$OTHER" | group | sed 's/^/   /'
        echo
    fi

    echo "Filtered as known-benign: $NOISE"
    echo "Tune the NOISE list in $0 if something above is harmless and chatty."
} | tee -a "$DIGEST"
