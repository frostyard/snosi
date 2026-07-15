#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

usage() {
    echo "Usage: $0 [--allow-file] [--yes] [--mok-certificate PATH] [--encrypt-var --recovery-key-file PATH [--tpm2-device DEVICE --tpm2-public-key PATH]] IMAGE EXPECTED_SHA256 TARGET" >&2
    exit 2
}

allow_file=false
assume_yes=false
encrypt_var=false
recovery_key_file=""
tpm2_device=""
tpm2_public_key=""
mok_certificate=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-file) allow_file=true; shift ;;
        --yes) assume_yes=true; shift ;;
        --encrypt-var) encrypt_var=true; shift ;;
        --recovery-key-file) [[ $# -ge 2 ]] || usage; recovery_key_file="$2"; shift 2 ;;
        --tpm2-device) [[ $# -ge 2 ]] || usage; tpm2_device="$2"; shift 2 ;;
        --tpm2-public-key) [[ $# -ge 2 ]] || usage; tpm2_public_key="$2"; shift 2 ;;
        --mok-certificate) [[ $# -ge 2 ]] || usage; mok_certificate="$2"; shift 2 ;;
        --help|-h) usage ;;
        --) shift; break ;;
        -*) usage ;;
        *) break ;;
    esac
done
[[ $# -eq 3 ]] || usage

if $encrypt_var; then
    [[ -n "$recovery_key_file" ]] || { echo "Error: --encrypt-var requires --recovery-key-file" >&2; exit 1; }
    [[ ! -e "$recovery_key_file" ]] || { echo "Error: recovery key file already exists" >&2; exit 1; }
    if [[ -n "$tpm2_device" || -n "$tpm2_public_key" ]]; then
        [[ -n "$tpm2_device" && -n "$tpm2_public_key" ]] || {
            echo "Error: TPM enrollment requires both --tpm2-device and --tpm2-public-key" >&2
            exit 1
        }
        [[ -f "$tpm2_public_key" ]] || { echo "Error: TPM PCR public key not found" >&2; exit 1; }
    fi
elif [[ -n "$recovery_key_file" || -n "$tpm2_device" || -n "$tpm2_public_key" ]]; then
    echo "Error: encryption options require --encrypt-var" >&2
    exit 1
fi
[[ -z "$mok_certificate" || -f "$mok_certificate" ]] || {
    echo "Error: MOK certificate not found" >&2
    exit 1
}

image="$1"
expected_sha256="$2"
target="$3"

[[ $EUID -eq 0 ]] || { echo "Error: must run as root" >&2; exit 1; }
[[ -f "$image" ]] || { echo "Error: image is not a regular file: $image" >&2; exit 1; }
[[ "$expected_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "Error: invalid SHA-256" >&2; exit 1; }

if [[ -b "$target" ]]; then
    [[ "$(blockdev --getss "$target")" -eq 512 ]] || {
        echo "Error: target must use 512-byte logical sectors" >&2
        exit 1
    }
    [[ "$(lsblk -dnro TYPE "$target")" == disk ]] || {
        echo "Error: target is not a whole disk: $target" >&2
        exit 1
    }
    if lsblk -nrpo MOUNTPOINT "$target" | tr -d '[:space:]' | grep -q .; then
        echo "Error: target or one of its partitions is mounted: $target" >&2
        exit 1
    fi
    target_size="$(blockdev --getsize64 "$target")"
elif $allow_file && [[ -f "$target" ]]; then
    target_size="$(stat -c %s "$target")"
else
    echo "Error: target must be a whole block device (--allow-file is test-only)" >&2
    exit 1
fi

if $assume_yes && ! $allow_file; then
    echo "Error: --yes is restricted to --allow-file test targets" >&2
    exit 1
fi
if $allow_file && [[ -n "$mok_certificate" ]]; then
    echo "Error: MOK enrollment requires a real UEFI target" >&2
    exit 1
fi

image_size="$(stat -c %s "$image")"
(( target_size >= image_size )) || {
    echo "Error: target is smaller than image ($target_size < $image_size bytes)" >&2
    exit 1
}

printf '%s  %s\n' "$expected_sha256" "$image" | sha256sum --check --status || {
    echo "Error: image checksum mismatch" >&2
    exit 1
}

layout="$(sfdisk --json "$image")"
for label in esp _empty var; do
    grep -Eq "\"name\"[[:space:]]*:[[:space:]]*\"$label\"" <<<"$layout" || {
        echo "Error: image is missing required GPT label: $label" >&2
        exit 1
    }
done
[[ "$(grep -Ec '\"name\"[[:space:]]*:[[:space:]]*\"_empty\"' <<<"$layout")" -eq 2 ]] || {
    echo "Error: image must contain two empty A/B slots" >&2
    exit 1
}

echo "Image:  $image ($image_size bytes)"
echo "Target: $target ($target_size bytes)"
if ! $assume_yes; then
    read -r -p "Type the full target path to erase it: " confirmation
    [[ "$confirmation" == "$target" ]] || { echo "Aborted" >&2; exit 1; }
fi

if [[ -b "$target" ]]; then
    wipefs --all "$target"
    dd if="$image" of="$target" bs=16M iflag=fullblock oflag=direct conv=fsync status=progress
    blockdev --rereadpt "$target"
    udevadm settle
else
    # Remove stale partition data while preserving the requested virtual size.
    truncate -s 0 "$target"
    truncate -s "$target_size" "$target"
    dd if="$image" of="$target" bs=16M iflag=fullblock conv=notrunc,sparse,fsync status=progress
fi

disk="$target"
loop_device=""
cleanup() {
    if [[ -n "${var_mapper:-}" ]]; then
        cryptsetup close "$var_mapper" 2>/dev/null || true
    fi
    if [[ -n "$loop_device" ]]; then
        losetup --detach "$loop_device" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if $allow_file; then
    loop_device="$(losetup --find --show --partscan "$target")"
    disk="$loop_device"
    # partscan's partition device nodes appear asynchronously via udev; the
    # resize branch below already settles before its own lsblk scan, but
    # when target_size == image_size (no resize needed -- the common case
    # for a same-size install fixture) nothing previously settled before
    # the var-partition lsblk scan a few lines down, racing udev and
    # intermittently failing "expected exactly one var partition" even
    # though the partition table is correct (root-caused running this
    # script against a real snow-ab build in
    # test/native-ab-secure-boot-test.sh).
    udevadm settle
fi

# The image's backup GPT records the build size. Relocate it before using the
# extra capacity, without changing any partition identity or start sector.
if (( target_size > image_size )); then
    sfdisk --lock=yes --relocate gpt-bak-std "$disk"
    blockdev --rereadpt "$disk"
    udevadm settle
fi

mapfile -t var_parts < <(lsblk -nrpo NAME,PARTLABEL "$disk" | while read -r node label; do
    [[ "$label" == var ]] && printf '%s\n' "$node"
done)
[[ ${#var_parts[@]} -eq 1 ]] || {
    echo "Error: expected exactly one var partition" >&2
    exit 1
}
var_part="${var_parts[0]}"
var_number="$(lsblk -dnro PARTN "$var_part")"
var_start="$(lsblk -dnro START "$var_part")"
last_number="$(lsblk -nrpo PARTN,START,TYPE "$disk" | awk '$3 == "part"' | sort -k2,2n | tail -n 1 | awk '{ print $1 }')"
[[ "$var_number" == "$last_number" ]] || {
    echo "Error: var is not the final physical partition" >&2
    exit 1
}
[[ "$(blkid -o value -s TYPE "$var_part")" == ext4 ]] || {
    echo "Error: var partition is not ext4" >&2
    exit 1
}

if (( target_size > image_size )); then
    set +e
    e2fsck -fp "$var_part"
    fsck_status=$?
    set -e
    (( (fsck_status & ~1) == 0 )) || {
        echo "Error: var filesystem check failed with status $fsck_status" >&2
        exit 1
    }

    printf 'start=%s,size=+\n' "$var_start" | \
        sfdisk --lock=yes --no-reread -N "$var_number" "$disk"
    blockdev --rereadpt "$disk"
    udevadm settle
    [[ "$(lsblk -dnro START "$var_part")" == "$var_start" ]] || {
        echo "Error: var partition start changed unexpectedly" >&2
        exit 1
    }
    resize2fs "$var_part"
fi

if $encrypt_var; then
    command -v cryptsetup >/dev/null || { echo "Error: cryptsetup is required" >&2; exit 1; }
    install -m 0600 /dev/null "$recovery_key_file"
    recovery_key="$(openssl rand -hex 32)"
    printf '%s' "$recovery_key" >"$recovery_key_file"
    cryptsetup luksFormat --type luks2 --batch-mode --key-file "$recovery_key_file" "$var_part"
    var_mapper="snosi-var-install-$$"
    cryptsetup open --key-file "$recovery_key_file" "$var_part" "$var_mapper"
    mkfs.ext4 -F -L var "/dev/mapper/$var_mapper"

    if [[ -n "$tpm2_device" ]]; then
        command -v systemd-cryptenroll >/dev/null || {
            echo "Error: systemd-cryptenroll is required for TPM enrollment" >&2
            exit 1
        }
        systemd-cryptenroll \
            --unlock-key-file="$recovery_key_file" \
            --tpm2-device="$tpm2_device" \
            --tpm2-pcrs= \
            --tpm2-pcrlock= \
            --tpm2-public-key="$tpm2_public_key" \
            --tpm2-public-key-pcrs=11 \
            "$var_part"
    fi

    cryptsetup close "$var_mapper"
    var_mapper=""
    echo "Encrypted /var recovery key written to $recovery_key_file"
fi

if [[ -n "$mok_certificate" ]]; then
    command -v mokutil >/dev/null || { echo "Error: mokutil is required" >&2; exit 1; }
    mok_der="$(mktemp --suffix=.der)"
    trap 'rm -f "$mok_der"; cleanup' EXIT
    openssl x509 -in "$mok_certificate" -outform DER -out "$mok_der"
    mokutil --import "$mok_der"
    echo "Complete snosi MOK enrollment in MokManager on the next boot"
fi

sfdisk --verify "$disk"
echo "Native A/B image installed successfully"
