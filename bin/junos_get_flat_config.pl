#!/usr/bin/perl -w
use strict;
use Net::SCP::Expect;
use Getopt::Std;
use Term::ANSIColor qw(:constants);
use Net::Telnet;

use constant USAGEMSG => <<USAGE;
Usage: junos_get_flat_config.pl <optioins> <router list file>
        options:
                -f      <number>        how many ssh sessions to folk; default 1
                -l      router list file; otherwise use router name
                -h      print help
                -t      -t <core|edge|mobility>      use tacacs user/pass group from your .runcmd.passwd file

        .runcmd.passwd file:
                default_user = <tacacs_static_user>
                default_pass = <tacacs_static_pass>
		mobility_user = <tacacs_static_user>
                mobility_pass = <tacacs_static_pass>
                default_enable = <enable password>
                edge_enable = <edge enable password>
                core_enable = <core enable password>


USAGE
my %options;
getopts('f:hlt:', \%options);
die USAGEMSG if ($options{h});
my ($user, $pass, $max_fork);
my $home = $ENV{HOME};
my $passwdfile = "$home/.runcmd.passwd";
my $mode = 'default';
$mode = $options{t} if $options{t};
open PASS, $passwdfile or die "can not open password file!\n";
while (<PASS>) {
        $user = $1 if /$mode(?:_user) = (\S+?)$/;
        $pass = $1 if /$mode(?:_pass) = (\S+?)$/;
}
die "couldn't find $mode" . "_user from $passwdfile !\n" unless $user;
die "couldn't find $mode" . "_pass from $passwdfile !\n" unless $pass;

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
				Cmd_remove_mode => 1,
				Output_record_separator => "\r",
				Prompt => '/(?<=\n)[; ]?([\w\d\@\-]+(?:[Rr][Ee]\d)?>|[\w\d\@-]+(?:[Rr][Ee]\d)?#)\s*$/i',
                        );
        if (! $session) {
                kill 'KILL', $pid;
                die "Unable to create ssh session for $router\n";
        }
        $SIG{'INT'} = \&close_ssh;
        $SIG{'QUIT'} = \&close_ssh;
		$session->max_buffer_length( 10*1024*1024 );
		#my $logfile = $home . "log/$router.log";
        #$session->input_log($logfile);
		#print "$router ssh session log is saved to : $logfile \n";
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

	$session->cmd ('set cli screen-length 0');
	$session->cmd ('set cli screen-width 0');
	$session->cmd ("show config | display set | save /var/tmp/$router.flat.config");
	sleep (15);
    $session->cmd ('show system uptime');
    $session->close();
	print "$router saved flat config successfully to its harddisk: /var/tmp/$router.flat.config \n";
	scpconfig ($router); 
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

sub scpconfig {
  my $device = shift;
  eval{
    my $remotefile = "/var/tmp/$device.flat.config";
	my $backuppath = '/data/conformance/configs';
    my $localfile = "$backuppath/$device" . ".flat.config";
    rename ($localfile , $localfile . ".1")  if (-e $localfile);
    print "$device scp $remotefile...\n";
    my $scpe = Net::SCP::Expect->new(host=>$device, user=>$user, password=>$pass, auto_yes=>1);
    $scpe->scp(":$remotefile", $localfile) or die;
    print "$device $remotefile is backed up to $localfile\n";
  };
  if ($@) {
    my $error = $@;
    $error =~ s/`/'/g;
    print "\n#### Error from scpconfig() for device: $device####\n";
    print $error;
  }
}

