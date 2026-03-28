#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Tier 4: Smoke tests for bootc-deployed snosi images.
# This script runs INSIDE the booted VM via SSH.
# Output format: TAP-like (ok / not ok), exit code = number of failures.
set -euo pipefail

# shellcheck source=../lib/helpers.sh
HELPERS="${TEST_LIB_DIR:-$(dirname "$0")/../lib}/helpers.sh"
source "$HELPERS"

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

print_summary
