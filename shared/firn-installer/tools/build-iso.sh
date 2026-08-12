#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Assemble the single-installer ISO (firn ADR-0010) from a built
# firn-installer rootfs directory. Successor to
# shared/native-installer/tools/build-iso.sh (mechanism unchanged, incident
# comments carried over). Runs OUTSIDE mkosi, the same way
# shared/outformat/image/buildah-package.sh packages the OCI images:
# mkosi has no ISO/El Torito output format, and this needs host tools
# (xorriso, mtools, mkfs.vfat) that aren't in mkosi's build sandbox.
#
# The boot chain is fully Debian-trusted and pre-enrollment (never the Snosi
# MOK): Microsoft firmware db -> Debian-signed shim -> Debian-signed GRUB ->
# Debian-signed stock kernel. All four signed binaries are pulled straight
# out of the built rootfs (shared/firn-installer/mkosi.conf installed
# shim-signed, grub-efi-amd64-signed, shim-helpers-amd64-signed, and
# linux-image-amd64 as real Debian packages -- nothing here signs anything).
#
# grub-efi-amd64-signed's monolithic image has its prefix baked in at
# /EFI/debian (verified: `strings .../grubx64.efi.signed | grep '^/EFI'`),
# so grub.cfg MUST live at ESP:/EFI/debian/grub.cfg regardless of where the
# executables themselves sit. Debian's shim looks for its second-stage
# loader (grubx64.efi) and MokManager (mmx64.efi) in ITS OWN directory
# (confirmed via a UTF-16LE string dump of shimx64.efi.signed: `\\grubx64.efi`,
# `\mmx64.efi`, no directory component) -- since El Torito UEFI fallback
# boot requires shim at /EFI/BOOT/BOOTX64.EFI (no NVRAM boot entries exist
# for optical media), copies of grub/mmx64 go in /EFI/BOOT/ too (fbx64.efi
# deliberately does not -- see below).
#
# The installer userspace is the ENTIRE built rootfs packed as the kernel's
# initramfs (cpio+zstd), with a top-level /init -> usr/lib/systemd/systemd
# symlink (added by shared/firn-installer/postinst/mkosi.postinst.chroot).
# No switch_root, no dracut: the kernel only tries /sbin/init (and friends)
# on a SEPARATE "real" root device when the initramfs has no /init, which
# does not apply here, and systemd only behaves like a transient initrd
# when /etc/initrd-release exists, which this tree does not have -- so
# systemd just boots normally, with the whole tree as final root, entirely
# in RAM.
#
# Usage: build-iso.sh <rootfs-dir> <output-dir> [version]
#   output-dir: directory the final ISO is written into. The filename itself
#               is NOT caller-controlled: it is always the frozen public name
#               snosi-installer_<version>_x86-64.iso, so a caller can
#               never accidentally publish (or test against) a mis-named
#               artifact. The final path is printed as the last line of
#               stdout ("ISO_PATH=...").
#   version:    14-digit UTC YYYYMMDDHHMMSS (docs/native-ab-contracts.md §2);
#               defaults to the current time. Embedded in the ISO volume ID
#               (truncated to fit the 32-character ISO9660 d-characters
#               limit) and in /etc/snosi-installer-release inside the packed
#               rootfs/initramfs, so a booted installer can report its own
#               build version without depending on the ISO filename
#               surviving whatever media it was written to.
#
# Must run as root: reads root-owned/restricted subtrees of <rootfs-dir>
# (e.g. mode-0700 credstore dirs mkosi always creates) that a non-root
# caller cannot traverse.
set -euo pipefail

usage() {
    echo "Usage: $0 <rootfs-dir> <output-dir> [version]" >&2
    exit 2
}
[[ $# -eq 2 || $# -eq 3 ]] || usage

ROOTFS=$1
OUTPUT_DIR=$2
VERSION=${3:-$(date -u +%Y%m%d%H%M%S)}

[[ -d "$ROOTFS" ]] || { echo "Error: rootfs directory does not exist: $ROOTFS" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]{14}$ ]] || { echo "Error: version must be exactly 14 digits: $VERSION" >&2; exit 1; }

# mkfs.vfat lives in /usr/sbin, which Debian's default USER PATH omits; the
# Justfile recipe runs this under `sudo PATH="$PATH"` (preserving the caller's
# PATH for user-local tools), so sbin must be appended here rather than relied
# on from sudo's secure_path.
PATH="$PATH:/usr/sbin:/sbin"

for cmd in xorriso mcopy mmd mkfs.vfat cpio zstd find; do
    command -v "$cmd" >/dev/null || { echo "Error: required tool not found: $cmd" >&2; exit 1; }
done

mkdir -p "$OUTPUT_DIR"
ISO_NAME="snosi-installer_${VERSION}_x86-64.iso"
ISO_OUT="$OUTPUT_DIR/$ISO_NAME"

echo "=== Building firn-installer ISO ==="
echo "  rootfs:  $ROOTFS"
echo "  output:  $ISO_OUT"
echo "  version: $VERSION"

WORK=$(mktemp -d /var/tmp/firn-installer-iso.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1. Locate the signed boot chain material inside the built rootfs.
#
# fbx64.efi (the shim-helpers-amd64-signed fallback/NVRAM-registration
# loader) is deliberately NOT shipped in EFI/BOOT/ alongside shim, even
# though the package provides it: empirically reproduced live (isolated,
# minimal FAT images, bisecting file-by-file) that OVMF's shim, when it
# finds \EFI\BOOT\fbx64.efi next to itself, resets the machine instantly
# with ZERO diagnostic output -- before shim even attempts to load
# grubx64.efi (confirmed by removing fbx64.efi alone, with mmx64.efi and
# everything else unchanged: boot proceeds normally through GRUB, the
# signed kernel, and the packed initramfs). fbx64.efi's job is registering
# a permanent NVRAM boot entry for optical/removable install media, which
# this ISO doesn't need (El Torito + the GPT-hybrid ESP already make it
# directly bootable); mmx64.efi (MokManager, the actual thing the contract
# needs for post-install enrollment) works standalone and is unaffected.
# ---------------------------------------------------------------------------
shim="$ROOTFS/usr/lib/shim/shimx64.efi.signed"
grub="$ROOTFS/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
mmx64="$ROOTFS/usr/lib/shim/mmx64.efi.signed"
for f in "$shim" "$grub" "$mmx64"; do
    [[ -f "$f" ]] || { echo "Error: missing signed boot component: $f" >&2; exit 1; }
done

kernel_dir=$(find "$ROOTFS/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n1 || true)
[[ -n "$kernel_dir" ]] || { echo "Error: no kernel found under $ROOTFS/usr/lib/modules" >&2; exit 1; }
kver=$(basename "$kernel_dir")
vmlinuz="$ROOTFS/boot/vmlinuz-$kver"
[[ -f "$vmlinuz" ]] || { echo "Error: vmlinuz-$kver not found under $ROOTFS/boot" >&2; exit 1; }
echo "  kernel:  $kver"

# ---------------------------------------------------------------------------
# 1b. Stamp the version into the packed rootfs. VERSION is only known at ISO
#     ASSEMBLY time (this script), not at mkosi BUILD time (the rootfs was
#     already built by `mkosi --profile firn-installer build` before this
#     script ever runs) -- so this file cannot be baked in by the profile's
#     own postinst the way e.g. /etc/os-release is. A booted installer reads
#     this to report which installer build it is running from, independent
#     of the ISO filename (which may not survive being written to physical
#     media / re-labeled by imaging tools).
# ---------------------------------------------------------------------------
printf 'SNOSI_INSTALLER_VERSION=%s\nSNOSI_INSTALLER_BUILD_ID=firn-installer\n' "$VERSION" \
    >"$ROOTFS/etc/snosi-installer-release"

# ---------------------------------------------------------------------------
# 2. Pack the whole rootfs as the initramfs. Excludes the Debian-generated
#    /boot/{vmlinuz,initrd.img,System.map,config}-* -- the kernel and initrd
#    that actually boot are supplied externally by GRUB, so shipping a
#    second, unused, initramfs-tools-built initrd inside our own initramfs
#    would just be dead weight.
# ---------------------------------------------------------------------------
echo "=== Packing initramfs from rootfs ==="
initrd="$WORK/initrd.img"
# find AND cpio must run in the SAME subshell: a `cd` in a subshell that is
# only the first stage of a pipe does not affect the next pipeline stage
# (cpio is a separate process inheriting the ORIGINAL cwd, not the
# subshell's) -- confirmed live, cpio failed every path with "Cannot stat:
# No such file or directory" until find+cpio were nested inside one `(
# cd ... ; find | cpio )` and only that subshell's stdout piped to zstd.
(
    cd "$ROOTFS"
    find . \
        \( -path ./boot/vmlinuz-\* -o -path ./boot/initrd.img-\* \
           -o -path ./boot/System.map-\* -o -path ./boot/config-\* \) -prune -o \
        -print0 | cpio --null -o -H newc -R +0:+0 2>"$WORK/cpio.log"
) | zstd -T0 -q -o "$initrd"
echo "  initrd: $(du -h "$initrd" | cut -f1)"

# ---------------------------------------------------------------------------
# 3. grub.cfg -- non-interactive (timeout=0), no serial terminal dependency
#    on GRUB itself (only the kernel needs console=ttyS0; GRUB's own text
#    output isn't asserted on and the monolithic signed image's exact
#    compiled-in module set, e.g. whether `serial`/`terminal_output` are
#    present, was not independently verified).
#
# DUAL console: `console=tty0 console=ttyS0,115200n8`. firn is THE snosi
# installer, including on desktop/laptop hardware with a GPU and no serial
# port -- there the VGA console must render (a serial-only cmdline boots such
# a machine blind: blank screen, blinking cursor, the firn TUI drawing to a
# tty1 the kernel never lit up). So tty0 comes first (VGA gets kernel output
# and a live VT for firn-kiosk.service), ttyS0 second for headless/serial.
#
# KNOWN HANG, preserved from the native-installer lineage and re-scoped:
# adding `console=tty0` was root-caused to hang PID 1 SILENTLY in ONE narrow
# config -- Secure Boot enforced against a POPULATED Microsoft varstore (the
# ms.fd QEMU fixture the boot-chain PROOF test uses) with NO GPU device.
# Isolated to a single kernel arg, reproduced even with rdinit=/bin/bash, and
# read as an OVMF GOP/console-negotiation quirk of that fixture, not a defect
# here. It does NOT affect: single-console boots, dual-console against a
# non-SB or empty/setup-mode varstore, or real hardware with a GPU. firn's
# own installer-ISO E2E (test/firn-installer-iso-test.sh) boots SB-off, and
# the demo path is SB-off -- both unaffected. If a future SB-ENFORCED firn-ISO
# boot test is added against ms.fd, it must account for this (test serial-only
# there, or supply a GPU device) rather than dropping tty0 and re-blinding
# every desktop install.
# ---------------------------------------------------------------------------
cat >"$WORK/grub.cfg" <<'EOF'
set timeout=0
set default=0

menuentry "Snosi Installer" {
    search --no-floppy --set=root --file /firn-installer/vmlinuz
    linux /firn-installer/vmlinuz console=tty0 console=ttyS0,115200n8 ro
    initrd /firn-installer/initrd.img
}
EOF

# ---------------------------------------------------------------------------
# 4. Build the ESP FAT image (mtools -- no loop mount, no root needed for
#    this part specifically, though the script as a whole must run as root
#    to have read the rootfs in step 2).
# ---------------------------------------------------------------------------
echo "=== Building ESP image ==="
content_bytes=$(( $(stat -c%s "$shim") + $(stat -c%s "$grub") + $(stat -c%s "$mmx64") \
    + $(stat -c%s "$vmlinuz") + $(stat -c%s "$initrd") + 1048576 ))
# 15% headroom for FAT overhead/cluster rounding, minimum 64MiB.
esp_mib=$(( content_bytes * 115 / 100 / 1048576 + 1 ))
(( esp_mib < 64 )) && esp_mib=64
esp_img="$WORK/esp.img"
echo "  ESP size: ${esp_mib}MiB"
truncate -s "${esp_mib}M" "$esp_img"
mkfs.vfat -F 32 -n SNOSI_ESP "$esp_img" >/dev/null

mmd -i "$esp_img" ::EFI ::EFI/BOOT ::EFI/debian ::firn-installer
mcopy -i "$esp_img" "$shim" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$esp_img" "$grub" ::EFI/BOOT/grubx64.efi
mcopy -i "$esp_img" "$mmx64" ::EFI/BOOT/mmx64.efi
# Also ship grub/mmx64 alongside grub.cfg at the baked-in prefix directory.
# Not load-bearing for shim's own second-stage lookup (that only ever looks
# in shim's own directory, EFI/BOOT/) but keeps the conventional Debian ESP
# layout self-describing/inspectable. Deliberately no fbx64.efi anywhere on
# this ESP -- see the step-1 comment above.
mcopy -i "$esp_img" "$grub" ::EFI/debian/grubx64.efi
mcopy -i "$esp_img" "$mmx64" ::EFI/debian/mmx64.efi
mcopy -i "$esp_img" "$WORK/grub.cfg" ::EFI/debian/grub.cfg
mcopy -i "$esp_img" "$vmlinuz" ::firn-installer/vmlinuz
mcopy -i "$esp_img" "$initrd" ::firn-installer/initrd.img

# ---------------------------------------------------------------------------
# 5. Assemble the hybrid GPT+ESP El Torito ISO. UEFI-only (no BIOS/legacy
#    boot catalog entry): Secure Boot enforcement is the whole point of this
#    profile, and a legacy fallback path would just be an unenforced escape
#    hatch. -appended_part_as_gpt makes xorriso also emit a real GPT
#    partition table (not just an El Torito boot catalog entry) with an ESP
#    type-code partition, which is what real UEFI firmware (and OVMF) uses
#    to discover the ESP directly, the same "hybrid ISO" construction
#    systemd-boot/mkosi's own ISO-capable tooling and most UEFI live media
#    use.
# ---------------------------------------------------------------------------
echo "=== Assembling ISO ==="
# grub.cfg is ALSO placed directly in the ISO9660 tree at the same path,
# not only inside the appended FAT ESP partition -- confirmed live: booting
# via real El Torito/CD-ROM emulation (as opposed to a raw GPT/virtio-blk
# disk), GRUB's own prefix/root resolution lands on the ISO9660 volume
# itself, not the appended partition, so a grub.cfg that exists ONLY in the
# FAT ESP is invisible to it and GRUB drops to a bare `grub>` prompt
# instead of auto-booting. The big kernel/initramfs stay ESP-only (no
# point doubling ~190MiB): grub.cfg's `search --file` command scans EVERY
# visible filesystem for them and repoints $root at whichever device
# actually has them, regardless of which device GRUB itself started from.
mkdir -p "$WORK/iso-root/EFI/debian"
cp "$WORK/grub.cfg" "$WORK/iso-root/EFI/debian/grub.cfg"

# ---------------------------------------------------------------------------
# 5b. OPTIONAL offline flatpak seed (firn ADR-0006 media obligation). The seed
#     is a pre-built flatpak system installation tree (the core desktop apps +
#     their runtimes, produced by `just firn-flatpak-seed`); FIRN_FLATPAK_SEED_DIR
#     points at it. It is added as a squashfs FILE in the ISO9660 tree
#     (firn-flatpak-seed.squashfs) -- a DATA AREA, NOT part of the initramfs:
#     the initramfs (step 2) is unpacked entirely into tmpfs at boot and the
#     RAM budget cannot absorb a multi-GiB flatpak repo. The squashfs stays on
#     the physical medium; firn-flatpak-seed.service loop-mounts it read-only at
#     /var/lib/flatpak at runtime, where firn's flatpak step copies it into the
#     target (internal/flatpak/flatpak.go, hostFlatpakDir=/var/lib/flatpak).
#
#     -all-root makes every file in the squashfs uid/gid 0 regardless of the
#     (unprivileged) user that ran `just firn-flatpak-seed`, so the mounted
#     /var/lib/flatpak presents as root-owned exactly like a real system
#     installation and firn's tar-copy carries root ownership into the target.
#
#     OPTIONAL by design: an unset/absent seed dir builds a seedless ISO and
#     firn falls back to network at install time (ADR-0006 report-don't-fail).
#     A missing seed is NEVER a build failure.
# ---------------------------------------------------------------------------
if [[ -n "${FIRN_FLATPAK_SEED_DIR:-}" ]]; then
    if [[ -d "$FIRN_FLATPAK_SEED_DIR/repo" ]]; then
        command -v mksquashfs >/dev/null || {
            echo "Error: FIRN_FLATPAK_SEED_DIR set but mksquashfs not found (install squashfs-tools)" >&2; exit 1; }
        echo "=== Adding flatpak seed (squashfs data area, outside initramfs) ==="
        echo "  seed src: $FIRN_FLATPAK_SEED_DIR ($(du -sh "$FIRN_FLATPAK_SEED_DIR" | cut -f1))"
        mksquashfs "$FIRN_FLATPAK_SEED_DIR" "$WORK/iso-root/firn-flatpak-seed.squashfs" \
            -all-root -comp zstd -noappend >"$WORK/mksquashfs.log" 2>&1 \
            || { cat "$WORK/mksquashfs.log" >&2; exit 1; }
        echo "  seed squashfs: $(du -h "$WORK/iso-root/firn-flatpak-seed.squashfs" | cut -f1)"
    else
        # A path was given but has no ostree repo/ -- treat as a build mistake
        # (empty/half-built seed), not the "no seed at all" fast path.
        echo "Error: FIRN_FLATPAK_SEED_DIR=$FIRN_FLATPAK_SEED_DIR has no repo/ subdir -- not a flatpak seed tree" >&2
        exit 1
    fi
else
    echo "=== No flatpak seed (FIRN_FLATPAK_SEED_DIR unset); ISO relies on network at install time (ADR-0006) ==="
fi
# "SNOSI_INSTALLER_<14-digit version>" is 30 d-characters (uppercase/digit/
# underscore), within ISO9660's 32-character primary volume-identifier limit.
# The prefix is the installer-medium refusal contract: both firn and
# snosi-install refuse to install ONTO a device whose volume ID matches
# SNOSI_INSTALLER_* -- keep it byte-identical to native-installer's.
volid="SNOSI_INSTALLER_${VERSION}"
xorriso -as mkisofs \
    -iso-level 3 \
    -volid "$volid" \
    -appended_part_as_gpt \
    -partition_offset 16 \
    -no-emul-boot \
    -eltorito-alt-boot \
    -e --interval:appended_partition_2:all:: \
    -append_partition 2 0xef "$esp_img" \
    -output "$ISO_OUT" \
    "$WORK/iso-root" \
    >"$WORK/xorriso.log" 2>&1 || { cat "$WORK/xorriso.log" >&2; exit 1; }

echo "=== ISO built: $ISO_OUT ==="
sha256sum "$ISO_OUT"
echo "ISO_PATH=$ISO_OUT"
