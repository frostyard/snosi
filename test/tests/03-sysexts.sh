#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Tier 3: Sysext machinery validation tests for bootc-deployed snosi images.
# This script runs INSIDE the booted VM via SSH.
# Validates that systemd-sysext and sysupdate infrastructure is present.
# Sysexts may not be active on a fresh install; this checks the machinery, not content.
# Output format: TAP-like (ok / not ok), exit code = number of failures.
set -euo pipefail

# shellcheck source=../lib/helpers.sh
HELPERS="${TEST_LIB_DIR:-$(dirname "$0")/../lib}/helpers.sh"
source "$HELPERS"

echo "# Tier 3: Sysext machinery validation"

check "systemd-sysext binary exists" \
    command -v systemd-sysext

check "systemd-sysext list succeeds" \
    systemd-sysext list

check "sysupdate transfer configs exist" \
    test -d /usr/lib/sysupdate.d

echo ""
echo "# Informational: sysupdate transfer configs"
if [[ -d /usr/lib/sysupdate.d ]]; then
    ls -1 /usr/lib/sysupdate.d/ 2>/dev/null || echo "(empty)"
else
    echo "(directory not found)"
fi

echo ""
echo "# Informational: active extensions"
systemd-sysext list 2>/dev/null || echo "(none or command failed)"

print_summary
