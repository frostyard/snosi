# This sysext ships system units or system-unit drop-ins in
# /usr/lib/systemd/system. With this key, systemd-sysext reloads PID 1 after a
# merge or refresh, so PID 1 sees the new and changed unit files and the
# units start in the same boot, for example after "updex features enable
# --now". Without it, they start only after a reboot (snosi#1189). updex never
# runs daemon-reload itself (updex ADR-0019). mkosi keeps the keys of this
# file and adds the missing ones (ID, SYSEXT_ID, SYSEXT_SCOPE, ARCHITECTURE and
# the rest) after the postinst. The build-time guard
# shared/sysext/finalize/sysext-reload-manager-guard.sh requires this file for
# every sysext with a system unit. See docs/design/sysexts.md and
# docs/adr/0026-sysexts-with-system-units-reload-the-manager.md.
EXTENSION_RELOAD_MANAGER=1
