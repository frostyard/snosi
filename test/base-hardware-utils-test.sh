#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
base_conf="$root/mkosi.images/base/mkosi.conf"

echo "1..2"
test_number=0

for package in pciutils usbutils; do
    test_number=$((test_number + 1))
    if grep -Eq "^(Packages=|[[:space:]]+)${package}$" "$base_conf"; then
        echo "ok $test_number - base explicitly includes $package"
    else
        echo "not ok $test_number - base explicitly includes $package"
        exit 1
    fi
done
