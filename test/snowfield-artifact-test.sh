#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Phase 6: Surface-specific artifact checks for a built snowfield-ab profile,
# on top of the profile-neutral checks in native-ab-secure-artifact-test.sh
# (systemd version coherence, secure initrd contents, PCR signature
# sections). This script proves the plan's snowfield artifact list
# (docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md "Snowfield
# Native A/B"):
#   - the manifest carries the expected Surface kernel/firmware packages and
#     NOT a backports/generic amd64 kernel;
#   - the UKI's embedded .linux section is actually the Surface kernel;
#   - /usr/lib/modules/<surface-kver> is present in the root artifact;
#   - a spot-set of firmware is present, cross-referenced against each
#     firmware-carrying package's OWN dpkg file list (not a hardcoded path
#     guess -- a package rename/reorg cannot silently desync this check);
#   - the UKI's initrd carries dm-verity/dm-crypt, the TPM2 userspace stack,
#     the etc-overlay dracut module, the erofs root-filesystem module,
#     nvme/usb-storage, and the Surface early-boot module family
#     (surface_aggregator, intel-lpss, 8250_dw, the surface-hid chain).
#
# A NEW script rather than growing native-ab-secure-artifact-test.sh: these
# checks are meaningless for cayo-ab/snow-ab (backports kernel), and an
# if-branch gated on OUTPUT_NAME would clutter a script that is otherwise
# fully profile-neutral.
#
# Kept deliberately independent from the Phase-3-established fact (see
# CLAUDE.md "Module policy") that ext4/vfat/dm-mod/tpm_crb/tpm_tis/
# virtio_{blk,scsi,pci,net}/xhci-{hcd,pci} are compiled directly into THIS
# kernel build (confirmed against modules.builtin during Phase 6 authoring,
# 2026-07-15) rather than shipped as initrd .ko files -- this script does
# NOT assert their absence-as-modules (a future kernel config change could
# make any of them modular again without that being a regression), only the
# presence of the items that must appear as loadable modules in a
# --no-hostonly initrd today.
#
# Usage: sudo ./test/snowfield-artifact-test.sh [manifest] [uki] [root_raw]
# Env overrides: OUTPUT_NAME (default snowfield-ab), IMAGE_ID (default
# snowfield). Requires root: loop-mounts the root erofs partition read-only.
set -euo pipefail

output_name=${OUTPUT_NAME:-snowfield-ab}
image_id=${IMAGE_ID:-snowfield}
manifest=${1:-output/$output_name.manifest}
uki=${2:-output/$output_name.efi}
root_raw=${3:-output/$output_name.${image_id}_@v.root.raw.raw}

[[ $EUID -eq 0 ]] || {
    echo "Error: must run as root (loop-mounts the root erofs partition read-only)" >&2
    exit 1
}

for command in jq objcopy file lsinitrd dpkg-query mount umount awk; do
    command -v "$command" >/dev/null || {
        echo "Error: $command is required" >&2
        exit 1
    }
done
for f in "$manifest" "$uki" "$root_raw"; do
    [[ -f "$f" ]] || { echo "Error: missing required artifact: $f" >&2; exit 1; }
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
kernel_conf="$script_dir/../shared/kernel/surface/mkosi.conf"
[[ -f "$kernel_conf" ]] || { echo "Error: missing $kernel_conf" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Manifest: expected Surface package set, derived from shared/kernel/
# surface/mkosi.conf itself (not a hardcoded copy in this script) so a
# future package-set edit there cannot silently desync this check. Strips
# target-release pins (e.g. "/trixie-backports") and comments.
# ---------------------------------------------------------------------------
mapfile -t expected_packages < <(awk '
    /^Packages=/ { grab=1 }
    grab && /^[[:space:]]*#/ { next }
    grab && /^[[:space:]]*$/ { next }
    grab && /^[A-Za-z]/ && !/^Packages=/ { grab=0 }
    grab {
        line = $0
        sub(/^Packages=/, "", line)
        sub(/^[[:space:]]+/, "", line)
        sub(/\/[A-Za-z0-9._-]+$/, "", line)
        if (line != "") print line
    }
' "$kernel_conf")
[[ "${#expected_packages[@]}" -gt 0 ]] || {
    echo "Error: failed to parse any expected package from $kernel_conf" >&2
    exit 1
}
echo "Expected Surface packages (${#expected_packages[@]} from $kernel_conf): ${expected_packages[*]}"

for pkg in "${expected_packages[@]}"; do
    jq -e --arg p "$pkg" 'any(.packages[]; .name == $p)' "$manifest" >/dev/null || {
        echo "Error: manifest is missing expected Surface package: $pkg" >&2
        exit 1
    }
done
echo "ok - manifest contains every package listed in shared/kernel/surface/mkosi.conf"

if jq -e '.packages[] | select(.name == "linux-image-amd64" or (.name | test("^linux-image-[0-9].*-amd64$")))' \
    "$manifest" >/dev/null; then
    echo "Error: manifest unexpectedly contains a backports/generic amd64 kernel package" >&2
    exit 1
fi
echo "ok - no backports linux-image-amd64 (or versioned -amd64 flavor) in manifest"

kernel_pkg_version="$(jq -er '.packages[] | select(.name == "linux-image-surface") | .version' "$manifest")"
echo "linux-image-surface package version: $kernel_pkg_version"

workdir=$(mktemp -d /var/tmp/snowfield-artifact-test.XXXXXX)
mountpoint="$workdir/root"
mkdir -p "$mountpoint"
cleanup() {
    umount "$mountpoint" 2>/dev/null || true
    rm -rf "$workdir"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# UKI: the embedded .linux section must be the Surface kernel, not any
# generic/backports build. `file` decodes the bzImage header's embedded
# "Linux version" banner without needing to boot anything.
# ---------------------------------------------------------------------------
objcopy --dump-section ".linux=$workdir/linux" "$uki" "$workdir/uki.linux.copy"
linux_file_info="$(file "$workdir/linux")"
echo "UKI .linux section: $linux_file_info"
kernel_release="$(grep -oE 'version [^,]+' <<<"$linux_file_info" | head -1 | awk '{print $2}')"
[[ -n "$kernel_release" ]] || {
    echo "Error: could not parse a kernel release from the UKI .linux section" >&2
    exit 1
}
[[ "$kernel_release" == *-surface* ]] || {
    echo "Error: UKI embeds a non-Surface kernel: $kernel_release" >&2
    exit 1
}
echo "ok - UKI's embedded kernel is the Surface kernel ($kernel_release)"

# ---------------------------------------------------------------------------
# Root artifact: module directory + firmware completeness.
# ---------------------------------------------------------------------------
mount -t erofs -o loop,ro "$root_raw" "$mountpoint"

[[ -d "$mountpoint/usr/lib/modules/$kernel_release" ]] || {
    echo "Error: /usr/lib/modules/$kernel_release is missing from the root artifact" >&2
    exit 1
}
echo "ok - /usr/lib/modules/$kernel_release is present in the root artifact"

admindir="$mountpoint/usr/lib/sysimage/dpkg"
[[ -d "$admindir" ]] || { echo "Error: relocated dpkg admindir missing: $admindir" >&2; exit 1; }

# Spot-check firmware completeness by cross-referencing each firmware-
# carrying Surface package's OWN dpkg file list against the mounted root --
# derived from what the package actually shipped (per the brief's
# instruction), not a hardcoded path guess. firmware-iwlwifi covers the
# Intel wifi spot-check the brief calls out by name; the rest sample the
# breadth of the Surface firmware set (Bluetooth, WMI/PCMCIA legacy,
# Realtek, Intel graphics).
firmware_packages=(firmware-iwlwifi atmel-firmware bluez-firmware firmware-realtek firmware-intel-graphics)
firmware_files_checked=0
for pkg in "${firmware_packages[@]}"; do
    jq -e --arg p "$pkg" 'any(.packages[]; .name == $p)' "$manifest" >/dev/null || {
        echo "Error: expected firmware package not in manifest: $pkg" >&2
        exit 1
    }
    files="$(dpkg-query --admindir="$admindir" -L "$pkg" | grep -E '^/usr/lib/firmware/' || true)"
    [[ -n "$files" ]] || {
        echo "Error: $pkg's own dpkg file list has no /usr/lib/firmware entries" >&2
        exit 1
    }
    # Bounded sample: every file for small packages, first 25 for large ones
    # (firmware-iwlwifi alone ships ~350+ files) -- this is a spot-check of
    # package/artifact coherence, not an exhaustive re-verification of dpkg
    # unpack integrity.
    sample="$(head -25 <<<"$files")"
    while IFS= read -r path; do
        [[ -e "$mountpoint$path" ]] || {
            echo "Error: $pkg ships $path per its own dpkg file list, but it is missing from the built root artifact" >&2
            exit 1
        }
        firmware_files_checked=$((firmware_files_checked + 1))
    done <<<"$sample"
done
echo "ok - $firmware_files_checked firmware files spot-checked against their owning packages' dpkg file lists (${firmware_packages[*]}), all present"

umount "$mountpoint"

# ---------------------------------------------------------------------------
# Initrd content (extracted from the UKI's .initrd section).
# ---------------------------------------------------------------------------
initrd="$workdir/initrd"
objcopy --dump-section ".initrd=$initrd" "$uki" "$workdir/uki.initrd.copy"
listing="$workdir/initrd.list"
lsinitrd "$initrd" > "$listing"

# dracut module set (the block between "dracut modules:" and the next
# "====" separator in lsinitrd's plain-text report -- this lsinitrd has no
# --list-modules flag, confirmed live).
dracut_modules="$(sed -n '/^dracut modules:$/,/^========/p' "$listing" | sed '1d;$d')"
has_dracut_module() { grep -qxF "$1" <<<"$dracut_modules"; }
has_module_file() { grep -qE "(^|/)$1\\.ko(\\.[a-z0-9]+)?\$" "$listing"; }

has_module_file dm-verity
has_module_file dm-crypt
echo "ok - initrd carries dm-verity and dm-crypt"

# TPM: on this kernel build tpm_crb/tpm_tis are compiled directly into
# vmlinuz (confirmed against modules.builtin during Phase 6 authoring), so
# the initrd only needs the userspace TPM2 stack -- the tpm2-tss dracut
# module plus the actual libtss2-esys shared library it packages.
has_dracut_module tpm2-tss
grep -q 'libtss2-esys\.so' "$listing"
echo "ok - initrd carries the TPM2 userspace stack (tpm2-tss dracut module, libtss2-esys)"

# etc-overlay (Snosi's /etc overlay dracut module).
has_dracut_module etc-overlay
grep -q 'usr/libexec/snosi-etc-overlay-initrd' "$listing"
echo "ok - initrd carries the etc-overlay dracut module"

# erofs (root filesystem format).
has_module_file erofs
echo "ok - initrd carries the erofs module (root filesystem)"

# storage: nvme, usb-storage. xhci-hcd/xhci-pci and ahci-adjacent
# controllers are compiled directly into this kernel (see the TPM note
# above); dracut's own "qemu" module additionally pulls in the virtio
# storage/net family for --no-hostonly builds (confirmed present below),
# covering the brief's "missing virtio in the surface kernel initrd" risk.
has_module_file nvme
has_module_file usb-storage
has_dracut_module qemu
echo "ok - initrd carries nvme, usb-storage, and dracut's qemu (virtio) module"

# Surface-relevant early-boot modules: the surface_aggregator family
# (EC/platform communication), intel-lpss (the Surface's I2C/UART
# controller), 8250_dw (Synopsys DesignWare UART, the Surface's serial/EC
# path), and the surface HID chain (keyboard/cover input during an early
# boot or emergency shell) -- cross-checked against linux-surface's own
# documented early-boot module set and what shared/kernel/surface actually
# packages, not a hardcoded guess independent of the real module tree.
surface_early_boot_modules=(
    surface_aggregator surface_aggregator_registry
    intel-lpss intel-lpss-pci
    8250_dw
    hid-surface surface_hid surface_hid_core surface_kbd
)
for mod in "${surface_early_boot_modules[@]}"; do
    has_module_file "$mod" || {
        echo "Error: expected Surface early-boot module missing from initrd: $mod" >&2
        exit 1
    }
done
echo "ok - initrd carries the Surface aggregator/HID/lpss/uart module family (${surface_early_boot_modules[*]})"

echo "Snowfield Surface artifact validation passed (kernel $kernel_release, linux-image-surface $kernel_pkg_version)"
