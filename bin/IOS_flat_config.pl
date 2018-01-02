#! /usr/local/bin/perl -w
use strict;
use Getopt::Std;
use Term::ANSIColor qw(:constants);

use constant USAGEMSG => <<USAGE;
Usage: IOS_flat_config_fork.pl <7x50 list file>
        options:
                -l      the argument is device list file; otherwise it is device name
                -h      print this help

USAGE

my %options;
getopts('lh', \%options);
die USAGEMSG if $options{h};

my $backuppath = "/data/conformance/configs";

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
                        flatconfig($router);
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
sub flatconfig{
  my $router = uc $_[0];
  eval{
        #note: the logic here is that print line decision should be on last line, not current line
        my $config = "$backuppath/$router.native.config";
        open CONFIG, $config or die "can not open file $config\n";
        my $flat = "$backuppath/$router.flat.config";
        open FLAT, ">$flat" or die "can not open file $flat to write\n";
        my @parents;
        my $last_line='';
        my $last_spaces=0;
        my $skip = 0;

        while(<CONFIG>){
                next if $skip;
                next if /^\s*$/;
                next if /^\s*#/;
                next unless /^(\s*)/;
                my $current_spaces = length $1 if ($1);
				$current_spaces = 0 unless ($1);
                my $line = $_;
                chomp $line;
                $line =~ s/^\s+//; #remove leading spaces
                $line =~ s/\s+$//; #remove trailing spaces
                my $tree = join ('--', @parents);
                if ($current_spaces > $last_spaces) { #$last_line is a parent, it has subs
                        push @parents, $last_line if $last_line ne '!';
                }elsif ($current_spaces < $last_spaces) {
						my $printline = "$tree--$last_line\n";
						$printline =~ s/^--//; #remove leading spaces
                        print FLAT $printline if ($last_line ne '!');
                        pop @parents;
                }else{
						my $printline = "$tree--$last_line\n";
						$printline =~ s/^--//; #remove leading spaces
                        print FLAT $printline if ($last_line ne '!');
                }
                $last_line = $line;
                $last_spaces = $current_spaces;
        }

        close CONFIG;
        close FLAT;
        print "$router $config is flatted to $flat\n";

 };

  if ($@) {
        print RED "$router: error: $@\n";
	print RESET;
        return 0;
  }
  return 1;
}
