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

# Upstream sysupdate timers have no default OS transfer on bootc images, and
# sysexts update through updex. All three masks (systemd 262 adds
# systemd-sysupdate-update.timer) must be unconditional, not hidden in a branch.
for timer in systemd-sysupdate.timer systemd-sysupdate-reboot.timer \
    systemd-sysupdate-update.timer; do
    if ! grep -Fqx "ln -sf /dev/null /etc/systemd/system/$timer" \
        "$root/shared/outformat/image/finalize/mkosi.finalize.chroot"; then
        echo "image finalize must mask $timer unconditionally" >&2
        exit 1
    fi
done

# updex is the only sysext updater (updex ADR-0016). Base enables its update
# timer through 05-updex.preset, so that preset must carry the exact enable
# line and the image finalize must NOT mask the timer: an /etc mask wins over
# the preset and would leave every install without automatic sysext updates.
updex_preset="$root/mkosi.images/base/mkosi.extra/usr/lib/systemd/system-preset/05-updex.preset"
grep -Fqx 'enable updex-update.timer' "$updex_preset"
if sed 's/#.*//' "$root/shared/outformat/image/finalize/mkosi.finalize.chroot" |
    grep -Fq 'updex-update.timer'; then
    echo "image finalize must not mask updex-update.timer" >&2
    exit 1
fi

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

# Issue 517: systemd 258 moved the gpt-auto-root/-luks udev symlink rules into
# 90-image-dissect.rules, which Trixie's dracut 106 does not install. The secure
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
# on the bootc profiles.
#
# Unmasked, they fail permanently after a TPM replacement:
#     TPM key integrity check failed. Key most likely does not belong to this TPM.
# leaving a recovered system degraded forever. Observed on run 31235071207.
#
# Masks are /dev/null symlinks in the shipped tree. SRK setup and the signed-PCR-11 LUKS
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
# anything asking for an anchor at all. systemd 262 removed the anchor but still needs the masks: see the
# finalize script.
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
pin_fixture=$(mktemp)
trap 'rm -f "${compatibility_fixture:-}" "${pin_fixture:-}"' EXIT
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

# Secure assembly uses bootc's hidden storage-digest command, so one validated
# Frostyard bootc/libostree package pair stays under the signed contract: a
# floating entry lets an APT index advance change the package without review.
# Run 40245723511 built all four rootfs products and then failed with
# `expected bootc 1.16.8, observed bootc 1.17.1`; run 40229646374 built these
# exact versions in all four products. Revalidate the complete pair whenever
# either package changes.
#
# These checks enforce selector values and agreement with
# assembly.bootc_version only; they cannot show that revalidation happened.
bootc_packages="$root/shared/packages/bootc/mkosi.conf"
bootc_pin=1.16.8-frostyard202610040153~deb13
libostree_pin=2026.3-frostyard202610040153~deb13

bootc_package_entries() { # mkosi-conf
    # Entries of the fragment's Packages= list, one per line. Indented comments
    # inside the continuation belong to the list and must not end it.
    awk '
        /^Packages=/ { print substr($0, 10); in_packages = 1; next }
        in_packages && /^[[:space:]]*#/ { next }
        in_packages && /^[[:space:]]+[^[:space:]]/ {
            sub(/^[[:space:]]+/, ""); print; next
        }
        { in_packages = 0 }
    ' "$1"
}

check_bootc_pair_pins() { # mkosi-conf
    local file=$1 entries entry package pinned
    entries=$(bootc_package_entries "$file")
    for entry in "bootc=$bootc_pin" "libostree-1-1=$libostree_pin"; do
        package=${entry%%=*}
        pinned=$(grep -E "^${package}(=.*)?$" <<<"$entries" || true)
        if [[ $pinned != "$entry" ]]; then
            echo "${file#"$root"/} must select exactly $entry (found: ${pinned:-none})" >&2
            return 1
        fi
    done
}

# The pinned bootc upstream version and the assembly contract name one version.
check_bootc_contract_version() { # mkosi-conf contract
    local file=$1 upstream pinned
    upstream=$(jq -er '.assembly.bootc_version' "$2")
    pinned=$(sed -n 's/^bootc=\([0-9][0-9.]*\)-[^[:space:]]*$/\1/p' \
        <<<"$(bootc_package_entries "$file")")
    if [[ $pinned != "$upstream" ]]; then
        echo "bootc pin ($pinned) must agree with .assembly.bootc_version ($upstream)" >&2
        return 1
    fi
}

check_bootc_pair_pins "$bootc_packages"
check_bootc_contract_version "$bootc_packages" \
    "$root/shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json"

# Negative cases: a removed or floating pin, and a pin that disagrees with the
# assembly contract, must each be rejected by the check that owns them.
sed '/^[[:space:]]*libostree-1-1=/d' "$bootc_packages" >"$pin_fixture"
if check_bootc_pair_pins "$pin_fixture" 2>/dev/null; then
    echo "a removed libostree pin was accepted" >&2
    exit 1
fi
sed 's/^Packages=bootc=.*$/Packages=bootc/' "$bootc_packages" >"$pin_fixture"
if check_bootc_pair_pins "$pin_fixture" 2>/dev/null; then
    echo "a floating bootc entry was accepted" >&2
    exit 1
fi
sed 's/^Packages=bootc=.*$/Packages=bootc=1.17.1-frostyard202610040153~deb13/' \
    "$bootc_packages" >"$pin_fixture"
if check_bootc_contract_version "$pin_fixture" \
    "$root/shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json" 2>/dev/null; then
    echo "a bootc pin that disagrees with the assembly contract was accepted" >&2
    exit 1
fi

# All OCI bootc profiles consume the pinned runtime and the secure fragment.
for profile in floe snow snowfield sundog; do
    grep -q '^Include=%D/shared/packages/bootc/mkosi.conf$' \
        "$root/mkosi.profiles/$profile/mkosi.conf" || {
        echo "$profile must consume the pinned bootc runtime" >&2
        exit 1
    }
    grep -q '^Include=%D/shared/bootc-secure/mkosi.conf$' \
        "$root/mkosi.profiles/$profile/mkosi.conf"
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

# The profile and OCI-reference grammar has one home too: the same library.
# The two profile sets are deliberate. The secure VM lanes cover floe, snow and
# snowfield; publication also accepts sundog, which publishes a secure OCI image
# but has no secure VM lane. The lane digest refs accept any hex digit, while a
# published digest is lowercase hex only.
for validator in valid_profile valid_digest_ref valid_tracking_ref \
                 valid_published_image valid_published_digest; do
    count=$(grep -Ec "^${validator}\(\)" "$lib")
    [[ $count -eq 1 ]] || {
        echo "$lib must define ${validator} exactly once (found $count)" >&2
        exit 1
    }
done

for consumer in "$root/test/bootc-secure-install-test.sh" \
                "$root/test/bootc-secure-update-test.sh" \
                "$root/test/bootc-secure-rotation-test.sh" \
                "$root/shared/bootc-secure/ci/verify-published-image.sh" \
                "$root/shared/bootc-secure/ci/promote-published-image.sh"; do
    grep -Fq 'test/lib/bootc-secure-assertions.sh' "$consumer" || {
        echo "${consumer#"$root/"} must source the shared assertions library" >&2
        exit 1
    }
    for validator in valid_profile validate_profile valid_oci_ref valid_digest_ref \
                     valid_tracking_ref valid_published_image valid_published_digest; do
        if grep -Eq "^${validator}\(\)" "$consumer"; then
            echo "${consumer#"$root/"} redefines ${validator}; it belongs to the shared library" >&2
            exit 1
        fi
    done
    # A product alternation in code means a copy of the grammar is back.
    # Comments are stripped first; the install harness prints
    # PROFILE=floe|snow|snowfield in a usage message, which has no parentheses
    # and must stay.
    if sed 's/#.*//' "$consumer" | grep -Eq '\(floe\|snow|frostyard/\('; then
        echo "${consumer#"$root/"} carries a product alternation; use the shared validators" >&2
        sed 's/#.*//' "$consumer" | grep -nE '\(floe\|snow|frostyard/\(' >&2
        exit 1
    fi
done

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
