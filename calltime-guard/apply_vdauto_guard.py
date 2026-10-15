#!/usr/bin/python3 -I
# ROCKY10-CALLTIME-GUARD-v1 applier for AST_VDauto_dial.pl. Idempotent.
# Usage: apply_vdauto_guard.py /usr/share/astguiclient/AST_VDauto_dial.pl
# Exit 0 = patched or already patched; 1 = anchor not found (upstream changed) -> do NOT patch.
import sys
p = sys.argv[1]
s = open(p).read()
if 'ROCKY10-CALLTIME-GUARD-v1' in s:
    print('already patched'); sys.exit(0)
a = "use DBI;\n"
if s.count(a) != 1:
    print('anchor "use DBI;" not unique/found'); sys.exit(1)
s = s.replace(a, a + "use Rocky10CallTime qw(rocky10_calltime_block);   # ROCKY10-CALLTIME-GUARD-v1 (import)\n", 1)
anchor = """										$sthA->finish();

										if ($rec_countCUSTDATA)
											{
											$campaign_cid_override='';"""
if s.count(anchor) != 1:
    print('hopper-pull anchor not unique/found'); sys.exit(1)
guard = """										$sthA->finish();

										### ROCKY10-CALLTIME-GUARD-v1: hard 9pm/state/bad-timezone block, ignores campaign settings
										if ($rec_countCUSTDATA)
											{
											my $r10_block = rocky10_calltime_block($gmt_offset_now, $state, time());
											if (length($r10_block) > 0)
												{
												$stmtA = "DELETE FROM vicidial_hopper where lead_id='$lead_id'";
												$dbhA->do($stmtA);
												$lead_id_call_list .= "$lead_id|";
												if (open(R10out, ">>$PATHlogs/VDAD_CALLTIME_BLOCK.$file_date"))
													{
													print R10out "$now_date|$DBIPcampaign[$user_CIPct]|lead=$lead_id|alt=$alt_dial|state=$state|gmt=$gmt_offset_now|$r10_block\\n";
													close(R10out);
													}
												$event_string = "|     CALLTIME GUARD BLOCKED|$DBIPcampaign[$user_CIPct]|$lead_id|$state|$gmt_offset_now|$r10_block|";
												&event_logger;
												$rec_countCUSTDATA = 0;
												}
											}

										if ($rec_countCUSTDATA)
											{
											$campaign_cid_override='';"""
s = s.replace(anchor, guard, 1)
open(p, 'w').write(s)
print('patched')
