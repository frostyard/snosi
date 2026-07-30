#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Exercise secure Buildah packaging cleanup through controlled command fixtures.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGER="$ROOT_DIR/shared/outformat/image/buildah-package.sh"
failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

image_path() {
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

write_fixtures() { # state root
    local state=$1 root=$2
    mkdir -p "$state/bin" "$state/images" "$root/proc" "$root/usr/bin" "$root/usr/lib/modules/test-kernel" \
        "$root/boot/EFI/Linux" "$root/boot/EFI/BOOT"
    : >"$root/usr/lib/modules/test-kernel/vmlinuz"
    : >"$root/usr/lib/modules/test-kernel/initramfs.img"
    printf 'keep-linux\n' >"$root/boot/EFI/Linux/keep.txt"
    printf 'keep-boot\n' >"$root/boot/EFI/BOOT/pre-existing.efi"

    cat >"$state/bin/mountpoint" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $1 == -q && $2 == "$BUILD_FIXTURE_ROOT/proc" ]]
[[ -e "$BUILD_FIXTURE_STATE/proc-mounted" ]]
EOF
    cat >"$state/bin/mount" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $1 == --bind && $2 == /proc && $3 == "$BUILD_FIXTURE_ROOT/proc" ]]
printf '%s\n' "$*" >"$BUILD_FIXTURE_STATE/mount-invoked"
touch "$BUILD_FIXTURE_STATE/proc-mounted"
EOF
    cat >"$state/bin/chroot" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $1 == "$BUILD_FIXTURE_ROOT" && $2 == /usr/bin/bootc && $3 == --version ]]
printf '%s\n' "$*" >"$BUILD_FIXTURE_STATE/chroot-invoked"
if [[ ${BUILD_FIXTURE_CHROOT_FAIL:-0} == 1 ]]; then
    echo 'fixture rootfs loader failure' >&2
    exit 86
fi
printf '%s\n' "${BUILD_FIXTURE_BOOTC_VERSION:-bootc 1.16.3}"
EOF
    cat >"$state/bin/umount" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $1 == "$BUILD_FIXTURE_ROOT/proc" ]]
printf '%s\n' "$*" >"$BUILD_FIXTURE_STATE/umount-invoked"
[[ ${BUILD_FIXTURE_UMOUNT_FAIL:-0} != 1 ]] || exit 87
rm -f "$BUILD_FIXTURE_STATE/proc-mounted"
EOF
    cat >"$state/bin/buildah" <<'EOF'
#!/bin/bash
set -euo pipefail
touch "$BUILD_FIXTURE_STATE/buildah-invoked"
hash() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
case $1 in
    from) printf 'container-%s\n' "${RANDOM}" ;;
    mount) mount="$BUILD_FIXTURE_STATE/mount-$2"; mkdir -p "$mount"; printf '%s\n' "$mount" ;;
    umount|config|rm) : ;;
    commit) touch "$BUILD_FIXTURE_STATE/images/$(hash "$3")" ;;
    rmi) rm -f "$BUILD_FIXTURE_STATE/images/$(hash "$2")" ;;
    *) echo "unexpected buildah invocation: $*" >&2; exit 99 ;;
esac
EOF
    cat >"$state/bin/podman" <<'EOF'
#!/bin/bash
set -euo pipefail
count_file="$BUILD_FIXTURE_STATE/podman-count"
count=0
[[ ! -f "$count_file" ]] || count=$(<"$count_file")
count=$((count + 1))
printf '%s' "$count" >"$count_file"
if [[ $count -eq 1 ]]; then
    printf '%s\n' "$@" >"$BUILD_FIXTURE_STATE/podman-first-args"
fi
if [[ ${BUILD_FIXTURE_FINAL_PROBE_FAIL:-0} == 1 && $count -eq 2 ]]; then
    exit 86
fi
if [[ ${BUILD_FIXTURE_PUBLISHED_DIGEST_MISMATCH:-0} == 1 && $count -eq 3 ]]; then
    printf '%0128d\n' 1
    exit 0
fi
printf '%0128d\n' 0
EOF
    cat >"$state/assembler" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ $1 == --remove-injected ]]; then
    rm -f -- "$2/boot/EFI/Linux/test-kernel.efi" "$2/boot/EFI/BOOT/grubx64.efi" \
        "$2/usr/lib/snosi/bootc/systemd-bootx64.efi"
    exit 0
fi
if [[ $1 == --scan-image ]]; then
    exit 0
fi
if [[ $1 == --prepare-systemd-boot-source ]]; then
    mkdir -p "$2/usr/lib/snosi/bootc"
    printf 'immutable-bootloader\n' >"$2/usr/lib/snosi/bootc/systemd-bootx64.efi"
    exit 0
fi
printf '%s\n' "${SNOSI_BOOTC_SECURE_UKIFY_IMAGE:-}" >"$BUILD_FIXTURE_STATE/ukify-image"
touch "$BUILD_FIXTURE_STATE/assembler-invoked"
mkdir -p "$1/boot/EFI/Linux" "$1/boot/EFI/BOOT"
printf 'injected-uki\n' >"$1/boot/EFI/Linux/test-kernel.efi"
printf 'injected-bootloader\n' >"$1/boot/EFI/BOOT/grubx64.efi"
[[ ${BUILD_FIXTURE_ASSEMBLER_FAIL:-0} != 1 ]]
EOF
    chmod +x "$state/bin/mountpoint" "$state/bin/mount" "$state/bin/chroot" \
        "$state/bin/umount" "$state/bin/buildah" "$state/bin/podman" "$state/assembler"
}

assert_cleanup() { # state root first final published
    local state=$1 root=$2 first=$3 final=$4 published=$5 ukify_image
    [[ -f "$state/assembler-invoked" ]] || fail "controlled assembler was not invoked"
    [[ -f "$state/ukify-image" ]] || fail "assembler did not receive a ukify image"
    ukify_image=$(<"$state/ukify-image")
    [[ $ukify_image == localhost/snosi-bootc-secure-first-[0-9]* ]] ||
        fail "assembler did not receive the exact first-pass ukify image"
    { [[ -f "$state/podman-first-args" ]] && grep -Fxq -- "$ukify_image" "$state/podman-first-args"; } ||
        fail "assembler ukify image differs from the first digest candidate"
    [[ -f "$state/mount-invoked" && $(<"$state/mount-invoked") == "--bind /proc $root/proc" ]] || fail "rootfs proc bind was not exact"
    [[ -f "$state/chroot-invoked" && $(<"$state/chroot-invoked") == "$root /usr/bin/bootc --version" ]] || fail "bootc version did not use rootfs chroot"
    [[ -f "$state/umount-invoked" && $(<"$state/umount-invoked") == "$root/proc" ]] || fail "rootfs proc unmount was not exact"
    [[ ! -e "$state/proc-mounted" ]] || fail "rootfs proc mount survived"
    [[ ! -e "$state/images/$(image_path "$first")" ]] || fail "first probe image survived"
    [[ ! -e "$state/images/$(image_path "$final")" ]] || fail "final probe image survived"
    [[ ! -e "$state/images/$(image_path "$published")" ]] || fail "published image survived"
    [[ ! -e "$root/boot/EFI/Linux/test-kernel.efi" ]] || fail "Task 5 UKI residue survived"
    [[ ! -e "$root/boot/EFI/BOOT/grubx64.efi" ]] || fail "Task 5 bootloader residue survived"
    [[ ! -e "$root/usr/lib/snosi/bootc/systemd-bootx64.efi" ]] || fail "Task 7 immutable bootloader source residue survived"
    [[ $(<"$root/boot/EFI/Linux/keep.txt") == keep-linux ]] || fail "pre-existing Linux boot file changed"
    [[ $(<"$root/boot/EFI/BOOT/pre-existing.efi") == keep-boot ]] || fail "pre-existing boot file changed"
}

run_case() { # name assembler-fails|final-probe-fails|published-digest-mismatch
    local name=$1 work state root first final published status
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' RETURN
    state="$work/state"; root="$work/root"
    first="localhost/snosi-bootc-secure-first-$$"
    final="localhost/snosi-bootc-secure-final-$$"
    published="localhost/task5-cleanup-$name:latest"
    write_fixtures "$state" "$root"
    set +e
    BUILD_FIXTURE_STATE="$state" BUILD_FIXTURE_ROOT="$root" PATH="$state/bin:$PATH" SNOSI_BOOTC_SECURE=1 \
        SNOSI_BOOTC_MOK_KEY=fixture SNOSI_BOOTC_MOK_CERT=fixture \
        SNOSI_BOOTC_PCR_KEY=fixture SNOSI_BOOTC_PCR_CERT=fixture \
        SNOSI_BOOTC_SECURE_TEST_HOOKS=1 SNOSI_BOOTC_SECURE_TEST_ASSEMBLER="$state/assembler" \
        BUILD_FIXTURE_ASSEMBLER_FAIL=$([[ $name == assembler-fails ]] && printf 1 || printf 0) \
        BUILD_FIXTURE_FINAL_PROBE_FAIL=$([[ $name == final-probe-fails ]] && printf 1 || printf 0) \
        BUILD_FIXTURE_PUBLISHED_DIGEST_MISMATCH=$([[ $name == published-digest-mismatch ]] && printf 1 || printf 0) \
        "$PACKAGER" "$root" "$published" >/dev/null 2>&1
    status=$?
    set -e
    [[ $status -ne 0 ]] || fail "$name unexpectedly succeeded"
    assert_cleanup "$state" "$root" "$first" "$final" "$published"

    # A fresh secure invocation must not be blocked by leftovers from the failure.
    set +e
    BUILD_FIXTURE_STATE="$state" BUILD_FIXTURE_ROOT="$root" PATH="$state/bin:$PATH" SNOSI_BOOTC_SECURE=1 \
        SNOSI_BOOTC_MOK_KEY=fixture SNOSI_BOOTC_MOK_CERT=fixture \
        SNOSI_BOOTC_PCR_KEY=fixture SNOSI_BOOTC_PCR_CERT=fixture \
        SNOSI_BOOTC_SECURE_TEST_HOOKS=1 SNOSI_BOOTC_SECURE_TEST_ASSEMBLER="$state/assembler" \
        "$PACKAGER" "$root" "localhost/task5-cleanup-rerun-$name:latest" >/dev/null
    status=$?
    set -e
    [[ $status -eq 0 ]] || fail "$name left the next secure packaging run wedged"
    "$state/assembler" --remove-injected "$root"
}

run_probe_failure_case() { # name expected-text setup-command env-name env-value
    local name=$1 expected=$2 setup=$3 env_name=$4 env_value=$5 work state root published status output
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' RETURN
    state="$work/state"; root="$work/root"
    published="localhost/task5-probe-$name:latest"
    write_fixtures "$state" "$root"
    [[ $setup == none ]] || "$setup" "$state" "$root"
    set +e
    output=$(env BUILD_FIXTURE_STATE="$state" BUILD_FIXTURE_ROOT="$root" PATH="$state/bin:$PATH" \
        SNOSI_BOOTC_SECURE=1 SNOSI_BOOTC_MOK_KEY=fixture SNOSI_BOOTC_MOK_CERT=fixture \
        SNOSI_BOOTC_PCR_KEY=fixture SNOSI_BOOTC_PCR_CERT=fixture \
        SNOSI_BOOTC_SECURE_TEST_HOOKS=1 SNOSI_BOOTC_SECURE_TEST_ASSEMBLER="$state/assembler" \
        "$env_name=$env_value" "$PACKAGER" "$root" "$published" 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 ]] || fail "$name unexpectedly succeeded"
    [[ $output == *"$expected"* ]] || fail "$name lacked diagnostic: $expected"
    [[ ! -e "$state/assembler-invoked" ]] || fail "$name reached the assembler"
    [[ ! -e "$state/buildah-invoked" ]] || fail "$name reached Buildah"
    case $name in
        proc-missing)
            [[ ! -e "$state/mount-invoked" && ! -e "$root/proc" ]] || fail "$name changed malformed rootfs"
            ;;
        proc-pre-mounted)
            [[ ! -e "$state/mount-invoked" && ! -e "$state/umount-invoked" && -e "$state/proc-mounted" ]] || fail "$name touched an unowned mount"
            ;;
        chroot-fails|wrong-version)
            [[ -e "$state/umount-invoked" && ! -e "$state/proc-mounted" ]] || fail "$name did not clean its proc mount"
            ;;
        umount-fails)
            [[ -e "$state/umount-invoked" && -e "$state/proc-mounted" ]] || fail "$name did not expose failed unmount state"
            ;;
    esac
}

mark_proc_mounted() { touch "$1/proc-mounted"; }
remove_proc_dir() { rmdir "$2/proc"; }

run_probe_failure_case proc-missing 'rootfs proc directory is missing' remove_proc_dir UNUSED 0
run_probe_failure_case proc-pre-mounted 'rootfs proc is already mounted' mark_proc_mounted UNUSED 0
run_probe_failure_case chroot-fails 'fixture rootfs loader failure' none BUILD_FIXTURE_CHROOT_FAIL 1
run_probe_failure_case wrong-version 'expected bootc 1.16.3, observed bootc 1.16.2' none BUILD_FIXTURE_BOOTC_VERSION 'bootc 1.16.2'
run_probe_failure_case umount-fails 'failed to unmount rootfs proc' none BUILD_FIXTURE_UMOUNT_FAIL 1

run_case assembler-fails
run_case final-probe-fails
run_case published-digest-mismatch

[[ $failures -eq 0 ]] || exit 1
echo "bootc secure package cleanup fixtures passed"
