#!/usr/bin/perl -w
use HTML::Entities;
use strict;
use Getopt::Std;
use Term::ANSIColor qw(:constants);
use Net::Telnet;
use Net::SCP::Expect;
use IO::Pty ();
use POSIX ();

use constant USAGEMSG => <<USAGE;
Usage:  config_flat_conformance_update.pl <options> <conformance report file>
        options:
		-u			update devices with the missing configs by open telnet sessions
		-m	<timos>		CLI mode, only timos is supported for now; default is timos
		-e	<edge|core>	enable password type, edge or core; default is edge
		-o			log telnet session output to ~/log directory
		-t	<number>	telnet command timeout in seconds, default is 30;
		-w			write conformance commands to a file in /usr/local/www/apache22/data/conformance/7x50/ and upload the file to 7x50 cf3:
                -h              	optional. print this help
USAGE

my %options;
getopts('e:m:ouhw:', \%options);
die USAGEMSG if $options{h};

my ($user, $pass, $enable, $mode, $timeout);
my $httpdir = "/usr/local/www/apache22/data/conformance/7x50/";
my $execdir = "/usr/local/www/apache22/data/conformance/7x50/exec/";

if ($options{w}) {
	my $httpfile =  $httpdir . $options{'w'};
	open HTTP, ">$httpfile" or die "can not open $httpfile!\n";
	my $time = `date`;
	print HTTP "#### Conformance commands generated $time \n";
	close HTTP;
        my $passwdfile = "$ENV{HOME}/.runcmd.passwd";
        open PASS, $passwdfile or die "can not open password file $passwdfile!\n";
        while (<PASS>) {
                $user = $1 if /default_user\s+=\s+(\S+?)\s*$/;
                $pass = $1 if /default_pass\s+=\s+(\S+?)\s*$/;
        }
        close PASS;
        die "couldn't find default_user from $passwdfile !\n" unless $user;
        die "couldn't find default_pass from $passwdfile !\n" unless $pass;

}

if ($options{u}) {
        if ($options{t}) {
                $timeout = $options{'t'};
                die "-t option only accept a number!\n" unless $timeout =~ /^[1-9]\d+$/;
		die "-t option can not exceed 300!\n" unless $timeout <= 300;
        } else {
                $timeout = 30;
        }

	if ($options{m}) {
        	$mode = $options{'m'};
        	die "-m option only accept timos for now!\n" unless $mode =~ /^timos$/;
	} else {
        	$mode = 'timos';
	}

	my $enablemode;
	if ($options{e}) {
        	$enablemode = $options{'e'};
        	die "-e option only accept edge or core!\n" unless $enablemode =~ /^(edge|core)$/;
	} else {
        	$enablemode = 'edge';
	}

	my $passwdfile = "$ENV{HOME}/.runcmd.passwd";
	open PASS, $passwdfile or die "can not open password file $passwdfile!\n";
	$enablemode = $enablemode . "_enable";

	while (<PASS>) {
        	$user = $1 if /default_user\s+=\s+(\S+?)\s*$/;
        	$pass = $1 if /default_pass\s+=\s+(\S+?)\s*$/;
        	$enable = $1 if /$enablemode\s+=\s+(\S+?)\s*$/;
	}
	close PASS;
	die "couldn't find default_user from $passwdfile !\n" unless $user;
	die "couldn't find default_pass from $passwdfile !\n" unless $pass;
	die "couldn't find $enablemode from $passwdfile !\n" unless $enable;
}



my $file = shift @ARGV or die USAGEMSG;
open REPORT, $file or die "can not open conformace report file $file \n";

print RED "commands generated does not consider their sequences!\n";
print RED "commands in regex or unpected sections can not copy/past to CLI!\n";
print RESET;

my $modes = {
        'timos' => {
                #A:WNPGMBABRE01#
                #*A:WNPGMBABRE01#
                #*A:WNPGMBABRE01>config>router>policy-options#
                prompt => q/(?m:^\*?[AB]:[\w._-]+(>[\w-]+)*[\$#]\s*$)/,
                post_login_cmds => [
                        "environment no more",
                ],
        },
        'catos' => {
                prompt => q/(?m:^[\w.-]+\s?(?:\(config[^\)]*\))?\s?[\$#>]\s?(?:\(enable\))?\s*$)/,
                post_login_cmds => [
                        "set length 0",
                ],
        },
        'ios' => {
                prompt => q/(?m:^[\w.-]+\s?(?:\(config[^\)]*\))?\s?[\$#>]\s?(?:\(enable\))?\s*$)/,
                post_login_cmds => [
                        "term length 0",
                ],
        },
        'junos' => {
                prompt => q/(?m:[\w\d\@\-]+[Rr][Ee]\d>|[\w\d\@-]+[Rr][Ee]\d#)\s*$)/,
                post_login_cmds => [
                        "set cli screen-length 0",
                        "set cli screen-width 0",
                ],
        },
        "erx" => {
                #BNBYBC01TR01>
                #BNBYBC01TR01#
                #BNBYBC01TR01:VIDEO#
                #BNBYBC01TR01:VIDEO(config)#
                #BNBYBC01TR01:VIDEO(config-if)#
                #note, from net:telnet dump_log, seems ERX adds 0x0d before promt
                prompt => q/(?m:^\s*HOSTNAME(:[\w.]+)?(\([\w-]+\))?[>#]\s*$)/,
                post_login_cmds => [
                        "term length 0",
                        "term width 512",
                ],
        },
        "7330" => {
                prompt => q/(?:leg:|typ:)?(?:read:?|\w{7,20}:?) ?>([\w>-]+)*(#|\$)? *$/,
                post_login_cmds => [
                        "environment print no-more",
                        "environment inhibit-alarms",
                        "exit",
                ],
        },
};


while (<REPORT>) {
  if (/^<-\s*(\S+) /) {       #beginning of a router
    my $router = $1;
    unless ($router =~ /^\w{10}\d{2}$/) {
      print RED "invalid router name in line $_";
      print RESET;
      die;
    }
    print GREEN "Processing $router conformance commands ...\n";
    print RESET;
    my $count = 0;
    my @missing;
    my @regex;
    my @extra;
    while (<REPORT>) {
      $count ++;
      if ($count > 50000) {
        print RED "possible loop? procesed $count line without close tag ->\n";
	print RESET;
        die;
      } 
      next if /^\s*#/;
      next if /^\s*$/;
      if (/^<-/) {
        print RED "missing close tag when processing router : $router!\n";
        print RESET;
        die;
      }
      my $line = $_;
      chomp $line;
      $line =~ s/^\s+//; #remove leading spaces
      $line =~ s/\s+$//; #remove trailing spaces
      # need logic here to process below situations:
      if (/^->/) {		#closing tag
        if (@missing) {
          push @missing, "exit all";
          print BLUE "  updating $router with below lines:\n";
          print RESET;
          #print "    $_\n" foreach @missing;
          foreach ( @missing ) {
            my $line = $_;
            if (/\/config router mpls lsp-template (".+?") p2mp default-path "P_PATH"/) {
              print "    /config router mpls lsp-template $1 p2mp shutdown\n";
              print "    $line\n";
              print "    /config router mpls lsp-template $1 p2mp no shutdown\n";
            }else{
              print "    $line\n";
            }
          }  
          update($router, \@missing) if $options{u};	#open telnet sessions and update the router;
	  writehttp($router, \@missing) if $options{w}; #write commands to a http file;
        }
        if (@regex) {
          print BLUE "  below lines has regex, pls update manually:\n";
          print RESET;
          print "    $_\n" foreach @regex;
        }
        if (@extra) {
          print BLUE "  below lines are not expected on router , pls remove manually:\n";
          print RESET;
          print "    $_\n" foreach @extra;
        }
        unless (@missing or @regex or @extra) {
	  print BLUE "  nothing to update\n";
          print RESET;
        }
        last;
      }elsif ($line =~ /^- #(\S.+?)$/) {    # the line has regex
        push @regex, $1;
      }elsif ($line =~ /^\+ (\S.+?)$/) {	# the line is extra command begin with + sign
        push @extra, $1;
      }elsif ($line =~ /^- (\S.+?)$/) {		# the line is a missing command begin with - sign
        push @missing, $1;
      }else {
        print RED "  unexpected line : $line\n";
        print RESET;
      }

    } #end of while (<REPORT>) {

  } #end of if (/^<-\s*(\S+)\s*?$/) {
	
} #end of while (<REPORT>) {
close REPORT;

sub update{
  my $router = uc $_[0];
  my (@cmds) = @{$_[1]};
  my $session;
  eval{
        my $session_log = "$ENV{HOME}/log/" . $router . '.log';
        my $prompt = $modes->{$mode}->{'prompt'};
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
                Cmd_remove_mode => 1,
                Timeout => 30,
                Prompt => '/(?m:^\*?[AB]:[\w._-]+(>[\w-]+)*[\$#]\s*$)/',
            );
        if (! $session) {
        kill 'KILL', $pid;
                die "Unable to create ssh session for $router\n";
        }
        $SIG{'INT'} = \&close_ssh;
        $SIG{'QUIT'} = \&close_ssh;

        if ($options{o}) {
                rename ($session_log, $session_log . '.bak') if (-e $session_log) ;
                $session->input_log("$session_log") or die "log file $session_log open failed\n";
		print BLUE "$router telnet session is logged to $session_log\n";
		print RESET;
        }
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

        if ($options{'e'}) {
                $session->print('enable-admin');
                $session->waitfor("/Password:/i");
                my @output = $session->cmd(String => $enable, Timeout => 10);
                my $err = join("\n", @output);
                die "enable failed : $@\n" if ($err =~ m/(failed|sorry|denied|password|error)/i);
        }
        $session->cmd ($_) foreach (@{$modes->{$mode}->{'post_login_cmds'}});
	foreach (@cmds) {
		my $cmd = $_;
		my $lastprompt = $session->last_prompt();
		print "$lastprompt $cmd\n";
		my @output = $session->cmd ($cmd);
		print @output;
	}
        $session->close();
 };

  if ($@) {
        print RED "$router : error : $@";
        print RESET;
        $session->close();
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


sub writehttp{
  	my $router = uc $_[0];
  	my (@cmds) = @{$_[1]};
	my $httpfile = $httpdir . $options{w};
	my $execfile = $execdir . $router . "_conformance.exec";
        open HTTP, ">>$httpfile" or die "can not open $httpfile!\n";
        print HTTP "\n#### $router conformance commands ####\n";
	open EXEC , ">$execfile" or die "can not open $execfile!\n";
	my $time = `date`;
	print EXEC "#### $router commands generated : $time\n";
	if (@cmds) {
		#print HTTP "$_\n" foreach @cmds;
		#print EXEC "$_\n" foreach @cmds;
          foreach ( @cmds ) {
            my $line = $_;
            if (/\/config router mpls lsp-template (".+?") p2mp default-path "P_PATH"/) {
              print HTTP "    /config router mpls lsp-template $1 p2mp shutdown\n";
              print HTTP "    $line\n";
              print HTTP "    /config router mpls lsp-template $1 p2mp no shutdown\n";
            }else{
              print HTTP "    $line\n"
            }
          }
          foreach ( @cmds ) {
            my $line = $_;
            if (/\/config router mpls lsp-template (".+?") p2mp default-path "P_PATH"/) {
              print EXEC "    /config router mpls lsp-template $1 p2mp shutdown\n";
              print EXEC "    $line\n";
              print EXEC "    /config router mpls lsp-template $1 p2mp no shutdown\n";
            }else{
              print EXEC "    $line\n";
            }
          }


	}else{
		print HTTP "####nothing to update!\n";
		print EXEC  "####nothing to update!\n";
	}
        close HTTP;
	close EXEC;
	my $remotefile = $router . "_conformance.exec";
	my $scpe = Net::SCP::Expect->new(host=>$router, user=>$user, password=>$pass, auto_yes=>1);
	$scpe->scp($execfile, $remotefile) or die;
}
