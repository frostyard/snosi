#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static contract for authenticated systemd-sysupdate sysext metadata.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base_conf="$root/mkosi.images/base/mkosi.conf"
native_conf="$root/shared/outformat/ab-root/mkosi.conf"
native_runtime_ring="$root/shared/sysext/keys/import-pubring.gpg"
native_ring="$root/shared/native-ab/keys/import-pubring.gpg"
repo_ring="$root/mkosi.sandbox/etc/apt/keyrings/frostyard.gpg"

mapfile -t transfers < <(find "$root/mkosi.images/base/mkosi.extra/usr/lib" \
    -path '*/sysupdate.*.d/*.transfer' -type f | sort)
((${#transfers[@]} > 0)) || {
    echo "no sysext transfer files found" >&2
    exit 1
}

for transfer in "${transfers[@]}"; do
    grep -qx 'Verify=true' "$transfer" || {
        echo "sysext transfer does not require signed metadata: ${transfer#"$root"/}" >&2
        exit 1
    }
done

expected="$(mktemp)"
trap 'rm -f "$expected"' EXIT
cat "$native_ring" "$repo_ring" >"$expected"
cmp -s "$expected" "$native_runtime_ring" || {
    echo "native runtime keyring is not the canonical combined keyring" >&2
    exit 1
}

for target in import-pubring.gpg import-pubring.pgp; do
    grep -Fqx "ExtraTrees=%D/mkosi.sandbox/etc/apt/keyrings/frostyard.gpg:/usr/lib/systemd/$target" \
        "$base_conf" || {
        echo "base image does not ship $target from the repository keyring" >&2
        exit 1
    }
    grep -Fqx "ExtraTrees=%D/shared/sysext/keys/import-pubring.gpg:/usr/lib/systemd/$target" \
        "$native_conf" || {
        echo "native image does not overlay $target from the combined keyring" >&2
        exit 1
    }
done

repo_fingerprints="$(gpg --batch --show-keys --with-colons "$repo_ring" 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10 }')"
[[ "$repo_fingerprints" == 432C452CD2B7F4FF1B5D23264DE6A2016E622F97 ]] || {
    echo "base repository keyring has an unexpected signer set" >&2
    exit 1
}

native_fingerprints="$(gpg --batch --show-keys --with-colons "$native_runtime_ring" 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10 }')"
for fingerprint in \
    F37282A35CB6BDFEBFC8FE775A2EAC5C8216FD68 \
    432C452CD2B7F4FF1B5D23264DE6A2016E622F97; do
    grep -qx "$fingerprint" <<<"$native_fingerprints" || {
        echo "native runtime keyring is missing $fingerprint" >&2
        exit 1
    }
done

echo "ok - ${#transfers[@]} sysext transfers require signed manifests"
echo "ok - base trusts only the repository signer"
echo "ok - native runtime keyring also contains the OS-update trust root"
