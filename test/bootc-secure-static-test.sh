#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static contract for the bootc-only secure composition (Task 4).
# shellcheck disable=SC2016 # Exact literal source assertion below.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secure="$root/shared/bootc-secure/mkosi.conf"
tree="$root/shared/bootc-secure/tree"
package_manager="$root/shared/bootc-secure/package-manager"
artifact_validator="$root/test/bootc-secure-artifact-test.sh"

# Live validation executes the candidate image's pinned bootc through Podman;
# it must not depend on an independently installed host bootc.
grep -Fq 'for command in buildah jq objcopy objdump openssl podman sbverify; do' \
    "$artifact_validator"
if grep -Eq '^for command in .*\bbootc\b' "$artifact_validator"; then
    echo "bootc secure artifact validation must use candidate-image bootc, not host bootc" >&2
    exit 1
fi

# Exercise the exact initramfs generator with forced GPT discovery. This catches
# missing binaries and cryptsetup build support, but deliberately does not claim
# to reproduce production EFI discovery or the runtime failure in issue 517.
grep -Fq "SYSTEMD_PROC_CMDLINE='root=gpt-auto-force'" "$artifact_validator"
grep -Fq 'chroot "$initrd_root" "$generator"' "$artifact_validator"
grep -Fq 'late/systemd-cryptsetup@root.service' "$artifact_validator"
grep -Fq "'/dev/gpt-auto-root-luks'" "$artifact_validator"
grep -Fq 'objcopy --dump-section ".initrd=$initrd" "$uki" "$scratch/uki.copy"' \
    "$artifact_validator"
grep -Fq 'gpt_auto_fixture' "$artifact_validator"
grep -Fq 'SNOSI_REQUIRE_GPT_AUTO_VALIDATION=1' \
    "$root/.github/workflows/build-images.yml"
grep -Fq 'sudo apt-get install --yes --no-install-recommends dracut-core zstd' \
    "$root/.github/workflows/build-images.yml"
grep -Fq 'if ! (' "$artifact_validator"
grep -Fq 'Error: failed to unpack the UKI initramfs with lsinitrd' \
    "$artifact_validator"
grep -Fq "ExecStart=/usr/bin/systemd-cryptsetup attach 'root' '/dev/gpt-auto-root-luks' '' ''" \
    "$artifact_validator"

# Issue 517: systemd 261 moved the gpt-auto-root/-luks udev symlink rules into
# 90-image-dissect.rules, which dracut does not install by default. The secure
# tree must force it into the initramfs, and the artifact validator must fail
# any initramfs that cannot create /dev/gpt-auto-root-luks.
gpt_auto_dracut_conf="$tree/usr/lib/dracut/dracut.conf.d/35-gpt-auto-udev-rules.conf"
[[ -f "$gpt_auto_dracut_conf" ]]
grep -Fqx 'install_items+=" /usr/lib/udev/rules.d/90-image-dissect.rules "' \
    "$gpt_auto_dracut_conf"
grep -Fq 'SYMLINK+="gpt-auto-root-luks"' "$artifact_validator"
grep -Fq 'no udev rule creating /dev/gpt-auto-root-luks' "$artifact_validator"

# systemd 261 cannot migrate its NvPCR anchor between PCR signing keys, and a
# replaced TPM makes the anchor unreadable outright. The secure bootc profiles
# do not consume NvPCR attestation, so the stale-anchor consumers are masked --
# exactly as shared/native-ab-secure/finalize/disable-nvpcr.chroot already does
# for the native profiles.
#
# Unmasked, they fail permanently after a TPM replacement:
#     TPM key integrity check failed. Key most likely does not belong to this TPM.
# leaving a recovered system degraded forever. Observed on run 31235071207.
# The native decision simply had not been carried across to bootc.
#
# Masks are /dev/null symlinks in the shipped tree, the same mechanism ab-root
# uses for the bootc/nbc updater units. SRK setup and the signed-PCR-11 LUKS
# path are deliberately NOT masked -- those are load-bearing.
for masked in systemd-pcrproduct.service 'systemd-pcrlogin@.service'; do
    mask="$tree/usr/lib/systemd/system/$masked"
    [[ -L "$mask" && $(readlink "$mask") == /dev/null ]] || {
        echo "bootc secure tree must mask $masked with a /dev/null symlink" >&2
        exit 1
    }
done
for kept in systemd-tpm2-setup.service systemd-tpm2-setup-early.service; do
    [[ -e "$tree/usr/lib/systemd/system/$kept" ]] && {
        echo "bootc secure tree must NOT mask $kept; SRK setup is required" >&2
        exit 1
    }
done

# Masking the two consumer units is NOT sufficient, and assuming it was cost a
# live run. systemd-tpm2-setup{,-early} also reach for the anchor --
# "Failed to acquire anchor secret: Object is remote" -- and they cannot be
# masked because SRK setup is required. Removing the DEFINITIONS is what stops
# anything asking for an anchor at all, which is why native does both and this
# must too.
nvpcr_finalize="$root/shared/bootc-secure/finalize/disable-nvpcr.chroot"
[[ -x "$nvpcr_finalize" ]] || {
    echo "bootc secure must ship an executable disable-nvpcr finalize script" >&2
    exit 1
}
grep -Fq '/usr/lib/nvpcr/*.nvpcr' "$nvpcr_finalize"
grep -Fq 'ln -sfn /dev/null "/etc/nvpcr/' "$nvpcr_finalize"
grep -Fq 'FinalizeScripts=%D/shared/bootc-secure/finalize/disable-nvpcr.chroot' \
    "$root/shared/bootc-secure/mkosi.conf"
# SRK setup must survive: the finalize must not mask those units either.
# Comments are stripped first -- the script explains at length WHY it leaves
# systemd-tpm2-setup alone, and that prose must not trip the guard against
# touching it. (A grep that matches its own documentation is a recurring shape
# in this repo; it already caught the ssh_private_key check once.)
if sed 's/#.*//' "$nvpcr_finalize" | grep -Fq 'systemd-tpm2-setup'; then
    echo "disable-nvpcr must not touch systemd-tpm2-setup; SRK setup is required" >&2
    exit 1
fi

[[ -f "$secure" ]]
[[ -f "$package_manager/etc/apt/sources.list.d/forky.sources" ]]
[[ -f "$package_manager/etc/apt/preferences.d/forky" ]]
grep -q '^Suites: forky$' "$package_manager/etc/apt/sources.list.d/forky.sources"
grep -q '^Pin: release n=forky$' "$package_manager/etc/apt/preferences.d/forky"
grep -q '^Pin-Priority: 50$' "$package_manager/etc/apt/preferences.d/forky"

# The selected systemd family must come from one suite, including every ABI
# companion that bootc, cryptsetup, and the bootloader use.
for package in libnss-myhostname libnss-mymachines libnss-systemd \
    libpam-systemd libsystemd-shared libsystemd0 libudev1 systemd \
    systemd-boot systemd-boot-efi systemd-boot-tools systemd-container \
    systemd-cryptsetup systemd-repart systemd-resolved systemd-sysv \
    systemd-timesyncd systemd-tpm systemd-ukify udev; do
    grep -qE "^(Packages=|[[:space:]]*)$package/forky$" "$secure"
done

# shim-signed is already supplied by the shared base image. Keeping it out of
# this fragment avoids a resolved duplicate while every bootc profile retains
# the package through its mandatory base dependency.
grep -qE '^(Packages=|[[:space:]]*)shim-signed$' \
    "$root/mkosi.images/base/mkosi.conf"
if grep -qE '^(Packages=|[[:space:]]*)shim-signed$' "$secure"; then
    echo "bootc secure fragment must not duplicate base shim-signed" >&2
    exit 1
fi

# TPM recovery and Task 5's UKI assembly dependencies are explicit rather than
# relying on incidental dependencies.
for package in mokutil cryptsetup cryptsetup-bin tpm2-tools \
    sbsigntool openssl; do
    grep -qE "^(Packages=|[[:space:]]*)$package$" "$secure"
done

# Directory-format bootc profiles do not build a UKI through mkosi, so
# KernelCommandLine= is inert. Pinned bootc 1.16.8 reads sorted *.toml files
# from /usr/lib/bootc/kargs.d; its strict schema requires a kargs array.
if grep -q '^KernelCommandLine=' "$secure"; then
    echo "bootc secure fragment must use bootc kargs.d, not mkosi KernelCommandLine=" >&2
    exit 1
fi
kargs="$tree/usr/lib/bootc/kargs.d/10-lockdown.toml"
[[ -f "$kargs" ]]
grep -Fqx 'kargs = ["lockdown=integrity"]' "$kargs"

[[ -s "$root/shared/native-ab/keys/mok-2026.crt" ]]
[[ -s "$root/shared/native-ab/keys/pcr-signing-2026.pub" ]]
grep -q '^ExtraTrees=%D/shared/native-ab/keys/mok-2026.crt:/usr/lib/snosi/mok.crt$' "$secure"
grep -q '^ExtraTrees=%D/shared/native-ab/keys/pcr-signing-2026.pub:/usr/lib/snosi/pcr-signing.pub$' "$secure"

contract="$tree/usr/lib/snosi/bootc-secure.json"
[[ -f "$contract" ]]
# shellcheck source=shared/bootc-secure/compatibility.sh
source "$root/shared/bootc-secure/compatibility.sh"
snosi_bootc_secure_load_compatibility "$contract"
[[ $BOOTC_SECURE_VERSION == "$(jq -er '.assembly.bootc_version' "$contract")" ]]
[[ $BOOTC_SECURE_ASSEMBLY_COMPATIBILITY == \
    "bootc-$BOOTC_SECURE_VERSION-storage-digest-v1" ]]

compatibility_fixture=$(mktemp)
trap 'rm -f "$compatibility_fixture"' EXIT
jq '.installer.minimum_versions.bootc = "9.9.9"' "$contract" \
    >"$compatibility_fixture"
if snosi_bootc_secure_load_compatibility "$compatibility_fixture" 2>/dev/null; then
    echo "inconsistent bootc compatibility contract was accepted" >&2
    exit 1
fi

python3 - "$contract" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    contract = json.load(f)

bootc_version = contract["assembly"]["bootc_version"]
assert {key: contract[key] for key in (
    "schema", "mok_certificate", "pcr_public_key", "encrypted_root_mapper",
    "systemd_suite", "assembly",
)} == {
    "schema": 1,
    "mok_certificate": "/usr/lib/snosi/mok.crt",
    "pcr_public_key": "/usr/lib/snosi/pcr-signing.pub",
    "encrypted_root_mapper": "root",
    "systemd_suite": "forky",
    "assembly": {
        "compatibility": f"bootc-{bootc_version}-storage-digest-v1",
        "bootc_version": bootc_version,
        "storage_digest_command": "bootc container compute-composefs-digest-from-storage",
        "ukify": "direct-two-pass",
    },
}
assert contract["installer"]["minimum_versions"]["bootc"] == bootc_version
PY

reconciler="$tree/usr/libexec/snosi-bootc-bootloader-reconcile"
unit="$tree/usr/lib/systemd/system/snosi-bootc-bootloader-reconcile.service"
wants="$tree/usr/lib/systemd/system/multi-user.target.wants/snosi-bootc-bootloader-reconcile.service"
[[ -x "$reconciler" && -f "$unit" && -L "$wants" ]]
grep -Fqx 'ExecStart=/usr/libexec/snosi-bootc-bootloader-reconcile' "$unit"
grep -Fqx 'After=local-fs.target' "$unit"
grep -Fqx 'Before=shutdown.target' "$unit"
if grep -q '^\[Install\]' "$unit"; then
    echo "bootloader reconciler must use static /usr activation, not [Install]" >&2
    exit 1
fi
[[ "$(readlink "$wants")" == ../snosi-bootc-bootloader-reconcile.service ]]
grep -Fq '/usr/lib/snosi/bootc/systemd-bootx64.efi' "$root/shared/bootc-secure/assemble-uki.sh"
grep -Fq 'snosi_esp_resolve "$RUN_DIR" root' "$reconciler"
grep -Fq '/usr/lib/snosi/esp.sh' "$reconciler"

# Only OCI bootc profiles consume the fragment. Native A/B, including the raw
# fixture, must remain entirely independent of its packages and trust files.
for profile in cayo snow snowfield flurry; do
    grep -q '^Include=%D/shared/bootc-secure/mkosi.conf$' \
        "$root/mkosi.profiles/$profile/mkosi.conf"
done
for profile in cayo-ab-raw cayo-ab snow-ab snowfield-ab; do
    if grep -q 'shared/bootc-secure' "$root/mkosi.profiles/$profile/mkosi.conf"; then
        echo "native profile $profile must not include the bootc secure fragment" >&2
        exit 1
    fi
done

# The install and update harnesses must not carry private copies of these.
# Independent copies are what produced the update leg's failure: type2_only
# had drifted to accept only `efi` while bootc writes `uki`, so it could never
# pass -- while the install harness asserted the same property and passed.
# Sixth defect of that shape in this subsystem; the shared library is the fix,
# and this check is what keeps it shared.
lib="$root/test/lib/bootc-secure-assertions.sh"
[[ -f "$lib" ]] || { echo "missing $lib" >&2; exit 1; }
for harness in "$root/test/bootc-secure-install-test.sh" "$root/test/bootc-secure-update-test.sh"; do
    grep -Fq 'test/lib/bootc-secure-assertions.sh' "$harness" || {
        echo "${harness##*/} must source the shared assertions library" >&2
        exit 1
    }
    for shared in esp_cat composefs_from_cmdline type2_only signed_pcr11_token root_backing_device; do
        if grep -Eq "^${shared}\(\)" "$harness"; then
            echo "${harness##*/} redefines ${shared}; it belongs to the shared library" >&2
            exit 1
        fi
    done
done
# bootc writes `uki`; requiring `efi` alone rejects every genuine install.
grep -Fq '(uki|efi)' "$lib"

# No guest command in these harnesses may reach into /boot. bootc mounts it only
# while it is using it, so every /boot path reports absent on a HEALTHY system:
# it produced "BLS entries are not Type #2-only" on one run and "no UKI at the
# composefs path" on the next, both for state that was present the whole time.
# Boot assets are read off the ESP (esp_cat) or from /usr.
#
# Comments are stripped first: the harnesses explain this at length, and that
# prose must not trip the guard. Same shape as the ssh_private_key check that
# matched its own documentation.
for harness in "$root/test/bootc-secure-install-test.sh" \
               "$root/test/bootc-secure-update-test.sh" \
               "$lib"; do
    if sed 's/#.*//' "$harness" | grep -Eq '(vm_ssh|scp)[^#]*/boot/'; then
        echo "${harness##*/} reaches into /boot in a guest command; use esp_cat" >&2
        sed 's/#.*//' "$harness" | grep -nE '(vm_ssh|scp)[^#]*/boot/' >&2
        exit 1
    fi
done

echo "Bootc secure static validation passed"
