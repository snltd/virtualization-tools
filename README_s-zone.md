
## Clone Mode

Caveats: You can clone a branded zone, but it doesn't **quite** work. A
Solaris 10 guest on a Solaris 11 host will not get its `sysidcfg` stuff
configured, so you'll have to manually configure networking. It will
probably have the same MAC address too, so you'll have to correct that
with `zonecfg`. It's such an unlikely use case that I'll
probably never fix this. Clone mode doesn't support the `-a` option,
but `-e` will work and fall through to using an `anet` interface anyway.


Running with the `-f` option will create new `/zonedata` filesystems for
the new zone. Omitting it causes the cloned zone to use the same `lofs`
mounted `/zonedata` filesystems as the source zone.

