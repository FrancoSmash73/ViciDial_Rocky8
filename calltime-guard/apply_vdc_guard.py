#!/usr/bin/python3 -I
# ROCKY10-CALLTIME-GUARD-v1 applier for agc/vdc_db_query.php (manual dial). Idempotent.
# Usage: apply_vdc_guard.py /path/to/vdc_db_query.php
# Exit 0 = patched / already patched; 1 = anchor missing (upstream changed) -> file untouched.
import sys
p = sys.argv[1]
s = open(p).read()
if 'ROCKY10-CALLTIME-GUARD-v1' in s:
    print('already patched'); sys.exit(0)

a_next = "\t\t\t### Total and Daily call count limit check ###\n\t\t\tmanual_dccl_check($lead_id, $no_hopper_dialing_used, 0, $agent_dialed_number);\n"
a_only = "\t\t### Daily call count limit check ###\n\t\tmanual_dccl_check($lead_id, 0, 1, $phone_number);\n"
a_func = "function manual_dccl_check("
for a in (a_next, a_only, a_func):
    if s.count(a) != 1:
        print('anchor not unique/found: %r' % a[:60]); sys.exit(1)

s = s.replace(a_next, "\t\t\t### ROCKY10-CALLTIME-GUARD-v1 (manual next-lead dial)\n\t\t\tmanual_rocky10_calltime_check($lead_id, $no_hopper_dialing_used, 0, $agent_dialed_number);\n\n" + a_next, 1)
s = s.replace(a_only, "\t\t### ROCKY10-CALLTIME-GUARD-v1 (manual dial-only)\n\t\tmanual_rocky10_calltime_check($lead_id, 0, 1, $phone_number);\n\n" + a_only, 1)

func = r'''### ROCKY10-CALLTIME-GUARD-v1 -- hard 9pm / state / bad-timezone block for MANUAL dialing.
### Mirrors Rocky10CallTime.pm (auto-dial). Rules are in code, not the admin UI.
### Campaigns listed in $r10_exempt are not capped (TEST1 = owner's own test numbers).
function rocky10_calltime_block($gmt, $state, $epoch)
	{
	$STATE = array(
		'AL'=>array( 800,2000,array(0=>array(2400,2400))), 'FL'=>array( 800,2000,array()),
		'IL'=>array( 800,2100,array()), 'IN'=>array( 900,2000,array()), 'KY'=>array(1000,2100,array()),
		'LA'=>array( 800,2000,array(0=>array(2400,2400))), 'MA'=>array( 800,2000,array()),
		'MD'=>array( 800,2000,array()), 'ME'=>array( 900,1700,array()),
		'MS'=>array( 800,2000,array(0=>array(2400,2400))), 'NE'=>array( 800,2100,array()),
		'NV'=>array( 900,2000,array()), 'OK'=>array( 800,2000,array()),
		'PA'=>array( 900,2100,array(0=>array(1330,2100))),
		'RI'=>array( 900,1800,array(0=>array(2400,2400),6=>array(1000,1700))),
		'SD'=>array( 900,2100,array(0=>array(2400,2400))), 'TN'=>array( 800,2100,array()),
		'TX'=>array( 900,2100,array(0=>array(1200,2100))), 'UT'=>array( 900,2000,array()),
		'WA'=>array( 800,2000,array()), 'WY'=>array( 800,2000,array()) );
	$gmt = trim("$gmt");
	if ( ($gmt === '') or (!preg_match('/^-?[0-9]+(\.[0-9]+)?$/',$gmt)) ) {return "BAD_TZ($gmt)";}
	if ( ($gmt < -10) or ($gmt > -4) ) {return "BAD_TZ($gmt)";}
	$local = ($epoch + (int) round($gmt * 3600));
	$wday = (int) gmdate('w', $local);
	$hhmm = gmdate('Hi', $local);
	$now_m = (((int) gmdate('G', $local)) * 60) + ((int) gmdate('i', $local));
	$state = strtoupper(preg_replace('/\s+/','',"$state"));
	$start = 900;   $stop = 2100;   $safety = 2;
	if (isset($STATE[$state]))
		{
		$ss = $STATE[$state][0];   $se = $STATE[$state][1];
		if (isset($STATE[$state][2][$wday])) {$ss = $STATE[$state][2][$wday][0];   $se = $STATE[$state][2][$wday][1];}
		if ($ss >= 2400) {return "CLOSED_DAY($state wday=$wday local=$hhmm gmt=$gmt)";}
		if ($ss > $start) {$start = $ss;}
		if ($se < $stop) {$stop = $se;}
		}
	$start_m = (((int) floor($start / 100)) * 60) + ($start % 100);
	$stop_m = (((int) floor($stop / 100)) * 60) + ($stop % 100) - $safety;
	if ( ($now_m < $start_m) or ($now_m >= $stop_m) )
		{return "OUTSIDE_WINDOW($state local=$hhmm window=$start-$stop gmt=$gmt wday=$wday)";}
	return '';
	}

function manual_rocky10_calltime_check($temp_lead_id, $temp_no_hopper, $temp_dial_only, $temp_phone_number)
	{
	global $campaign, $user, $link, $NOW_TIME, $mel, $server_ip, $session_name, $one_mysql_log, $SSagent_debug_logging, $startMS, $ACTION, $php_script, $stage, $agent_log_id, $vla_status, $agent_dialed_type, $agent_dialed_number;
	$r10_exempt = array('TEST1');
	if (in_array($campaign, $r10_exempt, true)) {return;}

	$lid = preg_replace('/[^0-9]/','',"$temp_lead_id");
	$r10_gmt = '';   $r10_state = '';
	$stmt = "SELECT gmt_offset_now,state FROM vicidial_list where lead_id='$lid';";
	$rslt = mysql_to_mysqli($stmt, $link);
	if (mysqli_num_rows($rslt) > 0)
		{
		$row = mysqli_fetch_row($rslt);
		$r10_gmt = $row[0];   $r10_state = $row[1];
		}
	$r10_block = rocky10_calltime_block($r10_gmt, $r10_state, time());
	if (strlen($r10_block) < 1) {return;}

	error_log("ROCKY10-CALLTIME-GUARD manual BLOCK user=$user campaign=$campaign lead=$lid phone=$temp_phone_number action=$ACTION $r10_block");

	### purge from the dial queue and api (same cleanup the stock DNC refusal does)
	$stmt = "DELETE from vicidial_manual_dial_queue where phone_number='$temp_phone_number' and user='$user';";
	$rslt = mysql_to_mysqli($stmt, $link);
	$stmt = "UPDATE vicidial_live_agents set external_dial='' where user='$user';";
	$rslt = mysql_to_mysqli($stmt, $link);

	if ($temp_no_hopper > 0)
		{
		$stmt = "UPDATE vicidial_agent_log set lead_id=NULL,comments='' where agent_log_id='$agent_log_id';";
		$rslt = mysql_to_mysqli($stmt, $link);
		echo "OUTSIDE LOCAL CALLING HOURS\nTRY AGAIN\n";
		}
	else
		{
		if ($temp_dial_only) {echo " CALL NOT PLACED\nOUTSIDE LOCAL CALLING HOURS\n";}
		else {echo "OUTSIDE LOCAL CALLING HOURS\n";}
		}
	if ($SSagent_debug_logging > 0) {vicidial_ajax_log($NOW_TIME,$startMS,$link,$ACTION,$php_script,$user,$stage,$lid,$session_name,$stmt);}
	exit;
	}

'''
s = s.replace(a_func, func + a_func, 1)
open(p, 'w').write(s)
print('patched')
