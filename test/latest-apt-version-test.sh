#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/shared/download/latest-apt-version.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

cat >"$work/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$MOCK_CURL_ARGS"
cat "$MOCK_CURL_PAYLOAD"
exit "${MOCK_CURL_STATUS:-0}"
EOF
chmod +x "$work/bin/curl"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() {
    local description=$1 expected=$2 actual=$3
    if [[ $actual == "$expected" ]]; then pass "$description"; else fail "$description (got '$actual')"; fi
}
assert_fails_with() {
    local description=$1 expected=$2; shift 2
    local output status
    set +e
    output=$("$@" 2>&1)
    status=$?
    set -e
    if ((status != 0)) && [[ $output == *"$expected"* ]]; then pass "$description"; else fail "$description (status $status, output '$output')"; fi
}

cat >"$work/Packages" <<'EOF'
Package: demo
Version: 1.9-1

Package: other
Version: 99

Package: demo
Version: 1.10-1
EOF
gzip -c "$work/Packages" >"$work/Packages.gz"

export PATH="$work/bin:$PATH"
export MOCK_CURL_PAYLOAD="$work/Packages.gz"
export MOCK_CURL_ARGS="$work/curl.args"

actual=$("$SCRIPT" https://example.invalid/Packages.gz demo)
assert_eq 'newest Debian version is selected' '1.10-1' "$actual"
args=$(cat "$MOCK_CURL_ARGS")
[[ $args == *'--max-time 60'* ]] && pass 'curl has a 60-second transfer limit' || fail 'curl has a 60-second transfer limit'
[[ $args == *'--max-filesize 52428800'* ]] && pass 'curl has a 50 MiB compressed-size limit' || fail 'curl has a 50 MiB compressed-size limit'

assert_fails_with 'compressed input over the cap is rejected' \
    'compressed APT index exceeds 8 bytes' \
    env APT_INDEX_MAX_COMPRESSED_BYTES=8 "$SCRIPT" https://example.invalid/Packages.gz demo

assert_fails_with 'decompression expansion over the cap is rejected' \
    'decompressed APT index exceeds 32 bytes' \
    env APT_INDEX_MAX_DECOMPRESSED_BYTES=32 "$SCRIPT" https://example.invalid/Packages.gz demo

printf 'not gzip' >"$work/bad.gz"
export MOCK_CURL_PAYLOAD="$work/bad.gz"
assert_fails_with 'malformed gzip input is rejected' \
    'invalid or truncated APT Packages.gz index' \
    "$SCRIPT" https://example.invalid/Packages.gz demo

export MOCK_CURL_PAYLOAD="$work/Packages.gz"
assert_fails_with 'a missing package is rejected' 'no version found for missing' \
    "$SCRIPT" https://example.invalid/Packages.gz missing

assert_fails_with 'invalid resource limits are rejected' \
    'invalid APT index resource limit' \
    env APT_INDEX_MAX_DECOMPRESSED_BYTES=unlimited \
    "$SCRIPT" https://example.invalid/Packages.gz demo

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
