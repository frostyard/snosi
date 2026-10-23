#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture suite for the coder sysext's "inert until configured" gate
# (snosi#1117, snosi#1120).
#
# What this pins:
#  - usr/lib/coder-sysext/coder-configured parses /etc/coder.d/coder.env as
#    text (it never sources it) and succeeds only when CODER_ACCESS_URL has a
#    non-empty value and coder has a bind address. The deb's own coder.env
#    template is 291 bytes of empty key assignments, so
#    ConditionFileNotEmpty= never kept coder.service inert, and its empty
#    CODER_HTTP_ADDRESS= replaces coder's default 127.0.0.1:3000, so an access
#    URL alone made coder server exit 1 every 5 s (snosi#1120).
#  - mkosi.finalize ships the factory coder.env with
#    CODER_HTTP_ADDRESS=127.0.0.1:3000: inert as shipped, runnable with an
#    access URL alone.
#  - coder.service.d/10-snosi-configured.conf wires the check up as
#    ExecCondition= (an exit code 1..254 skips the unit without a failure)
#    and sets a start limit that RestartSec=5 can reach; that drop-in and the
#    check itself are pinned in required-paths.txt.
#  - mkosi.conf republishes the fix as SYSEXT_REVISION=3 at the same coder
#    version.
# Everything runs through CODER_ENV_FILE and BUILDROOT against scratch files.
# No root, network, or image build.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image="$root/mkosi.images/coder"
gate="$image/mkosi.extra/usr/lib/coder-sysext/coder-configured"
dropin="$image/mkosi.extra/usr/lib/systemd/system/coder.service.d/10-snosi-configured.conf"
finalize="$image/mkosi.finalize"
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

no_address_message() { # env-file
    printf 'coder-configured: CODER_HTTP_ADDRESS is empty in %s, so coder has no address to listen on; set it (for example 127.0.0.1:3000, or 0.0.0.0:3000 for every interface) or delete the line, then run: systemctl restart coder.service' "$1"
}

url='CODER_ACCESS_URL=https://coder.example.com'

# with_template path line... : the deb template, then the given lines
with_template() {
    local path=$1; shift
    write_deb_template "$path"
    printf '%s\n' "$@" >>"$path"
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
check_gate "an unquoted set value exits 0 (no address line: coder's default applies)" 0 "$work/plain.env"

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

# ==== the bind address (snosi#1120) ==========================================
# The r2 bug: the gate passed on the old template plus an access URL, and
# coder server exited 1 ("TLS is disabled ...") every 5 s.
with_template "$work/old-template-url.env" "$url"
check_gate "the old template plus an access URL only exits 1 and names CODER_HTTP_ADDRESS" 1 \
    "$work/old-template-url.env" "$(no_address_message "$work/old-template-url.env")"

with_template "$work/url-address.env" "$url" 'CODER_HTTP_ADDRESS=0.0.0.0:3000'
check_gate "the old template plus an access URL and an address exits 0" 0 "$work/url-address.env"

printf '%s\nCODER_HTTP_ADDRESS=""\n' "$url" >"$work/quoted-empty-address.env"
check_gate 'an empty quoted address ("") exits 1' 1 "$work/quoted-empty-address.env" \
    "$(no_address_message "$work/quoted-empty-address.env")"

with_template "$work/address-then-empty.env" "$url" 'CODER_HTTP_ADDRESS=127.0.0.1:3000' 'CODER_HTTP_ADDRESS='
check_gate "an address followed by an empty one exits 1 (last assignment wins)" 1 \
    "$work/address-then-empty.env" "$(no_address_message "$work/address-then-empty.env")"

with_template "$work/legacy-address.env" "$url" 'CODER_ADDRESS=127.0.0.1:3000'
check_gate "a non-empty deprecated CODER_ADDRESS is a bind address (exit 0)" 0 "$work/legacy-address.env"

with_template "$work/empty-legacy-address.env" "$url" 'CODER_HTTP_ADDRESS=127.0.0.1:3000' 'CODER_ADDRESS='
check_gate "an empty CODER_ADDRESS= exits 1 (coder rejects it)" 1 "$work/empty-legacy-address.env"

with_template "$work/tls.env" "$url" 'CODER_TLS_ENABLE=true'
check_gate "TLS enabled uses the default TLS address (exit 0)" 0 "$work/tls.env"

with_template "$work/tls-one.env" "$url" 'CODER_TLS_ENABLE=1'
check_gate "CODER_TLS_ENABLE=1 is true (exit 0)" 0 "$work/tls-one.env"

with_template "$work/tls-empty-address.env" "$url" 'CODER_TLS_ENABLE=true' 'CODER_TLS_ADDRESS='
check_gate "TLS enabled with an empty CODER_TLS_ADDRESS= exits 1" 1 "$work/tls-empty-address.env"

with_template "$work/tls-false.env" "$url" 'CODER_TLS_ENABLE=FALSE'
check_gate "TLS disabled with the empty template address exits 1" 1 \
    "$work/tls-false.env" "$(no_address_message "$work/tls-false.env")"

with_template "$work/tls-yes.env" "$url" 'CODER_HTTP_ADDRESS=127.0.0.1:3000' 'CODER_TLS_ENABLE=yes'
check_gate "CODER_TLS_ENABLE=yes exits 1 (not a Go boolean)" 1 "$work/tls-yes.env"
run_gate "$work/tls-yes.env"
if [[ $out == *'CODER_TLS_ENABLE=yes'* && $out != *$'\n'* ]]; then
    ok "an invalid CODER_TLS_ENABLE explains itself on one line"
else
    fail "an invalid CODER_TLS_ENABLE explains itself on one line" "$out"
fi

# ==== the factory template (mkosi.finalize) ==================================
buildroot="$work/buildroot"
mkdir -p "$buildroot/etc/coder.d" "$buildroot/usr/lib/coder-sysext"
write_deb_template "$buildroot/etc/coder.d/coder.env"
cp "$gate" "$buildroot/usr/lib/coder-sysext/coder-configured"
factory="$buildroot/usr/share/factory/etc/coder.d/coder.env"
if finalize_out=$(BUILDROOT=$buildroot bash "$finalize" 2>&1); then
    ok "mkosi.finalize accepts the deb template"
else
    fail "mkosi.finalize accepts the deb template" "$finalize_out"
fi
check "the factory coder.env sets CODER_HTTP_ADDRESS=127.0.0.1:3000 once" \
    test "$(grep -c '^CODER_HTTP_ADDRESS=' "$factory" 2>/dev/null)" = 1
check "the factory coder.env has no empty CODER_HTTP_ADDRESS=" \
    grep -qx 'CODER_HTTP_ADDRESS=127.0.0.1:3000' "$factory"
check "the deb's /etc copy is not changed" \
    test "$(wc -c <"$buildroot/etc/coder.d/coder.env")" = 291
check_gate "the factory template as shipped exits 1 (inert)" 1 "$factory" "$(unset_message "$factory")"
cp "$factory" "$work/new-template-url.env"
printf '%s\n' "$url" >>"$work/new-template-url.env"
check_gate "the factory template plus an access URL only exits 0" 0 "$work/new-template-url.env"
if BUILDROOT=$buildroot bash "$finalize" >/dev/null 2>&1 &&
    test "$(grep -c '^CODER_HTTP_ADDRESS=' "$factory")" = 1; then
    ok "mkosi.finalize is idempotent"
else
    fail "mkosi.finalize is idempotent"
fi

# A template the gate would pass without an access URL fails the build.
bad="$work/bad-buildroot"
mkdir -p "$bad/etc/coder.d" "$bad/usr/lib/coder-sysext"
printf '%s\n' "$url" >"$bad/etc/coder.d/coder.env"
cp "$gate" "$bad/usr/lib/coder-sysext/coder-configured"
if BUILDROOT=$bad bash "$finalize" >/dev/null 2>&1; then
    fail "mkosi.finalize rejects a factory coder.env that is not inert"
else
    ok "mkosi.finalize rejects a factory coder.env that is not inert"
fi

# ==== static wiring ==========================================================
check "coder-configured is executable" test -x "$gate"
check "the drop-in pins exactly one ExecCondition= for the gate" \
    test "$(grep -cx 'ExecCondition=+/usr/lib/coder-sysext/coder-configured' "$dropin")" = 1
check "required-paths pins the gate" \
    grep -qx '/usr/lib/coder-sysext/coder-configured' "$required"
check "required-paths pins the gate drop-in" \
    grep -qx '/usr/lib/systemd/system/coder.service.d/10-snosi-configured.conf' "$required"
check "the drop-in sets StartLimitIntervalSec=60" grep -qx 'StartLimitIntervalSec=60' "$dropin"
check "the drop-in sets StartLimitBurst=3" grep -qx 'StartLimitBurst=3' "$dropin"
# The deb's coder.service has RestartSec=5. The limit stops a loop only when
# StartLimitBurst starts, RestartSec apart, fit in one StartLimitIntervalSec.
interval=$(sed -n 's/^StartLimitIntervalSec=//p' "$dropin")
burst=$(sed -n 's/^StartLimitBurst=//p' "$dropin")
check "the start limit can trip at RestartSec=5 ((burst - 1) * 5 < interval)" \
    test $(((burst - 1) * 5)) -lt "$interval"
check "mkosi.conf republishes at SYSEXT_REVISION=3" \
    grep -qx 'Environment=SYSEXT_REVISION=3' "$config"

echo "1..$test_number"
if ((failures)); then
    echo "# $failures failure(s)"
    exit 1
fi

echo 'coder-sysext-test: PASSED'
