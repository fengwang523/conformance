#! /usr/local/bin/perl -w
use strict;
use Net::Telnet;
use Net::FTP;
use Getopt::Std;
use Term::ANSIColor qw(:constants);
use IO::Pty ();
use POSIX ();

use constant USAGEMSG => <<USAGE;
Usage: 7x50_saveconfig_fork.pl <optioins> <7x50 list file>
        options:
		-t     	-t <core|edge>      use tacacs user/pass/enable from your .runcmd.passwd file
                                <core|edge> : use core or edge enable password
		-l	the argument is 7750 list file; otherwise it is 7750 name
		-s	skip the 7x50s if CLI prompt does not begin with *
		-h     	print this help
	.runcmd.passwd file:
                default_user = <tacacs_static_user>
                default_pass = <tacacs_static_pass>
                default_enable = <enable password>
                edge_enable = <edge enable password>
                core_enable = <core enable password>
USAGE

my %options;
getopts('lst:f:h', \%options);
die USAGEMSG if $options{h};
my ($user,$pass,$enable);
my $home = $ENV{HOME};
if ($options{t}) {
        my $passwdfile = "$home/.runcmd.passwd";
        open PASS, $passwdfile or die "can not open password file!\n";
        my $mode = $options{t} . "_enable";
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
	print "missing -t option!\n";
	die USAGEMSG;
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

close ROUTERS;

my $max_fork = 5; #max telnet sessions to fork
if ($options{f}) {
        die "-f option only accept a number!\n" unless $options{f} =~ /^[1-9][0-9]*$/;
	die "-f option only accept a number between 1 and 10!\n" unless $options{f} >= 1 and $options{f} <= 10      ;

        $max_fork = $options{f};
}

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
                        saveconfig($router);
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
sub saveconfig{
  my $router = uc $_[0];
  my $session;
  eval{
	chomp $router;
        my $pid;
        my $pty = IO::Pty->new;
        my $tty = $pty->slave;
        ($pty,$pid)  = spawn("ssh","-a",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o","StrictHostKeyChecking=no",
                "-o", "PreferredAuthentications=password",
                "-o", "NumberOfPasswordPrompts=1",
                "-l", $user, $router);  # spawn() defined below

        $session = new Net::Telnet (
                                Fhopen => $pty,
                                Telnetmode => 0,
                            Timeout => 30,
                             Prompt => '/\*?(\w:)?\w{6,20}(?:>\w+){0,}[#] $/');
        if (! $session) {
                kill 'KILL', $pid;
                die "Unable to create ssh session for $router\n";
        }
        #my $logfile = "$home/log/$router.config";
        #$session->input_log($logfile);
        $SIG{'INT'} = \&close_ssh;
        $SIG{'QUIT'} = \&close_ssh;
        die "can not find password prompt!\n" unless ($session->waitfor( Match => '/Password: ?$/i', Timeout => 15 ));
        $session->print($pass);
        my($prematch,$match) = $session->waitfor(
                Match => '/Permission denied/',
                Match => '/Q to quit/',
                Match => $session->prompt,
                Timeout => 20
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

        if ($options{t}) {
                $session->print ('enable');
                $session->waitfor("/Password:/i");
                my @output = $session->cmd(String => $enable, Timeout => 10);
                my $err = join("\n", @output);
                die "enable failed : $@\n" if ($err =~ m/(failed|sorry|denied|password|error)/i);
        }
        $session->cmd ('environment no more');
	if ($options{s} and $session->last_prompt !~ /^\*/) {
		print "$router no changes to save.\n";
		return 0;
	}
        my @output = $session->cmd (String => 'admin save', Timeout => 600);
	my $err = join("\n", @output);
	die "admin save failed!\n" unless $err =~ /Completed/;
	print "$router admin save successful.\n";
        $session->close();


 };

  if ($@) {
        print RED "$router: error: $@\n";
	print RESET;
	$session->close;
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

                        $| = 1; #  make STDOUT unbuffered

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

