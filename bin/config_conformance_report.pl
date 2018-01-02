#!/usr/bin/perl -w
use HTML::Entities;
use DBI;
use strict;
use Getopt::Std;
use Term::ANSIColor qw(:constants);


# by Feng Wang , feng.wang@telus.com
# version 1.0 - script is based on native 7x50 indented config. ability limitations due to indented processing difficulties.
# version 2.0 - major changes from V1.0. Converted to use 7x50 flat config.
# - converted to use fork method for speed
# - introduce instance concept
#   - to find instances that share the same config, eg, 'config router isis interface \w{8}CA\d{2}'
# - changed the report style
#   - a page for routers summary
#   - a page for routers detail
# - introduced conformance scoring
# - introduced rule weight
#   - info:1 low:1 medium:2 high:3 critical: 5
# - introduced rule conditions
# - introdued get_parameter type of rule
# - break down rule types to:
#  - get_parameter
#  - simple
#  - dynamic 
# - breakdown rule match types to:
#  - any
#  - none
#  - any_if_found
#  - none_if_found
#  - x,y

# version 2.1 - some minor changes
# - changed instance detection to support multiple parameters
# - added new match type 'exclusive', to check for extra lines under a config level
# - added 'instance_condition', to provide a condition check for instance detection

#substitution is supported by encolsing the substitution tag with s< and >
#supported substitution tags
#	s<HOSTNAME>
#	s<HOSTCLLI>

use constant USAGEMSG => <<USAGE;
Usage:
	config_conformance_report.pl <optioins> <rules file> <router list file | router name>
	options:
		-b			optional. keep a backup copy of report html files
		-f <number>	optional. number of telnet sessions to fork; default is 5;
		-h			optional. print this help
		-l			the argument is 7750 list file; otherwise it is 7750 name
        -n          no html report
		-p			optional. print conformance diff lines
		-s			optional. update mySQL dashboard table
		-v			optional. verbose, print conformed rules in detail report
	example:
		config_conformance_report.pl rules/7750_rules.txt ABFDBC01RE01
		config_conformance_report.pl -l rules/7750_rules.txt lists/7750.list
		config_conformance_report.pl -p -l rules/7750_rules.txt lists/7750.list
		config_conformance_report.pl -l -b -s rules/7750_rules.txt lists/7750.list
USAGE

my %options;
getopts('bf:hlnpsv', \%options);
die USAGEMSG if $options{h};


#below codes to parse rules definition file and generate rules html page;
my $rule_file = shift @ARGV or die USAGEMSG;
open RULES, $rule_file or die "can not open rule list file $rule_file\n";
my %hrules; #global rules hash, detail see parse_rules sub routine;
my @arules; #global rules array, detail see parse_rules sub routine;
my %global; #global non-rules related parameters, detail see parse_rules sub routine;
my %weights = qw (info 1 low 1 medium 2 high 3 critical 5);
parse_rules() or die;
close RULES;
parse_global() or die;	#to parse and manopulate global parameters;  mostly for html file names adding date stamp

#below codes is for single device mode, print single device conformance result and exit
my %sum = qw (get_parameter 0 condition_matched 0 condition_not_matched 0 pass 0 fail 0);

#below codes to fork a child process for each router, performing conformance check
my %hrouters;
my @routers;
if ($options{l}) {
        my $list = shift @ARGV or die USAGEMSG;
        open ROUTERS, $list or die "can not open router list file $list\n";
        while(<ROUTERS>){
                #$hrouters{uc $1} ++ if /^(\w{10}\d{2})/;
				$hrouters{uc $1} ++ if /^([a-z,A-Z,0-9,-_]+)\s/;
        }
        close ROUTERS;
}else {
        my $router = shift @ARGV or die USAGEMSG;
        die "incorrect router name!\n" unless $router=~/^\w{10}\d{2}$/;
        $hrouters{uc $router} ++ ;
}

my $logfile = $global{'output_dir'} . $global{'output_report_log_file'};
open OUT, ">$logfile" or die "can not open file $logfile\n";
my $start = `date`;
print OUT "#report started at :$start\n";
close OUT;

my $max_fork = 1;
if ($options{f}) {
        die "-f option only accept a number!\n" unless $options{f} =~ /^[1-9][0-9]*$/;
        die "-f option only accept a number between 1 and 10!\n" unless $options{f} >= 1 and $options{f} <= 10;
        $max_fork = $options{f};
}

if ($options{p}) {
	print "#forking disabled with -p option\n";
	$max_fork = 1;
}

@routers = sort keys (%hrouters);
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
                        conformance($router);
                        exit(0);
                } else {
                        die "could not fork: $!\n";
                }
        }
        foreach (@childs) {
                waitpid($_, 0);
        }
}

conformance_report() unless ($options{n});
updateDB() if ($options{s});

################################### sub routines #################

sub parse_rules{
# @arules = ($name);	#to keep all rule names, purpose is to keep original rule sequence
# %hrules = ($name -> %hash); #$name = rule_name; #to keep all rules details. hash is easier to process;
# 	%hash = (
#               "type" -> string, 	
#			#simple;	#this is for fixed line rules without instances; default type
					#match type can only be none or any
#			#dynamic; 	#this is for rules under instance context;
					#match type can be none, any, x,y and any_if_found
#			#get_parameter; #this is to extract and keep a parameter
#		"weight" -> string,	#info=1; low=1; medium=2; high=3; critical=5; #default is medium
#		"match" -> string,
#			#none		#this is inverse match, ie match none
#			#any		#match the rule for all instances; this is default
#			#x,y		#x and y are numubers >0, x<=y
#			#any_if_found	#if instance is found, match all of them
#			#none_if_found	#if instance is found, inverse match
#			#exclusive	#exact match under a config level; ie excessive lines will report
#		"level" -> string,	#required for exclusive match type; eg: /config system security snmp
#		"parameter" -> string, #to keep a parameter if rule type is get_parameter
#		"condition" -> string, #a global condition the rule depends on
#			#for example get_version=TiMOS-C-8.0.R10
#		"exists" -> string, #a  rule depends on
#               "content" -> @array, 	#@array = (rule content);
#		"instance" -> string,	#applies to dynamic rule type
#			#to find instance with regex, $1 is the instance, 
#			#example to find CA uplink: /config port (\S+?) description ".*?\w{8}CA\d{2}.*?"
#		"instances" -> %hash);	
#			#when parsing router config file, instances will be populated to hash
#               "instance_condition" -> string,   #a line the instance depends on, for example
#			#T1600 BR-BR port could be standalone or aggregate
#			#if it is aggregate, instance_condition=set interfaces i<1> sonet-options as[0-3]
#			#if it is standalone, instance_condition=set interfaces i<1> unit i<2>
#           another example: to check that a lag instance should not be radio transport:
#           	<#instance_condition=/config lag i<1> description "(?:(?!Radio).)*?">
#           this example uses perl negative match

	while (<RULES>) {
		if (/^\{-\s/){	#to process global parameters
			my $count = 0;
			while (<RULES>) {
				$count ++;
				die "possible loop? procesed $count line without close tag -}\n" if $count >100;
				next if /^\s*#/;
				next if /^\s*$/;
				$global{$1} = $2 if /^(\w\S+?)\s*=\s*(\S.+?)\s*$/;
				last if /^-\}\s/;
				die "missing close tag -} when processing global parameters!\n" if /^<-/;
			}
		}
		if (/^<-\s*(\S+)\s*?$/) {	#to process rules
			my $rule_name = $1;
			push @arules, $rule_name;
			$hrules{$rule_name}{"type"} = 'simple';
			$hrules{$rule_name}{"weight"} = 'medium';
			$hrules{$rule_name}{"match"} = 'any';
			my @rule = ();
			my $count = 0;
			while (<RULES>) {
				$count ++;
                                die "possible loop? rule: $rule_name; procesed $count line without close tag ->\n" if $count >50000;
				next if /^\s*#/;
				next if /^\s*$/;
				die "missing close tag when processing rule : $rule_name!\n" if /^<-/;
				if (/^->/) {
					die "$rule_name has no content!\n" unless @rule;
					die "$rule_name is dynamic but no instance defined!\n"
						if $hrules{$rule_name}{"type"} eq 'dynamic' and not exists $hrules{$rule_name}{"instance"};
					die "$rule_name is simple but has instance defined!\n"
						if $hrules{$rule_name}{"type"} eq 'simple' and $hrules{$rule_name}{"instance"};
					die "$rule_name is simple but match type is $hrules{$rule_name}{'match'}!\n"
						if $hrules{$rule_name}{'match'} ne 'none' and $hrules{$rule_name}{'match'} ne 'any' and $hrules{$rule_name}{'match'} ne 'exclusive' and $hrules{$rule_name}{"type"} eq 'simple';
					die "$rule_name  match type is exclusive but no config level defined!\n" 
						if $hrules{$rule_name}{'match'} eq 'exclusive' and not exists $hrules{$rule_name}{'level'};
					$hrules{$rule_name}{"content"} = [@rule];
					last;
				}
				my $line = $_;
				chomp $line;
                                $line =~ s/^\s+//; #remove leading spaces
                                $line =~ s/\s+$//; #remove trailing spaces
				if ($line =~ /^<#type\s*=\s*(\w+)>\s*$/){
					my $type = $1;
					die "$rule_name has wrong type $type!\n"
						if $type !~ /^(simple|dynamic|get_parameter)$/;
					$hrules{$rule_name}{"type"} = $type;
                                }elsif ($line =~ /^<#instance\s*=\s*(\S.+?)>\s*$/){
                                        $hrules{$rule_name}{"instance"} = $1;
				}elsif ($line =~ /^<#condition\s*=\s*(\S.+?\s*=\s*\S.+?)>\s*$/){
					$hrules{$rule_name}{"condition"} = $1;
				}elsif ($line =~ /^<#weight\s*=\s*(\S.+?)>\s*$/){
					my $weight = $1;
					die "$rule_name has invalid weight!\n" 
						unless $weight =~ /^(info|low|medium|high|critical)$/;
                                        $hrules{$rule_name}{"weight"} = $weight;
				}elsif ($line =~ /^<#match\s*=\s*(\S+)>\s*$/){
					my $match = $1;
					die "$rule_name has invalid match type!\n"
						unless $match =~ /^(none|any|any_if_found|none_if_found|\d+,\d+|exclusive)/;
                                        $hrules{$rule_name}{"match"} = $match;
				}elsif ($line =~ /^<#level\s*=\s*(\S.+?)>\s*$/){
					$hrules{$rule_name}{"level"} = $1;
				}elsif ($line =~ /^<#instance_condition\s*=\s*(\S.+?)>\s*$/){
					$hrules{$rule_name}{"instance_condition"} = $1;
				}else {
					push @rule, $line;
				}
			}
		}
	}
print $#arules + 1, " conformance rules successfully parsed.\n";
return 1;
}

sub parse_global{
	return 1 unless ($options{b});
	my $date = `date +"%Y-%m-%d"`;
	chomp $date;
	my $report_link = $global{"output_report_summary_file"};
	$report_link =~ s/.html?$/_$date.html/;
	$global{"output_report_summary_file"} = $report_link;
	$report_link = $global{"output_report_detail_file"};
	$report_link =~ s/.html?$/_$date.html/;
	$global{"output_report_detail_file"} = $report_link;
}

sub html_rules{
	my $file = $global{'output_dir'} . $global{'output_report_summary_file'};
        open OUTPUT, ">>$file" or die "can not open file $file!\n";

	print OUTPUT "<p>Rules definition report:</p>\n";
	print OUTPUT "<table border='1'>\n";
 	print OUTPUT "<tr><th>Rule Name</th><th>Rule Lines</th></tr>\n";
	foreach (@arules) {
		my $rule_name = $_;
		my $type = $hrules{$rule_name}{"type"};
		my $string = $rule_name . "<br>type: $type";
		$string .= "<br>match type : $hrules{$rule_name}{'match'}"  if exists $hrules{$rule_name}{'match'};
		$string .= "<br>weight : $hrules{$rule_name}{'weight'}"  if exists $hrules{$rule_name}{'weight'};
		$string .= "<br>condition : $hrules{$rule_name}{'condition'}" if exists $hrules{$rule_name}{"condition"};
		print OUTPUT "<tr> <td><a name = $rule_name>$string</td>\n";
		print OUTPUT "<td>\n";
		print OUTPUT "<pre>\n";
		$string = "instance = $hrules{$rule_name}{'instance'}" if exists $hrules{$rule_name}{'instance'};
		print OUTPUT "#$string\n" if exists $hrules{$rule_name}{'instance'};
		$string = "level = $hrules{$rule_name}{'level'}" if exists $hrules{$rule_name}{'level'};
		print OUTPUT "#$string\n" if exists $hrules{$rule_name}{'level'};
		$string = "instance_condition = $hrules{$rule_name}{'instance_condition'}" if exists $hrules{$rule_name}{'instance_condition'};
		print OUTPUT "#$string\n" if exists $hrules{$rule_name}{'instance_condition'};
		foreach (@{$hrules{$rule_name}{"content"}}) {
			my $line = encode_entities( $_ ); 
			print OUTPUT "$line\n";
		}
		print OUTPUT "</pre>\n";
		print OUTPUT "</td></tr>\n";
	}
	print OUTPUT "</table>\n";
	print OUTPUT "</body>\n";
	print OUTPUT "</html>\n";
	close OUTPUT;
	return 1;
}


sub conformance{
	my $router = uc $_[0];
	my $hostclli = substr $router, 0, 8;
	my $start = time();
	my $province = substr($router,4,2);
	$global{'input_suffix'} = '.flat.config' unless exists $global{'input_suffix'};
	my $file = $global{'input_dir'} . $router . $global{'input_suffix'};
	my @logs;
	open FILE, $file or die "can not open file $file\n";
	push @logs, "#$router conformance started:\n";
	print "#$router conformance started:\n";
	my %configs;
	my @aconfigs;
	while (<FILE>){
		next if /^#/;
		next if /^\s*$/;
		my $line = $_;
		chomp $line;
		$line =~ s/^\s*//;
		$line =~ s/\s*$//;
		#next if /^\/configure router igmp ssm-translate/;  #skip ssm for now. too many lines to process
		$configs{$line} ++;
		push @aconfigs, $line;
		foreach (@arules) {	#loop though all config lines to find all instances in dynamic rules
			my $rule_name = $_;
			next if ($hrules{$rule_name}{"type"} eq 'get_parameter');	
			next unless $hrules{$rule_name}{"type"} eq 'dynamic';
                	my $instance = $hrules{$rule_name}{"instance"};
			if (my @matched = $line =~ /$instance/) {
				#print "rule_name:$rule_name; line:$line; instance:$instance\n";
				$hrules{$rule_name}{"instances"}{join '<i>', @matched} = 0; 
			}
		}
	}
	close FILE;
    foreach (@arules) {
		my $rule_name = $_;
		my $rule_type = $hrules{$rule_name}{"type"};
		my @rule_lines = @{$hrules{$rule_name}{"content"}};
		my $rule_size = scalar @rule_lines;
		my $number_instance = keys %{$hrules{$rule_name}{"instances"}};
        my $matched_instance = 0;
        my $diff_count = 0;
		my $condition;
		my $condition_matched;
		my ($status, $score);
		my $weight = $hrules{$rule_name}{"weight"};
		my $match = $hrules{$rule_name}{"match"};
        my @diffs;
		if ($rule_type eq 'get_parameter') {	#to get parameter from config lines
			die "$rule_name size not equal to 1\n" if $rule_size != 1;
			my $rline = $rule_lines[0];
			foreach (keys %configs) {
				my $cline = $_; #config line
				if ($cline =~ /$rline/) {
					$hrules{$rule_name}{'parameter'} = $1;
					last;
				}
			}
			die "$rule_name failed to get the parameter from file $file\n" if not exists $hrules{$rule_name}{'parameter'};
			push @logs, "  #!$router : $rule_name : $rule_type : parameter=$hrules{$rule_name}{'parameter'}\n";
			next;
		} #end of if ($rule_type eq 'get_parameter')

		if (exists $hrules{$rule_name}{"condition"}) {
			$condition = $hrules{$rule_name}{"condition"};
			my ($condition_rule_name,$parameter) = split '=', $condition;
			die "$rule_name condition failed to parse\n" unless ($condition_rule_name and $parameter);
			if ($hrules{$condition_rule_name}{'parameter'} !~ /$parameter/) {
				$condition_matched = 'no';
				push @logs, "  #!$router : $rule_name : $rule_type : condition=$condition : condition_matched=no\n";
				next;
			}else {
				$condition_matched = 'yes';
			}
		}else{
			$condition = 'no_condition';
			$condition_matched = 'n/a';
		} #end of if (exists $hrules{$rule_name}{"condition"}) {

		#below if block to process instance_condition;
        if (exists $hrules{$rule_name}{"instance_condition"}) {
			foreach (keys %{$hrules{$rule_name}{"instances"}}) {
				my $string = $hrules{$rule_name}{"instance_condition"};
				my $instance = $_;
				my @parameters = split '<i>', $instance;
				my $x = 1;
				foreach (@parameters) {
					my $parameter = $_;
					$string =~ s/i<$x>/$parameter/g; #replace with real instance
					$x ++;
				}
				foreach (keys %configs) {
					my $cline = $_; #config line
					if ($cline =~ /$string/) {
						$hrules{$rule_name}{"instances"}{$instance} = 'y'; 
						last;
					}
				}
				delete $hrules{$rule_name}{"instances"}{$instance} 
					unless $hrules{$rule_name}{"instances"}{$instance} eq 'y';
			}
		}  # end of if (exists $hrules{$rule_name}{"instance_condition"})

		$number_instance = keys %{$hrules{$rule_name}{"instances"}};
		if ($hrules{$rule_name}{"type"} eq 'simple') {
			$hrules{$rule_name}{"instances"}{"no_instance"} ++;
		}

		foreach (sort keys %{$hrules{$rule_name}{"instances"}}) {
			my @parameters = split '<i>', $_; #eg, ae0<i>0
			my @instance_diffs;
			foreach (@rule_lines) {
               	my $rline = $_; #rule_line
               	my $matched = 0;
               	$rline =~ s/s<HOSTNAME>/$router/g; #support HOSTNAME substitution
				$rline =~ s/s<HOSTCLLI>/$hostclli/g; #support HOSTCLLI substitution
				my $x = 1; 
				foreach (@parameters) {
					my $parameter = $_;
					$rline =~ s/i<$x>/$parameter/g; #replace with real instance 
					$x ++;
				}
               	if ($rline =~ /^r<(.+)>$/){ #a line with regex
                   	$rline = $1;
                   	foreach (keys %configs) {
                       	my $cline = $_; #config line
                       	if ($cline =~ /$rline/) {
                           	$matched = $cline;
                           	$rline = $cline;
                           	last;
                       	}
                  	}
					$rline = '#' . $rline unless $matched; #add a # before regex rule line
               	}else{
                   	$matched = $rline if exists $configs{$rline};
               	}
               	if ($match eq 'any') {
					push @instance_diffs, "- $rline" unless $matched;
                }elsif ($match eq 'any_if_found') {
					push @instance_diffs, "- $rline" unless $matched;
                }elsif ($match eq 'none') {
                   	push @instance_diffs, "+ $matched" if $matched;
				}elsif ($match eq 'none_if_found') {
					push @instance_diffs, "+ $matched" if $matched;
                }elsif ($match =~ /^(\d+),(\d+)$/) {
					push @instance_diffs, "- $rline" unless $matched;
                }elsif ($match eq 'exclusive') {
					push @instance_diffs, "- $rline" unless $matched;
				}
            } #end of foreach (@rule_lines) {

            my $level;
            if ($match eq 'exclusive') {
                $level = $hrules{$rule_name}{"level"};
                my $x = 1;
                foreach (@parameters) {
                    my $parameter = $_;
                    $level =~ s/i<$x>/$parameter/g; #replace with real instance
                    $x++;
               }
               foreach (@aconfigs) {
                    my $cline = $_; #config line
                    my $number = 0;
                    next unless $cline =~ /^$level/;
                    foreach (@rule_lines) {
                        my $rline = $_;
                        $rline =~ s/s<HOSTNAME>/$router/g;
						$rline =~ s/s<HOSTCLLI>/$hostclli/g;
                        my $x = 1;
                        foreach (@parameters) {
                            my $parameter = $_;
                            $rline =~ s/i<$x>/$parameter/g; #replace with real instance
                            $x ++;
                        }
						if ($rline =~ /^r<(.+)>$/){ #a line with regex
							$rline = $1;
							$number ++ if $cline =~ /$rline/;
 						}else {
                           	$number ++ if $cline eq $rline;
						}
                    }
                    push @instance_diffs, "+ $cline" if $number ==0;
               }  # end of foreach (@aconfigs)
            } #end of if ($match eq 'exclusive') {

			if (@instance_diffs) {
				$diff_count += $#instance_diffs + 1;
				push @diffs, @instance_diffs;
				$matched_instance ++ if $match eq 'none';
				$matched_instance ++ if $match eq 'none_if_found';
			}else {
				$matched_instance ++ if $match ne 'none' and $match ne 'none_if_found';
			}
        } #end of foreach (sort keys %{$hrules{$rule_name}{"instances"}})

		if ($rule_type eq 'simple') {
			$number_instance = 'n/a';
			$matched_instance = 'n/a';
			$status = 'pass';
			$status = 'fail' if $diff_count;
			$score = 100 * ($rule_size-$diff_count)/$rule_size;
			$score = 0 if $score < 0;
                }
		if ($rule_type eq 'dynamic') {
			if ($number_instance == 0) {
				if ($match eq 'any' or $match eq 'exclusive' or $match =~ /^(\d+),(\d+)$/) {
					$status = 'fail';
					$score = 0;
				}else {
					$status = 'pass';
					$score = 100;
				}
			}elsif ($match eq 'any' or $match eq 'any_if_found' or $match eq 'exclusive') {
				$status = 'pass' if $matched_instance == $number_instance;
				$status = 'fail' if $matched_instance != $number_instance;
				$score = 100 - 100 * $diff_count / ($number_instance * $rule_size);
				$score = 0 if $score < 0;
			}elsif ($match =~ /^(\d+),(\d+)$/) {
				my ($min, $max) = ($1, $2);
				$status = 'pass' if $min <= $matched_instance and $matched_instance <= $max;
				$status = 'fail' if $matched_instance < $min or $matched_instance > $max;
				$score = 100 if $status eq 'pass';
				$score = 100 - 100 * $diff_count / ($number_instance * $rule_size) 
					if $status eq 'fail';
				$score = 0 if $score < 0;
			}elsif ($match eq 'none' or $match eq 'none_if_found') {
				$status = 'pass' if $matched_instance == 0;
				$status = 'fail' if $matched_instance > 0;
				$score = 100 - 100 * $diff_count / ($number_instance * $rule_size);
				$score = 0 if $score < 0;
			}
		}
		$score = sprintf ("%2d%%", $score);
                my $string = "  ##$router : $rule_name : $rule_type : $match : $status : ";
                $string .= "$weight : $score : $condition : $condition_matched : ";
                $string .= "$rule_size : $number_instance : $matched_instance : $diff_count\n";
                push @logs, $string;
                push @logs, "    $_\n" foreach @diffs;
	}
	push @logs, "#$router conformance finished:\n\n";
        my $logfile = $global{'output_dir'} . $global{'output_report_log_file'};
        open OUT, ">>$logfile" or die "can not open file $logfile for writing\n";
	flock(OUT, 2); #exclusive writing
	print OUT $_ foreach (@logs);
        close OUT;
	my $end = time();
	my $delta= $end - $start;
	print "#$router conformance finished, took $delta seconds.\n";
	if ($options{p}) {
		print "<-$router conformance finished in $delta seconds.\n";
		foreach (@logs) {
			my $line = $_;
			print $line if $line =~ /^ +[-+]/;
		}
		print "->\n";
        }

  	return 1;
}

sub conformance_report{
	my $logfile = $global{'output_dir'} . $global{'output_report_log_file'};
	open LOG, $logfile or die "can not open file $logfile!\n";
	my $detailfile = $global{'output_dir'} . $global{'output_report_detail_file'};
	open DETAIL, ">$detailfile" or die "can not open file $detailfile!\n";
        my $sumfile = $global{'output_dir'} . $global{'output_report_summary_file'};
        open SUM, ">$sumfile" or die "can not open file $sumfile!\n";

	my $number_rules = $#arules + 1;
	my $number_routers = keys %hrouters;
	my $time;
	my %rules_sum;
#       %rules_sum = ($name -> %hash);
#       %hash = (
#               "total_weight" -> number,
#		"total_pass" -> number,
#               "total_fail" -> number,
#		"total_condition_match" -> number,
#               "total_condition_no_match" -> number,
#		"total_score" -> number,
#		"failed_routers" -> array,
#		}

        my %routers_sum;
#       %routers_sum = ($name -> %hash);
#       %hash = (
#               "total_weight" -> number,
#               "total_pass" -> number,
#               "total_fail" -> number,
#               "total_condition_match" -> number,
#               "total_condition_no_match" -> number,
#               "total_score" -> number,
#               "total_get_parameter" -> number,
#		}

	my $title = "$global{'report_title'} - conformance detail";
        print DETAIL "<html>\n";
        print DETAIL "<body>\n";
        print DETAIL  "<p>#### $title ####</p>\n";
	print DETAIL "<p><a href=$global{'output_report_summary_file'}>$global{'report_title'} summary report</a></p>\n";
	print DETAIL "<p><a href=http://abc-ni-01.osc.tac.net/conformance/> Other Conformance Reports</a></p>\n";
        while (<LOG>) {
		if (/^#report started at/) {
			print DETAIL "<p>$_</p>\n";
			$time = $_;
		}elsif (/^#([a-z,A-Z,0-9,-_]+) conformance started:/) {
			print DETAIL "<p><a name=#$1>$_</a></p>\n";
			print DETAIL "<table border='1'>\n";
			my $string = "<tr><th>Router</th><th>Rule_Name</th><th>Rule_type</th>\n";
			$string .= "<th>Match_type</th><th>Match_Status</th>\n";
			$string .= "<th>Rule_Weight</th><th>Score</th>\n";
			$string .= "<th>Rule_Condition</th><th>Condition_matched</th>\n";
			$string .= "<th>Rule_lines</th><th>Instances</th>\n";
			$string .= "<th>matched_instances</th><th>Diff_lines</th>\n";
			$string .= "</tr>\n";
			print DETAIL $string;
		}elsif (/^  #!(.+)$/) {  #rule type is get_parameter or condition not matched
			print DETAIL "<tr><td colspan='13'>info: $1</td></tr>\n";
			my @colmns = split ' : ', $1;
			my $router = $colmns[0];
			my $rule_name = $colmns[1];
			my $rule_type = $colmns[2];
			$rules_sum{$rule_name}{"type"} = $rule_type;
			if ($rule_type eq 'get_parameter') {
				$routers_sum{$router}{"total_get_parameter"} ++;
			}else { #condition not matched
				$routers_sum{$router}{"total_condition_no_match"} ++;
				$rules_sum{$rule_name}{"total_condition_no_match"} ++;
			}
		}elsif (/^  ##(.+)$/) {
			my @colmns = split ' : ', $1;
			my $router = $colmns[0];
			my $rule_name = $colmns[1];
			my $rule_type = $colmns[2];
			my $match = $colmns[3];
			my $status = $colmns[4];
			my $weight = $colmns[5];
			$weight = $weights{$weight};
			#print "score column = $colmns[6]\n"; 
			my $score = $1 if $colmns[6] =~ /^\s*(\d+)%\s*$/;
			my $condition = $colmns[7];
			my $condition_matched = $colmns[8];
			my $instances = $colmns[10];
			$rules_sum{$rule_name}{"total_weight"} += $weight;
			$rules_sum{$rule_name}{"total_pass"} ++ if $status eq 'pass';
			$rules_sum{$rule_name}{"total_fail"} ++ if $status eq 'fail';
			push @{$rules_sum{$rule_name}{"failed_routers"}}, $router if $status eq 'fail';
			$rules_sum{$rule_name}{"total_condition_match"} ++ if $condition_matched eq 'yes';
			print "rule:$rule_name, no score!\n" unless defined $score;
			$rules_sum{$rule_name}{"total_score"} += $score * $weight;
			if ($colmns[5] eq 'info'){	#Feng 2016-04-29, exclude if weight is info
				$routers_sum{$router}{"total_pass"} ++ if $status eq 'pass';
				$routers_sum{$router}{"total_fail"} ++ if $status eq 'fail';
				$routers_sum{$router}{"total_condition_match"} ++ if $condition_matched eq 'yes';
			} else {
				$routers_sum{$router}{"total_weight"} += $weight;
                $routers_sum{$router}{"total_pass"} ++ if $status eq 'pass';
                $routers_sum{$router}{"total_fail"} ++ if $status eq 'fail';
                $routers_sum{$router}{"total_condition_match"} ++ if $condition_matched eq 'yes';
                $routers_sum{$router}{"total_score"} += $score * $weight;
			}
			
			if ($options{v}) {
			}elsif ($status eq 'pass') {
				next;
			}
			my $bgcolor = '#FFFFFF'; #white	
			$bgcolor = '#CCCC00' if $status eq 'fail';  #sort of light yellow
			$bgcolor = '#F0F0F0' if ($match eq 'any_if_found' and $instances eq '0'); # grey
			print DETAIL "<tr bgcolor=$bgcolor>\n";
			print DETAIL "<td>$router</td>\n";
			shift @colmns;
			print DETAIL "<td><a name=$router:$rule_name>$rule_name</a></td>\n";
			shift @colmns;
			foreach (@colmns) {
				print DETAIL "<td>$_</td>\n";
			}
			print DETAIL "</tr>\n";
		}elsif (/^    (-|\+) /) {
			print DETAIL "<tr><td colspan='13'>&nbsp&nbsp&nbsp&nbsp$_</td></tr>\n";
		}elsif (/^#([a-z,A-Z,0-9,-_]+) conformance finished:/) {
			print DETAIL "</table>\n";
		}elsif (/^\s*$/) {
		}else {
			die "unexpected line:\n   $_\n";
		}

        }

	print DETAIL "<p>Rules with failed routers:</p>\n";
	print DETAIL "<table border='1'>\n";
	print DETAIL "<tr><th>Rule</th><th>Failed_Routers</th></tr>\n";

	foreach (@arules) {
		my $rule_name = $_;
		next unless $rules_sum{$rule_name}{"failed_routers"};
		my $count = 0;
		print DETAIL "<tr><td>$rule_name</td>\n";
		print DETAIL "<td>\n";
		foreach (@{$rules_sum{$rule_name}{"failed_routers"}}) {
			my $router = $_;
			print DETAIL "<a href=#$router:$rule_name>$router </a>\n";
			$count ++;
			if ($count > 6) {
				print DETAIL "<p> </p>\n";
				$count =0;
			}
		}
		print DETAIL "</td></tr>\n";
	}
	print DETAIL "</table>\n";

        print DETAIL "</body>\n";
        print DETAIL "</html>\n";

	close LOG;
	close DETAIL;


	if (exists $global{'from'} and exists $global{'to'}) {
                qx{sendEmail -f $global{'from'} -t $global{'to'} -u "$title" -o message-file=$detailfile};
        }

        $title = "$global{'report_title'} - conformance summary";
        print SUM "<html>\n";
        print SUM "<body>\n";
        print SUM  "<p>#### $title ####</p>\n";
	print SUM "<p><a href=$global{'output_report_detail_file'}>$global{'report_title'} details report</a></p>\n";
        print SUM "<p><a href=http://abc-ni-01.osc.tac.net/~t826733/conformance/> Other Conformance Reports</a></p>\n";

	print SUM "<p>$time</p>\n";

	my $total_score;
	my $total_weight;
	foreach (keys %rules_sum) {
		next if ($hrules{$_}{"type"} eq 'get_parameter');
		next if ($hrules{$_}{"weight"} eq 'info');	#Feng 2016-04-29
		$total_score += $rules_sum{$_}{"total_score"} if exists $rules_sum{$_}{"total_score"};
		$total_weight += $rules_sum{$_}{"total_weight"} if exists $rules_sum{$_}{"total_weight"};
	}
	my $sum_score = $total_score/$total_weight;
	$global{"config_score"} = $sum_score;
	$global{"software_score"} = $rules_sum{"system_version"}{"total_score"} / $rules_sum{"system_version"}{"total_weight"} if exists $rules_sum{"system_version"};
	$sum_score = sprintf ("%d%%", $sum_score);
	print SUM "<p>Overall Conformance Score Calculated from $number_rules Rules : $sum_score</p>\n";
	
	($total_score, $total_weight, $sum_score) = (0, 0, 0);	
	foreach (keys %routers_sum) {
		$total_score += $routers_sum{$_}{"total_score"} if exists $routers_sum{$_}{"total_score"};
		$total_weight += $routers_sum{$_}{"total_weight"} if exists $routers_sum{$_}{"total_weight"};
	}
	$sum_score = $total_score/$total_weight;
	$sum_score = sprintf ("%d%%", $sum_score);
	my $success_routers = keys %routers_sum;
	print SUM "<p>Overall Conformance Score Calculated from $success_routers Routers : $sum_score</p>\n";
	if ($success_routers != $number_routers) {
		print SUM "<p>Below router(s) failed open input file(s):</p>\n";
		foreach (sort keys (%hrouters)) {
			print SUM "&nbsp $_" if not exists $routers_sum{$_};
		}
	}

	print SUM "<p>Conformance Rules Summary Report:</p>\n";
	print SUM "<table border='1'>\n";
	my $string = "<tr><th>Rule_Name</th><th>Rule_Type</th><th>Passed</th><th>Failed</th>\n";
	$string .= "<th>Condition_Meet</th><th>Condition_Not_Meet</th>\n";
	$string .= "<th>Weight</th><th>Score</th>\n";
	print SUM $string;

	foreach (@arules) {
		my ($rule_name, $rule_type, $weight, $score);
		my ($passed, $failed, $condition_meet, $condition_not_meet);
		$rule_name = $_;
		#print "rulename : $rule_name\n";
		#print "  $_ -> $rules_sum{$rule_name}{$_}\n" foreach keys %{$rules_sum{$rule_name}};
		$rule_type = $hrules{$rule_name}{"type"};

		if (not exists $hrules{$rule_name}{"condition"}) {
			($condition_meet, $condition_not_meet) = qw (n/a n/a);
		}
		
		if ($rule_type eq 'get_parameter') {
			($passed, $failed, $condition_meet, $condition_not_meet) = qw (n/a n/a n/a n/a);
			($weight, $score) = qw (n/a n/a);
		}else {
			$weight = $hrules{$rule_name}{"weight"};
			$weight = $weights{$weight};
			if (exists $rules_sum{$rule_name}{"total_pass"}) {
				$passed = $rules_sum{$rule_name}{"total_pass"};
			}else {
				$passed = 0;
			}
			if (exists $rules_sum{$rule_name}{"total_fail"}) {
				$failed = $rules_sum{$rule_name}{"total_fail"};
			}else {
				$failed = 0;
			}
			if (exists $rules_sum{$rule_name}{"total_condition_match"}) {
				$condition_meet = $rules_sum{$rule_name}{"total_condition_match"};
			}else {
				$condition_meet = 0;
			}
			if (exists $rules_sum{$rule_name}{"total_condition_no_match"}) {
				$condition_not_meet = $rules_sum{$rule_name}{"total_condition_no_match"};
			}else{
				$condition_not_meet = 0;
			}
			my $total_score = $rules_sum{$rule_name}{"total_score"};
			if ($passed + $failed) {
				$score = $total_score / ($passed + $failed) / $weight;
				$score = sprintf ("%d%%", $score);
			}else {
				$score = 'n/a';
			}
		}
		my $bgcolor = '#CCCC00' if $score ne "100%";
		$bgcolor = '#FFFFFF' if $score eq "100%";
		$bgcolor = '#FFFFFF' if $rule_type eq 'get_parameter';
		$bgcolor = '#FFFFFF' if $score eq "n/a";
		$string = "<tr bgcolor=$bgcolor><td><a href=#$rule_name>$rule_name</a></td>";
		$string.= "<td>$rule_type</td>";
		$string.= "<td>$passed</td>";
		$string.= "<td>$failed</td>";
		$string.= "<td>$condition_meet</td>";
		$string.= "<td>$condition_not_meet</td>";
		$string.= "<td>$weight</td>";
		$string.= "<td>$score</td></tr>\n";
		print SUM $string;
	}

	print SUM "</table\n";	

	print SUM "<p>Conformance Routers Summary Report:</p>\n";
        print SUM "<table border='1'>\n";
        $string = "<tr><th>Router_Name</th><th>passed</th><th>Failed</th>\n";
        $string .= "<th>Condition_Meet</th><th>Condition_Not_Meet</th>\n";
        $string .= "<th>Get Parameters</th><th>Score</th>\n";
        print SUM $string;

	foreach (sort (keys %routers_sum)) {
	#foreach (sort (keys %hrouters)) {
		my $router = $_;
		#print "router : $router\n";
		my ($passed, $failed, $condition_meet, $condition_not_meet);
		my ($total_weight, $total_score, $score, $get_parameter);
		#print "  $_ -> $routers_sum{$router}{$_}\n" foreach keys %{$routers_sum{$router}};
		if (exists $routers_sum{$router}{"total_pass"}) {
			$passed = $routers_sum{$router}{"total_pass"};
		}else {
			$passed = 0;
		}
		if (exists $routers_sum{$router}{"total_fail"}) {
                        $failed = $routers_sum{$router}{"total_fail"};
                }else {
                        $failed = 0;
                }
		if (exists $routers_sum{$router}{"total_condition_match"}) {
                        $condition_meet = $routers_sum{$router}{"total_condition_match"};
                }else {
                        $condition_meet = 0;
                }
		if (exists $routers_sum{$router}{"total_condition_no_match"}) {
                        $condition_not_meet = $routers_sum{$router}{"total_condition_no_match"};
                }else {
                        $condition_not_meet = 0;
                }
		if (exists $routers_sum{$router}{"total_get_parameter"}) {
                        $get_parameter = $routers_sum{$router}{"total_get_parameter"};
                }else {
                        $get_parameter = 0;
                }

		$total_score = $routers_sum{$router}{"total_score"};
		$total_weight = $routers_sum{$router}{"total_weight"};
		$score = $total_score / $total_weight;
		$score = sprintf ("%d%%", $score);
		my $bgcolor = '#CCCC00' if $score ne "100%";
                $bgcolor = '#FFFFFF' if $score eq "100%";
		$string = "<tr bgcolor=$bgcolor><td><a href=$global{'output_report_detail_file'}#$router>$router</a></td>";
		$string .= "<td>$passed</td>";
		$string .= "<td>$failed</td>";
		$string .= "<td>$condition_meet</td>";
		$string .= "<td>$condition_not_meet</td>";
		$string .= "<td>$get_parameter</td>";
		$string .= "<td>$score</td>";
		print SUM $string;
	}
	print SUM "</table>\n";
	close SUM;
	html_rules();
        if (exists $global{'www_dir'}) {
            my $remote = $global{'www_dir'} . $global{'output_report_detail_file'};
			`cp $detailfile $remote`;
			$remote = $global{'www_dir'} . $global{'output_report_summary_file'};
			`cp $sumfile $remote`;
			print "html detail report generated : http://abc-ni-01.osc.tac.net/conformance/" . $global{"www_url_base"} . "$global{'output_report_detail_file'}\n";
			print "html summary report generated : http://abc-ni-01.osc.tac.net/conformance/" . $global{"www_url_base"} . "$global{'output_report_summary_file'}\n";
        }
        if (exists $global{'from'} and exists $global{'to'}) {
                qx{sendEmail -f $global{'from'} -t $global{'to'} -u "$title" -o message-file=$sumfile};
        }


}

sub updateDB{
	my $dbh = DBI->connect( 'dbi:mysql:bc_core:abc-ni-01.osc.tac.net:3306',
                              'feng',
                              '83jd723d',
                              {
                                RaiseError => 1,
                              }
   ) || die "Database connection not made: $DBI::errstr";
	my $date = `date +"%Y-%m-%d"`;
    chomp $date;
	my $current = 'y';
	my $device_type=$global{"device_type"};
    my $device_count = int keys %hrouters;
	my $rule_count = int $#arules + 1;
	my $bcp_version = $global{"BCP_version"};
	my $report_type = $global{"report_type"};
	my $report_link = $global{"www_url_base"} . $global{"output_report_summary_file"};
	my $config_score = int $global{"config_score"};
	my $software_score;
	if (exists $global{"software_score"}) {
		$software_score = int $global{"software_score"};
	}else {
		$software_score = -1;
	}

	print "updating mySQL conformance dashboard Database:\n";
	print "checking whether '$date' '$device_type' '$report_type' already exists...\n";
	my $sql = qq{	select * from dashboard
					where date="$date" and device_type="$device_type" and report_type="$report_type"
	};
	my $statement = $dbh->prepare( $sql ) or die "sql statement $sql failed\n";
	$statement->execute( );
	my $number = 0;
	while ( my @row = $statement->fetchrow_array) {
		#print "\t$_" foreach (@row) ;
		$number ++;
	}
	
	if ($number > 1) {
		 die "$date $device_type $report_type has more than one records!\n";
	}elsif ($number == 1) {
		print "'$date' '$device_type' '$report_type' exists, updating existing...\n";
			
		$sql = qq{	update dashboard
				set device_count=$device_count,
				rule_count=$rule_count,
				bcp_version="$bcp_version",
				report_link="$report_link",
				config_score=$config_score,
				software_score=$software_score
				where date="$date" and device_type="$device_type" and report_type="$report_type"
		};
		print "executing below sql statement ...\n$sql\n";
		$statement = $dbh->prepare( $sql ) or die "sql statement $sql failed\n";
		$statement->execute();
	}else {
		print "'$date' '$device_type' '$report_type' is new record.\n";
		print "unset current flag for previous current record...\n";
		$sql = qq{	update dashboard
				set current="n"
				where current="y" and device_type="$device_type" and report_type="$report_type"
		};
		print "executing below sql statement...\n$sql\n";
		$statement = $dbh->prepare( $sql ) or die "sql statement $sql failed\n";
		$statement->execute();
		
		$sql = qq{	insert into dashboard
				set date="$date",
				current="$current",
				device_type="$device_type",
				device_count=$device_count,
				rule_count=$rule_count,
				bcp_version="$bcp_version",
				report_type="$report_type",
				report_link="$report_link",
				config_score=$config_score,
				software_score=$software_score
		};
		print "executing below sql statement...\n$sql\n";
		$statement = $dbh->prepare( $sql ) or die "sql statement $sql failed\n";
		$statement->execute( );
	}
			
	$dbh->disconnect() or die "disconnect database failed\n";
}
