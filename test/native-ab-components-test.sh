#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Phase 1 QEMU integration test (docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md,
# "Phase 1: Fix Current Prototype Safety" exit criterion):
#
#   "the current prototype boots without failed legacy updaters, updates its
#   OS with two differently versioned sysext components enabled, reports
#   native /etc drift correctly, and cannot be mistaken for a publishable
#   secure profile" (the publication-guard half is covered statically by
#   check-native-publication-guard.sh; this test covers the runtime half).
#
# Builds two real versions (N, N+1) of profile $PROFILE (default cayo-ab-raw)
# via the pinned .mkosi checkout (mirrors the Justfile's ensure-mkosi
# bootstrap + `mkosi clean -ff` + `mkosi --profile $PROFILE build`), boots N
# in QEMU, and validates in order:
#
#   1. No failed legacy updaters; bootc/nbc/sysupdate auto-update units masked.
#   2. The OS default sysupdate.d target and the 18 shipped sysext components
#      are structurally separate (component discovery via `systemd-sysupdate
#      components`).
#   3. Two ad hoc test sysext components (testa, testb; independently
#      versioned) update independently of each other and leave OS partitions
#      and the ESP byte-identical.
#   4. A real N -> N+1 OS update succeeds with those two components still
#      enabled, without touching /var/lib/extensions.d, and the components
#      still enumerate correctly after reboot. The N+1 OS update source is
#      generated via shared/native-ab/publish/prepare-native-publication.sh
#      (--xz), so this exercises the real public artifact-naming contract
#      end to end, not hand-rolled fixture naming.
#   5. Native /etc drift tooling (snosi-etc-diff, snosi-etc-drift-report)
#      works correctly against the /.etc.lower overlay on a booted image.
#
# Usage: sudo ./test/native-ab-components-test.sh
# Env overrides (docs/native-ab-contracts.md §1): PROFILE (default
# cayo-ab-raw), IMAGE_ID (derived from PROFILE by default), CHANNEL
# (derived as <IMAGE_ID>-ab by default).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${KEEP_VM:=0}"
: "${SOURCE_PORT:=18093}"
: "${SSH_PORT:=2223}"
: "${SSH_TIMEOUT:=300}"
: "${SKIP_BUILD:=0}"
: "${BUILD_N_DIR:=}"
: "${BUILD_N1_DIR:=}"

# Product parameterization (docs/native-ab-contracts.md §1). PROFILE is the
# real `mkosi --profile` value built below; IMAGE_ID is the product/ImageId
# (partition-label prefix, §3) derived from it by stripping the -ab-raw/-ab
# dev-fixture/production suffixes; CHANNEL is the public name prefix
# (<ImageId>-ab, §1) used for the OS transfer's Source/UKI names regardless
# of which profile actually built the bits under test -- the shipped
# transfers (shared/native-ab/channels/<product>/tree/usr/lib/sysupdate.d/)
# always fetch channel-named blobs, so the CHANNEL default is "cayo-ab" even
# though the default PROFILE is the never-published "cayo-ab-raw" fixture.
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
PASS=0
FAIL=0

pass() { # description
    echo "ok - $1"
    PASS=$((PASS + 1))
}

fail() { # description [detail]
    echo "not ok - $1" >&2
    [[ $# -lt 2 ]] || echo "  $2" >&2
    FAIL=$((FAIL + 1))
}

assert_eq() { # description actual expected
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1" "expected '$3', got '$2'"
    fi
}

assert_true() { # description command...
    local desc="$1"
    shift
    if "$@"; then
        pass "$desc"
    else
        fail "$desc" "command failed: $*"
    fi
}

assert_contains() { # description haystack needle
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1" "expected to find: $3"
    fi
}

assert_not_contains() { # description haystack needle
    if [[ "$2" != *"$3"* ]]; then
        pass "$1"
    else
        fail "$1" "expected NOT to find: $3"
    fi
}

print_summary() {
    echo ""
    echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
    exit "$FAIL"
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

# resolve_mkosi - mirror Justfile's ensure-mkosi: fetch the pinned mkosi
# commit into a repo-local checkout if missing or at the wrong commit.
resolve_mkosi() {
    local commit dir
    commit="$(grep -m1 -oE 'systemd/mkosi@[0-9a-f]+' "$ROOT_DIR/.github/workflows/build.yml" | cut -d@ -f2)"
    dir="$ROOT_DIR/.mkosi"
    MKOSI="$dir/bin/mkosi"
    if [[ -x "$MKOSI" && "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$commit" ]]; then
        echo "Using pinned mkosi @ $commit ($dir)"
        return
    fi
    command -v python3 >/dev/null || { echo "Error: python3 is required to run mkosi" >&2; exit 1; }
    echo "Installing mkosi @ $commit into $dir"
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth=1 https://github.com/systemd/mkosi.git "$commit"
    git -C "$dir" checkout -q --detach FETCH_HEAD
}

# build_profile - clean build $PROFILE and copy its split artifacts into a
# stable destination (mkosi clean -ff wipes output/ on the next call).
build_profile() { # dest_dir
    local dest="$1"
    mkdir -p "$dest"
    echo "Building $PROFILE -> $dest (started $(date -u +%FT%TZ))"
    "$MKOSI" clean -ff
    "$MKOSI" --profile "$PROFILE" build
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.manifest" "$dest/"
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.raw" "$dest/"
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.efi" "$dest/"
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.${IMAGE_ID}_@v.root.raw.raw" "$dest/"
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.${IMAGE_ID}_@v.root-verity.raw.raw" "$dest/"
    # The product-curated feature catalog (features-catalog.finalize) is a
    # REQUIRED publication artifact since the sysext feature catalog landed
    # (prepare-native-publication.sh hard-fails without it). The build emits
    # it as <IMAGE_ID>.features.json, not <Output>-prefixed.
    cp "$ROOT_DIR/output/${IMAGE_ID}.features.json" "$dest/$PROFILE.features.json"
    echo "Build done -> $dest (finished $(date -u +%FT%TZ))"
}

write_sha256sums() { # dir
    local dir="$1" file name hash
    : > "$dir/SHA256SUMS"
    for file in "$dir"/*; do
        [[ -f "$file" ]] || continue
        name="$(basename "$file")"
        [[ "$name" == SHA256SUMS || "$name" == SHA256SUMS.gpg ]] && continue
        hash="$(sha256sum "$file")"
        hash="${hash%% *}"
        printf '%s  %s\n' "$hash" "$name" >> "$dir/SHA256SUMS"
    done
}

sign_manifest() { # dir
    gpg --homedir "$WORK_DIR/gnupg" --batch --yes --detach-sign \
        -o "$1/SHA256SUMS.gpg" "$1/SHA256SUMS"
}

disk_device() {
    vm_ssh 'lsblk -J -o PATH,TYPE' | jq -er '.blockdevices[] | select(.type == "disk") | .path'
}

for command in jq losetup mount xz python3 qemu-system-x86_64 gpg git sfdisk; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done
[[ $EUID -eq 0 ]] || { echo "Error: must run as root" >&2; exit 1; }

trap cleanup EXIT
WORK_DIR="$(mktemp -d /var/tmp/native-ab-components-test.XXXXXX)"
# source/os is created later as a symlink straight into the publisher's own
# output tree (see "Prepare the N+1 OS update source" below) so the
# multi-gigabyte root/verity/disk artifacts are never copied a second time.
mkdir -p "$WORK_DIR/source/testa" "$WORK_DIR/source/testb" \
    "$WORK_DIR/definitions" "$WORK_DIR/mnt" "$WORK_DIR/gnupg" "$WORK_DIR/publish-src"
chmod 700 "$WORK_DIR/gnupg"

echo "=== Step 0: build N and N+1 (this takes tens of minutes) ==="
if [[ "$SKIP_BUILD" == 1 ]]; then
    [[ -n "$BUILD_N_DIR" && -n "$BUILD_N1_DIR" ]] || {
        echo "Error: SKIP_BUILD=1 requires BUILD_N_DIR and BUILD_N1_DIR" >&2
        exit 1
    }
    echo "SKIP_BUILD=1: reusing prebuilt artifacts at $BUILD_N_DIR and $BUILD_N1_DIR"
else
    resolve_mkosi
    BUILD_N_DIR="$WORK_DIR/build-n"
    BUILD_N1_DIR="$WORK_DIR/build-n1"
    build_profile "$BUILD_N_DIR"
    build_profile "$BUILD_N1_DIR"
fi

for f in manifest raw efi features.json "${IMAGE_ID}_@v.root.raw.raw" "${IMAGE_ID}_@v.root-verity.raw.raw"; do
    [[ -f "$BUILD_N_DIR/$PROFILE.$f" ]] || { echo "Error: missing N artifact: $f" >&2; exit 1; }
    [[ -f "$BUILD_N1_DIR/$PROFILE.$f" ]] || { echo "Error: missing N+1 artifact: $f" >&2; exit 1; }
done

n_version="$(jq -er '.config.version' "$BUILD_N_DIR/$PROFILE.manifest")"
n1_version="$(jq -er '.config.version' "$BUILD_N1_DIR/$PROFILE.manifest")"
echo "N=$n_version  N+1=$n1_version"
[[ "$n_version" != "$n1_version" ]] || { echo "Error: N and N+1 builds produced the same version" >&2; exit 1; }
[[ "$n1_version" > "$n_version" ]] || { echo "Error: N+1 version is not newer than N" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Prepare the N+1 OS update source VIA the publication naming pipeline
# (shared/native-ab/publish/prepare-native-publication.sh), not hand-rolled
# naming, so the update leg exercises the exact same public contract QEMU
# will consume in production, including the frozen §4 filenames and the
# already-shipped channel-prefixed Source MatchPattern (see the real
# shared/native-ab/channels/<product>/tree/usr/lib/sysupdate.d/*.transfer).
#
# The publisher validates profile-output-name == "<ImageId>-ab" (refusing to
# "publish" a *-ab-raw dev fixture by name) as a real safety property, so
# stage symlinks presenting $PROFILE's build outputs under the $CHANNEL name
# it expects -- symlinks, not copies, so the multi-gigabyte root/verity/disk
# artifacts are never duplicated on disk.
# ---------------------------------------------------------------------------
for suffix in manifest raw efi "${IMAGE_ID}_@v.root.raw.raw" "${IMAGE_ID}_@v.root-verity.raw.raw"; do
    ln -s "$BUILD_N1_DIR/$PROFILE.$suffix" "$WORK_DIR/publish-src/$CHANNEL.$suffix"
done
# The feature catalog is looked up as <product>.features.json, where product
# is the manifest's .config.name (= IMAGE_ID) -- NOT the channel-prefixed
# name the other staged artifacts use.
ln -s "$BUILD_N1_DIR/$PROFILE.features.json" "$WORK_DIR/publish-src/${IMAGE_ID}.features.json"
"$ROOT_DIR/shared/native-ab/publish/prepare-native-publication.sh" --xz \
    "$WORK_DIR/publish-src" "$CHANNEL" "$WORK_DIR/publish-out"

# Read the publisher's actual output location from its own
# publication-info.json (product field) rather than re-deriving
# "$WORK_DIR/publish-out/$IMAGE_ID/x86-64" from $IMAGE_ID -- the publisher's
# real product/dest derivation lives entirely in
# shared/native-ab/publish/prepare-native-publication.sh (manifest
# .config.name), and this test should consume that output, not assume it
# agrees with this script's own $IMAGE_ID parsing of $PROFILE.
mapfile -t publish_info_files < <(find "$WORK_DIR/publish-out" -name publication-info.json)
[[ ${#publish_info_files[@]} -eq 1 ]] || {
    echo "Error: expected exactly 1 publication-info.json under $WORK_DIR/publish-out, found ${#publish_info_files[@]}" >&2
    exit 1
}
publish_info_file="${publish_info_files[0]}"
publish_product="$(jq -er '.product' "$publish_info_file")"
[[ "$publish_product" == "$IMAGE_ID" ]] || {
    echo "Error: publisher product '$publish_product' (from $publish_info_file) does not match this test's IMAGE_ID '$IMAGE_ID'" >&2
    exit 1
}
publish_dest="$(dirname "$publish_info_file")"
ln -s "$publish_dest" "$WORK_DIR/source/os"

cat > "$WORK_DIR/definitions/10-root-verity.transfer" <<EOF
[Transfer]
ProtectVersion=%A
Verify=yes
[Source]
Type=url-file
Path=http://10.0.2.2:${SOURCE_PORT}/os/
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
Path=http://10.0.2.2:${SOURCE_PORT}/os/
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
Path=http://10.0.2.2:${SOURCE_PORT}/os/
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
    'snosi native A/B components test <native-ab-components-test@invalid>' ed25519 sign 0
gpg --homedir "$WORK_DIR/gnupg" --batch --export > "$WORK_DIR/import-pubring.gpg"
# The publisher already wrote SHA256SUMS scoped exactly to the 5 contract
# files it produced (unsigned, as documented in its own header) -- only
# gpg-sign it in place, don't recompute it with write_sha256sums (which
# would also hash publication-info.json, a file no transfer references).
sign_manifest "$publish_dest"

# ---------------------------------------------------------------------------
# Prepare two independently versioned test sysext components (testa, testb)
# ---------------------------------------------------------------------------
printf 'testa payload 1.2.0\n' > "$WORK_DIR/source/testa/testa_1.2.0.raw"
printf 'testa payload 1.3.0\n' > "$WORK_DIR/source/testa/testa_1.3.0.raw"
write_sha256sums "$WORK_DIR/source/testa"
printf 'testb payload 7.0\n' > "$WORK_DIR/source/testb/testb_7.0.raw"
printf 'testb payload 7.1\n' > "$WORK_DIR/source/testb/testb_7.1.raw"
write_sha256sums "$WORK_DIR/source/testb"

mkdir -p "$WORK_DIR/guest-fixtures/sysupdate.testa.d" "$WORK_DIR/guest-fixtures/sysupdate.testb.d"
cat > "$WORK_DIR/guest-fixtures/sysupdate.testa.d/testa.transfer" <<EOF
[Transfer]
Features=testa
Verify=false

[Source]
Type=url-file
Path=http://10.0.2.2:${SOURCE_PORT}/testa/
MatchPattern=testa_@v.raw

[Target]
Type=regular-file
Path=/var/lib/extensions.d/
MatchPattern=testa_@v.raw
CurrentSymlink=testa.raw
EOF
cat > "$WORK_DIR/guest-fixtures/sysupdate.testa.d/testa.feature" <<'EOF'
[Feature]
Description=Test component A (native-ab-components-test fixture)
Enabled=true
EOF
cat > "$WORK_DIR/guest-fixtures/sysupdate.testb.d/testb.transfer" <<EOF
[Transfer]
Features=testb
Verify=false

[Source]
Type=url-file
Path=http://10.0.2.2:${SOURCE_PORT}/testb/
MatchPattern=testb_@v.raw

[Target]
Type=regular-file
Path=/var/lib/extensions.d/
MatchPattern=testb_@v.raw
CurrentSymlink=testb.raw
EOF
cat > "$WORK_DIR/guest-fixtures/sysupdate.testb.d/testb.feature" <<'EOF'
[Feature]
Description=Test component B (native-ab-components-test fixture)
Enabled=true
EOF

# ---------------------------------------------------------------------------
# Boot N
# ---------------------------------------------------------------------------
ssh_keygen "$WORK_DIR"
DISK_IMAGE="$WORK_DIR/disk.raw"
cp --sparse=always "$BUILD_N_DIR/$PROFILE.raw" "$DISK_IMAGE"
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

booted_version="$(guest_version)"
assert_eq "booted version is N" "$booted_version" "$n_version"

# Let first boot (preset application, machine-id commit, etc.) fully settle
# before asserting on unit state.
vm_ssh 'systemctl is-system-running --wait' >/dev/null || true

# ===========================================================================
# Step 1: no failed legacy updaters
# ===========================================================================
echo ""
echo "=== Step 1: no failed legacy updaters ==="

failed_units="$(vm_ssh 'systemctl --failed --no-legend' || true)"
assert_eq "no failed systemd units" "$failed_units" ""

check_masked_timer() { # unit
    local status
    status="$(vm_ssh "systemctl is-enabled $1" || true)"
    assert_eq "$1 is masked" "$status" "masked"
}
check_masked_timer bootc-update-stage.timer
check_masked_timer bootc-update-stage.service
check_masked_timer nbc-update-download.timer
check_masked_timer nbc-update-download.service
check_masked_timer systemd-sysupdate.timer
check_masked_timer systemd-sysupdate-reboot.timer

check_user_mask_symlink() { # relpath
    local link target
    link="/usr/lib/systemd/user/$1"
    if vm_ssh "test -L '$link'"; then
        target="$(vm_ssh "readlink '$link'")"
        assert_eq "$link is a symlink to /dev/null" "$target" "/dev/null"
    else
        fail "$link is a symlink" "not a symlink (or missing)"
    fi
}
check_user_mask_symlink bootc-update-notify.path
check_user_mask_symlink bootc-update-notify.service

# ===========================================================================
# Step 1.5: factory /var (native dpkg relocation + per-product audit)
# ===========================================================================
echo ""
echo "=== Step 1.5: factory /var ==="

dpkg_link_target="$(vm_ssh 'readlink /var/lib/dpkg' || true)"
assert_eq "/var/lib/dpkg is a symlink with the exact relative relocation target" \
    "$dpkg_link_target" "../../usr/lib/sysimage/dpkg"

# aspell dictionary relocation: same shape as dpkg. cayo carries no
# dictionaries (aspell/aspell-en are snow-only packages), so this verifies
# the structural half — the relocation symlink, its target existing in the
# immutable root, and the audit classifying it as image-metadata — which
# is everything the shared finalize block and 00-snosi-aspell.conf
# provide; the populated snow case differs only in directory contents.
aspell_link_target="$(vm_ssh 'readlink /var/lib/aspell' || true)"
assert_eq "/var/lib/aspell is a symlink with the exact relative relocation target" \
    "$aspell_link_target" "../../usr/lib/sysimage/aspell"
assert_true "/usr/lib/sysimage/aspell exists in the immutable root" \
    vm_ssh 'test -d /usr/lib/sysimage/aspell'

systemd_version="$(vm_ssh "dpkg-query -W -f='\${Version}' systemd" || true)"
assert_true "dpkg-query -W systemd prints a version" bash -c "[[ -n '$systemd_version' ]]"
echo "systemd: $systemd_version"

kernel_version="$(vm_ssh "dpkg-query -W -f='\${Package} \${Version}\n' 'linux-image-*'" || true)"
assert_true "dpkg-query -W 'linux-image-*' prints a version" bash -c "[[ -n '$kernel_version' ]]"
echo "linux-image-*: $kernel_version"

assert_true "/usr/share/snosi/var-inventory.txt exists" \
    vm_ssh 'test -f /usr/share/snosi/var-inventory.txt'
inventory_metadata_lines="$(vm_ssh "grep -c '^image-metadata' /usr/share/snosi/var-inventory.txt" || true)"
assert_true "var-inventory.txt contains at least one image-metadata line" \
    bash -c "[[ '${inventory_metadata_lines:-0}' -ge 1 ]]"
assert_true "var-inventory.txt classifies /var/lib/aspell as image-metadata" \
    vm_ssh "grep -qx 'image-metadata	/var/lib/aspell' /usr/share/snosi/var-inventory.txt"

failed_units_after_var_checks="$(vm_ssh 'systemctl --failed --no-legend' || true)"
assert_eq "no failed systemd units after factory /var checks" "$failed_units_after_var_checks" ""

# ===========================================================================
# Step 2: component topology in the real image
# ===========================================================================
echo ""
echo "=== Step 2: component topology ==="

default_target_listing="$(vm_ssh "ls /usr/lib/sysupdate.d" | LC_ALL=C sort)"
expected_default_listing=$'10-root-verity.transfer\n20-root.transfer\n90-uki.transfer'
assert_eq "/usr/lib/sysupdate.d/ contains exactly the OS transfers, no features" \
    "$default_target_listing" "$expected_default_listing"

expected_sysext_components=(1password 1password-cli azurevpn bitwarden claude-desktop
    coder code-server debdev dev docker edge incus lemonade nix pilothouse podman
    tailscale vscode)

components_raw="$(vm_ssh '/usr/lib/systemd/systemd-sysupdate components --no-legend')"
echo "systemd-sysupdate components --no-legend:"
echo "$components_raw"
mapfile -t components_before <<<"$(awk '{print $1}' <<<"$components_raw" | LC_ALL=C sort -u)"

missing=0
for name in "${expected_sysext_components[@]}"; do
    found=0
    for c in "${components_before[@]}"; do
        [[ "$c" == "$name" ]] && { found=1; break; }
    done
    if [[ $found -eq 1 ]]; then
        pass "component list includes $name"
    else
        fail "component list includes $name" "not present in: $components_raw"
        missing=1
    fi
done
[[ $missing -eq 0 ]] || echo "Warning: one or more expected sysext components missing" >&2

# ===========================================================================
# Step 3: two differently versioned sysext components update independently
# ===========================================================================
echo ""
echo "=== Step 3: independent sysext component updates ==="

vm_ssh 'mkdir -p /etc/sysupdate.testa.d /etc/sysupdate.testb.d /var/lib/extensions.d'
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" \
    "$WORK_DIR/guest-fixtures/sysupdate.testa.d/testa.transfer" \
    "$WORK_DIR/guest-fixtures/sysupdate.testa.d/testa.feature" \
    root@localhost:/etc/sysupdate.testa.d/
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" \
    "$WORK_DIR/guest-fixtures/sysupdate.testb.d/testb.transfer" \
    "$WORK_DIR/guest-fixtures/sysupdate.testb.d/testb.feature" \
    root@localhost:/etc/sysupdate.testb.d/

disk_dev="$(disk_device)"
gpt_before="$(vm_ssh "sfdisk -J '$disk_dev'")"
esp_before="$(vm_ssh 'ls -la /boot/EFI/Linux')"

vm_ssh '/usr/lib/systemd/systemd-sysupdate --component=testa update'
vm_ssh '/usr/lib/systemd/systemd-sysupdate --component=testb update'

testa_target="$(vm_ssh 'readlink /var/lib/extensions.d/testa.raw' || true)"
testb_target="$(vm_ssh 'readlink /var/lib/extensions.d/testb.raw' || true)"
echo "testa.raw -> $testa_target"
echo "testb.raw -> $testb_target"
assert_contains "testa component updated to its newest version (1.3.0)" "$testa_target" "1.3.0"
assert_contains "testb component updated to its newest version (7.1)" "$testb_target" "7.1"
assert_true "testa and testb component versions differ" \
    bash -c "[[ '$testa_target' != '$testb_target' ]]"

gpt_after="$(vm_ssh "sfdisk -J '$disk_dev'")"
esp_after="$(vm_ssh 'ls -la /boot/EFI/Linux')"
assert_eq "GPT partition table byte-identical after sysext component updates" "$gpt_after" "$gpt_before"
assert_eq "ESP /EFI/Linux listing byte-identical after sysext component updates" "$esp_after" "$esp_before"

components_after_raw="$(vm_ssh '/usr/lib/systemd/systemd-sysupdate components --no-legend')"
assert_contains "component list includes testa after enabling" "$components_after_raw" "testa"
assert_contains "component list includes testb after enabling" "$components_after_raw" "testb"

# ===========================================================================
# Step 4: OS update with components enabled
# ===========================================================================
echo ""
echo "=== Step 4: OS update (N -> N+1) with components enabled ==="

extensions_before="$(vm_ssh 'ls -la /var/lib/extensions.d')"
vm_ssh 'mkdir -p /etc/systemd'
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" "$WORK_DIR/import-pubring.gpg" root@localhost:/etc/systemd/import-pubring.gpg
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" -r "$WORK_DIR/definitions" root@localhost:/var/tmp/native-ab-definitions

set +e
update_out="$(vm_ssh "/usr/lib/systemd/systemd-sysupdate --definitions=/var/tmp/native-ab-definitions --verify=yes update '$n1_version'" 2>&1)"
update_rc=$?
set -e
echo "$update_out"
assert_true "unqualified OS update to N+1 succeeds (no version-set collision)" bash -c "[[ $update_rc -eq 0 ]]"

extensions_after="$(vm_ssh 'ls -la /var/lib/extensions.d')"
assert_eq "/var/lib/extensions.d untouched by the OS update" "$extensions_after" "$extensions_before"

reboot_guest
rebooted_version="$(guest_version)"
assert_eq "booted version is N+1 after reboot" "$rebooted_version" "$n1_version"

components_post_reboot="$(vm_ssh '/usr/lib/systemd/systemd-sysupdate components --no-legend')"
assert_contains "testa still listed post-reboot" "$components_post_reboot" "testa"
assert_contains "testb still listed post-reboot" "$components_post_reboot" "testb"
testa_target_post="$(vm_ssh 'readlink /var/lib/extensions.d/testa.raw' || true)"
testb_target_post="$(vm_ssh 'readlink /var/lib/extensions.d/testb.raw' || true)"
assert_contains "testa symlink persists post-reboot (1.3.0)" "$testa_target_post" "1.3.0"
assert_contains "testb symlink persists post-reboot (7.1)" "$testb_target_post" "7.1"

health="$(vm_ssh 'systemctl is-system-running --wait' || true)"
assert_true "system health is running or degraded after OS update" \
    bash -c "[[ '$health' == running || '$health' == degraded ]]"

# ===========================================================================
# Step 5: native /etc drift
# ===========================================================================
echo ""
echo "=== Step 5: native /etc drift tooling ==="

baseline_machine="$(vm_ssh '/usr/bin/snosi-etc-diff --machine')"
baseline_lines="$(grep -c . <<<"$baseline_machine" || true)"
echo "baseline snosi-etc-diff --machine ($baseline_lines lines):"
echo "$baseline_machine"
assert_true "baseline drift is below sane threshold (<20 lines)" bash -c "[[ $baseline_lines -lt 20 ]]"

vm_ssh "printf '\nnative-ab-components-test marker\n' >> /etc/issue"

human_out="$(vm_ssh '/usr/bin/snosi-etc-diff')"
assert_contains "human listing reports M /etc/issue after edit" "$human_out" "M /etc/issue"

path_out="$(vm_ssh '/usr/bin/snosi-etc-diff /etc/issue')"
assert_contains "path-mode output flags /etc/issue as M" "$path_out" "M /etc/issue"
assert_contains "path-mode output shows a unified diff (+ added line)" "$path_out" "+native-ab-components-test marker"

# Force a fresh boot-style drift report while the drift still exists, so we
# can positively assert the report file's existence and content (the
# service deletes the report file entirely when there is zero drift).
vm_ssh 'systemctl start snosi-etc-drift-report.service'
report_result="$(vm_ssh 'systemctl show -p Result --value snosi-etc-drift-report.service')"
assert_eq "snosi-etc-drift-report.service ran successfully" "$report_result" "success"
assert_true "/var/lib/snosi/etc-drift.report exists while drift is present" \
    vm_ssh 'test -f /var/lib/snosi/etc-drift.report'
report_content="$(vm_ssh 'cat /var/lib/snosi/etc-drift.report')"
report_lines="$(grep -c . <<<"$report_content" || true)"
echo "etc-drift.report ($report_lines lines):"
echo "$report_content"
assert_contains "etc-drift.report contains the /etc/issue drift entry" "$report_content" "issue"
assert_true "etc-drift.report line count is below sane threshold (<20 lines)" \
    bash -c "[[ $report_lines -lt 20 ]]"

restore_out="$(vm_ssh '/usr/bin/snosi-etc-diff --restore /etc/issue')"
assert_contains "restore reports success" "$restore_out" "restored /etc/issue"

after_restore="$(vm_ssh '/usr/bin/snosi-etc-diff')"
assert_not_contains "M /etc/issue no longer reported after restore" "$after_restore" "M /etc/issue"

vm_ssh 'systemctl start snosi-etc-drift-report.service'
post_restore_lines="$(vm_ssh '[[ -f /var/lib/snosi/etc-drift.report ]] && wc -l < /var/lib/snosi/etc-drift.report || echo 0')"
assert_true "etc-drift.report reflects baseline (<=$baseline_lines lines) once /etc/issue drift is restored" \
    bash -c "[[ $post_restore_lines -le $baseline_lines ]]"

leftover_mounts="$(vm_ssh "mount | grep -c snosi-etc-diff" || true)"
assert_eq "no leftover snosi-etc-diff bind mounts" "$leftover_mounts" "0"

echo ""
echo "Native A/B components test: N=$n_version -> N+1=$n1_version"
print_summary
