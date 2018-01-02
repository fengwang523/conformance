#! /usr/bin/perl -w
use Net::Telnet;
use Getopt::Std;
use strict;
use Term::ANSIColor qw(:constants);
use IO::Pty ();
use POSIX ();
use Net::SCP::Expect;

use constant USAGEMSG => <<USAGE;
Usage: cisco_show_config.pl <optioins> <cisco device list file or name>
	options:
                -e      <core|edge>      use tacacs user/pass/enable from your .runcmd.passwd file
                                <core|edge> : use core or edge enable password
		-f	<number>	how many telnet sessions to folk; default 1
		-l	list file; otherwise use router name
		-h	print help
        .runcmd.passwd file:
                default_user = <tacacs_static_user>
                default_pass = <tacacs_static_pass>
                default_enable = <enable password>
                edge_enable = <edge enable password>
                core_enable = <core enable password>


USAGE
my %options;
getopts('e:f:hl', \%options);
die USAGEMSG if ($options{h});
my ($user, $pass, $enable, $max_fork, $mode);
my $home = $ENV{HOME};
my $passwdfile = "$home/.runcmd.passwd";
open PASS, $passwdfile or die "can not open password file!\n";
while (<PASS>) {
        $user = $1 if /default_user = (\S+?)$/;
        $pass = $1 if /default_pass = (\S+?)$/;
	if ($options{e}) {
		$mode = $options{e} . "_enable";
                $enable = $1 if /$mode = (\S+?)$/;
        }
}
close PASS;
die "couldn't find default_user from $passwdfile !\n" unless $user;
die "couldn't find default_pass from $passwdfile !\n" unless $pass;
if ($options{e}) {
	die "couldn't find $mode from $passwdfile !\n" unless $enable;
}else {
	print "missing -e option, will not use enable mode\n";
}

if ($options{f}) {
	die "-f option only accept a number!\n" unless $options{f} =~ /^[1-9][0-9]*$/;
	die "-f option only accept a number between 1 and 20!\n" unless $options{f} >= 1 and $options{f} <= 20;
	$max_fork = $options{f};
}else {
	$max_fork = 1;
}

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
while (1) {
        my %sub;  #shift max_fork of routers from routers, and put them into hash sub;
        my @childs; 
        for (1..$max_fork) {
                my $router = shift @routers;
                $sub{$_} = $router if $router;
        }
        last unless scalar keys (%sub);
	#print BLUE, "\nprocessing ", scalar keys (%sub), " devices in parallel...\n", RESET;
        foreach (sort keys(%sub)) {
                my $number = $_;
                my $router = $sub{$number};
                my $pid = fork();
                if ($pid) {
                        # parent
                        push(@childs, $pid);
                } elsif ($pid == 0) {
                        # child
                        #print "child $number : router : $router\n";
			&do_cmd($router);
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
sub do_cmd{
  my $router = uc $_[0];
  eval{
	my $pid;
	my $pty = IO::Pty->new;
	my $tty = $pty->slave;
        ($pty,$pid)  = spawn("ssh","-a",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o","StrictHostKeyChecking=no",
                "-o", "PreferredAuthentications=password",
                "-o", "NumberOfPasswordPrompts=1",
                "-l", $user, $router);  # spawn() defined below

	my $session = new Net::Telnet (
				Fhopen => $pty,
				Telnetmode => 0,
                             	Timeout => 30,
				Output_record_separator => "\r",
				Cmd_remove_mode => 1,
				#Prompt => '/(?m:^\*?[AB]:[\w._-]+(>[\w-]+)*[\$#]\s*$)/',
				Prompt => '/(?m:^[\w.-]+\s?(?:\(config[^\)]*\))?\s?[\$#>]\s?(?:\(enable\))?\s*$)/',
			);
	$session->prompt('/\w[\w-]+(?:\(config[^\)]*\))?[#>]\s?$/') if $router =~ /^\w{8}(?:CS|OC|NX)\d{2}$/;
        if (! $session) {
		kill 'KILL', $pid;
                die "Unable to create ssh session for $router\n";
        }
        $SIG{'INT'} = \&close_ssh;
        $SIG{'QUIT'} = \&close_ssh;
	my $sessionlog = "/data/conformance/configs/$router.native.config";
	$session->input_log($sessionlog);
	die "can not find password prompt!\n" unless ($session->waitfor( Match => '/(Password|password|passcode): ?$/i', Timeout => 5 ));
	$session->print($pass);
        my($prematch,$match) = $session->waitfor(
                Match => '/Permission denied/',
                Match => '/Q to quit/',
                Match => $session->prompt,
                Timeout => 10,
        );
        if (  (not defined $match) || $match eq '' || $match =~ /Permission denied/ ) {
                die "ssh login to $router failed: $match\n";
        # More prompt due to large banner
        } elsif ($match =~ /Q to quit/ ) {
                $session->put(" ");
                if ( ! $session->waitfor( Match => $session->prompt ) ) {
                        die "ssh login to $router failed: can not find command prompt\n";
                }
        }
        print "$router ssh login successful.\n";

	if ($options{e}) {
		$session->print ('enable');
                my($prematch,$match) = $session->waitfor( Match => '/Password: ?$/i');
                my @output = $session->cmd(String => $enable, Timeout => 5);
                my $err = join("\n", @output);
                die "enable failed : $enable : $@\n" if ($err =~ m/(failed|sorry|denied|password|error)/i);
	}
	$session->cmd ('term length 0');
	$session->cmd ('show clock');
	$session->cmd ('show version');
	$session->cmd (String => 'show startup-config', Timeout => 180);
	my $size = -s $sessionlog;
	print "$router show config output saved to $sessionlog, size=$size\n";
	die "$router config file $sessionlog too small!\n" if $size<5000;
	$session->close();
 };

  if ($@) {
	print "$router : error : $@";
        return 0;
  }
  return 1;
}

sub spawn {
        my(@cmd) = @_;
        my($pid, $pty, $tty, $tty_fd);
  eval{
        ## Create a new pseudo terminal.
        $pty = new IO::Pty
            or die $!;

        $SIG{CHLD}="IGNORE";  # is this line needed??

        ## Execute the program in another process.
        unless ($pid = fork) {  # child process
            die "problem spawning program: $!\n" unless defined $pid;

            ## Disassociate process from existing controlling terminal.
            POSIX::setsid
                or die "setsid failed: $!";

            ## Associate process with a new controlling terminal.
            $tty = $pty->slave;
                $pty->make_slave_controlling_terminal();
            $tty_fd = $tty->fileno;
            close $pty;

            ## Make stdio use the new controlling terminal.
            open STDIN, "<&$tty_fd" or die $!;
            open STDOUT, ">&$tty_fd" or die $!;
            open STDERR, ">&STDOUT" or die $!;
            close $tty;
			
			$| = 1;	#  make STDOUT unbuffered
			
            ## Execute requested program.
            exec @cmd
                or die "problem executing $cmd[0]\n";
        } # end child process

 };
  if ($@) {
        print "error : $@";
        return 0;
  }
	$pty;

} # end sub spawn
