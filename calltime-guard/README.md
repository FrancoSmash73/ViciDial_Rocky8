# calltime-guard — hard outbound call-time protection

Why: stock ViciDial treats the calling window as an ordinary campaign setting. One admin saving a campaign as
`24hours` made it auto-dial past 9 pm local (and `AST_VDauto_dial.pl` never rechecks a lead after it is in the
hopper). This adds three independent layers that do not depend on the admin UI settings.

| Layer | What | Where |
|-------|------|-------|
| 1 — dial-time hard stop | Every lead is re-checked right before it is dialed; blocked leads are dropped from the hopper | `Rocky10CallTime.pm` + patch to `AST_VDauto_dial.pl` (`apply_vdauto_guard.py`); manual dialing: `rocky10_calltime.inc.php` + hooks in `agc/vdc_db_query.php` (`apply_vdc_guard.py`) |
| 2 — settings protection | MariaDB triggers refuse any call time / state call time / holiday / campaign / list change that lets calling start before 08:00 or end after 21:00 | `calltime_triggers.sql` |
| 3 — alerting | Per-minute watcher mails root on any call placed outside its legal window, setting drift, or a missing guard | `vicidial-calltime-watch.pl` + `.service`/`.timer` |

## Rules (same in Perl, PHP and SQL)
- Company window **09:00–21:00 lead-local** (`gmt_offset_now`, DST-adjusted). A state's stricter window is
  intersected, never widened (AL/FL/LA/MA/MD/MS/OK/WA/WY end 20:00; IN/NV/UT 09–20; ME 09–17; RI 09–18, Sat 10–17;
  Sunday closed AL/LA/MS/SD/RI; TX Sunday from 12:00; PA Sunday from 13:30; KY opens 10:00). The table is copied from
  the stock `vicidial_state_call_times` rows — **have compliance review it**; it lives in `Rocky10CallTime.pm`
  and `rocky10_calltime.inc.php` (edit both, keep them identical).
- 2-minute safety margin off every window end (the watcher uses 0).
- `gmt_offset_now` missing / outside −10..−4 → `BAD_TZ`; offset implausible for the lead's state → `TZ_MISMATCH`.
- Lead with no/unknown state: default window, not blocked.
- Campaign **`TEST1`** is exempt from the *manual* cap and from the triggers/watcher (owner's own-number test
  campaign). Change the name in `rocky10_calltime.inc.php` (`$r10_exempt`), `calltime_triggers.sql` (3 places) and
  `vicidial-calltime-watch.pl` (`$EXEMPT`), or remove the exemption if you don't have such a campaign.

## Install / upgrade (automatic)
`vicidial_rocky10_part2_install.sh` stages these files to `/usr/local/share/vicidial-rocky10/calltime-guard/`,
installs the watcher + timer, and its `vicidial-rocky10-repatch` script (sections 8, 8b, 8c) applies the Perl
patch, the PHP hooks and the triggers — and re-applies them after any `install.pl` re-run or ViciDial upgrade
(each patch is verified with `perl -c` / `php -l` and rolled back on failure). Triggers need DB root over the local
socket. The watcher mails `root` — configure an MTA/relay and a `root` alias or it only logs.

## Tests (no live calls, no live data touched)
```
cd calltime-guard
perl -I. test_calltime.pl                 # 57 rule cases
perl -I. dryrun_hopper.pl                 # what the guard would block in the live hopper right now
# triggers: build a scratch DB with copies of the 5 tables, load calltime_triggers.sql, then
./test_triggers.sh <scratchdb>            # 27 cases; refuses to run against 'asterisk'
/usr/local/sbin/vicidial-calltime-watch --dry-run --since <epoch>   # audit history without mailing
```
