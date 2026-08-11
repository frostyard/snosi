#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$root/check-runtime-etc-guard.sh"
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

    if output=$(SNOSI_RUNTIME_ETC_GUARD_ROOT="$fixture" "$guard" 2>&1); then
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

setup_systemctl() {
    mkdir -p "$CASE_ROOT/shared/example/tree/usr/libexec"
    cat >"$CASE_ROOT/shared/example/tree/usr/libexec/mutate" <<'EOF'
systemctl disable old.service
systemctl enable new.service
EOF
}

setup_rm_etc() {
    mkdir -p "$CASE_ROOT/mkosi.extra/usr/libexec"
    printf 'rm -f /etc/example.conf\n' >"$CASE_ROOT/mkosi.extra/usr/libexec/mutate"
}

setup_comments() {
    mkdir -p "$CASE_ROOT/shared/example/tree/usr/libexec"
    cat >"$CASE_ROOT/shared/example/tree/usr/libexec/mutate" <<'EOF'
# systemctl disable commented.service
rm -f /etc/runtime-only.conf # etc-guard-allow: created only at runtime
# etc-guard-allow: generated unit exists only at runtime
systemctl enable generated.service
EOF
}

setup_build_time() {
    mkdir -p "$CASE_ROOT/shared/example"
    cat >"$CASE_ROOT/shared/example/mkosi.postinst.chroot" <<'EOF'
systemctl enable image-defined.service
rm -f /etc/build-only.conf
EOF
}

printf '1..5\n'
CASE_SETUP=setup_empty run_case "empty repository passes" 0
CASE_SETUP=setup_systemctl run_case "runtime systemctl disable and enable are rejected" 1 "new.service"
CASE_SETUP=setup_rm_etc run_case "runtime removal under /etc is rejected" 1 "runtime deletion/rename under /etc"
CASE_SETUP=setup_comments run_case "comments and explicit allowances are ignored" 0
CASE_SETUP=setup_build_time run_case "build-time scripts are excluded" 0

exit "$failures"
