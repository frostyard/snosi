#!/usr/bin/env bash
# verify-published-index.sh — confirm the PUBLIC origin serves a valid, current
# SHA256SUMS + SHA256SUMS.gpg matched pair after a promotion.
#
# This is the independent "served bytes" check the checklist demands ("do not
# treat a purge API 200 alone as success", §5 / runbook §14-15). It fetches the
# two metadata files a real client would fetch -- the PLAIN URLs, no cache-buster
# -- with a revalidation hint, verifies the detached signature against the
# shipped update pubring, and (optionally) asserts the promoted version is the
# one being served. It retries to absorb edge-purge propagation; persistent
# staleness or a mismatch after the retry budget is a hard failure (the whole
# point of the check).
#
# It does NOT prove a *different geographic region* is fresh -- a true
# multi-region check remains a manual/edge-analytics step -- but it catches the
# common, dangerous cases: a stale cached pair, a sig/manifest mismatch, or an
# unreachable origin.
#
# Usage: verify-published-index.sh [--pubring <path>] [--expect-version <v>]
#                                  [--attempts N] [--delay S] <base-url>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PUBRING="$ROOT_DIR/shared/native-ab/keys/import-pubring.gpg"
EXPECT_VERSION=""
ATTEMPTS=6
DELAY=5

usage() {
    echo "Usage: verify-published-index.sh [--pubring <path>] [--expect-version <v>] [--attempts N] [--delay S] <base-url>" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --pubring) PUBRING="$2"; shift 2 ;;
    --expect-version) EXPECT_VERSION="$2"; shift 2 ;;
    --attempts) ATTEMPTS="$2"; shift 2 ;;
    --delay) DELAY="$2"; shift 2 ;;
    -h | --help) usage ;;
    --) shift; break ;;
    -*) echo "Error: unknown option: $1" >&2; usage ;;
    *) break ;;
    esac
done
[[ $# -eq 1 ]] || usage
BASE_URL="${1%/}"

for cmd in curl gpgv; do
    command -v "$cmd" >/dev/null || { echo "Error: required command not found: $cmd" >&2; exit 1; }
done
[[ -s "$PUBRING" ]] || { echo "Error: pubring not found or empty: $PUBRING" >&2; exit 1; }
[[ "$EXPECT_VERSION" == "" || "$EXPECT_VERSION" =~ ^[0-9]{14}$ ]] || { echo "Error: --expect-version must be 14 digits" >&2; exit 1; }

WORK="$(mktemp -d /var/tmp/verify-published-index.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

sums_url="$BASE_URL/SHA256SUMS"
sig_url="$BASE_URL/SHA256SUMS.gpg"

# A revalidation hint so a shared/local cache does not answer for us; the object
# itself is no-store, so a correctly configured edge always serves origin.
fetch() { # url dest
    curl -fsS --max-time 60 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' -o "$2" "$1"
}

attempt=1
last_err=""
while (( attempt <= ATTEMPTS )); do
    err=""
    if ! fetch "$sig_url" "$WORK/SHA256SUMS.gpg"; then
        err="could not fetch $sig_url"
    elif ! fetch "$sums_url" "$WORK/SHA256SUMS"; then
        err="could not fetch $sums_url"
    elif ! gpgv --keyring "$PUBRING" "$WORK/SHA256SUMS.gpg" "$WORK/SHA256SUMS" >/dev/null 2>&1; then
        err="served SHA256SUMS is not validly signed by the shipped pubring (stale/mismatched pair?)"
    elif [[ -n "$EXPECT_VERSION" ]] && ! grep -qE "_${EXPECT_VERSION}[._]" "$WORK/SHA256SUMS"; then
        err="served SHA256SUMS does not advertise version $EXPECT_VERSION (stale index still cached?)"
    else
        echo "OK: $BASE_URL serves a valid signed SHA256SUMS${EXPECT_VERSION:+ for version $EXPECT_VERSION} (attempt $attempt/$ATTEMPTS)"
        exit 0
    fi
    last_err="$err"
    echo "attempt $attempt/$ATTEMPTS: $err" >&2
    (( attempt < ATTEMPTS )) && sleep "$DELAY"
    attempt=$(( attempt + 1 ))
done

echo "Error: public index verification failed after $ATTEMPTS attempts: $last_err" >&2
exit 1
