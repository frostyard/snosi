#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Structural and live artifact validation for Task 5 bootc secure assembly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSEMBLER="$ROOT_DIR/shared/bootc-secure/assemble-uki.sh"

# This is a structural initramfs check. Forced discovery proves that the exact
# embedded generator can emit a root cryptsetup unit and has cryptsetup support;
# it does not exercise production EFI discovery or reproduce issue 517's VM
# failure. That remains the responsibility of the secure-install VM lane.
validate_gpt_auto_cryptsetup() (
    local uki scratch initrd initrd_root generator_root generator unit
    for command in chroot lsinitrd objcopy zstd; do
        if ! command -v "$command" >/dev/null; then
            if [[ ${SNOSI_REQUIRE_GPT_AUTO_VALIDATION:-0} == 1 ]]; then
                echo "Error: required initramfs gpt-auto validation is missing $command" >&2
                return 1
            fi
            echo "SKIP: initramfs gpt-auto validation requires $command" >&2
            return 0
        fi
    done
    if (( EUID != 0 )) && [[ ${SNOSI_GPT_AUTO_FIXTURE:-0} != 1 ]]; then
        if [[ ${SNOSI_REQUIRE_GPT_AUTO_VALIDATION:-0} == 1 ]]; then
            echo "Error: required initramfs gpt-auto validation needs root for chroot" >&2
            return 1
        fi
        echo "SKIP: initramfs gpt-auto validation requires root for chroot" >&2
        return 0
    fi

    uki=$(find "$ROOTFS/boot/EFI/Linux" -maxdepth 1 -type f -name '*.efi' -print -quit)
    [[ -n $uki ]] || { echo "Error: assembled UKI is missing" >&2; return 1; }

    scratch=$(mktemp -d)
    initrd="$scratch/initrd"
    initrd_root="$scratch/root"
    mkdir -p "$initrd_root"
    trap 'rm -rf "$scratch"' EXIT
    # objcopy rewrites its input when no output is named, stripping a PE's
    # Authenticode certificate table. Always write a disposable output and
    # leave the assembled, signed UKI byte-for-byte untouched.
    objcopy --dump-section ".initrd=$initrd" "$uki" "$scratch/uki.copy"
    if ! (
        cd "$initrd_root"
        lsinitrd --unpack "$initrd"
    ); then
        echo "Error: failed to unpack the UKI initramfs with lsinitrd" >&2
        return 1
    fi

    generator=/usr/lib/systemd/system-generators/systemd-gpt-auto-generator
    [[ -x "$initrd_root$generator" ]] || {
        echo "Error: initramfs is missing $generator" >&2
        return 1
    }

    # The generated unit binds to /dev/gpt-auto-root-luks, which only a udev
    # rule creates. systemd 261 moved that rule from 99-systemd.rules into
    # 90-image-dissect.rules, which dracut does not install by default; a
    # dracut.conf.d drop-in in shared/bootc-secure/tree forces it in. Without
    # it the unit sits unactivated and boot dies in emergency mode (issue 517).
    grep -Frqs 'SYMLINK+="gpt-auto-root-luks"' "$initrd_root/usr/lib/udev/rules.d" || {
        echo "Error: initramfs has no udev rule creating /dev/gpt-auto-root-luks (issue 517)" >&2
        return 1
    }

    generator_root=/run/snosi-gpt-auto-generator-test
    mkdir -p \
        "$initrd_root$generator_root/normal" \
        "$initrd_root$generator_root/early" \
        "$initrd_root$generator_root/late"
    SYSTEMD_IN_INITRD=1 \
    SYSTEMD_IN_CHROOT=0 \
    SYSTEMD_PROC_CMDLINE='root=gpt-auto-force' \
    SYSTEMD_VIRTUALIZATION=none \
        chroot "$initrd_root" "$generator" \
            "$generator_root/normal" \
            "$generator_root/early" \
            "$generator_root/late"

    unit="$initrd_root$generator_root/late/systemd-cryptsetup@root.service"
    [[ -f $unit ]] || {
        echo "Error: initramfs gpt-auto-generator did not emit systemd-cryptsetup@root.service" >&2
        return 1
    }
    grep -Eq "^ExecStart=/usr/(bin|lib/systemd)/systemd-cryptsetup attach 'root' '/dev/gpt-auto-root-luks'([[:space:]]|$)" "$unit" || {
        echo "Error: generated root cryptsetup unit has the wrong attach command" >&2
        return 1
    }
    grep -Fq 'BindsTo=dev-gpt\x2dauto\x2droot\x2dluks.device' "$unit" || {
        echo "Error: generated root cryptsetup unit does not bind to the LUKS device" >&2
        return 1
    }
    find "$initrd_root$generator_root/late" -type l \
        -lname '../systemd-cryptsetup@root.service' -print -quit | grep -q . || {
        echo "Error: generated root cryptsetup unit has no LUKS device dependency" >&2
        return 1
    }
    echo "bootc secure initramfs gpt-auto structural validation passed"
)

gpt_auto_fixture() (
    local fixture before after output status
    fixture=$(mktemp -d)
    trap 'rm -rf "$fixture"' EXIT
    mkdir -p "$fixture/bin" "$fixture/root/boot/EFI/Linux"
    printf 'signed UKI fixture\n' >"$fixture/root/boot/EFI/Linux/test.efi"
    before=$(sha256sum "$fixture/root/boot/EFI/Linux/test.efi")

    cat >"$fixture/bin/objcopy" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $# -eq 4 && $1 == --dump-section && $2 == .initrd=* ]] || {
    echo "stub objcopy: expected dump section, input, and explicit output arguments" >&2
    exit 1
}
printf 'initrd fixture\n' >"${2#.initrd=}"
cp -- "$3" "$4"
EOF
    cat >"$fixture/bin/lsinitrd" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $1 == --unpack && -s $2 ]]
mkdir -p usr/lib/systemd/system-generators
printf '#!/bin/sh\nexit 0\n' >usr/lib/systemd/system-generators/systemd-gpt-auto-generator
chmod +x usr/lib/systemd/system-generators/systemd-gpt-auto-generator
if [[ ${FIXTURE_OMIT_GPT_AUTO_RULE:-0} != 1 ]]; then
    mkdir -p usr/lib/udev/rules.d
    printf 'ENV{ID_PART_GPT_AUTO_ROOT}=="1", ENV{ID_FS_TYPE}=="crypto_LUKS", SYMLINK+="gpt-auto-root-luks"\n' \
        >usr/lib/udev/rules.d/90-image-dissect.rules
fi
EOF
    cat >"$fixture/bin/chroot" <<'EOF'
#!/bin/bash
set -euo pipefail
root=$1
shift 2
late=$3
unit="$root$late/systemd-cryptsetup@root.service"
cat >"$unit" <<'UNIT'
[Unit]
BindsTo=dev-gpt\x2dauto\x2droot\x2dluks.device
[Service]
ExecStart=/usr/bin/systemd-cryptsetup attach 'root' '/dev/gpt-auto-root-luks' '' ''
UNIT
mkdir -p "$root$late/dev-gpt\\x2dauto\\x2droot\\x2dluks.device.wants"
ln -s ../systemd-cryptsetup@root.service \
    "$root$late/dev-gpt\\x2dauto\\x2droot\\x2dluks.device.wants/systemd-cryptsetup@root.service"
EOF
    # The fixture's lsinitrd stub does not decompress data, but the validator
    # deliberately requires zstd for real artifact validation.
    printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/zstd"
    chmod +x "$fixture/bin/objcopy" "$fixture/bin/lsinitrd" "$fixture/bin/chroot" "$fixture/bin/zstd"

    ROOTFS="$fixture/root"
    PATH="$fixture/bin:$PATH" SNOSI_GPT_AUTO_FIXTURE=1 validate_gpt_auto_cryptsetup
    after=$(sha256sum "$fixture/root/boot/EFI/Linux/test.efi")
    [[ $after == "$before" ]] || {
        echo "Error: gpt-auto validation modified the signed UKI" >&2
        return 1
    }

    set +e
    output=$(PATH="$fixture/bin:$PATH" SNOSI_GPT_AUTO_FIXTURE=1 \
        FIXTURE_OMIT_GPT_AUTO_RULE=1 validate_gpt_auto_cryptsetup 2>&1)
    status=$?
    set -e
    [[ $status -eq 1 && $output == *"no udev rule creating /dev/gpt-auto-root-luks"* ]] || {
        echo "Error: missing gpt-auto-root-luks udev rule was not diagnosed" >&2
        return 1
    }

    cat >"$fixture/bin/lsinitrd" <<'EOF'
#!/bin/bash
echo "Need 'zstd' to unpack the initramfs." >&2
exit 1
EOF
    chmod +x "$fixture/bin/lsinitrd"
    set +e
    output=$(PATH="$fixture/bin:$PATH" SNOSI_GPT_AUTO_FIXTURE=1 \
        validate_gpt_auto_cryptsetup 2>&1)
    status=$?
    set -e
    [[ $status -eq 1 && $output == *"Error: failed to unpack the UKI initramfs with lsinitrd"* ]] || {
        echo "Error: initramfs unpack failure was not diagnosed correctly" >&2
        return 1
    }
    [[ $output != *"initramfs is missing"* ]] || {
        echo "Error: initramfs unpack failure was misreported as a missing generator" >&2
        return 1
    }
)

if [[ ${1:-} == --fixtures ]]; then
    "$ASSEMBLER" --self-test
    "$ASSEMBLER" --credential-self-test
    gpt_auto_fixture
    echo "bootc secure artifact fixtures passed"
    exit 0
fi

ROOTFS=${1:?Usage: $0 ROOTFS OCI_IMAGE_REF MOK_CERT PCR_CERT [PREVIOUS_PCR_CERT]}
IMAGE=${2:?Usage: $0 ROOTFS OCI_IMAGE_REF MOK_CERT PCR_CERT [PREVIOUS_PCR_CERT]}
MOK_CERT=${3:?Usage: $0 ROOTFS OCI_IMAGE_REF MOK_CERT PCR_CERT [PREVIOUS_PCR_CERT]}
PCR_CERT=${4:?Usage: $0 ROOTFS OCI_IMAGE_REF MOK_CERT PCR_CERT [PREVIOUS_PCR_CERT]}
PREVIOUS_PCR_CERT=${5:-}

[[ -d "$ROOTFS" ]] || { echo "Error: missing rootfs: $ROOTFS" >&2; exit 1; }
for command in buildah jq objcopy objdump openssl podman sbverify; do
    command -v "$command" >/dev/null || { echo "BLOCKED: missing $command" >&2; exit 2; }
done

"$ASSEMBLER" --validate "$ROOTFS" "$IMAGE" "$MOK_CERT" "$PCR_CERT" "$PREVIOUS_PCR_CERT"
validate_gpt_auto_cryptsetup
echo "bootc secure artifact validation passed"
