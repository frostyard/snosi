#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Focused regression test for verified_download lookup across split checksum metadata.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_HELPER="$PROJECT_ROOT/shared/download/verified-download.sh"
WORK_DIR=""
SERVER_PID=""
PASS=0
FAIL=0

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
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

assert_file_content() {
    local desc="$1"
    local path="$2"
    local expected="$3"

    if [[ ! -f "$path" ]]; then
        record_fail "$desc" "missing output file: $path"
        return
    fi

    local actual
    actual="$(cat "$path")"
    if [[ "$actual" == "$expected" ]]; then
        record_pass "$desc"
    else
        record_fail "$desc" "expected '$expected', got '$actual'"
    fi
}

run_verified_download() {
    local checksums_file="$1"
    local key="$2"
    local output="$3"
    local log="$4"

    if [[ -n "$checksums_file" ]]; then
        CHECKSUMS_FILE="$checksums_file" bash -c '
            set -euo pipefail
            source "$1"
            verified_download "$2" "$3"
        ' bash "$HELPER" "$key" "$output" >"$log" 2>&1
    else
        bash -c '
            set -euo pipefail
            source "$1"
            verified_download "$2" "$3"
        ' bash "$HELPER" "$key" "$output" >"$log" 2>&1
    fi
}

expect_download() {
    local desc="$1"
    local key="$2"
    local output="$3"
    local expected="$4"
    local log="$WORK_DIR/$key.log"

    if run_verified_download "" "$key" "$output" "$log"; then
        assert_file_content "$desc" "$output" "$expected"
    else
        record_fail "$desc" "verified_download failed; log: $(cat "$log")"
    fi
}

expect_failure() {
    local desc="$1"
    local checksums_file="$2"
    local key="$3"
    local output="$4"
    local log="$WORK_DIR/$key.fail.log"

    if run_verified_download "$checksums_file" "$key" "$output" "$log"; then
        record_fail "$desc" "verified_download unexpectedly succeeded"
    else
        record_pass "$desc"
    fi
}

sha256_of() {
    sha256sum "$1" | cut -d' ' -f1
}

write_checksum_json() {
    local path="$1"
    local key="$2"
    local payload="$3"
    local version="$4"

    cat >"$path" <<JSON
{
  "$key": {
    "url": "file://$payload",
    "sha256": "$(sha256_of "$payload")",
    "version": "$version"
  }
}
JSON
}

[[ -f "$SOURCE_HELPER" ]] || { echo "Error: helper not found: $SOURCE_HELPER" >&2; exit 1; }

WORK_DIR="$(mktemp -d)"
HELPER="$WORK_DIR/shared/download/verified-download.sh"
mkdir -p "$WORK_DIR/shared/download" "$WORK_DIR/payloads" "$WORK_DIR/out"
cp "$SOURCE_HELPER" "$HELPER"

printf 'sysext payload fixture' >"$WORK_DIR/payloads/sysext.txt"
printf 'image payload fixture' >"$WORK_DIR/payloads/image.txt"
printf 'override payload fixture' >"$WORK_DIR/payloads/override.txt"

write_checksum_json "$WORK_DIR/shared/download/sysext-checksums.json" \
    "sysext-fixture" "$WORK_DIR/payloads/sysext.txt" "sysext-test"
write_checksum_json "$WORK_DIR/shared/download/image-checksums.json" \
    "image-fixture" "$WORK_DIR/payloads/image.txt" "image-test"
write_checksum_json "$WORK_DIR/shared/download/override-checksums.json" \
    "override-fixture" "$WORK_DIR/payloads/override.txt" "override-test"

echo "# verified_download split checksum lookup"

expect_download "sysext-checksums.json key downloads and verifies" \
    "sysext-fixture" "$WORK_DIR/out/sysext.txt" "sysext payload fixture"

expect_download "image-checksums.json key downloads and verifies" \
    "image-fixture" "$WORK_DIR/out/image.txt" "image payload fixture"

printf 'do not overwrite' >"$WORK_DIR/symlink-target.txt"
ln -s "$WORK_DIR/symlink-target.txt" "$WORK_DIR/out/symlink.txt"
if run_verified_download "" \
    "image-fixture" "$WORK_DIR/out/symlink.txt" "$WORK_DIR/symlink.log"; then
    assert_file_content "pre-existing output symlink is replaced" \
        "$WORK_DIR/out/symlink.txt" "image payload fixture"
    assert_file_content "pre-existing output symlink target is not overwritten" \
        "$WORK_DIR/symlink-target.txt" "do not overwrite"
    if [[ -L "$WORK_DIR/out/symlink.txt" ]]; then
        record_fail "download output is a regular file" "output remains a symlink"
    else
        record_pass "download output is a regular file"
    fi
else
    record_fail "pre-existing output symlink is safely replaced" \
        "verified_download failed; log: $(cat "$WORK_DIR/symlink.log")"
fi

expect_failure "missing key fails" \
    "" "missing-fixture" "$WORK_DIR/out/missing.txt"

expect_failure "CHECKSUMS_FILE override excludes split checksum files" \
    "$WORK_DIR/shared/download/override-checksums.json" \
    "sysext-fixture" "$WORK_DIR/out/override-restricted.txt"

if run_verified_download "$WORK_DIR/shared/download/override-checksums.json" \
    "override-fixture" "$WORK_DIR/out/override.txt" "$WORK_DIR/override.log"; then
    assert_file_content "CHECKSUMS_FILE override file key downloads and verifies" \
        "$WORK_DIR/out/override.txt" "override payload fixture"
else
    record_fail "CHECKSUMS_FILE override file key downloads and verifies" \
        "verified_download failed; log: $(cat "$WORK_DIR/override.log")"
fi

echo ""
echo "# verified_download retries transient transfer failures"

RETRY_PAYLOAD_FILE="$WORK_DIR/payloads/retry.txt"
printf 'retry payload fixture' >"$RETRY_PAYLOAD_FILE"
PORT_FILE="$WORK_DIR/retry-server.port"
COUNT_FILE="$WORK_DIR/retry-server.count"

cat >"$WORK_DIR/retry-server.py" <<'PY'
import os
import socket
import struct
import sys
import threading

PORT_FILE, COUNT_FILE, PAYLOAD_FILE = sys.argv[1:4]

with open(PAYLOAD_FILE, "rb") as fh:
    PAYLOAD = fh.read()

STATES = {}
LOCK = threading.Lock()


def record(path):
    """Count the request and publish every count to the count file."""
    with LOCK:
        STATES[path] = STATES.get(path, 0) + 1
        tmp = COUNT_FILE + ".tmp"
        with open(tmp, "w") as fh:
            for name in sorted(STATES):
                fh.write("%s %d\n" % (name, STATES[name]))
        os.replace(tmp, COUNT_FILE)
        return STATES[path]


def read_path(conn):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            return None
        buf += chunk
        if len(buf) > 65536:
            return None
    parts = buf.split(b"\r\n", 1)[0].decode("latin-1").split(" ")
    if len(parts) < 2:
        return None
    return parts[1]


def respond(conn, status, body=b""):
    head = (
        "HTTP/1.1 %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
        % (status, len(body))
    ).encode("latin-1")
    conn.sendall(head + body)


def handle(conn):
    try:
        path = read_path(conn)
        if path is None:
            return
        count = record(path)
        if path == "/payload" and count == 1:
            # First request: no response at all. SO_LINGER on with a zero
            # timeout makes close() send RST instead of FIN.
            conn.setsockopt(
                socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
            )
            return
        if path == "/payload" and count == 2:
            respond(conn, "504 Gateway Timeout")
        elif path == "/payload":
            respond(conn, "200 OK", PAYLOAD)
        else:
            respond(conn, "404 Not Found")
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(8)

tmp = PORT_FILE + ".tmp"
with open(tmp, "w") as fh:
    fh.write("%d\n" % server.getsockname()[1])
os.replace(tmp, PORT_FILE)

while True:
    try:
        conn, _ = server.accept()
    except OSError:
        break
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY

python3 "$WORK_DIR/retry-server.py" \
    "$PORT_FILE" "$COUNT_FILE" "$RETRY_PAYLOAD_FILE" \
    >"$WORK_DIR/retry-server.log" 2>&1 &
SERVER_PID=$!

RETRY_PORT=""
for _ in $(seq 1 100); do
    if [[ -s "$PORT_FILE" ]]; then
        RETRY_PORT="$(head -n1 "$PORT_FILE")"
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

if [[ -z "$RETRY_PORT" ]]; then
    record_fail "local retry fixture server answers on 127.0.0.1" \
        "no port within 10 s; log: $(cat "$WORK_DIR/retry-server.log" 2>/dev/null)"
    echo ""
    echo "# Results: $PASS passed, $FAIL failed, $(( PASS + FAIL )) total"
    exit "$FAIL"
fi

write_url_checksum_json() {
    local path="$1"
    local key="$2"
    local url="$3"
    local payload="$4"

    cat >"$path" <<JSON
{
  "$key": {
    "url": "$url",
    "sha256": "$(sha256_of "$payload")"
  }
}
JSON
}

server_request_count() {
    local path="$1"
    local count=0
    local name value

    [[ -f "$COUNT_FILE" ]] || { echo 0; return 0; }
    while read -r name value; do
        if [[ "$name" == "$path" ]]; then
            count="$value"
        fi
    done <"$COUNT_FILE"
    echo "$count"
}

RETRY_CHECKSUMS="$WORK_DIR/retry-checksums.json"
write_url_checksum_json "$RETRY_CHECKSUMS" "retry-fixture" \
    "http://127.0.0.1:$RETRY_PORT/payload" "$RETRY_PAYLOAD_FILE"

# The fixture answers request 1 with a connection reset and request 2 with 504,
# so a passing download proves both were retried.
export VERIFIED_DOWNLOAD_RETRY_DELAY=0
retry_started="$(date +%s)"
if run_verified_download "$RETRY_CHECKSUMS" "retry-fixture" \
    "$WORK_DIR/out/retry.txt" "$WORK_DIR/retry.log"; then
    assert_file_content "connection reset and 504 are retried until the payload arrives" \
        "$WORK_DIR/out/retry.txt" "retry payload fixture"
else
    record_fail "connection reset and 504 are retried until the payload arrives" \
        "verified_download failed; log: $(cat "$WORK_DIR/retry.log")"
fi
retry_elapsed=$(( $(date +%s) - retry_started ))
echo "# reset plus 504 retried in ${retry_elapsed}s (curl backoff, 0-second delay)"

requests="$(server_request_count "/payload")"
if [[ "$requests" == "3" ]]; then
    record_pass "the fixture server saw exactly 3 requests for the payload"
else
    record_fail "the fixture server saw exactly 3 requests for the payload" \
        "saw '$requests'; log: $(cat "$WORK_DIR/retry.log")"
fi

NOT_FOUND_CHECKSUMS="$WORK_DIR/not-found-checksums.json"
write_url_checksum_json "$NOT_FOUND_CHECKSUMS" "not-found-fixture" \
    "http://127.0.0.1:$RETRY_PORT/always404" "$RETRY_PAYLOAD_FILE"

export VERIFIED_DOWNLOAD_RETRIES=1
expect_failure "a permanent 404 fails once the retry budget is spent" \
    "$NOT_FOUND_CHECKSUMS" "not-found-fixture" "$WORK_DIR/out/not-found.txt"
if [[ -e "$WORK_DIR/out/not-found.txt" ]]; then
    record_fail "a permanent 404 leaves no output file" "output file exists"
else
    record_pass "a permanent 404 leaves no output file"
fi
not_found_requests="$(server_request_count "/always404")"
if [[ "$not_found_requests" == "2" ]]; then
    record_pass "a permanent 404 is tried exactly 1 + VERIFIED_DOWNLOAD_RETRIES times"
else
    record_fail "a permanent 404 is tried exactly 1 + VERIFIED_DOWNLOAD_RETRIES times" \
        "saw '$not_found_requests' requests, expected 2"
fi

payload_requests_before="$(server_request_count "/payload")"
export VERIFIED_DOWNLOAD_RETRIES=abc
if run_verified_download "$RETRY_CHECKSUMS" "retry-fixture" \
    "$WORK_DIR/out/invalid-retries.txt" "$WORK_DIR/invalid-retries.log"; then
    record_fail "a non-numeric VERIFIED_DOWNLOAD_RETRIES fails" "download succeeded"
else
    record_pass "a non-numeric VERIFIED_DOWNLOAD_RETRIES fails"
fi
if [[ -e "$WORK_DIR/out/invalid-retries.txt" ]]; then
    record_fail "a non-numeric VERIFIED_DOWNLOAD_RETRIES downloads nothing" \
        "output file exists"
elif [[ "$(server_request_count "/payload")" == "$payload_requests_before" ]]; then
    record_pass "a non-numeric VERIFIED_DOWNLOAD_RETRIES fails before any download"
else
    record_fail "a non-numeric VERIFIED_DOWNLOAD_RETRIES fails before any download" \
        "the fixture server saw a new request"
fi
if grep -q 'must be non-negative integers' "$WORK_DIR/invalid-retries.log"; then
    record_pass "a non-numeric VERIFIED_DOWNLOAD_RETRIES reports the expected error"
else
    record_fail "a non-numeric VERIFIED_DOWNLOAD_RETRIES reports the expected error" \
        "log: $(cat "$WORK_DIR/invalid-retries.log")"
fi
unset VERIFIED_DOWNLOAD_RETRIES VERIFIED_DOWNLOAD_RETRY_DELAY

echo ""
echo "# Results: $PASS passed, $FAIL failed, $(( PASS + FAIL )) total"
exit "$FAIL"
