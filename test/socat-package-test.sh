#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
base_conf="$root/mkosi.images/base/mkosi.conf"

package_is_listed() {
    local package=$1
    local conf=$2
    grep -Eq "^(Packages=|[[:space:]]+)${package}$" "$conf"
}

echo "1..1"

if package_is_listed socat "$base_conf"; then
    echo "ok 1 - base explicitly includes socat"
else
    echo "not ok 1 - base explicitly includes socat"
    exit 1
fi
