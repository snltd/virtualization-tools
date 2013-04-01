Scripts to help with Unix (probably Solaris) administration. Documentation
is in the wiki pages, but briefly:

In the top-level directory:

 * `s-dr.sh`: backs up key system files for rudimentary DR
 * `s-ldom.sh`: creates, clones, and destroys logical domains.
 * `s-zone.sh`: creates, clones and destroys Solaris zones.
 * `un`: unpacks archives of various types
 * `zonedog.sh`: a watchdog that ensures vital zones are running

In the zfs/ subdirectory:

 * `zfs_real_usage.sh`: shows how much space datasets and snapshots really use
 * `zfs_remove_snap.sh`: batch remove ZFS snapshots
 * `zfs_scrub.sh`: wrapper to 'zpool scrub'
 * `zfs_send_stream.sh`: recursively send ZFS datasets on machines too old to
  have `zfs send -R`.
 * `zfs_snapshot.sh`: batch snapshotter
