#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Non-root fixture for the retained installer ISO candidate/verify/promote
# pipeline. An ephemeral signing key and localhost origin never touch R2.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
publish="$root/shared/native-ab/publish"
for cmd in jq python3 sha256sum git gpg gpgv curl; do
    command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 1; }
done

work=$(mktemp -d /var/tmp/iso-publication-pipeline.XXXXXX)
server_pid=""; cold_pid=""; ignore_pid=""
cleanup() {
    for pid in "$server_pid" "$cold_pid" "$ignore_pid"; do
        [[ -z $pid ]] || kill "$pid" 2>/dev/null || true
    done
    rm -rf "$work"
}
trap cleanup EXIT

pass=0
check() { # description command...
    local description=$1
    shift
    if "$@"; then
        pass=$((pass + 1))
        echo "ok $pass - $description"
    else
        echo "not ok - $description" >&2
        exit 1
    fi
}
reject() { # description command...
    local description=$1
    shift
    if "$@" >"$work/rejected.log" 2>&1; then
        echo "not ok - $description (unexpected success)" >&2
        exit 1
    fi
    pass=$((pass + 1))
    echo "ok $pass - $description"
}

key_home="$work/gnupg"
mkdir -m 700 "$key_home"
passphrase_file="$work/passphrase"
printf '%s' 'throwaway-iso-publication-fixture' >"$passphrase_file"
chmod 600 "$passphrase_file"
GNUPGHOME="$key_home" gpg --batch --pinentry-mode loopback \
    --passphrase-file "$passphrase_file" --quick-generate-key \
    'iso-publication-fixture <iso@invalid>' ed25519 sign 0 >/dev/null 2>&1
pubring="$work/pubring.gpg"
secret="$work/secret.asc"
GNUPGHOME="$key_home" gpg --batch --export -o "$pubring"
GNUPGHOME="$key_home" gpg --batch --pinentry-mode loopback \
    --passphrase-file "$passphrase_file" --armor --export-secret-keys \
    -o "$secret" 'iso@invalid'
signing=(--signing-key "$secret" --passphrase-file "$passphrase_file" --pubring "$pubring")

v1=20260301000000
v2=20260302000000
iso1="$work/snosi-installer_${v1}_x86-64.iso"
iso2="$work/snosi-installer_${v2}_x86-64.iso"
# Larger than 8192 bytes so verify-remote probes two non-overlapping ranges.
python3 - "$iso1" "$iso2" <<'PY'
from pathlib import Path
import sys
for n, filename in enumerate(sys.argv[1:], 1):
    Path(filename).write_bytes(bytes(range(256)) * (40 + n))
PY
reject 'prepare refuses incorrectly named ISO' \
    "$publish/prepare-iso-publication.sh" "$iso1" "$v2" "$work/bad"
reject 'prepare refuses malformed version' \
    "$publish/prepare-iso-publication.sh" "$iso1" 123 "$work/bad"
"$publish/prepare-iso-publication.sh" "$iso1" "$v1" "$work/one" >/dev/null
"$publish/prepare-iso-publication.sh" "$iso2" "$v2" "$work/two" >/dev/null
check 'flat ISO namespace is recorded in publication-info.json' \
    jq -e '.dest_path == "isos/native/v1" and .channel == "snosi-installer"' "$work/one/publication-info.json"
check 'prepared ISO checksum validates' \
    bash -c 'cd "$1" && sha256sum -c SHA256SUMS' _ "$work/one"

dest="$work/origin"
mkdir -p "$dest"
# Bind only localhost; choose distinct OS-allocated ports for each origin.
ports=$(python3 - <<'PY'
import socket
sockets = [socket.socket() for _ in range(3)]
try:
    for sock in sockets:
        sock.bind(('127.0.0.1', 0))
    print(*(sock.getsockname()[1] for sock in sockets))
finally:
    for sock in sockets:
        sock.close()
PY
)
read -r port ignore_port cold_port <<< "$ports"
python3 "$root/test/lib/range-http-server.py" "$port" "$dest" >"$work/server.log" 2>&1 &
server_pid=$!
base="http://127.0.0.1:$port/isos/native/v1"
ready=0
for _ in {1..30}; do
    if curl -fsS "http://127.0.0.1:$port/" -o /dev/null 2>/dev/null; then
        ready=1
        break
    fi
    sleep 0.1
done
check 'local HTTP origin responds' test "$ready" -eq 1
check 'local Range-capable origin started' kill -0 "$server_pid"

"$publish/publish-candidate.sh" "$work/one" "$dest" >/dev/null
candidate="$dest/isos/native/v1/.candidate/$v1/$(basename "$iso1")"
check 'candidate is under the flat installer namespace' test -f "$candidate"
check 'candidate has immutable cache metadata' \
    grep -q immutable "$candidate.meta.json"
check 'ISO candidate verifies by size, hash and two HTTP ranges' \
    "$publish/verify-remote.sh" "$work/one" "$base"

printf 'X' | dd of="$candidate" bs=1 seek=0 count=1 conv=notrunc status=none
reject 'tampered ISO candidate fails remote verification' \
    "$publish/verify-remote.sh" "$work/one" "$base"
"$publish/publish-candidate.sh" "$work/one" "$dest" >/dev/null

# Force an origin that persistently returns HTTP 200 to Range, then model the
# cold CDN response that returns 200 only once before correctly returning 206.
python3 "$root/test/lib/range-http-server.py" "$ignore_port" "$dest" --ignore-ranges \
    >"$work/ignored.log" 2>&1 & ignore_pid=$!
for _ in {1..30}; do
    curl -fsS "http://127.0.0.1:$ignore_port/" -o /dev/null 2>/dev/null && break
    sleep 0.1
done
check 'ignored-Range origin started' kill -0 "$ignore_pid"
reject 'persistent HTTP 200 for Range fails closed' \
    env PUBLISH_HTTP_RANGE_ATTEMPTS=2 PUBLISH_HTTP_RANGE_RETRY_DELAY=0 \
    "$publish/verify-remote.sh" "$work/one" "http://127.0.0.1:$ignore_port/isos/native/v1"
check 'ignored-Range failure reports HTTP 200' grep -q 'server ignored Range.*HTTP 200' "$work/rejected.log"

python3 "$root/test/lib/range-http-server.py" "$cold_port" "$dest" --ignore-first-ranges 1 \
    >"$work/cold.log" 2>&1 & cold_pid=$!
for _ in {1..30}; do
    curl -fsS "http://127.0.0.1:$cold_port/" -o /dev/null 2>/dev/null && break
    sleep 0.1
done
check 'cold-Range origin started' kill -0 "$cold_pid"
check 'cold origin recovers after the first ignored Range' \
    env PUBLISH_HTTP_RANGE_ATTEMPTS=4 PUBLISH_HTTP_RANGE_RETRY_DELAY=0 \
    "$publish/verify-remote.sh" "$work/one" "http://127.0.0.1:$cold_port/isos/native/v1"

"$publish/promote.sh" "${signing[@]}" "$work/one" "$base" "$dest" >"$work/promoted.log"
index_dir="$dest/isos/native/v1"
check 'first promotion reports no outgoing signed index' \
    grep -q 'No existing signed index to archive' "$work/promoted.log"
check 'signed index validates against ephemeral pubring' \
    gpgv --keyring "$pubring" "$index_dir/SHA256SUMS.gpg" "$index_dir/SHA256SUMS"
check 'both index objects carry no-store cache policy' \
    bash -c 'grep -q no-store "$1/SHA256SUMS.gpg.meta.json" && grep -q no-store "$1/SHA256SUMS.meta.json"' _ "$index_dir"
check 'public origin serves signed first ISO version' \
    "$publish/verify-published-index.sh" --pubring "$pubring" --expect-version "$v1" --attempts 1 --delay 0 "$base"
reject 'public index rejects a version not yet promoted' \
    "$publish/verify-published-index.sh" --pubring "$pubring" --expect-version "$v2" --attempts 1 --delay 0 "$base"
cp "$index_dir/SHA256SUMS.gpg" "$work/sig.bak"
printf tamper >>"$index_dir/SHA256SUMS.gpg"
reject 'public index rejects tampered signature' \
    "$publish/verify-published-index.sh" --pubring "$pubring" --attempts 1 --delay 0 "$base"
cp "$work/sig.bak" "$index_dir/SHA256SUMS.gpg"

"$publish/publish-candidate.sh" "$work/two" "$dest" >/dev/null
check 'second ISO candidate verifies' "$publish/verify-remote.sh" "$work/two" "$base"
"$publish/promote.sh" "${signing[@]}" "$work/two" "$base" "$dest" >/dev/null
check 'second promotion archives the outgoing signed ISO index' \
    test -f "$index_dir/.history/$v1/SHA256SUMS.gpg"
check 'public index serves second ISO version' \
    "$publish/verify-published-index.sh" --pubring "$pubring" --expect-version "$v2" --attempts 1 --delay 0 "$base"
reject 'missing pubring prevents promotion' \
    "$publish/promote.sh" --signing-key "$secret" --passphrase-file "$passphrase_file" \
    --pubring "$work/missing.gpg" "$work/one" "$base" "$dest"

echo "ISO publication pipeline: $pass checks passed"
