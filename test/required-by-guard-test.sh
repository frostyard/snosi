#!/bin/bash
# Fixture test for check-required-by-guard.sh (no RequiredBy= enablement
# and no shipped *.requires/ links in image payloads). See docs/adr/0013.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$root/check-required-by-guard.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

test_number=0
failures=0

run_case() {
    local name=$1 expected_status=$2 expected_output=${3:-}
    local fixture="$work/case-$((test_number + 1))" output status

    mkdir -p "$fixture"
    CASE_ROOT=$fixture
    "$CASE_SETUP"
    git -C "$fixture" init -q
    git -C "$fixture" add .

    if output=$(SNOSI_REQUIRED_BY_GUARD_ROOT="$fixture" "$guard" 2>&1); then
        status=0
    else
        status=$?
    fi

    test_number=$((test_number + 1))
    if [[ $status -eq $expected_status &&
        ( -z $expected_output || $output == *"$expected_output"* ) ]]; then
        printf 'ok %d - %s\n' "$test_number" "$name"
    else
        printf 'not ok %d - %s\n' "$test_number" "$name"
        printf '# expected status %d, got %d\n' "$expected_status" "$status"
        printf '# output: %s\n' "$output"
        failures=$((failures + 1))
    fi
}

setup_empty() {
    :
}

setup_requiredby_payload() {
    mkdir -p "$CASE_ROOT/shared/example/tree/usr/lib/systemd/system"
    cat >"$CASE_ROOT/shared/example/tree/usr/lib/systemd/system/bad.service" <<'EOF'
[Unit]
Description=Bad

[Install]
RequiredBy=multi-user.target
EOF
}

setup_wantedby_payload() {
    mkdir -p "$CASE_ROOT/shared/example/tree/usr/lib/systemd/system"
    cat >"$CASE_ROOT/shared/example/tree/usr/lib/systemd/system/good.service" <<'EOF'
[Unit]
Description=Good

[Install]
WantedBy=multi-user.target
EOF
}

setup_requiredby_outside_payload() {
    mkdir -p "$CASE_ROOT/docs"
    cat >"$CASE_ROOT/docs/example.service" <<'EOF'
[Install]
RequiredBy=multi-user.target
EOF
}

setup_requiredby_allowed() {
    mkdir -p "$CASE_ROOT/shared/example/tree/usr/lib/systemd/system"
    cat >"$CASE_ROOT/shared/example/tree/usr/lib/systemd/system/ok.service" <<'EOF'
[Install]
RequiredBy=multi-user.target # requiredby-guard-allow: retired together with its dependent, migration shipped
EOF
}

setup_requiredby_mkosi_extra() {
    mkdir -p "$CASE_ROOT/mkosi.images/base/mkosi.extra/usr/lib/systemd/system"
    cat >"$CASE_ROOT/mkosi.images/base/mkosi.extra/usr/lib/systemd/system/bad.timer" <<'EOF'
[Install]
RequiredBy=timers.target
EOF
}

setup_shipped_requires_link() {
    mkdir -p "$CASE_ROOT/shared/example/tree/usr/lib/systemd/system/multi-user.target.requires"
    ln -s /usr/lib/systemd/system/foo.service \
        "$CASE_ROOT/shared/example/tree/usr/lib/systemd/system/multi-user.target.requires/foo.service"
}

setup_requires_in_unit_section() {
    # Requires= in [Unit] of the dependent unit is the CORRECT hard-dep
    # mechanism and must not be flagged.
    mkdir -p "$CASE_ROOT/shared/example/tree/usr/lib/systemd/system"
    cat >"$CASE_ROOT/shared/example/tree/usr/lib/systemd/system/dep.service" <<'EOF'
[Unit]
Requires=network.target

[Install]
WantedBy=multi-user.target
EOF
}

CASE_SETUP=setup_empty
run_case "empty tree passes" 0 "check-required-by-guard: OK"

CASE_SETUP=setup_requiredby_payload
run_case "RequiredBy= in shared tree payload fails" 1 "RequiredBy= enablement"

CASE_SETUP=setup_requiredby_mkosi_extra
run_case "RequiredBy= in mkosi.extra payload fails" 1 "RequiredBy= enablement"

CASE_SETUP=setup_wantedby_payload
run_case "WantedBy= is fine" 0 "check-required-by-guard: OK"

CASE_SETUP=setup_requires_in_unit_section
run_case "Requires= in [Unit] is fine" 0 "check-required-by-guard: OK"

CASE_SETUP=setup_requiredby_outside_payload
run_case "RequiredBy= outside payload dirs is ignored" 0 "check-required-by-guard: OK"

CASE_SETUP=setup_requiredby_allowed
run_case "requiredby-guard-allow escape hatch works" 0 "check-required-by-guard: OK"

CASE_SETUP=setup_shipped_requires_link
run_case "shipped .requires link fails" 1 "shipped .requires enablement link"

printf '1..%d\n' "$test_number"
exit "$((failures > 0 ? 1 : 0))"
