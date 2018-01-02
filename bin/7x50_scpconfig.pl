#!/usr/bin/perl -w
use strict;
use Net::SCP::Expect;
use Getopt::Std;
use Term::ANSIColor qw(:constants);

use constant USAGEMSG => <<USAGE;
Usage: 7x50_scpconfig.pl <optioins> <7x50 list file>
        options:
                -l      the argument is 7750 list file; otherwise it is 7750 name
                -h      print this help
        .runcmd.passwd file:
                default_user = <tacacs_static_user>
                default_pass = <tacacs_static_pass>
                default_enable = <enable password>
                edge_enable = <edge enable password>
                core_enable = <core enable password>
USAGE

my %options;
getopts('lh', \%options);
die USAGEMSG if $options{h};

my %h;
if ($options{l}) {
        my $list = shift @ARGV or die USAGEMSG;
        open ROUTERS, $list or die "can not open router list file $list\n";
        while(<ROUTERS>){
		next if /^\s*#/;
                $h{uc $1} ++ if /^(\w{10}\d{2})/;
        }
        close ROUTERS;
}else {
        my $router = shift @ARGV or die USAGEMSG;
        $h{uc $router} ++ if $router=~/^\w{10}\d{2}$/;
}
my @routers = sort keys (%h);

my @errors;
my $backuppath = "/data/conformance/configs";
my ($user,$pass) = getUser ();

my $max_fork = 15;
while (1) {
        my %sub;  #shift max_fork of routers from routers, and put them into hash sub;
        my @childs;
        for (1..$max_fork) {
                my $router = shift @routers;
                $sub{$_} = $router if $router;
        }
        last unless scalar keys (%sub);
        foreach (sort keys(%sub)) {
                my $number = $_;
                my $router = $sub{$number};
                my $pid = fork();
                if ($pid) {
                        # parent
                        push(@childs, $pid);
                } elsif ($pid == 0) {
                        # child
                        getConfig($router);
                        exit(0);
                } else {
                        die "could not fork: $!\n";
                }
        }
        foreach (@childs) {
                waitpid($_, 0);
        }
}

emailError() if (@errors);

#### sub routetines ####
sub getUser {
  my ($user,$pass);
  my $home = $ENV{HOME};
  my $passwdfile = "$home/.runcmd.passwd";
  open PASS, $passwdfile or die "can not open password file!\n";
  while (<PASS>) {
    $user = $1 if /default_user = (\S+?)$/;
    $pass = $1 if /default_pass = (\S+?)$/;
  }
  close PASS;
  die "couldn't find default_user from $passwdfile !\n" unless $user;
  die "couldn't find default_pass from $passwdfile !\n" unless $pass;
  ($user,$pass);
}

sub getConfig {
  my $device = shift;
  eval{
    my $remotefile = "config.cfg";
    my $localfile = "$backuppath/$device" . ".native.config";
    rename ($localfile , $localfile . ".1")  if (-e $localfile);
    print "$device scp $remotefile...\n";
    my $scpe = Net::SCP::Expect->new(host=>$device, user=>$user, password=>$pass, auto_yes=>1);
    $scpe->scp(":$remotefile", $localfile) or die;
    print "$device $remotefile is backed up to $localfile\n";
  };
  if ($@) {
    my $error = $@;
    push @errors, "\n#### Error from getconfig() for device: $device####\n";
    push @errors, $error;
    $error =~ s/`/'/g;
    print "\n#### Error from getconfig() for device: $device####\n";
    print $error;
  }
}

sub emailError {
  my $from = 'feng.wang\@telus.com';
  my $to = 'feng.wang\@telus.com';
  qx{/usr/local/bin/sendEmail  -f $from -t $to -u "scp config error" -m "@errors"};
  exit;
}
