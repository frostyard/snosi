#!/usr/bin/env bash
# Verify that the stable installer URL redirects to the immutable ISO named by
# the promoted SHA256SUMS. This is discovery-path validation only; the adjacent
# verify-published-index.sh performs the OpenPGP trust check first.
set -euo pipefail

usage() {
    echo "Usage: $0 <stable-url> <expected-version>" >&2
    exit 2
}

[[ $# -eq 2 ]] || usage
STABLE_URL="$1"
EXPECTED_VERSION="$2"

[[ "$STABLE_URL" == https://* || "$STABLE_URL" == http://* ]] || { echo "Error: stable URL must be HTTP(S)" >&2; exit 1; }
[[ "$EXPECTED_VERSION" =~ ^[0-9]{14}$ ]] || { echo "Error: expected version must be exactly 14 digits" >&2; exit 1; }
command -v curl >/dev/null || { echo "Error: curl is required" >&2; exit 1; }

WORK="$(mktemp -d /var/tmp/verify-installer-redirect.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

expected_name="snosi-native-installer_${EXPECTED_VERSION}_x86-64.iso"
base_url="${STABLE_URL%/*}"
expected_location="$base_url/$expected_name"

status="$(curl -sS --max-time 60 -D "$WORK/headers" -o /dev/null -w '%{http_code}' "$STABLE_URL")"
[[ "$status" == 302 ]] || { echo "Error: $STABLE_URL returned HTTP $status, expected 302" >&2; exit 1; }

location="$(awk 'BEGIN {IGNORECASE=1} /^Location:/ {sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0} END {print value}' "$WORK/headers")"
[[ "$location" == "$expected_location" ]] || {
    echo "Error: redirect Location is '$location', expected '$expected_location'" >&2
    exit 1
}

cache_control="$(awk 'BEGIN {IGNORECASE=1} /^Cache-Control:/ {sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0} END {print value}' "$WORK/headers")"
[[ "${cache_control,,}" == *no-store* ]] || { echo "Error: redirect lacks Cache-Control: no-store (got '$cache_control')" >&2; exit 1; }

curl -fsSI --max-time 60 "$location" >/dev/null || { echo "Error: immutable ISO is not reachable: $location" >&2; exit 1; }
curl -fsS --max-time 60 -o "$WORK/SHA256SUMS" "$base_url/SHA256SUMS"

awk -v name="$expected_name" '
    $2 == name && length($1) == 64 && $1 !~ /[^0-9a-f]/ {matches++}
    END {exit matches == 1 ? 0 : 1}
' "$WORK/SHA256SUMS" || {
    echo "Error: $base_url/SHA256SUMS does not contain exactly one canonical entry for $expected_name" >&2
    exit 1
}

echo "OK: $STABLE_URL redirects without caching to the promoted ISO $expected_name (discovery only; verify-published-index.sh authenticates the index)"
