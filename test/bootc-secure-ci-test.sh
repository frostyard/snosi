#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/shared/bootc-secure/ci/run-full-window.sh"

task123_fixture_coverage_is_present() { # workflow
    local workflow=$1
    grep -Fq 'run: ./test/bootc-secure-spike-test.sh --fixtures' "$workflow" \
        && grep -Fq 'run: sudo apt-get update && sudo apt-get install --yes cryptsetup' "$workflow" \
        && grep -Fq 'run: sudo ./test/task2-recovery-key-bytes-test.sh' "$workflow" \
        && grep -Fq 'run: python3 ./test/task3-console-pump-test.py' "$workflow"
}

workflow_invokes_static_coverage_test() { # workflow
    grep -Fq 'run: ./test/bootc-secure-ci-test.sh' "$1"
}

PASS=0
FAIL=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert_true() { local description=$1; shift; if "$@"; then pass "$description"; else fail "$description"; fi; }
assert_false() { local description=$1; shift; if "$@"; then fail "$description"; else pass "$description"; fi; }
unconfigured_harness_blocks_cleanly() { # harness
    local output status
    set +e
    output=$(env -i PATH="$PATH" "$ROOT_DIR/test/$1" 2>&1)
    status=$?
    set -e
    [[ $status -eq 2 && $output == *'BLOCKED:'* && $output != *'Error: retaining'* ]]
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

refs="$work/refs.env"
cat >"$refs" <<'EOF'
OCI_REF=ghcr.io/frostyard/cayo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TRACKING_REF=ghcr.io/frostyard/cayo:secure-test
UPDATE_N1_REF=ghcr.io/frostyard/cayo@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
UPDATE_N2_REF=ghcr.io/frostyard/cayo@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
UPDATE_N1_VERSION=20260729123456
UPDATE_N2_VERSION=20260729123457
ROTATION_OLD_REF=ghcr.io/frostyard/cayo@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
ROTATION_TRANSITION_REF=ghcr.io/frostyard/cayo@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
ROTATION_NEW_REF=ghcr.io/frostyard/cayo@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
EOF
chmod 600 "$refs"

assert_true 'mode-0700 absolute state root is accepted' validate_state_root "$work"
chmod 755 "$work"
assert_false 'world-readable state root is rejected' validate_state_root "$work"
chmod 700 "$work"
assert_true 'plain known refs are sourced' load_refs_env "$refs"
assert_true 'known refs are available after sourcing' test "$OCI_REF" = 'ghcr.io/frostyard/cayo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
printf 'UNKNOWN=value\n' >>"$refs"
assert_false 'unknown refs variable is rejected' load_refs_env "$refs"
cp "$refs" "$work/unknown.env"
head -n -1 "$refs" >"$work/valid.env"
mv "$work/valid.env" "$refs"
chmod 600 "$refs"
printf 'OCI_REF=$(id)\n' >>"$refs"
assert_false 'command substitution is rejected' load_refs_env "$refs"
head -n -1 "$refs" >"$work/valid.env"
mv "$work/valid.env" "$refs"
chmod 600 "$refs"
printf 'OCI_REF =value\n' >>"$refs"
assert_false 'whitespace syntax is rejected' load_refs_env "$refs"
head -n -1 "$refs" >"$work/valid.env"
mv "$work/valid.env" "$refs"
chmod 600 "$refs"
chmod 644 "$refs"
assert_false 'world-readable refs are rejected' load_refs_env "$refs"
assert_true 'unconfigured secure install harness blocks without a cleanup retention diagnostic' \
    unconfigured_harness_blocks_cleanly bootc-secure-install-test.sh
assert_true 'unconfigured secure update harness blocks without a cleanup retention diagnostic' \
    unconfigured_harness_blocks_cleanly bootc-secure-update-test.sh
assert_true 'test-bootc-secure workflow runs Task 1-3 fixture coverage' \
    task123_fixture_coverage_is_present "$ROOT_DIR/.github/workflows/test-bootc-secure.yml"
assert_true 'validate workflow runs Task 1-3 fixture coverage' \
    task123_fixture_coverage_is_present "$ROOT_DIR/.github/workflows/validate.yml"
assert_true 'validate workflow runs the bootc secure CI wiring regression' \
    workflow_invokes_static_coverage_test "$ROOT_DIR/.github/workflows/validate.yml"

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
