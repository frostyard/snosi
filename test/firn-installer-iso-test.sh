#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static Firn installer ISO sandbox contract. The old QEMU harness installed
# retired A/B products; it is not evidence for secure bootc installation.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ${1:-} != --static || $# -ne 1 ]]; then
    echo "BLOCKED: the former Firn ISO live harness installed retired A/B products. Secure bootc fresh-install proof belongs to Firn's lab matrix (core ADR-0031); run this script with --static for the ISO sandbox check." >&2
    exit 2
fi

grep -Fqx 'SandboxTrees=%D/shared/bootc-secure/package-manager' \
    "$root/shared/firn-installer/mkosi.conf" || {
    echo 'Firn ISO must use the bootc Forky sandbox' >&2
    exit 1
}

conf="$root/shared/firn-installer/mkosi.conf"
pinned=$(grep -cx 'Packages=frostyard-firn=0.6.0' "$conf" || true)
any=$(grep -cE '^Packages=frostyard-firn([[:space:]]|=|$)' "$conf" || true)
if [[ $pinned -ne 1 || $any -ne 1 ]]; then
    echo 'Firn ISO must pin exactly one Packages=frostyard-firn=0.6.0 and no unpinned frostyard-firn' >&2
    exit 1
fi

echo 'Firn ISO static sandbox contract passed'
