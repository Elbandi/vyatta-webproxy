#!/usr/bin/perl
#
# Module: vyatta-update-webproxy.pl
# 
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
# 
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2008 Vyatta, Inc.
# All Rights Reserved.
# 
# Author: Stig Thormodsrud
# Date: August 2008
# Description: Script to configure webproxy (squid and squidguard).
# 
# **** End License ****
#

use Getopt::Long;
use POSIX;

use lib "/opt/vyatta/share/perl5";
use Vyatta::Config;
use Vyatta::Webproxy;

use warnings;
use strict;

# squid globals
my $squid_conf      = '/etc/squid3/squid.conf';
my $squid_log       = '/var/log/squid3/access.log';
my $squid_cache_dir = '/var/spool/squid3';
my $squid_def_fs    = 'ufs';
my $squid_def_port  = 3128;
my $squid_chain     = 'WEBPROXY_CONNTRACK';

# squidGuard globals
my $squidguard_conf          = '/etc/squid/squidGuard.conf';
my $squidguard_redirect_def  = "http://www.google.com";
my $squidguard_enabled       = 0;

# global hash of ipv4 addresses on the system
my %config_ipaddrs = ();


sub squid_enable_conntrack {
    system("iptables -t raw -L $squid_chain -n >& /dev/null");
    if ($? >> 8) {
	# chain does not exist yet. set up conntrack.
	system("iptables -t raw -N $squid_chain");
	system("iptables -t raw -A $squid_chain -j ACCEPT");
	system("iptables -t raw -I PREROUTING 1 -j $squid_chain");
	system("iptables -t raw -I OUTPUT     1 -j $squid_chain");
    }
}

sub squid_disable_conntrack {
    # remove the conntrack setup.
    my @lines
	= `iptables -t raw -L PREROUTING -vn --line-numbers | egrep ^[0-9]`;
    foreach (@lines) {
	my ($num, $ignore1, $ignore2, $chain, $ignore3, $ignore4, $in, $out,
	    $ignore5, $ignore6) = split /\s+/;
	if ($chain eq $squid_chain) {
	    system("iptables -t raw -D PREROUTING $num");
	    system("iptables -t raw -D OUTPUT $num");
	    system("iptables -t raw -F $squid_chain");
	    system("iptables -t raw -X $squid_chain");
	    last;
	}
    }
}

sub squid_get_constants {
    my $output;
    
    my $date = `date`; chomp $date;
    $output  = "#\n# autogenerated by vyatta-update-webproxy.pl on $date\n#\n";

    $output .= "acl manager proto cache_object\n";
    $output .= "acl localhost src 127.0.0.1/32\n";
    $output .= "acl to_localhost dst 127.0.0.0/8\n";
    $output .= "acl net src 0.0.0.0/0\n";
    $output .= "acl SSL_ports port 443\n";
    $output .= "acl Safe_ports port 80          # http\n";
    $output .= "acl Safe_ports port 21          # ftp\n";
    $output .= "acl Safe_ports port 443         # https\n";
    $output .= "acl Safe_ports port 70          # gopher\n";
    $output .= "acl Safe_ports port 210         # wais\n";
    $output .= "acl Safe_ports port 1025-65535  # unregistered ports\n";
    $output .= "acl Safe_ports port 280         # http-mgmt\n";
    $output .= "acl Safe_ports port 488         # gss-http\n";
    $output .= "acl Safe_ports port 591         # filemaker\n";
    $output .= "acl Safe_ports port 777         # multiling http\n";
    $output .= "acl CONNECT method CONNECT\n\n";
    
    $output .= "http_access allow manager localhost\n";
    $output .= "http_access deny manager\n";
    $output .= "http_access deny !Safe_ports\n";
    $output .= "http_access deny CONNECT !SSL_ports\n";
    $output .= "http_access allow localhost\n";
    $output .= "http_access allow net\n";
    $output .= "http_access deny all\n\n";

    system("touch $squid_log");
    system("chown proxy.adm $squid_log");

    return $output;
}

sub squid_validate_conf {
    my $config = new Vyatta::Config;

    #
    # Need to validate the config before issuing any iptables 
    # commands.
    #
    $config->setLevel("service webproxy");
    my $cache_size = $config->returnValue("cache-size");
    if (! defined $cache_size) {
	print "Must define cache-size\n";
	exit 1;
    }

    $config->setLevel("service webproxy listen-address");
    my @ipaddrs = $config->listNodes();
    if (scalar(@ipaddrs) <= 0) {
	print "Must define at least 1 listen-address\n";
	exit 1;
    }

    foreach my $ipaddr (@ipaddrs) {
	if (!defined $config_ipaddrs{$ipaddr}) {
	    print "listen-address [$ipaddr] is not a configured address\n";
	    exit 1;
	}
	# does it need to be primary ???
    }

    #check for nameserver
    if (system("grep -cq nameserver /etc/resolv.conf 2> /dev/null")) {
	print "Warning: webproxy may not work properly without a namserver\n";
    }
    return 0;
}

sub squid_get_values {
    my $output = '';
    my $config = new Vyatta::Config;

    $config->setLevel("service webproxy");
    my $o_def_port = $config->returnOrigValue("default-port");
    my $n_def_port = $config->returnValue("default-port");
    $o_def_port = $squid_def_port if ! defined $o_def_port;
    $n_def_port = $squid_def_port if ! defined $n_def_port;

    my $cache_size = $config->returnValue("cache-size");
    $cache_size = 100 if ! defined $cache_size;
    if ($cache_size > 0) {
	$output  = "cache_dir $squid_def_fs $squid_cache_dir ";
        $output .= "$cache_size 16 256\n";
    } else {
	# disable caching
	$output  = "cache_dir null $squid_cache_dir\n";
    }

    if ($config->exists("disable-access-log")) {
	$output .= "access_log none\n\n";
    } else {
	$output .= "access_log $squid_log squid\n\n";
    }

    # by default we'll disable the store log
    $output .= "cache_store_log none\n\n";

    my $num_nats = 0;
    $config->setLevel("service webproxy listen-address");
    my %ipaddrs_status = $config->listNodeStatus();
    my @ipaddrs = sort keys %ipaddrs_status;
    foreach my $ipaddr (@ipaddrs) {
	my $status = $ipaddrs_status{$ipaddr};
	#print "$ipaddr = [$status]\n";
	$status = "changed" if $n_def_port != $o_def_port and 
	                       $status eq "static";

	my $o_port = $config->returnOrigValue("$ipaddr port");	
	my $n_port = $config->returnValue("$ipaddr port");	
	$o_port = $o_def_port if ! defined $o_port;	
	$n_port = $n_def_port if ! defined $n_port;	

	my $o_dt = $config->existsOrig("$ipaddr disable-transparent");
	my $n_dt = $config->exists("$ipaddr disable-transparent");
	my $transparent = "transparent";
	$transparent = "" if $n_dt;
	if ($status ne "deleted") {
	    $num_nats++ if $transparent eq "transparent";
	    $output .= "http_port $ipaddr:$n_port $transparent\n";
	}

	my $intf = $config_ipaddrs{$ipaddr};

	#
	# handle NAT rule for transparent
	#
        my $A_or_D = undef;
	if ($status eq "added" and !defined $n_dt) {
	    $A_or_D = 'A';
	} elsif ($status eq "deleted" and !defined $o_dt) {
	    $A_or_D = 'D';
	} elsif ($status eq "changed") {
	    $o_dt = 0 if !defined $o_dt;
	    $n_dt = 0 if !defined $n_dt;
	    if ($o_dt ne $n_dt) {
		if ($n_dt) {
		    $A_or_D = 'D';
		} else {
		    $A_or_D = 'A';
		}
	    }
	    #
	    #handle port # change
	    #
	    if ($o_port ne $n_port and !$o_dt) {
		my $cmd = "sudo iptables -t nat -D PREROUTING -i $intf ";
		$cmd   .= "-p tcp --dport 80 -j REDIRECT --to-port $o_port";
		#print "[$cmd]\n";
		my $rc = system($cmd);
		if ($rc) {
		    print "Error removing port redirect [$!]\n";
		}		
		if (!$n_dt) {
		    $A_or_D = 'A';		    
	        } else {
		    $A_or_D = undef;
		}
	    }
	}
	if (defined $A_or_D) {
	    squid_enable_conntrack() if $A_or_D eq 'A';
	    my $cmd = "sudo iptables -t nat -$A_or_D PREROUTING -i $intf ";
	    $cmd   .= "-p tcp --dport 80 -j REDIRECT --to-port $n_port";
	    #print "[$cmd]\n";
	    my $rc = system($cmd);
	    if ($rc) {
		my $action = "adding";
		$action = "deleting" if $A_or_D eq 'D';
		print "Error $action port redirect [$!]\n";
	    }
	} 
    }
    $output .= "\n";

    squid_disable_conntrack() if $num_nats < 1;

    #
    # check if squidguard is configured
    #
    $config->setLevel("service webproxy url-filtering");
    if ($config->exists("squidguard")) {
	$squidguard_enabled = 1;
	$output .= "redirect_program /usr/bin/squidGuard -c $squidguard_conf\n";
	$output .= "redirect_children 8\n";
	$output .= "redirector_bypass on\n\n";
    }
    return $output;
}

sub squidguard_gen_cron {
    my ($old_int, $new_int) = @_;

    system("rm -rf /etc/cron.$old_int/squidGuard") if defined $old_int;
    return if ! defined $new_int;

    my $file = "/etc/cron.$new_int/squidGuard";
    my $date = `date`; chomp $date;
    my $output;
    $output  = "#!/bin/sh\n";
    $output .= "#\n# autogenerated by vyatta-update-webproxy.pl on $date\n#\n";
    $output .= "# cron job to automatically update the squidGuard blacklist\n";
    $output .= "#\n";
    $output .= "/opt/vyatta/bin/sudo-users/vyatta-sg-blacklist.pl ";
    $output .= " --auto-update-blacklist\n";

    webproxy_write_file($file, $output); 
    system("chmod 755 $file");
}

sub squidguard_validate_conf {
    my $config = new Vyatta::Config;
    my $path = "service webproxy url-filtering squidguard";

    $config->setLevel("service webproxy url-filtering");
    return 0 if ! $config->exists("squidguard");

    my $blacklist_installed = 1;
    if (!squidguard_is_blacklist_installed()) {
	print "Warning: no blacklists installed\n";
	$blacklist_installed = 0;
    }
    my @blacklists   = squidguard_get_blacklists();
    my %is_blacklist = map { $_ => 1 } @blacklists;

    $config->setLevel("$path block-category");
    my @block_category = $config->returnValues();
    my %is_block       = map { $_ => 1 } @block_category; 
    foreach my $category (@block_category) {
	if (! defined $is_blacklist{$category} and $category ne 'all') {
	    print "Unknown blacklist category [$category]\n";
	    exit 1;
	}
    }
    if (defined $is_block{all}) {
	if (!$blacklist_installed) {
	    print "Can't use block-category [all] without an installed ";
	    print "blacklist\n";
	    exit 1;
	}
	@block_category = ();
	foreach my $category (@blacklists) {
	    push @block_category, $category;
	}
    }

    my $db_dir = squidguard_get_blacklist_dir();
    foreach my $category (@block_category) {
	if (! defined $is_blacklist{$category}) {
	    print "Unknown blacklist category [$category]\n";
	    exit 1;
	}
	my ($domains, $urls, $exps) =
	    squidguard_get_blacklist_domains_urls_exps(
		$category);
	my $db_file = '';
	if (defined $domains) {
	    $db_file = "$db_dir/$domains.db";
	    if (! -e $db_file) {
		print "Missing DB for [$domains].\n";
		print "Try running \"update webproxy blacklists\"\n";
		exit 1;
	    }
	}
	if (defined $urls) {
	    $db_file = "$db_dir/$urls.db";
	    if (! -e $db_file) {
		print "Missing DB for [$urls].\n";
		print "Try running \"update webproxy blacklists\"\n";
		exit 1;
	    }
	}
	# is it needed for exps?
    }

    $config->setLevel("$path log");
    my @log_category = $config->returnValues();
    foreach my $log (@log_category) {
	if (! defined $is_blacklist{$log} and $log ne "all") {
	    print "Log [$log] is not a valid blacklist category\n";
	    exit 1;
	}
    }

    $config->setLevel($path);
    my $redirect_url = $config->returnValue("redirect-url");
    $redirect_url    = $squidguard_redirect_def if ! defined $redirect_url;
    if ($redirect_url !~ /^http:\/\/.*/) {
	print "Invalid redirect-url [$redirect_url]. ";
        print "Should start with \"http://\"\n";
	exit 1;
    }
    return 0;
}

sub squidguard_get_constants {
    my $output;
    my $date = `date`; chomp $date;
    $output  = "#\n# autogenerated by vyatta-update-webproxy.pl on $date\n#\n";

    $output  = "dbhome /var/lib/squidguard/db\n";
    $output .= "logdir /var/log/squid\n\n";

    return $output;
}

sub squidguard_generate_local {
    my ($action, @local_sites) = @_;

    my $db_dir       = squidguard_get_blacklist_dir();
    my $local_action = "local-$action";
    my $dir          = "$db_dir/$local_action";

    if (scalar(@local_sites) <= 0) {
	system("rm -rf $dir") if -d $dir;
	return "";
    }

    system("mkdir $dir") if ! -d $dir;
    my $file = "$dir/domains";
    open(my $FD, ">", $file) or die "unable to open $file $!";
    print $FD join("\n", @local_sites), "\n";
    close $FD;
    system("chown -R proxy.proxy $dir > /dev/null 2>&1");
    squidguard_generate_db(0, $local_action);
    return $local_action;
}

sub squidguard_get_values {
    my $output = "";
    my $config = new Vyatta::Config;

    my $path = "service webproxy url-filtering squidguard";

    $config->setLevel("$path local-ok");
    my @local_ok_sites = $config->returnValues();
    my $local_ok = squidguard_generate_local('ok', @local_ok_sites);
 
    $config->setLevel("$path local-block");
    my @local_block_sites = $config->returnValues();
    my $local_block       = squidguard_generate_local('block', 
						      @local_block_sites);

    $config->setLevel("$path block-category");
    my @block_category = $config->returnValues();
    my %is_block       = map { $_ => 1 } @block_category;    

    $config->setLevel("$path log");
    my @log_category = $config->returnValues();
    if (scalar(@log_category) > 0) {
	my $log_file = squidguard_get_blacklist_log();
	system("touch $log_file");
	system("chown proxy.adm $log_file");
    }
    my %is_logged    = map { $_ => 1 } @log_category;    

    my @blacklists   = squidguard_get_blacklists();
    my %is_blacklist = map { $_ => 1 } @blacklists;
    if (defined $is_block{all}) {
	@block_category = ();
	foreach my $category (@blacklists) {
	    next if $category eq "local-ok";
	    next if $category eq "local-block";
	    push @block_category, $category;
	}
    }

    if ($local_ok ne "") {
	$output .= squidguard_build_dest($local_ok, 0);
    }

    my $acl_block = "";
    foreach my $category ($local_block, @block_category) {
	next if $category eq "";
	my $logging = 0;
	if (defined $is_logged{all} or defined $is_logged{$category}) {
	    $logging = 1;
	}
	$output .= squidguard_build_dest($category, $logging);
	$acl_block .= "!$category ";
    }

    $output .= "acl {\n";
    $output .= "\tdefault {\n";
    $output .= "\t\tpass $local_ok !in-addr $acl_block all\n";

    $config->setLevel($path);
    my $redirect_url = $config->returnValue("redirect-url");
    $redirect_url    = $squidguard_redirect_def if ! defined $redirect_url;
    $output         .= "\t\tredirect 302:$redirect_url\n\t}\n}\n";

    # auto update
    $config->setLevel($path);
    my $old_auto_update = $config->returnOrigValue("auto-update");
    my $auto_update     = $config->returnValue("auto-update");
    squidguard_gen_cron($old_auto_update, $auto_update);

    return $output;
}


#
# main
#
my $update_webproxy;
my $stop_webproxy;

GetOptions("update!"           => \$update_webproxy,
           "stop!"             => \$stop_webproxy,
);

#
# make a hash of ipaddrs => interface
#
my @lines = `ip addr show | grep 'inet '`;
chomp @lines;
foreach my $line (@lines) {
    if ($line =~ /inet\s+([0-9.]+)\/.*\s(\w+)$/) {
	$config_ipaddrs{$1} = $2;
    }
}

if (defined $update_webproxy) { 
    my $config;

    squid_validate_conf();
    squidguard_validate_conf();
    $config  = squid_get_constants();
    $config .= squid_get_values();
    webproxy_write_file($squid_conf, $config);
    if ($squidguard_enabled) {
	my $config2;
	$config2  = squidguard_get_constants();
	$config2 .= squidguard_get_values();
	webproxy_write_file($squidguard_conf, $config2);
    }
    squid_restart(1);
}

if (defined $stop_webproxy) {
    #
    # Need to call squid_get_values() to delete the NAT rules
    #
    squid_get_values();
    system("rm -f $squid_conf $squidguard_conf");
    squid_stop();
}

exit 0;

# end of file
