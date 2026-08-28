#!/bin/bash
# NetworkManager Wi-Fi backend / package-closure drift guard (issue #805).
#
# Cayo shipped shared/cayo/tree/etc/NetworkManager/conf.d/iwd.conf setting
# wifi.backend=iwd while no product installs iwd -- NetworkManager was told to
# use a backend that is not in the image. This test fails whenever a shipped
# payload selects a Wi-Fi backend whose implementing package is absent from the
# package closure that payload ships into (base plus, for shared/<product>/tree
# and shared/composition/<product>, that product's package set).
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

test_number=0
failures=0

ok() {
    test_number=$((test_number + 1))
    echo "ok $test_number - $1"
}

not_ok() {
    test_number=$((test_number + 1))
    echo "not ok $test_number - $1"
    failures=$((failures + 1))
}

# Backend value as understood by NetworkManager -> Debian package providing it.
backend_package() {
    case "$1" in
        iwd) echo iwd ;;
        wpa_supplicant) echo wpasupplicant ;;
        *) echo "" ;;
    esac
}

# Every package named in any Packages= list of the given mkosi config files.
packages_in() {
    awk '
        /^Packages=/ { collecting = 1; sub(/^Packages=/, ""); }
        /^[A-Za-z]+=/ && !/^Packages=/ { collecting = 0 }
        /^[[:space:]]*$/ { collecting = 0 }
        collecting { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "") print }
    ' "$@" 2>/dev/null
}

# Payload dirs that ship files into an image, mapped to the config files whose
# Packages= lists define what that payload can rely on.
payload_dirs=$(find . -type d \( -name mkosi.extra -o -name tree \) \
    -not -path './.mkosi/*' -not -path './saved-unused/*' -printf '%P\n' | sort)

found_any=0

for payload in $payload_dirs; do
    while IFS= read -r conf; do
        [ -n "$conf" ] || continue
        backend=$(sed -n 's/^[[:space:]]*wifi\.backend[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$conf" | tail -1)
        [ -n "$backend" ] || continue
        found_any=1

        confs=(mkosi.images/base/mkosi.conf)
        product=$(printf '%s\n' "$payload" | sed -n 's#^shared/\([^/]*\)/tree$#\1#p')
        if [ -n "$product" ] && [ -f "shared/packages/$product/mkosi.conf" ]; then
            confs+=("shared/packages/$product/mkosi.conf")
        fi

        pkg=$(backend_package "$backend")
        if [ -z "$pkg" ]; then
            not_ok "$conf selects unknown wifi.backend=$backend (add it to backend_package)"
            continue
        fi

        if packages_in "${confs[@]}" | grep -qx "$pkg"; then
            ok "$conf selects wifi.backend=$backend and $pkg is installed (${confs[*]})"
        else
            not_ok "$conf selects wifi.backend=$backend but $pkg is not in ${confs[*]}"
        fi
    done < <(find "$payload" -path '*/NetworkManager/conf.d/*' -type f 2>/dev/null | sort)
done

# Regression pin for #805 itself: cayo must not resurrect the iwd override
# while cayo's closure has wpasupplicant and no iwd.
if [ -e shared/cayo/tree/etc/NetworkManager/conf.d/iwd.conf ]; then
    not_ok "cayo ships no iwd.conf override (found shared/cayo/tree/etc/NetworkManager/conf.d/iwd.conf)"
else
    ok "cayo ships no iwd.conf override"
fi

# Guard the mapping table itself: wpasupplicant is the backend base installs.
if packages_in mkosi.images/base/mkosi.conf | grep -qx wpasupplicant; then
    ok "base installs wpasupplicant (NetworkManager's default backend)"
else
    not_ok "base installs wpasupplicant (NetworkManager's default backend)"
fi

if [ "$found_any" -eq 0 ]; then
    ok "no shipped NetworkManager conf.d file overrides wifi.backend"
fi

echo "1..$test_number"
[ "$failures" -eq 0 ]
