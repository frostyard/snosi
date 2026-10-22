#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Assertions shared by the bootc secure install, update and rotation harnesses
# and by the two bootc secure publication helpers
# (shared/bootc-secure/ci/verify-published-image.sh and
# shared/bootc-secure/ci/promote-published-image.sh).
#
# These existed as independent copies in both harnesses, and three of the four
# had drifted. One drift was semantic and load-bearing: type2_only accepted only
# `efi` in the update harness while bootc writes `uki`, so the update leg could
# never pass -- eleven seconds after the install harness asserted the same
# property against the same system and passed.
#
# That is the sixth defect in this subsystem caused by a fix landing in one of
# two sibling harnesses. One copy now, sourced by every consumer.
#
# The secure bootc profile and OCI reference grammar moved here for the same
# reason. Keep this file free of side effects when it is sourced: no shell
# options and nothing at top level except variable assignments and function
# definitions.
#
# esp_cat requires vm_ssh from test/lib/ssh.sh; nothing else here does.


# --- Secure bootc profile and OCI reference grammar -------------------------
#
# There are two profile sets, on purpose. A secure VM lane needs a bootable
# secure image under test; sundog publishes a secure OCI image but has no secure
# VM lane, so publication accepts one profile more than the lanes do. The test
# digest refs accept any hex digit; publication accepts lowercase hex only,
# because that is what the registry digest grammar allows.
BOOTC_SECURE_LANE_PROFILES='floe|snow|snowfield'
BOOTC_SECURE_PUBLISHED_PROFILES='floe|snow|snowfield|sundog'

valid_profile() { # profile; exact match of the whole string.
    local re='^('"$BOOTC_SECURE_LANE_PROFILES"')$'
    [[ $1 =~ $re ]]
}
valid_digest_ref() { # ghcr.io/frostyard/<lane-profile>@sha256:<64 hex>
    local re='^ghcr\.io/frostyard/('"$BOOTC_SECURE_LANE_PROFILES"')@sha256:[[:xdigit:]]{64}$'
    [[ $1 =~ $re ]]
}
valid_tracking_ref() { # ghcr.io/frostyard/<lane-profile>:<tracking-tag>
    local re='^ghcr\.io/frostyard/('"$BOOTC_SECURE_LANE_PROFILES"'):[a-zA-Z0-9][a-zA-Z0-9._-]*$'
    [[ $1 =~ $re ]]
}
valid_published_image() { # ghcr.io/frostyard/<published-profile>
    local re='^ghcr\.io/frostyard/('"$BOOTC_SECURE_PUBLISHED_PROFILES"')$'
    [[ $1 =~ $re ]]
}
valid_published_digest() { # sha256:<64 lowercase hex>
    local re='^sha256:[a-f0-9]{64}$'
    [[ $1 =~ $re ]]
}


# bootc mounts /boot only while it is using it, and leaves it unmounted
# otherwise -- so an installed target has no /boot to read, and
# `cat /boot/loader/entries/*.conf` fails with "No such file or directory" on a
# perfectly healthy system. Mount the ESP the same way exercise_reconciler
# does: locate it by GPT type GUID on the disk backing the root mapper, rather
# than assuming any mount point exists.
esp_cat() { # glob-relative-to-esp
    # shellcheck disable=SC2016 # This complete script executes on the guest.
    vm_ssh 'set -euo pipefail
esp=""
while read -r path ptype; do
    if [ "${ptype,,}" = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]; then esp="$path"; break; fi
done < <(lsblk -rno PATH,PARTTYPE)
if [ -z "$esp" ]; then
    echo "esp_cat: no partition carries the ESP type GUID; block layout follows" >&2
    lsblk -rno PATH,TYPE,PARTTYPE,PKNAME >&2
    exit 1
fi
mountpoint=$(mktemp -d /run/task9-esp-read.XXXXXX)
trap "umount \"$mountpoint\" 2>/dev/null || true; rmdir \"$mountpoint\" 2>/dev/null || true" EXIT
mount -o ro "$esp" "$mountpoint" || { echo "esp_cat: cannot mount $esp" >&2; exit 1; }
cat "$mountpoint"/'"$1"' || { echo "esp_cat: no match for '"$1"' on $esp; ESP contains:" >&2; find "$mountpoint" -maxdepth 3 >&2; exit 1; }
'
}

composefs_from_cmdline() {
    local token value='' count=0
    for token in $1; do
        [[ $token == composefs=* ]] || continue
        value=${token#composefs=}; value=${value#\?}; value=${value%%,*}; count=$((count + 1))
    done
    [[ $count -eq 1 && $value =~ ^[[:xdigit:]]{128}$ ]] && printf '%s\n' "$value"
}
type2_only() { # path; materialize once because callers may provide a FIFO.
    local entries
    entries=$(cat "$1") || return
    # `uki` OR `efi`. bootc writes `uki` -- verified from a real installed
    # target, whose only BLS entry is:
    #
    #     title Floe Linux 13
    #     version 13
    #     uki /EFI/Linux/bootc/bootc_composefs-<128 hex>.efi
    #     sort-key bootc-floe-0
    #
    # Requiring `efi` rejected every genuine install. Both spell a Type #2
    # entry; what makes it Type #2 is a single bundled EFI image and the
    # absence of `linux`/`initrd`, which is still enforced above.
    # frostyard/fisherman#22 fixed the identical assumption in its validator.
    ! grep -Eq '^[[:space:]]*(linux|initrd)[[:space:]]+' <<<"$entries" \
        && grep -Eq '^[[:space:]]*(uki|efi)[[:space:]]+/EFI/Linux/bootc/bootc_composefs-[[:xdigit:]]{128}\.efi[[:space:]]*$' <<<"$entries"
}
signed_pcr11_token() {
    jq -e '[.tokens[] | select(.type == "systemd-tpm2")] as $tokens | ($tokens | length == 1) and $tokens[0]."tpm2-pcrs" == [] and $tokens[0].tpm2_pubkey_pcrs == [11] and ($tokens[0] | has("tpm2-pcrlock") | not)' >/dev/null
}
root_backing_device() { # cryptsetup status root output
    local device
    device=$(awk '/^[[:space:]]*device:/{print $2}' <<<"$1")
    [[ $device == /dev/* && $device != *$'\n'* ]] && printf '%s\n' "$device"
}
