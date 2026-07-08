#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Focused regression test for verified_download lookup across split checksum metadata.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_HELPER="$PROJECT_ROOT/shared/download/verified-download.sh"
WORK_DIR=""
PASS=0
FAIL=0

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

record_pass() {
    echo "ok - $1"
    (( PASS++ )) || true
}

record_fail() {
    echo "not ok - $1"
    if [[ $# -gt 1 ]]; then
        echo "  $2" >&2
    fi
    (( FAIL++ )) || true
}

assert_file_content() {
    local desc="$1"
    local path="$2"
    local expected="$3"

    if [[ ! -f "$path" ]]; then
        record_fail "$desc" "missing output file: $path"
        return
    fi

    local actual
    actual="$(cat "$path")"
    if [[ "$actual" == "$expected" ]]; then
        record_pass "$desc"
    else
        record_fail "$desc" "expected '$expected', got '$actual'"
    fi
}

run_verified_download() {
    local checksums_file="$1"
    local key="$2"
    local output="$3"
    local log="$4"

    if [[ -n "$checksums_file" ]]; then
        CHECKSUMS_FILE="$checksums_file" bash -c '
            set -euo pipefail
            source "$1"
            verified_download "$2" "$3"
        ' bash "$HELPER" "$key" "$output" >"$log" 2>&1
    else
        bash -c '
            set -euo pipefail
            source "$1"
            verified_download "$2" "$3"
        ' bash "$HELPER" "$key" "$output" >"$log" 2>&1
    fi
}

expect_download() {
    local desc="$1"
    local key="$2"
    local output="$3"
    local expected="$4"
    local log="$WORK_DIR/$key.log"

    if run_verified_download "" "$key" "$output" "$log"; then
        assert_file_content "$desc" "$output" "$expected"
    else
        record_fail "$desc" "verified_download failed; log: $(cat "$log")"
    fi
}

expect_failure() {
    local desc="$1"
    local checksums_file="$2"
    local key="$3"
    local output="$4"
    local log="$WORK_DIR/$key.fail.log"

    if run_verified_download "$checksums_file" "$key" "$output" "$log"; then
        record_fail "$desc" "verified_download unexpectedly succeeded"
    else
        record_pass "$desc"
    fi
}

sha256_of() {
    sha256sum "$1" | cut -d' ' -f1
}

write_checksum_json() {
    local path="$1"
    local key="$2"
    local payload="$3"
    local version="$4"

    cat >"$path" <<JSON
{
  "$key": {
    "url": "file://$payload",
    "sha256": "$(sha256_of "$payload")",
    "version": "$version"
  }
}
JSON
}

[[ -f "$SOURCE_HELPER" ]] || { echo "Error: helper not found: $SOURCE_HELPER" >&2; exit 1; }

WORK_DIR="$(mktemp -d)"
HELPER="$WORK_DIR/shared/download/verified-download.sh"
mkdir -p "$WORK_DIR/shared/download" "$WORK_DIR/payloads" "$WORK_DIR/out"
cp "$SOURCE_HELPER" "$HELPER"

printf 'sysext payload fixture' >"$WORK_DIR/payloads/sysext.txt"
printf 'image payload fixture' >"$WORK_DIR/payloads/image.txt"
printf 'override payload fixture' >"$WORK_DIR/payloads/override.txt"

write_checksum_json "$WORK_DIR/shared/download/sysext-checksums.json" \
    "sysext-fixture" "$WORK_DIR/payloads/sysext.txt" "sysext-test"
write_checksum_json "$WORK_DIR/shared/download/image-checksums.json" \
    "image-fixture" "$WORK_DIR/payloads/image.txt" "image-test"
write_checksum_json "$WORK_DIR/shared/download/override-checksums.json" \
    "override-fixture" "$WORK_DIR/payloads/override.txt" "override-test"

echo "# verified_download split checksum lookup"

expect_download "sysext-checksums.json key downloads and verifies" \
    "sysext-fixture" "$WORK_DIR/out/sysext.txt" "sysext payload fixture"

expect_download "image-checksums.json key downloads and verifies" \
    "image-fixture" "$WORK_DIR/out/image.txt" "image payload fixture"

expect_failure "missing key fails" \
    "" "missing-fixture" "$WORK_DIR/out/missing.txt"

expect_failure "CHECKSUMS_FILE override excludes split checksum files" \
    "$WORK_DIR/shared/download/override-checksums.json" \
    "sysext-fixture" "$WORK_DIR/out/override-restricted.txt"

if run_verified_download "$WORK_DIR/shared/download/override-checksums.json" \
    "override-fixture" "$WORK_DIR/out/override.txt" "$WORK_DIR/override.log"; then
    assert_file_content "CHECKSUMS_FILE override file key downloads and verifies" \
        "$WORK_DIR/out/override.txt" "override payload fixture"
else
    record_fail "CHECKSUMS_FILE override file key downloads and verifies" \
        "verified_download failed; log: $(cat "$WORK_DIR/override.log")"
fi

echo ""
echo "# Results: $PASS passed, $FAIL failed, $(( PASS + FAIL )) total"
exit "$FAIL"
