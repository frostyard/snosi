#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Phase 7 end-to-end rehearsal of the production-shaped publication/signing
# pipeline (shared/native-ab/publish/{publish-candidate,verify-remote,promote,
# withdraw}.sh, docs/native-ab-contracts.md §4/§5/§7, plan "Atomic
# Publication Procedure"). Everything runs against a LOCAL origin -- no
# uploads to real R2/Cloudflare -- but every pipeline script invocation is
# the exact one a real run against `rclone:r2:<bucket>` would use, just with
# a local-directory DEST instead (see publish-lib.sh's header).
#
# Scaffolding choice (brief: "secure-boot harness scaffolding or the lighter
# updateux scaffolding -- your choice, document it"): this test builds
# `cayo-ab-raw` (unsigned, no Secure Boot/MOK), NOT `cayo-ab`. It uses the
# same "publish under the channel name" trick already established by
# test/native-ab-updateux-test.sh and test/native-ab-components-test.sh:
# prepare-native-publication.sh's channel-name argument is validated
# independently of which mkosi profile actually produced the bytes, so
# cayo-ab-raw's split artifacts are staged under symlinks literally named
# "cayo-ab.*" before being handed to it. This is deliberate and safe for
# THIS test's purpose: shared/native-ab/keys/README.md documents that the
# DEV update-signing pubring ships at /usr/lib/systemd/import-pubring.gpg on
# EVERY native A/B image via the shared shared/outformat/ab-root/mkosi.conf
# fragment, cayo-ab-raw included -- so booting cayo-ab-raw and NEVER
# touching /etc/systemd/import-pubring.gpg gives exactly the "verify against
# the stock shipped pubring" trust path the brief requires, without paying
# for OVMF Secure Boot + MOK enrollment (Phase 6 territory, orthogonal to
# update-signature verification). The origin URL override (/etc/sysupdate.d
# whole-file replacement, documented in usr/libexec/snosi-sysupdate-stage's
# own header) is used exactly as in test/native-ab-updateux-test.sh; the
# pubring override mechanism that script ALSO demonstrates is deliberately
# NOT used here.
#
# Local HTTP origin: test/lib/range-http-server.py, NOT plain
# `python3 -m http.server` -- see that script's header for why (stdlib's
# SimpleHTTPRequestHandler has no Range support at all, which would make
# verify-remote.sh's mandatory range-GET check meaningless).
#
# Sequence (brief section B):
#   1. Build cayo-ab-raw twice (N, N+1); prepare publication with --xz.
#   2. publish-candidate.sh -> local origin; served by the range HTTP server.
#   3. verify-remote.sh: corrupt one candidate byte first (must fail
#      closed), then a clean pass.
#   4. promote.sh with the committed DEV key; assert signature-first
#      ordering (nanosecond mtimes) and both no-store sidecars.
#   5. QEMU: boot N directly (mkosi's cayo-ab-raw output is already a
#      bootable GPT disk -- no bootc/podman install step for native
#      images), point the guest's OS transfers at the local origin via the
#      documented /etc/sysupdate.d override, do NOT touch the pubring.
#      Stage promoted N+1 via snosi-sysupdate-stage; reboot; assert N+1.
#   6. Tamper cases (each must fail closed, guest stays on N+1): (a) a
#      payload byte flipped after signing; (b) partial publication (new
#      SHA256SUMS.gpg + old SHA256SUMS); (c) resigned index with a WRONG
#      (untrusted) key. All three reuse N+1's real, already-verified bytes
#      hardlinked under a fabricated higher version number (same trick as
#      test/native-ab-updateux-test.sh's tamper case), run through the REAL
#      publish-candidate/promote pipeline scripts, so what gets corrupted
#      afterwards is deliberately narrow and documented per case.
#   7. Withdrawal: withdraw.sh back to N+1's own archived pair; guest
#      check reports current/no-newer.
#
# Usage: sudo ./test/native-ab-publication-test.sh
# Env overrides: SKIP_BUILD=1 with BUILD_N_DIR/BUILD_N1_DIR to reuse
# already-built cayo-ab-raw output dirs (each must contain
# cayo-ab-raw.manifest, cayo-ab-raw.raw, cayo-ab-raw.efi,
# cayo-ab-raw.cayo_@v.root.raw.raw, cayo-ab-raw.cayo_@v.root-verity.raw.raw)
# instead of building fresh (tens of minutes each).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PUBLISH_DIR="$ROOT_DIR/shared/native-ab/publish"
: "${KEEP_VM:=0}"
: "${SOURCE_PORT:=18192}"
: "${SSH_PORT:=2225}"
: "${SSH_TIMEOUT:=300}"
: "${SKIP_BUILD:=0}"
: "${BUILD_N_DIR:=}"
: "${BUILD_N1_DIR:=}"

PROFILE=cayo-ab-raw
IMAGE_ID=cayo
CHANNEL="${IMAGE_ID}-ab"
SIGNING_KEY="$ROOT_DIR/.snosi-private/os-update-signing.key"
PUBRING="$ROOT_DIR/shared/native-ab/keys/import-pubring.gpg"

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

assert_false() { # description command...
    local desc="$1"
    shift
    if "$@"; then
        fail "$desc" "command unexpectedly succeeded: $*"
    else
        pass "$desc"
    fi
}

assert_contains() { # description haystack needle
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1" "expected to find: $3 -- got: $2"
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

# build_profile dest_dir -- clean build $PROFILE (forcing a rebuild if
# mkosi's own output already exists from an earlier invocation this run),
# copy its split artifacts into a stable destination (mkosi wipes output/ on
# the next clean build).
build_profile() {
    local dest="$1"
    mkdir -p "$dest"
    echo "Building $PROFILE -> $dest (started $(date -u +%FT%TZ))"
    "$MKOSI" --profile "$PROFILE" --force build
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

# prepare_version build_dir dest_root -- stage build_dir's split artifacts
# under the CHANNEL name (the "publish under the channel name" trick, see
# header) and run the real prepare-native-publication.sh --xz against them.
# Prints the prepared product/x86-64 directory path.
prepare_version() {
    local build_dir="$1" dest_root="$2" stage
    stage="$(mktemp -d "$WORK_DIR/prepare-src.XXXXXX")"
    for suffix in manifest raw efi "${IMAGE_ID}_@v.root.raw.raw" "${IMAGE_ID}_@v.root-verity.raw.raw"; do
        ln -s "$build_dir/$PROFILE.$suffix" "$stage/$CHANNEL.$suffix"
    done
    # The feature catalog is looked up as <product>.features.json, where
    # product is the manifest's .config.name (= IMAGE_ID) -- NOT the
    # channel-prefixed name the other staged artifacts use.
    ln -s "$build_dir/$PROFILE.features.json" "$stage/${IMAGE_ID}.features.json"
    "$PUBLISH_DIR/prepare-native-publication.sh" --xz "$stage" "$CHANNEL" "$dest_root" >&2
    echo "$dest_root/$IMAGE_ID/x86-64"
}

# build_fake_prepared_dir real_prepared_dir fake_version dest_root -- builds
# a synthetic prepared-dir claiming version $fake_version, made of HARDLINKS
# to real_prepared_dir's real, already-verified bytes (same "fabricate a
# newer filename set from real bytes" trick as
# test/native-ab-updateux-test.sh's tamper case: no 3rd multi-gigabyte
# build, and it guarantees systemd-sysupdate actually attempts a real
# verify/update rather than silently no-opping as "nothing newer"). Prints
# the prepared product/x86-64 directory path.
build_fake_prepared_dir() {
    local real_dir="$1" fake_version="$2" dest_root="$3" dest
    dest="$dest_root/$IMAGE_ID/x86-64"
    mkdir -p "$dest"

    local real_root real_verity real_disk real_efi real_manifest real_sbom
    real_root="$(find "$real_dir" -maxdepth 1 -name "${CHANNEL}_*.root.raw.xz")"
    real_verity="$(find "$real_dir" -maxdepth 1 -name "${CHANNEL}_*.root-verity.raw.xz")"
    real_disk="$(find "$real_dir" -maxdepth 1 -name "${CHANNEL}_*.disk.raw.xz")"
    real_efi="$(find "$real_dir" -maxdepth 1 -name "${CHANNEL}_*.efi")"
    real_manifest="$(find "$real_dir" -maxdepth 1 -name "${CHANNEL}_*.manifest.json")"
    real_sbom="$(find "$real_dir" -maxdepth 1 -name "${CHANNEL}_*.sbom.spdx.json")"

    local root_uuid verity_uuid real_version
    real_version="$(jq -er '.version' "$real_dir/publication-info.json")"
    root_uuid="$(basename "$real_root" | sed -E "s/^${CHANNEL}_${real_version}_([0-9a-fA-F-]+)\.root\.raw\.xz\$/\\1/")"
    verity_uuid="$(basename "$real_verity" | sed -E "s/^${CHANNEL}_${real_version}_([0-9a-fA-F-]+)\.root-verity\.raw\.xz\$/\\1/")"

    local fake_root="$dest/${CHANNEL}_${fake_version}_${root_uuid}.root.raw.xz"
    local fake_verity="$dest/${CHANNEL}_${fake_version}_${verity_uuid}.root-verity.raw.xz"
    local fake_disk="$dest/${CHANNEL}_${fake_version}.disk.raw.xz"
    local fake_efi="$dest/${CHANNEL}_${fake_version}.efi"
    local fake_manifest="$dest/${CHANNEL}_${fake_version}.manifest.json"
    local fake_sbom="$dest/${CHANNEL}_${fake_version}.sbom.spdx.json"
    ln -f "$real_root" "$fake_root"
    ln -f "$real_verity" "$fake_verity"
    ln -f "$real_disk" "$fake_disk"
    ln -f "$real_efi" "$fake_efi"
    ln -f "$real_manifest" "$fake_manifest"
    ln -f "$real_sbom" "$fake_sbom"

    (cd "$dest" && sha256sum "$(basename "$fake_root")" "$(basename "$fake_verity")" \
        "$(basename "$fake_disk")" "$(basename "$fake_efi")" \
        "$(basename "$fake_manifest")" "$(basename "$fake_sbom")") >"$dest/SHA256SUMS"

    jq -n --arg product "$IMAGE_ID" --arg channel "$CHANNEL" --arg version "$fake_version" \
        --arg root "$(basename "$fake_root")" --arg verity "$(basename "$fake_verity")" \
        --arg disk "$(basename "$fake_disk")" --arg efi "$(basename "$fake_efi")" \
        --arg manifest "$(basename "$fake_manifest")" --arg sbom "$(basename "$fake_sbom")" \
        --arg root_uuid "$root_uuid" --arg verity_uuid "$verity_uuid" \
        '{product: $product, channel: $channel, version: $version, xz: true,
          partuuids: {root: $root_uuid, verity: $verity_uuid},
          artifacts: {
            root: {name: $root}, root_verity: {name: $verity}, disk: {name: $disk},
            efi: {name: $efi}, manifest: {name: $manifest}, sbom: {name: $sbom}}}' \
        >"$dest/publication-info.json"

    echo "$dest"
}

check_masked() { # unit
    local status
    status="$(vm_ssh "systemctl is-enabled $1" || true)"
    assert_eq "$1 is masked" "$status" "masked"
}

assert_no_update_activity() {
    check_masked bootc-update-stage.timer
    check_masked bootc-update-stage.service
    check_masked nbc-update-download.timer
    check_masked nbc-update-download.service
    check_masked systemd-sysupdate.timer
    check_masked systemd-sysupdate-reboot.timer
}

# run_stager -- runs the guest stager over SSH, printing its output and
# returning its exit code (never aborting the test script on a nonzero
# stager exit -- callers decide what that means).
run_stager() {
    local out rc=0
    out="$(vm_ssh '/usr/libexec/snosi-sysupdate-stage' 2>&1)" || rc=$?
    echo "$out"
    return "$rc"
}

for command in jq losetup mount xz python3 qemu-system-x86_64 gpg gpgv git sfdisk curl rsync; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done
[[ $EUID -eq 0 ]] || { echo "Error: must run as root" >&2; exit 1; }
[[ -s "$SIGNING_KEY" ]] || { echo "Error: DEV signing key not found: $SIGNING_KEY" >&2; exit 1; }
[[ -s "$PUBRING" ]] || { echo "Error: DEV pubring not found: $PUBRING" >&2; exit 1; }

trap cleanup EXIT
WORK_DIR="$(mktemp -d /var/tmp/native-ab-publication-test.XXXXXX)"
mkdir -p "$WORK_DIR/mnt" "$WORK_DIR/origin"

echo "=== Step 0: build N and N+1 (this takes tens of minutes unless SKIP_BUILD=1) ==="
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
# Step 1: prepare-native-publication.sh --xz for both N and N+1
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 1: prepare-native-publication.sh --xz ==="
prepared_n="$(prepare_version "$BUILD_N_DIR" "$WORK_DIR/prepared-n")"
prepared_n1="$(prepare_version "$BUILD_N1_DIR" "$WORK_DIR/prepared-n1")"
assert_true "prepared N has a sbom.spdx.json" test -f "$prepared_n/${CHANNEL}_${n_version}.sbom.spdx.json"
assert_true "prepared N+1 has a sbom.spdx.json" test -f "$prepared_n1/${CHANNEL}_${n1_version}.sbom.spdx.json"

DEST="$WORK_DIR/origin"
HOST_BASE_URL="http://127.0.0.1:${SOURCE_PORT}/os/native/v1/${IMAGE_ID}/x86-64"
GUEST_BASE_URL="http://10.0.2.2:${SOURCE_PORT}/os/native/v1/${IMAGE_ID}/x86-64"

python3 "$SCRIPT_DIR/lib/range-http-server.py" "$SOURCE_PORT" "$DEST" >"$WORK_DIR/http.log" 2>&1 &
HTTP_PID=$!
sleep 1
kill -0 "$HTTP_PID" 2>/dev/null || { echo "Error: range HTTP server failed to start" >&2; cat "$WORK_DIR/http.log" >&2; exit 1; }

# ===========================================================================
# Step 2-3: publish-candidate.sh, verify-remote.sh (tamper then clean)
# ===========================================================================
echo ""
echo "=== Step 2: publish-candidate.sh (N) ==="
"$PUBLISH_DIR/publish-candidate.sh" "$prepared_n" "$DEST"
assert_true "candidate root object exists under .candidate/$n_version/" \
    bash -c "find '$DEST/os/native/v1/$IMAGE_ID/x86-64/.candidate/$n_version' -name '${CHANNEL}_${n_version}_*.root.raw.xz' | grep -q ."
assert_true "candidate objects carry an immutable Cache-Control sidecar" \
    bash -c "grep -q 'immutable' '$DEST/os/native/v1/$IMAGE_ID/x86-64/.candidate/$n_version/${CHANNEL}_${n_version}.efi.meta.json'"

echo ""
echo "=== Step 3a: verify-remote.sh must FAIL closed on a corrupted candidate byte ==="
n_efi_candidate="$DEST/os/native/v1/$IMAGE_ID/x86-64/.candidate/$n_version/${CHANNEL}_${n_version}.efi"
printf 'X' | dd of="$n_efi_candidate" bs=1 seek=0 count=1 conv=notrunc status=none
set +e
"$PUBLISH_DIR/verify-remote.sh" "$prepared_n" "$HOST_BASE_URL"
verify_rc=$?
set -e
assert_true "verify-remote exits nonzero on a corrupted candidate object" bash -c "[[ $verify_rc -ne 0 ]]"

echo ""
echo "=== Step 3b: verify-remote.sh clean pass after re-publishing ==="
"$PUBLISH_DIR/publish-candidate.sh" "$prepared_n" "$DEST"
"$PUBLISH_DIR/verify-remote.sh" "$prepared_n" "$HOST_BASE_URL"
pass "verify-remote clean pass for N"

# ===========================================================================
# Step 4: promote.sh with the DEV key; assert ordering + no-store sidecars
# ===========================================================================
echo ""
echo "=== Step 4: promote.sh (N) with the committed DEV key ==="
"$PUBLISH_DIR/promote.sh" --signing-key "$SIGNING_KEY" "$prepared_n" "$HOST_BASE_URL" "$DEST"

product_dir="$DEST/os/native/v1/$IMAGE_ID/x86-64"
assert_true "final SHA256SUMS.gpg exists after promotion" test -f "$product_dir/SHA256SUMS.gpg"
assert_true "final SHA256SUMS exists after promotion" test -f "$product_dir/SHA256SUMS"
# %y (human-readable, nanosecond-precision, fixed-width) sorts correctly as
# a plain string; %Y is whole seconds only and too coarse to observe
# ordering within the same second on a fast local rehearsal.
gpg_mtime="$(stat -c %y "$product_dir/SHA256SUMS.gpg")"
sums_mtime="$(stat -c %y "$product_dir/SHA256SUMS")"
assert_true "SHA256SUMS.gpg written before (or same instant as, never after) SHA256SUMS" \
    bash -c "[[ '$gpg_mtime' < '$sums_mtime' || '$gpg_mtime' == '$sums_mtime' ]]"
assert_contains "SHA256SUMS.gpg sidecar is no-store" \
    "$(cat "$product_dir/SHA256SUMS.gpg.meta.json")" "no-store"
assert_contains "SHA256SUMS sidecar is no-store" \
    "$(cat "$product_dir/SHA256SUMS.meta.json")" "no-store"
assert_true "gpgv accepts the promoted index against the committed DEV pubring" \
    gpgv --keyring "$PUBRING" "$product_dir/SHA256SUMS.gpg" "$product_dir/SHA256SUMS"

# ===========================================================================
# Step 5: QEMU -- boot N, point transfers at the local origin, do NOT touch
# the pubring, stage N+1, reboot, assert N+1
# ===========================================================================
echo ""
echo "=== Step 5: QEMU boot N ==="

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

vm_start "$DISK_IMAGE"
wait_for_ssh

booted_version="$(guest_version)"
assert_eq "booted version is N" "$booted_version" "$n_version"
vm_ssh 'systemctl is-system-running --wait' >/dev/null || true
assert_no_update_activity

vm_ssh 'cat /usr/lib/systemd/import-pubring.gpg' >"$WORK_DIR/guest-pubring.gpg"
assert_true "guest's shipped pubring is the committed DEV pubring (byte-identical)" \
    cmp -s "$WORK_DIR/guest-pubring.gpg" "$PUBRING"
assert_false "no /etc pubring override present (this test never installs one -- the whole point)" \
    vm_ssh 'test -e /etc/systemd/import-pubring.gpg'

# Origin override transfer files: byte-identical to the shipped channel
# transfers except [Source] Path= (documented mechanism, see
# usr/libexec/snosi-sysupdate-stage's header and test/native-ab-updateux-
# test.sh, which uses the identical trick).
mkdir -p "$WORK_DIR/overrides"
for f in 10-root-verity 20-root 90-uki; do
    # Only the [Source] section's Path= is the origin URL -- [Target] also
    # has its own Path= (e.g. "Path=auto" / "Path=/EFI/Linux") that must be
    # left untouched. A section-blind `sed s/^Path=.../` would rewrite BOTH,
    # corrupting the transfer file (systemd-sysupdate then rejects it:
    # "Target path is not a normalized, absolute path") -- caught live in
    # this test's own first run.
    awk -v url="${GUEST_BASE_URL}/" '
        /^\[/ { section = $0 }
        section == "[Source]" && /^Path=/ { print "Path=" url; next }
        { print }
    ' "$ROOT_DIR/shared/native-ab/channels/$IMAGE_ID/tree/usr/lib/sysupdate.d/$f.transfer" \
        >"$WORK_DIR/overrides/$f.transfer"
done
vm_ssh 'mkdir -p /etc/sysupdate.d'
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" \
    "$WORK_DIR/overrides/10-root-verity.transfer" \
    "$WORK_DIR/overrides/20-root.transfer" \
    "$WORK_DIR/overrides/90-uki.transfer" \
    root@localhost:/etc/sysupdate.d/

echo "--- guest stager on N (nothing promoted newer than N yet) ---"
set +e
run_stager
stager_rc=$?
set -e
assert_eq "manual stager run on N (nothing newer) exits 0" "$stager_rc" "0"
check_content="$(vm_ssh 'cat /run/snosi/update-check' 2>/dev/null || true)"
assert_contains "update-check reports outcome=current on N" "$check_content" "outcome=current"

echo ""
echo "=== Step 5b: publish + verify + promote N+1 ==="
"$PUBLISH_DIR/publish-candidate.sh" "$prepared_n1" "$DEST"
"$PUBLISH_DIR/verify-remote.sh" "$prepared_n1" "$HOST_BASE_URL"
"$PUBLISH_DIR/promote.sh" --signing-key "$SIGNING_KEY" "$prepared_n1" "$HOST_BASE_URL" "$DEST"
assert_true "N's signed index was archived to .history/$n_version/ by the N+1 promotion" \
    test -f "$product_dir/.history/$n_version/SHA256SUMS.gpg"

echo "--- guest stager stages N+1 ---"
run_stager
stager_rc=$?
assert_eq "manual stager run stages N+1" "$stager_rc" "0"
check_content="$(vm_ssh 'cat /run/snosi/update-check' 2>/dev/null || true)"
assert_contains "update-check reports outcome=staged" "$check_content" "outcome=staged"
sem_content="$(vm_ssh 'cat /run/snosi/update-staged' 2>/dev/null || true)"
assert_contains "semaphore records the staged N+1 version" "$sem_content" "version=$n1_version"

echo ""
echo "=== Step 5c: reboot into N+1 ==="
reboot_guest
rebooted_version="$(guest_version)"
assert_eq "booted version is N+1 after reboot" "$rebooted_version" "$n1_version"
vm_ssh 'systemctl is-system-running --wait' >/dev/null || true
assert_false "reboot-pending semaphore is gone after the applying reboot" \
    vm_ssh 'test -e /run/snosi/update-staged'
assert_no_update_activity

# ===========================================================================
# Step 6: tamper cases -- each must fail closed, guest stays on N+1
# ===========================================================================
fake_version="$(printf '%014d' "$((n1_version + 1))")"
echo ""
echo "=== Step 6: tamper cases (fabricated version $fake_version, real N+1 bytes) ==="

# --- (a) payload byte flipped after signing ---------------------------------
echo ""
echo "--- Step 6a: payload byte flipped after signing ---"
fake_dir_a="$(build_fake_prepared_dir "$prepared_n1" "$fake_version" "$WORK_DIR/prepared-fake-a")"
"$PUBLISH_DIR/publish-candidate.sh" "$fake_dir_a" "$DEST"
"$PUBLISH_DIR/verify-remote.sh" "$fake_dir_a" "$HOST_BASE_URL"
"$PUBLISH_DIR/promote.sh" --signing-key "$SIGNING_KEY" "$fake_dir_a" "$HOST_BASE_URL" "$DEST"
assert_true "gpgv accepts the correctly-signed fake-$fake_version index before corruption" \
    gpgv --keyring "$PUBRING" "$product_dir/SHA256SUMS.gpg" "$product_dir/SHA256SUMS"
fake_root_final="$(find "$product_dir" -maxdepth 1 -name "${CHANNEL}_${fake_version}_*.root.raw.xz")"
printf 'X' | dd of="$fake_root_final" bs=1 seek=0 count=1 conv=notrunc status=none

set +e
run_stager
stager_rc=$?
set -e
assert_true "stager exits nonzero on a payload corrupted after signing" bash -c "[[ $stager_rc -ne 0 ]]"
check_content="$(vm_ssh 'cat /run/snosi/update-check' 2>/dev/null || true)"
assert_contains "update-check reports outcome=failed (6a)" "$check_content" "outcome=failed"
assert_false "no semaphore from the failed run (6a)" vm_ssh 'test -e /run/snosi/update-staged'
final_version="$(guest_version)"
assert_eq "running version unchanged after 6a" "$final_version" "$n1_version"

# --- (b) partial publication: new SHA256SUMS.gpg + old SHA256SUMS -----------
echo ""
echo "--- Step 6b: partial publication (new signature, old manifest) ---"
fake_dir_b="$(build_fake_prepared_dir "$prepared_n1" "$fake_version" "$WORK_DIR/prepared-fake-b")"
"$PUBLISH_DIR/publish-candidate.sh" "$fake_dir_b" "$DEST"
"$PUBLISH_DIR/verify-remote.sh" "$fake_dir_b" "$HOST_BASE_URL"
"$PUBLISH_DIR/promote.sh" --signing-key "$SIGNING_KEY" "$fake_dir_b" "$HOST_BASE_URL" "$DEST"
# Roll back JUST the manifest to N+1's real, currently-archived (by the
# promotion above) SHA256SUMS content -- the just-uploaded signature stays,
# now covering different bytes than what SHA256SUMS actually contains.
cp "$product_dir/.history/$n1_version/SHA256SUMS" "$product_dir/SHA256SUMS"
assert_false "gpgv rejects the deliberately mismatched (new sig / old manifest) pair" \
    gpgv --keyring "$PUBRING" "$product_dir/SHA256SUMS.gpg" "$product_dir/SHA256SUMS"

set +e
run_stager
stager_rc=$?
set -e
assert_true "stager exits nonzero on a mismatched signature/manifest pair" bash -c "[[ $stager_rc -ne 0 ]]"
check_content="$(vm_ssh 'cat /run/snosi/update-check' 2>/dev/null || true)"
assert_contains "update-check reports outcome=failed (6b)" "$check_content" "outcome=failed"
assert_false "no semaphore from the failed run (6b)" vm_ssh 'test -e /run/snosi/update-staged'
final_version="$(guest_version)"
assert_eq "running version unchanged after 6b" "$final_version" "$n1_version"

# --- (c) resigned index with a WRONG (untrusted) key -------------------------
echo ""
echo "--- Step 6c: resigned index with a wrong, untrusted key ---"
fake_dir_c="$(build_fake_prepared_dir "$prepared_n1" "$fake_version" "$WORK_DIR/prepared-fake-c")"
"$PUBLISH_DIR/publish-candidate.sh" "$fake_dir_c" "$DEST"
"$PUBLISH_DIR/verify-remote.sh" "$fake_dir_c" "$HOST_BASE_URL"

WRONG_GNUPGHOME="$WORK_DIR/wrong-gnupghome"
mkdir -p "$WRONG_GNUPGHOME"
chmod 700 "$WRONG_GNUPGHOME"
GNUPGHOME="$WRONG_GNUPGHOME" gpg --batch --passphrase '' --quick-generate-key \
    'native-ab-publication-test WRONG key <wrong@invalid>' ed25519 sign 0 >/dev/null 2>&1
"$PUBLISH_DIR/promote.sh" --gnupghome "$WRONG_GNUPGHOME" "$fake_dir_c" "$HOST_BASE_URL" "$DEST"
assert_false "gpgv rejects an index signed by an untrusted key" \
    gpgv --keyring "$PUBRING" "$product_dir/SHA256SUMS.gpg" "$product_dir/SHA256SUMS"

set +e
run_stager
stager_rc=$?
set -e
assert_true "stager exits nonzero on a wrong-key signature" bash -c "[[ $stager_rc -ne 0 ]]"
check_content="$(vm_ssh 'cat /run/snosi/update-check' 2>/dev/null || true)"
assert_contains "update-check reports outcome=failed (6c)" "$check_content" "outcome=failed"
assert_false "no semaphore from the failed run (6c)" vm_ssh 'test -e /run/snosi/update-staged'
final_version="$(guest_version)"
assert_eq "running version unchanged after 6c" "$final_version" "$n1_version"

final_layout="$(vm_ssh 'lsblk -J -o PARTLABEL' 2>/dev/null || echo "{}")"
fake_label_count="$(jq --arg l "${IMAGE_ID}_${fake_version}_r" \
    '[.. | objects | select(.partlabel? == $l)] | length' <<<"$final_layout")"
assert_eq "no partition labeled with the fabricated fake version exists after all 3 tamper cases" "$fake_label_count" "0"

# ===========================================================================
# Step 7: withdrawal -- restore N+1's own archived pair; guest reports
# current/no-newer
# ===========================================================================
echo ""
echo "=== Step 7: withdraw.sh back to N+1's archived pair ==="
"$PUBLISH_DIR/withdraw.sh" --pubring "$PUBRING" "$IMAGE_ID" "$n1_version" "$DEST"
assert_true "gpgv accepts the withdrawn (restored) index" \
    gpgv --keyring "$PUBRING" "$product_dir/SHA256SUMS.gpg" "$product_dir/SHA256SUMS"
assert_contains "restored SHA256SUMS advertises N+1's manifest again" \
    "$(cat "$product_dir/SHA256SUMS")" "${CHANNEL}_${n1_version}.manifest.json"

set +e
run_stager
stager_rc=$?
set -e
assert_eq "guest stager after withdrawal exits 0 (nothing newer than running N+1)" "$stager_rc" "0"
check_content="$(vm_ssh 'cat /run/snosi/update-check' 2>/dev/null || true)"
assert_contains "update-check reports outcome=current after withdrawal" "$check_content" "outcome=current"

final_version="$(guest_version)"
assert_eq "guest is still running N+1 after the full tamper+withdrawal sequence" "$final_version" "$n1_version"

echo ""
echo "Native A/B publication pipeline rehearsal: N=$n_version -> N+1=$n1_version, 3/3 tamper cases rejected, withdrawal verified"
print_summary
