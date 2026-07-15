#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Withdrawal (plan "R2 Retention And Cost Control": "To withdraw a bad
# release, restore the previous SHA256SUMS and its exact matching
# SHA256SUMS.gpg using the same signature-first, manifest-last sequence,
# then purge both metadata URLs"). Restores an archived signed index pair
# that promote.sh saved before overwriting it (see promote.sh's "Archive the
# OUTGOING signed index pair" step) back to the live, currently-served
# names.
#
# The archived pair is gpgv-verified against the update pubring BEFORE
# anything live is touched: withdraw refuses outright if the pair does not
# cryptographically match (a corrupted archive, or one manually tampered
# with, must never be restored as if it were trustworthy). This never
# creates a NEW signature -- it only replays an already-signed pair, exactly
# per the plan's "restore ... using the same signature-first, manifest-last
# sequence" (no --signing-key needed).
#
# Note (plan): withdrawal only changes which index the update channel
# advertises. It does not delete or modify the immutable versioned objects
# for ANY version -- those remain available under their own frozen names for
# retention/incident-response per docs/native-ab-contracts.md §13. Systems
# already running the withdrawn version are unaffected; per the plan, they
# need a higher-version repair release, never a server-side downgrade.
#
# Usage: withdraw.sh [--pubring <path>] [--purge-hook <cmd>]
#                     <product> <version> <dest>
#
#   product   e.g. "cayo" (the ImageId, docs/native-ab-contracts.md §1).
#   version   the 14-digit version whose archived signed index pair
#             (promote.sh's ".history/<version>/") should become current
#             again.
#   dest      publication origin root, same addressing as publish-
#             candidate.sh / promote.sh.
set -euo pipefail

usage() {
    echo "Usage: $0 [--pubring <path>] [--purge-hook <cmd>] <product> <version> <dest>" >&2
    exit 2
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=shared/native-ab/publish/publish-lib.sh
source "$SCRIPT_DIR/publish-lib.sh"

PUBRING="$ROOT_DIR/shared/native-ab/keys/import-pubring.gpg"
PURGE_HOOK=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
    --pubring)
        PUBRING="$2"
        shift 2
        ;;
    --purge-hook)
        PURGE_HOOK="$2"
        shift 2
        ;;
    -h | --help)
        usage
        ;;
    --)
        shift
        break
        ;;
    -*)
        echo "Error: unknown option: $1" >&2
        usage
        ;;
    *)
        POSITIONAL+=("$1")
        shift
        ;;
    esac
done
POSITIONAL+=("$@")
[[ ${#POSITIONAL[@]} -eq 3 ]] || usage
PRODUCT="${POSITIONAL[0]}"
VERSION="${POSITIONAL[1]}"
DEST="${POSITIONAL[2]}"

version_regex='^[0-9]{14}$'
[[ "$VERSION" =~ $version_regex ]] || {
    echo "Error: version '$VERSION' does not match the frozen grammar $version_regex (docs/native-ab-contracts.md §2)" >&2
    exit 1
}

command -v gpgv >/dev/null || { echo "Error: required command not found: gpgv" >&2; exit 1; }
[[ -s "$PUBRING" ]] || { echo "Error: pubring not found or empty: $PUBRING" >&2; exit 1; }

dest_parse "$DEST"
product_dir="$(product_path "$PRODUCT")"
history_rel="$product_dir/$(history_subpath "$VERSION")"

echo "Withdrawing to archived version $VERSION for product $PRODUCT ($DEST -> $product_dir/)"

dest_object_exists "$history_rel/SHA256SUMS" || {
    echo "Error: no archived SHA256SUMS at $history_rel/ -- was $VERSION ever promoted-over (i.e. is there a later promotion whose promote.sh run archived it)?" >&2
    exit 1
}
dest_object_exists "$history_rel/SHA256SUMS.gpg" || {
    echo "Error: archived SHA256SUMS exists at $history_rel/ but SHA256SUMS.gpg does not -- refusing an incomplete pair" >&2
    exit 1
}

WORK_DIR="$(mktemp -d /var/tmp/withdraw.XXXXXX)"
register_cleanup "rm -rf '$WORK_DIR'"

dest_read_object "$history_rel/SHA256SUMS" "$WORK_DIR/SHA256SUMS"
dest_read_object "$history_rel/SHA256SUMS.gpg" "$WORK_DIR/SHA256SUMS.gpg"

# ---------------------------------------------------------------------------
# Refuse outright unless the archived pair is a cryptographically MATCHED
# pair against the trusted pubring. This is the whole point of withdraw.sh
# existing as a separate, careful step instead of a plain file copy.
# ---------------------------------------------------------------------------

if ! gpgv --keyring "$PUBRING" "$WORK_DIR/SHA256SUMS.gpg" "$WORK_DIR/SHA256SUMS" 2>"$WORK_DIR/gpgv.log"; then
    echo "Error: archived pair for $VERSION at $history_rel/ FAILS signature verification against $PUBRING -- refusing to restore a mismatched/corrupted pair" >&2
    sed 's/^/  gpgv: /' "$WORK_DIR/gpgv.log" >&2
    exit 1
fi
echo "Archived pair verified against $PUBRING"

if ! grep -qE "_${VERSION}[._]" "$WORK_DIR/SHA256SUMS"; then
    echo "Error: archived SHA256SUMS at $history_rel/ does not appear to mention version $VERSION -- refusing (wrong history entry?)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Restore live: signature FIRST, manifest LAST (same ordering guarantee as
# promote.sh, for the same reason).
# ---------------------------------------------------------------------------

echo "Restoring SHA256SUMS.gpg (signature) FIRST..."
dest_put_file "$WORK_DIR/SHA256SUMS.gpg" "$product_dir/SHA256SUMS.gpg" "no-store"
echo "Restoring SHA256SUMS (manifest) LAST..."
dest_put_file "$WORK_DIR/SHA256SUMS" "$product_dir/SHA256SUMS" "no-store"

if [[ -n "$PURGE_HOOK" ]]; then
    sig_ref="$product_dir/SHA256SUMS.gpg"
    sums_ref="$product_dir/SHA256SUMS"
    echo "Running purge hook: $PURGE_HOOK $sig_ref $sums_ref"
    eval "$PURGE_HOOK" "$sig_ref" "$sums_ref"
else
    echo "No --purge-hook given; nothing purged (see docs/native-ab-publication.md for the real Cloudflare purge command)."
fi

echo "Withdrew to $VERSION for $PRODUCT"
