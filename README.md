# Solaris Virtualization Tools

Scripts to help with administration of a virtualized Solaris setup.

## s-zone.sh

This script creates, clones and destroys zones. It was written to
work with Solaris 10, but you can use it with most other SunOS
systems which handle zones. 

It's grown and grown from being a small script used to make simple
zones. Internally, it's not very nice, but it's served me very well
in a number of production environments.

[Documentation is
here](https://github.com/snltd/admin-scripts/wiki/s-zone.sh).

## s-ldom.sh 

Creates, clones, and destroys logical domains on Sun T-series
systems. Works with Solaris 10 and Solaris 11.

[Documentation is
here](https://github.com/snltd/admin-scripts/wiki/s-ldom.sh).

## s-dr.sh

A simple script which backs up key system files for rudimentary DR.
It works hand-in-hand with `s-zone.sh` to allow you to easily
rebuild lost zones.

[It is documented here in the
wiki](https://github.com/snltd/admin-scripts/wiki/s-dr.sh).

## zonedog.sh

A watchdog which ensures vital zones are running. Run it from
`cron`.
