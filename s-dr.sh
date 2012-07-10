#!/bin/ksh

#=============================================================================
#
# s-dr.sh
# -------
#
# Copy basic DR information to a directory.  This information can be used in
# tandem with s-zone.sh, but the files it saves are useful in many other
# circumstances.
#
# For use on Solaris 9, 10 and 11, SPARC and x86.
#
# v3.0  First public release. Removed all site-specific stuff and cleaned
#       code up. 
#
# (c) 2012 SNLTD. Please see http://snltd.co.uk/scripts/s-dr.php for more
# information
#
#=============================================================================

#-----------------------------------------------------------------------------
# VARIABLES

MY_VER="3.0"
	# Version of script 

PATH=/usr/bin:/usr/sbin
	# Always set your path

# Default directory to write files to. This can be overridden with the -d
# flag

BASEDIR="/var/snltd/s-dr"

SMF_PTN="snltd"
	# Services whose FMRIs contain with this string will have their
	# manifests stored. Pattern matching is done via egrep(1), so multiple
	# patterns may be specified if separated by "|" characters

# FILELIST is a list of the files which we wish to preserve or restore. It
# can contain files, links or directories. They should be relative to root.

FILELIST=".ssh \
	etc/X11 \
	etc/auto_home \
	etc/auto_master \
	etc/default/inetinit \
	etc/default/login \
	etc/defaultrouter \
	etc/ethers \
	etc/group \
	etc/hostname* \
	etc/inet/hosts \
	etc/inet/inetd.conf \
	etc/inet/netmasks \
	etc/inet/ntp.conf \
	etc/inet/services \
	etc/logadm.conf \
	etc/logindevperms \
	etc/my.cnf \
	etc/nsswitch.conf \
	etc/passwd \
	etc/resolv.conf \
	etc/security/auth_attr \
	etc/security/exec_attr \
	etc/security/policy.conf \
	etc/security/prof_attr \
	etc/shadow \
	etc/ssh \
	etc/sysidcfg \
	etc/syslog.conf \
	etc/system \
	etc/system \
	etc/user_attr \
	etc/vfstab \
	var/spool/cron/crontabs"

# Here we set variables for the names of the files we're going to write. We
# do this so we know the arc_ and rec_ functions will be looking for the
# same things

OS_INFO="os_info"
CRLE_FILE="crle_info"
SCCLI_FILE="3510_config"
MD_FILE="metadevices"
OS_FILE="os_info"
PKG_FILE="package_list"
PCH_FILE="patch_list"
PROUTE_FILE="persistent_routes"
RTABLE_FILE="routing_table"
SC_SETUP_FILE="sc_setup"
SC_USERS_FILE="sc_users"
SMF_ARC_FILE="smf_archive"
SMF_SVCS_FILE="smf_svc_list"
SMF_SVC_BASE="service."
VTOC_BASE="vtoc"
FDISK_BASE="fdisk"
ZFS_PROPS="zfs_props"
ZFS_DEF_BASE="zpool_defs"

# ARC_GLOBAL is a list of the things to do when we archive a global zone

ARC_GLOBAL="os \
	fdisk \
	vtoc \
	metadb \
	zfs \
	eeprom \
	sched_class \
	sc \
	routing \
	crle \
	patches \
	packages \
	svcs \
	3510 \
	files"

# ARC_LOCAL is a list of the things to do when we archive a local zone

ARC_LOCAL="zone_info \
	crle \
	routing
	patches \
	packages \
	svcs \
	files"

# REC_GLOBAL is a list of things to do when re restore a local zone. Note
# that you can't restore quite a few of the things that were archived.
# Some, like fdisk or vtoc, make no sense in this context. Others, like
# restoring ZFS pools and patches, are non-trivial to implement, and not
# really needed at the moment. Maybe one day.

REC_GLOBAL="zpool \
	zfs \
	sched_class \
	crle \
	svcs \
	packages \
	routing \
	files"

# REC_LOCAL is a list of things to do when we restore a local zone

REC_LOCAL="crle \
	svcs \
	packages \
	routing \
	files"

ERRS=0
	# Keep count of how many functions failed

LOGDEV="local7"
	# System log facility to which we record any errors

TMPFILE="/tmp/${0##*/}.$$.$RANDOM"
	# Temp file. We re-use this in a few places

LOCK_FILE=/var/run/s-dr.pid
	# Lock file

#-----------------------------------------------------------------------------
# FUNCTIONS

function usage
{
	cat<<-EOUSAGE

	usage:

	  ${0##*/} archive [-z zone,zone] [-d directory] [-R dir] [-N dir]
	
	  ${0##*/} restore [-Fn] [-p package_dir] [-d directory] zone

	  ${0##*/} -V
	
	  -V :     print version and exit

	ARCHIVE MODE:
	  -d :     local directory in which to store DR information. By default
	           information is stored in ${BASEDIR}. A directory named
	           hostname is created under this directory, and the files
	           are stored inside that

	  -R :     information for scp to copy DR information to remote host.
	           Of form "user@host:directory"

	  -N :     automounted NFS path to copy DR information to. Of the form
	           /net/host/dir

	  -s :     archive SMF manifests whose FMRI begins with given string.
	           Defaults to "snltd"

	  -z :     only take data for the given zone(s). Multiple zones can be
	           supplied in a comma separated list

	RESTORE MODE:
	  -d :     directory in which to find DR information. Defaults to
	           ${BASEDIR}

	  -F :     don't interactively ask for confirmation before doing a
	           restore

	  -N :     don't restore the DR files. Meaningless without -z

	  -p :     restore missing packages from given directory

	Restore mode only restores files and reconfigures services in an already
	running zone. To rebuild a zone from scratch, use s-zone.sh.

	EOUSAGE
	exit 2
}

function zone_run
{
	# Run a command in global, or a local, zone
	# $1 is the command -- QUOTE IT IF IT HAS SPACES!
	# $2 is the zone

	# If we've been given a zone name, run the command in that zone. If not,
	# run it here. The print into the zlogin gives zlogin some stdin of its
	# own, so it won't pinch the stdin that perhaps should be going into a
	# read(1)

	if [[ $2 == "global" ]]
	then
		eval $1
	else
		print | zlogin $2 $1
	fi

}

function get_zone_root_dir
{
	# Get a zone's root directory.
	# $1 is the zone to get the root of

	if [[ $1 == "global" ]]
	then
		print /
	else
		print "$(zonecfg -z $1 info zonepath | cut -d\  -f2)/root"
	fi
}

function can_has
{
    # simple wrapper to whence, because I got tired of typing >/dev/null
    # $1 is the file to check

    whence $1 >/dev/null \
        && return 0 \
        || return 1
}

function is_cron
{
	# Are we being run from cron? True if we are, false if we're not. Value
	# is cached in IS_CRON variable. This works by examining the tty the
	# process is running on. Cron doesn't allocate one, the shells have a
	# pts/n, on Solaris at least

	RET=0

	if [[ -n $IS_CRON ]]
	then
		RET=$IS_CRON
	else
		[[ $(ps -otty= -p$$)  == "?"* ]] || RET=1
		IS_CRON=$RET
	fi

	return $RET

}

function is_global
{
    # Are we running in the global zone? True if we are, false if we're
    # not. True also if we're on Solaris 9 or something else that doesn't
    # know about zones. Now caches the value in the IS_GLOBAL variable

    RET=0

    if [[ -n $IS_GLOBAL ]]
    then
        RET=$IS_GLOBAL
    else
        can_has zonename && [[ $(zonename) != global ]] && RET=1
        IS_GLOBAL=$RET
    fi

    return $RET
}

function is_root
{
    # Are we running as root? 

    if [[ -n $IS_ROOT ]]
    then
        RET=$IS_ROOT
    else
        [[ $(id) == "uid=0(root)"* ]] && RET=0 || RET=1
        IS_ROOT=$RET
    fi

    return $RET
}

function die
{
    # Print a message and exit.
    # $1 is the message to print
    # $2 is an optional exit code. Exits 1 if $2 is blank

	log "$1" "err"
    exit ${2:-1}
}

function log
{
	# Shorthand wrapper to logger, so we are guaranteed a consistent message
	# format. We write through syslog if we're running through cron, through
	# stderr if not

	# $1 is the message
	# $2 is the syslog level. If not supplied, defaults to info

	[[ $2 == "err" ]] && EXTRA="ERROR: " || EXTRA=""

	is_cron \
		&& logger -p ${LOGDEV}.${2:-info} "${0##*/}: $1" \
		|| print -u2 "${EXTRA}$1"
	
}

function inc_error
{
	# Print a failure message and increment the error counter. Remember
	# ksh88 variables always have global scope

	print "FAILED"
	((ERRS = ERRS + 1))
}

function qualify_path
{
	# Make a path fully qualified, if it isn't already
	# $1 is the path to qualify

	if [[ $1 != /* ]]
	then
		print "$(pwd)/$1"
	else
		print $1
	fi

}

function whole_root_zone
{
	# return 0 if a zone is whole root, 1 if it's not
	# $1 is the zone to examine

	TFILE="$(get_zone_root_dir $1)/usr/tfile$$"

	touch $TFILE 2>/dev/null \
		&& RET=0 \
		|| RET=1

	rm -f $TFILE

	return $RET
}

function get_patch_list
{
	# Get a list of patches in the given zone
	# $1 is the zone

	patchadd -p -R $(get_zone_root_dir $1) \
	| sed "/^$/d;s/Patch: \([^ ]*\) .*$/\1/" 
}

function get_package_list
{
	# Get a list of the packages in the given zone
	# $1 is the zone

	if can_has pkg
	then
		pkg -R $(get_zone_root_dir $1) list -H
	else
		pkginfo -R $(get_zone_root_dir $1) -x | sed "/^ /d;s/ .*//" 
	fi
}

#- archive functions ---------------------------------------------------------

function run_archive
{
	# This is the main function of the "archive" part of the program. It
	# calls the arc_ functions with suitable arguments.
	
	# $1 is the zone to run tests for

	[[ $1 == "global" ]] \
		&& THINGS=$ARC_GLOBAL \
		|| THINGS=$ARC_LOCAL

	ZDIR="${OUTDIR}/$1"

	mkdir -p $ZDIR

	if [[ -d $ZDIR ]]
	then
		print "working on $1"

		# Run the functions. I do the error handling in the functions
		# themselves. I know that's odd, and I'm not that happy doing it,
		# but, because not all the functions are guaranteed to do anything,
		# it's very hard to properly catch errors and produce diagnostic
		# information so that it's always valid.  However, if we do have a
		# function return nonzero, we might as well write a log message

		for thing in $THINGS
		do
			arc_$thing $ZDIR $1 || log "error in function arc_$thing" err
		done

		print
	else
		print "WARNING can't create zone directory [$ZDIR]"
		log "no directory $ZDIR" err
		inc_error
	fi
}

# The functions that do the archiving are called arc_something(). They
# should take a maximum of two arguments.  The first should be the directory
# the function should create files in, the second should be the zone to work
# on. Some functions won't have a $2.

# Most of these functions have a corresponding rec_() function, which
# recovers and reinstalls the data saved by the arc_() function.

function arc_os
{
	# Just archives the revision of the O/S so we can see what we've got
	# backed up. Used by the svccfg restore

	# $1 is the directory to write files to

	print -n "  archiving OS revision info: "

	uname -X > ${1}/$OS_INFO \
		&& print "ok" || inc_error
}

function arc_fdisk
{
	# Store fdisk information on X86 systems
	
	# $1 is the directory to write files to

	if [[ $(uname -i) == i86pc ]]
	then

		for disk in $DISKLIST
		do
			print -n "  archiving fdisk layout for ${disk}: "
			
			fdisk -W ${1}/${FDISK_BASE}.$disk /dev/rdsk/${disk}p0 \
			&& print "ok" || inc_error
		done

	fi
	
}

function arc_vtoc
{
	# Store VTOC information for every disk on the system
	# $1 is the directory to write the files to

	for disk in $DISKLIST
	do
		print -n "  archiving VTOC for ${disk}s2: "
		prtvtoc /dev/rdsk/${disk}s2 > ${1}/${VTOC_BASE}.${disk}s2 \
		&& print "ok" || inc_error
	done

}

function arc_metadb
{
	# Store metadb information
	# $1 is the directory to write the file to

	if can_has metadb && metastat >/dev/null 2>&1
	then
		print -n "  archiving metadevice information: "
		metastat -p >${1}/$MD_FILE && print "ok" || inc_error
	fi

}

function arc_zfs
{
	# Store ZFS related information
	# $1 is the directory to write to

	if can_has zpool
	then

		zpool list -Ho name | while read pool
		do
			print -n "  archiving zpool information for \"${pool}\": "
			zpool status -v $pool > ${1}/${ZFS_DEF_BASE}.$pool \
			&& print "ok" || inc_error
		done
	
		print -n "  archiving ZFS dataset properties: "

		zc=0

		zfs list -Ho name | while read fs
		do
			zfs get -Ho name,property,value -s local all $fs \
				|| zerr=1

		done >${1}/$ZFS_PROPS

		[[ -z $zerr ]] && print "ok" || inc_err

	fi

}

function arc_zone_info
{
	# Store the zone config
	# $1 is the directory to write to
	# $2 is the zone

	print -n "  archiving zone config for ${2}: "

	zonecfg -z $2 export >${1}/zone_config \
		&& print "ok" || inc_error
}
	
function arc_crle
{
	# $1 is the directory to write to
	# $2 is the zone

	print -n "  archiving CRLE info for ${2}: "

	zone_run "crle" $2 >${1}/$CRLE_FILE \
		&& print "ok" || inc_error
}

function arc_sc
{
	# Store the system controller setup, assuming we can get to it.
	# $1 is the target directory

	SCADM="/usr/platform/$(uname -i)/sbin/scadm"

	if [[ -x $SCADM ]]
	then
		print -n "  archiving SC users: "
		$SCADM usershow >${1}/$SC_USERS_FILE \
			&& print "ok" || inc_error

		print -n "  archiving SC setup: "
		$SCADM show >${1}/$SC_SETUP_FILE \
			&& print "ok" || inc_error

	fi
}

function arc_routing
{
	# Make a note of the routing table, and properly record any persistent
	# routes

	# $1 is the directory to store them in
	# $2 is the zone to work on

	print -n "  archiving routing table: "

	netstat -nr >${1}/$RTABLE_FILE \
		&& print "ok" || inc_error

	if zone_run "route -p show 2>/dev/null" $2 | egrep -s :
	then
		print -n "  archiving persistent routes for $2: "

		zone_run "route -p show" $2 | sed -n "/:/s/^.*: //p" \
		>"${1}/$PROUTE_FILE" \
			&& print "ok" || inc_error
	fi
}

function arc_packages
{
	# Archive the list of packages in a zone. We ran into trouble running
	# pkginfo through zlogin (it sometimes just hung) so we'll query the
	# database with pkginfo -R

	# $1 is the directory to write to
	# $2 is the zone

	print -n "  archiving package info for ${2}: "
	
	get_package_list $2 >${1}/$PKG_FILE \
		&& print "ok" || inc_error

}

function arc_patches
{
	# Archive a list of the patches installed in a zone. Same method and
	# reasoning as for packages
	# $1 is the directory to write to
	# $2 is the zone

	if can_has patchadd
	then

		print -n "  archiving patch info for ${2}: "

		get_patch_list $2 >${1}/$PCH_FILE && print "ok" || inc_error
	fi
}

function arc_3510
{
	# Archive the 3510 configuration, if one is attached
	# $1 is the directory to write to

	if can_has sccli
	then
		print -n "  archiving 3510 configuration: "

		print "show configuration" | sccli >${1}/$SCCLI_FILE 2>&1 \
			&& print "ok" || inc_error

	fi
}

function arc_files
{
	# $1 is the directory to copy files to
	# $2 is the zone

	# What's the output directory? We need to export this, because the tar
	# will start in a subshell. I don't like doing this subshell thing, but
	# Solaris tar doesn't provide a cleaner way, and I don't want to have to
	# install gnu tar on everything.

	print -n "  archiving files for ${2}: "

	export DEST_DIR="${1}/root"

	mkdir -p $DEST_DIR

	if cd $(get_zone_root_dir $2)
	then
		# Suppress stderr, because not all these files will be in every zone

		tar -cf - $FILELIST 2>/dev/null | ( cd $DEST_DIR; tar -xf -) \
			&& print "ok" || inc_error
	else
		inc_error
	fi

}

function arc_svcs
{
	# Get an XML dump of the current SMF repository. This takes not only the
	# states, but any properties which have been altered. Sweet.

	# It's not always a good idea (or possible) to reimport that archive, so
	# we also take a snapshot of the running services. This way we can at
	# least turn services on and off to get back to where we were, even
	# though altered properties will be lost.

	# Finally, we do a svccfg export of any services whose FMRI begins with
	# the contents of the SMF_PTN variable

	# $1 is the directory to write the file to
	# $2 is the zone to query

	if can_has svcs
	then
		TFILE="${TMPFILE}.repository.db"

		print -n "  archiving SMF repository for ${2}: "

		cp "$(get_zone_root_dir $2)/etc/svc/repository.db" $TFILE

		# We need a different command in Solaris 11

		svccfg help 2>&1 | egrep -s archive \
			&& svccmd="archive" \
			|| svccmd="extract -a"

		svccfg -f - <<-EOSVCCFG 
			repository $TFILE
		 	$svccmd >${1}/$SMF_ARC_FILE
		EOSVCCFG

		[[ $? == 0 ]] && print "ok" || inc_error

		rm -f $TFILE

		print -n "  archiving SMF service state for ${2}: "

		zone_run "svcs -Ho fmri" $2 >${1}/$SMF_SVCS_FILE \
			&& print "ok" || inc_error

		grep "^svc:/$SMF_PTN/" ${1}/$SMF_SVCS_FILE | while read svc
		do
			sname=${svc%:*}
			sname_short=${sname##*/}

			print -n \
			"  archiving $SMF_PTN service '${sname_short}' from ${2}: " 

			zone_run "svccfg export $sname" $2 \
			>"${1}/${SMF_SVC_BASE}${SMF_PTN}.${sname_short}.xml" \
				&& print "ok" || inc_error

		done

	fi
}

function arc_eeprom
{
	# Get EEPROM settings and save them in a file. This is very easy
	# $1 is the directory to save to

	print -n "  archiving EEPROM settings: "

	eeprom >${1}/eeprom_info \
		&& print "ok" || inc_error

}

function arc_sched_class
{
	# Archive the default scheduling class, if one is set
	# $1 is the directory to save to

	SLINE="$(dispadmin -d 2>&1)"

	if [[ $SLINE != *"class is not set"* ]]
	then
		print -n "  archiving default scheduling class: "

		print $SLINE | cut -d\  -f1 >${1}/sched_class \
			&& print "ok" || inc_error

	fi

}

#- RESTORE FUNCTIONS ---------------------------------------------------------

function run_restore
{
	# An analog to run_archive. It calls the rec_ functions with suitable
	# arguments.
	
	# $1 is the zone to restore
	# $2 is the directory with the files we're restoring

	[[ $1 == "global" ]] \
		&& THINGS=$REC_GLOBAL \
		|| THINGS=$REC_LOCAL

	if [[ -d $2 ]]
	then
		print "working on $1"

		# Run the functions. 

		for thing in $THINGS
		do
			rec_$thing $2 $1 || log "error in function rec_$thing" err
		done

		print
	else
		die "no zone data directory [$2]"
	fi
}

function rec_zpool
{
	# Import, or possibly recreate zpools, if we're in the global zone.
	# $1 is the directory to find the ZFS configuration in

	# First we try to import them. We can get the names from the archive
	# files. You have to use a for loop here. If you use read | while, the
	# interactive read won't work.

	for zcf in $(ls ${1}/${ZFS_DEF_BASE}.*)
	do
		pool=${zcf##*.}

		# The pool may already be on the system

		if zpool list $pool >/dev/null 2>&1
		then
			print "  zpool '$pool' already on system. Skipping."
			continue
		fi

		print -n "  trying to import zpool '$pool': "

		if zpool import -f $pool >/dev/null 2>&1
		then
			print "ok"
		else
			cat<<-EOMSG 


--------------------------------------------------------------------------------

   We were not able to import the zpool '$pool'. This script has the ability
   to recreate the pool and all the datasets it contains, but these will be
   empty, and will overwrite any pool which previously failed to import.

   If you enter "force" here, then the 'zpool create' command will be
   invoked with the -f flag, which will forcibly overwrite any existing
   zpool on the required slices.

--------------------------------------------------------------------------------

			EOMSG

			read "recreate?Do you want to recreate the '$pool' zpool? [no] "
	
			if [[ $recreate == "y"* || $recreate == "force" ]]
			then

				[[ $recreate == "force" ]] && FF="-f " || FF=""

				ZP_CMD=$(print -n "zpool create $FF"
	
					grep ONLINE $zcf | grep -v state: | while read f1 f2 junk
					do
						print -n "$f1 "
					done)
	
				print -n "  recreating pool $pool:"
	
				$($ZP_CMD) && print "ok" || inc_error
			fi

		fi
	
	done
}

function rec_routing
{
	# Recreate persistent routes, if there are any
	# $1 is the directory the route file is in

	RFILE="${1}/$PROUTE_FILE"

	if [[ -s $RFILE ]]
	then
		print -n "  restoring persistent routes: "

		$(sed "s/add/-p add/" $RFILE >/dev/null) \
			&& print "ok" || inc_error

	fi

}

function rec_zfs
{
	# Recreate ZFS datasets, if we're in the global zone.
	# $1 is the directory to find the ZFS configuration in

	ZFS_FILE="${1}/$ZFS_PROPS"

	[[ -s $ZFS_FILE ]] || return

	print "  restoring ZFS datasets"

	# Run the file through sort so we know parents will be created before
	# children

	sort $ZFS_FILE | while read dataset key val 
	do
		
		# Create the dataset if it doesn't exist

		if ! zfs list $dataset >/dev/null 2>&1
		then
			print -n "    creating ${dataset}: "
			zfs create $dataset 2>/dev/null \
				&& print "ok" || inc_error
		fi

		# Now set whatever property we have hold of

		print -n "    setting $key to ${val}: "

		zfs set ${key}=$val $dataset 2>/dev/null \
			&& print "ok" || inc_error

	done 
}

function rec_crle
{
	# $1 is the directory to find the crle config file in
	# $2 is the zone

	CRLE_CMD="$(sed -n '/Command line:/{n;p;}' ${1}/$CRLE_FILE)"

	if [[ -n $CRLE_CMD ]]
	then
		print -n "  restoring CRLE info for ${2}: "

		zone_run "$CRLE_CMD" $2 && print "ok" || inc_error
	fi

}

function rec_patches
{
	# $1 is the DR directory
	# $2 is the zone

	if whole_root_zone $2
	then
		print "  restoring patches is not currently supported"
	else
		print "  $2 is a sparse zone, patches can't be modified"
	fi
}


function rec_packages
{
	# Restore packages, if we've been asked to. We only do this if -p has
	# been given, and if that directory is valid. NB - this nasty function
	# has many exit points!
	
	# ONLY WORKS FOR SYSV PACKAGES! (for now)

	# $1 is the DR directory
	# $2 is the zone

	# Look to see if we need to run this function

	[[ -z $PKG_DIR ]] && return

	can_has pkgadd || return

	# We were given a directory. Does it look valid?

	if [[ ! -d $PKG_DIR ]] 
	then
		log "directory does not exist. [${PKG_DIR}]" err
		return 1
	fi

	# If the zone is sparse root, we can't restore packages. If it's whole
	# root, diff the packages in the zone with the packages the DR data says
	# should be in the zone

	if whole_root_zone $2
	then
		get_package_list $2 >$TMPFILE

		P_EXTRA=$(diff $1/$PKG_FILE $TMPFILE | egrep "^<" \
		| cut -d\  -f2)
		P_MISSING=$(diff $1/$PKG_FILE $TMPFILE | egrep "^>" \
		| cut -d\ -f2)
	else
		print "  $2 is a sparse zone, packages can't be modified."
	fi

	# Any packages to change?

	if [[ -z "${P_EXTRA}$P_MISSING" ]]
	then
		print  "  Packages do not need modifying."
		return
	fi

	# We may need to add packages

	if [[ -n $P_EXTRA ]]
	then
		
		for pkg in $P_EXTRA
		do
			print -n "  installing ${pkg}: "
			
			if [[ -d ${PKG_DIR}/$pkg ]]
			then
				pkgadd -R $(get_zone_root_dir $2) \
				-d $PKG_DIR -n -a $ADMIN_FILE $pkg >/dev/null 2>&1 \
					&& print "ok" || inc_error
			else
				print "not found"
			fi

		done

	fi

	# We may need to remove packages

	if [[ -n $P_MISSING ]]
	then

		for pkg in $P_MISSING
		do
			print -n "  removing package ${pkg}: "
			pkgrm -R $(get_zone_root_dir $2) -n -a $ADMIN_FILE $pkg \
			>/dev/null 2>&1 \
				&& print "ok" || inc_error
		done

	fi

}

function rec_files
{
	# Copy archived files back into a zone

	# $1 is the directory to find the files in
	# $2 is the zone

	print -n "  restoring files to zone ${2}: "

	cd "${1}/root"

	tar -cf - . \
		| ( cd $(get_zone_root_dir $2); tar -xf -)  \
		&& print "ok" || inc_error
}

function rec_sched_class
{
	
	# Set the scheduling class. Only makes sense in a global zone. 
	# $1 is the directory where we find the archive file

	SFILE="${1}/sched_class"

	if [[ -s $SFILE ]]
	then
		print -n "  restoring default scheduling class: "

		dispadmin -d $(cat $SFILE) \
			&& print "ok" || inc_error
	fi
}

function rec_svcs
{
	# Restore the state of the SMF repository.

	# $1 is the directory to find the old service list in
	# $2 is the zone

	print "  restoring SMF services for $2"

	# Do we have the svccfg "restore" command. At the time of writing it's
	# only in OpenSolaris, but it should be in 5.10 at some point.

	if [[ -s ${1}/$SMF_ARC_FILE ]] && svccfg restore 2>&1 | egrep -s Syntax 
	then
		
		# We have it, but we know it's a bit of a dangerous thing. Let's ask
		# the user if he wants to use it. I refuse to bow to the current
		# trend for calling the unknown user "she". This is a Unix system
		# administration script. Let's be honest, the user's going to be a
		# man.

		cat<<-EOMSG 

--------------------------------------------------------------------------------

   This system has the ability to restore the archived contents of the SMF
   repository with the 'svccfg restore' command. This is a potentially
   dangerous operation unless the current revision and patch level of the OS
   is the same as it was when the DR information was taken.

--------------------------------------------------------------------------------

		EOMSG
		read "userest?Do you want to do a full svccfg restore? [no] "
	
		[[ $userest == "y"* ]] && USE_ARCHIVE=true
	fi

	if [[ -n $USE_ARCHIVE ]]
	then
		# This is the new-fangled svccfg restore command

		# If it's a local zone, we copy the XML archive to the zone, and run
		# the restore from there.  If I understand the docs correctly, this
		# is safer than referring to a local zone's repository from the
		# global zone. It's still potentially unsafe though, if moving from
		# one patch level to another.

		if [[ $2 == global ]]
		then
			ARC_DIR=$1
		else
			cp "${1}/$SMF_ARC_FILE" $(get_zone_root_dir $2)
			ARC_DIR="/"
		fi
		
		print -n "  restoring SMF manifest archive: "

		zone_run "svccfg restore ${ARC_DIR}/$SMF_ARC_FILE" $2 \
			&& print "ok" || inc_error

		if [[ $2 != global ]]
		then
			print "  rebooting zone"
			zoneadm -z $2 reboot
			rm -f /$SMF_ARC_FILE
		fi

	else

		# This is the old-school, "safe" way of restoring the SMF state.

		# First, import any services we archived, assuming they're not there
		# already

		ls ${1}/${SMF_SVC_BASE}* 2>/dev/null | while read svc
		do
			print -n "  importing service from ${svc##*/}: "

        	svccfg -f - <<-EOSVCCFG
				repository $(get_zone_root_dir $2)/etc/svc/repository.db
				import $svc
			EOSVCCFG

			[[ $? == 0 ]] && print "ok" || inc_error

		done

		# Get a sorted list of current services and the old services. Has to
		# be sorted so the diff output makes sense

		zone_run "svcs -Ho fmri" $2 | sort -u >${TMPFILE}.svc.exist

		sort -u ${1}/$SMF_SVCS_FILE >${TMPFILE}.svc.require

		diff ${TMPFILE}.svc.exist ${TMPFILE}.svc.require \
			| egrep ">|<" | sort | while read line
		do
			svc="${line#* }"
	
			# No point trying to manage legacy services through svcadm

			[[ $svc == "lrc"* ]] && continue

			if [[ $line == "<"* ]]
			then
				print -n "    disabling service ${svc}: "

				zone_run "svcadm disable $svc" $2 \
					&& print "ok" || inc_error

			else
				print -n "    enabling service ${svc}: "

				zone_run "svcadm enable $svc" $2 \
					&& print "ok" || inc_error
			fi

		done 

		rm -f ${TMPFILE}.svc.exist ${TMPFILE}.svc.require

	fi
}

function clean_up
{
	# This function is run at the end of the script, or by a trap

	rm -f $TMPFILE $ADMIN_FILE $LOCK_FILE
}

function catch_int
{
	# Catches an INT signal. Cleans up and reports what happened.

	clean_up
	die "Interrupted by user."
}

#-----------------------------------------------------------------------------
# SCRIPT STARTS HERE

# If the user hits Ctrl-C, clean up the temp and lock files

trap 'catch_int' INT 

# We want to be silent if we're running from cron. If you turn off stdout
# altogether, you get errors. It seems safe to turn off stderr though.

is_cron &&
	{ exec >/dev/null; exec 2>&-; }

# See if we've been asked for the version. Do this before we bother to start
# checking UIDs and whatnot

if [[ $1 == "-V" ]]
then
	print "$MY_VER"
	exit 0
fi

# If we're already running, don't run

if [[ -f $LOCK_FILE ]]
then
	die \
	"Lock file [${LOCK_FILE}] says script is running. PID=$(cat $LOCK_FILE)"
fi

# We need to be root

is_root || die "script can only be run as root"

is_global || die "script can only be run from global zone"

if [[ $1 == "archive" ]]
then
	# Do a shift to get rid of the argument we just parsed

	shift

#- ARCHIVE MODE --------------------------------------------------------------

	while getopts "d:N:R:s:z:" option 2>/dev/null
	do

		case $option in 

			"d")	# Override default OUTDIR
					BASEDIR=$(qualify_path $OPTARG)
					;;

			"R")	# Get information for SCP
					SCP_STR=$OPTARG
					;;

			"N")	 # Get information for NFS
					NFS_STR=$OPTARG
					;;

			"s")	SMF_PTN=$OPTARG
					;;

			"z")	ZONELIST="$(print $OPTARG | tr , \ )"
					;;

			*)		usage

		esac

	done

	shift $(($OPTIND - 1))

	# Make sure we have the directories we need. 

	OUTDIR="${BASEDIR}/$(uname -n)"

	mkdir -p $OUTDIR

	[[ -d $OUTDIR && -r $OUTDIR ]] \
		|| die "can't write to output directory [${OUTDIR}]"

	# We're finally about to do some work, so create the lock file

	print $$ >$LOCK_FILE

	print "writing files in $OUTDIR"

	# Get the disklist. We need this for a couple of things

	DISKLIST=$(print | format | \
	sed -n '/[0-9]\. /s/.* [0-9]\. \([^ ]*\).*$/\1/p') 

	if can_has zoneadm
	then

		# Get a list of zones. If we haven't been given one, assume the user
		# wants to archive ALL zones that are running. If the user supplied
		# the list, then Set a variable called CHECK, to make the script
		# check the given zone exists

		[[ -z $ZONELIST ]] \
			&& ZONELIST=$(zoneadm list) \
			|| CHECK=1

		# Run all the zone tests, assuming the zone exists. We don't treat
		# the global zone any differently from the local ones. The
		# intelligence is in the arc_ functions. 

		for zone in $ZONELIST
		do
			if [[ -n $CHECK ]]
			then
				
				if ! zoneadm -z $zone list >/dev/null 2>&1
				then
					print "WARNING zone $zone does not exist"
					continue
				fi

			fi

			run_archive $zone
		done
	else
		run_archive global
	fi

	# Did we have any errors? If we did, write to the system log 

	[[ $ERRS -gt 0 ]] && \
		log "encountered $ERRS errors whilst archiving" err

	# Now copy the files, if we've been asked to

	if [[ -n $SCP_STR ]]
	then
		print -n "\ncopying files to ${SCP_STR#*@} as ${SCP_STR%:*}: "

		if scp -rqCp $OUTDIR $SCP_STR
		then
			print "ok"
			ARCHIVED="${SCP_STR#*@} as ${SCP_STR%:*}"
		else
			print "failed"
			EXIT=1
			log "failed to scp DR files to $SCP_STR" err
		fi

	fi

	# Copy over NFS if we've been asked to. There's no reason why we can't
	# do this as well as SCP. I suppose you could use it as a backup if the
	# scp failed.

	if [[ -n $NFS_STR ]]
	then
		print -n "\ncopying files to ${NFS_STR}: "

		if cp -Rp $OUTDIR $NFS_STR
		then
			print "ok" 
			ARCHIVED=$NFS_STR
		else
			print "failed"
			EXIT=1
			log "failed to copy DR files to $NFS_STR" err
		fi

	fi

	# If we archived the files, say so

	[[ -n $ARCHIVED ]] && is_cron \
		&& log "archived DR data on $ARCHIVED. [$ERRS errors]"

	# That's everything

elif [[ $1 == "restore" ]]
then

#- RESTORE MODE --------------------------------------------------------------

	# By default we're going to restore the DR files

	RES_DR=true

	# Do a shift to chop off the arg that got us here

	shift

	while getopts "d:Fnp:Nz" option 2>/dev/null
	do

		case $option in 

			"d")	# Set the source directory
					BASEDIR=$(qualify_path $OPTARG)
					;;

			"F")	FORCE=true
					;;

			"N")	unset RES_DR
					;;

			"p")	PKG_DIR=$OPTARG
					;;

			*)		usage

		esac
	done

	# Discard all the options, and make sure we have one argument left --
	# the name of the zone to restore

	shift $((OPTIND - 1))

	[[ $# != 1 ]] && usage

	# A couple of sanity checks

	ZONE=$1

	[[ -d $BASEDIR ]] || die "no directory $BASEDIR"

	# We need an admin file if we have to add or remove packages. Create it
	# anyway - it's free

	ADMIN_FILE="${TMPFILE}.admin"

	can_has pkginfo && cat <<-EOF >$ADMIN_FILE
		mail=
		instance=unique
		partial=nocheck
		runlevel=nocheck
		idepend=nocheck
		rdepend=nocheck
		space=nocheck
		setuid=nocheck
		conflict=nocheck
		action=nocheck
		networktimeout=1
		networkretries=0
		authentication=quit
		keystore=/var/sadm/security
		proxy=
		basedir=default
	EOF

	# Now make sure that the zone we want to restore is on this host, and in
	# the BASEDIR
	
	zoneadm -z $ZONE list >/dev/null 2>&1 \
		|| die "zone $ZONE does not exist on server"
	
	if [[ -n $RES_DR ]]
	then
		SRC="${BASEDIR}/$(uname -n)/$ZONE"
	
		[[ -d $SRC ]] \
			|| die "no DR information for $ZONE in $SRC"

		[[ -z $FORCE ]] \
			&& read "restore?really restore DR files for ${ZONE}? "

		# Now do the restore, assuming we have the all-clear

		print $$ >$LOCK_FILE
	
		if [[ x$restore == "xy" || -n $FORCE ]]
		then
			print "restoring $ZONE from $SRC"
			run_restore $ZONE $SRC
		fi
	fi

else
	usage
fi

clean_up

exit $ERRS
