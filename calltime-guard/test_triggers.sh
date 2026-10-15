#!/bin/bash
# Tests layer-2 triggers against a SCRATCH copy of the tables (never run against the live DB name).
# Usage: ./test_triggers.sh r10test      (create the DB + table copies + load calltime_triggers.sql first)
DB="${1:?scratch db name}"; [ "$DB" = "asterisk" ] && { echo "refusing to run against the live DB"; exit 2; }
pass=0; fail=0
t() { # name expect(BLOCK|OK) sql
  out=$(mysql "$DB" -e "$3" 2>&1); rc=$?
  if [ "$2" = BLOCK ]; then { [ $rc -ne 0 ] && echo "$out" | grep -q "ROCKY10 CALL-TIME GUARD\|does not exist"; } && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL (expected block): $1 -> $out"; }
  else [ $rc -eq 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL (expected ok): $1 -> $out"; }; fi
}
t "campaign -> 24hours"            BLOCK "UPDATE vicidial_campaigns SET local_call_time='24hours' WHERE campaign_id='WASH'"
t "campaign -> unknown id"         BLOCK "UPDATE vicidial_campaigns SET local_call_time='nope' WHERE campaign_id='WASH'"
t "campaign -> 9am-5pm (ok)"       OK    "UPDATE vicidial_campaigns SET local_call_time='9am-5pm' WHERE campaign_id='WASH'"
t "campaign -> 9am-9pm (ok)"       OK    "UPDATE vicidial_campaigns SET local_call_time='9am-9pm' WHERE campaign_id='WASH'"
t "internal stat update (ok)"      OK    "UPDATE vicidial_campaigns SET campaign_calldate=NOW() WHERE campaign_id='WASH'"
t "TEST1 -> 24hours exempt (ok)"   OK    "UPDATE vicidial_campaigns SET local_call_time='24hours' WHERE campaign_id='TEST1'"
t "TEST1 other update (ok)"        OK    "UPDATE vicidial_campaigns SET campaign_calldate=NOW() WHERE campaign_id='TEST1'"
t "new campaign 24hours"           BLOCK "INSERT INTO vicidial_campaigns (campaign_id,campaign_name,local_call_time) VALUES ('ZZNEW1','x','24hours')"
t "new campaign 9am-9pm (ok)"      OK    "INSERT INTO vicidial_campaigns (campaign_id,campaign_name,local_call_time) VALUES ('ZZNEW2','x','9am-9pm')"
t "call time widened to 2400"      BLOCK "UPDATE vicidial_call_times SET ct_default_stop=2400 WHERE call_time_id='9am-9pm'"
t "call time start 0700"           BLOCK "UPDATE vicidial_call_times SET ct_default_start=700 WHERE call_time_id='9am-9pm'"
t "call time narrowed (ok)"        OK    "UPDATE vicidial_call_times SET ct_default_stop=2000 WHERE call_time_id='9am-9pm'"
t "call time sunday 0700-2100"     BLOCK "UPDATE vicidial_call_times SET ct_sunday_start=700, ct_sunday_stop=2100 WHERE call_time_id='9am-9pm'"
t "call time sunday closed (ok)"   OK    "UPDATE vicidial_call_times SET ct_sunday_start=2400, ct_sunday_stop=2400 WHERE call_time_id='9am-9pm'"
t "call time saturday 1000-2200"   BLOCK "UPDATE vicidial_call_times SET ct_saturday_start=1000, ct_saturday_stop=2200 WHERE call_time_id='9am-9pm'"
t "new call time 24h"              BLOCK "INSERT INTO vicidial_call_times (call_time_id,call_time_name,ct_default_start,ct_default_stop) VALUES ('zz24','x',0,2400)"
t "new call time 9-9 (ok)"         OK    "INSERT INTO vicidial_call_times (call_time_id,call_time_name,ct_default_start,ct_default_stop) VALUES ('zz99','x',900,2100)"
t "state rule widened 2200"        BLOCK "UPDATE vicidial_state_call_times SET sct_default_stop=2200 WHERE state_call_time_id='alabama'"
t "state rule narrower (ok)"       OK    "UPDATE vicidial_state_call_times SET sct_default_stop=1900 WHERE state_call_time_id='alabama'"
t "state rule saturday 0600"       BLOCK "UPDATE vicidial_state_call_times SET sct_saturday_start=600, sct_saturday_stop=1200 WHERE state_call_time_id='alabama'"
t "list -> 24hours"                BLOCK "UPDATE vicidial_lists SET local_call_time='24hours' WHERE list_id=1001"
t "list -> campaign (ok)"          OK    "UPDATE vicidial_lists SET local_call_time='campaign' WHERE list_id=1001"
t "list -> 9am-5pm (ok)"           OK    "UPDATE vicidial_lists SET local_call_time='9am-5pm' WHERE list_id=1001"
t "TEST1 list -> 24hours (ok)"     OK    "UPDATE vicidial_lists SET local_call_time='24hours' WHERE list_id=1000"
t "holiday 0600-2200"              BLOCK "INSERT INTO vicidial_call_time_holidays (holiday_id,holiday_name,holiday_date,ct_default_start,ct_default_stop) VALUES ('zzh','x','2026-12-25',600,2200)"
t "holiday closed 0/0 (ok)"        OK    "INSERT INTO vicidial_call_time_holidays (holiday_id,holiday_name,holiday_date,ct_default_start,ct_default_stop) VALUES ('zzh2','x','2026-12-25',0,0)"
# state-rule reference: a call time pointing at a (now) non-compliant state rule is refused when assigned
mysql "$DB" -e "UPDATE vicidial_state_call_times SET sct_default_stop=1900 WHERE state_call_time_id='alabama'; INSERT INTO vicidial_call_times (call_time_id,call_time_name,ct_default_start,ct_default_stop,ct_state_call_times) VALUES ('zzst','x',900,2100,'alabama|')" >/dev/null 2>&1
t "call time w/ compliant state rule assigned to campaign (ok)" OK "UPDATE vicidial_campaigns SET local_call_time='zzst' WHERE campaign_id='WASH'"
printf "triggers: passed %d failed %d\n" $pass $fail; [ $fail -eq 0 ]
