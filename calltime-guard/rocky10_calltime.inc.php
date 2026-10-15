<?php
# ROCKY10-CALLTIME-GUARD-v1 -- shared include for agc/vdc_db_query.php (manual dialing).
# Installed to /usr/local/share/vicidial-rocky10/calltime-guard/. Mirrors Rocky10CallTime.pm.
### hard 9pm / state / bad-timezone block for MANUAL dialing.
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
	$ZONE = array('E'=>array(-5,-4), 'C'=>array(-6,-5), 'M'=>array(-7,-6), 'P'=>array(-8,-7));
	$SZ = array('E'=>'CT DC DE GA MA MD ME NH NJ NY NC OH PA RI SC VT VA WV', 'EC'=>'FL IN KY MI TN',
		'C'=>'AL AR IL IA LA MN MS MO OK WI', 'CM'=>'KS NE ND SD TX', 'M'=>'AZ CO MT NM UT WY', 'MP'=>'ID', 'P'=>'CA NV OR WA');
	$STATE_TZ = array('AK'=>array(-10,-9,-8), 'HI'=>array(-10), 'PR'=>array(-4), 'VI'=>array(-4));
	foreach ($SZ as $zs => $list)
		{
		$offs = array();
		foreach (str_split($zs) as $zc) {$offs = array_merge($offs, $ZONE[$zc]);}
		foreach (explode(' ', $list) as $stc) {$STATE_TZ[$stc] = $offs;}
		}
	$gmt = trim("$gmt");
	if ( ($gmt === '') or (!preg_match('/^-?[0-9]+(\.[0-9]+)?$/',$gmt)) ) {return "BAD_TZ($gmt)";}
	if ( ($gmt < -10) or ($gmt > -4) ) {return "BAD_TZ($gmt)";}
	$local = ($epoch + (int) round($gmt * 3600));
	$wday = (int) gmdate('w', $local);
	$hhmm = gmdate('Hi', $local);
	$now_m = (((int) gmdate('G', $local)) * 60) + ((int) gmdate('i', $local));
	$state = strtoupper(preg_replace('/\s+/','',"$state"));
	if (isset($STATE_TZ[$state]))
		{
		$hit = 0;
		foreach ($STATE_TZ[$state] as $o) {if (abs($o - $gmt) < 0.01) {$hit = 1;}}
		if ($hit < 1) {return "TZ_MISMATCH($state gmt=$gmt)";}
		}
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

