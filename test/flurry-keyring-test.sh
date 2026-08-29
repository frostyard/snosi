#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
packages="$root/shared/packages/flurry/mkosi.conf"
build_script="$root/shared/flurry/scripts/build/omarchy.chroot"
postinst="$root/shared/flurry/scripts/postinstall/flurry.postinst.chroot"

echo "1..5"

for package in gnome-keyring libpam-gnome-keyring libsecret-1-0; do
    if grep -Eq "^(Packages=|[[:space:]]+)${package}$" "$packages"; then
        echo "ok - flurry explicitly includes $package"
    else
        echo "not ok - flurry explicitly includes $package"
        exit 1
    fi
done

if grep -Fq 'HOME="$SKEL" bash "$SRC/install/user/default-keyring.sh"' "$build_script"; then
    echo "ok - new users inherit upstream default keyring setup"
else
    echo "not ok - new users inherit upstream default keyring setup"
    exit 1
fi

if grep -Fq "sed -i '/pam_gnome_keyring\\.so/d' /etc/pam.d/sddm" "$postinst"; then
    echo "ok - SDDM does not replace the passwordless keyring"
else
    echo "not ok - SDDM does not replace the passwordless keyring"
    exit 1
fi
