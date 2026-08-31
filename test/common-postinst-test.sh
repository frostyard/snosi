#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Fixture regression test for shared/scripts/common-postinst.sh, the common
# post-installation logic sourced by the image profiles
# (shared/{snow,cayo}/scripts/postinstall/*.postinst.chroot). That
# script rewrites /usr/lib/os-release (NAME/PRETTY_NAME/ID and the sysext
# matching fields) and generates the /usr/share/frostyard package manifest,
# so it hard-requires OS_PRETTY_NAME and OS_NAME to be set before it is
# sourced -- otherwise every profile would silently ship an os-release with an
# empty NAME/PRETTY_NAME.
#
# This test exercises the script's fail-closed env-var contract (the two
# `${VAR:?...}` guards on lines 6-7): with either required variable unset the
# script must abort non-zero, emit a diagnostic naming the missing variable,
# and stop *before* touching os-release. These guard branches are covered by
# neither a unit test nor the operational image build (which always runs with
# both variables set), so they were previously unverified: removing a guard
# would ship a mislabeled os-release across all three profiles while CI stayed
# green.
#
# Scope: the guards are testable with no root, no network, and no mkosi build.
# The script's success path (sed -i on /usr/lib/os-release, mkdir under
# /usr/share and /var/lib, `apt list --installed`) writes to absolute system
# paths and therefore needs a namespaced/root-capable harness; that slice is
# intentionally out of scope here and is tracked separately.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/shared/scripts/common-postinst.sh"

[[ -f "$SCRIPT" ]] || {
    echo "common-postinst-test: cannot find $SCRIPT" >&2
    exit 1
}

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# Source the real script in a fresh non-interactive bash with a controlled
# environment. `env -i` guarantees OS_PRETTY_NAME/OS_NAME start unset
# regardless of the caller's environment; only the assignments passed as
# arguments are present (plus a bogus IMAGE_ID, which the guards must reject
# before it is ever used). Captures combined stdout+stderr and the exit code.
run_guard() {
    local out rc=0
    out=$(env -i PATH="$PATH" IMAGE_ID=fixture-id "$@" \
        bash -c 'source "$0"' "$SCRIPT" 2>&1) || rc=$?
    printf '%s' "$out"
    return "$rc"
}

# --- OS_PRETTY_NAME missing --------------------------------------------------
if out=$(run_guard OS_NAME=fixture-name); then
    fail "missing OS_PRETTY_NAME: script must abort non-zero"
else
    pass "missing OS_PRETTY_NAME: script aborts non-zero"
    if grep -q 'OS_PRETTY_NAME' <<<"$out"; then
        pass "missing OS_PRETTY_NAME: diagnostic names the missing variable"
    else
        fail "missing OS_PRETTY_NAME: diagnostic names the missing variable"
    fi
    if grep -q 'Updating os-release' <<<"$out"; then
        fail "missing OS_PRETTY_NAME: must fail closed before touching os-release"
    else
        pass "missing OS_PRETTY_NAME: fails closed before touching os-release"
    fi
fi

# --- OS_NAME missing ---------------------------------------------------------
if out=$(run_guard OS_PRETTY_NAME='Fixture Pretty'); then
    fail "missing OS_NAME: script must abort non-zero"
else
    pass "missing OS_NAME: script aborts non-zero"
    if grep -q 'OS_NAME' <<<"$out"; then
        pass "missing OS_NAME: diagnostic names the missing variable"
    else
        fail "missing OS_NAME: diagnostic names the missing variable"
    fi
    if grep -q 'Updating os-release' <<<"$out"; then
        fail "missing OS_NAME: must fail closed before touching os-release"
    else
        pass "missing OS_NAME: fails closed before touching os-release"
    fi
fi

# --- both missing ------------------------------------------------------------
if out=$(run_guard); then
    fail "both required variables missing: script must abort non-zero"
else
    pass "both required variables missing: script aborts non-zero"
fi

printf '\ncommon-postinst-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
