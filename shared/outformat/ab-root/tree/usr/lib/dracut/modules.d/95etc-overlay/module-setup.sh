#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck disable=SC2154 # Variables are provided by dracut's module environment.

check() {
    return 0
}

depends() {
    echo "crypt rootfs-block systemd-veritysetup"
    return 0
}

install() {
    local service=snosi-etc-overlay-initrd.service
    local dropin=10-snosi-etc-overlay.conf

    inst_multiple mount mountpoint mkdir udevadm
    inst_simple "$moddir/etc-overlay-mount.sh" /usr/libexec/snosi-etc-overlay-initrd
    chmod 0755 "$initdir/usr/libexec/snosi-etc-overlay-initrd"
    inst_simple "$moddir/$service" "$systemdsystemunitdir/$service"
    inst_simple "$moddir/$dropin" \
        "$systemdsystemunitdir/initrd-root-fs.target.d/$dropin"
}

installkernel() {
    # btrfs alongside ext4: firn supports a btrfs /var (ADR-0008), and the
    # initrd must carry the driver to mount it before switch-root.
    instmods overlay ext4 btrfs
}
