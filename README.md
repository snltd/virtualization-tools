# Solaris Virtualization Tools

Scripts to help with administration of a virtualized Solaris setup.

## s-zone.sh

This script creates, clones and destroys zones. It was written to work
with Solaris 10, but it will work on most other SunOS systems which
handle zones. I use it on a mix of Solaris 10, Solaris 11 and OmniOS. I
don't think it would work on SmartOS, but they already have [something
better](https://github.com/joyent/smartos-live/blob/master/src/vm/man/vmadm.1m.md).

It's grown and grown, on the hoof, from being a small script used to
make simple zones, and it shows. I've added in what I needed, when I
needed it, usually in the quickest way that got the job done. The code
is absolutely horrible, and no kind of example to anyone on how to write
any kind of program. But, it's served me very well in a number of
production environments, since 2007.

[Documentation is
in the wiki](https://github.com/snltd/admin-scripts/wiki/s-zone.sh).

## s-ldom.sh

Creates, clones, and destroys logical domains on Sun T-series
systems. Works with Solaris 10 and Solaris 11.

The documentation is in [README_s-ldom.md]
(https://github.com/snltd/virtualization-tools/blob/master/README_s-ldom.md)

## s-dr.sh

A simple script which backs up key system files for rudimentary DR.
It works hand-in-hand with `s-zone.sh` to allow you to easily
rebuild lost zones.

[It is documented here in the
wiki](https://github.com/snltd/admin-scripts/wiki/s-dr.sh).

## zonedog.sh

A watchdog which ensures vital zones are running. Run it from
`cron`.
