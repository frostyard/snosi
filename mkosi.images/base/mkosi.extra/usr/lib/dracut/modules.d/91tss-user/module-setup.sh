#!/bin/bash
# shellcheck shell=bash disable=SC2154

# Issue #309 L23: the tpm2-tss dracut module ships tmpfiles/udev rules
# that reference the tss user, so copy the resolved NSS entries into initrd.

check() {
    return 0
}

depends() {
    echo systemd
}

install() {
    getent passwd tss >> "$initdir/etc/passwd" || :
    getent group tss >> "$initdir/etc/group" || :
}
