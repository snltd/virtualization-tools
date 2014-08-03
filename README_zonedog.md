# `zonedog.sh`

I have never been able to get to the bottom of why, but on some
machines, all zones don't always come back up on a reboot.

Hence, this simple watchdog script which runs from cron, and starts
non-running zones.

## Usage

    # zonedog.sh [-q] <zone>..<zone>

    # zonedog.sh [-hV]

where:

* **-q** suppresses all output (for use with cron)
* **-h** prints brief usage info
* **-V** prints the version of the script and exits

Arguments are a list of the zones you wish to ensure are running.

## Caveats

Zones are started in whatever order they come out of `zoneadm list`, so
no dependencies or priorities are honoured.

The script should be run in the global zone only, as a user with zone
admin privileges. It doesn't check to see that either of those things
are true.
