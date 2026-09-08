#!/bin/bash
set -euo pipefail

# Exercise real sysusers/tmpfiles against disposable roots, never host accounts.
if (( EUID != 0 )); then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
base="$root/mkosi.images/base/mkosi.extra/usr/lib"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo '1..4'
for scenario in missing existing; do
    target="$work/$scenario"
    mkdir -p "$target/etc" "$target/usr/lib/sysusers.d" "$target/usr/lib/tmpfiles.d"
    printf 'root:x:0:0:root:/root:/bin/sh\n' > "$target/etc/passwd"
    printf 'root:x:0:\nnogroup:x:65534:\n' > "$target/etc/group"
    cp "$base/tmpfiles.d/nfs-common.conf" "$target/usr/lib/tmpfiles.d/"
    # Debian rpcbind's packaged rule (the image does not override it).
    printf 'D /run/rpcbind 0755 _rpc root - -\n' > "$target/usr/lib/tmpfiles.d/rpcbind.conf"

    if [[ "$scenario" == missing ]]; then
        if systemd-tmpfiles --root="$target" --create nfs-common.conf rpcbind.conf > "$work/missing.log" 2>&1; then
            echo 'not ok 1 - missing service accounts must fail tmpfiles'
            exit 1
        fi
        grep -q "Failed to resolve user 'statd'" "$work/missing.log"
        grep -q "Failed to resolve user '_rpc'" "$work/missing.log"
        echo 'ok 1 - reproduces both missing-account tmpfiles failures'
    else
        # Simulate persistent identities and NFS state on an existing install.
        printf '_rpc:x:123:65534::/run/rpcbind:/usr/sbin/nologin\nstatd:x:124:65534::/var/lib/nfs:/usr/sbin/nologin\n' >> "$target/etc/passwd"
        cp "$target/etc/passwd" "$work/existing.passwd"
        mkdir -p "$target/var/lib/nfs"
        printf 'existing NFS state\n' > "$target/var/lib/nfs/state"
    fi

    cp "$base/sysusers.d/nfs-common.conf" "$base/sysusers.d/rpcbind.conf" "$target/usr/lib/sysusers.d/"
    systemd-sysusers --root="$target" nfs-common.conf rpcbind.conf
    systemd-tmpfiles --root="$target" --create nfs-common.conf rpcbind.conf

    rpc_uid=$(awk -F: '$1 == "_rpc" {print $3}' "$target/etc/passwd")
    statd_uid=$(awk -F: '$1 == "statd" {print $3}' "$target/etc/passwd")
    [[ -n "$rpc_uid" && "$rpc_uid" != 0 && -n "$statd_uid" && "$statd_uid" != 0 ]]
    grep -Eq '^_rpc:x:[0-9]+:65534::/run/rpcbind:/usr/sbin/nologin$' "$target/etc/passwd"
    grep -Eq '^statd:x:[0-9]+:65534::/var/lib/nfs:/usr/sbin/nologin$' "$target/etc/passwd"
    [[ $(stat -c '%u:%g:%a' "$target/run/rpcbind") == "$rpc_uid:0:755" ]]
    for directory in sm sm.bak; do
        [[ $(stat -c '%u:%g:%a' "$target/var/lib/nfs/$directory") == "$statd_uid:65534:755" ]]
    done
    [[ $(stat -c '%u:%g:%a' "$target/var/lib/nfs/state") == "$statd_uid:65534:644" ]]

    if [[ "$scenario" == missing ]]; then
        echo 'ok 2 - sysusers repairs absent accounts and tmpfiles creates correctly owned state'
        cp "$target/etc/passwd" "$work/created.passwd"
        systemd-sysusers --root="$target" nfs-common.conf rpcbind.conf
        cmp "$work/created.passwd" "$target/etc/passwd"
        echo 'ok 3 - repeated sysusers preserves allocated identities'
    else
        cmp "$work/existing.passwd" "$target/etc/passwd"
        [[ $(cat "$target/var/lib/nfs/state") == 'existing NFS state' ]]
        echo 'ok 4 - existing identities and persistent NFS state survive'
    fi
done
