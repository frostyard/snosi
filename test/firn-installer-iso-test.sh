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
unpinned=$(grep -Fxc 'Packages=frostyard-firn' "$conf" || true)
any=$(grep -cE '^(Packages=|[[:space:]]+)frostyard-firn([[:space:]=/]|$)' "$conf" || true)
if [[ $unpinned -ne 1 || $any -ne 1 ]]; then
    echo 'Firn ISO must install exactly one unpinned Packages=frostyard-firn' >&2
    exit 1
fi

# Firn reads each image's org.frostyard.core-flatpaks label (firn
# ADR-0018); the retired ISO fallback gave every product Snow's set.
fallback=usr/share/firn/core-flatpaks.json
if grep -v '^[[:space:]]*#' "$conf" "$root/Justfile" | grep -Fq "$fallback" ||
    [[ -e "$root/shared/firn-installer/tree/$fallback" ]]; then
    echo "Firn ISO must not ship the retired /$fallback fallback" >&2
    exit 1
fi

echo 'Firn ISO static sandbox contract passed'
