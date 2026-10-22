#!/bin/bash
# Fixture test for check-upholds-guard.sh (no Upholds= of a condition-gated
# unit unless it is a RemainAfterExit=yes oneshot). See snosi#1100 and
# docs/design/sysexts.md "Service Activation Pattern (Upholds=)".
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$root/check-upholds-guard.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

test_number=0
failures=0

# run_case name expected_status [expected_output ...]
run_case() {
    local name=$1 expected_status=$2
    shift 2
    local fixture="$work/case-$((test_number + 1))" output status want ok=1

    mkdir -p "$fixture"
    CASE_ROOT=$fixture
    "$CASE_SETUP"
    git -C "$fixture" init -q
    git -C "$fixture" add .

    if output=$(SNOSI_UPHOLDS_GUARD_ROOT="$fixture" "$guard" 2>&1); then
        status=0
    else
        status=$?
    fi

    for want in "$@"; do
        [[ $output == *"$want"* ]] || ok=0
    done

    test_number=$((test_number + 1))
    if [[ $status -eq $expected_status && $ok -eq 1 ]]; then
        printf 'ok %d - %s\n' "$test_number" "$name"
    else
        printf 'not ok %d - %s\n' "$test_number" "$name"
        printf '# expected status %d, got %d\n' "$expected_status" "$status"
        printf '# output: %s\n' "$output"
        failures=$((failures + 1))
    fi
}

sysdir() { # image -> payload systemd/system dir (created)
    local d="$CASE_ROOT/mkosi.images/$1/mkosi.extra/usr/lib/systemd/system"
    mkdir -p "$d"
    printf '%s' "$d"
}

uphold() { # image target...
    local d
    d=$(sysdir "$1")
    shift
    mkdir -p "$d/multi-user.target.d"
    printf '[Unit]\nUpholds=%s\n' "$*" >"$d/multi-user.target.d/10-x.conf"
}

setup_empty() { :; }

setup_k3s_old() {
    local d f
    d=$(sysdir k3s)
    mkdir -p "$d/multi-user.target.d"
    cp "$root/test/fixtures/upholds-guard/k3s-old/10-k3s.conf" "$d/multi-user.target.d/10-k3s.conf"
    for f in k3s.service k3s-agent.service; do
        cp "$root/test/fixtures/upholds-guard/k3s-old/$f" "$d/$f"
    done
}

setup_real_k3s() {
    mkdir -p "$CASE_ROOT/mkosi.images/k3s"
    cp -a "$root/mkosi.images/k3s/mkosi.extra" "$CASE_ROOT/mkosi.images/k3s/"
}

setup_real_himmelblau() {
    mkdir -p "$CASE_ROOT/mkosi.images/himmelblau"
    cp -a "$root/mkosi.images/himmelblau/mkosi.extra" "$CASE_ROOT/mkosi.images/himmelblau/"
}

setup_conditioned_simple() {
    uphold x gated.service
    printf '[Unit]\nConditionPathExists=/etc/gated\n[Service]\nType=simple\nExecStart=/usr/bin/true\n' \
        >"$(sysdir x)/gated.service"
}

setup_oneshot_no_rae() {
    uphold x gated.service
    printf '[Unit]\nConditionPathExists=/etc/gated\n[Service]\nType=oneshot\nExecStart=/usr/bin/true\n' \
        >"$(sysdir x)/gated.service"
}

setup_dropin_condition() {
    local d
    uphold x gated.service
    d=$(sysdir x)
    printf '[Service]\nType=simple\nExecStart=/usr/bin/true\n' >"$d/gated.service"
    mkdir -p "$d/gated.service.d"
    printf '[Unit]\nConditionPathExists=/etc/gated\n' >"$d/gated.service.d/10-cond.conf"
}

setup_dropin_rae() {
    local d
    uphold x gated.service
    d=$(sysdir x)
    printf '[Unit]\nConditionPathExists=/etc/gated\n[Service]\nType=oneshot\nExecStart=/usr/bin/true\n' >"$d/gated.service"
    mkdir -p "$d/gated.service.d"
    printf '[Service]\nRemainAfterExit=yes\n' >"$d/gated.service.d/20-rae.conf"
}

setup_allow_above() {
    uphold x gated.service
    printf '[Unit]\n# upholds-guard-allow: never fails on installed systems\nConditionPathExists=/etc/gated\n[Service]\nType=simple\n' \
        >"$(sysdir x)/gated.service"
}

setup_allow_inline() {
    uphold x gated.service
    printf '[Unit]\nConditionPathExists=/etc/gated # upholds-guard-allow: nope\n[Service]\nType=simple\n' \
        >"$(sysdir x)/gated.service"
}

setup_not_in_repo() {
    uphold x packaged.service
}

setup_outside_payload() {
    mkdir -p "$CASE_ROOT/docs/systemd/system"
    printf '[Unit]\nUpholds=gated.service\n' >"$CASE_ROOT/docs/systemd/system/multi-user.target.d.conf"
    printf '[Unit]\nConditionPathExists=/etc/gated\n[Service]\nType=simple\n' \
        >"$CASE_ROOT/docs/systemd/system/gated.service"
}

setup_two_lines_one_bad() {
    local d
    d=$(sysdir x)
    mkdir -p "$d/multi-user.target.d"
    printf '[Unit]\nUpholds=good.service\nUpholds=other.service bad.service\n' \
        >"$d/multi-user.target.d/10-x.conf"
    printf '[Service]\nType=simple\n' >"$d/good.service"
    printf '[Service]\nType=simple\n' >"$d/other.service"
    printf '[Unit]\nConditionPathExists=/etc/bad\n[Service]\nType=simple\n' >"$d/bad.service"
}

CASE_SETUP=setup_empty
run_case "empty tree passes" 0 "check-upholds-guard: OK"

CASE_SETUP=setup_k3s_old
run_case "old k3s units (snosi#1100) fail and name both units" 1 \
    "k3s.service is upheld" "k3s-agent.service is upheld" "snosi#1100"

CASE_SETUP=setup_real_k3s
run_case "current k3s payload passes" 0 "check-upholds-guard: OK"

CASE_SETUP=setup_real_himmelblau
run_case "current himmelblau payload passes" 0 "check-upholds-guard: OK"

CASE_SETUP=setup_conditioned_simple
run_case "upheld conditioned simple service fails" 1 "gated.service is upheld"

CASE_SETUP=setup_oneshot_no_rae
run_case "upheld conditioned oneshot without RemainAfterExit fails" 1 "gated.service is upheld"

CASE_SETUP=setup_dropin_condition
run_case "condition only in a .d drop-in fails" 1 "10-cond.conf:2:"

CASE_SETUP=setup_dropin_rae
run_case "RemainAfterExit=yes from a drop-in passes" 0 "check-upholds-guard: OK"

CASE_SETUP=setup_allow_above
run_case "allow comment on the line above exempts" 0 "check-upholds-guard: OK"

CASE_SETUP=setup_allow_inline
run_case "trailing inline allow comment does not exempt" 1 "gated.service is upheld"

CASE_SETUP=setup_not_in_repo
run_case "upheld unit not in the repo passes" 0 "check-upholds-guard: OK"

CASE_SETUP=setup_outside_payload
run_case "conditioned units outside payload paths are ignored" 0 "check-upholds-guard: OK"

CASE_SETUP=setup_two_lines_one_bad
run_case "two Upholds= lines, one bad target, fail" 1 "bad.service is upheld"

printf '1..%d\n' "$test_number"
exit "$((failures > 0 ? 1 : 0))"
