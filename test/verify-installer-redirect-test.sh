#!/usr/bin/env bash
# Fixture test for shared/native-ab/publish/verify-installer-redirect.sh.
#
# The script under test performs discovery-path validation of the stable
# installer redirect: it checks argument/URL/version input, then uses curl to
# confirm the stable URL returns HTTP 302 with a Location pointing at the
# promoted immutable ISO, a Cache-Control: no-store header, a reachable ISO,
# and exactly one canonical SHA256SUMS entry for that ISO name.
#
# All network access is stubbed via a fake `curl` placed at the front of PATH
# and driven by fixture files in $STUB_DIR, so every branch is exercised
# offline and deterministically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=test/lib/helpers.sh
source "$SCRIPT_DIR/lib/helpers.sh"

SCRIPT="$REPO_ROOT/shared/native-ab/publish/verify-installer-redirect.sh"

WORKROOT="$(mktemp -d /var/tmp/verify-installer-redirect-test.XXXXXX)"
trap 'rm -rf "$WORKROOT"' EXIT

BIN="$WORKROOT/bin"
EMPTY_BIN="$WORKROOT/empty-bin"
mkdir -p "$BIN" "$EMPTY_BIN"
ORIG_PATH="$PATH"

VALID_URL="https://get.example.com/installer"
VALID_VERSION="20240115120000"
ISO_NAME="snosi-installer_${VALID_VERSION}_x86-64.iso"
VALID_LOCATION="https://get.example.com/${ISO_NAME}"
HEX64="$(printf 'a%.0s' $(seq 1 64))"

# Fake curl driven by files in $STUB_DIR:
#   headers        -> written to the -D target in status-probe mode
#   status         -> printed as the %{http_code} in status-probe mode
#   sha256sums     -> written to the -o target in download mode (absent => fail)
#   iso_reachable  -> "1" (default) success / "0" failure for the HEAD probe
cat > "$BIN/curl" <<'CURL_STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${STUB_DIR:?STUB_DIR must be set for the curl stub}"

headers_target=""
out_target=""
prev=""
for arg in "$@"; do
    case "$prev" in
        -D) headers_target="$arg" ;;
        -o) out_target="$arg" ;;
    esac
    prev="$arg"
done

if [[ -n "$headers_target" ]]; then
    # Status-probe invocation (-D <headers> -o /dev/null -w '%{http_code}').
    cat "$STUB_DIR/headers" > "$headers_target"
    printf '%s' "$(cat "$STUB_DIR/status")"
    exit 0
elif [[ -n "$out_target" ]]; then
    # SHA256SUMS download (-o <file>).
    if [[ -f "$STUB_DIR/sha256sums" ]]; then
        cat "$STUB_DIR/sha256sums" > "$out_target"
        exit 0
    fi
    exit 22
else
    # HEAD reachability probe (-fsSI <location>).
    if [[ "$(cat "$STUB_DIR/iso_reachable" 2>/dev/null || echo 1)" == "1" ]]; then
        exit 0
    fi
    exit 22
fi
CURL_STUB
chmod +x "$BIN/curl"

# Reset $STUB_DIR to a fully-valid happy-path fixture set.
reset_stub() {
    STUB_DIR="$WORKROOT/stub"
    rm -rf "$STUB_DIR"
    mkdir -p "$STUB_DIR"
    {
        echo "HTTP/2 302"
        echo "Location: ${VALID_LOCATION}"
        echo "Cache-Control: no-store"
    } > "$STUB_DIR/headers"
    echo "302" > "$STUB_DIR/status"
    echo "1" > "$STUB_DIR/iso_reachable"
    printf '%s  %s\n' "$HEX64" "$ISO_NAME" > "$STUB_DIR/sha256sums"
    export STUB_DIR
}

# run_script <url> <version> — run the script with the stub curl on PATH.
run_script() {
    PATH="$BIN:$ORIG_PATH" bash "$SCRIPT" "$@"
}

# expect_code <expected-exit> <cmd...> — succeeds iff cmd exits with the code.
expect_code() {
    local want="$1"; shift
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    [[ "$got" == "$want" ]]
}

# --- Input validation (no curl needed) --------------------------------------

reset_stub
check "usage error (exit 2) when given no arguments" \
    expect_code 2 run_script
check "usage error (exit 2) when given one argument" \
    expect_code 2 run_script "$VALID_URL"
check "usage error (exit 2) when given three arguments" \
    expect_code 2 run_script "$VALID_URL" "$VALID_VERSION" extra

check "rejects non-HTTP(S) stable URL" \
    expect_code 1 run_script "ftp://get.example.com/installer" "$VALID_VERSION"
check "rejects version shorter than 14 digits" \
    expect_code 1 run_script "$VALID_URL" "2024011512000"
check "rejects version longer than 14 digits" \
    expect_code 1 run_script "$VALID_URL" "202401151200000"
check "rejects non-digit version" \
    expect_code 1 run_script "$VALID_URL" "2024011512000X"

# curl missing: PATH has no curl, so `command -v curl` fails before any probe.
# Invoke bash by absolute path so emptying PATH only affects the script's own
# command lookups (curl), not finding the interpreter.
BASH_BIN="$(command -v bash)"
missing_curl() {
    PATH="$EMPTY_BIN" "$BASH_BIN" "$SCRIPT" "$VALID_URL" "$VALID_VERSION"
}
check "fails when curl is not installed" expect_code 1 missing_curl

# --- Happy path --------------------------------------------------------------

reset_stub
check "accepts a fully valid redirect + SHA256SUMS" \
    expect_code 0 run_script "$VALID_URL" "$VALID_VERSION"

# The http:// acceptance needs its own fixture (different Location scheme).
check_http_scheme() {
    reset_stub
    local url="http://get.example.com/installer"
    local location="http://get.example.com/${ISO_NAME}"
    {
        echo "HTTP/2 302"
        echo "Location: ${location}"
        echo "Cache-Control: no-store"
    } > "$STUB_DIR/headers"
    run_script "$url" "$VALID_VERSION"
}
check "accepts an http:// (non-TLS) stable URL" expect_code 0 check_http_scheme

# --- Redirect / header failures ---------------------------------------------

with_status_not_302() {
    reset_stub
    echo "200" > "$STUB_DIR/status"
    sed -i 's#^HTTP/2 302#HTTP/2 200#' "$STUB_DIR/headers"
    run_script "$VALID_URL" "$VALID_VERSION"
}
check "fails when stable URL does not return HTTP 302" \
    expect_code 1 with_status_not_302

with_wrong_location() {
    reset_stub
    {
        echo "HTTP/2 302"
        echo "Location: https://get.example.com/snosi-installer_20991231235959_x86-64.iso"
        echo "Cache-Control: no-store"
    } > "$STUB_DIR/headers"
    run_script "$VALID_URL" "$VALID_VERSION"
}
check "fails when redirect Location names the wrong ISO" \
    expect_code 1 with_wrong_location

with_no_cache_control() {
    reset_stub
    {
        echo "HTTP/2 302"
        echo "Location: ${VALID_LOCATION}"
    } > "$STUB_DIR/headers"
    run_script "$VALID_URL" "$VALID_VERSION"
}
check "fails when Cache-Control: no-store is absent" \
    expect_code 1 with_no_cache_control

with_cacheable_response() {
    reset_stub
    {
        echo "HTTP/2 302"
        echo "Location: ${VALID_LOCATION}"
        echo "Cache-Control: max-age=3600"
    } > "$STUB_DIR/headers"
    run_script "$VALID_URL" "$VALID_VERSION"
}
check "fails when Cache-Control allows caching (max-age)" \
    expect_code 1 with_cacheable_response

# --- ISO reachability / SHA256SUMS failures ---------------------------------

with_unreachable_iso() {
    reset_stub
    echo "0" > "$STUB_DIR/iso_reachable"
    run_script "$VALID_URL" "$VALID_VERSION"
}
check "fails when the immutable ISO is unreachable" \
    expect_code 1 with_unreachable_iso

with_missing_sha_entry() {
    reset_stub
    printf '%s  %s\n' "$HEX64" "some-other-file.iso" > "$STUB_DIR/sha256sums"
    run_script "$VALID_URL" "$VALID_VERSION"
}
check "fails when SHA256SUMS has no entry for the ISO" \
    expect_code 1 with_missing_sha_entry

with_duplicate_sha_entry() {
    reset_stub
    {
        printf '%s  %s\n' "$HEX64" "$ISO_NAME"
        printf '%s  %s\n' "$HEX64" "$ISO_NAME"
    } > "$STUB_DIR/sha256sums"
    run_script "$VALID_URL" "$VALID_VERSION"
}
check "fails when SHA256SUMS has duplicate entries for the ISO" \
    expect_code 1 with_duplicate_sha_entry

with_noncanonical_sha_entry() {
    reset_stub
    # Hash is not 64 lowercase hex chars (uppercase + too short).
    printf '%s  %s\n' "DEADBEEF" "$ISO_NAME" > "$STUB_DIR/sha256sums"
    run_script "$VALID_URL" "$VALID_VERSION"
}
check "fails when the SHA256SUMS entry hash is non-canonical" \
    expect_code 1 with_noncanonical_sha_entry

print_summary
