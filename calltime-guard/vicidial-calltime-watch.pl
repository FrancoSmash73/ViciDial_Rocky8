#!/usr/bin/perl
# ROCKY10-CALLTIME-GUARD-v1 layer 3: alerting. Runs every minute (systemd timer).
#
#   1. LATE CALLS  - every vicidial_log row since the last run is re-checked with the same rules as the
#                    guards (Rocky10CallTime, margin 0). Any call placed outside its lead's legal window
#                    (campaign TEST1 exempt) => one e-mail listing them. Each call alerts once.
#   2. DRIFT       - any non-TEST1 campaign/list whose call time is non-compliant.
#   3. INTEGRITY   - layer-2 triggers/functions missing, code-guard markers missing from
#                    AST_VDauto_dial.pl / vdc_db_query.php, module/include files missing, or the RUNNING
#                    dialer older than its guard files (old code still in memory).
#   For 2+3 an e-mail is sent when the problem set changes, re-sent every 6 h while it persists, and a
#   RESOLVED mail is sent when it clears.
#
# Options:  --dry-run         print what would be mailed, send nothing, do not move the watermark
#           --since EPOCH     start the late-call scan at EPOCH (with --dry-run: audit history)
#           --db NAME         database to check (default asterisk; tests use a scratch copy)
#           --test-mail       send a test message to root and exit
# Mail goes to root (aliased to the admin mailbox).  State: /var/lib/vicidial-calltime-watch/
use strict; use warnings;
use DBI; use POSIX qw(strftime);
use Rocky10CallTime qw(rocky10_calltime_block);

my ($DRY, $SINCE, $DB, $TESTMAIL) = (0, undef, 'asterisk', 0);
while (@ARGV) { my $a = shift @ARGV;
	if ($a eq '--dry-run') {$DRY=1} elsif ($a eq '--since') {$SINCE=shift @ARGV} elsif ($a eq '--db') {$DB=shift @ARGV}
	elsif ($a eq '--test-mail') {$TESTMAIL=1} else {die "unknown option $a\n"} }

my $STATE  = '/var/lib/vicidial-calltime-watch';
my $LOG    = '/var/log/astguiclient/calltime-watch.log';
my $EXEMPT = 'TEST1';
my $REMIND = 6 * 3600;
my $HOST   = `hostname`; chomp $HOST;
mkdir $STATE unless -d $STATE;

sub logmsg { my $m = shift; return if $DRY; if (open(my $f, '>>', $LOG)) { print $f strftime('%Y-%m-%d %H:%M:%S', localtime), " $m\n"; close $f } }
sub mail_root {
	my ($subject, $body) = @_;
	if ($DRY) { print "----- WOULD MAIL: $subject\n$body\n"; return 1 }
	open(my $m, '|-', '/usr/sbin/sendmail', '-t', '-i') or do { logmsg("sendmail failed: $!"); return 0 };
	print $m "To: root\nFrom: calltime-watch <root>\nSubject: [$HOST] $subject\n\n$body\n";
	return close($m);
}
sub slurp { my $f = shift; local $/; open(my $h, '<', $f) or return ''; my $c = <$h>; close $h; return $c }
sub spit  { my ($f, $c) = @_; return if $DRY; open(my $h, '>', $f) or return; print $h $c; close $h }

if ($TESTMAIL) { mail_root('call-time watch TEST message', "This is a test from vicidial-calltime-watch on $HOST at " . localtime() . ".\nIf you can read this, alerting works."); exit 0 }

my $dbh = DBI->connect("DBI:MariaDB:database=$DB", 'root', '', { RaiseError => 0, PrintError => 0 });
if (!$dbh) { problem_only("cannot connect to database '$DB' as root: $DBI::errstr"); exit 1 }

# ---------------------------------------------------------------- 1. late calls
my $now = time();
my $wm_file = "$STATE/last_epoch";
my $since = defined $SINCE ? $SINCE : slurp($wm_file);
$since = $now if !defined $since || $since !~ /^\d+$/;     # first run: start from now
my @late;
my $rows = $dbh->selectall_arrayref(
	"SELECT l.start_epoch, l.campaign_id, l.user, l.lead_id, l.phone_number, v.state, v.gmt_offset_now, l.status
	   FROM vicidial_log l LEFT JOIN vicidial_list v ON v.lead_id = l.lead_id
	  WHERE l.start_epoch > ? AND l.start_epoch <= ? AND l.campaign_id <> ?
	  ORDER BY l.start_epoch", undef, $since, $now, $EXEMPT) || [];
for my $r (@$rows) {
	my ($ep, $camp, $user, $lead, $phone, $st, $gmt, $status) = @$r;
	my $why = rocky10_calltime_block($gmt, $st, $ep, 0);
	next if $why eq '';
	push @late, sprintf("%s  %-8s user=%-8s lead=%-9s %s  status=%s  %s",
		strftime('%m-%d %H:%M:%S', localtime($ep)), $camp, $user // '', $lead, $phone // '', $status // '', $why);
}
spit($wm_file, $now);
if (@late) {
	my $n = @late; my $shown = $n > 60 ? 60 : $n;
	my $body = "$n call(s) were PLACED OUTSIDE the legal calling window (company 09:00-21:00 local, plus state rules).\n"
	         . "Server time shown. The hard guards should have prevented these - investigate immediately.\n\n"
	         . join("\n", @late[0 .. $shown - 1]) . ($n > $shown ? "\n... and " . ($n - $shown) . " more (see $LOG)" : '') . "\n";
	logmsg("LATE CALLS: $n"); logmsg("  $_") for @late[0 .. $shown - 1];
	mail_root("ALERT: $n call(s) outside legal calling hours", $body);
}

# ---------------------------------------------------------------- 2+3. drift / integrity
my @problems;
my ($trg) = $dbh->selectrow_array("SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema=? AND trigger_name LIKE 'rocky10%'", undef, $DB);
my ($fn)  = $dbh->selectrow_array("SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema=? AND routine_name LIKE 'rocky10%'", undef, $DB);
push @problems, "layer-2 triggers: " . ($trg // 0) . " of 10 present (run /usr/local/sbin/vicidial-rocky10-repatch)" if ($trg // 0) < 10;
push @problems, "layer-2 functions: " . ($fn // 0) . " of 4 present" if ($fn // 0) < 4;
if (($fn // 0) >= 4) {
	for my $c (@{ $dbh->selectall_arrayref("SELECT campaign_id, local_call_time FROM vicidial_campaigns WHERE campaign_id <> ?", undef, $EXEMPT) || [] }) {
		my ($why) = $dbh->selectrow_array("SELECT rocky10_calltime_reason(?)", undef, $c->[1] // '');
		push @problems, "campaign $c->[0]: call time '" . ($c->[1] // 'NULL') . "' - $why" if $why;
	}
	for my $l (@{ $dbh->selectall_arrayref("SELECT list_id, campaign_id, local_call_time FROM vicidial_lists WHERE campaign_id <> ? AND local_call_time IS NOT NULL AND local_call_time <> 'campaign'", undef, $EXEMPT) || [] }) {
		my ($why) = $dbh->selectrow_array("SELECT rocky10_calltime_reason(?)", undef, $l->[2]);
		push @problems, "list $l->[0] ($l->[1]): call time '$l->[2]' - $why" if $why;
	}
}
if ($DB eq 'asterisk') {
	my $M = 'ROCKY10-CALLTIME-GUARD-v1';
	for my $f ('/usr/share/astguiclient/AST_VDauto_dial.pl', '/var/www/html/agc/vdc_db_query.php') {
		push @problems, "code guard marker missing in $f" unless slurp($f) =~ /\Q$M\E/;
	}
	for my $f ('/usr/local/share/perl5/5.40/Rocky10CallTime.pm', '/usr/local/share/vicidial-rocky10/calltime-guard/rocky10_calltime.inc.php') {
		push @problems, "guard file missing: $f" unless -s $f;
	}
	my $pid = `pgrep -f '^/usr/bin/perl /usr/share/astguiclient/AST_VDauto_dial.pl' | head -1`; chomp $pid;
	if ($pid =~ /^\d+$/) {
		my $started = (stat("/proc/$pid"))[9];                   # proc dir mtime ~= process start
		for my $f ('/usr/share/astguiclient/AST_VDauto_dial.pl', '/usr/local/share/perl5/5.40/Rocky10CallTime.pm') {
			my $mt = (stat $f)[9] // 0;
			push @problems, "running dialer (pid $pid) started before $f was last changed - restart it so the new code is loaded" if $mt > $started + 5;
		}
	}
}
problem_only(@problems);

sub problem_only {
	my @p = @_;
	my $cur = join("\n", sort @p);
	my $prev_file = "$STATE/problems.txt"; my $time_file = "$STATE/problems.sent";
	my $prev = slurp($prev_file); my $sent = slurp($time_file) || 0; $sent =~ s/\s+//g;
	if ($cur ne '') {
		my $changed = ($cur ne $prev);
		if ($changed || ($now - $sent) >= $REMIND) {
			logmsg("PROBLEMS: " . scalar(@p)); logmsg("  $_") for sort @p;
			mail_root("WARNING: call-time protection problem (" . scalar(@p) . ")", ($changed ? "New or changed problems:\n\n" : "Still unresolved (reminder):\n\n") . "$cur\n");
			spit($time_file, $now);
		}
		spit($prev_file, $cur);
	} elsif ($prev ne '') {
		logmsg("RESOLVED");
		mail_root('RESOLVED: call-time protection problems cleared', "All previously reported call-time protection problems are gone.\n\nPrevious list:\n$prev\n");
		spit($prev_file, ''); spit($time_file, '0');
	}
	spit("$STATE/heartbeat", "$now\n");
}
