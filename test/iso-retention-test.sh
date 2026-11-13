#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Non-root regression test for shared/native-ab/publish/retention.sh
# (ADR-0036) and the two publish-lib.sh helpers it uses (dest_list_objects,
# dest_delete_listed). Builds a synthetic "isos/native/v1/" namespace in a
# local directory -- signed live index, six promoted installer ISOs, stale
# and fresh ".candidate/" scratch, ".history/" archived index pairs,
# historical "snosi-native-installer_*" media and one stray -- and checks
# that the dry run touches nothing, that --execute deletes exactly the
# objects outside the keep window, that the --max-delete cap refuses a
# larger plan, and that every fail-closed refusal (unverifiable index,
# multi-version index, index naming a missing object) leaves the namespace
# untouched.
#
# Signing: an EPHEMERAL ed25519 key generated in the test's own temp dir.
# Never production material.
#
# If rclone is on PATH, the main scenario is replayed through the rclone
# backend against an on-the-fly local remote (":local:<dir>"), so the
# production code path (lsf listing, --files-from-raw batch delete) runs
# without any network. Skipped, with a note, when rclone is absent.
#
# Usage: ./test/iso-retention-test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RETENTION="$ROOT_DIR/shared/native-ab/publish/retention.sh"
NS="isos/native/v1"

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

WORK_DIR="$(mktemp -d /var/tmp/iso-retention-test.XXXXXX)"

# --- ephemeral signing key ---------------------------------------------------
GNUPGHOME="$WORK_DIR/gnupghome"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
export GNUPGHOME
gpg --batch --passphrase '' --quick-generate-key 'iso-retention-test EPHEMERAL <ephemeral@invalid>' ed25519 sign 0 >/dev/null 2>&1
PUBRING="$WORK_DIR/pubring.gpg"
gpg --batch --export -o "$PUBRING"
[[ -s "$PUBRING" ]] || { echo "Error: failed to export ephemeral pubring" >&2; exit 1; }

# --- fixture builders --------------------------------------------------------
OLD_EPOCH="$(date -d '10 days ago' +%s)"

# write_object path content [old] -- old=1 (default) backdates mtime beyond
# any grace; old=0 leaves the object fresh.
write_object() {
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" >"$1"
    [[ "${3:-1}" == 0 ]] || touch -d "@$OLD_EPOCH" "$1"
}

iso_name() { echo "snosi-installer_${1}_x86-64.iso"; }

# index_for dir names... -- signed SHA256SUMS over the given object names
index_for() {
    local dir="$1" n
    shift
    : >"$dir/SHA256SUMS"
    for n in "$@"; do
        printf '%s  %s\n' "$(sha256sum "$dir/$n" | cut -d' ' -f1)" "$n" >>"$dir/SHA256SUMS"
    done
    gpg --batch --yes --detach-sign --digest-algo SHA512 -o "$dir/SHA256SUMS.gpg" "$dir/SHA256SUMS"
    touch -d "@$OLD_EPOCH" "$dir/SHA256SUMS" "$dir/SHA256SUMS.gpg"
}

# build_fixture root -- six promoted ISOs v1..v6, live = v6
V=(20260901000000 20260902000000 20260903000000 20260904000000 20260905000000 20260906000000)
build_fixture() {
    local dir="$1/$NS" v
    for v in "${V[@]}"; do write_object "$dir/$(iso_name "$v")" "iso $v"; done
    index_for "$dir" "$(iso_name "${V[5]}")"
    # .history: archived index pairs of v1..v5 (what promote.sh leaves)
    for v in "${V[@]:0:5}"; do
        write_object "$dir/.history/$v/SHA256SUMS" "index $v"
        write_object "$dir/.history/$v/SHA256SUMS.gpg" "sig $v"
    done
    # .candidate: a stale failed run, a fresh (in-flight) run, the live one
    write_object "$dir/.candidate/20260820000000/$(iso_name 20260820000000)" "stale candidate"
    write_object "$dir/.candidate/20260907000000/$(iso_name 20260907000000)" "fresh candidate" 0
    write_object "$dir/.candidate/${V[5]}/$(iso_name "${V[5]}")" "live candidate"
    # objects this script must never classify as its own payload
    write_object "$dir/snosi-native-installer_20260801000000_x86-64.iso" "historical media"
    write_object "$dir/snosi-installer_${V[0]}_x86-64.iso.sig" "near-miss name"
    write_object "$dir/README.txt" "stray"
    write_object "$dir/.history/notes/README" "non-version history dir"
    # an object outside the namespace
    write_object "$1/ext/demo/demo_1.raw" "sysext"
}

count_objects() { find "$1" -type f ! -name '*.meta.json' | wc -l; }
# no_objects_under path -- true iff no object remains under path (bucket
# backends have no directories, so only objects are the contract).
no_objects_under() { [[ ! -e "$1" ]] || [[ "$(count_objects "$1")" == 0 ]]; }

# --- main scenario -----------------------------------------------------------
# run_scenario label dest-arg root
run_scenario() {
    local label="$1" dest="$2" root="$3"
    local dir="$root/$NS" out before v rc

    echo "=== $label: dry run ==="
    before="$(count_objects "$root")"
    out="$("$RETENTION" --pubring "$PUBRING" "$dest" 2>&1)" || { fail "[$label] dry run exits 0" "$out"; return; }
    pass "[$label] dry run exits 0"
    assert_eq "[$label] dry run deletes nothing" "$(count_objects "$root")" "$before"
    assert_contains "[$label] dry run reports current version" "$out" "current version ${V[5]}"
    assert_contains "[$label] dry run keeps current + previous 2" "$out" "Keep versions: ${V[3]},${V[4]},${V[5]}"
    assert_contains "[$label] dry run lists stale candidate for deletion" "$out" ".candidate/20260820000000/"
    assert_contains "[$label] dry run reports unclassified objects" "$out" "unclassified"
    assert_contains "[$label] dry run counts 10 deletions" "$out" "To delete: 10 object(s)"

    echo "=== $label: --max-delete refuses a larger plan ==="
    rc=0
    out="$("$RETENTION" --pubring "$PUBRING" --execute --max-delete 9 "$dest" 2>&1)" || rc=$?
    assert_eq "[$label] over-cap plan exits 3" "$rc" "3"
    assert_contains "[$label] over-cap plan says why" "$out" "more than --max-delete 9"
    assert_eq "[$label] over-cap plan deletes nothing" "$(count_objects "$root")" "$before"

    echo "=== $label: execute ==="
    out="$("$RETENTION" --pubring "$PUBRING" --execute --max-delete 10 "$dest" 2>&1)" || { fail "[$label] execute exits 0" "$out"; return; }
    pass "[$label] execute exits 0"
    assert_eq "[$label] exactly 10 objects deleted" "$(count_objects "$root")" "$((before - 10))"
    assert_true "[$label] live index untouched" test -f "$dir/SHA256SUMS" -a -f "$dir/SHA256SUMS.gpg"
    assert_true "[$label] gpgv still accepts the live index" gpgv --keyring "$PUBRING" "$dir/SHA256SUMS.gpg" "$dir/SHA256SUMS"
    for v in "${V[@]:3}"; do
        assert_true "[$label] kept ISO $v present" test -f "$dir/$(iso_name "$v")"
    done
    for v in "${V[@]:0:3}"; do
        assert_false "[$label] pruned ISO $v gone" test -e "$dir/$(iso_name "$v")"
        assert_true "[$label] history of pruned $v gone" no_objects_under "$dir/.history/$v"
    done
    assert_true "[$label] history of kept v4 present" test -f "$dir/.history/${V[3]}/SHA256SUMS"
    assert_true "[$label] stale candidate gone" no_objects_under "$dir/.candidate/20260820000000"
    assert_true "[$label] fresh (in-flight) candidate kept" test -f "$dir/.candidate/20260907000000/$(iso_name 20260907000000)"
    assert_true "[$label] live version's candidate kept" test -f "$dir/.candidate/${V[5]}/$(iso_name "${V[5]}")"
    assert_true "[$label] historical native-installer media kept" test -f "$dir/snosi-native-installer_20260801000000_x86-64.iso"
    assert_true "[$label] near-miss name kept" test -f "$dir/snosi-installer_${V[0]}_x86-64.iso.sig"
    assert_true "[$label] stray kept" test -f "$dir/README.txt"
    assert_true "[$label] non-version history dir kept" test -f "$dir/.history/notes/README"
    assert_true "[$label] object outside the namespace kept" test -f "$root/ext/demo/demo_1.raw"

    echo "=== $label: second execute is a no-op ==="
    out="$("$RETENTION" --pubring "$PUBRING" --execute "$dest" 2>&1)" || { fail "[$label] re-run exits 0" "$out"; return; }
    assert_contains "[$label] re-run finds nothing to delete" "$out" "Nothing to delete."
}

# --- fail-closed refusals (local dest only; the logic is backend-agnostic) ---
# refused description expected-text root -- run --execute, expect failure
refused() {
    local desc="$1" want="$2" root="$3" out before
    before="$(count_objects "$root")"
    if out="$("$RETENTION" --pubring "$PUBRING" --execute "$root" 2>&1)"; then
        fail "$desc is refused" "$out"
    else
        pass "$desc is refused"
    fi
    [[ -z "$want" ]] || assert_contains "$desc: message" "$out" "$want"
    assert_eq "$desc: nothing deleted" "$(count_objects "$root")" "$before"
}

run_refusals() {
    local root="$WORK_DIR/refuse" dir out
    dir="$root/$NS"

    echo "=== refusal: tampered index ==="
    rm -rf "$root"; build_fixture "$root"
    printf 'x' >>"$dir/SHA256SUMS"
    refused "tampered index" "does not verify" "$root"

    echo "=== refusal: index names a missing object ==="
    rm -rf "$root"; build_fixture "$root"
    rm -f "$dir/$(iso_name "${V[5]}")"
    refused "missing indexed object" "no such object exists" "$root"

    echo "=== refusal: index advertises two versions ==="
    rm -rf "$root"; build_fixture "$root"
    index_for "$dir" "$(iso_name "${V[5]}")" "$(iso_name "${V[4]}")"
    refused "multi-version index" "exactly one version" "$root"

    echo "=== refusal: index names no installer ISO ==="
    rm -rf "$root"; build_fixture "$root"
    index_for "$dir" "README.txt"
    refused "index without an installer ISO" "exactly one version" "$root"

    echo "=== refusal: no live index ==="
    rm -rf "$root"; build_fixture "$root"
    rm -f "$dir/SHA256SUMS" "$dir/SHA256SUMS.gpg"
    refused "missing live index" "" "$root"

    echo "=== newer-than-live version (in-flight promotion) is kept ==="
    rm -rf "$root"; build_fixture "$root"
    write_object "$dir/$(iso_name 20260909000000)" "newer iso"
    out="$("$RETENTION" --pubring "$PUBRING" --execute "$root" 2>&1)" || fail "newer version run exits 0" "$out"
    assert_contains "newer version is reported" "$out" "newer than the live index"
    assert_true "newer version kept" test -f "$dir/$(iso_name 20260909000000)"
    assert_contains "newer version does not consume the keep window" "$out" "Keep versions: ${V[3]},${V[4]},${V[5]},20260909000000"
    assert_false "older versions still pruned alongside" test -e "$dir/$(iso_name "${V[0]}")"

    echo "=== grace protects a fresh ISO outside the keep window ==="
    rm -rf "$root"; build_fixture "$root"
    touch "$dir/$(iso_name "${V[0]}")"
    out="$("$RETENTION" --pubring "$PUBRING" --execute "$root" 2>&1)" || fail "grace run exits 0" "$out"
    assert_true "fresh old-versioned ISO kept" test -f "$dir/$(iso_name "${V[0]}")"
    assert_false "aged ISO outside the window pruned" test -e "$dir/$(iso_name "${V[1]}")"

    echo "=== --keep-previous 0 keeps only current ==="
    rm -rf "$root"; build_fixture "$root"
    out="$("$RETENTION" --pubring "$PUBRING" --keep-previous 0 --execute "$root" 2>&1)" || fail "keep-previous 0 exits 0" "$out"
    assert_contains "keep-previous 0 keeps current only" "$out" "Keep versions: ${V[5]}"
    assert_false "keep-previous 0 pruned v5" test -e "$dir/$(iso_name "${V[4]}")"
    assert_true "keep-previous 0 kept current" test -f "$dir/$(iso_name "${V[5]}")"
}

# --- run ---------------------------------------------------------------------
LOCAL_ROOT="$WORK_DIR/local"
build_fixture "$LOCAL_ROOT"
run_scenario "local dest" "$LOCAL_ROOT" "$LOCAL_ROOT"

run_refusals

if command -v rclone >/dev/null && rclone version >/dev/null 2>&1; then
    RCLONE_ROOT="$WORK_DIR/rclone"
    build_fixture "$RCLONE_ROOT"
    # publish-lib passes everything after "rclone:" verbatim as rclone's
    # "<remote>:<path>"; ":local:" is rclone's on-the-fly local backend.
    run_scenario "rclone dest" "rclone::local:$RCLONE_ROOT" "$RCLONE_ROOT"
else
    echo "# rclone not usable: rclone-backend replay skipped (local-dest coverage above is complete)"
fi

echo ""
echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
exit "$FAIL"
