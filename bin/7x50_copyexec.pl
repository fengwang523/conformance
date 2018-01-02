#! /usr/bin/perl -w

use Net::Telnet;
use warnings;
use strict;
use Getopt::Std;

use constant USAGEMSG => <<USAGE;
Usage: 7x50_copyexec.pl <optioins>  <7x50 list file or 7x50 name>
        options:
                -e      <core|edge|embargo>      use tacacs user/pass/enable from your .runcmd.passwd file
                        <core|edge|embargo> : use core or edge or embargo enable password
		-l	
                -h      print this help
        .runcmd.passwd file:
                default_user = <tacacs_static_user>
                default_pass = <tacacs_static_pass>
                default_enable = <enable password>
                edge_enable = <edge enable password>
                core_enable = <core enable password>
USAGE

my %options;
getopts('e:lh', \%options);
die USAGEMSG if $options{h};

my $execdir = "/usr/local/www/apache22/data/conformance/7x50/exec/";
my ($user, $pass, $enable);
my %routers;
my $prompt = q/(?m:^\*?[AB]:[\w._-]+(>[\w-]+)*[\$#]\s*$)/;

if ($options{e}) {
	die USAGEMSG unless $options{e} =~ /^(?:core|edge|embargo)$/;
        my $home = $ENV{HOME};
        my $passwdfile = "$home/.runcmd.passwd";
        open PASS, $passwdfile or die "can not open password file!\n";
        my $mode = $options{e} . "_enable";
        while (<PASS>) {
                $user = $1 if /default_user\s+=\s+(\S+?)\s*$/;
                $pass = $1 if /default_pass\s+=\s+(\S+?)\s*$/;
                $enable = $1 if /$mode\s+=\s+(\S+?)\s*$/;
        }
        close PASS;
        die "couldn't find default_user from $passwdfile !\n" unless $user;
        die "couldn't find default_pass from $passwdfile !\n" unless $pass;
        die "couldn't find $mode from $passwdfile !\n" unless $enable;
}else {
        die USAGEMSG;
}

if ($options{l}) {
        my $list = shift @ARGV or die USAGEMSG;
        open ROUTERS, $list or die "can not open router list file $list\n";
        while(<ROUTERS>){
                $routers{uc $1} ++ if /^(\w{10}\d{2})/;
        }
        close ROUTERS;
}else {
        my $router = shift @ARGV or die USAGEMSG;
        die "incorrect router name!\n" unless $router=~/^\w{10}\d{2}$/;
        $routers{uc $router} ++ ;
}


foreach (sort keys(%routers)) {
	my $router = $_;
	print "\n########$router : copying .exec file to standby cf3:########\n";
	my $session = new Net::Telnet (Host => $router,
                            Timeout => 30,
                             Prompt => "/$prompt/");
	$session->open($router) or die "telnet session open failed : $@\n";
	$session->login($user, $pass) or die "login failed : $@\n";
	$session->print('enable-admin');
	$session->waitfor("/Password:/i");
	my @output = $session->cmd(String => $enable, Timeout => 10);
	my $err = join("\n", @output);
	die "enable failed : $@\n" if ($err =~ m/(failed|sorry|denied|password|error)/i);
	my $execfile = $router . "_conformance.exec";
	my $active;
	my $exist;
	@output = $session->cmd ("file dir $execfile");
	foreach (@output) {
		$active = $1 if (/^Volume in drive cf3 on slot (A|B)/);
		$exist = 1 if (/ \d+ +$execfile/);
	}
	die "$router : can not detect active flash card !\n" unless $active;
	die "$router : $execfile does not exist!\n" unless $exist;
	if ($active eq 'A') {
		my $lastprompt = $session->last_prompt();
		print "  $lastprompt file copy $execfile cf3-b:$execfile force\n";
		@output = $session->cmd ("file copy $execfile cf3-b:$execfile force");
		print "  $_" foreach (@output);
	}elsif ($active eq 'B') {
		my $lastprompt = $session->last_prompt();
		print "  $lastprompt file copy $execfile cf3-a:$execfile force\n";
		@output= $session->cmd ("file copy $execfile cf3-a:$execfile force");
		print "  $_" foreach (@output);
	}else {
		die "$router : wrong flash card $active detected!\n";
	}
	
	$session->close;
}
