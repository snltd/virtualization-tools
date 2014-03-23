# s ldom.sh

s-ldom.sh is a script which creates, clones and destroys logical domains on
Solaris 10 and 11 hosts.

I find it useful to create a "gold" domain image by building a domain in
`create` mode, Jumpstarting it, then running `sys-unconfig` and destroying the
domain whilst leaving the root ZVOL in place. Then I can use `clone` mode to
very quickly create new domains which only need configuring.

## Requirements

A hypervisor equipped server running Solaris 10 or 11, with LDOM software
installed.  The script can be run in `setup-primary` mode to configure the
initial control domain. If you prefer not to do this, `s-ldom.sh` expects to
find a VCC called `primary-vcc` and a virtual disk server called `primary-vds`.

You need an existing ZFS pool for your virtual disks, if you intend to use
them. My default pool is called `space/ldm`. If you use a different path,
change the value of the `ZFSROOT` variable.

## Usage

`s-ldom.sh` is invoked with a command word, a list of options, and a domain
name. All operations require root privileges.

### `create` Mode and `clone` Mode

Both these modes are used to make a domain.

```
# s-ldom.sh create -v cpus -m size -M maus [-NCt] [-e var,var] <-B size|-D device> -i NIC_list domain

# s-ldom.sh clone -v cpus -m size -M maus [-NCt] [-e var,var] <-s snapshot> -i NIC_LIST domain
```

where:

* *`-v number`* Assign 'number' virtual CPUs to the guest domain. If this
number exceeds the number of unassigned VCPUs, an error is generated.
* *`-m memory`* Assign the given amount of memory to the guest domain. Requires
a 'G' as suffix. For instance, `-m 10g` to assign 10Gb. Other suffexes are not
currently supported. If the memory is not available, an error is generated.
*`-M number`* assign 'number' MAUs to the guest domain. If this number exceeds
the number of unassigned MAUs, an error is generated.
* *`-i NIC`* used to specify the physical interface to which the domain's
virtual NIC will be attached. If no virtual switch exists on the given NIC, an
error is generated, unless the `-N` option (see below) is also supplied, in
which case a new virtual switch is created.
* *`-N`* If this is set and `-i` is used to specify an interface which does not
have a virtual switch bound to it, then a virtual switch is created on that
NIC, named `vsw-NIC`, where `NIC` is the physical NIC name.
* *`-C`* Attach to the domain console, with `telnet` once the domain is
created.
* *`-B size`* Specifies the size of the ZVOL created for the boot disk. Only
applicable in `create` mode.
* *`-D device`* Specifies a raw device file to be used as a boot disk. Should
be in `cxtxdxs2` format; `/dev/rdsk/` is not required. Only applicable in
`create` mode, and incompatible with the `-B` option.
* *`-s snapshot`* Specifies a pre-existing ZFS dataset, containing a ZVOL, from
which to clone a new boot disk device. Only applicable in clone mode.
* *`-t`* Tells the script not to rewrite the system's `spconfig` once the
domain is created.
* *`-e KEY=VAL,`* A comma-separated list of OBP variables to set in the new
domain.


### `destroy` Mode

```
# s-ldom.sh destroy [-Fa] domain
```

where:

* *`-F`* Normally the user is asked to confirm that a domain is to be
destroyed. With this option, that confirmation is not sought.
* *`-a`* Not only destroys the domain, returning resources to the primary pool,
but also destroys any ZFS datasets belonging to that domain. If clones of those
datasets exist, an error will occur.

### `setup-primary` mode

This mode configures a machine to use LDOMs. It creates a primary, or control,
domain with 4 VCPUs, 1 MAU, and 2Gb of RAM.

```
# s-ldom.sh setup-primary
```

### Other Modes

```
# s-ldom.sh free
```

List CPUs, MAUs and memory not yet allocated to guest domains.

```
# s-ldom.sh -V
```

Print the version of `s-ldom.sh` and exit.

## Examples

Create a new domain `mydomain` with 8 VCPUs, 2 MAUs, 8Gb of RAM, and a 20Gb
root disk. The domain will be connected to the network through `e1000g1`, and
if no virtual switch is already attached to that interface, one will be
created.

```
# s-ldom.sh create -v8 -M2 -m 8G -i e1000g1 -B 20G -N mydomain
```

Destroy the domain `olddomain`, leaving the boot disk in place so the domain
can be re-instated at a later date by running the script in create mode.

```
# s-ldom.sh destroy -F olddomain
```

Create `mydomain` as above, but from a ZFS snapshot of a "gold" domain,
attaching to the console one creation is complete. Don't have it boot up
by default.

```
# s-ldom.sh clone -v8 -M2 -m 8G -i e1000g1 -e auto-boot\?=false -s space/ldom -N mydomain
```

## Limitations

The script has no concept of I/O domains, or handing PCI slots/controllers to
guests. It can only create domains whose boot disk is a ZVOL hosted by the
primary domain. This will probably not change until I work on a job where I
need to do one or more of these things.

For now, the script can only create domains with a single virtual NIC. Support
for multiple NICs is coming. Currently the script can only create a single
virtual disk for the domain, which is the root disk. The ability to create more
disks will be added in the future.

Cloning from  an existing boot disk requires you to create a ZFS snapshot
yourself.  This is unlikely to change.

## Supported Versions

`s-ldom.sh` was written and tested on a SunFire T2000 running Solaris 10 and
version 2.0 of the Logical Domain software. I have used it a few times on
Solaris 11, and with version 1 LDM software, but you attempt to do so at your
own risk. As ever, the software is supplied with no guarantees of any kind.
