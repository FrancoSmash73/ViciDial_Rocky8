#!/usr/bin/perl
# Read-only: shows what the call-time guard would block in the CURRENT hopper right now.
use strict; use warnings; use DBI; use Rocky10CallTime qw(rocky10_calltime_block);
my %c; open(my $f,'<','/etc/astguiclient.conf') or die; while(<$f>){ $c{$1}=$2 if /^(\w+)\s*=>?\s*(\S+)/ } close $f;
my $d=DBI->connect("DBI:MariaDB:$c{VARDB_database};host=$c{VARDB_server}",$c{VARDB_user},$c{VARDB_pass},{RaiseError=>1});
my $r=$d->selectall_arrayref("select campaign_id,state,gmt_offset_now from vicidial_hopper"); my %n;
for (@$r){ my $b=rocky10_calltime_block($_->[2],$_->[1],time); $b=~s/\(.*//; $n{"$_->[0] ".($b||'ALLOW')}++ }
print "$_ => $n{$_}\n" for sort keys %n; print "hopper rows ",scalar(@$r),"\n";
