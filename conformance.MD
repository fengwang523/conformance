conformance scripts are in bin/ dir

1. NI Conformance Script Supported Vendors:
 The script only supports config files in flatformat. 

 Does not support indented config format  

 Junos support flat config natively (show config | display set) 

 Nokia 7x50 SROS native indented config file can be flatted via conformance script therefore is supported 

 Cisco IOS config can be flatted with a script as well

2. script files

  config_conformance_report.pl     #the main script to generate conformance result

  7x50_saveconfig.pl               #save config on nokia 7x50 devices

  7x50_scpconfig.pl                #scp config from nokia 7x50 devices

  7x50_flat_config.pl              #flat the native 7x50 config

  7x50_filter_config.pl            #filter 7x50 flat config to speed up conformance script

  junos_get_flat_config.pl         #get display set style config from junos devices

  cisco_show_config.pl             #get config from cisco devices
 
  IOS_flat_config.pl               #convert IOS native to flat stype

  config_conformance_update.pl     #read conformace result, and push updates to network

3. conformance rule template files

  locate in /rules directory

  Rule template file structure
   
    - to comment out any line, type # at the beginning of the line 
    - file contains two portions: global parameters and list of conformance rules
    - rule lines can be built using perl type regular expression 

4.  Global Parameters:
    - Global parameters are required to provide instructions to conformance script fo
r varies of things
    - Global parameters are enclosed in between "{-" and "-}"
    - use below as a template:

{-
device_type = Nokia_7750C4_RE
BCP_version = 15.2.0
report_type = BCP Base Config Conformance
input_dir = /data/conformance/configs/
input_suffix = .filter.config
output_dir = /data/conformance/output/
www_dir =  /usr/local/www/apache22/data/conformance/nokia/
www_url_base = nokia/
from = feng.wang\@telus.com
to = feng.wang\@telus.com
output_report_summary_file = Nokia_7750C4_RE_BCP15.2.0_conformance_summary.html
output_report_detail_file = Nokia_7750C4_RE_BCP15.2.0_conformance_detail.html
output_report_log_file = Nokia_7750C4_RE_BCP15.2.0_conformance_log.txt
report_title = Nokia 7750C4 RE BCP 15.2.0 Conformance
-}

  example explained: 

 {- : open tag 
 device_type : use <Vendor>_<Chassis>_<Device Role> format, eg: Nokia_7750C4_RE;  !!! no space please!!! 
 BCP_version : BCP version for the rules, eg: 15.2.0 
 report_type : for now please use "BCP Base Config Conformance"; in future you may do for example "MVPN Config Conformance" 
 input_dir : always use "/data/conformance/configs/" 
 input_suffix : normally it is ".flat.config"; unless for 7750 RE case to use filtered config file 
 output_dir : always use "/data/conformance/output/" 
 www_dir : either "/usr/local/www/apache22/data/conformance/nokia/" or "/usr/local/www/apache22/data/conformance/junos/" 
 www_url_base = either "nokia/" or "junos/" 
 from : email address for email report; can be commented out if you don't want email 
 to : email address for email report; can be commented out if you don't want email 
 output_report_summary_file : use <vendor>_<chassis>_<device role>_<BCPversion>_conformance_summary.html 
 output_report_detail_file : use <vendor>_<chassis>_<device role>_<BCPversion>_conformance_detail.html 
 output_report_log_file = Nokia_7750C4_RE_BCP15.2.0_conformance_log.txt 
 report_title = Nokia 7750C4 RE BCP 15.2.0 Conformance 
 -} : closing tag 


5. rule types:

5.1 Simple Rules

5.1.1 Simple rule practical scenarios:

 Simple means that the config lines in this rule are typical static lines. 
 The simplest rule is some config lines that can be directly copied from BCP to device with no dependencies 
 However, there are scenarios require information dependent on each device or other part of config, examples:
  -  router system or loopback IP is device dependent 
  - syslog/tacacs/sntp server IPs depend on the province 
  - some config is only supported in certain software version 

 or you may want to check that certain config line should not be applied on the device 
 this section will explain how to build rules for these scenarios from simplest to advanced 
   
5.1.2 A simple Nokia 7x50 SROS rule example

in this example, a group of config lines can be copied from BCP to each device: 
<- system_global
/config system power-supply 1 dc
/config system power-supply 2 dc
/config system l4-load-balancing
/config system lsr-load-balancing lbl-ip
/config system snmp packet-size 9216
/config system lldp tx-interval 20
/config system lldp tx-hold-multiplier 3
->

5.1.3 A simple JUNOS rule example

<- event-options
set event-options policy BGP_TRAPS events rpd_bgp_neighbor_state_changed
set event-options policy BGP_TRAPS then raise-trap
->

5.1.4 Simple rule structure explained

<- rule_name
<#type=rule_type>                 #default rule type is simple so this line can be omitted
<#condition=conditional_rule_name=value>     #default rule has no conditional rule so this line can be omitted
<#match=match_type>               #default rule match_type is to match any so this line can be omitted
<#weight=rule_weight>             #rule weight is to differentiate rule importance, default is medium so this line can be omitted
rule line 1
rule line 2
...
rule line n
->


  
