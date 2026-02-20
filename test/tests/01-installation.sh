#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Tier 1: Installation validation tests for bootc-deployed snosi images.
# This script runs INSIDE the booted VM via SSH and is fully self-contained.
# Output format: TAP-like (ok / not ok), exit code = number of failures.
set -euo pipefail

PASS=0
FAIL=0

# check - Run a test and record the result.
# Usage: check "description" command [args...]
check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok - $desc"
        (( PASS++ )) || true
    else
        echo "not ok - $desc"
        (( FAIL++ )) || true
    fi
}

echo "# Tier 1: Installation validation"

check "System is running" \
    systemctl is-system-running --wait --timeout=120

check "Root filesystem is read-only" \
    awk '$5 == "/" { exit (/\bro\b/ ? 0 : 1) }' /proc/mounts

check "Composefs is active" \
    findmnt -n -o FSTYPE / -t overlay,composefs

check "usr is read-only" \
    test ! -w /usr/bin

check "bootc status succeeds" \
    bootc status

check "bootc has image reference" \
    bash -c 'bootc status --json | jq -e ".status.booted.image"'

echo ""
echo "# Results: $PASS passed, $FAIL failed, $(( PASS + FAIL )) total"
exit "$FAIL"
