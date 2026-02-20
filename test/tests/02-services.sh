#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Tier 2: Systemd service health tests for bootc-deployed snosi images.
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

echo "# Tier 2: Service health"

check "systemd-resolved is active" \
    systemctl is-active systemd-resolved

check "NetworkManager is active" \
    systemctl is-active NetworkManager

check "ssh is active" \
    systemctl is-active ssh

# shellcheck disable=SC2016
check "nbc-update-download.timer is loaded" \
    bash -c 'test -n "$(systemctl list-timers --all --no-legend nbc-update-download.timer)"'

check "frostyard-updex service exists" \
    systemctl cat frostyard-updex

# shellcheck disable=SC2016
check "no failed systemd units" \
    bash -c 'test "$(systemctl --failed --no-legend | wc -l)" -eq 0'

echo ""
echo "# Results: $PASS passed, $FAIL failed, $(( PASS + FAIL )) total"
exit "$FAIL"
