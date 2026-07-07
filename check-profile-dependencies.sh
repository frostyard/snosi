#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

profiles=(cayo cayoloaded snow snowloaded snowfield snowfieldloaded)
sysexts=(
    1password-cli
    code-server
    debdev
    dev
    docker
    incus
    nix
    podman
    tailscale
)

failed=0

for profile in "${profiles[@]}"; do
    summary=$(mkosi -f --profile "$profile" summary)

    for sysext in "${sysexts[@]}"; do
        if grep -q "^IMAGE: ${sysext}$" <<<"$summary"; then
            echo "Profile ${profile} unexpectedly includes sysext dependency ${sysext}." >&2
            failed=1
        fi
    done
done

if (( failed )); then
    exit 1
fi

echo "Profile builds depend only on base."
