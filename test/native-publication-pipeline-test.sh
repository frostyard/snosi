#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Static, non-root regression test for the Phase 7 publication/signing
# pipeline (shared/native-ab/publish/{publish-candidate,verify-remote,
# promote,withdraw}.sh + publish-lib.sh + generate-sbom.sh). Companion to
# test/native-publish-test.sh (which covers prepare-native-publication.sh
# alone): this test builds a synthetic, tiny fixture the same way (fake GPT
# via `truncate` + `sfdisk` script mode, no loop device, no root) and drives
# it through the FULL candidate -> verify -> promote -> withdraw lifecycle
# against a local directory `dest` and a local, real HTTP origin
# (test/lib/range-http-server.py -- see its header for why not plain
# `python3 -m http.server`). Uses the committed DEV signing key
# (.snosi-private/os-update-signing.key) and the committed DEV pubring
# (shared/native-ab/keys/import-pubring.gpg) -- both dev-only, never
# production material.
#
# The full real-build QEMU rehearsal (real cayo-ab-raw images, a live
# guest verifying against the stock shipped pubring, tamper cases at the
# systemd-sysupdate layer) is test/native-ab-publication-test.sh; that one
# needs root/KVM/tens of minutes and is intentionally NOT wired into
# validate.yml, matching every other QEMU harness in this repo. This script
# is fast (seconds) and safe for every PR.
#
# Usage: ./test/native-publication-pipeline-test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISH_DIR="$ROOT_DIR/shared/native-ab/publish"
SIGNING_KEY="$ROOT_DIR/.snosi-private/os-update-signing.key"
PUBRING="$ROOT_DIR/shared/native-ab/keys/import-pubring.gpg"

WORK_DIR=""
HTTP_PID=""
PORT=0
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
    [[ -z "$HTTP_PID" ]] || kill "$HTTP_PID" 2>/dev/null || true
    [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for command in jq python3 sfdisk sha256sum git xz gpg gpgv curl; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done
[[ -s "$SIGNING_KEY" ]] || { echo "Error: DEV signing key not found: $SIGNING_KEY" >&2; exit 1; }
[[ -s "$PUBRING" ]] || { echo "Error: DEV pubring not found: $PUBRING" >&2; exit 1; }

WORK_DIR="$(mktemp -d /var/tmp/native-publication-pipeline-test.XXXXXX)"

# build_fixture dir product profile-output-name version -- same synthetic
# fixture as test/native-publish-test.sh.
build_fixture() {
    local dir="$1" product="$2" profile_output_name="$3" version="$4"
    mkdir -p "$dir"

    python3 - "$dir/$profile_output_name.manifest" "$product" "$version" <<'PYEOF'
import json, sys
path, product, version = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({"config": {"name": product, "version": version},
           "packages": [{"type": "deb", "name": "bash", "version": "5.2-1", "architecture": "amd64"}]},
          open(path, "w"))
PYEOF
    printf 'root payload %s\n' "$version" >"$dir/$profile_output_name.${product}_@v.root.raw.raw"
    printf 'verity payload %s\n' "$version" >"$dir/$profile_output_name.${product}_@v.root-verity.raw.raw"
    printf 'efi payload %s\n' "$version" >"$dir/$profile_output_name.efi"
    truncate -s 2M "$dir/$profile_output_name.raw"

    cat >"$dir/sfdisk-script.txt" <<EOF
label: gpt
unit: sectors

start=34, size=100, type=L, name="${product}_${version}_r"
start=200, size=100, type=L, name="${product}_${version}_v"
EOF
    sfdisk "$dir/$profile_output_name.raw" <"$dir/sfdisk-script.txt" >/dev/null
}

PRODUCT=cayo
CHANNEL=cayo-ab
VERSION1=20260101000000
VERSION2=20260102000000

build_fixture "$WORK_DIR/mkosi-out-1" "$PRODUCT" "$CHANNEL" "$VERSION1"
build_fixture "$WORK_DIR/mkosi-out-2" "$PRODUCT" "$CHANNEL" "$VERSION2"

"$PUBLISH_DIR/prepare-native-publication.sh" "$WORK_DIR/mkosi-out-1" "$CHANNEL" "$WORK_DIR/publish-out-1" >/dev/null
"$PUBLISH_DIR/prepare-native-publication.sh" "$WORK_DIR/mkosi-out-2" "$CHANNEL" "$WORK_DIR/publish-out-2" >/dev/null
PREPARED1="$WORK_DIR/publish-out-1/$PRODUCT/x86-64"
PREPARED2="$WORK_DIR/publish-out-2/$PRODUCT/x86-64"
assert_true "prepare-native-publication.sh generated a real sbom.spdx.json (v1)" \
    test -f "$PREPARED1/${CHANNEL}_${VERSION1}.sbom.spdx.json"
assert_true "generated sbom.spdx.json is valid JSON with >=1 package" \
    bash -c "[[ \$(jq '.packages | length' '$PREPARED1/${CHANNEL}_${VERSION1}.sbom.spdx.json') -ge 1 ]]"

DEST="$WORK_DIR/origin"
mkdir -p "$DEST"
PORT=18923
python3 "$ROOT_DIR/test/lib/range-http-server.py" "$PORT" "$DEST" >"$WORK_DIR/http.log" 2>&1 &
HTTP_PID=$!
sleep 1
kill -0 "$HTTP_PID" 2>/dev/null || { echo "Error: range HTTP server failed to start" >&2; cat "$WORK_DIR/http.log" >&2; exit 1; }
BASE_URL="http://127.0.0.1:${PORT}/os/native/v1/${PRODUCT}/x86-64"

echo "=== publish-candidate.sh ==="
"$PUBLISH_DIR/publish-candidate.sh" "$PREPARED1" "$DEST"
assert_true "candidate objects landed under .candidate/$VERSION1/" \
    test -f "$DEST/os/native/v1/$PRODUCT/x86-64/.candidate/$VERSION1/${CHANNEL}_${VERSION1}.efi"
assert_contains "candidate payload sidecar records immutable Cache-Control" \
    "$(cat "$DEST/os/native/v1/$PRODUCT/x86-64/.candidate/$VERSION1/${CHANNEL}_${VERSION1}.efi.meta.json")" \
    "immutable"

echo "=== verify-remote.sh: tamper then clean ==="
efi_candidate="$DEST/os/native/v1/$PRODUCT/x86-64/.candidate/$VERSION1/${CHANNEL}_${VERSION1}.efi"
printf 'X' | dd of="$efi_candidate" bs=1 seek=0 count=1 conv=notrunc status=none
assert_false "verify-remote.sh fails closed on a corrupted candidate byte" \
    "$PUBLISH_DIR/verify-remote.sh" "$PREPARED1" "$BASE_URL"
"$PUBLISH_DIR/publish-candidate.sh" "$PREPARED1" "$DEST" >/dev/null
assert_true "verify-remote.sh clean pass" "$PUBLISH_DIR/verify-remote.sh" "$PREPARED1" "$BASE_URL"

echo "=== promote.sh: ordering, sidecars, gpgv ==="
"$PUBLISH_DIR/promote.sh" --signing-key "$SIGNING_KEY" "$PREPARED1" "$BASE_URL" "$DEST"
product_dir="$DEST/os/native/v1/$PRODUCT/x86-64"
assert_true "final SHA256SUMS.gpg exists" test -f "$product_dir/SHA256SUMS.gpg"
assert_true "final SHA256SUMS exists" test -f "$product_dir/SHA256SUMS"
gpg_mtime="$(stat -c %y "$product_dir/SHA256SUMS.gpg")"
sums_mtime="$(stat -c %y "$product_dir/SHA256SUMS")"
assert_true "SHA256SUMS.gpg written no later than SHA256SUMS" \
    bash -c "[[ '$gpg_mtime' < '$sums_mtime' || '$gpg_mtime' == '$sums_mtime' ]]"
assert_contains "SHA256SUMS.gpg sidecar is no-store" \
    "$(cat "$product_dir/SHA256SUMS.gpg.meta.json")" "no-store"
assert_contains "SHA256SUMS sidecar is no-store" \
    "$(cat "$product_dir/SHA256SUMS.meta.json")" "no-store"
assert_true "gpgv accepts the promoted index against the committed DEV pubring" \
    gpgv --keyring "$PUBRING" "$product_dir/SHA256SUMS.gpg" "$product_dir/SHA256SUMS"

echo "=== a second promotion archives the outgoing pair ==="
"$PUBLISH_DIR/publish-candidate.sh" "$PREPARED2" "$DEST" >/dev/null
"$PUBLISH_DIR/verify-remote.sh" "$PREPARED2" "$BASE_URL" >/dev/null
"$PUBLISH_DIR/promote.sh" --signing-key "$SIGNING_KEY" "$PREPARED2" "$BASE_URL" "$DEST" >/dev/null
assert_true "v1's signed index was archived to .history/$VERSION1/" \
    test -f "$product_dir/.history/$VERSION1/SHA256SUMS.gpg"
assert_contains "current index now advertises v2" \
    "$(cat "$product_dir/SHA256SUMS")" "${CHANNEL}_${VERSION2}.manifest.json"

echo "=== withdraw.sh ==="
"$PUBLISH_DIR/withdraw.sh" --pubring "$PUBRING" "$PRODUCT" "$VERSION1" "$DEST"
assert_contains "current index advertises v1 again after withdrawal" \
    "$(cat "$product_dir/SHA256SUMS")" "${CHANNEL}_${VERSION1}.manifest.json"
assert_true "gpgv accepts the withdrawn (restored) index" \
    gpgv --keyring "$PUBRING" "$product_dir/SHA256SUMS.gpg" "$product_dir/SHA256SUMS"

assert_false "withdraw.sh refuses a version with no archived pair" \
    "$PUBLISH_DIR/withdraw.sh" --pubring "$PUBRING" "$PRODUCT" 20261231235959 "$DEST"

cp "$product_dir/.history/$VERSION1/SHA256SUMS.gpg" "$WORK_DIR/sig.bak"
printf 'X' | dd of="$product_dir/.history/$VERSION1/SHA256SUMS.gpg" bs=1 seek=0 count=1 conv=notrunc status=none
assert_false "withdraw.sh refuses a tampered archived pair" \
    "$PUBLISH_DIR/withdraw.sh" --pubring "$PUBRING" "$PRODUCT" "$VERSION1" "$DEST"
cp "$WORK_DIR/sig.bak" "$product_dir/.history/$VERSION1/SHA256SUMS.gpg"

echo "=== wrong-key signing is mechanically possible but gpgv rejects it ==="
WRONG_GNUPGHOME="$WORK_DIR/wrong-gnupghome"
mkdir -p "$WRONG_GNUPGHOME"
chmod 700 "$WRONG_GNUPGHOME"
GNUPGHOME="$WRONG_GNUPGHOME" gpg --batch --passphrase '' --quick-generate-key \
    'native-publication-pipeline-test WRONG key <wrong@invalid>' ed25519 sign 0 >/dev/null 2>&1
"$PUBLISH_DIR/publish-candidate.sh" "$PREPARED2" "$DEST" >/dev/null
"$PUBLISH_DIR/promote.sh" --gnupghome "$WRONG_GNUPGHOME" "$PREPARED2" "$BASE_URL" "$DEST" >/dev/null
assert_false "gpgv rejects an index signed by an untrusted key" \
    gpgv --keyring "$PUBRING" "$product_dir/SHA256SUMS.gpg" "$product_dir/SHA256SUMS"

echo "=== promote.sh: missing pubring hard-fails without touching the origin ==="
BAD_PUBRING="$WORK_DIR/does-not-exist.gpg"
before_snapshot="$(find "$DEST" -type f -exec sha256sum {} + | sort)"
promote_bad_pubring_output="$WORK_DIR/promote-bad-pubring.log"
promote_bad_pubring_rc=0
"$PUBLISH_DIR/promote.sh" --signing-key "$SIGNING_KEY" --pubring "$BAD_PUBRING" \
    "$PREPARED1" "$BASE_URL" "$DEST" >"$promote_bad_pubring_output" 2>&1 || promote_bad_pubring_rc=$?
assert_true "promote.sh exits non-zero on a missing --pubring" \
    bash -c "[[ $promote_bad_pubring_rc -ne 0 ]]"
assert_contains "missing --pubring error names the bad path" \
    "$(cat "$promote_bad_pubring_output")" "pubring not found or empty: $BAD_PUBRING"
after_snapshot="$(find "$DEST" -type f -exec sha256sum {} + | sort)"
assert_eq "origin dir unchanged after missing-pubring promote failure" "$after_snapshot" "$before_snapshot"

print_summary
