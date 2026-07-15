#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Exercise native A/B rejection, update, rollback, slot reuse, and fallback.
#
# Usage: sudo ./test/native-ab-update-test.sh BASE_RAW UPDATE_PREFIX1 UPDATE_PREFIX2 UPDATE_PREFIX3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${KEEP_VM:=0}"
: "${SOURCE_PORT:=18080}"
: "${SSH_PORT:=2222}"
: "${SSH_TIMEOUT:=300}"

# Product parameterization (docs/native-ab-contracts.md §1). This script
# takes prebuilt artifact prefixes on the command line, so PROFILE only
# feeds the IMAGE_ID default -- set IMAGE_ID/CHANNEL directly to test a
# different product without a real "*-ab-raw" profile name to strip.
: "${PROFILE:=cayo-ab-raw}"
if [[ -z "${IMAGE_ID:-}" ]]; then
    IMAGE_ID="${PROFILE%-ab-raw}"
    IMAGE_ID="${IMAGE_ID%-ab}"
fi
: "${CHANNEL:=${IMAGE_ID}-ab}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ssh.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/vm.sh"

WORK_DIR=""
HTTP_PID=""
loop=""
declare -a versions=() root_uuids=() verity_uuids=()

usage() {
    echo "Usage: $0 BASE_RAW UPDATE_PREFIX1 UPDATE_PREFIX2 UPDATE_PREFIX3" >&2
    exit 2
}

cleanup() {
    [[ -z "$loop" ]] || losetup -d "$loop" 2>/dev/null || true
    [[ -z "$HTTP_PID" ]] || kill "$HTTP_PID" 2>/dev/null || true
    if [[ "$KEEP_VM" == 1 ]]; then
        echo "KEEP_VM=1: leaving VM and $WORK_DIR in place"
        return
    fi
    vm_cleanup
    [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}

guest_version() {
    vm_ssh ". /usr/lib/os-release; echo \"\$IMAGE_VERSION\""
}

reboot_guest() {
    vm_ssh systemctl reboot || true
    sleep 5
    wait_for_ssh
}

write_manifest() {
    local mode="${1:-valid}"
    local first="${versions[0]}" file name hash
    : > "$WORK_DIR/source/SHA256SUMS"
    for file in "$WORK_DIR/source"/*; do
        name="$(basename "$file")"
        [[ "$name" == SHA256SUMS || "$name" == SHA256SUMS.gpg ]] && continue
        [[ "$mode" != missing-uki || "$name" != "${CHANNEL}_${first}.efi" ]] || continue
        [[ "$mode" != missing-verity || "$name" != ${CHANNEL}_${first}_*.root-verity.raw.xz ]] || continue
        if [[ "$mode" == bad-root && "$name" == ${CHANNEL}_${first}_*.root.raw.xz ]]; then
            hash="$(printf '0%.0s' {1..64})"
        else
            hash="$(sha256sum "$file")"
            hash="${hash%% *}"
        fi
        printf '%s  %s\n' "$hash" "$name" >> "$WORK_DIR/source/SHA256SUMS"
    done
}

sign_manifest() {
    gpg --homedir "$WORK_DIR/gnupg" --batch --yes --detach-sign \
        -o "$WORK_DIR/source/SHA256SUMS.gpg" "$WORK_DIR/source/SHA256SUMS"
}

assert_not_activated() {
    local expected="$1" layout empty_count running
    layout="$(vm_ssh 'lsblk -J -o PARTLABEL')"
    empty_count="$(jq '[.. | objects | select(.partlabel? == "_empty")] | length' <<<"$layout")"
    [[ "$empty_count" -eq 2 ]] || { echo "Error: rejected update committed a partition label" >&2; exit 1; }
    vm_ssh "test ! -e /boot/EFI/Linux/${CHANNEL}_${versions[0]}+3-0.efi"
    running="$(guest_version)"
    [[ "$running" == "$expected" ]] || { echo "Error: rejected update changed running version" >&2; exit 1; }
}

expect_rejected() {
    local description="$1" verify="$2" expected="$3" rc
    echo "Failure injection: $description"
    set +e
    vm_ssh "/usr/lib/systemd/systemd-sysupdate --definitions=/var/tmp/native-ab-definitions --verify=$verify update '${versions[0]}'"
    rc=$?
    set -e
    [[ $rc -ne 0 ]] || { echo "Error: invalid update succeeded: $description" >&2; exit 1; }
    assert_not_activated "$expected"
}

partition_path() {
    local label="$1"
    vm_ssh "lsblk -J -o PATH,PARTLABEL" | jq -er --arg label "$label" \
        '.. | objects | select(.partlabel? == $label) | .path'
}

install_update() {
    local index="$1" verify="${2:-no}"
    local version="${versions[index]}" root_uuid="${root_uuids[index]}" verity_uuid="${verity_uuids[index]}"
    local layout installed_root_uuid installed_verity_uuid
    echo "Installing update $version"
    vm_ssh "/usr/lib/systemd/systemd-sysupdate --definitions=/var/tmp/native-ab-definitions --verify=$verify update '$version'"
    layout="$(vm_ssh 'lsblk -J -o PATH,PARTLABEL,PARTUUID')"
    installed_root_uuid="$(jq -r --arg label "${IMAGE_ID}_${version}_r" \
        '.. | objects | select(.partlabel? == $label) | .partuuid' <<<"$layout")"
    installed_verity_uuid="$(jq -r --arg label "${IMAGE_ID}_${version}_v" \
        '.. | objects | select(.partlabel? == $label) | .partuuid' <<<"$layout")"
    [[ "${installed_root_uuid,,}" == "$root_uuid" ]]
    [[ "${installed_verity_uuid,,}" == "$verity_uuid" ]]
    vm_ssh "test -e /boot/EFI/Linux/${CHANNEL}_${version}+3-0.efi"
}

verify_boot() {
    local expected="$1" actual health
    actual="$(guest_version)"
    [[ "$actual" == "$expected" ]] || { echo "Error: booted $actual, expected $expected" >&2; exit 1; }
    vm_ssh 'grep -qx var-persist /var/native-ab-update-test'
    vm_ssh 'grep -qx etc-persist /etc/native-ab-update-test'
    health="$(vm_ssh 'systemctl is-system-running --wait' || true)"
    [[ "$health" == running || "$health" == degraded ]] || { echo "Error: system health is $health" >&2; exit 1; }
}

wait_for_failed_boot() {
    local deadline=$((SECONDS + 120))
    while (( SECONDS < deadline )); do
        if [[ -f "$QEMU_CONSOLE_LOG" ]] && grep -q 'Entering emergency mode' "$QEMU_CONSOLE_LOG"; then
            return 0
        fi
        sleep 2
    done
    echo "Error: corrupt update did not reach emergency mode" >&2
    return 1
}

[[ $# -eq 4 ]] || usage
[[ $EUID -eq 0 ]] || { echo "Error: must run as root" >&2; exit 1; }

BASE_RAW="$(realpath "$1")"
shift
declare -a prefixes=()
for arg in "$@"; do
    prefixes+=("$(realpath -m "$(dirname "$arg")")/$(basename "$arg")")
done

for command in jq losetup mount xz python3 qemu-system-x86_64 gpg; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done
[[ -f "$BASE_RAW" ]] || { echo "Error: baseline not found: $BASE_RAW" >&2; exit 1; }

trap cleanup EXIT
WORK_DIR="$(mktemp -d /var/tmp/native-ab-update-test.XXXXXX)"
mkdir -p "$WORK_DIR/source" "$WORK_DIR/definitions" "$WORK_DIR/mnt" "$WORK_DIR/gnupg"
chmod 700 "$WORK_DIR/gnupg"
DISK_IMAGE="$WORK_DIR/disk.raw"
cp --sparse=always "$BASE_RAW" "$DISK_IMAGE"

for prefix in "${prefixes[@]}"; do
    manifest="${prefix}.manifest"
    raw="${prefix}.raw"
    uki="${prefix}.efi"
    root="${prefix}.${IMAGE_ID}_@v.root.raw.raw"
    verity="${prefix}.${IMAGE_ID}_@v.root-verity.raw.raw"
    for file in "$manifest" "$raw" "$uki" "$root" "$verity"; do
        [[ -f "$file" ]] || { echo "Error: required artifact not found: $file" >&2; exit 1; }
    done
    version="$(jq -er '.config.version' "$manifest")"
    layout="$(sfdisk --json "$raw")"
    root_uuid="$(jq -er --arg label "${IMAGE_ID}_${version}_r" '.partitiontable.partitions[] | select(.name == $label) | .uuid | ascii_downcase' <<<"$layout")"
    verity_uuid="$(jq -er --arg label "${IMAGE_ID}_${version}_v" '.partitiontable.partitions[] | select(.name == $label) | .uuid | ascii_downcase' <<<"$layout")"
    versions+=("$version")
    root_uuids+=("$root_uuid")
    verity_uuids+=("$verity_uuid")
    echo "Preparing update $version"
    xz -T0 -c "$root" > "$WORK_DIR/source/${CHANNEL}_${version}_${root_uuid}.root.raw.xz"
    xz -T0 -c "$verity" > "$WORK_DIR/source/${CHANNEL}_${version}_${verity_uuid}.root-verity.raw.xz"
    cp "$uki" "$WORK_DIR/source/${CHANNEL}_${version}.efi"
done

cat > "$WORK_DIR/definitions/10-root-verity.transfer" <<EOF
[Transfer]
ProtectVersion=%A
Verify=yes
[Source]
Type=url-file
Path=http://10.0.2.2:${SOURCE_PORT}/
MatchPattern=${CHANNEL}_@v_@u.root-verity.raw.xz
[Target]
Type=partition
Path=auto
MatchPattern=${IMAGE_ID}_@v_v
MatchPartitionType=root-verity
PartitionFlags=0
ReadOnly=yes
InstancesMax=2
EOF
cat > "$WORK_DIR/definitions/20-root.transfer" <<EOF
[Transfer]
ProtectVersion=%A
Verify=yes
[Source]
Type=url-file
Path=http://10.0.2.2:${SOURCE_PORT}/
MatchPattern=${CHANNEL}_@v_@u.root.raw.xz
[Target]
Type=partition
Path=auto
MatchPattern=${IMAGE_ID}_@v_r
MatchPartitionType=root
PartitionFlags=0
ReadOnly=yes
InstancesMax=2
EOF
cat > "$WORK_DIR/definitions/90-uki.transfer" <<EOF
[Transfer]
ProtectVersion=%A
Verify=yes
[Source]
Type=url-file
Path=http://10.0.2.2:${SOURCE_PORT}/
MatchPattern=${CHANNEL}_@v.efi
[Target]
Type=regular-file
Path=/EFI/Linux
PathRelativeTo=boot
MatchPattern=${CHANNEL}_@v+@l-@d.efi
MatchPattern=${CHANNEL}_@v+@l.efi
MatchPattern=${CHANNEL}_@v.efi
Mode=0444
TriesLeft=3
TriesDone=0
InstancesMax=2
EOF

gpg --homedir "$WORK_DIR/gnupg" --batch --passphrase '' --quick-generate-key \
    'snosi native A/B test <native-ab-test@invalid>' ed25519 sign 0
gpg --homedir "$WORK_DIR/gnupg" --batch --export > "$WORK_DIR/import-pubring.gpg"
write_manifest valid
sign_manifest

ssh_keygen "$WORK_DIR"
loop="$(losetup --find --show --partscan "$DISK_IMAGE")"
mount "${loop}p6" "$WORK_DIR/mnt"
mkdir -p "$WORK_DIR/mnt/roothome/.ssh"
cp "${SSH_KEY}.pub" "$WORK_DIR/mnt/roothome/.ssh/authorized_keys"
chmod 700 "$WORK_DIR/mnt/roothome/.ssh"
chmod 600 "$WORK_DIR/mnt/roothome/.ssh/authorized_keys"
umount "$WORK_DIR/mnt"
losetup -d "$loop"
loop=""

python3 -m http.server "$SOURCE_PORT" --bind 0.0.0.0 --directory "$WORK_DIR/source" >"$WORK_DIR/http.log" 2>&1 &
HTTP_PID=$!
vm_start "$DISK_IMAGE"
wait_for_ssh
base_version="$(guest_version)"
initial_uki="$(vm_ssh "find /boot/EFI/Linux -maxdepth 1 -type f -printf '%f\n'" | head -1)"
base_root_path="$(partition_path "${IMAGE_ID}_${base_version}_r")"
vm_ssh "printf '%s\n' var-persist > /var/native-ab-update-test"
vm_ssh "printf '%s\n' etc-persist > /etc/native-ab-update-test"
vm_ssh 'mkdir -p /etc/systemd'
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" "$WORK_DIR/import-pubring.gpg" root@localhost:/etc/systemd/import-pubring.gpg
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" -r "$WORK_DIR/definitions" root@localhost:/var/tmp/native-ab-definitions

write_manifest missing-uki
expect_rejected "missing UKI" no "$base_version"
write_manifest missing-verity
expect_rejected "missing verity" no "$base_version"
write_manifest bad-root
expect_rejected "root checksum mismatch" no "$base_version"
write_manifest valid
sign_manifest
printf '\n' >> "$WORK_DIR/source/SHA256SUMS"
expect_rejected "tampered signed manifest" yes "$base_version"
write_manifest valid
sign_manifest

install_update 0 yes
hop1_root_path="$(partition_path "${IMAGE_ID}_${versions[0]}_r")"
reboot_guest
verify_boot "${versions[0]}"

echo "Testing explicit rollback to $base_version"
vm_ssh "bootctl set-oneshot '$initial_uki'"
reboot_guest
verify_boot "$base_version"
reboot_guest
verify_boot "${versions[0]}"

install_update 1 yes
[[ "$(partition_path "${IMAGE_ID}_${versions[1]}_r")" == "$base_root_path" ]] || { echo "Error: N+2 did not reuse baseline slot" >&2; exit 1; }
reboot_guest
verify_boot "${versions[1]}"

install_update 2 yes
[[ "$(partition_path "${IMAGE_ID}_${versions[2]}_r")" == "$hop1_root_path" ]] || { echo "Error: N+3 did not reuse N+1 slot" >&2; exit 1; }

echo "Testing boot-count fallback from ${versions[2]} to ${versions[1]}"
bad_root_path="$(partition_path "${IMAGE_ID}_${versions[2]}_r")"
vm_ssh "dd if=/dev/zero of='$bad_root_path' bs=4096 count=1 conv=fsync status=none"
vm_ssh systemctl reboot || true
for attempt in 1 2 3; do
    wait_for_failed_boot
    vm_stop
    if [[ $attempt -lt 3 ]]; then
        vm_start "$DISK_IMAGE"
    fi
done
vm_start "$DISK_IMAGE"
wait_for_ssh
verify_boot "${versions[1]}"
vm_ssh "test -e /boot/EFI/Linux/${CHANNEL}_${versions[2]}+0-3.efi"

echo "Native A/B full spike passed: $base_version -> ${versions[*]} -> fallback ${versions[1]}"
