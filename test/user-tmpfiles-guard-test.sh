#!/bin/bash
# Fixture test for check-user-tmpfiles-guard.sh (no tracked paths under
# usr/lib/user-tmpfiles.d, which user scope never reads). See snosi#1265:
# https://github.com/frostyard/snosi/issues/1265
# shellcheck disable=SC2329 # CASE_SETUP invokes the setup functions indirectly.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$root/check-user-tmpfiles-guard.sh"
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

    if output=$(SNOSI_USER_TMPFILES_GUARD_ROOT="$fixture" "$guard" 2>&1); then
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

setup_user_share() {
    mkdir -p "$CASE_ROOT/shared/example/tree/usr/share/user-tmpfiles.d"
    printf '# Valid user search path\n' >"$CASE_ROOT/shared/example/tree/usr/share/user-tmpfiles.d/x.conf"
}

setup_user_lib_mkosi_extra() {
    mkdir -p "$CASE_ROOT/mkosi.images/base/mkosi.extra/usr/lib/user-tmpfiles.d"
    printf '# Unread user search path\n' >"$CASE_ROOT/mkosi.images/base/mkosi.extra/usr/lib/user-tmpfiles.d/x.conf"
}

setup_system_lib() {
    mkdir -p "$CASE_ROOT/shared/example/tree/usr/lib/tmpfiles.d"
    printf '# Valid system search path\n' >"$CASE_ROOT/shared/example/tree/usr/lib/tmpfiles.d/x.conf"
}

setup_revert() {
    mkdir -p "$CASE_ROOT/shared/bootc-secure/tree/usr/lib/user-tmpfiles.d"
    # Exact rule removed by snosi#1265: restoring it must fail the guard.
    cat >"$CASE_ROOT/shared/bootc-secure/tree/usr/lib/user-tmpfiles.d/snosi-containers-policy.conf" <<'EOF'
# Rootless container work is user-controlled. The strict update policy lives in
# immutable /usr (/usr/lib/snosi/containers/bootc-policy.json) and does not read
# this copy; /etc/containers/policy.json accepts workload images.
d %h/.config/containers 0700 - - -
C %h/.config/containers/policy.json 0600 - - - /usr/share/snosi/containers/user-policy.json
EOF
}

setup_outside_payload() {
    mkdir -p "$CASE_ROOT/docs/example/usr/lib/user-tmpfiles.d"
    printf '# Also forbidden outside payloads\n' >"$CASE_ROOT/docs/example/usr/lib/user-tmpfiles.d/x.conf"
}

setup_root_path() {
    mkdir -p "$CASE_ROOT/usr/lib/user-tmpfiles.d"
    printf '# Also forbidden at the repository root\n' >"$CASE_ROOT/usr/lib/user-tmpfiles.d/x.conf"
}

CASE_SETUP=setup_empty
run_case "empty tree passes" 0 "check-user-tmpfiles-guard: OK"

CASE_SETUP=setup_user_share
run_case "usr/share user rules pass" 0 "check-user-tmpfiles-guard: OK"

CASE_SETUP=setup_user_lib_mkosi_extra
run_case "usr/lib user rules in mkosi.extra fail" 1 "mkosi.images/base/mkosi.extra/usr/lib/user-tmpfiles.d/x.conf: systemd-tmpfiles --user never reads"

CASE_SETUP=setup_system_lib
run_case "usr/lib system rules pass" 0 "check-user-tmpfiles-guard: OK"

CASE_SETUP=setup_revert
run_case "REVERT of the exact retired container-policy rule fails" 1 "shared/bootc-secure/tree/usr/lib/user-tmpfiles.d/snosi-containers-policy.conf: systemd-tmpfiles --user never reads"

CASE_SETUP=setup_outside_payload
run_case "usr/lib user rules outside payloads fail" 1 "docs/example/usr/lib/user-tmpfiles.d/x.conf: systemd-tmpfiles --user never reads"

CASE_SETUP=setup_root_path
run_case "usr/lib user rules at the repository root fail" 1 "usr/lib/user-tmpfiles.d/x.conf: systemd-tmpfiles --user never reads"

# No override: the guard must find the real repository from its own path,
# even when called from another working directory.
if output=$(cd "$work" && env -u SNOSI_USER_TMPFILES_GUARD_ROOT "$guard" 2>&1); then
    status=0
else
    status=$?
fi
test_number=$((test_number + 1))
if [[ $status -eq 0 && $output =~ ^check-user-tmpfiles-guard:\ OK\ \(([1-9][0-9]*)\ tracked\ paths\ checked\)$ ]]; then
    printf 'ok %d - real repository passes without an override\n' "$test_number"
else
    printf 'not ok %d - real repository passes without an override\n' "$test_number"
    printf '# expected status 0, got %d\n# output: %s\n' "$status" "$output"
    failures=$((failures + 1))
fi

printf '1..%d\n' "$test_number"
exit "$((failures > 0 ? 1 : 0))"
