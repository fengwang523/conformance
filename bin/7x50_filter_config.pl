#! /usr/local/bin/perl -w
use strict;
use Getopt::Std;
use Term::ANSIColor qw(:constants);

use constant USAGEMSG => <<USAGE;
Usage: 7x50_filter_config_fork.pl <7x50 list file>
        options:
                -l      the argument is 7750 list file; otherwise it is 7750 name
		-i 	the filter type is inclusive
                -h      print this help

USAGE

my %options;
getopts('lhi', \%options);
die USAGEMSG if $options{h};

my $backuppath = "/data/conformance/configs";

#my $type = 'include';	#either include or exclude mode, for below filter lines
my $type = 'exclude';
my @filters = 	(	
		#"config qos sap-ingress",
		#"config qos sap-egress",
		#"config filter ip-filter",
		#"config filter ipv6-filter",
		"config router igmp ssm-translate",
		"config subscriber-mgmt sla-profile",
		"config subscriber-mgmt sub-profile",
		"config subscriber-mgmt sub-ident-policy",
		"config service",
#		"config system security management-access-filter",
#		"config lag",
		);
my %h;

if ($options{l}) {
        my $list = shift @ARGV or die USAGEMSG;
        open ROUTERS, $list or die "can not open router list file $list\n";
        while(<ROUTERS>){
                $h{$1} ++ if /^(\w{10}\d{2})/;
        }
        close ROUTERS;
}else {
        my $router = shift @ARGV or die USAGEMSG;
        $h{$router} ++ if $router=~/^\w{10}\d{2}$/;
	die "incorrect device name : $router  !\n" unless $router=~/^\w{10}\d{2}$/;
}

if ($options{i}) {
        $type = 'i';
}

my @routers = sort keys (%h);

my $max_fork = 10;
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
                        filterconfig($router);
                        exit(0);
                } else {
                        die "could not fork: $!\n";
                }
        }
        foreach (@childs) {
                waitpid($_, 0);
        }
}

################################### sub routines #################
sub filterconfig{
  my $router = uc $_[0];
  eval{
	my $flatconfig = "$backuppath/$router.flat.config";
	open FLAT, $flatconfig or die "can not open file $flatconfig\n";
	my $filterconfig = "$backuppath/$router.filter.config";
	open FILTER, ">$filterconfig" or die "can not open file $filterconfig to write\n";

	while(<FLAT>){
		my $line = $_;
		my $match = 'n';
		foreach ( @filters ) {
			$match = 'y' if $line =~ /$_/;
		}
		if ($type eq 'exclude') {
			print FILTER $line if ($match eq 'n');
		}
		if ($type eq 'include') {
			print FILTER $line if ($match eq 'y');
		}
	}

	close FLAT;
	close FILTER;
	print "$router $flatconfig is filtered to $filterconfig\n";
 };

  if ($@) {
        print RED "$router: error: $@\n";
	print RESET;
        return 0;
  }
  return 1;
}
