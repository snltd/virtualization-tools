#!/bin/ksh

#=============================================================================
#
# zonedog.sh
# ----------
#
# Sometimes when I boot my workstation, zones don't start. This is a
# simple watchdog script which gets run from cron, and starts
# non-running zones.  Give it a list of zones to start on the command
# line. Zones are started in whatever order they come out of 'zoneadm
# list', so no dependencies or priorities are honoured.
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
# v1.1. Removed redundant code.
#
# R Fisher 04/2013
#
#=============================================================================

PATH=/usr/bin:/usr/sbin
	# Always set your PATH

MY_VER="1.1"

#-----------------------------------------------------------------------------
# SCRIPT STARTS HERE

# Only runs in the global.

if [[ $(zonename 2>/dev/null) != "global" ]]
then
	print "ERROR: script must be run in global zone."
	exit 3
fi

while getopts "Vhq" option
do

	case $option in
		
		q)	exec >/dev/null
			exec 2>&-;
			;;

		h)	cat <<-EOUSAGE

usage: ${0##*/} [-Vhq] zone...

where:

      -q :     be quiet
      -V :     print version information
      -h :     print usage information

EOUSAGE
			exit 2
			;;

		V)	print $MY_VER
			exit 0
			;;

	esac
done

# Make sure we have at least one zone to look at
			
if [[ $# == 0 ]] 
then
	print -u2 "usage: ${0##*/} [-Vhq] zone..."
	exit 1
fi

# Get a list of all the zones on this host, and their state. For each
# one that is not running, look to see if it was among the arguments,
# and if it was, boot it up.

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

