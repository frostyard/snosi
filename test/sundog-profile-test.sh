#!/bin/bash
# Static contract for the Sundog KDE Plasma bootc desktop.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
profile="$root/mkosi.profiles/sundog/mkosi.conf"
composition="$root/shared/composition/sundog/mkosi.conf"
packages="$root/shared/packages/sundog/mkosi.conf"
postinst="$root/shared/sundog/scripts/postinstall/sundog.postinst.chroot"

fail() {
    echo "sundog-profile-test: FAIL: $*" >&2
    exit 1
}

require_line() {
    local file=$1 pattern=$2 description=$3
    grep -Eq "$pattern" "$file" || fail "$description"
}

for file in "$profile" "$composition" "$packages" "$postinst" \
    "$root/shared/composition/sundog/var-outcomes.txt"; do
    [[ -f $file ]] || fail "missing ${file#"$root"/}"
done

# Product boundary: Sundog has exactly one bootc profile and no native A/B
# selector or composition.
require_line "$profile" '^ImageId=sundog$' "profile does not identify Sundog"
require_line "$profile" 'shared/packages/bootc/mkosi\.conf' "bootc runtime is not composed"
require_line "$profile" 'shared/bootc-secure/mkosi\.conf' "bootc security layer is not composed"
require_line "$profile" 'shared/outformat/image/mkosi\.conf' "OCI output is not composed"
if grep -q 'outformat/ab-root' "$profile" || [[ -e "$root/mkosi.profiles/sundog-ab" ]]; then
    fail "Sundog must remain bootc-only"
fi

# Product composition retains the standard bootc scaffold and audits every
# build-time /var path.
require_line "$composition" 'ExtraTrees=%D/shared/cayo/tree' "shared bootc scaffold is missing"
require_line "$composition" 'ExtraTrees=%D/shared/sundog/tree' "Sundog overlay is missing"
require_line "$composition" 'shared/composition/var-audit\.finalize' "/var audit is not wired"
require_line "$composition" 'shared/packages/sundog/mkosi\.conf' "Sundog package set is not composed"

declare -a required_packages=(
    kde-plasma-desktop kwin-wayland sddm sddm-theme-breeze
    plasma-nm plasma-pa kscreen powerdevil polkit-kde-agent-1 libpam-kwallet5
    xdg-desktop-portal-kde qt6-wayland dolphin konsole
    plasma-discover-backend-flatpak kde-config-flatpak fcitx5 kde-config-fcitx5
    plymouth-theme-breeze flatpak tuned tuned-ppd podman distrobox
)
for package in "${required_packages[@]}"; do
    require_line "$packages" "^[[:space:]]*(Packages=)?${package}$" "required package is missing: $package"
done

if grep -Eq '^[[:space:]]*(Packages=)?im-config$' "$packages"; then
    fail "im-config must not override Plasma Wayland input-method activation"
fi

declare -a forbidden_packages=(
    gdm3 gnome-shell hyprland kwin-x11 plasma-discover-backend-packagekit
    power-profiles-daemon snow-first-setup
)
for package in "${forbidden_packages[@]}"; do
    if grep -Eq "^[[:space:]]*(Packages=)?${package}$" "$packages"; then
        fail "forbidden package is declared: $package"
    fi
done

# Every gui-base package is explicit in Sundog's package set. This makes the
# desktop-app sysext omission contract reviewable without resolving apt.
while IFS= read -r package; do
    [[ -n $package ]] || continue
    require_line "$packages" "^[[:space:]]*(Packages=)?${package}$" \
        "gui-base package missing from Sundog: $package"
done < <(
    awk '
        /^Packages=/ { print substr($0, 10); in_packages=1; next }
        in_packages && /^[[:space:]]+[[:alnum:]]/ { gsub(/^[[:space:]]+/, ""); print; next }
        { in_packages=0 }
    ' "$root/mkosi.images/gui-base/mkosi.conf"
)

require_line "$postinst" 'OS_NAME="Sundog Linux"' "OS branding is missing"
require_line "$postinst" 'rm -f /usr/share/xsessions/plasmax11\.desktop' "X11 session is not suppressed"
require_line "$postinst" 'display-manager\.service' "static SDDM alias is missing"
require_line "$composition" 'ExtraTrees=%D/shared/desktop/tree' "shared desktop recovery tree is missing"
require_line "$root/shared/desktop/tree/usr/lib/tmpfiles.d/saned.conf" \
    '^d /var/lib/saned 0755 saned saned - -$' "saned factory state is not recovered"
require_line "$root/shared/desktop/tree/usr/lib/tmpfiles.d/upower.conf" \
    '^d /var/lib/upower 0755 root root - -$' "upower factory state is not recovered"
require_line "$root/shared/sundog/tree/etc/sddm.conf.d/10-sundog.conf" '^Current=breeze$' "SDDM Breeze theme is not selected"
require_line "$root/shared/sundog/tree/etc/plymouth/plymouthd.conf" '^Theme=breeze$' "Plymouth Breeze theme is not selected"

echo "sundog-profile-test: PASS"
