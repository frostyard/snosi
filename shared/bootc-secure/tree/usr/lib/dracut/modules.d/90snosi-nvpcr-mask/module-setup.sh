#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck disable=SC2154 # $initdir comes from dracut's module environment.

# snosi#1378: dracut 113's 11systemd-pcrextend copies NvPCR definitions
# into the initrd. The rootfs FinalizeScript runs after the initramfs is
# built, so its masks do not reach the initrd. snosi UKIs do not have an
# initrd NvPCR policy (ukify --sign-initrd-pcrs).

check() {
    return 255
}

depends() {
    return 0
}

install() {
    # Dracut installs modules in sorted modules.d order, so prefix 90 runs
    # after 11systemd-pcrextend. test/bootc-secure-artifact-test.sh checks
    # the resulting masks in the UKI.
    local definition
    for definition in "$initdir"/usr/lib/nvpcr/*.nvpcr; do
        [[ -e "$definition" || -L "$definition" ]] || continue
        mkdir -p "$initdir/etc/nvpcr" || return 1
        ln -sfn /dev/null "$initdir/etc/nvpcr/${definition##*/}" || return 1
    done
}
