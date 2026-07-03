#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Verify persistence markers after a bootc update hop (or reboot).
# This script runs INSIDE the booted VM via SSH, as root, after every
# hop performed by bootc-update-test.sh. Counterpart of
# persistence-write.sh. Output: TAP-like, exit code = failures.
set -euo pipefail

HELPERS="${TEST_LIB_DIR:-$(dirname "$0")/../lib}/helpers.sh"
# shellcheck source=test/lib/helpers.sh
source "$HELPERS"

STATE=/var/persist-test

echo "# Persistence verification"

# --- /var ---
check "/var marker file content intact" \
    grep -qx "var-marker-v1" "$STATE/data.txt"

check "persisttest user still resolves" \
    id persisttest

check "persisttest home marker intact" \
    grep -qx "home-marker" /var/home/persisttest/marker.txt

check "podman image survives in /var/lib/containers" \
    podman image exists localhost/persist-test:1

check "/opt bind still shows /var/opt content" \
    grep -qx "opt-marker" /opt/persist-test/marker

# shellcheck disable=SC2016
check "journal retains previous boots (boot count grew)" \
    bash -c '[[ $(journalctl --list-boots --quiet 2>/dev/null | wc -l) -gt $(cat /var/persist-test/boot-count) ]]'

# --- /etc ---
check "new local /etc file survives" \
    grep -qx "etc-new-marker" /etc/persist-test.conf

check "local modification to shipped /etc file survives" \
    grep -q "persist-test-motd-marker" /etc/motd

if [[ -f "$STATE/issue.net-was-deleted" ]]; then
    check "locally deleted shipped /etc file stays deleted" \
        bash -c '[[ ! -e /etc/issue.net ]]'
fi

check "hostname survives" \
    bash -c '[[ $(hostname) == persist-test-vm ]]'

check "NetworkManager profile survives" \
    test -f /etc/NetworkManager/system-connections/persist-test.nmconnection

# --- Identity stability (guards regressions found 2026-07: host keys and
# machine-id must never change across reboots or updates) ---
check "SSH host keys unchanged" \
    sha256sum --check --quiet "$STATE/hostkeys.sha256"

# shellcheck disable=SC2016
check "machine-id unchanged" \
    bash -c 'diff -q <(cat /etc/machine-id) /var/persist-test/machine-id'

# --- Informational (answers plan open questions; not pass/fail) ---
if [[ -e /run/ostree-booted ]]; then
    echo "# info: /run/ostree-booted EXISTS on this composefs deployment"
else
    echo "# info: /run/ostree-booted ABSENT on this composefs deployment"
fi

print_summary
