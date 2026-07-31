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
    mkdir -p "$state/bin" "$state/images" "$state/containers" "$state/mounts" "$root/proc" "$root/usr/bin" "$root/usr/lib/modules/test-kernel" \
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
printf '%s\n' "$*" >>"$BUILD_FIXTURE_STATE/buildah-commands"
hash() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
case $1 in
    from)
        count=0
        [[ ! -f "$BUILD_FIXTURE_STATE/container-count" ]] || count=$(<"$BUILD_FIXTURE_STATE/container-count")
        count=$((count + 1))
        printf '%s' "$count" >"$BUILD_FIXTURE_STATE/container-count"
        container="container-$count"
        mkdir -p "$BUILD_FIXTURE_STATE/containers/$container/fs"
        printf '%s\n' "$2" >"$BUILD_FIXTURE_STATE/$container-source"
        image="$BUILD_FIXTURE_STATE/images/$(hash "$2").fs"
        [[ ! -d $image ]] || /bin/cp -a "$image/." "$BUILD_FIXTURE_STATE/containers/$container/fs/"
        printf '%s\n' "$container"
        ;;
    mount)
        mount="$BUILD_FIXTURE_STATE/mounts/$2"
        ln -s "../containers/$2/fs" "$mount"
        printf '%s\n' "$mount"
        ;;
    umount) rm -f -- "$BUILD_FIXTURE_STATE/mounts/$2" ;;
    config)
        container=${!#}
        for ((i = 2; i < $#; i++)); do
            [[ ${!i} != --label ]] || {
                i=$((i + 1))
                printf '%s\n' "${!i}" >>"$BUILD_FIXTURE_STATE/$container-labels"
            }
        done
        ;;
    rm) rm -rf -- "$BUILD_FIXTURE_STATE/containers/$2" ;;
    commit)
        if [[ ${BUILD_FIXTURE_FINAL_NONBOOT_MUTATION:-0} == 1 && $3 == "$BUILD_FIXTURE_PUBLISHED" ]]; then
            printf 'forbidden non-boot mutation\n' >"$BUILD_FIXTURE_STATE/containers/$2/fs/usr/nonboot-mutation"
        fi
        /bin/cp -a "$BUILD_FIXTURE_STATE/containers/$2/fs" "$BUILD_FIXTURE_STATE/images/$(hash "$3").fs"
        touch "$BUILD_FIXTURE_STATE/images/$(hash "$3")"
        ;;
    rmi) rm -rf -- "$BUILD_FIXTURE_STATE/images/$(hash "$2")" "$BUILD_FIXTURE_STATE/images/$(hash "$2").fs" ;;
    *) echo "unexpected buildah invocation: $*" >&2; exit 99 ;;
esac
EOF
    cat >"$state/bin/cp" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ ${2:-} == "$BUILD_FIXTURE_ROOT/boot/." ]]; then
    printf '%s\n' "$1" >"$BUILD_FIXTURE_STATE/cp-final-option"
    printf '%s\n' "$2" >"$BUILD_FIXTURE_STATE/cp-final-source"
    printf '%s\n' "${!#}" >"$BUILD_FIXTURE_STATE/cp-final-destination"
    [[ ${BUILD_FIXTURE_FINAL_CP_FAIL:-0} != 1 ]] || exit 89
fi
/bin/cp "$@"
EOF
    cat >"$state/bin/podman" <<'EOF'
#!/bin/bash
set -euo pipefail
case $1 in
    inspect)
        printf '{}\n'
        ;;
    load)
        cat >/dev/null
        if [[ ${BUILD_FIXTURE_CHUNK_UNPARSEABLE_LOAD:-0} == 1 ]]; then
            printf 'unparseable fixture output\n'
        else
            printf 'Loaded image: %s\n' "$(<"$BUILD_FIXTURE_STATE/chunk-image")"
        fi
        ;;
    tag)
        :
        ;;
    run)
        if [[ " $* " == *' quay.io/coreos/chunkah@sha256:fdff3175bfb41e111089392ef8a41b46a10766c7b2ec454ba1272a0c39ce3bf3 '* ]]; then
            printf '%s\n' "$@" >"$BUILD_FIXTURE_STATE/chunk-args"
            for ((i = 1; i <= $#; i++)); do
                if [[ ${!i} == SOURCE_DATE_EPOCH=* ]]; then
                    printf '%s\n' "${!i#SOURCE_DATE_EPOCH=}" >"$BUILD_FIXTURE_STATE/chunk-source-epoch"
                elif [[ ${!i} == --mount=type=image,* ]]; then
                    image=${!i#*src=}
                    printf '%s\n' "${image%%,*}" >"$BUILD_FIXTURE_STATE/chunk-image"
                fi
            done
            [[ ${BUILD_FIXTURE_CHUNK_FAIL:-0} != 1 ]] || exit 88
            exit 0
        fi
        previous=""
        image=""
        for argument in "$@"; do
            [[ $argument != bootc ]] || { image=$previous; break; }
            previous=$argument
        done
        count=0
        [[ ! -f "$BUILD_FIXTURE_STATE/digest-probe-count" ]] || count=$(<"$BUILD_FIXTURE_STATE/digest-probe-count")
        count=$((count + 1))
        printf '%s' "$count" >"$BUILD_FIXTURE_STATE/digest-probe-count"
        if [[ $count -eq 1 ]]; then
            printf '%s\n' "$image" >"$BUILD_FIXTURE_STATE/first-digest-image"
        else
            printf '%s\n' "$image" >"$BUILD_FIXTURE_STATE/final-digest-image"
        fi
        snapshot="$BUILD_FIXTURE_STATE/images/$(printf '%s' "$image" | sha256sum | cut -d' ' -f1).fs"
        if [[ ${BUILD_FIXTURE_MALFORMED_FIRST_DIGEST:-0} == 1 && $count -eq 1 ]] ||
                [[ ${BUILD_FIXTURE_MALFORMED_FINAL_DIGEST:-0} == 1 && $count -eq 2 ]]; then
            printf 'not-a-storage-digest\n'
        elif [[ ${BUILD_FIXTURE_PUBLISHED_DIGEST_MISMATCH:-0} == 1 && $count -eq 2 ]]; then
            printf '%0128d\n' 1
        else
            tar -C "$snapshot" --exclude=./boot --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - . | sha512sum | cut -d' ' -f1
        fi
        ;;
    *)
        echo "unexpected podman invocation: $*" >&2
        exit 99
        ;;
esac
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
    touch "$BUILD_FIXTURE_STATE/scan-invoked"
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
        "$state/bin/umount" "$state/bin/buildah" "$state/bin/cp" "$state/bin/podman" "$state/assembler"
}

assert_cleanup() { # state root published
    local state=$1 root=$2 published=$3 ukify_image first
    [[ -f "$state/assembler-invoked" ]] || fail "controlled assembler was not invoked"
    [[ -f "$state/ukify-image" ]] || fail "assembler did not receive a ukify image"
    ukify_image=""
    [[ ! -f "$state/ukify-image" ]] || ukify_image=$(<"$state/ukify-image")
    [[ $ukify_image == localhost/snosi-bootc-secure-first-[0-9]* ]] ||
        fail "assembler did not receive the exact first-pass ukify image"
    first=""
    [[ ! -f "$state/chunk-image" ]] || first=$(<"$state/chunk-image")
    [[ $first == localhost/snosi-bootc-secure-first-[0-9]* ]] || fail "chunker did not receive the first candidate"
    [[ $ukify_image == "$first" ]] || fail "assembler ukify image differs from the chunked digest candidate"
    [[ -f "$state/mount-invoked" && $(<"$state/mount-invoked") == "--bind /proc $root/proc" ]] || fail "rootfs proc bind was not exact"
    [[ -f "$state/chroot-invoked" && $(<"$state/chroot-invoked") == "$root /usr/bin/bootc --version" ]] || fail "bootc version did not use rootfs chroot"
    [[ -f "$state/umount-invoked" && $(<"$state/umount-invoked") == "$root/proc" ]] || fail "rootfs proc unmount was not exact"
    [[ ! -e "$state/proc-mounted" ]] || fail "rootfs proc mount survived"
    [[ ! -e "$state/images/$(image_path "$first")" ]] || fail "first candidate image survived"
    [[ ! -e "$state/images/$(image_path "$published")" ]] || fail "published image survived"
    [[ ! -d "$state/containers" || -z $(compgen -G "$state/containers/*") ]] || fail "Buildah working container survived"
    [[ ! -d "$state/mounts" || -z $(compgen -G "$state/mounts/*") ]] || fail "Buildah working mount survived"
    [[ ! -e "$root/boot/EFI/Linux/test-kernel.efi" ]] || fail "Task 5 UKI residue survived"
    [[ ! -e "$root/boot/EFI/BOOT/grubx64.efi" ]] || fail "Task 5 bootloader residue survived"
    [[ ! -e "$root/usr/lib/snosi/bootc/systemd-bootx64.efi" ]] || fail "Task 7 immutable bootloader source residue survived"
    [[ $(<"$root/boot/EFI/Linux/keep.txt") == keep-linux ]] || fail "pre-existing Linux boot file changed"
    [[ $(<"$root/boot/EFI/BOOT/pre-existing.efi") == keep-boot ]] || fail "pre-existing boot file changed"
}

run_case() { # name assembler-fails|final-cp-fails|published-digest-mismatch|nonboot-mutation
    local name=$1 work state root published status
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' RETURN
    state="$work/state"; root="$work/root"
    published="localhost/task5-cleanup-$name:latest"
    write_fixtures "$state" "$root"
    set +e
    BUILD_FIXTURE_STATE="$state" BUILD_FIXTURE_ROOT="$root" BUILD_FIXTURE_PUBLISHED="$published" PATH="$state/bin:$PATH" SNOSI_BOOTC_SECURE=1 \
        SNOSI_BOOTC_MOK_KEY=fixture SNOSI_BOOTC_MOK_CERT=fixture \
        SNOSI_BOOTC_PCR_KEY=fixture SNOSI_BOOTC_PCR_CERT=fixture \
        SNOSI_BOOTC_SECURE_TEST_HOOKS=1 SNOSI_BOOTC_SECURE_TEST_ASSEMBLER="$state/assembler" SOURCE_DATE_EPOCH=1722384000 \
        BUILD_FIXTURE_ASSEMBLER_FAIL=$([[ $name == assembler-fails ]] && printf 1 || printf 0) \
        BUILD_FIXTURE_FINAL_CP_FAIL=$([[ $name == final-cp-fails ]] && printf 1 || printf 0) \
        BUILD_FIXTURE_PUBLISHED_DIGEST_MISMATCH=$([[ $name == published-digest-mismatch ]] && printf 1 || printf 0) \
        BUILD_FIXTURE_FINAL_NONBOOT_MUTATION=$([[ $name == nonboot-mutation ]] && printf 1 || printf 0) \
        "$PACKAGER" "$root" "$published" >/dev/null 2>&1
    status=$?
    set -e
    [[ $status -ne 0 ]] || fail "$name unexpectedly succeeded"
    assert_cleanup "$state" "$root" "$published"

    # A fresh secure invocation must not be blocked by leftovers from the failure.
    set +e
    BUILD_FIXTURE_STATE="$state" BUILD_FIXTURE_ROOT="$root" BUILD_FIXTURE_PUBLISHED="localhost/task5-cleanup-rerun-$name:latest" PATH="$state/bin:$PATH" SNOSI_BOOTC_SECURE=1 \
        SNOSI_BOOTC_MOK_KEY=fixture SNOSI_BOOTC_MOK_CERT=fixture \
        SNOSI_BOOTC_PCR_KEY=fixture SNOSI_BOOTC_PCR_CERT=fixture \
        SNOSI_BOOTC_SECURE_TEST_HOOKS=1 SNOSI_BOOTC_SECURE_TEST_ASSEMBLER="$state/assembler" SOURCE_DATE_EPOCH=1722384000 \
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
        SNOSI_BOOTC_SECURE_TEST_HOOKS=1 SNOSI_BOOTC_SECURE_TEST_ASSEMBLER="$state/assembler" SOURCE_DATE_EPOCH=1722384000 \
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
run_case final-cp-fails
run_case published-digest-mismatch
run_case nonboot-mutation

run_success_case() {
    local work state root published
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' RETURN
    state="$work/state"; root="$work/root"; published="localhost/task5-cleanup-success:latest"
    write_fixtures "$state" "$root"
    BUILD_FIXTURE_STATE="$state" BUILD_FIXTURE_ROOT="$root" BUILD_FIXTURE_PUBLISHED="$published" PATH="$state/bin:$PATH" SNOSI_BOOTC_SECURE=1 \
        SNOSI_BOOTC_MOK_KEY=fixture SNOSI_BOOTC_MOK_CERT=fixture SNOSI_BOOTC_PCR_KEY=fixture SNOSI_BOOTC_PCR_CERT=fixture \
        SNOSI_BOOTC_SECURE_TEST_HOOKS=1 SNOSI_BOOTC_SECURE_TEST_ASSEMBLER="$state/assembler" SOURCE_DATE_EPOCH=1722384000 \
        "$PACKAGER" "$root" "$published" org.opencontainers.image.version=fixture >/dev/null
    first=""
    [[ ! -f "$state/chunk-image" ]] || first=$(<"$state/chunk-image")
    if [[ ! -f "$state/chunk-args" ]] || ! grep -Fxq -- '--prune' "$state/chunk-args"; then
        fail "chunkah lost --prune"
    fi
    if [[ ! -f "$state/chunk-args" ]] || ! grep -Fxq -- '/sysroot/' "$state/chunk-args"; then
        fail "chunkah lost /sysroot/"
    fi
    if [[ ! -f "$state/chunk-args" ]] || ! grep -Fxq -- '--max-layers' "$state/chunk-args"; then
        fail "chunkah lost --max-layers"
    fi
    if [[ ! -f "$state/chunk-args" ]] || ! grep -Fxq -- '128' "$state/chunk-args"; then
        fail "chunkah lost the default layer limit"
    fi
    [[ -f "$state/chunk-source-epoch" && $(<"$state/chunk-source-epoch") == 1722384000 ]] || fail "chunkah received the wrong source epoch"
    grep -Fxq "from $first" "$state/buildah-commands" || fail "final image was not derived from the chunked candidate"
    [[ $(<"$state/cp-final-option") == -a && $(<"$state/cp-final-source") == "$root/boot/." ]] ||
        fail "final image did not copy only the rootfs boot tree"
    [[ $(<"$state/cp-final-destination") == "$state/mounts/container-2/boot/" ]] ||
        fail "final image did not copy the boot overlay into the derived container"
    [[ -f "$state/digest-probe-count" && $(<"$state/digest-probe-count") == 2 ]] || fail "secure packaging did not perform exactly two digest probes"
    [[ -f "$state/first-digest-image" && $(<"$state/first-digest-image") == "$first" ]] || fail "chunked candidate was not digest authority"
    [[ -f "$state/final-digest-image" && $(<"$state/final-digest-image") == "$published" ]] || fail "published image was not the final digest authority"
    grep -Fxq 'containers.bootc=1' "$state/container-1-labels" || fail "first candidate lost the bootc label"
    grep -Fxq 'org.opencontainers.image.vendor=frostyard' "$state/container-1-labels" || fail "first candidate lost the vendor label"
    grep -Fxq 'org.opencontainers.image.version=fixture' "$state/container-1-labels" || fail "first candidate lost the caller label"
    ! grep -Fxq 'io.snosi.bootc.secureboot-capable=true' "$state/container-1-labels" || fail "first candidate gained the secure capability label"
    ! grep -Fq 'io.snosi.bootc.secureboot-assembly=' "$state/container-1-labels" || fail "first candidate gained the assembly label"
    grep -Fxq 'io.snosi.bootc.secureboot-capable=true' "$state/container-2-labels" || fail "final container lost the secure label"
    grep -Fxq 'io.snosi.bootc.secureboot-assembly=bootc-1.16.3-storage-digest-v1' "$state/container-2-labels" || fail "final container lost the assembly label"
    "$state/assembler" --remove-injected "$root"
}

run_chunk_failure_case() { # name env-name env-value expected-text
    local name=$1 env_name=$2 env_value=$3 expected=$4 work state root published output status
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' RETURN
    state="$work/state"; root="$work/root"; published="localhost/task5-chunk-$name:latest"
    write_fixtures "$state" "$root"
    set +e
    output=$(env BUILD_FIXTURE_STATE="$state" BUILD_FIXTURE_ROOT="$root" BUILD_FIXTURE_PUBLISHED="$published" PATH="$state/bin:$PATH" \
        SNOSI_BOOTC_SECURE=1 SNOSI_BOOTC_MOK_KEY=fixture SNOSI_BOOTC_MOK_CERT=fixture \
        SNOSI_BOOTC_PCR_KEY=fixture SNOSI_BOOTC_PCR_CERT=fixture SNOSI_BOOTC_SECURE_TEST_HOOKS=1 \
        SNOSI_BOOTC_SECURE_TEST_ASSEMBLER="$state/assembler" SOURCE_DATE_EPOCH=1722384000 \
        "$env_name=$env_value" "$PACKAGER" "$root" "$published" 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 && $output == *"$expected"* ]] || fail "$name was not rejected with $expected"
    [[ ! -e "$state/scan-invoked" ]] || fail "$name reached publication scanning"
    if [[ $name != malformed-final-digest ]]; then
        [[ ! -e "$state/assembler-invoked" ]] || fail "$name reached assembly"
    fi
    [[ ! -e "$state/images/$(image_path "$published")" ]] || fail "$name retained a final image"
    [[ ! -e "$state/images/$(image_path localhost/snosi-bootc-secure-first-$$)" ]] || fail "$name retained the first candidate"
    [[ ! -d "$state/containers" || -z $(compgen -G "$state/containers/*") ]] || fail "$name retained a container"
    [[ ! -d "$state/mounts" || -z $(compgen -G "$state/mounts/*") ]] || fail "$name retained a mount"

    # The failed candidate must not poison a later protected package attempt.
    set +e
    BUILD_FIXTURE_STATE="$state" BUILD_FIXTURE_ROOT="$root" \
        BUILD_FIXTURE_PUBLISHED="localhost/task5-chunk-rerun-$name:latest" PATH="$state/bin:$PATH" \
        SNOSI_BOOTC_SECURE=1 SNOSI_BOOTC_MOK_KEY=fixture SNOSI_BOOTC_MOK_CERT=fixture \
        SNOSI_BOOTC_PCR_KEY=fixture SNOSI_BOOTC_PCR_CERT=fixture SNOSI_BOOTC_SECURE_TEST_HOOKS=1 \
        SNOSI_BOOTC_SECURE_TEST_ASSEMBLER="$state/assembler" SOURCE_DATE_EPOCH=1722384000 \
        "$PACKAGER" "$root" "localhost/task5-chunk-rerun-$name:latest" >/dev/null
    status=$?
    set -e
    [[ $status -eq 0 ]] || fail "$name left the next secure packaging run wedged"
    "$state/assembler" --remove-injected "$root"
}

run_chunk_failure_case chunk-failure BUILD_FIXTURE_CHUNK_FAIL 1 'chunkah'
run_chunk_failure_case unparseable-load BUILD_FIXTURE_CHUNK_UNPARSEABLE_LOAD 1 'could not parse loaded image ref'
run_chunk_failure_case malformed-first-digest BUILD_FIXTURE_MALFORMED_FIRST_DIGEST 1 'unsupported bootc storage-digest interface'
run_chunk_failure_case malformed-final-digest BUILD_FIXTURE_MALFORMED_FINAL_DIGEST 1 'unsupported bootc storage-digest interface'

run_missing_epoch_case() {
    local work state root output status
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' RETURN
    state="$work/state"; root="$work/root"
    write_fixtures "$state" "$root"
    set +e
    output=$(env BUILD_FIXTURE_STATE="$state" BUILD_FIXTURE_ROOT="$root" PATH="$state/bin:$PATH" SNOSI_BOOTC_SECURE=1 \
        SNOSI_BOOTC_MOK_KEY=fixture SNOSI_BOOTC_MOK_CERT=fixture SNOSI_BOOTC_PCR_KEY=fixture SNOSI_BOOTC_PCR_CERT=fixture \
        SNOSI_BOOTC_SECURE_TEST_HOOKS=1 SNOSI_BOOTC_SECURE_TEST_ASSEMBLER="$state/assembler" \
        "$PACKAGER" "$root" localhost/task5-cleanup-missing-epoch:latest 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 && $output == *'SOURCE_DATE_EPOCH is required for secure chunking'* ]] || fail "missing source epoch was not rejected"
    [[ ! -e "$state/chunk-args" && ! -e "$state/assembler-invoked" && ! -e "$state/buildah-invoked" ]] ||
        fail "missing source epoch reached chunkah, assembler, or final commit"
}

run_invalid_epoch_case() {
    local work state root output status
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' RETURN
    state="$work/state"; root="$work/root"
    write_fixtures "$state" "$root"
    set +e
    output=$(env BUILD_FIXTURE_STATE="$state" BUILD_FIXTURE_ROOT="$root" PATH="$state/bin:$PATH" SNOSI_BOOTC_SECURE=1 \
        SNOSI_BOOTC_MOK_KEY=fixture SNOSI_BOOTC_MOK_CERT=fixture SNOSI_BOOTC_PCR_KEY=fixture SNOSI_BOOTC_PCR_CERT=fixture \
        SNOSI_BOOTC_SECURE_TEST_HOOKS=1 SNOSI_BOOTC_SECURE_TEST_ASSEMBLER="$state/assembler" SOURCE_DATE_EPOCH=not-a-number \
        "$PACKAGER" "$root" localhost/task5-cleanup-invalid-epoch:latest 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 && $output == *'SOURCE_DATE_EPOCH must be a non-negative integer'* ]] || fail "invalid source epoch was not rejected"
    [[ ! -e "$state/assembler-invoked" ]] || fail "invalid source epoch reached assembly"
    [[ ! -e "$state/images/$(image_path localhost/task5-cleanup-invalid-epoch:latest)" ]] || fail "invalid source epoch reached final commit"
}

run_success_case
run_missing_epoch_case
run_invalid_epoch_case

[[ $failures -eq 0 ]] || exit 1
echo "bootc secure package cleanup fixtures passed"
