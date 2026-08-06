#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Focused regression test for shared/download/update-checksums.sh's split
# checksum metadata selection (issue #389, companion to
# test/verified-download-split-checksums-test.sh, which covers the read side).
#
# The script resolves an existing key by searching sysext-checksums.json and
# then image-checksums.json relative to its OWN directory, with CHECKSUMS_FILE
# as an explicit single-file override. Every case below runs the real script
# from a throwaway copy of that directory layout, against file:// payloads, and
# asserts BOTH that the intended file changed and that the sibling files are
# untouched byte for byte.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="$PROJECT_ROOT/shared/download/update-checksums.sh"
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

assert_equals() {
    local desc="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" == "$expected" ]]; then
        record_pass "$desc"
    else
        record_fail "$desc" "expected '$expected', got '$actual'"
    fi
}

assert_json() {
    local desc="$1"
    local file="$2"
    local filter="$3"
    local expected="$4"

    if [[ ! -f "$file" ]]; then
        record_fail "$desc" "missing file: $file"
        return
    fi

    assert_equals "$desc" "$expected" "$(jq -r "$filter" "$file")"
}

# Every case snapshots its metadata files before running the script; this
# asserts a file the script must not have touched is still byte-identical.
assert_unchanged() {
    local desc="$1"
    local dir="$2"
    local name="$3"

    if [[ ! -f "$dir/$name" ]]; then
        record_fail "$desc" "missing file: $dir/$name"
        return
    fi

    if cmp -s "$dir/before/$name" "$dir/$name"; then
        record_pass "$desc"
    else
        record_fail "$desc" "$name was modified: $(diff "$dir/before/$name" "$dir/$name" | tr '\n' ' ')"
    fi
}

assert_stderr_contains() {
    local desc="$1"
    local dir="$2"
    local needle="$3"

    if grep -qF -- "$needle" "$dir/stderr.log"; then
        record_pass "$desc"
    else
        record_fail "$desc" "stderr lacked '$needle': $(cat "$dir/stderr.log")"
    fi
}

sha256_of() {
    sha256sum "$1" | cut -d' ' -f1
}

write_entry_json() {
    local path="$1"
    local key="$2"
    local version="$3"

    cat >"$path" <<JSON
{
  "$key": {
    "url": "file://$WORK_DIR/payloads/stale.txt",
    "sha256": "$STALE_SHA",
    "version": "$version"
  }
}
JSON
}

# Builds an isolated copy of shared/download/ for one case. Extra arguments
# name metadata files to omit, so the "a default file is missing" branches can
# be exercised without mutating a shared fixture.
new_case() {
    local name="$1"; shift
    local dir="$WORK_DIR/cases/$name"
    local omit=" $* "

    mkdir -p "$dir/before"
    cp "$SOURCE_SCRIPT" "$dir/update-checksums.sh"
    chmod +x "$dir/update-checksums.sh"

    [[ "$omit" == *" sysext-checksums.json "* ]] || \
        write_entry_json "$dir/sysext-checksums.json" "sysext-fixture" "sysext-old"
    [[ "$omit" == *" image-checksums.json "* ]] || \
        write_entry_json "$dir/image-checksums.json" "image-fixture" "image-old"
    [[ "$omit" == *" override-checksums.json "* ]] || \
        write_entry_json "$dir/override-checksums.json" "sysext-fixture" "override-old"

    cp "$dir"/*-checksums.json "$dir/before/"
    echo "$dir"
}

# Runs the real script inside a case directory (its $0 dirname is what selects
# the metadata files) and records the exit status in RUN_STATUS.
run_update() {
    local dir="$1"; shift

    RUN_STATUS=0
    ( cd "$dir" && ./update-checksums.sh "$@" ) \
        >"$dir/stdout.log" 2>"$dir/stderr.log" || RUN_STATUS=$?
}

[[ -f "$SOURCE_SCRIPT" ]] || { echo "Error: script not found: $SOURCE_SCRIPT" >&2; exit 1; }
command -v jq >/dev/null || { echo "Error: jq is required" >&2; exit 1; }

WORK_DIR="$(mktemp -d)"
mkdir -p "$WORK_DIR/payloads" "$WORK_DIR/cases"

printf 'stale payload fixture' >"$WORK_DIR/payloads/stale.txt"
printf 'fresh payload fixture' >"$WORK_DIR/payloads/fresh.txt"
STALE_SHA="$(sha256_of "$WORK_DIR/payloads/stale.txt")"
FRESH_SHA="$(sha256_of "$WORK_DIR/payloads/fresh.txt")"
FRESH_URL="file://$WORK_DIR/payloads/fresh.txt"

echo "# update-checksums.sh split checksum metadata selection"

# --- Key present only in sysext-checksums.json --------------------------------
CASE_DIR="$(new_case sysext-key)"
run_update "$CASE_DIR" sysext-fixture "$FRESH_URL" sysext-new
assert_equals "sysext-only key: script succeeds" 0 "$RUN_STATUS"
assert_json "sysext-only key: url updated in sysext-checksums.json" \
    "$CASE_DIR/sysext-checksums.json" '."sysext-fixture".url' "$FRESH_URL"
assert_json "sysext-only key: sha256 updated in sysext-checksums.json" \
    "$CASE_DIR/sysext-checksums.json" '."sysext-fixture".sha256' "$FRESH_SHA"
assert_json "sysext-only key: version updated in sysext-checksums.json" \
    "$CASE_DIR/sysext-checksums.json" '."sysext-fixture".version' "sysext-new"
assert_unchanged "sysext-only key: image-checksums.json untouched" \
    "$CASE_DIR" image-checksums.json
assert_unchanged "sysext-only key: override-checksums.json untouched" \
    "$CASE_DIR" override-checksums.json

# --- Key present only in image-checksums.json ---------------------------------
CASE_DIR="$(new_case image-key)"
run_update "$CASE_DIR" image-fixture "$FRESH_URL" image-new
assert_equals "image-only key: script succeeds" 0 "$RUN_STATUS"
assert_json "image-only key: url updated in image-checksums.json" \
    "$CASE_DIR/image-checksums.json" '."image-fixture".url' "$FRESH_URL"
assert_json "image-only key: sha256 updated in image-checksums.json" \
    "$CASE_DIR/image-checksums.json" '."image-fixture".sha256' "$FRESH_SHA"
assert_json "image-only key: version updated in image-checksums.json" \
    "$CASE_DIR/image-checksums.json" '."image-fixture".version' "image-new"
assert_unchanged "image-only key: sysext-checksums.json untouched" \
    "$CASE_DIR" sysext-checksums.json

# --- Optional version argument ------------------------------------------------
CASE_DIR="$(new_case omitted-version)"
run_update "$CASE_DIR" sysext-fixture "$FRESH_URL"
assert_equals "omitted version: script succeeds" 0 "$RUN_STATUS"
assert_json "omitted version: sha256 still updated" \
    "$CASE_DIR/sysext-checksums.json" '."sysext-fixture".sha256' "$FRESH_SHA"
assert_json "omitted version: existing version preserved" \
    "$CASE_DIR/sysext-checksums.json" '."sysext-fixture".version' "sysext-old"

# --- Key absent from both split files -----------------------------------------
CASE_DIR="$(new_case missing-key)"
run_update "$CASE_DIR" absent-fixture "$FRESH_URL" absent-new
assert_equals "absent key: script fails" 1 "$RUN_STATUS"
assert_stderr_contains "absent key: reports split metadata lookup failure" \
    "$CASE_DIR" "Key 'absent-fixture' not found in split checksum metadata"
assert_unchanged "absent key: sysext-checksums.json untouched" \
    "$CASE_DIR" sysext-checksums.json
assert_unchanged "absent key: image-checksums.json untouched" \
    "$CASE_DIR" image-checksums.json

# --- CHECKSUMS_FILE override --------------------------------------------------
# The key also exists in sysext-checksums.json, so this proves the override
# short-circuits the search rather than merely agreeing with it.
CASE_DIR="$(new_case override)"
CHECKSUMS_FILE="$CASE_DIR/override-checksums.json" \
    run_update "$CASE_DIR" sysext-fixture "$FRESH_URL" override-new
assert_equals "CHECKSUMS_FILE override: script succeeds" 0 "$RUN_STATUS"
assert_json "CHECKSUMS_FILE override: sha256 updated in the named file" \
    "$CASE_DIR/override-checksums.json" '."sysext-fixture".sha256' "$FRESH_SHA"
assert_json "CHECKSUMS_FILE override: version updated in the named file" \
    "$CASE_DIR/override-checksums.json" '."sysext-fixture".version' "override-new"
assert_unchanged "CHECKSUMS_FILE override: sysext-checksums.json untouched" \
    "$CASE_DIR" sysext-checksums.json
assert_unchanged "CHECKSUMS_FILE override: image-checksums.json untouched" \
    "$CASE_DIR" image-checksums.json

# --- CHECKSUMS_FILE override reaches a file outside the split pair -------------
CASE_DIR="$(new_case override-missing-defaults)"
rm -f "$CASE_DIR/sysext-checksums.json" "$CASE_DIR/image-checksums.json"
CHECKSUMS_FILE="$CASE_DIR/override-checksums.json" \
    run_update "$CASE_DIR" sysext-fixture "$FRESH_URL" override-new
assert_equals "CHECKSUMS_FILE override: does not require the default files" \
    0 "$RUN_STATUS"
assert_json "CHECKSUMS_FILE override: named file updated without defaults" \
    "$CASE_DIR/override-checksums.json" '."sysext-fixture".sha256' "$FRESH_SHA"

# --- A default metadata file is missing ---------------------------------------
# Current behavior, locked in deliberately: the search hard-fails on the first
# missing candidate, so a key that only image-checksums.json carries is
# unreachable when sysext-checksums.json is absent.
CASE_DIR="$(new_case missing-sysext-file sysext-checksums.json)"
run_update "$CASE_DIR" image-fixture "$FRESH_URL" image-new
assert_equals "missing sysext-checksums.json: hard-fails before image lookup" \
    1 "$RUN_STATUS"
assert_stderr_contains "missing sysext-checksums.json: reports the missing file" \
    "$CASE_DIR" "Error: Checksums file not found:"
assert_unchanged "missing sysext-checksums.json: image-checksums.json untouched" \
    "$CASE_DIR" image-checksums.json

# The search stops at the first matching candidate, so a missing
# image-checksums.json is never noticed for a sysext key.
CASE_DIR="$(new_case missing-image-file image-checksums.json)"
run_update "$CASE_DIR" sysext-fixture "$FRESH_URL" sysext-new
assert_equals "missing image-checksums.json: sysext key still resolves" \
    0 "$RUN_STATUS"
assert_json "missing image-checksums.json: sysext-checksums.json updated" \
    "$CASE_DIR/sysext-checksums.json" '."sysext-fixture".sha256' "$FRESH_SHA"

# A missing image-checksums.json IS fatal once the search has to look at it.
CASE_DIR="$(new_case missing-image-file-absent-key image-checksums.json)"
run_update "$CASE_DIR" absent-fixture "$FRESH_URL" absent-new
assert_equals "missing image-checksums.json: absent key hard-fails" 1 "$RUN_STATUS"
assert_stderr_contains "missing image-checksums.json: reports the missing file" \
    "$CASE_DIR" "Error: Checksums file not found:"

# --- Download failure leaves metadata untouched -------------------------------
CASE_DIR="$(new_case download-failure)"
run_update "$CASE_DIR" sysext-fixture "file://$WORK_DIR/payloads/does-not-exist.txt" \
    sysext-new
if [[ "$RUN_STATUS" -eq 0 ]]; then
    record_fail "unfetchable URL: script fails" "script unexpectedly succeeded"
else
    record_pass "unfetchable URL: script fails"
fi
assert_unchanged "unfetchable URL: sysext-checksums.json untouched" \
    "$CASE_DIR" sysext-checksums.json

echo ""
echo "# Results: $PASS passed, $FAIL failed, $(( PASS + FAIL )) total"
exit "$FAIL"
