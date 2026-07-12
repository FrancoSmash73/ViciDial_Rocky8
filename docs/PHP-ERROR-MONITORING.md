# PHP error monitoring & the parse-error gate

ViciDial's php-fpm error log is ~97% benign noise — stock upstream code relies on PHP
treating undefined variables as `null`/`''`, so it emits `Undefined variable` warnings
constantly (one live box logged 850,160 of them). A genuinely broken page hides under that
volume. On one server a parse error left **9 agent pages dead for 6 days** with no alarm,
because the errors were buried 40× under the harmless chatter.

**Do not "fix" the undefined-variable warnings.** Those files are stock upstream ViciDial
(~263 files, ~380k lines) and get replaced wholesale on every upgrade. Editing them means
forking upstream, losing it on the next update, and risking turning a loud warning into a
silent logic bug. The right move is: leave the noise, cap the log, and **alert on what's left.**

## `php-error-signal.sh` (installed by part1)

Reads only the log lines since its last run (byte-offset marker), strips the known-benign
boilerplate, and prints **nothing** unless real signal remains. With `MAILTO=root` in cron it
mails you only when it matters.

- **CRITICAL** (never suppressed): `PHP Parse error` / `PHP Fatal error` — a page is *dead*.
  Matched *before* the noise filter, so a fatal can't be dropped because its text contains a
  noise phrase.
- **Signal**: any other non-boilerplate warning (failed DB calls, bad args, real deprecations).
- **Noise** (suppressed): `Undefined variable|array key|index|offset|property`, plus
  `Trying to access array offset on null` (benign PHP 8 legacy; fires on every agent login).

```bash
php-error-signal.sh            # incremental (what cron runs) — silent when quiet
php-error-signal.sh --all      # scan whole log now; read-only, does NOT move the marker
php-error-signal.sh --status   # marker position / unread bytes
```

Deployed automatically by `vicidial_rocky10_part1_install.sh` (cron `/etc/cron.d/php-error-signal`,
hourly at :17). Assumes deprecations are already suppressed at the ini (part1 does this) and mail
resolves (`command -v sendmail`).

**Known limit:** lines written between a run and a log rotation land in the rotated-out file and
aren't scanned. A *persistent* break re-errors into the new file and is caught next run (that's the
6-day case); only a one-off transient in that window can be missed. Reading rotated files back was
rejected as too risky on a production dialer.

## The parse-error gate — run after ANY bulk edit of the ViciDial PHP tree

A skin re-install, an upgrade, a mass sed — anything touching many PHP files — can leave a file
that fatals on every request. `php-error-signal.sh` catches it at runtime, but the cheap one-time
gate is:

```bash
# Does every PHP file still parse?
for f in /var/www/html/agc/*.php /var/www/html/vicidial/*.php; do
    php -l "$f" >/dev/null 2>&1 || echo "BROKEN: $f"
done
```

`php -l` clean is *the* gate. If you also patched files in bulk, a **constant size-delta** across
all patched files (vs their `.bak`) is a strong body-integrity signal — a parse error stops the
parser at the break, so `php -l` alone doesn't prove the rest of the file survived.

## Note: the vicidial ini filename varies

Some installs ship `/etc/php.d/99-vicidial.ini`, others `/etc/php.d/vicidial.ini`. Glob for it
(`ls /etc/php.d/*vicidial*.ini`) rather than assuming a prefix. **Never** create a second ini to
satisfy a hardcoded path — two files setting `error_reporting` is a footgun.
