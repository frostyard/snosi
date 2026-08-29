#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FINALIZE_SCRIPT="$ROOT_DIR/shared/sysext/finalize/sysext-usr-only.sh"
WORK_DIR="$(mktemp -d)"
BUILDROOT="$WORK_DIR/buildroot"
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
    local output

    if output=$(BUILDROOT="$BUILDROOT" IMAGE_ID=fixture "$FINALIZE_SCRIPT" 2>&1); then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
    RUN_OUTPUT="$output"
}

reset_buildroot() {
    rm -rf "$BUILDROOT"
    mkdir -p "$BUILDROOT/usr/bin" "$BUILDROOT/var" "$BUILDROOT/opt"
    printf '#!/bin/sh\n' >"$BUILDROOT/usr/bin/fixture"
}

reset_buildroot
run_finalize
if [[ $RUN_STATUS -eq 0 ]]; then
    pass "/usr payload with empty /var and /opt mountpoints is accepted"
else
    fail "/usr payload was rejected: $RUN_OUTPUT"
fi

reset_buildroot
mkdir -p "$BUILDROOT/var/log" "$BUILDROOT/var/cache/dictionaries-common"
printf 'build log\n' >"$BUILDROOT/var/log/dpkg.log"
printf 'build cache\n' >"$BUILDROOT/var/cache/dictionaries-common/aspell.db"
run_finalize
if [[ $RUN_STATUS -eq 0 && ! -e "$BUILDROOT/var/log" &&
    ! -e "$BUILDROOT/var/cache" ]]; then
    pass "build-only package logs and caches are removed before payload validation"
else
    fail "build-only package residue was not cleaned: $RUN_OUTPUT"
fi

reset_buildroot
mkdir -p "$BUILDROOT/var/lib/fixture"
printf 'state\n' >"$BUILDROOT/var/lib/fixture/state"
run_finalize
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/var/lib"* &&
    "$RUN_OUTPUT" == *"must be /usr-only"* ]]; then
    pass "/var payload is rejected with the contract and offending path"
else
    fail "/var payload produced the wrong result: $RUN_OUTPUT"
fi

reset_buildroot
mkdir -p "$BUILDROOT/opt/fixture/bin"
printf '#!/bin/sh\n' >"$BUILDROOT/opt/fixture/bin/tool"
run_finalize
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/opt/fixture"* &&
    "$RUN_OUTPUT" == *"must be /usr-only"* ]]; then
    pass "/opt payload is rejected with the contract and offending path"
else
    fail "/opt payload produced the wrong result: $RUN_OUTPUT"
fi

reset_buildroot
mkdir -p "$BUILDROOT/var/lib" "$WORK_DIR/outside"
printf 'must not be inspected\n' >"$WORK_DIR/outside/host-path"
ln -s "$WORK_DIR/outside" "$BUILDROOT/var/lib/external-link"
run_finalize
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/var/lib/external-link"* &&
    "$RUN_OUTPUT" != *"host-path"* ]]; then
    pass "symlink payload is rejected without traversing outside the buildroot"
else
    fail "symlink payload produced the wrong result: $RUN_OUTPUT"
fi

if ((failures > 0)); then
    exit 1
fi

echo "sysext-usr-only-test: PASSED"
