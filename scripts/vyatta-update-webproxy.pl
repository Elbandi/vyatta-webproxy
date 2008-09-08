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

use lib "/opt/vyatta/share/perl5/";
use VyattaConfig;
use VyattaWebproxy;

use warnings;
use strict;

my $squid_conf      = '/etc/squid3/squid.conf';
my $squid_log       = '/var/log/squid3/access.log';
my $squid_cache_dir = '/var/spool/squid3';
my $squid_init      = '/etc/init.d/squid3';
my $squid_def_fs    = 'ufs';
my $squid_def_port  = 3128;

my $squidguard_conf          = '/etc/squid/squidGuard.conf';
my $squidguard_log           = '/var/log/squid';
my $squidguard_blacklist_log = "$squidguard_log/blacklist.log";

my $squidguard_redirect_def  = "http://www.google.com";
my $squidguard_enabled       = 0;

my %config_ipaddrs = ();


sub numerically { $a <=> $b; }

sub squid_restart {
    system("$squid_init restart");
}

sub squid_stop {
    system("$squid_init stop");
}

sub squid_get_constants {
    my $output;
    
    my $date = `date`; chomp $date;
    $output  = "#\n# autogenerated by vyatta-update-webproxy.pl on $date\n#\n";

    $output .= "access_log $squid_log squid\n\n";

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

    return $output;
}

sub squid_validate_conf {
    my $config = new VyattaConfig;

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

    $config->setLevel("service webproxy listening-address");
    my @ipaddrs = $config->listNodes();
    if (scalar(@ipaddrs) <= 0) {
	print "Must define at least 1 listening-address\n";
	exit 1;
    }

    foreach my $ipaddr (@ipaddrs) {
	if (!defined $config_ipaddrs{$ipaddr}) {
	    print "listing-address [$ipaddr] is not a configured address\n";
	    exit 1;
	}
    }
}

sub squid_get_values {
    my $output = '';
    my $config = new VyattaConfig;

    $config->setLevel("service webproxy");
    my $def_port = $config->returnValue("default-port");
    $def_port = $squid_def_port if ! defined $def_port;

    my $cache_size = $config->returnValue("cache-size");
    $cache_size = 100 if ! defined $cache_size;
    if ($cache_size > 0) {
	$output  = "cache_dir $squid_def_fs $squid_cache_dir ";
        $output .= "$cache_size 16 256\n\n";
    } else {
	# disable caching
	$output  = "cache_dir null /null\n\n";
    }

    $config->setLevel("service webproxy listening-address");
    my %ipaddrs_status = $config->listNodeStatus();
    my @ipaddrs = sort numerically keys %ipaddrs_status;
    foreach my $ipaddr (@ipaddrs) {
	my $status = $ipaddrs_status{$ipaddr};
	#print "$ipaddr = [$status]\n";

	my $o_port = $config->returnOrigValue("$ipaddr port");	
	my $n_port = $config->returnValue("$ipaddr port");	
	$o_port = $def_port if ! defined $o_port;	
	$n_port = $def_port if ! defined $n_port;	

	my $o_dt = $config->existsOrig("$ipaddr disable-transparent");
	my $n_dt = $config->exists("$ipaddr disable-transparent");
	my $transparent = "transparent";
	$transparent = "" if $n_dt;
	$output .= "http_port $ipaddr:$n_port $transparent\n";

	my $intf = $config_ipaddrs{$ipaddr};

	#
	# handle NAT rule for transparent
	#
        my $A_or_D = undef;
	if ($status eq "added" and !defined $n_dt) {
	    $A_or_D = 'A';
	} elsif ($status eq "deleted") {
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
		    print "Error adding port redirect [$!]\n";
		}		
		if (!$n_dt) {
		    $A_or_D = 'A';		    
	        } else {
		    $A_or_D = undef;
		}
	    }
	}
	if (defined $A_or_D) {
	    my $cmd = "sudo iptables -t nat -$A_or_D PREROUTING -i $intf ";
	    $cmd   .= "-p tcp --dport 80 -j REDIRECT --to-port $n_port";
	    #print "[$cmd]\n";
	    my $rc = system($cmd);
	    if ($rc) {
		print "Error adding port redirect [$!]\n";
	    }
	} 
    }
    $output .= "\n";

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

sub squidguard_get_constants {
    my $output;
    my $date = `date`; chomp $date;
    $output  = "#\n# autogenerated by vyatta-update-webproxy.pl on $date\n#\n";

    $output  = "dbhome /var/lib/squidguard/db\n";
    $output .= "logdir /var/log/squid\n\n";

    return $output;
}

sub squidguard_generate_block_site {
    my @block_sites = @_;

    my $db_dir = VyattaWebproxy::squidguard_get_blacklist_dir();
    my $block_site = 'block-site';
    my $dir = "$db_dir/$block_site";

    if (scalar(@block_sites) <= 0) {
	system("rm -rf $dir") if -d $dir;
	return undef;
    }

    system("mkdir $dir") if ! -d $dir;
    my $file = "$dir/domains";
    open(my $FD, ">", $file) or die "unable to open $file $!";
    print $FD join("\n", @block_sites), "\n";
    close $FD;
    return $block_site;
}

sub squidguard_get_values {
    my $output = "";
    my $config = new VyattaConfig;

    my $path = "service webproxy url-filtering squidguard";
 
    $config->setLevel("$path block-site");
    my @block_sites = $config->returnValues();
    squidguard_generate_block_site(@block_sites);

    $config->setLevel("$path allow-category");
    my @allow_category = $config->returnValues();

    $config->setLevel("$path log");
    my @log_category = $config->returnValues();
    my %is_logged    = map { $_ => 1 } @log_category;    

    my @blacklists = VyattaWebproxy::squidguard_get_blacklists();
    my %is_blacklist = map { $_ => 1 } @blacklists;
    if (scalar(@blacklists) <= 0) {
	print "Warning: no blacklists installed\n";
    }

    my $ok = "";
    if (scalar(@allow_category > 0)) {
	$output .= "dest ok {\n";
	foreach my $allow (@allow_category) {
	    if (! defined $is_blacklist{$allow}) {
		print "Unknown blacklist category [$allow]\n";
		exit 1;
	    }
	    my ($domains, $urls, $exps) = 
		VyattaWebproxy::squidguard_get_blacklist_domains_urls_exps(
		    $allow);
	    $output    .= "\tdomainlist     $domains\n" if defined $domains;
	    $output    .= "\turllist        $urls\n"    if defined $urls;
	    $output    .= "\texpressionlist $exps\n"    if defined $exps;
	}
	$output .= "}\n\n";
	$ok = "ok";
    }
    
    my $acl_block = "";
    foreach my $category (@blacklists) {
	if (! defined $is_blacklist{$category}) {
	    print "Unknown blacklist category [$category]\n";
	    exit 1;
	}
	my ($domains, $urls, $exps) =
	    VyattaWebproxy::squidguard_get_blacklist_domains_urls_exps(
		$category);
	$output    .= "dest $category {\n";
	$output    .= "\tdomainlist     $domains\n" if defined $domains;
	$output    .= "\turllist        $urls\n"    if defined $urls;
	$output    .= "\texpressionlist $exps\n"    if defined $exps;
	if (defined $is_logged{all} or defined $is_logged{$category}) {
	    $output    .= "\tlog            $squidguard_blacklist_log\n";
	}
	$output    .= "}\n\n";
	$acl_block .= "!$category ";
    }

    $output .= "acl {\n";
    $output .= "\tdefault {\n";
    $output .= "\t\tpass $ok !in-addr $acl_block all\n";

    $config->setLevel($path);
    my $redirect_url = $config->returnValue("redirect-url");
    $redirect_url = $squidguard_redirect_def if ! defined $redirect_url;

    $output .= "\t\tredirect 302:$redirect_url\n\t}\n}\n";

    return $output;
}

sub squidguard_update_blacklist {
    my @blacklists = VyattaWebproxy::squidguard_get_blacklists();

    if (scalar(@blacklists) <= 0) {
	print "No blacklists installed\n";
	exit 1;
    }
    my $db_dir = VyattaWebproxy::squidguard_get_blacklist_dir();
    system("chown -R proxy.proxy $db_dir > /dev/null 2>&1");
    system("chmod 2770 $db_dir >/dev/null 2>&1");

    #
    # generate temporary config
    #
    my $tmp_conf = "/tmp/sg.conf.$$";
    foreach my $category (@blacklists) {
	my $output;
	$output  = "dbhome $db_dir\n";
	$output .= "dest block {\n";
	my ($domains, $urls, $exps) =
	    VyattaWebproxy::squidguard_get_blacklist_domains_urls_exps(
		$category);
	$output .= "\tdomainlist     $domains\n" if defined $domains;
	$output .= "\turllist        $urls\n"    if defined $urls;
	$output .= "\texpressionlist $exps\n"    if defined $exps;
	$output .= "}\n\n";
	webproxy_write_file($tmp_conf, $output);
    
	foreach my $type ("domains", "urls") {
	    my $path = "$category/$type";
	    my $file = "$db_dir/$path";
	    if (-e $file) {
		my $file_db = "$file.db";
		if (! -e $file_db) {
		    #
		    # it appears that there is a bug in squidGuard that if
		    # the db file doesn't exist then running with -C leaves
		    # huge tmp files in /var/tmp.
		    #
		    system("touch $file.db");
		    system("chown -R proxy.proxy $file.db > /dev/null 2>&1");
		}
		my $wc = `cat $file| wc -l`; chomp $wc;
		print "Building DB for [$path] - $wc entries\n";
		my $cmd = "\"squidGuard -c $tmp_conf -C $path\"";
		system("su - proxy -c $cmd > /dev/null 2>&1");
	    }
	}
	system("rm $tmp_conf");
    }
}

sub webproxy_write_file {
    my ($file, $config) = @_;

    open(my $fh, '>', $file) || die "Couldn't open $file - $!";
    print $fh $config;
    close $fh;
}


#
# main
#
my $update_webproxy;
my $stop_webproxy;
my $update_blacklist;

GetOptions("update!"           => \$update_webproxy,
           "stop!"             => \$stop_webproxy,
	   "update-blacklist!" => \$update_blacklist,
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
    $config  = squid_get_constants();
    $config .= squid_get_values();
    webproxy_write_file($squid_conf, $config);
    if ($squidguard_enabled) {
	my $config2;
	$config2  = squidguard_get_constants();
	$config2 .= squidguard_get_values();
	webproxy_write_file($squidguard_conf, $config2);
    }
    squid_restart();
}

if (defined $stop_webproxy) {
    #
    # Need to call squid_get_values() to delete the NAT rules
    #
    squid_get_values();
    squid_stop();
}

if (defined $update_blacklist) {
    squidguard_update_blacklist();
    squid_restart();
}

exit 0;

# end of file
