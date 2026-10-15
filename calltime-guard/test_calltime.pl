#!/usr/bin/perl
# Unit tests for Rocky10CallTime (no DB, no dialing). Usage: perl -I. test_calltime.pl
use strict; use warnings; use Time::Local qw(timegm);
use Rocky10CallTime qw(rocky10_calltime_block);
my ($pass,$fail)=(0,0);
# local wall time -> epoch UTC for a lead at $gmt
sub ep { my ($y,$m,$d,$H,$M,$gmt)=@_; return timegm(0,$M,$H,$d,$m-1,$y) - $gmt*3600; }
sub t { my ($name,$expect_block,$gmt,$st,$epoch)=@_;
  my $r = rocky10_calltime_block($gmt,$st,$epoch); my $blocked = $r ne '' ? 1 : 0;
  if ($blocked == $expect_block) {$pass++} else {$fail++; print "FAIL: $name -> '$r'\n"} }
# 2026-10-14 is a Wednesday; 2026-10-11 Sunday; 2026-10-10 Saturday
t('WA 19:57 ok',0,-7,'WA',ep(2026,10,14,19,57,-7));
t('WA 19:58 blocked (2m margin)',1,-7,'WA',ep(2026,10,14,19,58,-7));
t('WA 20:00 blocked',1,-7,'WA',ep(2026,10,14,20,0,-7));
t('WA 08:00 blocked (company start 09:00)',1,-7,'WA',ep(2026,10,14,8,0,-7));
t('WA 09:00 ok',0,-7,'WA',ep(2026,10,14,9,0,-7));
t('nostate 20:57 ok',0,-7,'',ep(2026,10,14,20,57,-7));
t('nostate 20:58 blocked',1,-7,'',ep(2026,10,14,20,58,-7));
t('nostate 21:00 blocked',1,-7,undef,ep(2026,10,14,21,0,-7));
t('NY 20:30 ok',0,-4,'NY',ep(2026,10,14,20,30,-4));
t('NY 21:05 blocked',1,-4,'NY',ep(2026,10,14,21,5,-4));
t('HI 20:30 ok',0,-10,'HI',ep(2026,10,14,20,30,-10));
t('HI 21:30 blocked',1,-10,'HI',ep(2026,10,14,21,30,-10));
t('AK -8 20:30 ok',0,-8,'AK',ep(2026,10,14,20,30,-8));
t('AK -8 21:01 blocked',1,-8,'AK',ep(2026,10,14,21,1,-8));
t('gmt +10 blocked',1,10,'AR',ep(2026,10,14,12,0,10));
t('gmt -2.5 blocked',1,-2.5,'',ep(2026,10,14,12,0,-2.5));
t('gmt undef blocked',1,undef,'NY',ep(2026,10,14,12,0,-5));
t('gmt garbage blocked',1,'abc','NY',time);
t('AL Sunday closed',1,-6,'AL',ep(2026,10,11,12,0,-6));
t('AL Wednesday 12:00 ok',0,-6,'AL',ep(2026,10,14,12,0,-6));
t('LA Sunday closed',1,-6,'LA',ep(2026,10,11,12,0,-6));
t('MS Sunday closed',1,-6,'MS',ep(2026,10,11,12,0,-6));
t('SD Sunday closed',1,-6,'SD',ep(2026,10,11,12,0,-6));
t('TX Sunday 11:59 blocked',1,-5,'TX',ep(2026,10,11,11,59,-5));
t('TX Sunday 12:00 ok',0,-5,'TX',ep(2026,10,11,12,0,-5));
t('TX Wed 20:57 ok',0,-5,'TX',ep(2026,10,14,20,57,-5));
t('PA Sunday 13:29 blocked',1,-4,'PA',ep(2026,10,11,13,29,-4));
t('PA Sunday 13:30 ok',0,-4,'PA',ep(2026,10,11,13,30,-4));
t('RI Sat 09:30 blocked (opens 10:00)',1,-4,'RI',ep(2026,10,10,9,30,-4));
t('RI Sat 10:00 ok',0,-4,'RI',ep(2026,10,10,10,0,-4));
t('RI Sat 16:58 blocked',1,-4,'RI',ep(2026,10,10,16,58,-4));
t('RI Wed 17:30 ok',0,-4,'RI',ep(2026,10,14,17,30,-4));
t('RI Wed 18:00 blocked',1,-4,'RI',ep(2026,10,14,18,0,-4));
t('ME 17:00 blocked',1,-4,'ME',ep(2026,10,14,17,0,-4));
t('UT 19:57 ok',0,-6,'UT',ep(2026,10,14,19,57,-6));
t('UT 20:00 blocked',1,-6,'UT',ep(2026,10,14,20,0,-6));
t('KY 09:30 blocked (opens 10:00)',1,-5,'KY',ep(2026,10,14,9,30,-5));
t('FL lower-case state ok',0,-4,'fl',ep(2026,10,14,12,0,-4));
t('unknown state XX uses company window',0,-5,'XX',ep(2026,10,14,20,30,-5));
t('PM near midnight blocked',1,-7,'WA',ep(2026,10,14,23,59,-7));
printf "passed %d failed %d\n",$pass,$fail; exit($fail?1:0);
