#!/bin/ksh

#=============================================================================
#
# s-zone.sh
# ---------
#
# A script to help create, destroy, recreate, and manage zones Solaris
# servers. Usage is fairly complicated. The help command will help you.
#
# This script was originally written in the days before ZFS root, when it
# was wise to put zone roots on UFS. To get some ZFS benefit, the script
# would create non-core-FS filesystems under /zonedata/zone-name, which
# would be ZFS, and loopback mount those filesystems in the zone. By
# default, this approach is still followed, and the user can select the
# loopback filesystems to be created by selecting an install "class" or by
# using the -f option. If no class is selected, then no addititional
# filesystems will be created, and everything will end up installed under
# the zone root.
#
# R Fisher 11/09
#
# v2.0   Initial public release. RDF 30/09/2009
#
# v2.1   Better handling of /zonedata type zones. Support branded zones,
#        lx is tested on x86 b130 only for the Centos image on Sun's
#        website.  SUNWsolaris8 is tested on SPARC 5.10 for the Solaris 8
#        container image Sun supply. SUNWsolaris9 has been tested with a
#        minimal SPARC Solaris 9 build. Works on OpenSolaris 2009.03.
#        Added new "clone" command for simple zone cloning.
#
# v3.0	 Code tidy. Readied for public consumption. Much improvement of
#        cloning. Works properly on S10/SXCE/S11 Express. New "all" and
#        "list" commands.
#
# v3.1   -a option to create anet networked zones on Solaris 11
#
# v3.1.1 Understands more software. Minor bugfixes. New "help" system.
#
#=============================================================================

#-----------------------------------------------------------------------------
# VARIABLES

MY_VER="3.1.1"
	# Version of script. KEEP UPDATED!

PATH=/usr/bin:/usr/sbin
	# Always set your PATH

TIMEZONE="${TZ:-Europe/London}"
	# The default timezone for installed zones. Change this if you like.
	# Defaults to the value of $TZ, if it is set

TIMEZONE_S8="GB"
	# Timezone names have changed over the years. Use this to override the
	# default value for branded zones

TIMEZONE_S11="GB"
	# Timezone names have changed again in Solaris 11. Along with everything
	# else.

ZONEROOT="/zones"
	# Where the zones go

DATAROOT="/zonedata"
	# Where zone loopback fses are mounted in the global zone

ZOS_QUOTA="8G"
	# A quota size for zone root filesystems on ZFS. Must be in the
	# standard "zfs set quota" format. Comment it out if you don't want to
	# set quotas

TMPFILE=$(mktemp -t)
	# Just a temp file. I hate temp files, but in this case it's
	# unavoidable. We use it to build the zone config file

ARC_DIR="/var/zones"
	# Where we archive zone config files

ZSCR="/etc/rc3.d/S01zone_config.sh"
	# A script we can write to to perform more customization on first
	# reboot.

DR_SCR="/usr/local/bin/s-dr.sh"
	# The location of the DR recovery script needed to recreate zones

DR_DIR="/var/snltd/s-dr"
	# Default location for DR data

ROOT_PASSWORD="gasZQVaMqMbTA"
	# encrypted root password (plaintext is 'zoneroot')

# Classes currently define filesystem lists. Theoretically they could also
# contain other things.

CLASSES="
plain:FSLIST:/usr/local=local
apache:FSLIST:/usr/local=local,/www=www,/var/apache/logs=logs
appserv:FSLIST:/usr/local=local,/www=www,/var/apache/logs=logs,/data=data
dns:FSLIST:/usr/local=local,/var/log/named=logs,/var/named=named
db:FSLIST:/usr/local=local,/data=data,/home=/export/home,/config=config
iplanet:FSLIST:/opt=opt,/www=www,/usr/local=local
mail:FSLIST:/usr/local=local,/var/log/exim=logs
snltd:FSLIST:/config=config,/home=/export/home
oracle:FSLIST:/u01=u01,/u02=u02,/usr/local=local,/opt=opt
"

# Files to copy from the global zone to the local zone. Not done for lx
# zones. We copy fewer files for Solaris 11 because the DNS config is done
# at zone creation time

FILELIST_S11="etc/passwd \
	etc/shadow \
	etc/group \
	etc/auto_home \
	etc/syslog.conf \
	etc/ssh/sshd_config \
	etc/default/inetinit \
	etc/default/syslogd \
	etc/default/login \
	etc/security/policy.conf"

FILELIST="$FILELIST_S11 \
	etc/nsswitch.conf \
	etc/resolv.conf"

# Empty files created in new zones. Again, not done for lx zones

TOUCHLIST="var/adm/loginlog \
	var/log/authlog \
	var/log/sshd.log"

ERRLOG=$(mktemp -t)
	# Error log for zoneadm install

#-----------------------------------------------------------------------------
# FUNCTIONS

function die
{
	# print an error message and exit
	# $1 is the message
	# $2 is the exit code

	print -u2 "ERROR: $1"

	if [[ -s $ERRLOG ]]
	then
		print "\nDUMPING ERROR LOG"
		cat $ERRLOG
	fi >&2

	rm -f $TMPFILE $ERRLOG
	exit ${2:-1}
}

usage()
{
	cat <<-EOH
	usage: ${0##*/} <command> [options]

	commands are:
	create, recreate, clone remove, all, list, version, help

	'${0##*/} help <command>' for more information.
	EOH
    exit 2
}

usage_further()
{
    case $1 in

        create)
            cat<<-EOH
	  ${0##*/} create <-i|-e|-a addr> [-F fslist] [-c class] [-wFp] <zone>

	  ${0##*/} create <-b brand> <-I image> [-t type] <-i|-e addr>
	            [-v nic=vnic] [-Ffslist] [-c class] [-Fp] <zone>

	  -w, --whole        create a whole-root zone
	  -v, --vnic         create VNIC on physical NIC (nic=vnic)
	  -i, --iflist       shared interface list
	                     if1=addr1;route,if2=addr2;route,...,ifn=addrn;route
	                     route is optional
	  -e, --exclusive    exclusive interface list
	                     if1=addr1,if2=addr2,...,ifn=addrn
	  -a, --anet         automatic interface list (Solaris 11 only)
	                     if1=addr1,if2=addr2,...,ifn=addrn
	  -f, --fslist       filesystem list
	                     dir1=special1,dir2=special2...
	                     where dir is the local zone mountpoint and
	                     special is the global zone mountpoint
	                     unqualified specials are relative to /zonedata/zone
	  -c, --class        class of zone. Available classes are:
$(for class in $CLASSES
do
	print $class | sed 's/^\([^:]*\).*$/                          - \1/'
done)
	  -F, --force        if zone exists, remove it and re-create
	  -p, --prefix       prefix the zone name with "$(uname -n)z-"
	  -R, --rset         parent ZFS dataset of the zone root. If not
	                     supplied uses the root pool
	  -D, --dset         ZFS dataset under which to create additional
	                     loopback filesystems. If not supplied, uses the
	                     value given by -R
	  -n, --nocopy       do not copy files like passwd, resolv.conf,
	                     syslog.conf etc. to the global zone
	  -b, --brand        install a zone of the specified brand. May be
	                     'lx', 's8', 's9', or 's10'. (Linux, Solaris 8, 9
	                     and 10). Requires an install image to be
	                     supplied with -I option
	  -I, --image        full path to install image for branded zones
	  -t, --type         for lx branded zones, the type of install. One
	                     of "server", "desktop", "developer" or "all"
			EOH
			;;

         recreate)
			cat<<-EOH

	  ${0##*/} recreate [-wsF] [ -d directory] <zone>

	  -d, --dir          directory in which to find DR information
	  -F, --force        if zone exists, remove it and re-create
	  -s, --sparse       Recreate zone as sparse-root
	  -w, --whole        Recreate zone as whole-root
			EOH
			;;

         destroy)
			cat<<-EOH
	  ${0##*/} remove|destroy [-f] [-k|z] <zone> zone ... zone

	  -F, --force        force removal of zones (non-interactive)
	  -a, --all          remove the zone's root, if on ZFS, AND
	                     additional ZFS filesystems. By default, these
	                     are kept, but the zone's O/S files are removed
	                     (cannot be used in conjunction with -n)
	  -n, --nofs         don't destroy any zone filesystems or remove any
	                     files which are not removed by the 'zoneadm
	                     uninstall' command
	                     (cannot be used in conjunction with -a)
			EOH
            ;;

         clone)
			cat <<-EOH
	  ${0##*/} clone [-Ff] <-i|-e addr> -s<zone> <zone>

	  -F, --force        force removal of existing zone
	  -f, --fs           create new /zonedata filesystems for target zone
	  -i, --iflist       shared interface list
	  -e, --exclusive    exclusive interface list
	  -s, --source       source zone
			EOH
			;;

        all)
	        print "${0##*/} all <halt|reboot|shutdown|boot|run>"
            ;;

        list)
	        print "${0##*/} list <classes|files>"
            ;;

        *)	usage
            ;;

    esac
	exit 2
}

function rm_zone_if_exists
{
	# Check to see if a zone already exists. CAN EXIT!
	# $1 is the zone to check

	if get_zone_state $1 >/dev/null
	then

		[[ -n $FORCE ]] && remove_zone $1 || die \
			"zone '$1' already exists. To destroy and re-create it, use -F"
	fi
}

function check_zpool
{
	# Get the zpool that filesystems will belong to. Used to check options.
	# Prints out a valid pool name, or "ufs", or "err".

	# $1 is the mountpoint
	# $2 is the pool name

	# If we've been given a pool name, simply check it exists. If not, look
	# at the given mountpoint, and see if it belongs to a pool. If it does,
	# that's the pool name we return. If not, we return "ufs"

	typeset pool

	if [[ -n $2 ]]
	then
		pool=$(zfs list -H -o name $2 2>/dev/null | sed 's|/.*$||')
		[[ -z $pool ]] && pool="err"
	elif df -n $1 | egrep -s ": zfs"
	then
		pool=$(df -h $1 | sed '1d;s/\/.*$//')
	else
		pool="ufs"
	fi

	print $pool
}

function check_ip_addr
{
	# Check an IP address looks roughly valid and does not ping
	# $1 is the address

	# Make sure we've only got numbers and dots, then ping the address to
	# make sure it's free.

	print $1 | egrep -s "[^0-9.]" && ret=1

	print $1 | tr . "\n" | while read oct
	do
		(( $oct < 0 || $oct > 255 )) && ret=1
	done 2>/dev/null

	[[ -n $ret ]] && print "    $1 is not a valid ethernet address."

	if ping $1 1 >/dev/null 2>&1
	then
		print "    got response when pinging ${1}."
		ret=1
	fi

	return $ret
}

function get_netmask
{
	# Get the netmask the zone will use. Query /etc/netmasks first

	# $1 is the physical interface

	if [[ -f /etc/netmasks ]]
	then
		grep "^${1%.*}.0" /etc/netmasks | read net mask
	fi

	if [[ -n $mask ]]
	then
		NETMASK=$mask
		print "  netmask is ${NETMASK}."
	else
		NETMASK="255.255.255.0"
		print "  netmask not found. Defaulting to ${NETMASK}."
	fi

}

function get_zone_state
{
	# Get the state of the given zone
	# $1 is the zone

	zs=$(zoneadm -z $1 list -p | cut -d: -f3 2>/dev/null)

	if [[ -n $zs ]]
	then
		print $zs
		return 0
	else
		return 1
	fi

}

function remove_zone
{
	# remove the given zone, completely. Doesn't remove any filesystems:
	# that's what remove_zfs is for

	# $1 is the zone to remove

	# We have to halt, uninstall, and delete, in that order. But, we can't
	# be sure what state the zone is in.

	if get_zone_state $1 >/dev/null
	then
		zstate=$(get_zone_state $1)
		print "Removing ${1}:"

		if [[ $zstate == "running" ]]
		then
			print -n "  halting: "
			zoneadm -z $1 halt && print "ok" || die "failed"
			sleep 1
			zstate=$(get_zone_state $1)
		fi

		if [[ $zstate == "installed" || $zstate == "incomplete" ]]
		then
			print -n "  uninstalling: "
			zoneadm -z $1 uninstall -F >/dev/null 2>&1 \
				&& print "ok" || die "failed"
		fi

		print -n "  deleting: "
		zonecfg -z $1 delete -F && print "ok" || die "failed"
	else
		print "Zone $1 does not exist."
	fi

}

function zone_wait
{
	# Wait for a zone to be fully booted. We do this by looking for the
	# presence of the ttymon process. Put the sleep inside the loop so it
	# gets a second extra to sort itself out once it's seen to be up

	# $1 is the zone to monitor

	print -n "  waiting for $1 to be fully up: "

	while ! ps -z $1 | egrep -s ttymon
	do
		sleep 1
	done

	print "ok"
}

function zone_boot
{
	# Wrapper to boot a zone and say we're doing it
	# $1 is the zone

	print "\nBooting $1"
    print "#----zone_boot()" >>$ERRLOG

	zoneadm -z $1 boot >>$ERRLOG 2>&1\
		&& print "  boot process begun" || die "boot failed"

}

function configure_zone
{
	# Wrapper to zonecfg. Run it, and archive off the config file

	# $1 is the name of the zone
	# $2 is the name of the config file

	print "\nConfigure Zone"

	if zonecfg -z $1 -f $2
	then
		print "  zone is configured"
		[[ -d $ARC_DIR ]] || mkdir -p $ARC_DIR
		mv $2 "${ARC_DIR}/${1}.cfg"
		print $INV_CMD >"${ARC_DIR}/${1}.cmd"
	else
        print "#---- zone config file follows" >>$ERRLOG
		cat $TMPFILE >>$ERRLOG
		die "Exiting."
	fi
}

function install_zone_lx
{
	# Install an lx branded zone
	# $1 is the zone

	print -n "\nInstalling zone: "
    print "#----install_zone_lx()" >>$ERRLOG

	zoneadm -z $1 install -d $INST_IMG $LX_TYPE >/dev/null 2>$ERRLOG \
		&& print "ok" \
		|| die "failed to install zone"
}

function install_zone
{
	# Install a zone and a load of files which belong to it. Used in
	# creation and recreation

	# $1 is the zone
	# $2 is the zone root
	# $SYSIDBLOCK may be defined before calling

	print "\nInstalling zone"

	if [[ -n $S11 ]]
	then
		SCI=$(mktemp)_sci.xml
		print "  generating enable_sci.xml at $SCI"

		cat <<-EOSCI >$SCI
		<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
		<service_bundle type="profile" name="sysconfig">
  		<service version="1" type="service" name="system/config-user">
    		<instance enabled="true" name="default">
      		<property_group type="application" name="root_account">
        		<propval type="astring" name="login" value="root"/>
        		<propval type="astring" name="password" value="$ROOT_PASSWORD"/>
        		<propval type="astring" name="type" value="normal"/>
      		</property_group>
    		</instance>
  		</service>

  		<service version="1" type="service" name="system/timezone">
    		<instance enabled="true" name="default">
      		<property_group type="application" name="timezone">
        		<propval type="astring" name="localtime" value="$TIMEZONE_S11"/>
      		</property_group>
    		</instance>
  		</service>
  		<service version="1" type="service" name="system/environment">
    		<instance enabled="true" name="init">
      		<property_group type="application" name="environment">
        		<propval type="astring" name="LANG" value="C"/>
      		</property_group>
    		</instance>
  		</service>
  		<service version="1" type="service" name="system/identity">
    		<instance enabled="true" name="node">
      		<property_group type="application" name="config">
        		<propval type="astring" name="nodename" value="$1"/>
      		</property_group>
    		</instance>
  		</service>
  		<service version="1" type="service" name="system/keymap">
    		<instance enabled="true" name="default">
      		<property_group type="system" name="keymap">
        		<propval type="astring" name="layout" value="UK-English"/>
      		</property_group>
    		</instance>
  		</service>
  		<service version="1" type="service" name="system/console-login">
    		<instance enabled="true" name="default">
      		<property_group type="application" name="ttymon">
        		<propval type="astring" name="terminal_type" value="sun-color"/>
      		</property_group>
    		</instance>
  		</service>
  		<service version="1" type="service" name="network/physical">
    		<instance enabled="true" name="default">
      		<property_group type="application" name="netcfg">
        		<propval type="astring" name="active_ncp" value="DefaultFixed"/>
      		</property_group>
    		</instance>
  		</service>

  		<service version="1" type="service" name="network/install">
    		<instance enabled="true" name="default">
      		<property_group type="application" name="install_ipv4_interface">
        		<propval type="astring" name="address_type" value="static"/>
        		<propval type="net_address_v4" name="static_address"
				value="${S11_IP_ADDR}/${S11_IP_NETMASK}"/>
        		<propval type="astring" name="name" value="${S11_IP_PHYS}/v4"/>
      		</property_group>
    		</instance>
  		</service>
		EOSCI

# default route and IPV6 stuff. Goes under the propval S11_IP_PHYS line
#<propval type="net_address_v4" name="default_route" value="192.168.1.1"/>
#</property_group>
#<property_group type="application" name="install_ipv6_interface">
#<propval type="astring" name="stateful" value="yes"/>
#<propval type="astring" name="stateless" value="yes"/>
#<propval type="astring" name="address_type" value="addrconf"/>
#<propval type="astring" name="name" value="atge0/v6"/>

		# DNS stuff - just copy whatever the global zone is using

		nameservers=$(svcprop -p config/nameserver dns/client)
		search=$(svcprop -p config/search dns/client)

		if [[ -n $nameservers ]]
		then
			cat <<-EOSCI >>$SCI
  			<service version="1" type="service" name="system/name-service/switch">
    			<property_group type="application" name="config">
      			<propval type="astring" name="default" value="files"/>
      			<propval type="astring" name="host" value="files dns"/>
      			<propval type="astring" name="printer" value="user files"/>
    			</property_group>
			    <instance enabled="true" name="default"/>
  			</service>
  			<service version="1" type="service" name="system/name-service/cache">
    			<instance enabled="true" name="default"/>
  			</service>
  			<service version="1" type="service" name="network/dns/client">
    			<property_group type="application" name="config">
      			<property type="net_address" name="nameserver">
        			<net_address_list>
			EOSCI

			for ns in $nameservers
			do
          		print "			<value_node value=\"$ns\"/>"
			done >>$SCI

        	print "</net_address_list></property>" >>$SCI

			if [[ -n $search ]]
			then
				print '<property type="astring" name="search"><astring_list>'

				for val in $search
				do
          			print "<value_node value=\"$val\"/>"
				done

        		print "</astring_list></property>"
			fi >>$SCI

    		print "</property_group>" >>$SCI
		fi

		cat <<-EOSCI >>$SCI
			<instance enabled="true" name="default"/>
			</service>
			</service_bundle>
		EOSCI

		ADMX="-c $SCI"
	else
		print "  generating sysidcfg"

		if [[ -z $SYSIDBLOCK ]]
		then
			SYSIDBLOCK="network_interface=PRIMARY {
			hostname=$1
			netmask=$NETMASK
			protocol_ipv6=no
			default_route=none
			}
			"
		fi

	fi

	# We need to run zoneadm with different args depending on what we're
	# doing

	if [[ -n $BRAND ]]
	then
		ZARGS="install $ADMX -s -u -a $INST_IMG"
	elif [[ x$MODE == xclone ]]
	then
	    ZARGS="clone $ADMX $SRC_ZONE"
	else
		ZARGS="install $ADMX"
	fi

	# Now run it, and report success, or bail out

	print "  running 'zoneadm -z $1 ${ZARGS}'\n  logging to $ERRLOG"

	eval zoneadm -z $1 "$ZARGS" >$ERRLOG 2>&1 \
		&& print "  zone installed" \
		|| die "failed to install zone"

	# Drop in a sysidcfg file

	if [[ -z $S11 ]]
	then
		print "  installing sysidcfg"

		cat <<-EOSYSIDCFG >${2}/root/etc/sysidcfg
			system_locale=C
			terminal=xterm
			$SYSIDBLOCK
			timeserver=localhost
			security_policy=NONE
			name_service=NONE
			timezone=$TIMEZONE
			root_password=$ROOT_PASSWORD
		EOSYSIDCFG

	fi

	# Choose the default NFSv4 domain for Solaris 10+

	if [[ x$BRAND != "xs9" && x$BRAND  != "xs8" ]]
	then
		print "nfs4_domain=default" >>${2}/root/etc/sysidcfg
		touch ${2}/root/etc/.NFS4inst_state.domain
	fi
}

function make_zfs
{
	# Make a ZFS filesystem, and set its mountpoint.  Do the create and set
	# mountpoint separately. This corrects any existing, but unmounted or
	# wrongly mounted, filesystems

	# $1 is the name of the filesystem
	# $2 is the mountpoint

	typeset RET MPT

	# Does the parent exist? Watch the recursion!

	zfs list ${1%/*} >/dev/null 2>&1 || make_zfs ${1%/*} "none"

	if zfs list $1 >/dev/null 2>&1
	then
		print "    dataset '${1}' already exists"
	else
		print -n "    creating ZFS dataset '${1}': "

		if zfs create $1
		then
			print "created"
		else
			print "failed"
			return 1
		fi

	fi

	# Set the mountpoint. Do this in a separate stage because I don't think
	# you could use create -o with early versions of ZFS could you?

	MPT=$(zfs get -Ho value mountpoint $1)

	if [[ $MPT == $2 ]]
	then
		print "    mountpoint already correct"
	else
		print -n "    setting mountpoint to '$2': "

		if zfs set mountpoint=$2 $1
		then
			print "ok"
		else
			print "failed"
			return 1
		fi

	fi

}

function remove_zfs
{
	# Wrapper to cleanly and kindly remove a ZFS filesystem and all its
	# snapshots

	# $1 is the dataset name

	if zfs list $1 >/dev/null 2>&1
	then
		MPT=$(zfs get -Ho value mountpoint $1)
		print "  removing $1 (${MPT})"
		zfs destroy -r $1
		rmdir -ps $MPT
	fi
}

function customize_zone_lx
{
	# Customize Linux zones
	# $1 is the zone
	# $2 is the zone root
	# $3 is the root of the filesystem to copy files from
	# $FILELIST may be defined before calling

	:
}

function customize_zone
{
	# Customize Solaris zones
	# $1 is the zone
	# $2 is the zone root
	# $3 is the root of the filesystem to copy files from
	# $FILELIST may be defined before calling

	ZROOT=$2
	MINIROOT="${3%/}"

	# Copy some files from the global zone to the local zone.

	print "  installing files:"

	for file in $FILELIST
	do
		cfile="${MINIROOT}/$file"
		print -n "    $cfile "

		if [[ -f $cfile ]]
		then
			cp -p $cfile ${ZROOT}/root/$file \
			&& print "copied" || print "copy failed"
		else
			print "no file in miniroot [$MINIROOT]"
			touch ${ZROOT}/root/$file
		fi

	done

	for file in $TOUCHLIST
	do
		cfile="${MINIROOT}/$file"
		print -n "    $cfile "
		touch ${ZROOT}/root/$file \
		&& print "created" || print "FAILED TO CREATE"
	done

	# There's quite a bit of stuff you can't do at first configuration. So,
	# we'll create a horrible little script that sits in rc3.d (SMF really
	# would be overkill here!) does some stuff, removes itself, and reboots
	# the zone.

	cat <<-EOSCR > ${ZROOT}/root/$ZSCR
		#!/bin/sh

		PATH=/bin:/usr/sbin
		NSS=/etc/nsswitch.conf
		NFS=/etc/default/nfs

		if [ -x /usr/sbin/svccfg ]
		then
			svccfg apply /var/svc/profile/generic_limited_net.xml
			svcadm disable name-service-cache
		fi

		if [ -f \$NFS ]
		then
			cp \$NFS \${NFS}.tmp
			sed 's/^NFSMAPID_DOMAIN.*/#&/' \${NFS}.tmp > \$NFS
		fi

		cp \$NSS \${NSS}.tmp
		sed 's/^hosts:.*files/& dns/' \${NSS}.tmp > \$NSS

		$POST_EXTRA

	 	rm -f \${NFS}.tmp \${NSS}.tmp \$0
		reboot
	EOSCR

	chmod 744 ${ZROOT}/root/$ZSCR
}

function print_zfs_rm_list
{
	# Print a list of filesystems which will be destroyed in remove mode

	print "The following ZFS filesystems will be destroyed:"

	for fs in $*
	do
		print "  $fs"
	done

}

function get_s11_network_data
{
	# Writes globals. This script needs a serious working over
	# $1 is IFLIST

	# Solaris 11 can only configure the primary network interface through
	# the enable_sci.xml file. Don't like it? Take it up with Oracle, and
	# good luck with that.

	if [[ -n $S11 && $1 == *,* ]]
	then
		print "  WARNING: Solaris 11 only supports configuration of one NIC"
		IFLIST=${1%%,*}
	fi

	print $1 | sed "s/[=;]/ /g" | read S11_IP_PHYS S11_IP_ADDR S11_IP_DEFRT

	S11_IP_NETMASK="24"
}

#-----------------------------------------------------------------------------
# SCRIPT STARTS HERE

# If we've been asked to print the version, do that right now and quit

if [[ $1 == "-V" || $1 == "--version" || $1 == "version" ]]
then
	print $MY_VER
	exit 0
fi

# Solaris 11? That's different

[[ $(uname -v) == 11* ]] && S11=true

# Store the script's arguments and options

INV_CMD="$0 $*"

# Basic checks before we do anything. We need to be root, in the global zone
# of a system which knows about zones, unless it's help or something.

if [[ $1 != "list" && $1 != "help" ]]
then
	whence zoneadm >/dev/null || die "This system does not support zones."

	id | egrep -s "uid=0" || die "script can only be run by root."

	[[ $(zonename) == "global" ]] \
		|| die "This script can only be run from the global zone."
fi

(( $# == 0 )) && usage

# Get the mode keyword (the first argument), then chop it off the arglist

MODE=$1
shift $(( $OPTIND ))

# All commands need an argument.

(( $# < 1 )) && usage_further $MODE

# The rest of the script is divided into blocks. One each for
# each command keyword.

#-- ZONE CREATION ------------------------------------------------------------

if [[ x$MODE == xcreate ]]
then

	while getopts \
        "a:(anet)b:(brand)c:(class)d:(default)v:(vnic)e:(exclusive)F(force)f:(fslist)i:(iflist)I:(image)n(nocopy)pt:(type)wzR:(rpool)D:(dpool)" option 2>/dev/null
	do
		case $option in

            a)  AIFLIST=$OPTARG
                ;;

			b)	BRAND=$OPTARG
				;;

			c)	CLASS=$OPTARG
				;;

			D)	DPOOL=$OPTARG
				;;

			e)	EIFLIST=$OPTARG
				;;

			f)	FSLIST=$OPTARG
				;;

			F)	FORCE=true
				;;

			i)	SIFLIST=$OPTARG
				;;

			I)	INST_IMG=$OPTARG
				;;

			n)	NOCOPY=true
				;;

			p)	PREFIX=$(uname -n)
				;;

			R)	RPOOL=$OPTARG
				;;

			t)	LX_TYPE=$OPTARG
				;;

			v)	VNIC=$OPTARG
				;;

			w)	CREATE_FLAGS="-b"
				;;

			*)	usage_further $MODE
				;;
		esac

	done

	shift $(($OPTIND - 1))

	[[ $# == 1  ]] || die "no zone name supplied."

	[[ -n $PREFIX ]] && zone="${PREFIX}z-$1" || zone=$1

	# Basic checks. Is it worth carrying on? Branded zones need an install
	# image

	[[ -n $INST_IMG && ! -f $INST_IMG ]] \
		&& die "Install image does not exist. [$INST_IMG]"

	# Issue a warning if we don't have FSS scheduler. zoneadm boot would
	# normally do this, but we silence it

	dispadmin -d 2>/dev/null | egrep -s FSS \
		|| print "WARNING: set default scheduler to FSS"

    [[ -n $AIFLIST && -z $S11 ]] \
        && die "automatic interfaces are only supported in Solaris 11"

	# Either exclusive, shared, or automatic interfaces - not more than
    # one

    ifcount=0

    for iflist in $AIFLIST $EIFLIST $SIFLIST
    do
        ((ifcount = $ifcount + 1))
        IFLIST=$iflist
    done

    (( $ifcount > 1 )) && die "-a, -i and -e are exclusive"

	[[ -z $IFLIST ]] && die "no network interfaces defined"

	# To use shared IP on Solaris 11 you need to specify an alternate
	# template. We also use a different FILELIST

	if [[ -n $S11 ]]
	then
		FILELIST=$FILELIST_S11
		[[ -n $IFLIST ]] && CREATE_FLAGS="-t SYSdefault-shared-ip"
	fi

	# Check the zone root exists

	[[ -d $ZONEROOT ]] || die "Zone root does not exist. [${ZONEROOT}]"

	# If we've been given a -f or -c option, we're using the old-skool
	# DATAROOT for loopback fileasystems

	if [[ -n ${FSLIST}$CLASS ]]
	then

		[[ -d $DATAROOT ]] \
			|| die "Zone data root does not exist. [${DATAROOT}]"

		if [[ -n $DPOOL ]]
		then
			zfs list $DPOOL >/dev/null 2>&1 \
				|| die "invalid parent dataset for zone data [${DPOOL}]."
		else
			# If we haven't been given a pool, use whatever DATAROOT is,
			# even if it's UFS

			df -b $DATAROOT | sed 1d | read pool b

			[[ $pool == "/"* ]] && UFSDATA=1 || DPOOL=$pool
		fi

	fi

	# If we've been given ZFS parent dataset for RPOOL, make sure it exists.
	# If not, look to see what ZONEROOT is in and work from there. If it's
	# ZFS, its pool is RPOOL, if it's UFS, fine

	if [[ -n $RPOOL ]]
	then
		zfs list $RPOOL >/dev/null 2>&1 \
			|| die "invalid parent dataset for zone root [${RPOOL}]."

	else
		# We haven't been given a root
		df -b $ZONEROOT | sed 1d | read pool b

		[[ $pool == "/"* ]] && UFSROOT=1 || RPOOL=$pool

	fi

	# Does the zone already exist?. If it does, remove it if -F has been
	# supplied. If not, stop

	rm_zone_if_exists $zone

	# Functions to install and customize zones. Can be overriden per-brand

	INSTALL_ZONE="install_zone"
	CUSTOMIZE_ZONE="customize_zone"

	# Brand stuff

	if [[ -n $BRAND ]]
	then
		# Don't copy files with branded zones. It's not safe to assume
		# that's a sensible thing to do.

		NOCOPY=true

		[[ -n $INST_IMG ]] \
			|| die "Branded zones require an install image. (-I)"

		if [[ $BRAND == "lx" ]]
		then
			pkginfo SUNWlxr SUNWlxu >/dev/null 2>&1 \
				|| die "System does not support lx brand."

			CREATE_FLAGS="-t SUNWlx"

			# For linux zones we can select an install type, one of "core",
			# "server", "desktop", "developer" or "all". The user can choose
			# it with the -t option, but if they haven't, fall back to
			# "core". You don't want more linux than is strictly necessary.

			if [[ -z $LX_TYPE ]]
			then
				print \
				"WARNING: no image type selected. Defaulting to 'core'."
				LX_TYPE="core"
			fi

			# LX branded zones have their own install and customize
			# functions

			INSTALL_ZONE="install_zone_lx"
			CUSTOMIZE_ZONE="customize_zone_lx"
		elif [[ $BRAND == "s8" ]]
		then
			pkginfo SUNWs8brandr SUNWs8brandu >/dev/null 2>&1 \
				|| die "System does not support solaris8 brand."

			CREATE_FLAGS="-t SUNWsolaris8"
			EXTRA_ZONECFG='add attr
				set name=machine
				set type=string
				set value=sun4u
				end'
			TIMEZONE=$TIMEZONE_S8
		elif [[ $BRAND == "s9" ]]
		then

			pkginfo SUNWs9brandr SUNWs9brandu >/dev/null 2>&1 \
				|| die "System does not support solaris9 brand."

			CREATE_FLAGS="-t SUNWsolaris9"
		elif [[ $BRAND == "s10" ]]
		then

			# Does the system support solaris10?

			if [[ -f /bin/pkg ]]
			then
				pkg list system/zones/brand/brand-solaris10 >/dev/null 2>&1 \
					|| NZ=1
			else
				pkginfo SUNWs10brandr SUNWs10brandu >/dev/null 2>&1 \
					|| NZ=1
			fi

			[[ -n $NZ ]] && die "System does not support solaris10 brand."

			if [[ -n $S11 ]]
			then
				[[ -n $SIFLIST ]] \
					&& die "solaris10 branded zones must use exclusive IP"

				CREATE_FLAGS="-t SYSsolaris10"
				unset S11
			else
				[[ -n $EIFLIST ]] \
					&& die "solaris10 branded zones must use shared IP"
				CREATE_FLAGS="-t SUNWsolaris10"
			fi

		else
			 die "Unsupported brand. [${BRAND}]"
		fi

	fi

	tput bold
	print "\nCreating zone '${zone}'"
	tput sgr0

	# If we have to make a VNIC, do that now. Solaris 10 can't do this,
    # so fail gracefully.

	if [[ -n $VNIC ]]
	then
		vnic=${VNIC#*=}
		pnic=${VNIC%=*}

        [[ -z $vnic || -z $pnic || $vnic == $pnic ]] \
            && die "incorrect VNIC specification"

		print -n "  creating VNIC '$vnic' on link '$pnic': "

		if dladm help 2>&1 | egrep -s "create-vnic"
		then

			if dladm show-link $vnic >/dev/null 2>&1
			then
				print "already exists"
			else
				dladm create-vnic -l $pnic $vnic && print "ok" || die "failed"
			fi

		else
			die "host does not support VNICs"
		fi

	fi

	[[ -n $BRAND ]] && print "  brand is '${BRAND}'"

	# Start creating the zone config file. It's the TEMPFILE

	ZROOT=${ZONEROOT}/$zone

	cat <<-EOZ >$TMPFILE
		create $CREATE_FLAGS
		set zonepath=$ZROOT
		set autoboot=true
	EOZ

	# Solaris 10 assumes shared IP, 11 assumes exclusive. So, if we're

	if [[ -n $EIFLIST || -n $AIFLIST ]]
	then
		print "set ip-type=exclusive" >>$TMPFILE
	elif [[ -n $S11 ]]
	then

		# Solaris 11 assumes you're doing an exclusive IP, so if we're not,
		# we have to say so

		print "set ip-type=shared" >>$TMPFILE
	fi

	# Parse the interface list and construct the interface definitions for
	# shared IP instances

	print "\nNetwork"

	[[ -n $S11 ]] && get_s11_network_data $IFLIST

	print $IFLIST | tr , "\n" | while read if
	do
	# Before the = is the NIC, after the = is the address. The address
		# may have a ;route attached

		[[ $if != "*;" ]] && if="${if};"

		phys=${if%%=*}
		addrplus=${if##*=}

		addr=${addrplus%;*}
		defrt=${addrplus#*;}

		[[ -z $defrt ]] && defrt="none"

		print "  configuring interface $phys ($addr, default route=${defrt})"
		get_netmask $addr

		# If we're doing shared interfaces, check the requested interface
		# exists on the system and is plumbed at boot. If we're using
		# exclusive interfaces, the interface *CAN'T* be used by the global
		# zone unless it's a link

		if [[ -n $SIFLIST ]]
		then
			ifconfig $phys >/dev/null 2>&1 || { print \
			"    interface $phys is not configured. Skipping."; continue; }
        elif [[ -n $EIFLIST ]]
        then

			ifconfig $phys >/dev/null 2>&1 && { print \
			"    interface $phys is configured in global zone. Skipping."
			continue; }
		fi

		# Check the IP address looks valid, and doesn't ping

		if ! check_ip_addr $addr
		then
			print "    Skipping."
			continue
		fi

		# Put the network config in the temporary zone config file


        if [[ -n $AIFLIST ]]
        then

            cat <<-EONET >>$TMPFILE
            add anet
                set linkname=$phys
                set lower-link=auto
			EONET

        else

            cat <<-EONET >>$TMPFILE
            add net
                set physical=$phys
			EONET

            # For a shared interface. The IP address goes in the zone config.
            # For an exclusive interface, the IP address goes in the sysidcfg
            # file (assuming we're not on Solaris 11)

            if [[ -n $SIFLIST ]]
            then
                print "    set address=$addr" >>$TMPFILE
            elif [[ -z $S11 ]]
            then

                # This SYSIDBLOCK will override the one built into the
                # install_zone() function

                SYSIDBLOCK="$SYSIDBLOCK
                network_interface=$phys {
                  hostname=$zone
                  ip_address=$addr
                  netmask=$NETMASK
                  protocol_ipv6=no
                  default_route=$defrt
                }
                "
            fi

        fi

		# Close off this interface section

		print "end" >>$TMPFILE
		print "    Network successfully configured"
		SET_IF=true
	done

	[[ -n $SET_IF ]] || die "Could not define any network interfaces."

	# Solaris 8 requires a sparser sysidcfg. It isn't smart enough to ignore
	# things it doesn't understand.

	if [[ x$BRAND == xs8 ]]
	then
		SYSIDBLOCK="network_interface=PRIMARY {
			hostname=$zone
			netmask=$NETMASK
			protocol_ipv6=no
		}"
	fi

	print "\nZone roots"

	# Is the zoneroot UFS? If it is, make the directory with the right perms
	# and print a message. ZFS is more involved.

	if [[ -n $UFSROOT ]]
	then

		print \
		"  zone root is on UFS filesystem $(df $ZONEROOT | sed 's/ .*$//')"

		mkdir -p -m 0700 $ZROOT \
			|| die "Could not create zone root.  [$ZROOT]" 4

	else
		RZFS=${RPOOL}/$zone # shorthand variable
		print "  zone root is in '${RZFS}' dataset"

		# Now we can make the ZFS root. Don't do this on Solaris 11 -
		# zoneadm does it for you

		if [[ -z $S11 ]]
		then
			make_zfs $RZFS/ROOT $ZROOT

			zfs set compression=on $RZFS

			[[ -n $ZOS_QUOTA ]] \
				&& zfs set quota=$ZOS_QUOTA $RZFS

			chown root:root $ZROOT
			chmod 0700 $ZROOT
		fi

	fi

	[[ -d $ZROOT ]] && print "  zone path is $ZROOT"

	# Now create the filsystems and their corresponding definitions. Are we
	# using a defined class? If we are, generate a list of filesystems for
	# later

	print "\nFilesystems"

	if [[ -n $CLASS ]]
	then
		print "  using class $CLASS"

		[[ -n $FSLIST ]] \
			&& print "  overriding class filesystem list (-f supplied)"

		FSLIST=$(print $CLASSES | tr " " "\n" | grep ^$CLASS: | cut -d: -f3)
	fi

	# Parse FSLIST for zone filesystems

	if [[ -n $FSLIST ]]
	then

		print $FSLIST | tr , "\n" | while read fs
		do
			dir=${fs%=*}
			spec=${fs#*=}
			print -n "  ${dir}: "

			[[ -z $dir || -z $spec ]] && \
				{ print "not fully defined.  Skipping"; continue; }

			# If the "special" directory isn't fully qualified, then it
			# should be under the zone's $DATAROOT directory. If it is fully
			# qualified, we don't try to modify it, but just add a mapping.

			if [[ $spec == /* ]]
			then
				print "simple mapping"
			else
				spec="${DATAROOT}/$zone/$spec"

				# If the special does not exist, create it. If DATAROOT is
				# on UFS, that's as simple as making directories. For ZFS,
				# we make a filesystem for each directory, under DPOOL

				rmdir -ps $spec 2>/dev/null

				if [[ -n $UFSDATA ]]
				then
					mkdir -p $spec
					print "(UFS)"
				else
					DZFS=${DPOOL}/${zone}/${dir##*/}
					print "(ZFS - $DZFS)"

					make_zfs $DZFS $spec \
						|| die "could not create filesystem. [$DZFS]"

				fi

			fi

			# update the zone config file

			print "    mapping $spec to $dir"

			cat <<-EOFS >>$TMPFILE
			add fs
			set dir=$dir
			set special=$spec
			set type=lofs
			end
			EOFS

		done

	fi

	# Now we can finish off the zone config file and configure. We archive
	# the zone files off in case we ever need to recreate.

	cat <<-EOZONE >>$TMPFILE
	add rctl
	  set name=zone.cpu-shares
	  add value (priv=privileged,limit=4,action=none)
	end
	EOZONE

	print "$EXTRA_ZONECFG" >>$TMPFILE

	configure_zone $zone $TMPFILE

	# Do some class specific stuff

	if [[ x$CLASS == xapache ]]
	then
		POST_EXTRA='groupadd -g80 www
		userdel webservd
		groupdel webservd
		useradd -u80 -g80 -s /bin/false -c "Apache user" -d /var/tmp www
		chown -R www:www /var/apache/logs
		'
	fi

	# Everything's ready. Install the zone

	$INSTALL_ZONE $zone $ZROOT

	# Boot the zone

	zone_boot $zone

	# And copy stuff in from the global to make it useful, if we've been
	# asked to

	[[ -z $NOCOPY ]] && $CUSTOMIZE_ZONE $zone $ZROOT /

	# Reboot if it's installed from an image

	if [[ -n $INST_IMG ]]
	then
		print "Rebooting..."
		zoneadm -z $zone reboot
	fi

#-- ZONE REMOVAL  ------------------------------------------------------------

# Removing zones is pretty easy. It's always simpler to destroy something
# than create it.

elif [[ x$MODE == xremove ]]
then

	while getopts "F(force)a(all)n(nofs)p(print)" option
	do
		case $option in

			F)	FORCE=true
				;;

			a)	REMOVE_ALL=true
				;;

			n)	KEEP_ALL=true
				;;

			p)	PRINT_ONLY=true
				;;

			*)	usage_further $MODE
				;;
		esac

	done

	shift $(($OPTIND - 1))

	# -p and -F are mutually exclusive

	[[ -n $FORCE && -n $PRINT_ONLY ]] \
		&& die "-p and -F are mutually exclusive." 10

	# -a and -n are mutually exclusive

	[[ -n $KEEP_ALL && -n $REMOVE_ALL ]] \
		&& die "-a and -n are mutually exclusive." 10

	# Make sure we've something to remove. We can handle as many zones as
	# you like, but we need something to go at

	[[ $# == 0 ]] && die "no zones to remove" 11

	for zone in $@
	do
		# From the zonepath, work out what dataset the zone root is on

		if ! zoneadm -z $zone list >/dev/null 2>&1
		then
			print "WARNING: '${zone}' is not configured."
			continue
		fi

		ZPATH=$(zonecfg -z $zone info zonepath)
		ZPATH=${ZPATH#*: }
		ZDS=$(df -k $ZPATH | sed "1d;s/ .*$//")

		unset remove

		if [[ -n $REMOVE_ALL ]]
		then
			# Get a list of ZFS filesystems which we think belong to this
			# zone.

			zonecfg -z $zone info fs | sed -n '/special: /s/^.*: //p' |
			while read fs
			do
				print -u2 here
				print -u2 $fs
				df -kFzfs $fs | sed 1d | read zds junk

				ZFS_RM_LIST=" $ZFS_RM_LIST $zds "
			done

		fi

		# Are we removing a ZFS root?

		[[ -z $KEEP_ALL ]] && [[ $(df -n $ZPATH) == *": zfs"* ]] \
			&& ZFS_RM_LIST="$ZDS $ZFS_RM_LIST"

		# If the ZFS root is the system root, which it sometimes is, STOP
		# NOW

		[[ "x $ZFS_RM_LIST x" == *" $(df -h / | sed '1d;s/ .*$//') "*  ]] \
			&& die "ZFS datasets to be removed include / [${ZFS_RM_LIST}]."

		# Do we only want to print the datasets which would be destroyed?

		if [[ -n $PRINT_ONLY ]]
		then

			[[ -n $ZFS_RM_LIST ]] \
				&& print_zfs_rm_list $ZFS_RM_LIST \
				|| print "no ZFS datasets would be destroyed."

			exit 0
		fi

		# Go interactive if the -f option hasn't been supplied. Print a list
		# of the filesystems which will be destroyed

		if [[ -z $FORCE ]]
		then

			[[ -n $ZFS_RM_LIST ]] && print_zfs_rm_list $ZFS_RM_LIST

			read "remove?really remove zone ${zone}? "
		fi

		# Now do the removal, assuming we have the all-clear

		if [[ x$remove == "xy" || -n $FORCE ]]
		then
			# Remove the zone

			remove_zone $zone

			for fs in $ZFS_RM_LIST
			do
				remove_zfs $fs
			done

		fi

	done

#-- ZONE CLONING -------------------------------------------------------------

elif [[ x$MODE == xclone ]]
then

	zoneadm help 2>&1 | egrep -s ^clone \
		|| die "This system does not support zone cloning."

	while getopts \
		"f(fs)F(force)e:i:(iflist)s:(source)" option 2>/dev/null
	do

		case $option in

			f)	DO_CFS=true
				;;

			F)	FORCE=true
				;;

			e)	IFLIST=$OPTARG
				;;

			i)	IFLIST=$OPTARG
				;;

			s)	SRC_ZONE=$OPTARG
				;;

			*)	usage_further $MODE

		esac

	done

	shift $(( $OPTIND - 1))

	# We need a single argument

	[[ $# == 1 ]] || usage_further $MODE

	ZNAME=$1

	# Does the source zone exist?

	get_zone_state $SRC_ZONE >/dev/null || die "source zone does not exist"

	# Get the ZFS dataset of the source zone's root. If we don't get one,
	# bail

	SZR=$(zfs list | grep $(zoneadm -z $SRC_ZONE list -p | cut -d: -f4) \
	| sed 's/ .*$//')

	[[ -n $SZR ]] || die "source zone does not have ZFS root"

	# Does the target zone exist? We may need to clear it

	rm_zone_if_exists $ZNAME

	# Have we been given an interface list?

	[[ -n $IFLIST ]] || die "Specify interface and IP address with -i."

	ZROOT=${ZONEROOT}/$ZNAME

	RPOOL="${SZR%%/*}/${ZNAME}/ROOT"

	cat<<-EOI

	Cloning $SRC_ZONE
	  new zonename is $ZNAME
	  new zone root is $ZROOT
	  new zone root on dataset '${RPOOL}'
	EOI

	# We know the parent of RPOOL exists, so we can create RPOOL and set its
	# mountpoint

	print "\n  ZFS root dataset"

	if zfs list $RPOOL >/dev/null 2>&1
	then
		print "  root dataset already exists"
	else
		make_zfs $RPOOL $ZROOT
		print "  root dataset created as '${RPOOL}', mounted at $ZROOT"
		chown root:root $ZROOT
		chmod 0700 $ZROOT
	fi

	# When we clone we look to see if there are any /zonedata filesystems.
	# If there are, we create ones for the new zone

	print "\n  Creating data filesystems"

	if [[ -z $DO_CFS ]]
	then
		print "    not requested"
	else

		zonecfg -z $SRC_ZONE info fs | grep "special: $DATAROOT" | \
		while read a mpt
		do
			zds=$(zfs list | grep " ${mpt}$" | sed 's/ .*$//')
			print "    creating duplicate for $mpt on $zds"
			new_ds=$(print $zds | sed "s/${SRC_ZONE}/${ZNAME}/")
			new_mpt=$(print $mpt | sed "s/${SRC_ZONE}/${ZNAME}/")

			# Create the filesystem and get ready to sed the original zone's
			# config file

			make_zfs $new_ds $new_mpt
			SEDLINE="$SEDLINE -e \"s|special=$mpt|special=$new_mpt|\""
		done

	fi

	# Parse the interface list. We want to get the address of each given
	# interface in the source zone so we can change it in the target zone

	print "\n  Parsing interface list"

	SEDLINE="$SEDLINE -e 's|zonepath=.*$|zonepath=${ZROOT}|'"

	[[ -n $S11 ]] && get_s11_network_data $IFLIST

	print $IFLIST | tr , "\n" | while read if
	do
		phys=${if%%=*}
		addr=${if##*=}

		get_netmask $addr

		check_ip_addr $addr || die "Problem with network interfaces."

		print "    getting interface $phys"

		OE=$(zonecfg -z $SRC_ZONE info net physical=$phys 2>/dev/null \
		| sed -n -e '/address/s/^.*: //;s/\./\\\./gp')

		if [[ -z $OE ]]
		then
			print "     can't find 'net' resource: trying 'anet'"
			OE=$(zonecfg -z $SRC_ZONE info anet physical=$phys 2>/dev/null \
			| sed -n -e '/address/s/^.*: //;s/\./\\\./gp')
		fi

		if [[ -z $OE ]]
		then
			if=$(zonecfg -z $SRC_ZONE info | sed -n '/linkname/s/^.* //p')
			die "interface $phys not in source zone. Try $if."
		fi

		print "    matched interface $phys"

		SEDLINE="${SEDLINE} -e 's/$OE/$addr/'"
	done

	# Now copy the source zone's config, altering the IP addresses and
	# filesystem specials

	zonecfg -z $SRC_ZONE export | eval sed "$SEDLINE" >$TMPFILE
	configure_zone $ZNAME $TMPFILE

	# We may have to halt the zone

	if [[ $(get_zone_state $SRC_ZONE) == "running" ]]
	then
		print "  halting $SRC_ZONE"
		zoneadm -z $SRC_ZONE halt
		RB_Z=1
	fi

	install_zone $ZNAME $ZROOT
	zone_boot $ZNAME

	# reboot the source zone if we halted it

	[[ -n $RB_Z ]] && zone_boot $SRC_ZONE

#-- ZONE RECREATION ----------------------------------------------------------

elif [[ x$MODE == xrecreate ]]
then

	while getopts \
		"d:(dir)e:F(force)w(whole)s(sparse)" option 2>/dev/null
	do

		case $option in

			d)	DR_DIR=$OPTARG
				;;

			e)	IP_ADDR=$OPTARG
				;;

			F)	FORCE=true
				;;

			s)	ZTYPE="sparse"
				;;

			w)	ZTYPE="whole"
				;;

			*)	usage_further $MODE

		esac

	done

	shift $(( $OPTIND - 1))

	# We need a single argument

	[[ $# == 1 ]] || usage_further $MODE

	ZNAME=$1

	# Does the given DR directory exist?

	[[ -d $DR_DIR ]] || die "DR directory does not exist. [$1]"

	# Work out where we think the DR data for the given zone should be

	Z_CF_DIR="${DR_DIR}/$(uname -n)/$ZNAME"

	[[ -d $Z_CF_DIR ]] || die "No DR data for $ZNAME. [$Z_CF_DIR]"

	# Can we get to the DR script?

	[[ -f $DR_SCR ]] || die "no DR recovery script. [$DR_SCR]"

	# Do we have a config file

	Z_CF="${Z_CF_DIR}/zone_config"

	[[ -s $Z_CF ]] || die "no config file [$Z_CF]"

	# Do we have an exclusive IP address?

	egrep -s "ip-type=exclusive" $Z_CF \
		&& cat<<-EOWARN

		=====================================================================

		  WARNING: zone was previously built with an exclusive IP instance,
		  but this script doesn't yet have the ability to recreate the
		  networking configuration. Once the zone is installed, you have to
		  connect to the zone's console with

		    # zlogin -C $ZNAME

		  and manually enter the name and IP address.

		=====================================================================

		EOWARN

	rm_zone_if_exists $ZNAME

	# Get the zone root, then make it, with the correct permissions

	ZROOT=$(sed -n '/zonepath=/s/^.*zonepath=//p' $Z_CF)

	mkdir -p -m 0700 $ZROOT $ARC_DIR

	# We may wish to force the whole/sparse root zone type. We can do this
	# by removing the add inherit-pkg-dir lines from an existing config. To
	# make a zone sparse, we have to ADD those lines

	if [[ x$ZTYPE == xsparse ]]
	then
		print "forcing sparse root"
		INHERIT_FILE="/tmp/inherit$$"

		# Remove the inherit directories first

		cat <<-EOINHERIT >>$INHERIT_FILE
		add inherit-pkg-dir
		set dir=/lib
		end
		add inherit-pkg-dir
		set dir=/platform
		end
		add inherit-pkg-dir
		set dir=/sbin
		end
		add inherit-pkg-dir
		set dir=/usr
		end
		EOINHERIT

		sed '/add inherit-pkg-dir/,/end/d' $Z_CF \
		| sed "/ip-type/ r $INHERIT_FILE" >$TMPFILE
		rm $INHERIT_FILE
	elif [[ x$ZTYPE == xwhole ]]
	then
		print "forcing whole root"
		sed '/add inherit-pkg-dir/,/end/d' $Z_CF >$TMPFILE
	else
		cp $Z_CF $TMPFILE
	fi

	# Do we have all the filesystems we need to reference? If not, we'll
	# make a ZFS filesystem especially. There's a fair degree of assumption
	# going on here, but I think that's okay.

	sed -n "/set special/s/^.*=//p" $Z_CF | while read special
	do

		if [[ ! -d $special ]]
		then
			MK_FS=true
			break
		fi

	done

	if [[ -n $MK_FS ]]
	then

		ztop="${ZPOOL}/$ZNAME"

		# If the top-level zone filesystem isn't there, make it

		make_zfs_root $ztop $ZROOT

		sed -n -e '/set special/{x;1!p;g;$!N;p;D;}' -e h $Z_CF | \
		while read line
		do
			line=${line#set }
			key=${line%=*}
			eval $(print $line)

			[[ $key == type ]] \
				&& make_zfs_special ${ztop}/${special##*/} $special

		done

	fi

	# Read the config file into zonecfg

	configure_zone $ZNAME $TMPFILE

	# Install and boot the zone. We need a netmask - use the first physical
	# interface in the zone config file

	cat $Z_CF
	get_netmask $(sed -n '/^set physical/s/^.*=//p' $Z_CF)

	install_zone $ZNAME $ZROOT
	zoneadm -z $ZNAME boot || die "failed to boot zone"

	# Wait for the zone to boot, then run the customize function

	zone_wait $ZNAME
	customize_zone $ZNAME $ZROOT "${Z_CF_DIR}/root"

	# Now we wait for the zone to come up properly, then run the DR script

	sleep 4
	zone_wait $ZNAME

	print "running restore script"
	$DR_SCR restore -F -d ${Z_CF_DIR%/$(uname -n)/*} $ZNAME

#-- ALL ZONE OPERATIONS ------------------------------------------------------

elif [[ x$MODE == xall ]]
then

	# Do we have any local zones?

	[[ -z $(zoneadm list -c | grep -v global) ]] \
		&& die "no local zones on this system"

	# Stop running zones

	if [[ $1 == "halt" || $1 == "reboot" || $1 == "shutdown" ]]
	then

		zl=$(zoneadm list | grep -v global)

		if [[ -z $zl ]]
		then
			print "no running zones to $1"
		else

			for z in $zl
			do

				if [[ $1 == "shutdown" ]]
				then
					print "  shutting down $z"
					zlogin $z "init 5"
				else
					print "  ${1}ing $z"
					zoneadm -z $z $1
				fi

			done

		fi

	elif [[ $1 == "boot" ]]
	then

		# Start non-running zones

		zl=$(zoneadm list -pc | egrep -v "global|:running:" | cut -d: -f2)

		if [[ -z $zl ]]
		then
			print "no non-running zones to boot"
		else

			for z in $zl
			do
				print "  booting $z"
				zoneadm -z $z boot
			done

		fi


    elif [[ $1 == "run" ]]
    then
        shift

        # Run whatever's left in all zones

        zl=$(zoneadm list | sed 1d)

		if [[ -z $zl ]]
		then
			print "no running zones"
		else

			for z in $zl
			do
				print "running '$*' in $z"
				zlogin $z $*
			done

        fi

	fi

#-- INFORMATION --------------------------------------------------------------

elif [[ x$MODE == xlist ]]
then

	if [[ $1 == "files" ]]
	then
		print "\nThe following files will be copied from the global zone:\n"

		for file in $FILELIST
		do
			[[ -f /$file ]] && print "  /$file"
		done | sort

		print "\nFile copying can be disabled with the '-n' option."

	elif [[ $1 == "classes" ]]
	then
		print "\nThe following classes are defined:\n"

		for class in $CLASSES
		do
			print "  ${class%%:*}:\n    ${class#*FSLIST:}\n" | tr , ' '
		done

	elif [[ $1 == "defaults" ]]
	then
		cat<<-EODEF
		The following zone defaults are set:"

		             zoneroot : $ZONEROOT
		            zone data : $DATAROOT
		            time zone : $TIMEZONE ('$TIMEZONE_S8' for Solaris 8 branded)
		  ZFS zone root quota : $ZOS_QUOTA
		  zone config archive : $ARC_DIR
		     name prefix (-p) : $(uname -n)z-
		      path to s-dr.sh : $DR_SCR $([[ -f $DR_SCR ]] || print "(not installed)")
		  DR/zone restore dir : $DR_DIR

		EODEF
	else
		usage_further $MODE
	fi

elif [[ x$MODE == xhelp ]]
then
	usage_further $1
else # I don't know what we're supposed to be doing.
	usage
fi
