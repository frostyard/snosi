#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Write persistence markers before a bootc update hop.
# This script runs INSIDE the booted VM via SSH, as root, exactly once
# (on the freshly installed system). persistence-verify.sh asserts the
# markers after every subsequent reboot/hop.
# Baselines are recorded under /var/persist-test/ (itself a /var marker).
set -euo pipefail

STATE=/var/persist-test
mkdir -p "$STATE"

echo "# Writing persistence markers"

# --- /var markers (shared state/os/default/var; must always persist) ---
echo "var-marker-v1" > "$STATE/data.txt"

# User account: crosses /etc (passwd/shadow) and /var (home on /var/home)
if ! id persisttest >/dev/null 2>&1; then
    useradd -m -s /bin/bash persisttest
fi
echo "home-marker" > /var/home/persisttest/marker.txt
chown persisttest:persisttest /var/home/persisttest/marker.txt

# Container image in /var/lib/containers, built offline (no registry pull)
tmpf=$(mktemp -d)
echo "container-marker" > "$tmpf/marker"
tar -C "$tmpf" -cf - marker | podman import --quiet - localhost/persist-test:1 >/dev/null
rm -rf "$tmpf"

# /opt is a bind to /var/opt
mkdir -p /var/opt/persist-test
echo "opt-marker" > /var/opt/persist-test/marker

# --- /etc markers (per-deployment copy; must carry into new deployments) ---
# New local file
echo "etc-new-marker" > /etc/persist-test.conf

# Locally modified shipped file
echo "# persist-test-motd-marker" >> /etc/motd

# Locally deleted shipped file (issue.net is shipped by base-files and inert)
if [[ -f /etc/issue.net ]]; then
    rm /etc/issue.net
    touch "$STATE/issue.net-was-deleted"
fi

# Identity
hostnamectl set-hostname persist-test-vm

# NetworkManager connection profile (never activated; loopback-ish dummy)
cat > /etc/NetworkManager/system-connections/persist-test.nmconnection <<'EOF'
[connection]
id=persist-test
uuid=8db7a1f0-5aa5-4e8b-9e52-persisttest0
type=dummy
interface-name=persist0
autoconnect=false
EOF
chmod 600 /etc/NetworkManager/system-connections/persist-test.nmconnection

# --- Baselines for identity-stability checks ---
sha256sum /etc/ssh/ssh_host_*_key.pub > "$STATE/hostkeys.sha256"
cat /etc/machine-id > "$STATE/machine-id"
journalctl --list-boots --quiet 2>/dev/null | wc -l > "$STATE/boot-count"

echo "# Markers written; baselines recorded in $STATE"
