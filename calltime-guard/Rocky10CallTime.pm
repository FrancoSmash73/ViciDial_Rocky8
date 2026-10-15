package Rocky10CallTime;
# ROCKY10-CALLTIME-GUARD-v1
#
# Hard, code-level outbound call-time guard. Independent of every campaign /
# call-time / state-call-time setting in the ViciDial admin UI, so an admin
# cannot loosen it by saving a campaign as "24hours".
#
#   rocky10_calltime_block($gmt_offset_now, $state, $epoch)
#       returns ''            -> OK to dial
#       returns "REASON ..."  -> do NOT dial (reason text is for the log)
#
# Rules:
#   * Bad timezone (undef / non-numeric / outside -10..-4 US range) -> blocked.
#   * Lead local time = $epoch (UTC) + gmt_offset_now (ViciDial keeps it DST-adjusted).
#   * Company window is 09:00-21:00 local. A state with a stricter window
#     (see %STATE below) is intersected with it, never widened.
#   * A SAFETY_MIN-minute margin is removed from the END of the window because
#     ringing time follows the dial.
#   * State/timezone cross-check: a lead whose gmt_offset_now is not a plausible offset for
#     its own state (e.g. a TX lead tagged Hawaii time) is blocked as TZ_MISMATCH.
#     Offsets are DST-adjusted, so each zone lists standard and daylight values.
#   * State missing / unknown falls back to the company window (NOT blocked).
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(rocky10_calltime_block);

use constant DEF_START  => 900;    # HHMM local
use constant DEF_STOP   => 2100;
use constant SAFETY_MIN => 2;      # minutes shaved off the end of every window
use constant GMT_MIN    => -10;    # Hawaii
use constant GMT_MAX    => -4;     # Atlantic / Puerto Rico

# state => [ default_start, default_stop, { weekday(0=Sun) => [start, stop] } ]
# [2400,2400] means closed all day. Source: this box's vicidial_state_call_times.
my %STATE = (
	AL => [ 800, 2000, { 0 => [2400,2400] } ],
	FL => [ 800, 2000, {} ],
	IL => [ 800, 2100, {} ],
	IN => [ 900, 2000, {} ],
	KY => [1000, 2100, {} ],
	LA => [ 800, 2000, { 0 => [2400,2400] } ],
	MA => [ 800, 2000, {} ],
	MD => [ 800, 2000, {} ],
	ME => [ 900, 1700, {} ],
	MS => [ 800, 2000, { 0 => [2400,2400] } ],
	NE => [ 800, 2100, {} ],
	NV => [ 900, 2000, {} ],
	OK => [ 800, 2000, {} ],
	PA => [ 900, 2100, { 0 => [1330,2100] } ],
	RI => [ 900, 1800, { 0 => [2400,2400], 6 => [1000,1700] } ],
	SD => [ 900, 2100, { 0 => [2400,2400] } ],
	TN => [ 800, 2100, {} ],
	TX => [ 900, 2100, { 0 => [1200,2100] } ],
	UT => [ 900, 2000, {} ],
	WA => [ 800, 2000, {} ],
	WY => [ 800, 2000, {} ],
);


# Plausible gmt_offset_now values per state (standard AND daylight offsets of every zone the
# state touches). Anything else for that state is TZ_MISMATCH. States not listed are not checked.
my %ZONE = ( E => [-5,-4], C => [-6,-5], M => [-7,-6], P => [-8,-7] );
my %STATE_TZ;
{
	my %z = (
		(map { $_ => 'E'   } qw(CT DC DE GA MA MD ME NH NJ NY NC OH PA RI SC VT VA WV)),
		(map { $_ => 'EC'  } qw(FL IN KY MI TN)),
		(map { $_ => 'C'   } qw(AL AR IL IA LA MN MS MO OK WI)),
		(map { $_ => 'CM'  } qw(KS NE ND SD TX)),
		(map { $_ => 'M'   } qw(AZ CO MT NM UT WY)),
		(map { $_ => 'MP'  } qw(ID)),
		(map { $_ => 'P'   } qw(CA NV OR WA)),
	);
	for my $st (keys %z) { $STATE_TZ{$st} = { map { ($_ => 1) } map { @{ $ZONE{$_} } } split //, $z{$st} }; }
	$STATE_TZ{AK} = { map { ($_ => 1) } (-10, -9, -8) };   # incl. Aleutians
	$STATE_TZ{HI} = { -10 => 1 };
	$STATE_TZ{PR} = { -4 => 1 };
	$STATE_TZ{VI} = { -4 => 1 };
}

sub _mins { my $hhmm = shift; return int($hhmm / 100) * 60 + ($hhmm % 100); }

sub rocky10_calltime_block {
	my ($gmt, $state, $epoch) = @_;
	$epoch = time() unless defined $epoch;

	return 'BAD_TZ(undef)' unless defined $gmt && length $gmt;
	return "BAD_TZ($gmt)" unless $gmt =~ /^-?\d+(?:\.\d+)?$/;
	return "BAD_TZ($gmt)" if $gmt < GMT_MIN || $gmt > GMT_MAX;

	my ($sec,$min,$hour,$mday,$mon,$year,$wday) = gmtime($epoch + int($gmt * 3600 + ($gmt < 0 ? -0.5 : 0.5)));
	my $now_m = $hour * 60 + $min;
	my $hhmm  = sprintf('%02d%02d', $hour, $min);

	$state = '' unless defined $state;
	$state =~ s/\s+//g;
	$state = uc $state;

	if (my $ok = $STATE_TZ{$state}) {
		my $hit = 0; for my $o (keys %$ok) { if (abs($o - $gmt) < 0.01) { $hit = 1; last } }
		return "TZ_MISMATCH($state gmt=$gmt)" unless $hit;
	}

	my $start = DEF_START;
	my $stop  = DEF_STOP;
	my $tag   = $state ne '' ? $state : 'NOSTATE';
	if (my $s = $STATE{$state}) {
		my ($ss, $se) = @{$s}[0,1];
		if (my $d = $s->[2]{$wday}) { ($ss, $se) = @$d; }
		return "CLOSED_DAY($tag wday=$wday local=$hhmm gmt=$gmt)" if $ss >= 2400;
		$start = $ss if $ss > $start;     # intersect: never earlier than company start
		$stop  = $se if $se < $stop;      # never later than company stop
	}
	my $stop_m = _mins($stop) - SAFETY_MIN;
	return "OUTSIDE_WINDOW($tag local=$hhmm window=$start-$stop gmt=$gmt wday=$wday)"
		if $now_m < _mins($start) || $now_m >= $stop_m;
	return '';
}

1;
