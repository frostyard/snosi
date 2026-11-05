#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixtures for shared/outformat/image/finalize/snosi-health-timer.finalize
# (ADR-0029, and ADR-0030 for the Floe report sender) plus wiring checks: every OCI composition that runs the image
# finalize also runs this guard after it (and after updex-timer.finalize), and
# the base preset enables snosi-health.timer. Both timers are fixtured: a
# preset-enabled timer needs its units, its program and its manifest entry, and
# no image may ship /etc/snosi-health.
# No root needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT_DIR/shared/outformat/image/finalize/snosi-health-timer.finalize"
PRESET="$ROOT_DIR/mkosi.images/base/mkosi.extra/usr/lib/systemd/system-preset/06-snosi-health.preset"
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
    printf 'enable something-else.timer\n%s\n' "${1:-}" >"$BUILDROOT/$PRESET_DIR/06-snosi-health.preset"
}

add_units() {
    printf '[Unit]\nDescription=fixture timer\n' >"$BUILDROOT/$UNIT_DIR/snosi-health.timer"
    printf '[Unit]\nDescription=fixture service\n' >"$BUILDROOT/$UNIT_DIR/snosi-health.service"
    mkdir -p "$BUILDROOT/usr/bin"
    printf '#!/bin/bash\n' >"$BUILDROOT/usr/bin/snosi-health"
}

# The Floe sender: snosi-health-report.timer, its service and the sender.
add_report_units() {
    printf '[Unit]\nDescription=fixture timer\n' >"$BUILDROOT/$UNIT_DIR/snosi-health-report.timer"
    printf '[Unit]\nDescription=fixture service\n' >"$BUILDROOT/$UNIT_DIR/snosi-health-report.service"
    mkdir -p "$BUILDROOT/usr/libexec"
    printf '#!/bin/bash\n' >"$BUILDROOT/usr/libexec/snosi-health-report"
}

add_report_preset() { # [line]
    printf 'enable something-else.timer\n%s\n' "${1:-}" >"$BUILDROOT/$PRESET_DIR/06-snosi-health-report.preset"
}

add_manifest() { # [line...] (default: the base timer's entry)
    if [[ $# -eq 0 ]]; then
        set -- 'system timers.target.wants/snosi-health.timer'
    fi
    {
        printf 'system multi-user.target.wants/foo.service\n'
        printf '%s\n' "$@"
    } >"$BUILDROOT/$MANIFEST_PATH"
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
    if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"snosi-health-timer.finalize:"* &&
        "$RUN_OUTPUT" == *"$2"* ]]; then
        pass "$1"
    else
        fail "$1 (exit $RUN_STATUS): $RUN_OUTPUT"
    fi
}

# --- fixtures ---------------------------------------------------------------

reset_root
add_preset 'enable snosi-health.timer'
add_units
add_manifest
expect_pass "preset, both units and the manifest entry pass"

reset_root
add_preset 'enable snosi-health.timer'
add_units
rm -f "$BUILDROOT/$UNIT_DIR/snosi-health.timer"
add_manifest
expect_reject "missing timer unit is rejected" "snosi-health.timer is missing"

reset_root
add_preset 'enable snosi-health.timer'
add_units
rm -f "$BUILDROOT/$UNIT_DIR/snosi-health.service"
add_manifest
expect_reject "missing service unit is rejected" "snosi-health.service is missing"

reset_root
add_preset 'enable snosi-health.timer'
add_units
rm -f "$BUILDROOT/usr/bin/snosi-health"
add_manifest
expect_reject "missing collector is rejected" "usr/bin/snosi-health is missing"

reset_root
add_preset 'enable snosi-health.timer'
add_units
rm -f "$BUILDROOT/usr/bin/snosi-health"
mkdir -p "$BUILDROOT/usr/bin/snosi-health"
add_manifest
expect_reject "a collector that is not a regular file is rejected" "not a regular file"

reset_root
add_preset 'enable snosi-health.timer'
add_units
add_manifest 'system timers.target.wants/updex-update.timer'
expect_reject "manifest with only the updex entry is rejected" "lacks the entry"

reset_root
add_preset 'enable snosi-health.timer'
add_units
add_manifest 'system multi-user.target.wants/something-else.service'
expect_reject "manifest without the enablement entry is rejected" "lacks the entry"

reset_root
add_preset 'enable snosi-health.timer'
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
add_preset '# enable snosi-health.timer'
add_units
add_manifest 'system multi-user.target.wants/something-else.service'
expect_pass "a commented-out preset line alone passes"

reset_root
add_preset '  enable snosi-health.timer'
add_units
add_manifest
expect_pass "an indented enable line is honored"

reset_root
mkdir -p "$BUILDROOT/etc/systemd/system-preset"
add_preset 'enable something-else.timer'
printf 'enable snosi-health.timer\n' >"$BUILDROOT/etc/systemd/system-preset/90-admin.preset"
add_units
add_manifest
expect_pass "an /etc preset that enables the timer is honored"

# --- the Floe report sender (ADR-0030) --------------------------------------

both_timers() { # both presets, every unit, both manifest entries
    add_preset 'enable snosi-health.timer'
    add_report_preset 'enable snosi-health-report.timer'
    add_units
    add_report_units
    add_manifest 'system timers.target.wants/snosi-health.timer' \
        'system timers.target.wants/snosi-health-report.timer'
}

reset_root
both_timers
expect_pass "both timers, their units, the sender and both manifest entries pass"

reset_root
both_timers
rm -f "$BUILDROOT/$UNIT_DIR/snosi-health-report.timer"
expect_reject "missing report timer unit is rejected" "snosi-health-report.timer is missing"

reset_root
both_timers
rm -f "$BUILDROOT/$UNIT_DIR/snosi-health-report.service"
expect_reject "missing report service unit is rejected" "snosi-health-report.service is missing"

reset_root
both_timers
rm -f "$BUILDROOT/usr/libexec/snosi-health-report"
expect_reject "missing sender is rejected" "usr/libexec/snosi-health-report is missing"

reset_root
both_timers
rm -f "$BUILDROOT/usr/libexec/snosi-health-report"
mkdir -p "$BUILDROOT/usr/libexec/snosi-health-report"
expect_reject "a sender that is not a regular file is rejected" "not a regular file"

reset_root
both_timers
add_manifest 'system timers.target.wants/snosi-health.timer'
expect_reject "a manifest without the report timer entry is rejected" "lacks the entry"

reset_root
add_preset 'enable snosi-health.timer'
add_report_preset 'enable snosi-health-report.timer'
add_units
add_report_units
expect_reject "no manifest at all is rejected for both timers" "is missing"

reset_root
add_preset 'enable snosi-health.timer'
add_report_preset 'enable snosi-health-report.timer'
add_units
add_report_units
add_manifest
mkdir -p "$BUILDROOT/etc/snosi-health"
printf 'enabled=1\n' >"$BUILDROOT/etc/snosi-health/reporting.conf"
expect_reject "a shipped consent directory is rejected" "etc/snosi-health must not ship"

# 1 failure never hides the other: both are reported in 1 run.
reset_root
both_timers
mkdir -p "$BUILDROOT/etc/snosi-health"
rm -f "$BUILDROOT/$UNIT_DIR/snosi-health-report.timer"
run
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"etc/snosi-health must not ship"* &&
    "$RUN_OUTPUT" == *"snosi-health-report.timer is missing"* ]]; then
    pass "a shipped consent directory and a missing report unit are both reported"
else
    fail "both problems must be reported (exit $RUN_STATUS): $RUN_OUTPUT"
fi

# Fail closed: grep's error status (2) must fail, not pass.
SHIM_DIR="$WORK_DIR/shims"
mkdir -p "$SHIM_DIR"
printf '#!/bin/sh\necho "grep: simulated failure" >&2\nexit 2\n' >"$SHIM_DIR/grep"
chmod +x "$SHIM_DIR/grep"
reset_root
add_preset 'enable snosi-health.timer'
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

if grep -Fqx 'enable snosi-health.timer' "$PRESET"; then
    pass "06-snosi-health.preset enables snosi-health.timer"
else
    fail "$PRESET must contain the exact line 'enable snosi-health.timer'"
fi

compositions=0
for conf in "$ROOT_DIR"/shared/composition/*/mkosi.conf; do
    finalize_line=$(grep -n '^FinalizeScripts=.*/outformat/image/finalize/mkosi\.finalize\.chroot$' "$conf" | cut -d: -f1 || true)
    guard_line=$(grep -n '^FinalizeScripts=.*/outformat/image/finalize/snosi-health-timer\.finalize$' "$conf" | cut -d: -f1 || true)
    updex_line=$(grep -n '^FinalizeScripts=.*/outformat/image/finalize/updex-timer\.finalize$' "$conf" | cut -d: -f1 || true)
    if [[ -z "$finalize_line" ]]; then
        continue
    fi
    compositions=$((compositions + 1))
    name=$(basename "$(dirname "$conf")")
    if [[ -n "$guard_line" && -n "$updex_line" && "$guard_line" -gt "$finalize_line" && "$guard_line" -gt "$updex_line" ]]; then
        pass "$name runs the guard after the image finalize and updex-timer.finalize"
    else
        fail "$name must list shared/outformat/image/finalize/snosi-health-timer.finalize after mkosi.finalize.chroot and updex-timer.finalize"
    fi
done

# snow (also snowfield, whose profile includes shared/composition/snow), sundog
# and floe run the image finalize.
if ((compositions >= 3)); then
    pass "$compositions compositions run the image finalize"
else
    fail "expected at least 3 compositions with the image finalize, found $compositions"
fi

if ((failures > 0)); then
    echo "snosi-health-timer-guard-test: $failures failure(s)" >&2
    exit 1
fi
echo "snosi-health-timer-guard-test: PASSED"
