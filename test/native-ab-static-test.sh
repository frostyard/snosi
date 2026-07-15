#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ab="$root/shared/outformat/ab-root"

[[ -f "$ab/tree/usr/lib/snosi/native-ab" ]]
[[ ! -e "$ab/tree/usr/lib/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" ]]
[[ ! -e "$ab/tree/usr/lib/systemd/system/snosi-etc-overlay.service" ]]
if grep -q '^MachineId=' "$ab/mkosi.conf"; then
    echo "Native A/B image must use golden-image machine-id semantics" >&2
    exit 1
fi
grep -q '^KernelCommandLine=.*rd\.etc\.overlay=1' "$ab/mkosi.conf"
grep -q '^Initrds=$' "$ab/mkosi.conf"
grep -q '^KernelModulesInitrd=no$' "$ab/mkosi.conf"
grep -q '^KernelCommandLine=.*rd\.luks=1' "$ab/mkosi.conf"
if grep -q '^KernelModules=' "$ab/mkosi.conf"; then
    echo "Generic ab-root fragment must not carry a final-root KernelModules= filter (docs/native-ab-contracts.md §9)" >&2
    exit 1
fi
# Production channels ship the full module set unconditionally (dm_crypt
# included). The one remaining KernelModules= filter is the QEMU-only dev
# fixture's own -- verify it still includes dm_crypt so LUKS /var unlock
# keeps working there too.
grep -q '^[[:space:]]*dm_crypt$' "$root/mkosi.profiles/cayo-ab-raw/mkosi.conf"

# The native ab-root override of the base image's bootc dracut.conf.d file
# only works because ExtraTrees= composition overwrites files at IDENTICAL
# relative paths (last ExtraTrees= wins) -- find whichever base file adds
# the "bootc" dracut module and assert ab-root's tree carries a file at that
# exact same relative path. If a future rename ever let both survive
# assembly, dracut would load both and re-add the bootc dracut module
# (composefs boot) to an image that must never carry it.
base_bootc_conf="$(grep -rl 'add_dracutmodules.*\bbootc\b' \
    "$root/mkosi.images/base/mkosi.extra/usr/lib/dracut/dracut.conf.d" 2>/dev/null | head -1)"
if [[ -z "$base_bootc_conf" ]]; then
    echo "No base dracut.conf.d file adds the bootc dracut module -- update this check" >&2
    exit 1
fi
base_rel="${base_bootc_conf#"$root"/mkosi.images/base/mkosi.extra/}"
ab_shadow="$ab/tree/$base_rel"
if [[ ! -f "$ab_shadow" ]]; then
    echo "ab-root tree does not shadow $base_rel at the identical relative path ($ab_shadow missing) -- both the base bootc-module file and the native override would survive ExtraTrees composition" >&2
    exit 1
fi

grep -q 'ARTIFACTDIR/io\.mkosi\.initrd' \
    "$root/shared/kernel/scripts/postinst/mkosi.postinst.chroot"
grep -q 'systemd-veritysetup' \
    "$ab/tree/usr/lib/dracut/modules.d/95etc-overlay/module-setup.sh"
grep -q 'chmod 0755.*snosi-etc-overlay-initrd' \
    "$ab/tree/usr/lib/dracut/modules.d/95etc-overlay/module-setup.sh"
grep -q 'initrd-root-fs.target.d' \
    "$ab/tree/usr/lib/dracut/modules.d/95etc-overlay/module-setup.sh"
grep -q '^Wants=snosi-etc-overlay-initrd.service$' \
    "$ab/tree/usr/lib/dracut/modules.d/95etc-overlay/10-snosi-etc-overlay.conf"
grep -q '^Before=initrd-root-fs.target initrd-switch-root.target$' \
    "$ab/tree/usr/lib/dracut/modules.d/95etc-overlay/snosi-etc-overlay-initrd.service"
if grep -q '^ConditionKernelCommandLine=' \
    "$ab/tree/usr/lib/dracut/modules.d/95etc-overlay/snosi-etc-overlay-initrd.service"; then
    echo "The initrd executable owns the kernel-command-line gate" >&2
    exit 1
fi
grep -q 'getargbool 0 rd\.etc\.overlay' \
    "$ab/tree/usr/lib/dracut/modules.d/95etc-overlay/etc-overlay-mount.sh"
grep -q 'var_device=/dev/mapper/var' \
    "$ab/tree/usr/lib/dracut/modules.d/95etc-overlay/etc-overlay-mount.sh"
grep -q 'systemd-cryptsetup attach var' \
    "$ab/tree/usr/lib/dracut/modules.d/95etc-overlay/etc-overlay-mount.sh"
grep -q 'blkid -p -s TYPE -o value' \
    "$ab/tree/usr/lib/dracut/modules.d/95etc-overlay/etc-overlay-mount.sh"
grep -q '^After=sysroot.mount cryptsetup.target$' \
    "$ab/tree/usr/lib/dracut/modules.d/95etc-overlay/snosi-etc-overlay-initrd.service"

secure="$root/mkosi.profiles/cayo-ab-secure/mkosi.conf"
forky_tree="$root/shared/cayo-ab-secure/package-manager/etc/apt"
grep -q '^Bootloader=systemd-boot$' "$secure"
grep -q '^ShimBootloader=signed$' "$secure"
grep -q '^UnifiedKernelImages=unsigned$' "$secure"
grep -q '^SecureBoot=yes$' "$secure"
grep -q '^SecureBootAutoEnroll=no$' "$secure"
grep -q '^SignExpectedPcr=yes$' "$secure"
grep -q '^SandboxTrees=%D/shared/cayo-ab-secure/package-manager$' "$secure"
grep -q '^ExtraSearchPaths=%D/shared/cayo-ab-secure/tools$' "$secure"
grep -q '^SandboxTrees=%D/.snosi-private/history:/usr/lib/snosi-pcr-history$' "$secure"
grep -q '^Environment=PCR_SIGNING_KEY_PREVIOUS$' "$secure"
[[ -x "$root/shared/cayo-ab-secure/tools/ukify" ]]
grep -q 'PCR_SIGNING_KEY_PREVIOUS' "$root/shared/cayo-ab-secure/tools/ukify"
grep -q '^Suites: forky$' "$forky_tree/sources.list.d/forky.sources"
grep -q '^Pin: release n=forky$' "$forky_tree/preferences.d/forky"
grep -q '^Pin-Priority: 50$' "$forky_tree/preferences.d/forky"
for package in libnss-myhostname libnss-mymachines libnss-systemd \
    libpam-systemd libsystemd-shared libsystemd0 libudev1 systemd \
    systemd-boot systemd-boot-efi systemd-boot-tools systemd-container \
    systemd-cryptsetup systemd-repart systemd-resolved systemd-sysv \
    systemd-timesyncd systemd-tpm udev; do
    grep -q "^[[:space:]]*$package/forky$" "$secure"
done
if grep -q 'grub-efi-amd64-signed' "$secure"; then
    exit 1
fi
grep -q '^[[:space:]]*shim-signed$' "$secure"
if grep -Rqi forky "$root/mkosi.conf" "$root/mkosi.images" \
    "$root/mkosi.profiles/cayo-ab-raw" "$root/mkosi.sandbox"; then
    echo "Forky must remain isolated to cayo-ab-secure" >&2
    exit 1
fi

installer="$root/test/cayo-ab-install-spike.sh"
grep -q -- '--encrypt-var' "$installer"
grep -qF -- "--tpm2-pcrs= \\" "$installer"
grep -qF -- "--tpm2-pcrlock= \\" "$installer"
if grep -q -- '--tpm2-pcrs=7' "$installer"; then
    exit 1
fi
grep -q -- '--tpm2-public-key-pcrs=11' "$installer"
grep -q 'mokutil --import' "$installer"
grep -q 'cryptsetup luksFormat --type luks2' "$installer"

nvpcr_finalize="$root/shared/cayo-ab-secure/finalize/disable-nvpcr.chroot"
[[ -x "$nvpcr_finalize" ]]
grep -q '/usr/lib/nvpcr/\*\.nvpcr' "$nvpcr_finalize"
grep -q '/etc/systemd/system/systemd-pcrproduct.service' "$nvpcr_finalize"
grep -q '/etc/systemd/system/systemd-pcrlogin@\.service' "$nvpcr_finalize"
grep -q 'FinalizeScripts=%D/shared/cayo-ab-secure/finalize/disable-nvpcr.chroot' "$secure"

rotation_test="$root/test/native-ab-secure-rotation-test.sh"
secure_update_test="$root/test/native-ab-secure-update-test.sh"
negative_test="$root/test/native-ab-secure-artifact-negative-test.sh"
[[ -x "$rotation_test" ]]
[[ -x "$secure_update_test" ]]
[[ -x "$negative_test" ]]
grep -q 'EXPECTED_MACHINE_ID' "$rotation_test"
grep -q 'open --test-passphrase' "$rotation_test"
grep -q 'assert_only_tpm_token.*old_fingerprint' "$rotation_test"
grep -q 'assert_only_tpm_token.*new_fingerprint' "$rotation_test"
grep -q 'systemd-sysupdate' "$rotation_test"
grep -q '^Verify=yes$' "$rotation_test"
if grep -q '^Verify=no$' "$rotation_test"; then
    echo "Secure rotation transfers must verify their signed manifest" >&2
    exit 1
fi
grep -q 'tampered signed manifest' "$rotation_test"
grep -q 'root payload checksum mismatch' "$rotation_test"
grep -q 'systemd-sysupdate.*vacuum' "$rotation_test"
grep -q 'EXPECTED_MACHINE_ID' "$secure_update_test"
grep -q 'INCUS_INSTANCE' "$secure_update_test"
grep -q '^Verify=yes$' "$secure_update_test"
grep -q 'bootctl set-oneshot' "$secure_update_test"
grep -q 'Entering emergency mode' "$secure_update_test"
grep -q 'stop.*--force' "$secure_update_test"
grep -q 'assert_new_only_token' "$secure_update_test"
grep -q 'systemd-pcrproduct.service systemd-pcrlogin@0.service' "$secure_update_test"
grep -q 'rearmed_entry=.*+3-0\.efi' "$secure_update_test"
grep -q 'N+3 was not blessed before boot-count re-arming' "$secure_update_test"
grep -q '\.sha256\[0\]\.pol = \.sha256\[1\]\.pol' "$negative_test"
grep -q -- '--update-section.*\.pcrpkey' "$negative_test"

# The 3 OS transfers moved from the generic ab-root tree to the per-product
# channel fragment (Phase 3, docs/native-ab-contracts.md §5); cayo is the
# channel exercised by both cayo-ab-raw and cayo-ab-secure.
channel="$root/shared/native-ab/channels/cayo"
for transfer in 10-root-verity 20-root 90-uki; do
    file="$channel/tree/usr/lib/sysupdate.d/$transfer.transfer"
    [[ -f "$file" ]]
    grep -q '^Verify=yes$' "$file"
    grep -q '^ProtectVersion=%A$' "$file"
    grep -q '^InstancesMax=2$' "$file"
done
grep -q '^PartitionFlags=0$' "$channel/tree/usr/lib/sysupdate.d/10-root-verity.transfer"
grep -q '^PartitionFlags=0$' "$channel/tree/usr/lib/sysupdate.d/20-root.transfer"

grep -q 'MatchPattern=cayo-ab_@v_@u.root-verity.raw.xz' \
    "$channel/tree/usr/lib/sysupdate.d/10-root-verity.transfer"
grep -q 'MatchPattern=cayo-ab_@v_@u.root.raw.xz' \
    "$channel/tree/usr/lib/sysupdate.d/20-root.transfer"
grep -q '^TriesLeft=3$' "$channel/tree/usr/lib/sysupdate.d/90-uki.transfer"
grep -q '^Path=/EFI/Linux$' "$channel/tree/usr/lib/sysupdate.d/90-uki.transfer"
grep -q '^disable systemd-sysupdate.timer$' \
    "$ab/tree/usr/lib/systemd/system-preset/00-native-ab.preset"
grep -q '^disable systemd-sysupdate-reboot.timer$' \
    "$ab/tree/usr/lib/systemd/system-preset/00-native-ab.preset"
grep -q 'ln -sf /dev/null /etc/systemd/system/systemd-sysupdate.timer' \
    "$root/shared/outformat/image/finalize/mkosi.finalize.chroot"
grep -q 'ln -sf /dev/null /etc/systemd/system/systemd-sysupdate-reboot.timer' \
    "$root/shared/outformat/image/finalize/mkosi.finalize.chroot"

# ---------------------------------------------------------------------------
# Native updater isolation: bootc and nbc units must never activate on native
# images. The base image ships their unit files unconditionally (shared by
# the bootc profiles and the native A/B profiles), so native ExtraTrees must
# mask each one with a same-named /dev/null symlink -- the same mechanism
# already used for systemd-growfs-root.service. Upstream's own
# bootc-fetch-apply-updates.timer/.service ship inside the `bootc` deb itself
# (via shared/packages/bootc/mkosi.conf), which only the bootc profiles
# Include=; native profiles never install that package, so those two units
# are never present on native images and need no mask here.
assert_masked() { # relpath-under-tree
    local target="$ab/tree/usr/lib/systemd/$1"
    [[ -L "$target" ]] || { echo "Missing mask symlink: $target" >&2; exit 1; }
    [[ "$(readlink "$target")" == /dev/null ]] || {
        echo "Not masked to /dev/null: $target" >&2
        exit 1
    }
}

for unit in system/bootc-update-stage.timer system/bootc-update-stage.service \
    system/nbc-update-download.timer system/nbc-update-download.service; do
    base_unit="$root/mkosi.images/base/mkosi.extra/usr/lib/systemd/$unit"
    [[ -f "$base_unit" ]] || { echo "Expected base unit missing: $base_unit" >&2; exit 1; }
    assert_masked "$unit"
done

for unit in user/bootc-update-notify.path user/bootc-update-notify.service; do
    base_unit="$root/mkosi.images/base/mkosi.extra/usr/lib/systemd/$unit"
    if [[ -f "$base_unit" ]]; then
        assert_masked "$unit"
    fi
done

echo "Native A/B static validation passed"
