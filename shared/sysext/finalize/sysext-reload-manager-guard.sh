#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared finalize script for every sysext: fail the build if the delta ships
# anything under usr/lib/systemd/system (a unit, a drop-in directory or a
# drop-in) but no extension-release file with EXTENSION_RELOAD_MANAGER=1.
#
# Why (snosi#1189): systemd-sysext reloads PID 1 after a merge or refresh only
# when a merged extension sets EXTENSION_RELOAD_MANAGER=1 in its
# extension-release file. updex never runs daemon-reload itself (updex
# ADR-0019), so without the key "updex features enable <name> --now" merges
# the sysext but PID 1 does not know its units, and they start only after a
# reboot. User units (usr/lib/systemd/user) do not count.
#
# $BUILDROOT is the delta, and $IMAGE_ID names the sysext. The release file is
# usr/lib/extension-release.d/extension-release.$IMAGE_ID. Only the exact line
# `EXTENSION_RELOAD_MANAGER=1` counts: a value of 0 or a commented line fails.
set -euo pipefail

ID=${IMAGE_ID:?sysext-reload-manager-guard: IMAGE_ID not set}
DELTA=${BUILDROOT:?sysext-reload-manager-guard: BUILDROOT not set}
UNITS=usr/lib/systemd/system
RELEASE=usr/lib/extension-release.d/extension-release.$ID

die() {
    echo "sysext-reload-manager-guard: $*" >&2
    exit 1
}

[[ -d $DELTA ]] || die "delta buildroot $DELTA is not a directory"

# Any entry counts, a dangling symlink too.
shopt -s nullglob dotglob
entries=("$DELTA/$UNITS"/*)
if ((${#entries[@]} == 0)); then
    echo "sysext-reload-manager-guard: $ID OK (no system units in the delta)"
    exit 0
fi

if [[ ! -f $DELTA/$RELEASE ]]; then
    die "$ID ships ${#entries[@]} entries in /$UNITS but no /$RELEASE: add mkosi.extra/$RELEASE with EXTENSION_RELOAD_MANAGER=1, or PID 1 does not load the units until a reboot (snosi#1189; docs/design/sysexts.md \"Service Activation Pattern (Upholds=)\")"
fi

if ! grep -qx 'EXTENSION_RELOAD_MANAGER=1' "$DELTA/$RELEASE"; then
    die "/$RELEASE has no line EXTENSION_RELOAD_MANAGER=1 (a value of 0 or a commented line does not count): PID 1 does not load the units of $ID until a reboot (snosi#1189)"
fi

echo "sysext-reload-manager-guard: $ID OK (${#entries[@]} system unit entries, EXTENSION_RELOAD_MANAGER=1)"
