#!/bin/ksh

#=============================================================================
#
# bootdog.sh
# ----------
#
# Sometimes when I boot my workstation, zones don't start. This is a simple
# watchdog script which gets run from cron, and starts non-running zones.
# Give it a list of zones to start on the command line. Zones are started in
# whatever order they come out of 'zoneadm list', so no dependencies or
# priorities are honoured.
#
# Run it in a global zone only, as a user with zone admin privileges. It
# doesn't check to see that either of those things are true.
#
# -q suppresses all output (for use with cron)
# -h prints brief usage info
# -V prints the version
#
# v1.0. Please log all changes below.
#
# R Fisher 04/2013
#
#=============================================================================

PATH=/usr/bin:/usr/sbin

ZONELIST="tap-ws tap-dns"

MY_VER="1.0"

#-----------------------------------------------------------------------------
# FUNCTIONS

die()
{
	# Exit function

	[[ -n $1 ]] && print -u2 "ERROR: $1" || print "FAILED"

	exit ${2:-1}
}

#-----------------------------------------------------------------------------
# SCRIPT STARTS HERE

while getopts "Vhq" option
do

	case $option in
		
		q)	exec >/dev/null
			exec 2>&-;
			;;

		h)	print -u2 "usage: ${0##*/} [-Vhq] <zone>..."
			exit 2
			;;

		V)	print $MY_VER
			exit 0
			;;

	esac
done

# Make sure we have at least one zone to look at
			
[[ $# == 0 ]] && die "no zones given"

# Get a list of all the zones on this host, and their state. For each one
# that is not running, look to see if it was among the arguments, and if it
# was, boot it up.

zoneadm list -pc | cut -d: -f2,3 | tr : \  | while read zone state
do

	[[ $state == "running" ]] && continue

	for z in $*
	do

		if [[ $zone == $z ]]
		then
			print "booting $z"
			zoneadm -z $z boot
		fi

	done


done

