#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static guard (frostyard/snosi#1326): the base presets must not enable the
# root instance of xfs_healer@.service. On forky its ExecCondition exits 255 on
# the composefs overlay root, so the unit fails at every boot.
#
# The test runs `systemctl --root` preset-all on a scratch root that holds the
# base image's real preset files, Debian's catch-all `enable *`, and stub units
# with the [Install] sections of forky's xfsprogs units. It then checks the
# enablement symlinks that first boot would create. A control run without the
# base presets must create the symlink, so the check cannot pass vacuously.
#
# No root, no network, no image build.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
presets="$root/mkosi.images/base/mkosi.extra/usr/lib/systemd/system-preset"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

make_root() { # dir with_base_presets(0|1)
    local dir="$1" units="$1/usr/lib/systemd/system"
    mkdir -p "$units" "$dir/usr/lib/systemd/system-preset" "$dir/etc"
    # [Install] sections as forky's xfsprogs 7.2.0-1 ships them.
    printf '%s\n' '[Unit]' 'Description=Self Healing of XFS Metadata for %f' \
        '[Service]' 'ExecStart=/bin/true' \
        '[Install]' 'WantedBy=multi-user.target' 'DefaultInstance=-' \
        >"$units/xfs_healer@.service"
    printf '%s\n' '[Unit]' 'Description=Start Self Healing of XFS Metadata' \
        '[Service]' 'ExecStart=/bin/true' \
        '[Install]' 'WantedBy=multi-user.target' \
        >"$units/xfs_healer_start.service"
    # Debian's systemd ships 99-default.preset with `enable *`.
    echo 'enable *' >"$dir/usr/lib/systemd/system-preset/99-default.preset"
    if [[ $2 == 1 ]]; then
        cp "$presets"/*.preset "$dir/usr/lib/systemd/system-preset/"
    fi
    systemctl --root="$dir" preset-all >/dev/null 2>&1
}

wants() { echo "$1/etc/systemd/system/multi-user.target.wants/$2"; }

make_root "$work/control" 0
if [[ -L "$(wants "$work/control" 'xfs_healer@-.service')" ]]; then
    pass "control: without the base presets, preset-all enables xfs_healer@-.service"
else
    fail "control: preset-all did not enable xfs_healer@-.service; the check below proves nothing"
fi

make_root "$work/image" 1
if [[ -e "$(wants "$work/image" 'xfs_healer@-.service')" || -L "$(wants "$work/image" 'xfs_healer@-.service')" ]]; then
    fail "the base presets enable xfs_healer@-.service (it fails on the overlay root, #1326)"
else
    pass "the base presets leave xfs_healer@-.service disabled"
fi
if [[ -L "$(wants "$work/image" 'xfs_healer_start.service')" ]]; then
    pass "the base presets keep xfs_healer_start.service enabled for XFS mounts"
else
    fail "the base presets disable xfs_healer_start.service; only the root instance must go"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 && PASS == 3 ))
