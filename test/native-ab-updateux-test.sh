#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Phase 4 QEMU validation (docs/plans/2026-07-14-bootc-native-ab-coexistence-
# plan.md, "Phase 4: Build Native Update UX" exit criterion):
#
#   "boot tests prove each format starts exactly one update stack and an
#   already-installed publication-disabled image acquires the static native
#   timer when upgraded to the first publication-enabled image."
#
# Builds two real versions of profile $PROFILE (default cayo-ab-raw) via the
# pinned .mkosi checkout, mirroring test/native-ab-components-test.sh's
# scaffolding:
#   N    -- ordinary build, SNOSI_NATIVE_AUTOSTAGE unset (publication-
#           disabled: the stager timer ships present but inert).
#   N+1  -- built with SNOSI_NATIVE_AUTOSTAGE=1 (publication-enabled: the
#           finalize script creates the static timers.target.wants/ link).
#
# Publishes both through the real naming pipeline
# (shared/native-ab/publish/prepare-native-publication.sh --xz) to a local
# HTTP fixture origin, signed with an ephemeral GPG key.
#
# Guest trust override (documented mechanism, no shipped-default weakened):
# the image ships the DEV pubring at /usr/lib/systemd/import-pubring.gpg
# (shared/native-ab/keys/import-pubring.gpg, unchanged). This test installs
# the ephemeral TEST key at /etc/systemd/import-pubring.gpg, which takes
# precedence over the /usr/lib copy by ordinary systemd config search-path
# precedence (the same mechanism used by test/native-ab-update-test.sh and
# test/native-ab-components-test.sh) -- the shipped production default is
# never touched.
#
# Origin override (documented mechanism, see snosi-sysupdate-stage's own
# header): the 3 shipped OS *.transfer files in
# shared/native-ab/channels/cayo/tree/usr/lib/sysupdate.d/ point at the
# production R2 URL. This test drops byte-identical replacements, differing
# only in [Source] Path=, into /etc/sysupdate.d/ -- whole-file override by
# identical name, confirmed to be the only override mechanism sysupdate.d(5)
# actually supports (no NAME.transfer.d/ drop-ins). The stager itself never
# reads a URL from an env var; it always invokes the bare `systemd-sysupdate`
# CLI with no --definitions=, so production and this test exercise the
# identical code path.
#
# Sequence (docs/plans/.../Phase 4 exit criterion + brief):
#   1. Boot N: no bootc/nbc/upstream-sysupdate activity; the native stager
#      timer is present but inert (no wants link, is-enabled=static). A
#      manual stager run against an origin that only promotes N itself
#      reports outcome=current; the motd hook agrees.
#   2. Publish N+1 to the SAME origin (built with SNOSI_NATIVE_AUTOSTAGE=1).
#      A manual stager run stages it, passing its own post-stage checks;
#      update-check/semaphore/motd/snosi-update-status all agree; the user
#      notify unit files and their static wants link are present; running
#      the shared notify script directly (stubbed notify-send) proves
#      ack-gating fires once per staged version.
#   3. Reboot into N+1: the static wants link for the stager timer arrived
#      WITH the image -- assert it is ACTIVE (the Phase 4 exit criterion).
#      The semaphore is gone (fresh /run). A manual stager run against the
#      now-current origin reports outcome=current again; snosi-update-status
#      agrees; exactly one update stack (the native one) is active.
#   4. Tamper case: fabricate a filename set claiming a version newer than
#      N+1 (hardlinks to N+1's real, already-signed-and-verified bytes --
#      cheap, no 3rd mkosi build, and guarantees the fabricated "newer"
#      version forces sysupdate through an actual verify/update attempt
#      rather than silently no-opping as "nothing newer"), sign a valid
#      SHA256SUMS for it, then truncate SHA256SUMS.gpg to break the
#      signature. A manual stager run must fail closed: outcome=failed,
#      nothing staged, running version unchanged.
#
# Usage: sudo ./test/native-ab-updateux-test.sh
# Env overrides (docs/native-ab-contracts.md §1): PROFILE (default
# cayo-ab-raw), IMAGE_ID (derived from PROFILE by default), CHANNEL
# (derived as <IMAGE_ID>-ab by default).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${KEEP_VM:=0}"
: "${SOURCE_PORT:=18094}"
: "${SSH_PORT:=2224}"
: "${SSH_TIMEOUT:=300}"
: "${SKIP_BUILD:=0}"
: "${BUILD_N_DIR:=}"
: "${BUILD_N1_DIR:=}"

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

# build_profile dest_dir [env=val...] -- clean build $PROFILE, optionally
# with extra environment variables set for just this invocation (used to set
# SNOSI_NATIVE_AUTOSTAGE=1 for the N+1 build), and copy its split artifacts
# into a stable destination (mkosi clean -ff wipes output/ on the next call).
build_profile() {
    local dest="$1"
    shift
    mkdir -p "$dest"
    echo "Building $PROFILE -> $dest (env: ${*:-none}) (started $(date -u +%FT%TZ))"
    "$MKOSI" clean -ff
    env "$@" "$MKOSI" --profile "$PROFILE" build
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

sign_sums() { # dir
    gpg --homedir "$WORK_DIR/gnupg" --batch --yes --detach-sign \
        -o "$1/SHA256SUMS.gpg" "$1/SHA256SUMS"
}

# publish_version build_dir -- run the real publication pipeline against a
# build's outputs, staged under the publishable channel name (this refuses
# to "publish" *-ab-raw dev fixtures by name, same trick as
# native-ab-components-test.sh). Leaves the result (root/verity/efi/disk/
# manifest + a freshly generated, freshly signed SHA256SUMS/.gpg describing
# ONLY this version) in $publish_dest.
publish_version() {
    local build_dir="$1" stage
    stage="$(mktemp -d "$WORK_DIR/publish-src.XXXXXX")"
    for suffix in manifest raw efi "${IMAGE_ID}_@v.root.raw.raw" "${IMAGE_ID}_@v.root-verity.raw.raw"; do
        ln -s "$build_dir/$PROFILE.$suffix" "$stage/$CHANNEL.$suffix"
    done
    # The feature catalog is looked up as <product>.features.json, where
    # product is the manifest's .config.name (= IMAGE_ID) -- NOT the
    # channel-prefixed name the other staged artifacts use.
    ln -s "$build_dir/$PROFILE.features.json" "$stage/${IMAGE_ID}.features.json"
    "$ROOT_DIR/shared/native-ab/publish/prepare-native-publication.sh" --xz \
        "$stage" "$CHANNEL" "$WORK_DIR/publish-out"
    publish_dest="$WORK_DIR/publish-out/$IMAGE_ID/x86-64"
    sign_sums "$publish_dest"
}

check_masked() { # unit
    local status
    status="$(vm_ssh "systemctl is-enabled $1" || true)"
    assert_eq "$1 is masked" "$status" "masked"
}

# assert_no_update_activity -- bootc/nbc/upstream-sysupdate must never be
# active on a native image, regardless of the Phase 4 activation state of
# our own stager (this IS the "exactly one update stack" half of the check
# on both the N and N+1 boots).
assert_no_update_activity() {
    check_masked bootc-update-stage.timer
    check_masked bootc-update-stage.service
    check_masked nbc-update-download.timer
    check_masked nbc-update-download.service
    check_masked systemd-sysupdate.timer
    check_masked systemd-sysupdate-reboot.timer
}

for command in jq losetup mount xz python3 qemu-system-x86_64 gpg git sfdisk curl; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done
[[ $EUID -eq 0 ]] || { echo "Error: must run as root" >&2; exit 1; }

trap cleanup EXIT
WORK_DIR="$(mktemp -d /var/tmp/native-ab-updateux-test.XXXXXX)"
mkdir -p "$WORK_DIR/mnt" "$WORK_DIR/gnupg" "$WORK_DIR/overrides" "$WORK_DIR/publish-out"
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
    build_profile "$BUILD_N1_DIR" SNOSI_NATIVE_AUTOSTAGE=1
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
# Ephemeral test signing key + guest trust override
# ---------------------------------------------------------------------------
gpg --homedir "$WORK_DIR/gnupg" --batch --passphrase '' --quick-generate-key \
    'snosi native A/B updateux test <native-ab-updateux-test@invalid>' ed25519 sign 0
gpg --homedir "$WORK_DIR/gnupg" --batch --export > "$WORK_DIR/import-pubring.gpg"

# ---------------------------------------------------------------------------
# Origin override transfer files (byte-identical to the shipped channel
# transfers except [Source] Path=)
# ---------------------------------------------------------------------------
cat > "$WORK_DIR/overrides/10-root-verity.transfer" <<EOF
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
cat > "$WORK_DIR/overrides/20-root.transfer" <<EOF
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
cat > "$WORK_DIR/overrides/90-uki.transfer" <<EOF
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

# ---------------------------------------------------------------------------
# Publish N (the origin, at this point, promotes ONLY N -- matches the
# running system, so a check-new against it legitimately finds nothing
# newer).
# ---------------------------------------------------------------------------
publish_version "$BUILD_N_DIR"
mkdir -p "$WORK_DIR/source"
ln -s "$WORK_DIR/publish-out/$IMAGE_ID/x86-64" "$WORK_DIR/source/os"

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
vm_ssh 'systemctl is-system-running --wait' >/dev/null || true

vm_ssh 'mkdir -p /etc/sysupdate.d /etc/systemd'
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" \
    "$WORK_DIR/overrides/10-root-verity.transfer" \
    "$WORK_DIR/overrides/20-root.transfer" \
    "$WORK_DIR/overrides/90-uki.transfer" \
    root@localhost:/etc/sysupdate.d/
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" \
    "$WORK_DIR/import-pubring.gpg" root@localhost:/etc/systemd/import-pubring.gpg

# ===========================================================================
# Step 1: N boot -- no update activity, stager present but inert, "current"
# ===========================================================================
echo ""
echo "=== Step 1: N boot (publication-disabled) ==="

assert_no_update_activity

# Factory UKI naming (docs/native-ab-contracts.md §1, §6,
# shared/outformat/ab-root/mkosi.conf's UnifiedKernelImageFormat=&e):
# mkosi's build-time ESP UKI must be named "<channel>_<version>.efi" --
# exactly the channel transfer's Target MatchPattern -- so systemd-sysupdate
# sees the factory-installed version as already-installed the moment N
# boots, without ever running the stager. Before this was fixed, mkosi named
# it after &e-&k-&h (entry-token-kernelversion-roothash), which never
# matched, so sysupdate's installed-version accounting never saw the factory
# UKI and systemd-boot carried it forever as a third, unmanaged menu entry.
echo "ESP /EFI/Linux listing on N:"
esp_listing_n="$(vm_ssh 'ls -la /boot/EFI/Linux/')"
echo "$esp_listing_n"
assert_contains "factory ESP UKI is named <channel>_<version>.efi" \
    "$esp_listing_n" "${CHANNEL}_${n_version}.efi"

sysupdate_list_n="$(vm_ssh '/usr/lib/systemd/systemd-sysupdate list' 2>&1 || true)"
echo "$sysupdate_list_n"
assert_contains "systemd-sysupdate list sees the factory version N as installed" \
    "$sysupdate_list_n" "$n_version"

stage_status="$(vm_ssh 'systemctl is-enabled snosi-sysupdate-stage.timer' || true)"
assert_eq "snosi-sysupdate-stage.timer is-enabled=static (inert by default)" "$stage_status" "static"
assert_false "no timers.target.wants link for the stager timer on N" \
    vm_ssh 'test -e /usr/lib/systemd/system/timers.target.wants/snosi-sysupdate-stage.timer'
active_status="$(vm_ssh 'systemctl is-active snosi-sysupdate-stage.timer' || true)"
assert_eq "snosi-sysupdate-stage.timer is inactive on N" "$active_status" "inactive"

stager_out=""
stager_rc=0
stager_out="$(vm_ssh '/usr/libexec/snosi-sysupdate-stage' 2>&1)" || stager_rc=$?
echo "$stager_out"
assert_eq "manual stager run on N (nothing newer) exits 0" "$stager_rc" "0"

check_content="$(vm_ssh 'cat /run/snosi/update-check' 2>/dev/null || true)"
assert_contains "update-check reports outcome=current on N" "$check_content" "outcome=current"
assert_false "no reboot-pending semaphore on N" vm_ssh 'test -e /run/snosi/update-staged'

motd_out="$(vm_ssh 'run-parts /etc/update-motd.d 2>&1' || true)"
assert_contains "motd hook reports up to date on N" "$motd_out" "is up to date"

status_out="$(vm_ssh '/usr/bin/snosi-update-status' 2>&1 || true)"
echo "$status_out"
assert_contains "snosi-update-status reports the native channel on N" "$status_out" "$CHANNEL"
assert_contains "snosi-update-status reports up to date on N" "$status_out" "up to date"

# ===========================================================================
# Step 2: publish N+1, stage it manually
# ===========================================================================
echo ""
echo "=== Step 2: publish N+1 (publication-enabled build) and stage it ==="

publish_version "$BUILD_N1_DIR"

stager_out=""
stager_rc=0
stager_out="$(vm_ssh '/usr/libexec/snosi-sysupdate-stage' 2>&1)" || stager_rc=$?
echo "$stager_out"
assert_eq "manual stager run stages N+1" "$stager_rc" "0"
assert_contains "stager reports post-stage partition check" "$stager_out" "match the signed manifest"
assert_contains "stager reports post-stage UKI check" "$stager_out" "UKI present in ESP"

check_content="$(vm_ssh 'cat /run/snosi/update-check' 2>/dev/null || true)"
assert_contains "update-check reports outcome=staged" "$check_content" "outcome=staged"
sem_content="$(vm_ssh 'cat /run/snosi/update-staged' 2>/dev/null || true)"
echo "$sem_content"
assert_contains "semaphore records the staged version" "$sem_content" "version=$n1_version"
assert_contains "semaphore records the channel" "$sem_content" "image=$CHANNEL"

motd_out="$(vm_ssh 'run-parts /etc/update-motd.d 2>&1' || true)"
assert_contains "motd hook reports reboot-pending" "$motd_out" "staged"
assert_contains "motd hook includes the staged version" "$motd_out" "$n1_version"

status_out="$(vm_ssh '/usr/bin/snosi-update-status' 2>&1 || true)"
echo "$status_out"
assert_contains "snosi-update-status shows the staged version" "$status_out" "$n1_version"
assert_contains "snosi-update-status shows the staged UKI in the ESP" "$status_out" "UKI present in ESP"

assert_true "snosi-update-notify.path unit file present" \
    vm_ssh 'test -f /usr/lib/systemd/user/snosi-update-notify.path'
assert_true "snosi-update-notify.service unit file present" \
    vm_ssh 'test -f /usr/lib/systemd/user/snosi-update-notify.service'
assert_true "snosi-update-notify.path static wants link present" \
    vm_ssh 'test -L /usr/lib/systemd/user/graphical-session.target.wants/snosi-update-notify.path'

# Stubbed notify-send, run the shared notify script directly (no graphical
# session needed to exercise its logic -- see the header comment on why
# this is a legitimate unit-level check).
vm_ssh 'mkdir -p /var/tmp/fakebin'
vm_ssh "cat > /var/tmp/fakebin/notify-send" <<'FAKESCRIPT'
#!/bin/sh
echo "NOTIFY: $*" >> /var/tmp/notify.log
FAKESCRIPT
vm_ssh 'chmod +x /var/tmp/fakebin/notify-send'
vm_ssh 'rm -f /var/tmp/notify.log /root/.local/state/snosi/update-staged.ack'

vm_ssh 'PATH=/var/tmp/fakebin:$PATH HOME=/root /usr/libexec/bootc-update-notify'
first_notify="$(vm_ssh 'cat /var/tmp/notify.log 2>/dev/null || true')"
assert_contains "first notify run sends a notification" "$first_notify" "NOTIFY:"
assert_contains "notification body includes the staged version" "$first_notify" "$n1_version"

vm_ssh 'rm -f /var/tmp/notify.log'
vm_ssh 'PATH=/var/tmp/fakebin:$PATH HOME=/root /usr/libexec/bootc-update-notify'
second_notify="$(vm_ssh 'cat /var/tmp/notify.log 2>/dev/null || true')"
assert_eq "second notify run for the same version is ack-gated (no-op)" "$second_notify" ""

# ===========================================================================
# Step 3: reboot into N+1 -- static timer activation, semaphore cleared
# ===========================================================================
echo ""
echo "=== Step 3: reboot into N+1 ==="

reboot_guest
rebooted_version="$(guest_version)"
assert_eq "booted version is N+1 after reboot" "$rebooted_version" "$n1_version"
vm_ssh 'systemctl is-system-running --wait' >/dev/null || true

assert_false "reboot-pending semaphore is gone after the applying reboot" \
    vm_ssh 'test -e /run/snosi/update-staged'

wants_target="$(vm_ssh 'readlink -f /usr/lib/systemd/system/timers.target.wants/snosi-sysupdate-stage.timer' || true)"
assert_eq "the static wants link arrived with the N+1 image" "$wants_target" "/usr/lib/systemd/system/snosi-sysupdate-stage.timer"
active_status="$(vm_ssh 'systemctl is-active snosi-sysupdate-stage.timer' || true)"
assert_eq "snosi-sysupdate-stage.timer is ACTIVE on N+1 (Phase 4 exit criterion)" "$active_status" "active"

assert_no_update_activity

stager_out=""
stager_rc=0
stager_out="$(vm_ssh '/usr/libexec/snosi-sysupdate-stage' 2>&1)" || stager_rc=$?
echo "$stager_out"
assert_eq "manual stager run on N+1 (nothing newer) exits 0" "$stager_rc" "0"
check_content="$(vm_ssh 'cat /run/snosi/update-check' 2>/dev/null || true)"
assert_contains "update-check reports outcome=current on N+1" "$check_content" "outcome=current"

status_out="$(vm_ssh '/usr/bin/snosi-update-status' 2>&1 || true)"
echo "$status_out"
assert_contains "snosi-update-status shows N+1 running" "$status_out" "snosi $n1_version"
assert_contains "snosi-update-status agrees the system is current" "$status_out" "up to date"

# ===========================================================================
# Step 4: tamper case -- corrupted SHA256SUMS.gpg must fail closed
# ===========================================================================
echo ""
echo "=== Step 4: tampered signature fails closed ==="

# Fabricate a filename set claiming a version newer than N+1, hardlinked to
# N+1's own already-published (real, correctly hashed) bytes -- no 3rd mkosi
# build, and guarantees sysupdate actually attempts to trust the (about to
# be corrupted) index rather than silently no-opping as "nothing newer".
publish_dest="$WORK_DIR/publish-out/$IMAGE_ID/x86-64"
fake_version="$(printf '%014d' "$((n1_version + 1))")"
n1_root_real="$(find "$publish_dest" -maxdepth 1 -name "${CHANNEL}_${n1_version}_*.root.raw.xz")"
n1_verity_real="$(find "$publish_dest" -maxdepth 1 -name "${CHANNEL}_${n1_version}_*.root-verity.raw.xz")"
n1_efi_real="$publish_dest/${CHANNEL}_${n1_version}.efi"
root_uuid="$(basename "$n1_root_real" | sed -E "s/^${CHANNEL}_${n1_version}_([0-9a-fA-F-]+)\.root\.raw\.xz\$/\\1/")"
verity_uuid="$(basename "$n1_verity_real" | sed -E "s/^${CHANNEL}_${n1_version}_([0-9a-fA-F-]+)\.root-verity\.raw\.xz\$/\\1/")"
ln "$n1_root_real" "$publish_dest/${CHANNEL}_${fake_version}_${root_uuid}.root.raw.xz"
ln "$n1_verity_real" "$publish_dest/${CHANNEL}_${fake_version}_${verity_uuid}.root-verity.raw.xz"
ln "$n1_efi_real" "$publish_dest/${CHANNEL}_${fake_version}.efi"

: > "$publish_dest/SHA256SUMS"
for file in "$publish_dest"/*; do
    name="$(basename "$file")"
    [[ "$name" == SHA256SUMS || "$name" == SHA256SUMS.gpg || "$name" == publication-info.json ]] && continue
    hash="$(sha256sum "$file")"
    hash="${hash%% *}"
    printf '%s  %s\n' "$hash" "$name" >> "$publish_dest/SHA256SUMS"
done
sign_sums "$publish_dest"
# Corrupt the just-signed detached signature -- truncate the trailing bytes
# so the OpenPGP packet no longer parses/matches, rather than appending
# (which some parsers tolerate as trailing garbage after a valid packet).
sig_size="$(stat -c %s "$publish_dest/SHA256SUMS.gpg")"
head -c "$((sig_size > 10 ? sig_size - 10 : 0))" "$publish_dest/SHA256SUMS.gpg" > "$publish_dest/SHA256SUMS.gpg.tmp"
mv "$publish_dest/SHA256SUMS.gpg.tmp" "$publish_dest/SHA256SUMS.gpg"

stager_out=""
stager_rc=0
stager_out="$(vm_ssh '/usr/libexec/snosi-sysupdate-stage' 2>&1)" || stager_rc=$?
echo "$stager_out"
assert_true "stager exits non-zero on a tampered signature" bash -c "[[ $stager_rc -ne 0 ]]"

check_content="$(vm_ssh 'cat /run/snosi/update-check' 2>/dev/null || true)"
assert_contains "update-check reports outcome=failed on tampered signature" "$check_content" "outcome=failed"
assert_false "no semaphore appears from the failed (tampered) run" \
    vm_ssh 'test -e /run/snosi/update-staged'

final_layout="$(vm_ssh 'lsblk -J -o PARTLABEL' 2>/dev/null || echo "{}")"
fake_label_count="$(jq --arg l "${IMAGE_ID}_${fake_version}_r" \
    '[.. | objects | select(.partlabel? == $l)] | length' <<<"$final_layout")"
assert_eq "no partition labeled with the fabricated fake version exists" "$fake_label_count" "0"

final_version="$(guest_version)"
assert_eq "running version unchanged after the failed tamper case" "$final_version" "$n1_version"

echo ""
echo "Native A/B update UX test: N=$n_version -> N+1=$n1_version, tamper case rejected"
print_summary
