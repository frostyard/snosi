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
    # rule creates. systemd 258 moved that rule from 99-systemd.rules into
    # 90-image-dissect.rules, which Trixie's dracut 106 does not install; a
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

# Independent check of the sealed UKI command line (ADR-0027, issue 1213).
# The linux-surface kernel does not raise lockdown under Secure Boot, so the
# signed UKI must carry exactly one lockdown token: lockdown=integrity.
validate_sealed_lockdown() ( # rootfs
    local root=$1 uki scratch cmdline token
    local -a tokens lockdown_tokens=()
    uki=$(find "$root/boot/EFI/Linux" -maxdepth 1 -type f -name '*.efi' -print -quit)
    [[ -n $uki ]] || { echo "Error: assembled UKI is missing" >&2; return 1; }
    scratch=$(mktemp -d)
    trap 'rm -rf "$scratch"' EXIT
    # Always write a disposable output; never modify the signed UKI.
    objcopy --dump-section ".cmdline=$scratch/cmdline" "$uki" "$scratch/uki.copy" || {
        echo "Error: failed to dump the UKI .cmdline section" >&2
        return 1
    }
    cmdline=$(tr '\0' ' ' <"$scratch/cmdline")
    read -r -a tokens <<<"$cmdline"
    for token in "${tokens[@]}"; do
        [[ $token != lockdown=* ]] || lockdown_tokens+=("$token")
    done
    [[ ${#lockdown_tokens[@]} -eq 1 && ${lockdown_tokens[0]} == lockdown=integrity ]] || {
        echo "Error: sealed UKI command line must carry exactly one lockdown=integrity token (found: ${lockdown_tokens[*]:-none})" >&2
        return 1
    }
    echo "bootc secure sealed command line carries lockdown=integrity"
)

sealed_lockdown_fixture() (
    local fixture before after output status digest cmdline
    local -a rejected
    fixture=$(mktemp -d)
    trap 'rm -rf "$fixture"' EXIT
    mkdir -p "$fixture/bin" "$fixture/root/boot/EFI/Linux"
    printf 'signed UKI fixture\n' >"$fixture/root/boot/EFI/Linux/test.efi"
    before=$(sha256sum "$fixture/root/boot/EFI/Linux/test.efi")
    digest=$(printf '%0128d' 0)

    cat >"$fixture/bin/objcopy" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $# -eq 4 && $1 == --dump-section && $2 == .cmdline=* ]] || {
    echo "stub objcopy: expected dump section, input, and explicit output arguments" >&2
    exit 1
}
printf '%s\0' "$FIXTURE_CMDLINE" >"${2#.cmdline=}"
cp -- "$3" "$4"
STUB
    chmod +x "$fixture/bin/objcopy"

    PATH="$fixture/bin:$PATH" FIXTURE_CMDLINE="rw composefs=?$digest lockdown=integrity" \
        validate_sealed_lockdown "$fixture/root"
    after=$(sha256sum "$fixture/root/boot/EFI/Linux/test.efi")
    [[ $after == "$before" ]] || {
        echo "Error: sealed lockdown validation modified the signed UKI" >&2
        return 1
    }

    rejected=(
        "rw composefs=?$digest"
        "rw composefs=?$digest lockdown=none"
        "rw composefs=?$digest lockdown=integrity lockdown=none"
    )
    for cmdline in "${rejected[@]}"; do
        set +e
        output=$(PATH="$fixture/bin:$PATH" FIXTURE_CMDLINE="$cmdline" \
            validate_sealed_lockdown "$fixture/root" 2>&1)
        status=$?
        set -e
        [[ $status -eq 1 && $output == *"must carry exactly one lockdown=integrity token"* ]] || {
            echo "Error: sealed lockdown validation accepted: $cmdline" >&2
            return 1
        }
    done
    after=$(sha256sum "$fixture/root/boot/EFI/Linux/test.efi")
    [[ $after == "$before" ]] || {
        echo "Error: sealed lockdown validation modified the signed UKI" >&2
        return 1
    }
)

# Independent product/Plymouth check of the sealed shape (ADR-0027, ADR-0033).
validate_sealed_splash() ( # rootfs
    local root=$1 id uki scratch cmdline token splash=0 quiet=0
    local -a tokens
    [[ -f "$root/usr/lib/os-release" ]] || {
        echo "Error: rootfs os-release is missing" >&2; return 1;
    }
    id=$(grep '^ID=' "$root/usr/lib/os-release" | sed -E "s/^ID=//; s/^[\"']//; s/[\"']$//") || id=""
    case $id in
        snow|snowfield|sundog|floe) ;;
        *) echo "Error: unsupported or missing rootfs ID: $id" >&2; return 1 ;;
    esac
    uki=$(find "$root/boot/EFI/Linux" -maxdepth 1 -type f -name '*.efi' -print -quit)
    [[ -n $uki ]] || { echo "Error: assembled UKI is missing" >&2; return 1; }
    scratch=$(mktemp -d)
    trap 'rm -rf "$scratch"' EXIT
    # Always write a disposable output; never modify the signed UKI.
    objcopy --dump-section ".cmdline=$scratch/cmdline" "$uki" "$scratch/uki.copy" || {
        echo "Error: failed to dump the UKI .cmdline section" >&2; return 1;
    }
    cmdline=$(tr '\0' ' ' <"$scratch/cmdline")
    read -r -a tokens <<<"$cmdline"
    for token in "${tokens[@]}"; do
        case $token in
            splash) splash=$((splash + 1)) ;;
            quiet) quiet=$((quiet + 1)) ;;
            nosplash|plymouth.*)
                echo "Error: forbidden sealed splash token: $token" >&2; return 1 ;;
        esac
    done
    if [[ $id == floe ]]; then
        [[ $splash -eq 0 && $quiet -eq 0 ]] || {
            echo "Error: floe must not seal splash or quiet tokens" >&2; return 1;
        }
        [[ ! -e "$root/usr/sbin/plymouthd" && ! -L "$root/usr/sbin/plymouthd" ]] || {
            echo "Error: floe must not ship plymouthd" >&2; return 1;
        }
    else
        [[ $splash -eq 1 && $quiet -eq 1 ]] || {
            echo "Error: $id must seal exactly one splash and one quiet token" >&2; return 1;
        }
        [[ -e "$root/usr/sbin/plymouthd" ]] || {
            echo "Error: $id must ship plymouthd" >&2; return 1;
        }
    fi
    echo "bootc secure sealed splash command line matches $id"
)

sealed_splash_fixture() (
    local fixture before after digest id case_name cmdline output status expected
    fixture=$(mktemp -d)
    trap 'rm -rf "$fixture"' EXIT
    mkdir -p "$fixture/bin" "$fixture/root/boot/EFI/Linux" "$fixture/root/usr/lib" "$fixture/root/usr/sbin"
    printf 'signed UKI fixture\n' >"$fixture/root/boot/EFI/Linux/test.efi"
    before=$(sha256sum "$fixture/root/boot/EFI/Linux/test.efi")
    digest=$(printf '%0128d' 0)
    cat >"$fixture/bin/objcopy" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $# -eq 4 && $1 == --dump-section && $2 == .cmdline=* ]] || {
    echo "stub objcopy: expected dump section, input, and explicit output arguments" >&2
    exit 1
}
printf '%s\0' "$FIXTURE_CMDLINE" >"${2#.cmdline=}"
cp -- "$3" "$4"
STUB
    chmod +x "$fixture/bin/objcopy"
    for case_name in snow snowfield sundog floe snow-no-splash floe-splash floe-daemon \
        snow-no-daemon sundog-duplicate snow-ignore-serial unknown missing-os-release \
        snow-nosplash snow-no-quiet; do
        id=snow; expected=1
        cmdline="rw composefs=?$digest lockdown=integrity splash quiet"
        touch "$fixture/root/usr/sbin/plymouthd"
        case $case_name in
            snow|snowfield|sundog) id=$case_name; expected=0 ;;
            floe) id=floe; expected=0; cmdline="rw composefs=?$digest lockdown=integrity"; rm "$fixture/root/usr/sbin/plymouthd" ;;
            snow-no-splash) cmdline="rw composefs=?$digest lockdown=integrity" ;;
            floe-splash) id=floe; rm "$fixture/root/usr/sbin/plymouthd" ;;
            floe-daemon) id=floe; cmdline="rw composefs=?$digest lockdown=integrity" ;;
            snow-no-daemon) rm "$fixture/root/usr/sbin/plymouthd" ;;
            sundog-duplicate) id=sundog; cmdline="rw composefs=?$digest lockdown=integrity splash splash quiet" ;;
            snow-ignore-serial) cmdline+=" plymouth.ignore-serial-consoles" ;;
            unknown) id=debian ;;
            missing-os-release) ;;
            snow-nosplash) cmdline+=" nosplash" ;;
            snow-no-quiet) cmdline="rw composefs=?$digest lockdown=integrity splash" ;;
        esac
        printf 'ID="%s"\n' "$id" >"$fixture/root/usr/lib/os-release"
        [[ $case_name != missing-os-release ]] || rm "$fixture/root/usr/lib/os-release"
        set +e
        output=$(PATH="$fixture/bin:$PATH" FIXTURE_CMDLINE="$cmdline" \
            validate_sealed_splash "$fixture/root" 2>&1)
        status=$?
        set -e
        [[ $status -eq $expected && ( $expected -eq 0 || $output == *"Error: "* ) ]] || {
            echo "Error: sealed splash fixture failed: $case_name ($output)" >&2; return 1;
        }
        after=$(sha256sum "$fixture/root/boot/EFI/Linux/test.efi")
        [[ $after == "$before" ]] || {
            echo "Error: sealed splash validation modified the signed UKI: $case_name" >&2; return 1;
        }
    done
    echo "bootc secure sealed splash fixtures passed"
)

# SNOSI_BOOTC_SECURE_SUITE selects the assembler's contract (ADR-0038). The
# selected contract is the one --validate requires in the rootfs, so a rootfs
# of the other suite fails at the contract check, and an unknown suite fails
# before any work.
suite_contract_fixture() (
    local work output status trixie_contract forky_contract
    trixie_contract="$ROOT_DIR/shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json"
    forky_contract="$ROOT_DIR/shared/bootc-secure/suite/forky/tree/usr/lib/snosi/bootc-secure.json"
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    SNOSI_BOOTC_SECURE_SUITE=forky "$ASSEMBLER" --self-test >/dev/null 2>&1 || {
        echo "Error: suite fixture: the forky assembler self-test failed" >&2; return 1;
    }
    set +e
    output=$(SNOSI_BOOTC_SECURE_SUITE=sid "$ASSEMBLER" --self-test 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 && $output == *'unsupported SNOSI_BOOTC_SECURE_SUITE: sid'* ]] || {
        echo "Error: suite fixture: an unknown suite reached the assembler ($output)" >&2; return 1;
    }
    validate_with() { # suite contract
        mkdir -p "$work/$1/usr/lib/snosi"
        cp "$2" "$work/$1/usr/lib/snosi/bootc-secure.json"
        set +e
        output=$(SNOSI_BOOTC_SECURE_SUITE=$1 "$ASSEMBLER" --validate "$work/$1" localhost/none:none none none 2>&1)
        set -e
        rm -rf -- "${work:?}/$1"
    }
    # Its own contract passes the contract check and stops later, at the kernel.
    for suite in trixie forky; do
        contract=$trixie_contract
        [[ $suite == trixie ]] || contract=$forky_contract
        validate_with "$suite" "$contract"
        [[ $output != *'unexpected bootc secure rootfs contract'* && $output == *'expected exactly one kernel'* ]] || {
            echo "Error: suite fixture: $suite rejected its own contract ($output)" >&2; return 1;
        }
    done
    if ! cmp -s "$trixie_contract" "$forky_contract" &&
            [[ $(jq -r .assembly.bootc_version "$trixie_contract") != $(jq -r .assembly.bootc_version "$forky_contract") ]]; then
        validate_with forky "$trixie_contract"
        [[ $output == *'unexpected bootc secure rootfs contract'* ]] || {
            echo "Error: suite fixture: forky accepted a trixie rootfs contract ($output)" >&2; return 1;
        }
        validate_with trixie "$forky_contract"
        [[ $output == *'unexpected bootc secure rootfs contract'* ]] || {
            echo "Error: suite fixture: trixie accepted a forky rootfs contract ($output)" >&2; return 1;
        }
    fi
    echo "bootc secure suite contract fixtures passed"
)

if [[ ${1:-} == --fixtures ]]; then
    "$ASSEMBLER" --self-test
    "$ASSEMBLER" --credential-self-test
    gpt_auto_fixture
    sealed_lockdown_fixture
    sealed_splash_fixture
    suite_contract_fixture
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
validate_sealed_lockdown "$ROOTFS"
validate_sealed_splash "$ROOTFS"
validate_gpt_auto_cryptsetup
echo "bootc secure artifact validation passed"
