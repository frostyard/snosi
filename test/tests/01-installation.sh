#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Tier 1: Installation validation tests for bootc-deployed snosi images.
# This script runs INSIDE the booted VM via SSH.
# Output format: TAP-like (ok / not ok), exit code = number of failures.
set -euo pipefail

# shellcheck source=../lib/helpers.sh
HELPERS="${TEST_LIB_DIR:-$(dirname "$0")/../lib}/helpers.sh"
source "$HELPERS"

echo "# Tier 1: Installation validation"

# Wait for boot to complete (SSH can be ready before all services finish).
# Accept "degraded" since graphical services (GDM) fail in headless VMs.
sys_state="starting"
for _ in $(seq 1 60); do
    sys_state=$(systemctl is-system-running 2>/dev/null || true)
    [[ "$sys_state" == "starting" ]] || break
    sleep 2
done
echo "# system state: $sys_state"
check "System has booted" \
    test "$sys_state" = "running" -o "$sys_state" = "degraded"

# shellcheck disable=SC2016
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

print_summary
