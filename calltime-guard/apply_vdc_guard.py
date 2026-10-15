#!/usr/bin/python3 -I
# ROCKY10-CALLTIME-GUARD-v1 applier for agc/vdc_db_query.php (manual dial). Idempotent.
# Function bodies live in rocky10_calltime.inc.php (so rule changes never need a re-patch).
# Usage: apply_vdc_guard.py /path/to/vdc_db_query.php
# Exit 0 = patched / already patched; 1 = anchor missing (upstream changed) -> file untouched.
import sys
p = sys.argv[1]
s = open(p).read()
if 'ROCKY10-CALLTIME-GUARD-v1' in s:
    print('already patched'); sys.exit(0)

a_next = "\t\t\t### Total and Daily call count limit check ###\n\t\t\tmanual_dccl_check($lead_id, $no_hopper_dialing_used, 0, $agent_dialed_number);\n"
a_only = "\t\t### Daily call count limit check ###\n\t\tmanual_dccl_check($lead_id, 0, 1, $phone_number);\n"
a_req = 'require_once("dbconnect_mysqli.php");\n'
for a in (a_next, a_only, a_req):
    if s.count(a) != 1:
        print('anchor not unique/found: %r' % a[:60]); sys.exit(1)



req = r'''### ROCKY10-CALLTIME-GUARD-v1: shared guard functions. If the include is missing, FAIL CLOSED (manual dialing blocked except TEST1).
$r10_inc = '/usr/local/share/vicidial-rocky10/calltime-guard/rocky10_calltime.inc.php';
if (is_readable($r10_inc)) {require_once($r10_inc);}
else
	{
	function manual_rocky10_calltime_check($temp_lead_id, $temp_no_hopper, $temp_dial_only, $temp_phone_number)
		{
		global $campaign, $user;
		if ($campaign === 'TEST1') {return;}
		error_log("ROCKY10-CALLTIME-GUARD include missing - manual dial BLOCKED user=$user campaign=$campaign");
		echo ($temp_dial_only ? " CALL NOT PLACED\n" : "") . "OUTSIDE LOCAL CALLING HOURS\n";
		exit;
		}
	}
'''
s = s.replace(a_req, a_req + req, 1)
s = s.replace(a_next, "\t\t\t### ROCKY10-CALLTIME-GUARD-v1 (manual next-lead dial)\n\t\t\tmanual_rocky10_calltime_check($lead_id, $no_hopper_dialing_used, 0, $agent_dialed_number);\n\n" + a_next, 1)
s = s.replace(a_only, "\t\t### ROCKY10-CALLTIME-GUARD-v1 (manual dial-only)\n\t\tmanual_rocky10_calltime_check($lead_id, 0, 1, $phone_number);\n\n" + a_only, 1)
open(p, 'w').write(s)
print('patched')
