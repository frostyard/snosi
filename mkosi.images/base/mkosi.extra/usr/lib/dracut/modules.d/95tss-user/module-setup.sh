#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck disable=SC2154 # $initdir and $dracutsysrootdir come from dracut's module environment.

# snosi#723: the tpm2-tss package ships /usr/lib/tmpfiles.d/tpm2-tss-fapi.conf
# and /usr/lib/udev/rules.d/60-tpm-udev.rules, both of which reference the `tss`
# user and group. On TPM-backed encrypted-root systems systemd-tmpfiles and
# systemd-udevd process those files inside the initrd (before switch-root), but
# dracut's tpm2-tss module does not carry the tss passwd/group entries into the
# initramfs. Early boot therefore logs a burst of
#     Failed to resolve user `tss`: Unknown user
# from tmpfiles and udev. It is non-fatal but persistent, and can mask genuine
# TPM/initrd failures. Carry the tss user and group into the initramfs so
# early-boot resolution succeeds.

check() {
    # Only makes sense when the image actually defines a tss user (created by
    # /usr/lib/sysusers.d/tpm2-tss.conf). If it does not, skip silently.
    grep -q '^tss:' "$dracutsysrootdir/etc/passwd" 2>/dev/null || return 1
    return 0
}

depends() {
    # tpm2-tss ships the tmpfiles/udev rules that reference tss and creates
    # /etc/passwd via systemd; install after it so the entries land last.
    echo tpm2-tss
    return 0
}

install() {
    grep '^tss:' "$dracutsysrootdir/etc/passwd" >> "$initdir/etc/passwd" || :
    grep '^tss:' "$dracutsysrootdir/etc/group" >> "$initdir/etc/group" || :
}
