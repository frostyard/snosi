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
grep -Fq 'sudo apt-get install --yes --no-install-recommends dracut-core' \
    "$root/.github/workflows/build-images.yml"

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
    sbsigntool; do
    grep -qE "^(Packages=|[[:space:]]*)$package$" "$secure"
done

# Directory-format bootc profiles do not build a UKI through mkosi, so
# KernelCommandLine= is inert. Pinned bootc 1.16.3 reads sorted *.toml files
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
python3 - "$contract" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    contract = json.load(f)

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
        "compatibility": "bootc-1.16.3-storage-digest-v1",
        "bootc_version": "1.16.3",
        "storage_digest_command": "bootc container compute-composefs-digest-from-storage",
        "ukify": "direct-two-pass",
    },
}
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
grep -Fqx '    backing=$(cryptsetup status root | awk '\''/^[[:space:]]*device:/{print $2; exit}'\'')' "$reconciler"

# Only OCI bootc profiles consume the fragment. Native A/B, including the raw
# fixture, must remain entirely independent of its packages and trust files.
for profile in cayo snow snowfield; do
    grep -q '^Include=%D/shared/bootc-secure/mkosi.conf$' \
        "$root/mkosi.profiles/$profile/mkosi.conf"
done
for profile in cayo-ab-raw cayo-ab snow-ab snowfield-ab; do
    if grep -q 'shared/bootc-secure' "$root/mkosi.profiles/$profile/mkosi.conf"; then
        echo "native profile $profile must not include the bootc secure fragment" >&2
        exit 1
    fi
done

echo "Bootc secure static validation passed"
