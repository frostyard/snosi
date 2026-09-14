#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Static, non-root regression test for shared/native-ab/publish/retention.sh
# (docs/native-ab-contracts.md §13 "Retention") plus the two publish-lib.sh
# helpers it introduced (dest_list_objects, dest_delete_listed). Builds a
# synthetic publication namespace in a local directory dest -- signed live
# index, six promoted versions, stale and fresh ".candidate/" scratch,
# ".history/" archived pairs, one unclassifiable stray -- and checks that the
# dry run touches nothing, that --execute deletes exactly the objects outside
# the keep window, and that every fail-closed refusal (unverifiable index,
# multi-version index, index naming a missing object) leaves the namespace
# untouched. Also drives the flat ISO namespace shape (--dest-path, both the
# current "snosi-installer_" and the legacy "snosi-native-installer_" names).
#
# Signing: an EPHEMERAL ed25519 key generated in the test's own temp dir,
# exactly like test/native-publication-pipeline-test.sh's fresh-checkout
# mode. Never production material.
#
# If rclone is on PATH, the same scenario is replayed once more through the
# rclone backend against an on-the-fly local remote (":local:<dir>"), so the
# production code path (lsf listing, --files-from-raw batch delete) is
# exercised without any network. Skipped, with a note, when rclone is absent.
#
# Usage: ./test/native-ab-retention-test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RETENTION="$ROOT_DIR/shared/native-ab/publish/retention.sh"

WORK_DIR=""
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; [[ $# -lt 2 ]] || echo "  $2" >&2; FAIL=$((FAIL + 1)); }
assert_true() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d" "command failed: $*"; fi; }
assert_false() { local d="$1"; shift; if "$@"; then fail "$d" "command unexpectedly succeeded: $*"; else pass "$d"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to find: $3 -- got: $2"; fi; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

cleanup() { [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf "$WORK_DIR"; }
trap cleanup EXIT

for command in gpg gpgv sha256sum find awk cmp; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done

WORK_DIR="$(mktemp -d /var/tmp/native-ab-retention-test.XXXXXX)"

# --- ephemeral signing key ---------------------------------------------------
GNUPGHOME="$WORK_DIR/gnupghome"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
export GNUPGHOME
gpg --batch --passphrase '' --quick-generate-key 'retention-test EPHEMERAL <ephemeral@invalid>' ed25519 sign 0 >/dev/null 2>&1
PUBRING="$WORK_DIR/pubring.gpg"
gpg --batch --export -o "$PUBRING"
[[ -s "$PUBRING" ]] || { echo "Error: failed to export ephemeral pubring" >&2; exit 1; }

# --- fixture builders --------------------------------------------------------
OLD_EPOCH="$(date -d '10 days ago' +%s)"

# write_object path content [old] -- old=1 backdates mtime beyond any grace.
write_object() {
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" >"$1"
    [[ "${3:-1}" == 0 ]] || touch -d "@$OLD_EPOCH" "$1"
}

# sign_index dir -- writes dir/SHA256SUMS.gpg for dir/SHA256SUMS
sign_index() {
    gpg --batch --yes --detach-sign --digest-algo SHA512 -o "$1/SHA256SUMS.gpg" "$1/SHA256SUMS"
    touch -d "@$OLD_EPOCH" "$1/SHA256SUMS" "$1/SHA256SUMS.gpg"
}

# os_version_objects dir channel version -- the seven §4 objects of one build
os_version_objects() {
    local dir="$1" ch="$2" v="$3" n
    for n in "${ch}_${v}_aaaaaaaa-0000-0000-0000-000000000001.root.raw.xz" \
             "${ch}_${v}_bbbbbbbb-0000-0000-0000-000000000002.root-verity.raw.xz" \
             "${ch}_${v}.disk.raw.xz" "${ch}_${v}.efi" "${ch}_${v}.manifest.json" \
             "${ch}_${v}.sbom.spdx.json" "${ch}_${v}.features.json"; do
        write_object "$dir/$n" "payload $n"
    done
}

# index_for dir names... -- SHA256SUMS over the given object names, signed
index_for() {
    local dir="$1"; shift
    : >"$dir/SHA256SUMS"
    local n
    for n in "$@"; do
        printf '%s  %s\n' "$(sha256sum "$dir/$n" | cut -d' ' -f1)" "$n" >>"$dir/SHA256SUMS"
    done
    sign_index "$dir"
}

# build_os_fixture dest product -- six promoted versions v1..v6, live = v6
V=(20260901000000 20260902000000 20260903000000 20260904000000 20260905000000 20260906000000)
build_os_fixture() {
    local dir="$1/os/native/v1/$2/x86-64" ch="$2-ab" v
    for v in "${V[@]}"; do os_version_objects "$dir" "$ch" "$v"; done
    index_for "$dir" "${ch}_${V[5]}.disk.raw.xz" "${ch}_${V[5]}.efi" \
        "${ch}_${V[5]}_aaaaaaaa-0000-0000-0000-000000000001.root.raw.xz" \
        "${ch}_${V[5]}_bbbbbbbb-0000-0000-0000-000000000002.root-verity.raw.xz" \
        "${ch}_${V[5]}.manifest.json" "${ch}_${V[5]}.sbom.spdx.json" "${ch}_${V[5]}.features.json"
    # .history: archived index pairs of v1..v5 (what promote.sh leaves)
    for v in "${V[@]:0:5}"; do
        write_object "$dir/.history/$v/SHA256SUMS" "index $v"
        write_object "$dir/.history/$v/SHA256SUMS.gpg" "sig $v"
    done
    # .candidate: a stale failed run, a fresh (in-flight) run, and the live one
    write_object "$dir/.candidate/20260820000000/${ch}_20260820000000.disk.raw.xz" "stale candidate"
    write_object "$dir/.candidate/20260907000000/${ch}_20260907000000.disk.raw.xz" "fresh candidate" 0
    write_object "$dir/.candidate/${V[5]}/${ch}_${V[5]}.disk.raw.xz" "live candidate"
    # a stray this script must not understand
    write_object "$dir/README.txt" "stray"
    # a fresh top-level object of an old version (grace must protect it)
    write_object "$dir/${ch}_${V[0]}.extra.json" "fresh but old-versioned" 0
}

# build_iso_fixture dest -- flat namespace, current + legacy naming
build_iso_fixture() {
    local dir="$1/isos/native/v1" v
    for v in 20260801000000 20260802000000; do
        write_object "$dir/snosi-native-installer_${v}_x86-64.iso" "legacy iso $v"
    done
    for v in 20260803000000 20260804000000 20260805000000; do
        write_object "$dir/snosi-installer_${v}_x86-64.iso" "iso $v"
    done
    index_for "$dir" "snosi-installer_20260805000000_x86-64.iso"
    write_object "$dir/.candidate/20260720000000/snosi-installer_20260720000000_x86-64.iso" "stale iso candidate"
    write_object "$dir/.history/20260801000000/SHA256SUMS" "index"
    write_object "$dir/.history/20260801000000/SHA256SUMS.gpg" "sig"
}

count_objects() { find "$1" -type f ! -name '*.meta.json' | wc -l; }
# no_objects_under path -- true iff no object remains under path (an empty
# directory left behind by a directory-shaped backend does not count: bucket
# backends have no directories at all, so only objects are the contract).
no_objects_under() { [[ ! -e "$1" ]] || [[ "$(count_objects "$1")" == 0 ]]; }

# --- scenario runner ---------------------------------------------------------
# run_scenario label dest-arg-for-os dest-arg-for-iso dest-dir
run_scenario() {
    local label="$1" dest_os="$2" dest_iso="$3" root="$4"
    local dir="$root/os/native/v1/floe/x86-64" ch="floe-ab" out before after

    echo "=== $label: dry run ==="
    before="$(count_objects "$root")"
    out="$("$RETENTION" --pubring "$PUBRING" floe "$dest_os" 2>&1)" || { fail "[$label] dry run exits 0" "$out"; return; }
    pass "[$label] dry run exits 0"
    after="$(count_objects "$root")"
    assert_eq "[$label] dry run deletes nothing" "$after" "$before"
    assert_contains "[$label] dry run reports current version" "$out" "current version ${V[5]}"
    assert_contains "[$label] dry run keeps current + previous 2" "$out" "Keep versions: ${V[3]},${V[4]},${V[5]}"
    assert_contains "[$label] dry run lists stale candidate for deletion" "$out" ".candidate/20260820000000/"
    assert_contains "[$label] dry run reports the stray as unclassified" "$out" "unclassified"

    echo "=== $label: execute ==="
    out="$("$RETENTION" --pubring "$PUBRING" --execute floe "$dest_os" 2>&1)" || { fail "[$label] execute exits 0" "$out"; return; }
    pass "[$label] execute exits 0"
    assert_true "[$label] live index untouched" test -f "$dir/SHA256SUMS" -a -f "$dir/SHA256SUMS.gpg"
    assert_true "[$label] gpgv still accepts the live index" gpgv --keyring "$PUBRING" "$dir/SHA256SUMS.gpg" "$dir/SHA256SUMS"
    local v
    for v in "${V[@]:3}"; do
        assert_true "[$label] kept version $v payload present" test -f "$dir/${ch}_${v}.disk.raw.xz"
    done
    for v in "${V[@]:0:3}"; do
        assert_false "[$label] pruned version $v payload gone" test -e "$dir/${ch}_${v}.disk.raw.xz"
        assert_false "[$label] pruned version $v root gone" test -e "$dir/${ch}_${v}_aaaaaaaa-0000-0000-0000-000000000001.root.raw.xz"
    done
    assert_true "[$label] history of kept v4 present" test -f "$dir/.history/${V[3]}/SHA256SUMS"
    assert_false "[$label] history of pruned v1 gone" test -e "$dir/.history/${V[0]}/SHA256SUMS.gpg"
    assert_true "[$label] stale candidate gone" no_objects_under "$dir/.candidate/20260820000000"
    assert_true "[$label] fresh (in-flight) candidate kept" test -f "$dir/.candidate/20260907000000/${ch}_20260907000000.disk.raw.xz"
    assert_true "[$label] live version's candidate kept" test -f "$dir/.candidate/${V[5]}/${ch}_${V[5]}.disk.raw.xz"
    assert_true "[$label] unclassified stray kept" test -f "$dir/README.txt"
    assert_true "[$label] grace protects a fresh object of an old version" test -f "$dir/${ch}_${V[0]}.extra.json"
    assert_false "[$label] no .meta.json sidecar orphaned" bash -c "find '$dir' -name '*.meta.json' | grep -q ."

    echo "=== $label: second execute is a no-op ==="
    out="$("$RETENTION" --pubring "$PUBRING" --execute floe "$dest_os" 2>&1)" || { fail "[$label] re-run exits 0" "$out"; return; }
    assert_contains "[$label] re-run finds nothing to delete" "$out" "Nothing to delete."

    echo "=== $label: ISO namespace ==="
    local idir="$root/isos/native/v1"
    out="$("$RETENTION" --pubring "$PUBRING" --dest-path isos/native/v1 --execute native-installer "$dest_iso" 2>&1)" || { fail "[$label] iso execute exits 0" "$out"; return; }
    pass "[$label] iso execute exits 0"
    assert_contains "[$label] iso keep set spans legacy and current names" "$out" "Keep versions: 20260803000000,20260804000000,20260805000000"
    assert_true "[$label] iso current kept" test -f "$idir/snosi-installer_20260805000000_x86-64.iso"
    assert_true "[$label] iso previous-2 kept" test -f "$idir/snosi-installer_20260803000000_x86-64.iso"
    assert_false "[$label] legacy-named iso outside window gone" test -e "$idir/snosi-native-installer_20260801000000_x86-64.iso"
    assert_false "[$label] legacy-named iso outside window gone (2)" test -e "$idir/snosi-native-installer_20260802000000_x86-64.iso"
    assert_true "[$label] iso stale candidate gone" no_objects_under "$idir/.candidate/20260720000000"
    assert_true "[$label] iso history of pruned version gone" no_objects_under "$idir/.history/20260801000000"
}

# --- fail-closed refusals (local dest only; the logic is backend-agnostic) ---
run_refusals() {
    local root="$WORK_DIR/refuse" dir out before after
    dir="$root/os/native/v1/floe/x86-64"

    echo "=== refusal: tampered signature ==="
    rm -rf "$root"; build_os_fixture "$root" floe
    printf 'x' >>"$dir/SHA256SUMS"
    before="$(count_objects "$root")"
    out="$("$RETENTION" --pubring "$PUBRING" --execute floe "$root" 2>&1)" && fail "tampered index is refused" "$out" || pass "tampered index is refused"
    assert_contains "tampered index names gpgv" "$out" "does not verify"
    assert_eq "tampered index: nothing deleted" "$(count_objects "$root")" "$before"

    echo "=== refusal: index names a missing object ==="
    rm -rf "$root"; build_os_fixture "$root" floe
    rm -f "$dir/floe-ab_${V[5]}.efi"
    before="$(count_objects "$root")"
    out="$("$RETENTION" --pubring "$PUBRING" --execute floe "$root" 2>&1)" && fail "missing indexed object is refused" "$out" || pass "missing indexed object is refused"
    assert_contains "missing indexed object is named" "$out" "no such object exists"
    assert_eq "missing indexed object: nothing deleted" "$(count_objects "$root")" "$before"

    echo "=== refusal: index advertises two versions ==="
    rm -rf "$root"; build_os_fixture "$root" floe
    index_for "$dir" "floe-ab_${V[5]}.disk.raw.xz" "floe-ab_${V[4]}.disk.raw.xz"
    before="$(count_objects "$root")"
    out="$("$RETENTION" --pubring "$PUBRING" --execute floe "$root" 2>&1)" && fail "multi-version index is refused" "$out" || pass "multi-version index is refused"
    assert_contains "multi-version index reports both versions" "$out" "exactly one version"
    assert_eq "multi-version index: nothing deleted" "$(count_objects "$root")" "$before"

    echo "=== refusal: no live index ==="
    rm -rf "$root"; build_os_fixture "$root" floe
    rm -f "$dir/SHA256SUMS" "$dir/SHA256SUMS.gpg"
    before="$(count_objects "$root")"
    out="$("$RETENTION" --pubring "$PUBRING" --execute floe "$root" 2>&1)" && fail "missing live index is refused" "$out" || pass "missing live index is refused"
    assert_eq "missing live index: nothing deleted" "$(count_objects "$root")" "$before"

    echo "=== newer-than-live version (withdrawal / in-flight promotion) is kept ==="
    rm -rf "$root"; build_os_fixture "$root" floe
    os_version_objects "$dir" floe-ab 20260909000000
    out="$("$RETENTION" --pubring "$PUBRING" --execute floe "$root" 2>&1)" || fail "newer version run exits 0" "$out"
    assert_contains "newer version is reported" "$out" "newer than the live index"
    assert_true "newer version payload kept" test -f "$dir/floe-ab_20260909000000.disk.raw.xz"
    assert_contains "newer version does not consume the keep window" "$out" "Keep versions: ${V[3]},${V[4]},${V[5]},20260909000000"
    assert_false "older versions still pruned alongside" test -e "$dir/floe-ab_${V[0]}.disk.raw.xz"

    echo "=== --keep-previous 0 keeps only current ==="
    rm -rf "$root"; build_os_fixture "$root" floe
    out="$("$RETENTION" --pubring "$PUBRING" --keep-previous 0 --execute floe "$root" 2>&1)" || fail "keep-previous 0 exits 0" "$out"
    assert_contains "keep-previous 0 keeps current only" "$out" "Keep versions: ${V[5]}"
    assert_false "keep-previous 0 pruned v5" test -e "$dir/floe-ab_${V[4]}.disk.raw.xz"
    assert_true "keep-previous 0 kept current" test -f "$dir/floe-ab_${V[5]}.disk.raw.xz"
}

# --- run ---------------------------------------------------------------------
LOCAL_ROOT="$WORK_DIR/local"
build_os_fixture "$LOCAL_ROOT" floe
build_iso_fixture "$LOCAL_ROOT"
run_scenario "local dest" "$LOCAL_ROOT" "$LOCAL_ROOT" "$LOCAL_ROOT"

run_refusals

if command -v rclone >/dev/null; then
    RCLONE_ROOT="$WORK_DIR/rclone"
    build_os_fixture "$RCLONE_ROOT" floe
    build_iso_fixture "$RCLONE_ROOT"
    # publish-lib passes everything after "rclone:" verbatim as rclone's
    # "<remote>:<path>"; ":local:" is rclone's on-the-fly local backend.
    run_scenario "rclone dest" "rclone::local:$RCLONE_ROOT" "rclone::local:$RCLONE_ROOT" "$RCLONE_ROOT"
else
    echo "# rclone not installed: rclone-backend replay skipped (local-dest coverage above is complete)"
fi

echo ""
echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
exit "$FAIL"
