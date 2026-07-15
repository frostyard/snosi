#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later

# shellcheck source=/dev/null
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

getargbool 0 rd.etc.overlay || exit 0

sysroot="${NEWROOT:-/sysroot}"
var_device="$(getarg rd.etc.overlay.var=)"
if [ -z "$var_device" ]; then
    var_device=/dev/mapper/var
    raw_var_device=/dev/disk/by-partlabel/var
fi

info "snosi-etc-overlay: waiting for persistent /var at $var_device"
udevadm settle --timeout=30 2>/dev/null || true
if [ ! -e "$var_device" ] && [ -n "${raw_var_device:-}" ] && \
        [ "$(blkid -p -s TYPE -o value "$raw_var_device")" = crypto_LUKS ]; then
    info "snosi-etc-overlay: unlocking encrypted persistent /var"
    /usr/lib/systemd/systemd-cryptsetup attach var "$raw_var_device" - \
        tpm2-device=auto || die "snosi-etc-overlay: failed to unlock persistent /var"
fi
[ -e "$var_device" ] || var_device="${raw_var_device:-$var_device}"
[ -e "$var_device" ] || die "snosi-etc-overlay: persistent /var device not found"
[ -d "$sysroot/.etc.lower" ] || die "snosi-etc-overlay: immutable lower /etc is missing"

mkdir -p "$sysroot/var"
if ! mountpoint -q "$sysroot/var"; then
    mount -t ext4 "$var_device" "$sysroot/var" || \
        die "snosi-etc-overlay: failed to mount persistent /var"
fi

base="$sysroot/var/lib/snosi/etc-overlay"
mkdir -p "$base/upper" "$base/work" "$sysroot/etc"
mount -t overlay overlay \
    -o "lowerdir=$sysroot/.etc.lower,upperdir=$base/upper,workdir=$base/work" \
    "$sysroot/etc" || die "snosi-etc-overlay: failed to mount persistent /etc"

info "snosi-etc-overlay: persistent /var and /etc ready before switch-root"
