#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Tier 3: Sysext machinery validation tests for bootc-deployed snosi images.
# This script runs INSIDE the booted VM via SSH.
# Validates that systemd-sysext and sysupdate infrastructure is present.
# Sysexts may not be active on a fresh install; this checks the machinery, not content.
# Output format: TAP-like (ok / not ok), exit code = number of failures.
set -euo pipefail

HELPERS="${TEST_LIB_DIR:-$(dirname "$0")/../lib}/helpers.sh"
# shellcheck source=test/lib/helpers.sh
source "$HELPERS"

echo "# Tier 3: Sysext machinery validation"

check "systemd-sysext binary exists" \
    command -v systemd-sysext

check "systemd-sysext list succeeds" \
    systemd-sysext list

check "sysupdate component directories exist" \
    bash -c 'shopt -s nullglob; dirs=(/usr/lib/sysupdate.*.d); (( ${#dirs[@]} > 0 ))'

echo ""
echo "# Informational: sysupdate component directories"
shopt -s nullglob
component_dirs=(/usr/lib/sysupdate.*.d)
shopt -u nullglob
if [[ ${#component_dirs[@]} -gt 0 ]]; then
    for d in "${component_dirs[@]}"; do
        echo "## $d"
        ls -1 "$d" 2>/dev/null || echo "(empty)"
    done
else
    echo "(no sysupdate component directories found)"
fi

echo ""
echo "# Informational: active extensions"
systemd-sysext list 2>/dev/null || echo "(none or command failed)"

print_summary
