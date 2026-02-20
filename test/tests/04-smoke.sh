#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Tier 4: Smoke tests for bootc-deployed snosi images.
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

echo "# Tier 4: Smoke tests"

check "Network connectivity" \
    curl -sf --max-time 10 https://example.com

check "DNS resolution" \
    getent hosts example.com

# shellcheck disable=SC2016
check "Package metadata intact (>100 installed packages)" \
    bash -c 'test "$(dpkg -l | grep -c "^ii")" -gt 100'

# shellcheck disable=SC2016
check "System time is reasonable (year >= 2025)" \
    bash -c 'test "$(date +%Y)" -ge 2025'

# shellcheck disable=SC2016
check "Hostname is set" \
    bash -c 'test -n "$(hostname)"'

check "Locale is configured" \
    locale

echo ""
echo "# Results: $PASS passed, $FAIL failed, $(( PASS + FAIL )) total"
exit "$FAIL"
