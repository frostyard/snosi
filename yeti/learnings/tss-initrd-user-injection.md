# tss initrd user injection

Issue: frostyard/snosi#309

mkosi runs `systemd-sysusers` after postinstall scripts, but the shared kernel postinstall builds initrd with dracut during postinstall. Dracut modules that ship tmpfiles or udev rules referencing packaged users therefore cannot rely on mkosi's later sysusers pass.

For the tpm2-tss initrd path, run `systemd-sysusers` idempotently before dracut, then use a small dracut module to copy the resolved `tss` passwd/group entries into `$initdir/etc/passwd` and `$initdir/etc/group`. This keeps the initrd UID/GID aligned with the final image while avoiding boot-time `Failed to resolve user 'tss'` noise.
