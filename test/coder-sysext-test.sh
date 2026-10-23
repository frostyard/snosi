#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture suite for the coder sysext's "inert until configured" gate
# (snosi#1117).
#
# What this pins:
#  - usr/lib/coder-sysext/coder-configured parses /etc/coder.d/coder.env as
#    text (it never sources it) and succeeds only when CODER_ACCESS_URL has a
#    non-empty value. The deb's own coder.env template is 291 bytes of empty
#    key assignments, so ConditionFileNotEmpty= never kept coder.service
#    inert; this check is the real gate.
#  - coder.service.d/10-snosi-configured.conf wires it up as ExecCondition=
#    (an exit code 1..254 skips the unit without a failure), and that drop-in
#    and the check itself are pinned in required-paths.txt.
#  - mkosi.conf republishes the fix as SYSEXT_REVISION=2 at the same coder
#    version.
# Everything runs through CODER_ENV_FILE against scratch files. No root,
# network, or image build.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image="$root/mkosi.images/coder"
gate="$image/mkosi.extra/usr/lib/coder-sysext/coder-configured"
dropin="$image/mkosi.extra/usr/lib/systemd/system/coder.service.d/10-snosi-configured.conf"
required="$image/required-paths.txt"
config="$image/mkosi.conf"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

test_number=0
failures=0
ok() { test_number=$((test_number + 1)); echo "ok $test_number - $1"; }
fail() {
    test_number=$((test_number + 1)); failures=$((failures + 1))
    echo "not ok $test_number - $1"
    [[ -n ${2:-} ]] && printf '#   %s\n' "$2"
    return 0
}
check() { # description condition-command...
    local desc=$1; shift
    if "$@"; then ok "$desc"; else fail "$desc"; fi
}

# The byte-exact /etc/coder.d/coder.env the coder 2.37.4 deb ships (291 bytes).
write_deb_template() { # path
    cat >"$1" <<'TEMPLATE'
# Coder must be reachable from an external URL for users and workspaces to connect.
# e.g. https://coder.example.com
CODER_ACCESS_URL=

CODER_HTTP_ADDRESS=
CODER_PG_CONNECTION_URL=
CODER_TLS_CERT_FILE=
CODER_TLS_ENABLE=
CODER_TLS_KEY_FILE=

# Run "coder server --help" for flag information.
TEMPLATE
}

run_gate() { # env-file -> sets status and out
    status=0
    out=$(CODER_ENV_FILE=$1 "$gate" 2>&1) || status=$?
}

unset_message() { # env-file
    printf 'coder-configured: CODER_ACCESS_URL is not set in %s; set it, then run: systemctl restart coder.service' "$1"
}

# check_gate description expected-status env-file [expected-output]
check_gate() {
    local desc=$1 want=$2 file=$3 want_out=${4:-}
    run_gate "$file"
    if ((status != want)); then
        fail "$desc" "expected exit $want, got $status: $out"
    elif [[ -n $want_out && $out != "$want_out" ]]; then
        fail "$desc" "unexpected output: $out"
    else
        ok "$desc"
    fi
}

# ==== the gate ===============================================================
check_gate "missing env file exits 1" 1 "$work/absent.env"
run_gate "$work/absent.env"
if [[ $out == *'cannot read'* && $out != *$'\n'* ]]; then
    ok "missing env file explains itself on one line"
else
    fail "missing env file explains itself on one line" "$out"
fi

template="$work/template.env"
write_deb_template "$template"
check_gate "the 291-byte deb template exits 1" 1 "$template" "$(unset_message "$template")"
check "the deb template fixture is byte-exact (291 bytes)" \
    test "$(wc -c <"$template")" = 291

printf 'CODER_ACCESS_URL=https://coder.example.com\n' >"$work/plain.env"
check_gate "an unquoted set value exits 0" 0 "$work/plain.env"

printf 'CODER_ACCESS_URL=""\n' >"$work/double-empty.env"
check_gate 'an empty double-quoted value ("") exits 1' 1 "$work/double-empty.env" "$(unset_message "$work/double-empty.env")"

printf "CODER_ACCESS_URL=''\n" >"$work/single-empty.env"
check_gate "an empty single-quoted value ('') exits 1" 1 "$work/single-empty.env" "$(unset_message "$work/single-empty.env")"

printf '#CODER_ACCESS_URL=https://coder.example.com\n' >"$work/commented.env"
check_gate "a commented-out assignment only exits 1" 1 "$work/commented.env" "$(unset_message "$work/commented.env")"

printf 'CODER_ACCESS_URL="https://coder.example.com"\n' >"$work/double.env"
check_gate "a double-quoted value exits 0" 0 "$work/double.env"

printf "CODER_ACCESS_URL='https://coder.example.com'\n" >"$work/single.env"
check_gate "a single-quoted value exits 0" 0 "$work/single.env"

printf '  CODER_ACCESS_URL=https://coder.example.com\n' >"$work/indented.env"
check_gate "a leading-space assignment exits 0" 0 "$work/indented.env"

printf '\tCODER_ACCESS_URL=https://coder.example.com\n' >"$work/tabbed.env"
check_gate "a leading-tab assignment exits 0" 0 "$work/tabbed.env"

printf 'CODER_ACCESS_URL=https://coder.example.com\nCODER_ACCESS_URL=\n' >"$work/set-then-empty.env"
check_gate "a set value followed by an empty one exits 1 (last assignment wins)" 1 \
    "$work/set-then-empty.env" "$(unset_message "$work/set-then-empty.env")"

printf 'CODER_ACCESS_URL=\nCODER_ACCESS_URL=https://coder.example.com\n' >"$work/empty-then-set.env"
check_gate "an empty value followed by a set one exits 0" 0 "$work/empty-then-set.env"

# The file is parsed, never sourced: a value is taken literally.
cat >"$work/literal.env" <<'LITERAL'
CODER_ACCESS_URL=$(id -u)
LITERAL
check_gate "a value with a command substitution is not executed" 0 "$work/literal.env"

# ==== static wiring ==========================================================
check "coder-configured is executable" test -x "$gate"
check "the drop-in pins exactly one ExecCondition= for the gate" \
    test "$(grep -cx 'ExecCondition=+/usr/lib/coder-sysext/coder-configured' "$dropin")" = 1
check "required-paths pins the gate" \
    grep -qx '/usr/lib/coder-sysext/coder-configured' "$required"
check "required-paths pins the gate drop-in" \
    grep -qx '/usr/lib/systemd/system/coder.service.d/10-snosi-configured.conf' "$required"
check "mkosi.conf republishes at SYSEXT_REVISION=2" \
    grep -qx 'Environment=SYSEXT_REVISION=2' "$config"

echo "1..$test_number"
if ((failures)); then
    echo "# $failures failure(s)"
    exit 1
fi

echo 'coder-sysext-test: PASSED'
