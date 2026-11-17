#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static guard (frostyard/snosi#1326): the presets of every image must not
# enable the root instance of xfs_healer@.service. On forky its ExecCondition
# exits 255 on the composefs overlay root, so the unit fails at every boot.
#
# The products take base as their BaseTree and then apply their ExtraTrees, so
# a product tree file replaces the base file of the same name (the first fix
# put the line in base's 03-core.preset, which shared/snow/tree and
# shared/floe/tree replace). The test composes the preset directory the same
# way: base, then each shared/*/tree that ships presets, file over file. For
# each composition it runs `systemctl --root` preset-all on a scratch root with
# Debian's catch-all `enable *` and stub units with the [Install] sections of
# forky's xfsprogs units, and checks the links that first boot would create.
# Control runs make the check fail on purpose: one with no snosi presets, and
# one where a product tree's 03-core.preset carries the line but base does not.
#
# No root, no network, no image build.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
preset_rel="usr/lib/systemd/system-preset"
base_presets="$root/mkosi.images/base/mkosi.extra/$preset_rel"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# make_root DIR PRESET_DIR... : the presets of each PRESET_DIR, in order, a
# later file replacing an earlier one of the same name; then preset-all.
make_root() {
    local dir="$1" units="$1/usr/lib/systemd/system" src
    shift
    mkdir -p "$units" "$dir/$preset_rel" "$dir/etc"
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
    echo 'enable *' >"$dir/$preset_rel/99-default.preset"
    for src in "$@"; do
        cp "$src"/*.preset "$dir/$preset_rel/"
    done
    systemctl --root="$dir" preset-all >/dev/null 2>&1
}

link() { echo "$1/etc/systemd/system/multi-user.target.wants/$2"; }
enabled() { [[ -L "$(link "$1" "$2")" ]]; }

# check NAME DIR: the root instance is off and the dispatcher stays on.
check() {
    if enabled "$2" 'xfs_healer@-.service'; then
        fail "$1: the presets enable xfs_healer@-.service (it fails on the overlay root, #1326)"
    else
        pass "$1: xfs_healer@-.service stays disabled"
    fi
    if enabled "$2" 'xfs_healer_start.service'; then
        pass "$1: xfs_healer_start.service stays enabled for XFS mounts"
    else
        fail "$1: xfs_healer_start.service is disabled; only the root instance must go"
    fi
}

make_root "$work/control-none"
if enabled "$work/control-none" 'xfs_healer@-.service'; then
    pass "control: with no snosi presets, preset-all enables xfs_healer@-.service"
else
    fail "control: preset-all did not enable xfs_healer@-.service; the checks prove nothing"
fi

# Control for the overwrite: base's 03-core.preset carries the line, a product
# tree's 03-core.preset does not. The composed root must enable the unit.
mkdir -p "$work/ctl-base" "$work/ctl-tree"
printf '%s\n' 'disable xfs_healer@.service' >"$work/ctl-base/03-core.preset"
printf '%s\n' 'disable ModemManager.service' >"$work/ctl-tree/03-core.preset"
make_root "$work/control-overwrite" "$work/ctl-base" "$work/ctl-tree"
if enabled "$work/control-overwrite" 'xfs_healer@-.service'; then
    pass "control: a product tree file replaces the base file of the same name"
else
    fail "control: the composition does not replace files; the product checks prove nothing"
fi

make_root "$work/base" "$base_presets"
check "base" "$work/base"

trees=0
for tree_presets in "$root"/shared/*/tree/"$preset_rel"; do
    [[ -d $tree_presets ]] || continue
    tree="${tree_presets#"$root"/}"
    tree="${tree%%/tree/*}"
    if [[ -e "$tree_presets/07-xfs-healer.preset" ]]; then
        fail "$tree/tree ships 07-xfs-healer.preset, which replaces base's"
    fi
    make_root "$work/${tree//\//-}" "$base_presets" "$tree_presets"
    check "base + $tree/tree" "$work/${tree//\//-}"
    trees=$((trees + 1))
done
# shared/snow/tree (snow, snowfield), shared/floe/tree (floe, sundog) and
# shared/snosi-report/tree ship presets today.
if (( trees >= 3 )); then
    pass "checked $trees product trees with presets"
else
    fail "found $trees product trees with presets, expected at least 3"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
