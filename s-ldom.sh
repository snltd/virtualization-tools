#!/bin/ksh
#=============================================================================
#
# s-ldom.sh
# ---------
#
# Build, clone, and destroy Logical Domains.
#
# Currently only supports guest domains using ZFS zvols as their disks.
# Allows configuration of a single NIC and single disk per domain. This will
# change.
#
# Tested on a Solaris 10 update 10 T2000.
#
# R Fisher 03/12. See http://snltd.co.uk/scripts/s-ldom.php
#
# v1.0  Initial release
#
# v1.1  Added new "setup-primary" mode. Able to calculate free memory even
#       when it's "fragmented". No longer assume we're booting off a ZVOL,
#       so remove default boot ZVOL size. Write spconfig when a domain is
#       created or destroyed, unless '-t' flag is used.  Now maps multiple
#       network interfaces with -i, and properly identifies their MAC
#       addresses. Allows usage of disks for LDOM boot device with -D
#       option. RDF 03/05/12
#
#=============================================================================

#-----------------------------------------------------------------------------
# VARIABLES

PATH=/bin:/usr/sbin
	# Always set your path

MY_VER="1.1"

ZFSROOT="space/ldm"
	# The ZFS dataset under which the storage will be created. This must
	# exist

VDS="primary-vds"
	# The name of the virtual disk server in the primary domain

VCC="primary-vcc"
	# The name of the virtual console server in the primary domain

SPCONFIG="basic-conf"
	# The name we use for the spconfig - always

LDM_VARLIST="auto-boot\?=true \
	local-mac-address\?=true"
	# Variables to set in guest OBPs, whitespace separated

typeset -u MEMORY BOOT_SIZE

VCPUS=8			# Default number of VCPUs for guest - override with -v
MAUS=2			# Default number of MAUs for guest - override with -M
MEMORY="4G"		# Default amount of memory for guest - override with -m

#-----------------------------------------------------------------------------
# FUNCTIONS

die()
{
	# Exit function

	[[ -n $1 ]] && print -u2 "ERROR: $1" || print "FAILED"

	exit ${2:-1}
}

usage()
{
	I_AM=${0##*/}
	cat<<-EOUSAGE

	$I_AM create|clone [-v cpus] [-m size] [-M maus] [-e var,var] [-t]
	     [-NC] <-B size|-D device> [-s snapshot] -i NIC_list domain

	$I_AM destroy [-Fa]

	$I_AM setup-primary

	$I_AM free

	$I_AM -V

	create/clone mode:

	  -B :  in create mode, size of boot virtual disk. Requires suffix (e.g. G)
	  -D :  in create mode, raw device for domain boot disk
	  -N :  create VSW on physical NIC if it does not exist
	  -e :  OBP variables, key=value, comma-separated
	  -m :  amount of memory. Requires suffix (e.g. G)
	  -v :  number virtual CPUs to allocate to guest
	  -M :  number of MAUs to allocate to guest
	  -i :  comma separated list of datalinks through which guest communicates
	  -C :  connect to domain console when started
	  -s :  in clone mode, a ZFS snapshot from which to create the boot disk
	  -t :  don't write the spconfig
	  -V :  print version and exit

	destroy mode:

	  -F :  do not ask for confirmation before destroying domain
	  -a :  also destroy all filesystems belonging to domain

	EOUSAGE
}

domain_exists()
{
	# $1 is the domain

	ldm ls $1 >/dev/null 2>&1
}

create_ldom_hardware()
{
	# Do the basic allocation of resources to a new guest domain
	# $1 is the number of VCPUs
	# $2 is the number of MAUUs
	# $3 is the amount of memory
	# $4 is the domain name

	print -n "Creating domain '$4': "
	ldm add-domain $4 && print "ok" || die

	print -n "  assigning $1 VCPU(s): "
	ldm add-vcpu $1 $4 && print "ok" || die

	print -n "  assigning $2 MAU(s): "
	ldm add-mau $2 $4 && print "ok" || die

	print -n "  assigning $3 memory: "
	ldm add-mem $3 $4 && print "ok" || die
}

create_zvol()
{
	# Create a new boot disk of a given size
	# $1 is the size
	# $2 is the disk path

	print "\nCreating storage under '$ZFSROOT'"
	print -n "  creating $1 disk at '$2': "

	if zfs list $2 >/dev/null 2>&1
	then
		print "already exists - skipping"
	else
		zfs create -V $1 $2 && print "ok" || die
	fi
}

clone_zvol()
{
	# Clone a new boot disk from an existing snapshot
	# $1 is the dataset to clone
	# $2 is the disk path

	print -n "\nCloning '$1' to '$2': "

	if zfs list $2 >/dev/null 2>&1
	then
		print "already exists - skipping"
	else
		zfs clone $1 $2 && print "ok" || die
	fi
}

create_ldom_disk()
{
	# Map a disk for use in the LDOM
	# $1 is the disk path
	# $2 is the disk name
	# $3 is the LDM
	
	print -n "  creating VDS device '${2}': "

	if ldm ls-bindings -p | egrep -s "|vol=${2}|"
	then
		print "already exists - skipping"
	else
		ldm add-vdsdev $1 ${2}@$VDS && print "ok" || die
	fi
	
	print -n "  mapping disk to ${VDS}: "
	ldm add-vdisk $2 ${2}@$VDS $3 && print "ok" || die

	print -n "  setting boot-device: "
	ldm set-variable boot-device=$2 $3 && print "ok" || die
}

create_ldom_network()
{
	# Configure networking for new guest domain
	# $1 is the VSW to use
	# $2 is the VNIC name
	# $3 is the LDOM

	print -n "\nConfiguring virtual NIC '$2' on switch '$1': "
	ldm add-vnet $2 $1 $3 && print "ok" || die
}

create_vsw()
{
	# Create a virtual switch on the given physical NIC. The naming
	# convention is 'vsw-NIC'
	# $1 is the physical NIC

	VSW="vsw-$1"

	print -n "\nCreating VSW '$VSW' on physical NIC ${1}: "
	ldm add-vsw net-dev=$1 $VSW primary && print "ok" || die
}

set_ldom_variables()
{
	# Set LDOM OBP variables
	# $1 is the LDM, all other args are variables

	typeset domain=$1
	shift

	for var in $*
	do
		print -n "  setting '$var': "
		ldm set-variable "$var" $domain && print "ok" || die
	done
}

bind_ldom()
{
	# Bind the domain and start it
	# $1 is the LDM
	
	print -n "\nbinding domain: "
	ldm bind-domain $1 && print "ok" || die

	print -n "starting domain: "
	ldm start-domain $1 >/dev/null && print "ok" || die

	port=$(ldm ls -p $1 | cut -d\| -f5 | sed '1d;s/cons=//')

	print "\nConsole on port $port"

	ldm ls-bindings -p $1 | sed -n \
	'/^VNET/s/^.*vice=\([^|]*\).*addr=\([^|]*\).*$/MAC address: \2 (\1)/p'

	if [[ -n $CONNECT_TO_PORT ]]
	then
		print "  connecting...\n\n"
		telnet 0 $port
	fi

}

store_ldom_config()
{
	# Write the LDOM configuration
	
	[[ -n $NO_SP_WRITE ]] && return

	if ldm ls-spconfig | egrep -s "^$SPCONFIG"
	then
		print -n "\nClearing old spconfig '$SPCONFIG': "
		ldm rm-spconfig $SPCONFIG
	fi
		
	print -n "\nWriting spconfig '$SPCONFIG': "
	ldm add-spconfig $SPCONFIG && print "ok" || die
}

get_vsw()
{
	# Get the virtual switch bound to a given NIC
	# $1 is the NIC

	if dladm show-linkprop $1 >/dev/null 2>&1
	then
		ldm ls-bindings -p | sed -n "/net-dev=$1/s/VSW|name=\([^|]*\).*$/\1/p"
	else
		die "invalid NIC. [$nic]"
	fi

}

get_free_resources()
{
	# Get the free resources. They go into global variables

	_FREE_VCPUS=$(ldm ls-devices -p | grep -c "|pid=")
	_FREE_MAUS=$(ldm ls-devices -p | grep -c "|id=")
	_FREE_MEM=$(ldm ls-devices -p memory | sed -n '/size=/s/^.*size=//p')
	
	if [[ -z $_FREE_MEM ]]
	then
		_FREE_MEM=0
		_FREE_MEM_G=0
	else
		# Memory can get fragmented and be reported on multiple rows (at
		# least in ldm 1.4)

		_FREE_MEM=$(print "0 $(ldm ls-devices -p memory \
		| sed -n '/size=/s/^.*size=/+/p' | tr "\n" ' ')" | bc)
		_FREE_MEM_G=$(print "scale=2;$_FREE_MEM / 1073741824" | bc)
	fi
}

get_domain_state()
{
	# print the state of the domain given by $1

	ldm ls -p $1 | cut -d\| -f3 | sed '1d;s/state=//'
}

#-----------------------------------------------------------------------------
# SCRIPT STARTS HERE

# A couple of checks

[[ $(uname -m) != "sun4v" ]] && die "hardware does not support LDOMs."

whence ldm 2>&1 >/dev/null || die "system does not support LDOMs."

# Get the mode, then chop it off the args list to getopts works

[[ -z $1 ]] && die "no mode provided. [-h for help]"

MODE=$1
shift $(( $OPTIND ))

if [[ $MODE == "create" || $MODE == "clone" ]]
then

#- CREATE/CLONE --------------------------------------------------------------

	while getopts "B:CD:e:m:M:Ni:s:tv:V" option
	do

		case $option in
			
			B)	BOOT_SIZE=$OPTARG
				;;

			C)	CONNECT_TO_PORT=1
				;;

			D)	BOOT_DEVICE=$OPTARG
				unset BOOT_SIZE
				;;

			e)	EXTRAVARS="$(print $OPTARG | tr , ' ')"
				;;

			i)	NICLIST=$(print $OPTARG | tr , ' ')
				;;

			m)	MEMORY=$OPTARG
				;;

			M)	MAUS=$OPTARG
				;;

			N)	CREATE_VSW=1
				;;

			s)	SRC_ZFS=$OPTARG
				;;

			t)	NO_SP_WRITE=1
				;;

			v)	VCPUS=$OPTARG
				;;

			V)	print $MY_VER
				exit 0
				;;

			*)	die "invalid option"
				;;
		esac

	done

	shift $(($OPTIND - 1))

	# Check args

	[[ -n $1 ]] && LDM=$1 || die "no domain name supplied."

	# Can only have one of -D and -B

	[[ -n $BOOT_DEVICE && -n $BOOT_SIZE ]] \
		&& die "-B and -D options are mutually exclusive"

	# Check NICs

	if [[ -n $NICLIST ]]
	then

		for nic in $NICLIST
		do
			dladm show-link $nic >/dev/null 2>&1 || die "invalid NIC. [$nic]"
		done

	else
		die "no NIC supplied"
	fi

	# If we're not assigning a disk device, check for ZFS
	
	if [[ -z $BOOT_DEVICE ]]
	then
		whence zpool >/dev/null 2>&1 || die "system does not support ZFS."

		zfs list $ZFSROOT >/dev/null 2>&1 \
			|| die "ZFS dataset '$ZFSROOT' does not exist."
	
	fi

	# Does the domain exist already?

	domain_exists $LDM && die "domain '$LDM' already exists."

	# Do the VCPUS, MAUS, and memory look okay? We check the requested
	# resources are available, so find out what's free. The function writes
	# to global variables

	get_free_resources

	print $VCPUS | egrep -s "^[0-9]+$" \
		|| die "invalid number of VCPUs. [$VCPUS]"

	(( $VCPUS > $_FREE_VCPUS )) && die "only $_FREE_VCPUS VCPUs available"

	print $MAUS | egrep -s "^[0-9]+$" || die "invalid number of MAUs. [$MAU]"

	(( $MAUS > $_FREE_MAUS )) && die "only $_FREE_MAUS MAUs available"

	print $MEMORY | egrep -s "^[0-9]+G$" || die "invalid memory. [e.g. 10G]"

	(( ${MEMORY%G} > $_FREE_MEM_G )) && die "only ${_FREE_MEM_G}G available."

	# If we're cloning, do we have a source domain?

	if [[ $MODE == "clone" ]]
	then
		
		if [[ -z $SRC_ZFS ]]
		then
			die "clone mode requires -s option."
		else
			zfs list $SRC_ZFS >/dev/null 2>&1 \
				|| die "source snapshot '$SRC_ZFS' does not exist."
		fi

	elif [[ -n $SRC_ZFS ]]
	then
		die "-s option redundant in create mode."
	fi

	# If the physical interface exists, get the VSW on it. Make a list of
	# nic:vswitch_name:vnic_name chunks

	for nic in $NICLIST
	do
		vsw=$(get_vsw $nic)
		vnicname="${LDM}-vnet-$nic"

		if [[ -z $vsw ]]
		then

			[[ -n $CREATE_VSW ]] \
				&& create_vsw $nic \
				|| die "no vswitch associated with $nic. (-N creates one.)"

			vsw=$(get_vsw $nic)
		fi

		VSWLIST="$VSWLIST $vsw"
		VNICNAMELIST="$VNICNAMELIST $vnicname"
		NICDAT="$NICDAT ${nic}:${vsw}:$vnicname"
	done

	if [[ -n $BOOT_SIZE ]]
	then

		# We're making a boot disk. Does the description look sane?

		print $BOOT_SIZE | egrep -s "^[0-9]+G" \
			|| die "invalid boot disk size [e.g. 20G]"
	
		LDM_BOOT="${ZFSROOT}/${LDM}-boot"
	elif [[ -n $BOOT_DEVICE ]]
	then
		
		# We're mapping a boot device

		LDM_BOOT="/dev/dsk/$BOOT_DEVICE"
		[[ -a $LDM_BOOT ]] || die "invalid boot device"
	elif [[ $MODE == "clone" ]]
	then
		# We're cloning a snapshot.

		LDM_BOOT="${ZFSROOT}/${LDM}-boot"
	else
		die "Don't know what to do for a boot device."
	fi

	cat<<-EODEF

	The following logical domain will be ${MODE}d:"

	                     name : $LDM
	             virtual CPUs : $VCPUS
	                     MAUs : $MAUS
	                   memory : $MEMORY
	         physical link(s) : $NICLIST
	       virtual switch(es) : ${VSWLIST# *}
	           virtual nic(s) : ${VNICNAMELIST# *}
	              boot device : $LDM_BOOT
	EODEF

	if [[ $MODE == "clone" ]]
	then
		print "      source root dataset : $SRC_ZFS"
	elif [[ -n $BOOT_SIZE ]]
	then
		print "           boot disk size : $BOOT_SIZE"
	fi

	print
	
	create_ldom_hardware $VCPUS $MAUS $MEMORY $LDM

	for nic in $NICDAT
	do
		print $nic | tr ":" " " | read nicname vsw vnicname
		create_ldom_network $vsw $vnicname $LDM
	done

	if [[ $MODE == "clone" ]]
	then
		clone_zvol $SRC_ZFS $LDM_BOOT
		LDM_BOOT_DEV=/dev/zvol/dsk/$LDM_BOOT
	elif [[ -n $BOOT_SIZE ]]
	then
		create_zvol $BOOT_SIZE $LDM_BOOT 
		LDM_BOOT_DEV=/dev/zvol/dsk/$LDM_BOOT
	else
		LDM_BOOT_DEV=$LDM_BOOT
	fi

	create_ldom_disk $LDM_BOOT_DEV "${LDM}-boot" $LDM

	set_ldom_variables $LDM $LDM_VARLIST $EXTRAVARS

	bind_ldom $LDM

	store_ldom_config

elif [[ $MODE == "destroy" ]]
then
	# Does the domain exist?

	while getopts "Fa" option
	do

		case $option in
			
			a)	ALL_DISKS=1
				;;

			F)	FORCE=1
				;;
		esac
	
	done

	shift $(($OPTIND - 1))

	[[ -n $1 ]] && LDM=$1 || die "no domain supplied."

	domain_exists $LDM || die "domain '$LDM' does not exist."

	# We need to get the VDS devices that belong to this domain
	
	VDSS=$(ldm ls-bindings -p $LDM | sed -n \
	'/VDISK/s/^.*|name=\([^|]*\).*$/\1/p')

	VDSDEVS=$(ldm ls-bindings -p $LDM | sed -n \
	'/VDISK/s/^.*|vol=\([^|]*\).*$/\1/p')

	# Have we been asked to remove all the virtual disks?

	if [[ -n $ALL_DISKS ]]
	then
		
		for vds in $VDSS
		do
			ZFS_RM_LIST=" $ZFS_RM_LIST $(ldm ls-bindings -p primary \
			| sed -n "/|vol=$vds/s/^.*dev=\([^|]*\).*\$/\1/p" \
			| sed \ 's|/dev/zvol/dsk/||')"
		done

	fi

	if [[ -n $ZFS_RM_LIST ]]
	then
		print "The following ZFS datasets will be destroyed:\n"

		for fs in $ZFS_RM_LIST
		do
			zfs list $fs >/dev/null 2>&1 && print "  $fs"
		done
		print
	fi

	# Make sure the user really wants to do this

	[[ -z $FORCE ]] && read "remove?really remove domain '${LDM}'? "

	[[ $remove == "y" || -n $FORCE ]] || exit 0

	print "removing domain '$LDM'"

	# Make sure it's stopped

	if [[ $(get_domain_state $LDM) == "active" ]]
	then
		print -n "  stopping domain: "
		ldm stop $LDM >/dev/null && print "ok" || die
	fi

	if [[ $(get_domain_state $LDM) == "bound" ]]
	then
		print -n "  unbinding domain: "
		ldm unbind-domain $LDM && print "ok" || die
	fi

	print -n "  destroying domain: "
	ldm destroy $LDM && print "ok" || die

	if [[ -n $ZFS_RM_LIST ]]
	then
		print "\ndestroying ZFS datasets"
		
		for fs in $ZFS_RM_LIST
		do
			print -n "  ${fs}: "
			zfs destroy $fs && print "ok" || die
		done

	fi

	print "\ncleaning up VDSdevs"

	for dev in $VDSDEVS
	do
		print -n "  ${dev}: "
		ldm rm-vdsdev $dev && print "ok" || die
	done

	store_ldom_config

elif [[ $MODE == "free" ]]
then
	get_free_resources

	cat <<-EOFREE
	   free VCPUs: $_FREE_VCPUS
	    free MAUs: $_FREE_MAUS
	  free memory: ${_FREE_MEM_G}Gb (${_FREE_MEM}b)
	EOFREE
elif [[ $MODE == "setup-primary" ]]
then
	print -n "Creating control LDOM\n  assigning 4 x VCPU: "
	ldm set-vcpu 4 primary >/dev/null && print "ok" || die
	print -n "  assigning 2G memory: "
	ldm set-mem 2G primary >/dev/null && print "ok" || die
	print -n "  assigning one MAU: "
	ldm set-mau 1 primary >/dev/null && print "ok" || die
	print -n "  setting VCC port range to 5000-5100 on '$VCC': "
	ldm add-vcc port-range=5000-5100 $VCC primary >/dev/null \
		&& print "ok" || die
	print -n "  creating virtual disk server '$VDS': "
	ldm add-vds $VDS primary >/dev/null && print "ok" || die
	print -n "\nControl domain created."

	store_ldom_config

	cat<<-EOMSG

==============================================================================

  The control domain is configured. Note that no virtual switches have been
  created - this script creates them as they are required by new domains.
	
  To complete configuration, reboot the server with 'init 6'.

==============================================================================

	EOMSG
else
	usage
	exit 2
fi

