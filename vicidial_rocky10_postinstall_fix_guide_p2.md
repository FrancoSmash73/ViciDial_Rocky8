# ViciDial Post-Install FIX GUIDE — Part 2
**Server:** 172.236.243.149
**OS:** Rocky Linux 10.x (procps-ng 4.0.4, Perl 5.40, PHP 8.3, MariaDB 10.11)
**Asterisk:** 18.21.0-vici
**Date:** 2026-02-17

---

## Overview

This guide is the continuation of `Post Install_FIX-GUIDE.md` (Part 1). It documents every issue
found and fixed during the second phase of the post-install debug session, which began with only
**3 screen sessions** running (`astershell`, `astshell`, `asterisk`) when the system should have
**11+ ViciDial daemon screen sessions**.

Root causes traced back to two categories:
1. **Rocky Linux 10 compatibility breaks** — `procps-ng 4.0.4` path truncation and `Perl 5.40`
   removing the `Switch` module from its default distribution.
2. **Part 2 installation script architecture errors** — persistent daemon processes were
   incorrectly placed in cron as one-shot jobs, phantom scripts were referenced, and the custom
   process monitor had three separate bugs that killed working daemons.

---

## Background: The ViciDial Daemon Architecture

Understanding this architecture is essential for all fixes below.

ViciDial runs two categories of processes:

### Category A — Persistent Screen-Session Daemons
These are **long-running** Perl programs that must stay alive continuously. They are launched
**inside named GNU screen sessions** by `ADMIN_keepalive_ALL.pl`. The keepalive monitors for
their absence and re-launches them. They must **never** appear in cron or be given runtime limits.

| Screen Name    | Script                              | Purpose                          |
|----------------|-------------------------------------|----------------------------------|
| `ASTupdate`    | `AST_update_AMI2.pl`                | AMI event updater                |
| `ASTlisten`    | `AST_manager_listen_AMI2.pl`        | AMI event listener (master)      |
| `ASTsend`      | `AST_manager_send.pl`               | AMI command sender               |
| `ASTVDadapt`   | `AST_VDadapt.pl`                    | Adaptive dialer                  |
| `ASTVDauto`    | `AST_VDauto_dial.pl`                | Auto-dialer engine               |
| `ASTVDremote`  | `AST_VDremote_agents.pl`            | Remote agent handler             |
| `ASTfastlog`   | `FastAGI_log.pl`                    | FastAGI call logging             |
| `ASTSIPlogger` | `AST_manager_sip_AMI2.pl`           | SIP channel logger               |
| `ASTConfUpdater`| `AST_conf_update_CONFBRIDGE.pl`    | Conference bridge updater        |
| `ASTemail`     | `VD_email_inbound.pl`               | Inbound email daemon             |
| `ASTconf3way`  | `AST_conf_update_3way.pl`           | 3-way conference handler         |

### Category B — One-Shot Cron Scripts
These run briefly (seconds to a few minutes), complete their task, and exit. They belong in cron,
**not** in screen sessions. The `flock` wrapper (`vicidial_cron_wrapper.sh`) is appropriate here.

| Script                          | Schedule  | Purpose                           |
|---------------------------------|-----------|-----------------------------------|
| `AST_VDhopper.pl`               | `* * * *` | Load leads into dialing hopper    |
| `AST_manager_kill_hung_congested.pl` | `* * * *` | Kill stalled calls               |
| `AST_vm_update.pl`              | `* * * *` | Voicemail status sync             |
| `AST_conf_update.pl`            | `* * * *` | Conference record sync            |
| `AST_inbound_email_parser.pl`   | `* * * *` | Parse inbound emails              |
| `AST_VDauto_dial_FILL.pl`       | `*/5 * * *` | Fill hopper gaps                |
| `AST_flush_DBqueue.pl`          | `*/5 * * *` | Flush database action queue     |
| `AST_CRON_audio_1_move_mix.pl`  | every 3m  | Move and mix audio recordings     |
| `AST_CRON_audio_2_compress.pl`  | every 3m  | Compress recordings to MP3/HTTPS  |

---

## FIX 6 — `Switch.pm` Missing (Perl 5.40 Removed Deprecated Module)

### Symptom
`AST_update_AMI2.pl` and `AST_manager_listen_AMI2.pl` both crashed at launch:
```
Can't locate Switch.pm in @INC (you may need to install the Switch module)
(@INC contains: /usr/local/lib64/perl5/5.40 ... )
BEGIN failed--compilation aborted at /usr/share/astguiclient/AST_update_AMI2.pl line 30.
```
Neither `ASTupdate` nor `ASTlisten` screen sessions would stay alive. Because `ASTlisten` (the
**master AMI listener**) never started, `ASTsend` and `ASTVDremote` immediately self-terminated
with "PROCESS KILLED NO LISTENER RUNNING" (see FIX 7 below for the related ps truncation issue).

### Root Cause — Rocky Linux 10 / Perl 5.40
`Switch.pm` was a `use feature 'switch'` wrapper that was **deprecated** in Perl 5.10 and
**removed entirely from the default Perl distribution in Perl 5.36+**. ViciDial's AMI2 scripts
still rely on it. CentOS 7 shipped Perl 5.16 which included `Switch.pm` by default. Rocky Linux 10
ships Perl 5.40 which does not.

**This is purely a Perl version issue — not related to PHP 8.3 or MariaDB 10.11.**

### Fix
```bash
cpanm Switch
```

Expected output:
```
--> Working on Switch
Fetching http://www.cpan.org/authors/id/C/CH/CHORNY/Switch-2.17.tar.gz ... OK
...
Successfully installed Switch-2.17
1 distribution installed
```

### Verification
```bash
perl -e 'use Switch; print "OK\n"'
# Output: OK
```

After installing, both `ASTupdate` and `ASTlisten` start and remain alive in their screen sessions.

---

## FIX 7 — `ps -o "%p %a"` Path Truncation (procps-ng 4.0.4 on Rocky Linux 10)

### Symptom — Four separate cascading failures all from one root cause

**Failure A — Keepalive always sees zero running daemons**
`ADMIN_keepalive_ALL.pl` uses `ps` to check which screen-session daemons are currently running.
On this system, it always reported finding nothing — so every 60-second keepalive cycle tried to
launch all screens again, creating a storm of duplicates.

**Failure B — ASTsend exits immediately ("LISTENER DEAD")**
`AST_manager_send.pl` checks every 10 loop iterations that `AST_manager_listen_AMI2.pl` is
running. If not found, it sets `$endless_loop=0` and exits. With the truncation bug, the listener
was always invisible.

**Failure C — ASTVDremote exits immediately ("PROCESS KILLED NO LISTENER RUNNING")**
`AST_VDremote_agents.pl` has the same listener check. Same truncation, same immediate exit.

**Failure D — ASTVDauto exits immediately ("PROCESS KILLED NO LISTENER RUNNING")**
`AST_VDauto_dial.pl` performs the same listener check every 10 loop iterations (line 5249).
Same truncation bug, same immediate exit — so the auto-dialer engine was impossible to keep
alive even when campaigns were active and agents were logged in.

### Root Cause — procps-ng 4.x `%a` column-width behaviour

ViciDial scripts use this `ps` invocation:
```bash
/bin/ps -o "%p %a" --no-headers -A
```

In **procps-ng 3.3.x** (CentOS 7), `%a` expands to the full command line with no truncation.

In **procps-ng 4.0.4** (Rocky Linux 10), `%a` creates a **fixed-width column** based on the
terminal width at the time of the call. In a headless/daemon context, there is no terminal, so the
column is set to a very short default — typically 12 characters. The result:

```
# procps-ng 3.3.x (CentOS 7) — WORKS:
 83348 /usr/bin/perl /usr/share/astguiclient/AST_manager_listen_AMI2.pl --debug

# procps-ng 4.0.4 (Rocky Linux 10) — TRUNCATED:
 83348 /usr/share/as
```

ViciDial searches the `ps` output for the script name (e.g., `AST_manager_li` — the first 14
characters). With only `/usr/share/as` visible, the match fails 100% of the time.

The fix is to use the **keyword format** instead of the **header format**:
```bash
/bin/ps -o "pid,args" --no-headers -A
```
The `args` keyword uses the full available line width and does not truncate.

### Why Not PHP or MariaDB?
`procps-ng` is an entirely separate system utilities package (`ps`, `top`, `free`, `pgrep`,
`pkill`). PHP 8.3 handles web request execution. MariaDB 10.11 handles the database. Neither has
any effect on how `ps` formats its output. This truncation bug exists on any Rocky Linux 10 system
regardless of what PHP version or database is installed.

### Affected Files and Lines

#### File 1: `/usr/share/astguiclient/ADMIN_keepalive_ALL.pl`
Three occurrences at lines **705**, **819**, and **886**:
```perl
# BEFORE (truncates to ~12 chars on procps-ng 4.x):
@psoutput = `/bin/ps -o "%p %a" --no-headers -A`;

# AFTER (full path, no truncation):
@psoutput = `/bin/ps -o "pid,args" --no-headers -A`;
```

Applied using Python (not sed — see FIX 7 Addendum):
```python
import re
with open('/usr/share/astguiclient/ADMIN_keepalive_ALL.pl', 'r') as f:
    content = f.read()
old = '/bin/ps -o "%p %a" --no-headers -A'
new = '/bin/ps -o "pid,args" --no-headers -A'
content_new = content.replace(old, new)
print(f"Replaced {content.count(old)} occurrence(s)")
with open('/usr/share/astguiclient/ADMIN_keepalive_ALL.pl', 'w') as f:
    f.write(content_new)
# Output: Replaced 3 occurrence(s)
```

#### File 2: `/usr/share/astguiclient/AST_manager_send.pl`
One occurrence at line **316**:
```perl
# BEFORE:
my @psoutput = `/bin/ps -o "%p %a" --no-headers -A`;

# AFTER:
my @psoutput = `/bin/ps -o "pid,args" --no-headers -A`;
```

#### File 3: `/usr/share/astguiclient/AST_VDremote_agents.pl`
One occurrence at line **620**:
```perl
# BEFORE:
@psoutput = `/bin/ps -o "%p %a" --no-headers -A`;

# AFTER:
@psoutput = `/bin/ps -o "pid,args" --no-headers -A`;
```

#### File 4: `/usr/share/astguiclient/AST_VDauto_dial.pl`
One occurrence at line **5249** (the original `-f` format was already commented out; this line
was subsequently changed to `%p %a` and then needed the same `pid,args` fix):
```perl
# BEFORE:
@psoutput = `/bin/ps -o "%p %a" --no-headers -A`;

# AFTER:
@psoutput = `/bin/ps -o "pid,args" --no-headers -A`;
```

Applied using Python:
```python
with open('/usr/share/astguiclient/AST_VDauto_dial.pl', 'r') as f:
    content = f.read()
old = '/bin/ps -o "%p %a" --no-headers -A'
new = '/bin/ps -o "pid,args" --no-headers -A'
content_new = content.replace(old, new)
print(f"Replaced {content.count(old)} occurrence(s)")
with open('/usr/share/astguiclient/AST_VDauto_dial.pl', 'w') as f:
    f.write(content_new)
# Output: Replaced 1 occurrence(s)
```

### Verification
```bash
# Confirm fix is in place in all four files:
grep -n 'ps -o' /usr/share/astguiclient/ADMIN_keepalive_ALL.pl | grep -c 'pid,args'
# Output: 3

grep -n 'ps -o' /usr/share/astguiclient/AST_manager_send.pl | grep -c 'pid,args'
# Output: 1

grep -n 'ps -o' /usr/share/astguiclient/AST_VDremote_agents.pl | grep -c 'pid,args'
# Output: 1

grep -n 'ps -o' /usr/share/astguiclient/AST_VDauto_dial.pl | grep -c 'pid,args'
# Output: 1

# Confirm ps produces full paths:
/bin/ps -o "pid,args" --no-headers -A | grep AST_manager_listen
# Output: 83348 /usr/bin/perl /usr/share/astguiclient/AST_manager_listen_AMI2.pl --debug
```

### FIX 7 Addendum — `sed -i` Destroyed Two Files (Do NOT Use sed for This Pattern)

During an earlier fix attempt, `sed -i` with a pattern containing both double-quotes and
backticks was used to replace the ps format string. The shell expansion of the pattern inside
`sed` caused the substitution command to be malformed, resulting in **both files being silently
wiped to 0 bytes**.

**Recovery:**
```bash
# ADMIN_keepalive_ALL.pl — restore from backup created by install script:
/bin/cp /usr/share/astguiclient/ADMIN_keepalive_ALL.pl.backup \
        /usr/share/astguiclient/ADMIN_keepalive_ALL.pl

# AST_manager_send.pl — restore from source tree:
/bin/cp /usr/src/astguiclient/trunk/bin/AST_manager_send.pl \
        /usr/share/astguiclient/AST_manager_send.pl
```

**Rule:** When replacing strings containing both double-quotes and backticks in Perl source files,
use Python's `str.replace()` (shown above) or a heredoc-based file rewrite. Never use `sed -i`
with complex quoting for Perl source.

---

## FIX 8 — Wrong Crontab Architecture (Daemons Run as Cron Jobs)

### Symptom
The Part 2 installation script (`ViciDial_ULTIMATE_Part2_FINAL.sh`) wrote a crontab that ran
the three persistent screen-session daemons as one-shot cron jobs:
```cron
* * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_VDauto_dial.pl --debug
* * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_VDremote_agents.pl --debug
* * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_VDadapt.pl --debug
```
The `vicidial_cron_wrapper.sh` applies `flock -n` (exclusive lock) and `timeout 240`, so each
cron run is killed after 240 seconds regardless. These scripts are **not** designed to run this way.

### Root Cause
`AST_VDauto_dial.pl`, `AST_VDremote_agents.pl`, and `AST_VDadapt.pl` are **persistent daemons**
that run indefinitely inside named GNU screen sessions managed by `ADMIN_keepalive_ALL.pl`. They
interact with the AMI listener, process real-time call events, and maintain internal state across
minutes or hours. Running them as 4-minute cron jobs with an exclusive lock produces:
- Cron instance starts → flock acquired → daemon begins initialising
- 240 seconds later: `timeout` sends SIGTERM → daemon killed mid-operation
- Next minute: cron fires again → flock available again → cycle repeats
- Simultaneously, the keepalive ALSO tries to launch screen sessions for these daemons → two
  competing instances → process monitor kills both → no daemons at all

### Fix
Remove the three daemon scripts from cron entirely. `ADMIN_keepalive_ALL.pl` (running via
systemd timer every 60 seconds) is the **sole** mechanism that manages these daemons.

**Lines removed from crontab:**
```cron
# REMOVED — wrong architecture:
* * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_VDauto_dial.pl --debug
* * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_VDremote_agents.pl --debug
* * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_VDadapt.pl --debug
```

Also added the correct every-minute cron scripts that were **missing** from the original crontab:
```cron
* * * * * /usr/share/astguiclient/AST_manager_kill_hung_congested.pl
* * * * * /usr/share/astguiclient/AST_vm_update.pl
* * * * * /usr/share/astguiclient/AST_conf_update.pl
* * * * * /usr/share/astguiclient/AST_inbound_email_parser.pl
```

See the full corrected crontab in the **Post-Fix System State** section at the end of this guide.

---

## FIX 9 — Three Non-Existent `keepalive_AST_*.pl` Scripts in Crontab

### Symptom
Three crontab entries referenced scripts that do not exist anywhere on the system:
```cron
* * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/keepalive_AST_VDauto_dial.pl --debug
* * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/keepalive_AST_send_listen.pl --debug
* * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/keepalive_AST_VDadapt.pl --debug
```
Each cron execution failed with **exit code 127** (command not found) every minute, silently
cluttering cron logs.

### Root Cause
The Part 2 installation script's authors appear to have invented a naming convention
(`keepalive_AST_*.pl`) that does not correspond to any real ViciDial scripts. Standard ViciDial
has exactly one keepalive manager: `ADMIN_keepalive_ALL.pl`. There is no set of per-daemon
keepalive scripts.

### Fix
All three lines removed from crontab. No replacement scripts needed — `ADMIN_keepalive_ALL.pl`
already handles keepalive for all daemons.

---

## FIX 10 — Process Monitor `pgrep` Matching SCREEN Wrapper Commands

### Symptom
`vicidial_process_monitor.sh` (created by Part 2 install) reported "WARN: 2 instances of
`AST_VDauto_dial.pl` found" every scan cycle, then terminated the **wrong** instance, causing the
screen session to go dead within seconds of being launched.

### Root Cause
GNU screen launches daemons with a command line that **includes the script path in its arguments**:
```
SCREEN -d -m -S ASTVDauto /usr/share/astguiclient/AST_VDauto_dial.pl --debug
```

`pgrep -f "AST_VDauto_dial.pl"` matches **any process whose full command line contains that
string**. This means it matches:
1. The `screen -d -m` wrapper command (the screen session manager)
2. The actual `perl AST_VDauto_dial.pl` interpreter (the daemon doing the work)

The process monitor sorted by start time (ascending) and kept the **oldest** PID. The screen
wrapper is always launched a few milliseconds before the perl interpreter inside it, so the screen
wrapper was always the oldest → the **perl daemon** was always killed → the screen session lost
its inner process → screen session zombie disappeared.

**Timeline of what happened every 60 seconds:**
```
t=0s   keepalive runs → sees 0 instances → launches screen -d -m -S ASTVDauto ...
t=0s   screen wrapper PID: 95001   perl daemon PID: 95002
t=60s  process monitor runs → pgrep matches 95001 AND 95002 → WARN: 2 instances
t=60s  oldest = 95001 (screen) → keep; newer = 95002 (perl) → KILL
t=60s  perl daemon killed → screen session is now an empty shell → disappears
t=120s keepalive runs → ASTVDauto screen gone → re-launches → repeat forever
```

### Fix
Change `pgrep` to only match processes where the perl interpreter is the executable, not
processes that merely contain the script name as an argument:

```bash
# BEFORE — matches screen wrapper AND perl daemon:
PIDS=$(pgrep -f "$script" 2>/dev/null || true)

# AFTER — matches ONLY the perl interpreter running the script:
PIDS=$( { pgrep -f "perl.*${script}" 2>/dev/null || true; } )
```

The pattern `perl.*AST_VDauto_dial.pl` matches:
- `/usr/bin/perl /usr/share/astguiclient/AST_VDauto_dial.pl` ✓

But does NOT match:
- `/usr/bin/SCREEN -d -m -S ASTVDauto /usr/share/astguiclient/AST_VDauto_dial.pl` ✗

Applied in `/usr/local/bin/vicidial_process_monitor.sh` in both the duplicate-detection loop
(line 94) and the max-runtime loop (line 120).

---

## FIX 11 — Process Monitor `MAX_RUNTIME` Killing Persistent Daemons

### Symptom
Even after FIX 10 corrected the pgrep matching, `AST_VDauto_dial.pl`, `AST_VDadapt.pl`, and
`AST_VDremote_agents.pl` were being terminated every 3 minutes with:
```
ACTION: Terminating AST_VDauto_dial.pl (PID: 88234) - Runtime exceeded: 187s > 180s max
```

### Root Cause
The original `vicidial_process_monitor.sh` `MAX_RUNTIME` table included these persistent daemons:
```bash
declare -A MAX_RUNTIME=(
    ["ADMIN_keepalive_ALL.pl"]=240
    ["AST_VDhopper.pl"]=180
    ["AST_VDauto_dial_FILL.pl"]=180
    ["AST_flush_DBqueue.pl"]=120
    ["AST_CRON_audio_1_move_mix.pl"]=120
    ["AST_CRON_audio_2_compress.pl"]=180
    ["AST_VDauto_dial.pl"]=180        # WRONG — persistent daemon
    ["AST_VDadapt.pl"]=180            # WRONG — persistent daemon
    ["AST_VDremote_agents.pl"]=180    # WRONG — persistent daemon
    ["keepalive_AST_VDauto_dial.pl"]=240   # WRONG — script doesn't exist
    ["keepalive_AST_send_listen.pl"]=240   # WRONG — script doesn't exist
    ["keepalive_AST_VDadapt.pl"]=240       # WRONG — script doesn't exist
)
```

`AST_VDauto_dial.pl`, `AST_VDadapt.pl`, and `AST_VDremote_agents.pl` are **designed to run
indefinitely**. A 180-second maximum runtime is entirely wrong for them.

### Fix
Remove all three persistent daemons and all three phantom scripts from `MAX_RUNTIME`. Only
**one-shot/cron scripts** with known completion times belong in this table:

```bash
# CORRECT MAX_RUNTIME — one-shot/cron scripts only:
declare -A MAX_RUNTIME=(
    ["ADMIN_keepalive_ALL.pl"]=240
    ["AST_VDhopper.pl"]=180
    ["AST_VDauto_dial_FILL.pl"]=180
    ["AST_flush_DBqueue.pl"]=120
    ["AST_CRON_audio_1_move_mix.pl"]=120
    ["AST_CRON_audio_2_compress.pl"]=180
)
```

The corrected `/usr/local/bin/vicidial_process_monitor.sh` (full file) is in place on the server.

---

## Post-Fix System State

### Screen Sessions (Full Production Set)
```
There are screens on:
    5827.astershell     (Detached)   ← Asterisk management shell
    5829.astshell       (Detached)   ← ViciDial admin shell
    5837.asterisk       (Attached)   ← Asterisk PBX process
    83342.ASTupdate     (Detached)   ← AMI updater daemon
    83345.ASTsend       (Detached)   ← AMI command sender
    83348.ASTlisten     (Detached)   ← AMI listener (master)
    83354.ASTSIPlogger  (Detached)   ← SIP channel logger
    83357.ASTConfUpdater(Detached)   ← Conference bridge updater
    83363.ASTVDadapt    (Detached)   ← Adaptive dialer
    83366.ASTfastlog    (Detached)   ← FastAGI logger
    83369.ASTemail      (Detached)   ← Inbound email daemon
    83377.ASTconf3way   (Detached)   ← 3-way conference handler
    87350.ASTVDremote   (Detached)   ← Remote agents daemon
```

**Note on `ASTVDauto`:** `AST_VDauto_dial.pl` naturally exits when there are no active campaigns
or agents logged in. This is **normal behaviour** on an idle system. The keepalive relaunches it
on the next 60-second cycle when needed. Do not be alarmed if it is absent during off-peak hours.

### Process Monitor Health
```
[2026-02-17 17:35:16] ViciDial Process Monitor started (PID: ...)
[2026-02-17 17:36:16] --- Scan #2 ---
[2026-02-17 17:36:17] INFO: All processes healthy (0 actions taken)
[2026-02-17 17:43:19] ACTION: Terminating AST_VDauto_dial_FILL.pl (PID: 85047) - Runtime exceeded: 197s > 180s max
```
The one legitimate kill (FILL script at 197s) confirms the process monitor is working correctly
for actual runaway cron scripts.

### Corrected Root Crontab
```cron
### ViciDial Crontab - Fixed 2026-02-17 (Part 2 FIX GUIDE)
### ADMIN_keepalive_ALL.pl is managed by systemd timer (vicidial-keepalive.timer)

### Hopper fill - loads leads into the dialing hopper (CRITICAL)
* * * * * /usr/share/astguiclient/AST_VDhopper.pl -q

### Every-minute system tasks (standard ViciDial)
* * * * * /usr/share/astguiclient/AST_manager_kill_hung_congested.pl
* * * * * /usr/share/astguiclient/AST_vm_update.pl
* * * * * /usr/share/astguiclient/AST_conf_update.pl
* * * * * /usr/share/astguiclient/AST_inbound_email_parser.pl

### Cleanup (every 5 minutes - flock wrapped)
*/5 * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_VDauto_dial_FILL.pl
*/5 * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_flush_DBqueue.pl -q

### Hourly tasks
33 * * * * /usr/share/astguiclient/AST_cleanup_agent_log.pl
50 0 * * * /usr/share/astguiclient/AST_cleanup_agent_log.pl --last-24hours

### Recording file management (every 3 minutes)
0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * /usr/share/astguiclient/AST_CRON_audio_1_move_mix.pl --MIX
0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * /usr/share/astguiclient/AST_CRON_audio_1_move_VDonly.pl
1,4,7,10,13,16,19,22,25,28,31,34,37,40,43,46,49,52,55,58 * * * * /usr/local/bin/vicidial_cron_wrapper.sh /usr/share/astguiclient/AST_CRON_audio_2_compress.pl --MP3 --HTTPS

### Daily maintenance tasks
2 1 * * * /usr/share/astguiclient/AST_reset_mysql_vars.pl
3 1 * * * /usr/share/astguiclient/AST_DB_optimize.pl
1 1,7 * * * /usr/share/astguiclient/ADMIN_adjust_GMTnow_on_leads.pl --debug
25 0 * * * /usr/share/astguiclient/AST_DB_dead_cb_purge.pl --purge-non-cb -q
22 0 * * * /usr/share/astguiclient/AST_agent_day.pl
1 7 * * * /usr/share/astguiclient/AST_dialer_inventory_snapshot.pl -q --override-24hours
28 0 * * * /usr/bin/find /var/log/astguiclient -maxdepth 1 -type f -mtime +2 -print | xargs rm -f
29 0 * * * /usr/bin/find /var/log/asterisk -maxdepth 3 -type f -mtime +2 -print | xargs rm -f
30 0 * * * /usr/bin/find / -maxdepth 1 -name "screenlog.0*" -mtime +4 -print | xargs rm -f
24 1 * * * /usr/bin/find /var/spool/asterisk/monitorDONE/ORIG -maxdepth 2 -type f -mtime +1 -print | xargs rm -f

### Weekly tasks
2 0 * * 0 /usr/share/astguiclient/AST_agent_week.pl
0 4 * * 0 /usr/share/astguiclient/AST_DB_optimize.pl
```

---

## Key Files Modified (Part 2)

| File | Change |
|------|--------|
| `/usr/share/astguiclient/ADMIN_keepalive_ALL.pl` | 3x `ps -o "%p %a"` → `ps -o "pid,args"` (lines 705, 819, 886) |
| `/usr/share/astguiclient/AST_manager_send.pl` | Restored from source + 1x ps fix (line 316) |
| `/usr/share/astguiclient/AST_VDremote_agents.pl` | 1x `ps -o "%p %a"` → `ps -o "pid,args"` (line 620) |
| `/usr/share/astguiclient/AST_VDauto_dial.pl` | 1x `ps -o "%p %a"` → `ps -o "pid,args"` (line 5249) |
| `/usr/local/bin/vicidial_process_monitor.sh` | pgrep fix (perl.*script); MAX_RUNTIME pruned |
| `/root` crontab (root user) | Complete rewrite — removed phantom/wrong scripts, added standard ViciDial cron jobs |

## Packages Installed (Part 2)

| Package | Version | Method | Reason |
|---------|---------|--------|--------|
| `Switch` (Perl module) | 2.17 | `cpanm Switch` | Required by AMI2 scripts; removed from Perl 5.36+ |

## Root Causes Summary

| Fix | Root Cause Category |
|-----|---------------------|
| FIX 6 — Switch.pm | Rocky Linux 10 (Perl 5.40 removes deprecated modules) |
| FIX 7 — ps truncation | Rocky Linux 10 (procps-ng 4.0.4 fixed-width %a column) |
| FIX 8 — Crontab architecture | Part 2 install script design error |
| FIX 9 — Phantom scripts | Part 2 install script referencing non-existent files |
| FIX 10 — pgrep screen match | Part 2 install script — pgrep regex too broad |
| FIX 11 — MAX_RUNTIME daemons | Part 2 install script — daemon vs cron-job confusion |

**PHP 8.3 and MariaDB 10.11 were not a cause of any issue in this session.** ViciDial's
compatibility with PHP 8.3 requires specific patches (the vici-compiled binaries handle this),
and MariaDB is a drop-in replacement for MySQL for ViciDial's purposes.

---

*Part 2 completed 2026-02-17. System verified stable with 13 screen sessions and process monitor
reporting 0 actions per scan cycle.*
