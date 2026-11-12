#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Build the initramfs with dracut and check that dracut resolved the shared
# library dependencies of its executables. Sourced by
# shared/kernel/scripts/postinst/mkosi.postinst.chroot.
#
# dracut 106 (Debian Trixie) finds the executables to resolve with
# `find "$initdir" ... -not -path '*.ko*'`. initdir is
# "<tmpdir>/dracut.XXXXXX/initramfs", so when the random suffix starts with
# "ko" every path matches, the resolve pass installs nothing and dracut still
# exits 0. That initramfs has no libc and no dynamic loader and cannot boot.
# dracut-ng fixed it in 109 with `-not -name '*.ko*'`:
# https://github.com/dracut-ng/dracut-ng/commit/5c53a810bbc983efeaec17d88ac06a697059a201
# A miss happens on about 1 build in 3844 (62 * 62 suffix starts). A new run
# draws a new temporary directory, so build_initramfs tries again.
set -euo pipefail

# Tries before build_initramfs fails. Three misses in a row happen about once
# in 5.7e10 builds; a failure then points to a real defect, not to the race.
BUILD_INITRAMFS_ATTEMPTS=${BUILD_INITRAMFS_ATTEMPTS:-3}

# initramfs_has_libc IMAGE
# The resolve pass is the only step that installs libc.so.6, so its presence
# in the listing proves that the pass ran. The multiarch directory is not
# fixed, so any usr/lib/<dir>/libc.so.6 counts.
initramfs_has_libc() {
    local image=$1 listing
    # Capture first: grep -q on a pipe can end lsinitrd with SIGPIPE, and
    # pipefail would then report a miss.
    listing=$(lsinitrd "$image") || return 1
    grep -Eq '(^|[[:space:]])usr/lib/[^[:space:]/]+/libc\.so\.6$' <<<"$listing"
}

# build_initramfs KERNEL_VERSION OUTPUT
build_initramfs() {
    local kver=$1 output=$2 attempt
    for ((attempt = 1; attempt <= BUILD_INITRAMFS_ATTEMPTS; attempt++)); do
        dracut --force --no-hostonly --reproducible --zstd --verbose \
            --kver "$kver" "$output"
        if initramfs_has_libc "$output"; then
            return 0
        fi
        echo "WARNING: initramfs attempt $attempt/$BUILD_INITRAMFS_ATTEMPTS has no libc.so.6:" \
            "dracut skipped dependency resolution (dracut-ng 5c53a810, fixed in 109)" >&2
    done
    echo "ERROR: $output has no libc.so.6 after $BUILD_INITRAMFS_ATTEMPTS dracut runs" >&2
    return 1
}
