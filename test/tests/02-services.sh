#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Tier 2: Systemd service health tests for bootc-deployed snosi images.
# This script runs INSIDE the booted VM via SSH.
# Output format: TAP-like (ok / not ok), exit code = number of failures.
set -euo pipefail

HELPERS="${TEST_LIB_DIR:-$(dirname "$0")/../lib}/helpers.sh"
# shellcheck source=test/lib/helpers.sh
source "$HELPERS"

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

# On bootc/composefs installs (this test VM is one), the nbc units must be
# condition-gated OFF: nbc update errors rather than no-ops there
# (frostyard/nbc#139), which would leave a permanently failed unit.
if grep -q ' composefs=' /proc/cmdline; then
    # shellcheck disable=SC2016
    check "nbc-update-download.timer is gated off on composefs install" \
        bash -c 'test "$(systemctl is-active nbc-update-download.timer)" != "active"'
    # shellcheck disable=SC2016
    check "nbc-update-download.service has not failed" \
        bash -c 'test "$(systemctl show -P Result nbc-update-download.service)" = "success"'
fi

check "frostyard-updex is installed" \
    dpkg -s frostyard-updex

# shellcheck disable=SC2016
check "no failed systemd units" \
    bash -c 'test "$(systemctl --failed --no-legend | wc -l)" -eq 0'

print_summary
