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
check "bootc-update-stage.timer is loaded" \
    bash -c 'test -n "$(systemctl list-timers --all --no-legend bootc-update-stage.timer)"'

check "frostyard-updex is installed" \
    dpkg -s frostyard-updex

check "frostyard-nbc is not installed" \
    bash -c '! dpkg-query -W -f="\${Status}" frostyard-nbc 2>/dev/null | grep -q "install ok installed"'

check "nbc binary absent" \
    bash -c '! command -v nbc'

# shellcheck disable=SC2016
check "no failed systemd units" \
    bash -c 'test "$(systemctl --failed --no-legend | wc -l)" -eq 0'

print_summary
