#!/usr/bin/env bash
# cloudflare-purge.sh — purge specific URLs from the Cloudflare edge cache.
#
# Invoked by promote.sh / withdraw.sh via --purge-hook with the exact metadata
# URLs to purge, signature first (SHA256SUMS.gpg then SHA256SUMS). The
# cache-bypass rule plus the no-store Cache-Control header those two files carry
# already keep them out of cache; this purge is belt-and-suspenders for an edge
# that cached them before the rule existed, or during rule propagation.
#
# A 200/`success:true` from this API means the purge was ACCEPTED, not that the
# edge is already serving fresh bytes -- verify-published-index.sh is the
# independent served-bytes check (checklist §5 / runbook §14-15: "do not treat
# an API 200 alone as success").
#
# Required env:
#   CF_ZONE_ID    Cloudflare zone id for repository.frostyard.org
#   CF_API_TOKEN  API token with the "Zone.Cache Purge" permission on that zone
# Optional env:
#   CF_API_BASE   API base (default https://api.cloudflare.com/client/v4);
#                 override to a stub endpoint for testing.
#
# Usage: cloudflare-purge.sh <url> [<url> ...]
set -euo pipefail

usage() {
    echo "Usage: cloudflare-purge.sh <url> [<url> ...]" >&2
    exit 2
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || usage
[[ $# -ge 1 ]] || usage
for u in "$@"; do
    [[ "$u" == https://* || "$u" == http://* ]] || { echo "Error: not an http(s) URL: $u" >&2; exit 1; }
done

: "${CF_ZONE_ID:?CF_ZONE_ID is required}"
: "${CF_API_TOKEN:?CF_API_TOKEN is required}"
CF_API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"

for cmd in curl jq; do
    command -v "$cmd" >/dev/null || { echo "Error: required command not found: $cmd" >&2; exit 1; }
done

# Cloudflare expects {"files": ["url1", "url2", ...]}. Build it with jq so URLs
# are correctly JSON-escaped; the token is only ever passed in the Authorization
# header, never echoed.
files_json="$(printf '%s\n' "$@" | jq -R . | jq -s '{files: .}')"

resp="$(curl -fsS --max-time 30 -X POST "${CF_API_BASE}/zones/${CF_ZONE_ID}/purge_cache" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$files_json")" || { echo "Error: Cloudflare purge request failed (curl)" >&2; exit 1; }

if ! printf '%s' "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "Error: Cloudflare purge was not accepted:" >&2
    printf '%s' "$resp" | jq -c '.errors // .' >&2 2>/dev/null || printf '%s\n' "$resp" >&2
    exit 1
fi

echo "Cloudflare purge accepted for $# URL(s)."
