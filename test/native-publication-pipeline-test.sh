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
# `python3 -m http.server`).
#
# Signing key: if the gitignored DEV signing key
# (.snosi-private/os-update-signing.key) and its committed DEV pubring
# (shared/native-ab/keys/import-pubring.gpg) are both present, this test
# uses them -- both dev-only, never production material -- so local runs
# match the QEMU rehearsal. On a fresh checkout (no .snosi-private/), the
# test instead generates an EPHEMERAL, no-passphrase ed25519 keypair in its
# own temp workdir and exports a matching pubring, so every PR can run this
# self-test without any dev key present. Ephemeral mode still validates
# every script mechanic (candidate/verify/promote/withdraw, signature
# ordering, gpgv acceptance/rejection) -- it just does not exercise the
# shipped-image trust leg (a real client trusting the committed pubring),
# which is covered instead by the QEMU rehearsal below.
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
DEV_SIGNING_KEY="$ROOT_DIR/.snosi-private/os-update-signing.key"
DEV_PUBRING="$ROOT_DIR/shared/native-ab/keys/import-pubring.gpg"

WORK_DIR=""
HTTP_PID=""
S3_PID=""
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
    [[ -z "$S3_PID" ]] || kill "$S3_PID" 2>/dev/null || true
    [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for command in jq python3 sfdisk sha256sum git xz gpg gpgv curl; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done

WORK_DIR="$(mktemp -d /var/tmp/native-publication-pipeline-test.XXXXXX)"

# ---------------------------------------------------------------------------
# Signing key mode selection (see header comment). PROMOTE_KEY_ARGS is
# spliced into every promote.sh invocation below; PUBRING is used both for
# withdraw.sh's --pubring and for this script's own gpgv spot-checks. Never
# mix an ephemeral key with the committed DEV_PUBRING, or vice versa --
# gpgv would then reject everything this test itself just signed.
# ---------------------------------------------------------------------------

declare -a PROMOTE_KEY_ARGS=()
if [[ -s "$DEV_SIGNING_KEY" && -s "$DEV_PUBRING" ]]; then
    KEY_MODE="dev key (.snosi-private/os-update-signing.key + committed shared/native-ab/keys/import-pubring.gpg)"
    PUBRING="$DEV_PUBRING"
    PROMOTE_KEY_ARGS=(--signing-key "$DEV_SIGNING_KEY")
else
    # The ephemeral key is PASSPHRASE-PROTECTED and driven through
    # --signing-key + --passphrase-file, mirroring the production custody
    # exactly (the real key has a passphrase; promote.sh signs it via
    # gpg --pinentry-mode loopback). This exercises that loopback path on
    # every fresh-checkout CI run, not just the passphrase-less --gnupghome path.
    KEY_MODE="ephemeral passphrase-protected key (dev key not present -- throwaway ed25519 keypair for this run; exercises --signing-key + --passphrase-file loopback signing, not the shipped-image trust leg)"
    EPHEMERAL_GNUPGHOME="$WORK_DIR/ephemeral-gnupghome"
    mkdir -p "$EPHEMERAL_GNUPGHOME"
    chmod 700 "$EPHEMERAL_GNUPGHOME"
    EPHEMERAL_PASSPHRASE="pipeline-test-passphrase"
    EPHEMERAL_PASSFILE="$WORK_DIR/ephemeral-passphrase"
    printf '%s' "$EPHEMERAL_PASSPHRASE" > "$EPHEMERAL_PASSFILE"
    chmod 600 "$EPHEMERAL_PASSFILE"
    GNUPGHOME="$EPHEMERAL_GNUPGHOME" gpg --batch --pinentry-mode loopback \
        --passphrase "$EPHEMERAL_PASSPHRASE" --quick-generate-key \
        'native-publication-pipeline-test EPHEMERAL key <ephemeral@invalid>' ed25519 sign 0 >/dev/null 2>&1
    PUBRING="$WORK_DIR/ephemeral-pubring.gpg"
    GNUPGHOME="$EPHEMERAL_GNUPGHOME" gpg --batch --export -o "$PUBRING"
    [[ -s "$PUBRING" ]] || { echo "Error: failed to export ephemeral pubring" >&2; exit 1; }
    EPHEMERAL_SECRET="$WORK_DIR/ephemeral-secret.asc"
    GNUPGHOME="$EPHEMERAL_GNUPGHOME" gpg --batch --pinentry-mode loopback \
        --passphrase "$EPHEMERAL_PASSPHRASE" --armor --export-secret-keys \
        -o "$EPHEMERAL_SECRET" 'ephemeral@invalid'
    [[ -s "$EPHEMERAL_SECRET" ]] || { echo "Error: failed to export ephemeral secret key" >&2; exit 1; }
    PROMOTE_KEY_ARGS=(--signing-key "$EPHEMERAL_SECRET" --passphrase-file "$EPHEMERAL_PASSFILE")
fi
echo "=== signing key mode: $KEY_MODE ==="

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
promote1_out="$("$PUBLISH_DIR/promote.sh" "${PROMOTE_KEY_ARGS[@]}" --pubring "$PUBRING" "$PREPARED1" "$BASE_URL" "$DEST")"
echo "$promote1_out"
# Guards the archive block's exists-check: a first promotion has no outgoing
# signed index, and must say so -- not take the "already advertises (or is
# unparseable)" branch, which is what a false dest_object_exists positive
# produced on R2 (2026-07-16).
assert_contains "first promotion reports no existing signed index to archive" \
    "$promote1_out" "No existing signed index to archive (first promotion"
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
assert_true "gpgv accepts the promoted index against the in-use pubring ($KEY_MODE)" \
    gpgv --keyring "$PUBRING" "$product_dir/SHA256SUMS.gpg" "$product_dir/SHA256SUMS"

echo "=== verify-published-index.sh: served-bytes check against the (live http) origin ==="
assert_true "verify-published-index passes for the promoted version ($VERSION1)" \
    "$PUBLISH_DIR/verify-published-index.sh" --pubring "$PUBRING" \
    --expect-version "$VERSION1" --attempts 2 --delay 1 "$BASE_URL"
assert_false "verify-published-index fails when expecting a not-yet-served version ($VERSION2)" \
    "$PUBLISH_DIR/verify-published-index.sh" --pubring "$PUBRING" \
    --expect-version "$VERSION2" --attempts 1 --delay 0 "$BASE_URL"
# Tamper the served signature -> must fail (stale/mismatched pair). Restore
# exact bytes after; the second-promotion test below overwrites it anyway.
cp "$product_dir/SHA256SUMS.gpg" "$WORK_DIR/sig.bak"
printf 'tamper' >>"$product_dir/SHA256SUMS.gpg"
assert_false "verify-published-index fails on a tampered served signature" \
    "$PUBLISH_DIR/verify-published-index.sh" --pubring "$PUBRING" \
    --attempts 1 --delay 0 "$BASE_URL"
cp "$WORK_DIR/sig.bak" "$product_dir/SHA256SUMS.gpg"

echo "=== cloudflare-purge.sh: purge API call + success/failure handling (mocked curl) ==="
CFMOCK="$WORK_DIR/cfmock"
mkdir -p "$CFMOCK"
cat >"$CFMOCK/curl" <<'MOCK'
#!/usr/bin/env bash
# Mock curl for cloudflare-purge.sh: emit success unless the purge body names a
# URL containing "fail". Ignores all flags; only inspects the --data payload.
prev=""; body=""
for a in "$@"; do [[ "$prev" == "--data" ]] && body="$a"; prev="$a"; done
if [[ "$body" == *fail* ]]; then
    echo '{"success":false,"errors":[{"code":1012,"message":"mock failure"}]}'
else
    echo '{"success":true,"errors":[],"result":{"id":"mock"}}'
fi
MOCK
chmod +x "$CFMOCK/curl"
assert_true "cloudflare-purge succeeds on API success:true" \
    env CF_ZONE_ID=z CF_API_TOKEN=t "PATH=$CFMOCK:$PATH" \
    "$PUBLISH_DIR/cloudflare-purge.sh" "$BASE_URL/SHA256SUMS.gpg" "$BASE_URL/SHA256SUMS"
assert_false "cloudflare-purge fails on API success:false" \
    env CF_ZONE_ID=z CF_API_TOKEN=t "PATH=$CFMOCK:$PATH" \
    "$PUBLISH_DIR/cloudflare-purge.sh" "https://x/fail/SHA256SUMS"
assert_false "cloudflare-purge fails without CF env" \
    env -u CF_ZONE_ID -u CF_API_TOKEN "$PUBLISH_DIR/cloudflare-purge.sh" "$BASE_URL/SHA256SUMS"
assert_false "cloudflare-purge rejects a non-URL arg" \
    env CF_ZONE_ID=z CF_API_TOKEN=t "PATH=$CFMOCK:$PATH" \
    "$PUBLISH_DIR/cloudflare-purge.sh" "not-a-url"

echo "=== a second promotion archives the outgoing pair ==="
"$PUBLISH_DIR/publish-candidate.sh" "$PREPARED2" "$DEST" >/dev/null
"$PUBLISH_DIR/verify-remote.sh" "$PREPARED2" "$BASE_URL" >/dev/null
"$PUBLISH_DIR/promote.sh" "${PROMOTE_KEY_ARGS[@]}" --pubring "$PUBRING" "$PREPARED2" "$BASE_URL" "$DEST" >/dev/null
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
"$PUBLISH_DIR/promote.sh" --gnupghome "$WRONG_GNUPGHOME" --pubring "$PUBRING" "$PREPARED2" "$BASE_URL" "$DEST" >/dev/null
assert_false "gpgv rejects an index signed by an untrusted key" \
    gpgv --keyring "$PUBRING" "$product_dir/SHA256SUMS.gpg" "$product_dir/SHA256SUMS"

echo "=== promote.sh: missing pubring hard-fails without touching the origin ==="
BAD_PUBRING="$WORK_DIR/does-not-exist.gpg"
before_snapshot="$(find "$DEST" -type f -exec sha256sum {} + | sort)"
promote_bad_pubring_output="$WORK_DIR/promote-bad-pubring.log"
promote_bad_pubring_rc=0
"$PUBLISH_DIR/promote.sh" "${PROMOTE_KEY_ARGS[@]}" --pubring "$BAD_PUBRING" \
    "$PREPARED1" "$BASE_URL" "$DEST" >"$promote_bad_pubring_output" 2>&1 || promote_bad_pubring_rc=$?
assert_true "promote.sh exits non-zero on a missing --pubring" \
    bash -c "[[ $promote_bad_pubring_rc -ne 0 ]]"
assert_contains "missing --pubring error names the bad path" \
    "$(cat "$promote_bad_pubring_output")" "pubring not found or empty: $BAD_PUBRING"
after_snapshot="$(find "$DEST" -type f -exec sha256sum {} + | sort)"
assert_eq "origin dir unchanged after missing-pubring promote failure" "$after_snapshot" "$before_snapshot"

# ---------------------------------------------------------------------------
# ISO-shaped fixture leg (Task 8.2, docs/native-ab-contracts.md §5's flat
# "isos/native/v1" namespace): proves the SAME candidate/verify/promote/
# withdraw pipeline, unmodified apart from reading PUB_DEST_PATH instead of
# always deriving "os/native/v1/<product>/x86-64", works end to end for a
# publication-info.json whose dest_path has no per-product/x86-64 subpath.
# Uses shared/native-ab/publish/prepare-iso-publication.sh -- a tiny fixture
# file standing in for a real multi-hundred-MiB ISO (naming/staging logic
# does not care about the bytes).
# ---------------------------------------------------------------------------
echo "=== ISO-shaped fixture leg (isos/native/v1) ==="

ISO_VERSION1=20260301000000
ISO_VERSION2=20260302000000
ISO_FIXTURE1="$WORK_DIR/snosi-native-installer_${ISO_VERSION1}_x86-64.iso"
ISO_FIXTURE2="$WORK_DIR/snosi-native-installer_${ISO_VERSION2}_x86-64.iso"
printf 'fixture ISO bytes v1\n' >"$ISO_FIXTURE1"
printf 'fixture ISO bytes v2, slightly different length\n' >"$ISO_FIXTURE2"

assert_false "prepare-iso-publication.sh rejects a mis-named ISO file" \
    "$PUBLISH_DIR/prepare-iso-publication.sh" "$WORK_DIR/wrong-name.iso" "$ISO_VERSION1" "$WORK_DIR/iso-prepared-bad"

"$PUBLISH_DIR/prepare-iso-publication.sh" "$ISO_FIXTURE1" "$ISO_VERSION1" "$WORK_DIR/iso-prepared-1" >/dev/null
"$PUBLISH_DIR/prepare-iso-publication.sh" "$ISO_FIXTURE2" "$ISO_VERSION2" "$WORK_DIR/iso-prepared-2" >/dev/null
ISO_PREPARED1="$WORK_DIR/iso-prepared-1"
ISO_PREPARED2="$WORK_DIR/iso-prepared-2"
assert_true "prepare-iso-publication.sh: publication-info.json has the flat isos/native/v1 dest_path" \
    bash -c "[[ \$(jq -er '.dest_path' '$ISO_PREPARED1/publication-info.json') == 'isos/native/v1' ]]"

ISO_BASE_URL="http://127.0.0.1:${PORT}/isos/native/v1"

"$PUBLISH_DIR/publish-candidate.sh" "$ISO_PREPARED1" "$DEST"
assert_true "ISO candidate object landed under isos/native/v1/.candidate/$ISO_VERSION1/" \
    test -f "$DEST/isos/native/v1/.candidate/$ISO_VERSION1/snosi-native-installer_${ISO_VERSION1}_x86-64.iso"

assert_true "verify-remote.sh clean pass for the ISO candidate" \
    "$PUBLISH_DIR/verify-remote.sh" "$ISO_PREPARED1" "$ISO_BASE_URL"

"$PUBLISH_DIR/promote.sh" "${PROMOTE_KEY_ARGS[@]}" --pubring "$PUBRING" "$ISO_PREPARED1" "$ISO_BASE_URL" "$DEST"
iso_product_dir="$DEST/isos/native/v1"
assert_true "ISO final SHA256SUMS.gpg exists (no product/x86-64 subpath)" test -f "$iso_product_dir/SHA256SUMS.gpg"
assert_true "gpgv accepts the promoted ISO index" \
    gpgv --keyring "$PUBRING" "$iso_product_dir/SHA256SUMS.gpg" "$iso_product_dir/SHA256SUMS"
assert_contains "promoted ISO index lists the version-stamped name" \
    "$(cat "$iso_product_dir/SHA256SUMS")" "snosi-native-installer_${ISO_VERSION1}_x86-64.iso"

"$PUBLISH_DIR/publish-candidate.sh" "$ISO_PREPARED2" "$DEST" >/dev/null
"$PUBLISH_DIR/verify-remote.sh" "$ISO_PREPARED2" "$ISO_BASE_URL" >/dev/null
"$PUBLISH_DIR/promote.sh" "${PROMOTE_KEY_ARGS[@]}" --pubring "$PUBRING" "$ISO_PREPARED2" "$ISO_BASE_URL" "$DEST" >/dev/null
assert_true "ISO v1's signed index was archived to .history/$ISO_VERSION1/" \
    test -f "$iso_product_dir/.history/$ISO_VERSION1/SHA256SUMS.gpg"

"$PUBLISH_DIR/withdraw.sh" --pubring "$PUBRING" --dest-path isos/native/v1 snosi-native-installer "$ISO_VERSION1" "$DEST"
assert_contains "ISO index advertises v1 again after withdrawal via --dest-path" \
    "$(cat "$iso_product_dir/SHA256SUMS")" "snosi-native-installer_${ISO_VERSION1}_x86-64.iso"
assert_true "gpgv accepts the withdrawn (restored) ISO index" \
    gpgv --keyring "$PUBRING" "$iso_product_dir/SHA256SUMS.gpg" "$iso_product_dir/SHA256SUMS"

# ---------------------------------------------------------------------------
# publish-lib.sh dest backend semantics: dest_object_exists /
# dest_read_object / dest_copy_object must report a MISSING object as
# missing on EVERY backend. rclone's exit codes are backend-dependent here:
# bucket backends (S3/R2) have no real directories, so `rclone lsf`, `cat`,
# and `copyto` of a nonexistent object all exit 0 with empty output --
# observed live on R2 2026-07-16, when promote.sh took the "already
# advertises (or is unparseable)" archive branch on a FIRST promotion. The
# helpers must therefore key on produced output, never on exit status
# alone. The local-backend leg always runs (and pins that both backends
# behave identically); the S3 leg reproduces the real R2 shape via
# `rclone serve s3` and is skipped when rclone is not installed.
# ---------------------------------------------------------------------------
echo "=== publish-lib.sh dest backend semantics (missing vs present objects) ==="

# publib dest fn [args...] -- source publish-lib.sh in a child bash (it sets
# set -e and an EXIT trap of its own), dest_parse `dest`, then run one helper.
publib() { # dest fn [args...]
    env PUBLISH_DIR="$PUBLISH_DIR" bash -ec '
        source "$PUBLISH_DIR/publish-lib.sh"
        dest_parse "$1"
        fn="$2"
        shift 2
        "$fn" "$@"
    ' _ "$@"
}

# run_backend_asserts label dest -- the same 8 assertions against one backend.
run_backend_asserts() { # label dest
    local label="$1" dest="$2"
    local read_out="$WORK_DIR/backend-read-$label"
    local read_missing_out="$WORK_DIR/backend-read-missing-$label"
    rm -f "$read_out" "$read_missing_out"

    assert_true "$label dest: dest_object_exists true for a present object" \
        publib "$dest" dest_object_exists "sub/present.txt"
    assert_false "$label dest: dest_object_exists false for a missing object" \
        publib "$dest" dest_object_exists "sub/SHA256SUMS"
    assert_true "$label dest: dest_read_object fetches a present object" \
        publib "$dest" dest_read_object "sub/present.txt" "$read_out"
    assert_eq "$label dest: dest_read_object content round-trips" \
        "$(cat "$read_out" 2>/dev/null)" "present"
    assert_false "$label dest: dest_read_object fails for a missing object" \
        publib "$dest" dest_read_object "sub/SHA256SUMS" "$read_missing_out"
    assert_false "$label dest: dest_read_object leaves no outfile for a missing object" \
        test -e "$read_missing_out"
    assert_false "$label dest: dest_copy_object refuses a missing source object" \
        publib "$dest" dest_copy_object "sub/SHA256SUMS" "sub/copy-of-missing"
    assert_true "$label dest: dest_copy_object copies a present object" \
        publib "$dest" dest_copy_object "sub/present.txt" "sub/copy.txt"
}

LOCAL_BACKEND_DIR="$WORK_DIR/backend-local"
mkdir -p "$LOCAL_BACKEND_DIR/sub"
printf 'present\n' >"$LOCAL_BACKEND_DIR/sub/present.txt"
run_backend_asserts "local" "$LOCAL_BACKEND_DIR"
assert_false "local dest: dest_copy_object of a missing source created nothing" \
    test -e "$LOCAL_BACKEND_DIR/sub/copy-of-missing"

if command -v rclone >/dev/null; then
    S3_ROOT="$WORK_DIR/backend-s3-root"
    mkdir -p "$S3_ROOT/bucket/sub"
    printf 'present\n' >"$S3_ROOT/bucket/sub/present.txt"
    S3_PORT=18924
    rclone serve s3 --auth-key testkey,testsecret --addr "127.0.0.1:$S3_PORT" \
        "$S3_ROOT" >"$WORK_DIR/rclone-s3.log" 2>&1 &
    S3_PID=$!
    export RCLONE_CONFIG_PIPES3_TYPE=s3 \
        RCLONE_CONFIG_PIPES3_PROVIDER=Rclone \
        RCLONE_CONFIG_PIPES3_ENDPOINT="http://127.0.0.1:$S3_PORT" \
        RCLONE_CONFIG_PIPES3_ACCESS_KEY_ID=testkey \
        RCLONE_CONFIG_PIPES3_SECRET_ACCESS_KEY=testsecret \
        RCLONE_CONFIG_PIPES3_FORCE_PATH_STYLE=true
    s3_up=0
    for _ in $(seq 1 20); do
        if rclone lsf "pipes3:bucket/sub/" >/dev/null 2>&1; then
            s3_up=1
            break
        fi
        sleep 0.5
    done
    if [[ "$s3_up" == 1 ]]; then
        run_backend_asserts "s3" "rclone:pipes3:bucket"
        assert_false "s3 dest: dest_copy_object of a missing source created nothing" \
            test -e "$S3_ROOT/bucket/sub/copy-of-missing"
    else
        fail "rclone serve s3 backend came up" "$(tail -5 "$WORK_DIR/rclone-s3.log" 2>/dev/null)"
    fi
    kill "$S3_PID" 2>/dev/null || true
    S3_PID=""
else
    echo "# rclone not installed -- skipping the S3-backend leg (the local-backend leg above still ran)"
fi

print_summary
