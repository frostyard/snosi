#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixtures for shared/outformat/image/finalize/updex-timer.finalize plus
# wiring checks: every OCI composition that runs the image finalize also runs
# this guard after it, and the base preset enables updex-update.timer.
# No root needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT_DIR/shared/outformat/image/finalize/updex-timer.finalize"
PRESET="$ROOT_DIR/mkosi.images/base/mkosi.extra/usr/lib/systemd/system-preset/05-updex.preset"
WORK_DIR="$(mktemp -d)"
BUILDROOT="$WORK_DIR/root"
trap 'chmod -R u+rwX "$WORK_DIR" 2>/dev/null; rm -rf "$WORK_DIR"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "PASS: $*"; }

PRESET_DIR=usr/lib/systemd/system-preset
UNIT_DIR=usr/lib/systemd/system
MANIFEST_PATH=usr/share/snosi/enablement-manifest.txt

reset_root() {
    [[ -e "$BUILDROOT" ]] && chmod -R u+rwX "$BUILDROOT"
    rm -rf "$BUILDROOT"
    mkdir -p "$BUILDROOT/$PRESET_DIR" "$BUILDROOT/$UNIT_DIR" \
        "$(dirname "$BUILDROOT/$MANIFEST_PATH")"
}

add_preset() { # [line]
    printf 'enable something-else.timer\n%s\n' "${1:-}" >"$BUILDROOT/$PRESET_DIR/05-updex.preset"
}

add_units() {
    printf '[Unit]\nDescription=fixture timer\n' >"$BUILDROOT/$UNIT_DIR/updex-update.timer"
    printf '[Unit]\nDescription=fixture service\n' >"$BUILDROOT/$UNIT_DIR/updex-update.service"
}

add_manifest() { # [line]
    printf 'system multi-user.target.wants/foo.service\n%s\n' \
        "${1-system timers.target.wants/updex-update.timer}" >"$BUILDROOT/$MANIFEST_PATH"
}

run() {
    if RUN_OUTPUT=$(BUILDROOT="$BUILDROOT" "$GUARD" 2>&1); then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
}

expect_pass() { # description
    run
    if [[ $RUN_STATUS -eq 0 ]]; then pass "$1"; else fail "$1 (exit $RUN_STATUS): $RUN_OUTPUT"; fi
}

expect_reject() { # description expected-substring
    run
    if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"updex-timer.finalize:"* &&
        "$RUN_OUTPUT" == *"$2"* ]]; then
        pass "$1"
    else
        fail "$1 (exit $RUN_STATUS): $RUN_OUTPUT"
    fi
}

# --- fixtures ---------------------------------------------------------------

reset_root
add_preset 'enable updex-update.timer'
add_units
add_manifest
expect_pass "preset, both units and the manifest entry pass"

reset_root
add_preset 'enable updex-update.timer'
add_units
rm -f "$BUILDROOT/$UNIT_DIR/updex-update.timer"
add_manifest
expect_reject "missing timer unit is rejected" "updex-update.timer is missing"

reset_root
add_preset 'enable updex-update.timer'
add_units
rm -f "$BUILDROOT/$UNIT_DIR/updex-update.service"
add_manifest
expect_reject "missing service unit is rejected" "updex-update.service is missing"

reset_root
add_preset 'enable updex-update.timer'
add_units
add_manifest 'system multi-user.target.wants/something-else.service'
expect_reject "manifest without the enablement entry is rejected" "lacks the entry"

reset_root
add_preset 'enable updex-update.timer'
add_units
rm -f "$BUILDROOT/$MANIFEST_PATH"
expect_reject "missing enablement manifest is rejected" "is missing"

reset_root
add_preset 'enable something-else.timer'
add_units
add_manifest
expect_pass "no preset line for the timer passes"

reset_root
rm -rf "${BUILDROOT:?}/$PRESET_DIR"
add_units
add_manifest
expect_reject "missing preset directory is rejected" "is missing"

reset_root
add_preset '# enable updex-update.timer'
add_units
add_manifest 'system multi-user.target.wants/something-else.service'
expect_pass "a commented-out preset line alone passes"

reset_root
add_preset '  enable updex-update.timer'
add_units
add_manifest
expect_pass "an indented enable line is honored"

reset_root
mkdir -p "$BUILDROOT/etc/systemd/system-preset"
add_preset 'enable something-else.timer'
printf 'enable updex-update.timer\n' >"$BUILDROOT/etc/systemd/system-preset/90-admin.preset"
add_units
add_manifest
expect_pass "an /etc preset that enables the timer is honored"

# Fail closed: grep's error status (2) must fail, not pass.
SHIM_DIR="$WORK_DIR/shims"
mkdir -p "$SHIM_DIR"
printf '#!/bin/sh\necho "grep: simulated failure" >&2\nexit 2\n' >"$SHIM_DIR/grep"
chmod +x "$SHIM_DIR/grep"
reset_root
add_preset 'enable updex-update.timer'
add_units
add_manifest
if RUN_OUTPUT=$(PATH="$SHIM_DIR:$PATH" BUILDROOT="$BUILDROOT" "$GUARD" 2>&1); then
    fail "a failing grep must fail the guard (exit 0): $RUN_OUTPUT"
else
    RUN_STATUS=$?
    if [[ "$RUN_OUTPUT" == *"cannot read"* ]]; then
        pass "a failing grep fails the guard"
    else
        fail "a failing grep must report a read error (exit $RUN_STATUS): $RUN_OUTPUT"
    fi
fi

if RUN_OUTPUT=$(env -u BUILDROOT "$GUARD" 2>&1); then
    fail "missing BUILDROOT must fail closed"
else
    pass "missing BUILDROOT fails closed"
fi

# --- wiring ------------------------------------------------------------------

if grep -Fqx 'enable updex-update.timer' "$PRESET"; then
    pass "05-updex.preset enables updex-update.timer"
else
    fail "$PRESET must contain the exact line 'enable updex-update.timer'"
fi

compositions=0
for conf in "$ROOT_DIR"/shared/composition/*/mkosi.conf; do
    finalize_line=$(grep -n '^FinalizeScripts=.*/outformat/image/finalize/mkosi\.finalize\.chroot$' "$conf" | cut -d: -f1 || true)
    guard_line=$(grep -n '^FinalizeScripts=.*/outformat/image/finalize/updex-timer\.finalize$' "$conf" | cut -d: -f1 || true)
    if [[ -z "$finalize_line" ]]; then
        continue
    fi
    compositions=$((compositions + 1))
    name=$(basename "$(dirname "$conf")")
    if [[ -n "$guard_line" && "$guard_line" -gt "$finalize_line" ]]; then
        pass "$name runs the guard after the image finalize"
    else
        fail "$name must list shared/outformat/image/finalize/updex-timer.finalize after mkosi.finalize.chroot"
    fi
done

# snow (also snowfield), sundog and floe run the image finalize.
if ((compositions >= 3)); then
    pass "$compositions compositions run the image finalize"
else
    fail "expected at least 3 compositions with the image finalize, found $compositions"
fi

if ((failures > 0)); then
    echo "updex-timer-guard-test: $failures failure(s)" >&2
    exit 1
fi
echo "updex-timer-guard-test: PASSED"
