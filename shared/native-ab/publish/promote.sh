#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Phase 7 publication steps 8-15 (docs/native-ab-contracts.md §4/§7, plan
# "Atomic Publication Procedure"): promotes already-verified candidate
# objects (see verify-remote.sh) to their final immutable public names,
# generates a fresh SHA256SUMS over the bytes actually served from those
# final names (never trusting local disk), signs it, and publishes the
# signed index pair in the mandatory signature-first / manifest-last order
# with Cache-Control: no-store on both.
#
# Before overwriting an existing signed index pair, the outgoing pair is
# archived under a per-version history sub-path so withdraw.sh can restore
# it later (docs/native-ab-contracts.md's retention policy, plan "R2
# Retention And Cost Control").
#
# Signing key (never hardcoded -- docs/native-ab-contracts.md §7 "OpenPGP
# update key": private key belongs only in the protected promotion
# environment):
#   --signing-key <file>   import this OpenPGP secret-key export (e.g.
#                           .snosi-private/os-update-signing.key for
#                           rehearsal) into an ephemeral, 0700 GNUPGHOME
#                           that is removed on exit. Mutually exclusive
#                           with --gnupghome.
#   --gnupghome <dir>      use this existing GNUPGHOME as-is (key already
#                           imported); never touched or removed. Mutually
#                           exclusive with --signing-key.
#   --key-id <id>          gpg key id/fingerprint/uid to sign with, if the
#                           homedir has more than one usable secret key.
#                           Optional; gpg's default selection is used
#                           otherwise.
#   --pubring <path>       update-signing pubring used ONLY to gpgv-verify
#                           the OUTGOING signed index before archiving it
#                           (see "Archive the OUTGOING signed index pair"
#                           below) -- never used to authorize anything this
#                           run itself signs. Defaults to the committed
#                           shared/native-ab/keys/import-pubring.gpg.
#

# --purge-hook <cmd>: after a successful signature-first/manifest-last
# publish, <cmd> is invoked with the two final metadata URLs as arguments
# (SHA256SUMS.gpg then SHA256SUMS) -- the Cloudflare purge extension point
# (plan step 14-15: "Purge both metadata URLs during promotion"). No
# purge-hook runs anything by default; local rehearsal has nothing to purge.
#
# Usage: promote.sh [--signing-key <file> | --gnupghome <dir>]
#                    [--key-id <id>] [--purge-hook <cmd>] [--keep-candidate]
#                    <prepared-dir> <base-url> <dest>
#
#   prepared-dir  same prepare-native-publication.sh output dir passed to
#                 publish-candidate.sh/verify-remote.sh.
#   base-url      HTTP(S) URL of the product's "os/native/v1/<product>/
#                 x86-64" directory (same one passed to verify-remote.sh).
#                 Used to re-download both candidate objects (source of the
#                 copy-to-final step) and, after promotion, the FINAL
#                 objects (source of the signed SHA256SUMS).
#   dest          publication origin root, same addressing as publish-
#                 candidate.sh.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: promote.sh [--signing-key <file> | --gnupghome <dir>] [--key-id <id>]
                   [--purge-hook <cmd>] [--keep-candidate]
                   <prepared-dir> <base-url> <dest>
EOF
    exit 2
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=shared/native-ab/publish/publish-lib.sh
source "$SCRIPT_DIR/publish-lib.sh"

SIGNING_KEY=""
GNUPGHOME_ARG=""
KEY_ID=""
PURGE_HOOK=""
KEEP_CANDIDATE=0
PUBRING="$ROOT_DIR/shared/native-ab/keys/import-pubring.gpg"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
    --signing-key)
        SIGNING_KEY="$2"
        shift 2
        ;;
    --gnupghome)
        GNUPGHOME_ARG="$2"
        shift 2
        ;;
    --key-id)
        KEY_ID="$2"
        shift 2
        ;;
    --pubring)
        PUBRING="$2"
        shift 2
        ;;
    --purge-hook)
        PURGE_HOOK="$2"
        shift 2
        ;;
    --keep-candidate)
        KEEP_CANDIDATE=1
        shift
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
PREPARED_DIR="${POSITIONAL[0]}"
BASE_URL="${POSITIONAL[1]%/}"
DEST="${POSITIONAL[2]}"

if [[ -n "$SIGNING_KEY" && -n "$GNUPGHOME_ARG" ]]; then
    echo "Error: --signing-key and --gnupghome are mutually exclusive" >&2
    exit 1
fi
if [[ -z "$SIGNING_KEY" && -z "$GNUPGHOME_ARG" ]]; then
    echo "Error: one of --signing-key or --gnupghome is required" >&2
    exit 1
fi

for command in jq curl sha256sum gpg gpgv; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done
[[ -d "$PREPARED_DIR" ]] || { echo "Error: prepared-dir not found: $PREPARED_DIR" >&2; exit 1; }
PREPARED_DIR="$(cd "$PREPARED_DIR" && pwd)"

read_publication_info "$PREPARED_DIR"
echo "Product: $PUB_PRODUCT  Channel: $PUB_CHANNEL  Version: $PUB_VERSION"

# ---------------------------------------------------------------------------
# Signing key setup
# ---------------------------------------------------------------------------

if [[ -n "$SIGNING_KEY" ]]; then
    [[ -f "$SIGNING_KEY" ]] || { echo "Error: signing key file not found: $SIGNING_KEY" >&2; exit 1; }
    GNUPGHOME="$(mktemp -d /var/tmp/promote-gnupghome.XXXXXX)"
    chmod 700 "$GNUPGHOME"
    register_cleanup "rm -rf '$GNUPGHOME'"
    # Never echo key material; gpg --import's own stderr summary (key id,
    # uid) is the only output this produces.
    GNUPGHOME="$GNUPGHOME" gpg --batch --quiet --import "$SIGNING_KEY"
else
    [[ -d "$GNUPGHOME_ARG" ]] || { echo "Error: --gnupghome directory not found: $GNUPGHOME_ARG" >&2; exit 1; }
    GNUPGHOME="$GNUPGHOME_ARG"
fi
export GNUPGHOME

declare -a GPG_SIGN_ARGS=(--batch --yes --detach-sign)
[[ -z "$KEY_ID" ]] || GPG_SIGN_ARGS+=(--local-user "$KEY_ID")

# ---------------------------------------------------------------------------
# Step 8: copy verified candidate objects to their final immutable names.
# ---------------------------------------------------------------------------

dest_parse "$DEST"
product_dir="$(product_path "$PUB_PRODUCT")"
candidate_rel="$(candidate_subpath "$PUB_VERSION")"

WORK_DIR="$(mktemp -d /var/tmp/promote.XXXXXX)"
register_cleanup "rm -rf '$WORK_DIR'"

echo "Promoting candidate objects to final names ($product_dir/):"
mapfile -t object_names < <(candidate_object_names "$PREPARED_DIR")
[[ ${#object_names[@]} -gt 0 ]] || { echo "Error: SHA256SUMS in $PREPARED_DIR lists no objects" >&2; exit 1; }

for name in "${object_names[@]}"; do
    [[ -n "$name" ]] || continue
    echo "  $name"
    dest_copy_object "$product_dir/$candidate_rel/$name" "$product_dir/$name" \
        "public, max-age=31536000, immutable"
done

# ---------------------------------------------------------------------------
# Step 9: generate SHA256SUMS over the EXACT bytes served from the final
# names -- re-downloaded over HTTP, never trusted from local disk or from
# the copy step above (a copy could silently truncate/corrupt on some
# backend and this would still catch it, since it re-verifies what a client
# would actually receive).
# ---------------------------------------------------------------------------

final_url="$BASE_URL"
sums_new="$WORK_DIR/SHA256SUMS"
: >"$sums_new"
echo "Re-downloading final objects to generate the signed index:"
for name in "${object_names[@]}"; do
    [[ -n "$name" ]] || continue
    obj_url="$final_url/$name"
    obj_tmp="$WORK_DIR/obj-$name"
    http_get_to_file "$obj_url" "$obj_tmp" || {
        echo "Error: could not re-download promoted object from $obj_url" >&2
        exit 1
    }
    hash="$(sha256sum "$obj_tmp" | cut -d' ' -f1)"
    rm -f "$obj_tmp"
    printf '%s  %s\n' "$hash" "$name" >>"$sums_new"
    echo "  $name  $hash"
done

# ---------------------------------------------------------------------------
# Archive the OUTGOING signed index pair (if any) before it is overwritten,
# so withdraw.sh has something matched to restore. Named by the version it
# was serving, read from its own manifest.json entry so this is robust to
# manual edits (no arbitrary counter).
#
# Only archives a pair that gpgv itself accepts against $PUBRING. An outgoing
# index that does NOT verify (e.g. a previous promotion was interrupted, or
# something upstream left signature and manifest disagreeing) must never
# silently clobber a GOOD pair already sitting in .history/<version>/ from an
# earlier, valid promotion -- withdraw.sh's own refusal only protects the
# LIVE restore path, not this archive step, so this check has to happen here
# too. Skips archiving (with a warning) rather than aborting the promotion:
# the NEW version being promoted right now is not at fault for an already-
# broken outgoing index, and refusing to publish it over that would only
# compound the incident.
# ---------------------------------------------------------------------------

if dest_object_exists "$product_dir/SHA256SUMS" && dest_object_exists "$product_dir/SHA256SUMS.gpg"; then
    old_sums="$WORK_DIR/old-SHA256SUMS"
    old_sig="$WORK_DIR/old-SHA256SUMS.gpg"
    if dest_read_object "$product_dir/SHA256SUMS" "$old_sums" && dest_read_object "$product_dir/SHA256SUMS.gpg" "$old_sig"; then
        old_version="$(grep -oE "${PUB_CHANNEL}_[0-9]{14}\\.manifest\\.json" "$old_sums" |
            sed -E "s/^${PUB_CHANNEL}_([0-9]{14})\\.manifest\\.json\$/\\1/" | head -1)"
        if [[ -z "$old_version" || "$old_version" == "$PUB_VERSION" ]]; then
            echo "Outgoing index already advertises $PUB_VERSION (or is unparseable); nothing to archive."
        elif [[ -s "$PUBRING" ]] && ! gpgv --keyring "$PUBRING" "$old_sig" "$old_sums" 2>/dev/null; then
            echo "WARNING: outgoing index (claims version $old_version) does not verify against $PUBRING -- skipping archival rather than overwriting a possibly-good .history/$old_version/ entry with a broken one. The NEW promotion below is unaffected." >&2
        else
            echo "Archiving outgoing signed index (version $old_version) to $(history_subpath "$old_version")/"
            history_rel="$product_dir/$(history_subpath "$old_version")"
            dest_copy_object "$product_dir/SHA256SUMS" "$history_rel/SHA256SUMS"
            dest_copy_object "$product_dir/SHA256SUMS.gpg" "$history_rel/SHA256SUMS.gpg"
        fi
    fi
else
    echo "No existing signed index to archive (first promotion for $PUB_PRODUCT)."
fi

# ---------------------------------------------------------------------------
# Step 10-13: sign, then upload signature FIRST, manifest LAST, both
# Cache-Control: no-store. This ordering is what makes the short disagreement
# window fail closed (plan: "an old manifest and new detached signature
# disagree" -- never the reverse, an old signature covering a manifest that
# has already changed).
# ---------------------------------------------------------------------------

sig_new="$WORK_DIR/SHA256SUMS.gpg"
gpg "${GPG_SIGN_ARGS[@]}" -o "$sig_new" "$sums_new"

echo "Uploading SHA256SUMS.gpg (signature) FIRST..."
dest_put_file "$sig_new" "$product_dir/SHA256SUMS.gpg" "no-store"
echo "Uploading SHA256SUMS (manifest) LAST..."
dest_put_file "$sums_new" "$product_dir/SHA256SUMS" "no-store"

# ---------------------------------------------------------------------------
# Candidate cleanup (best-effort tidiness; not required for correctness --
# the final objects above are independent copies, and retention policy for
# candidates is out of scope here).
# ---------------------------------------------------------------------------

if [[ "$KEEP_CANDIDATE" == 0 ]]; then
    case "$DEST_KIND" in
    local)
        rm -rf "${DEST_LOCAL_ROOT:?}/$product_dir/$candidate_rel"
        ;;
    rclone)
        rclone purge "$DEST_RCLONE_TARGET/$product_dir/$candidate_rel" 2>/dev/null || true
        ;;
    esac
fi

# ---------------------------------------------------------------------------
# Step 14-15: Cloudflare purge extension point. Documented no-op locally --
# there is nothing to purge against a plain directory/http.server origin.
# ---------------------------------------------------------------------------

sig_url="$BASE_URL/SHA256SUMS.gpg"
sums_url="$BASE_URL/SHA256SUMS"
if [[ -n "$PURGE_HOOK" ]]; then
    echo "Running purge hook: $PURGE_HOOK $sig_url $sums_url"
    eval "$PURGE_HOOK" "$sig_url" "$sums_url"
else
    echo "No --purge-hook given; nothing purged (expected for local rehearsal -- see docs/native-ab-publication.md for the real Cloudflare purge command)."
fi

echo "Promoted $PUB_CHANNEL $PUB_VERSION: $sig_url then $sums_url"
