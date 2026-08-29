#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FINALIZE_SCRIPT="$ROOT_DIR/shared/sysext/finalize/sysext-required-paths.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

pass() {
    echo "PASS: $*"
}

run_finalize() {
    local paths_file="$1"
    local output

    cp "$paths_file" "$WORK_DIR/src/mkosi.images/test/required-paths.txt"
    if output=$(SRCDIR="$WORK_DIR/src" BUILDROOT="$WORK_DIR/buildroot" IMAGE_ID=test \
        "$FINALIZE_SCRIPT" 2>&1); then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
    RUN_OUTPUT="$output"
}

mkdir -p "$WORK_DIR/src/mkosi.images/test" "$WORK_DIR/buildroot/usr/lib/GitHub Copilot"

present_paths="$WORK_DIR/present-paths.txt"
printf '/usr/lib/GitHub Copilot\n' > "$present_paths"
run_finalize "$present_paths"
if [[ $RUN_STATUS -eq 0 ]]; then
    pass "present required path with internal spaces is accepted"
else
    fail "present required path with internal spaces is accepted: $RUN_OUTPUT"
fi

missing_paths="$WORK_DIR/missing-paths.txt"
printf '/usr/lib/Missing Copilot\n' > "$missing_paths"
run_finalize "$missing_paths"
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/usr/lib/Missing Copilot"* ]]; then
    pass "missing required path diagnostic preserves internal spaces"
else
    fail "missing required path diagnostic preserves internal spaces: $RUN_OUTPUT"
fi

if (( failures > 0 )); then
    exit 1
fi

"$ROOT_DIR/test/sysext-usr-only-test.sh"

echo "sysext-required-paths-test: PASSED"
