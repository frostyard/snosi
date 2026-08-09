#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Regression tests for bounded external APT package-index parsing.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$PROJECT_ROOT/shared/download/package-version.sh"
WORK_DIR=""
PASS=0
FAIL=0
RUN_STATUS=0
RUN_STDOUT=""
RUN_STDERR=""

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

record_pass() {
    echo "ok - $1"
    (( PASS++ )) || true
}

record_fail() {
    echo "not ok - $1"
    if [[ $# -gt 1 ]]; then
        echo "  $2" >&2
    fi
    (( FAIL++ )) || true
}

assert_equals() {
    local desc="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" == "$expected" ]]; then
        record_pass "$desc"
    else
        record_fail "$desc" "expected '$expected', got '$actual'"
    fi
}

assert_stderr_contains() {
    local desc="$1"
    local expected="$2"

    if [[ "$RUN_STDERR" == *"$expected"* ]]; then
        record_pass "$desc"
    else
        record_fail "$desc" "stderr lacked '$expected': $RUN_STDERR"
    fi
}

assert_curl_argument() {
    local desc="$1"
    local expected="$2"

    if grep -qxF -- "$expected" "$CURL_LOG"; then
        record_pass "$desc"
    else
        record_fail "$desc" "curl arguments lacked '$expected'"
    fi
}

run_lookup() {
    local fixture="$1"
    local max_bytes="$2"
    local max_seconds="$3"
    local sleep_seconds="${4:-}"

    export CURL_FIXTURE="$fixture"
    export CURL_SLEEP="$sleep_seconds"
    : >"$CURL_LOG"
    RUN_STATUS=0
    get_latest_package_version \
        "https://packages.example.invalid/Packages.gz" \
        "fixture" "$max_bytes" "$max_seconds" \
        >"$WORK_DIR/stdout.log" 2>"$WORK_DIR/stderr.log" ||
        RUN_STATUS=$?
    RUN_STDOUT="$(cat "$WORK_DIR/stdout.log")"
    RUN_STDERR="$(cat "$WORK_DIR/stderr.log")"
}

[[ -f "$HELPER" ]] || { echo "Error: helper not found: $HELPER" >&2; exit 1; }

WORK_DIR="$(mktemp -d)"
mkdir -p "$WORK_DIR/bin"
CURL_LOG="$WORK_DIR/curl.log"
export CURL_LOG

cat >"$WORK_DIR/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" >"$CURL_LOG"
if [[ -n "$CURL_SLEEP" ]]; then
    sleep "$CURL_SLEEP"
fi
cat "$CURL_FIXTURE"
EOF
chmod +x "$WORK_DIR/bin/curl"
export PATH="$WORK_DIR/bin:$PATH"

# shellcheck source=shared/download/package-version.sh
source "$HELPER"

cat >"$WORK_DIR/Packages" <<'EOF'
Package: fixture
Version: 1.9-1

Package: unrelated
Version: 99

Package: fixture
Version: 1.10-1

EOF
gzip -c "$WORK_DIR/Packages" >"$WORK_DIR/Packages.gz"
packages_size="$(wc -c <"$WORK_DIR/Packages")"

echo "# bounded APT package-index parsing"

run_lookup "$WORK_DIR/Packages.gz" "$packages_size" 60
assert_equals "an index exactly at the size limit succeeds" 0 "$RUN_STATUS"
assert_equals "the highest Debian package version is selected" "1.10-1" "$RUN_STDOUT"
assert_curl_argument "curl has a per-transfer timeout" "--max-time"
assert_curl_argument "curl bounds time across retries" "--retry-max-time"

# The producer pipeline can exit zero when the index exceeds the limit by one
# byte, so this case specifically verifies the MAX+1 size check.
run_lookup "$WORK_DIR/Packages.gz" "$((packages_size - 1))" 60
assert_equals "an index one byte over the limit fails" 1 "$RUN_STATUS"
assert_stderr_contains "an oversized index reports the size limit" \
    "decompressed package index exceeds"

{
    cat "$WORK_DIR/Packages"
    head -c 1048576 /dev/zero | tr '\0' x
} >"$WORK_DIR/oversized-Packages"
gzip -c "$WORK_DIR/oversized-Packages" >"$WORK_DIR/oversized-Packages.gz"
run_lookup "$WORK_DIR/oversized-Packages.gz" "$packages_size" 60
assert_equals "a gzip bomb that causes producer SIGPIPE fails" 1 "$RUN_STATUS"
assert_stderr_contains "producer SIGPIPE is reported as an oversized index" \
    "decompressed package index exceeds"

cp "$WORK_DIR/Packages.gz" "$WORK_DIR/truncated.gz"
truncate -s -8 "$WORK_DIR/truncated.gz"
run_lookup "$WORK_DIR/truncated.gz" "$packages_size" 60
assert_equals "a truncated gzip containing an early version fails" 1 "$RUN_STATUS"
assert_stderr_contains "a truncated gzip reports validation failure" \
    "transfer or gzip validation failed"

run_lookup "$WORK_DIR/Packages.gz" "$packages_size" 1 3
assert_equals "the hard transfer deadline aborts a stalled curl" 1 "$RUN_STATUS"
assert_stderr_contains "a transfer timeout reports validation failure" \
    "transfer or gzip validation failed"

echo ""
echo "# Results: $PASS passed, $FAIL failed, $(( PASS + FAIL )) total"
exit "$FAIL"
