#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Phase 7 publication step 2 (docs/native-ab-contracts.md §4/§5, plan
# "Atomic Publication Procedure" step 7): verifies every candidate object
# publish-candidate.sh uploaded is actually retrievable, byte-for-byte
# correct, and range-GET-capable, before promote.sh ever copies it to a
# final public name. Checks, per object:
#
#   1. size  -- HTTP Content-Length matches the locally-recorded size.
#   2. full GET + SHA-256 -- the ENTIRE object downloads and hashes to the
#      value in the local (pre-upload) SHA256SUMS.
#   3. >=2 representative range GETs -- byte ranges actually return the
#      correct sub-range bytes (systemd-sysupdate/curl -r resumable
#      transfers depend on this; an origin/CDN that silently ignores Range
#      and returns the full 200 body every time would otherwise pass a
#      naive check while breaking real range requests).
#
# Fails closed: the first mismatch aborts (rc=1) and prints which object and
# which check failed. Never trusts "the upload command exited 0" as proof of
# anything -- this is an independent, byte-level re-verification against the
# public-facing HTTP path.
#
# Usage: verify-remote.sh <prepared-dir> <base-url>
#
#   prepared-dir  same prepare-native-publication.sh output dir passed to
#                 publish-candidate.sh (source of expected names/sizes/
#                 hashes and of product/version). The full blobs are OPTIONAL:
#                 when an object listed in SHA256SUMS is not present locally
#                 (the CI cross-job verifier ships only publication-info.json
#                 + SHA256SUMS between jobs -- multi-GiB blobs never travel
#                 as artifacts), the object is downloaded once from the
#                 public URL, verified against SHA256SUMS, and that
#                 downloaded copy becomes the byte-level reference for the
#                 size and range checks. Every check stays fail-closed; only
#                 the source of the reference bytes changes.
#   base-url      HTTP(S) URL of the product's "os/native/v1/<product>/
#                 x86-64" directory (e.g. the local rehearsal origin, or
#                 https://repository.frostyard.org/os/native/v1/cayo/x86-64
#                 in production) -- NOT the bucket root. The candidate
#                 sub-path is appended automatically.
set -euo pipefail

usage() {
    echo "Usage: $0 <prepared-dir> <base-url>" >&2
    exit 2
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/native-ab/publish/publish-lib.sh
source "$SCRIPT_DIR/publish-lib.sh"

[[ $# -eq 2 ]] || usage
PREPARED_DIR="$1"
BASE_URL="${2%/}"

for command in jq curl sha256sum dd; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done
[[ -d "$PREPARED_DIR" ]] || { echo "Error: prepared-dir not found: $PREPARED_DIR" >&2; exit 1; }
PREPARED_DIR="$(cd "$PREPARED_DIR" && pwd)"

read_publication_info "$PREPARED_DIR"
candidate_rel="$(candidate_subpath "$PUB_VERSION")"
candidate_url="$BASE_URL/$candidate_rel"
echo "Verifying candidate objects for $PUB_CHANNEL $PUB_VERSION at $candidate_url/"

fail_count=0
check_object() { # name
    local name="$1" local_file url expected_sha256 expected_size actual_size actual_sha256
    local_file="$PREPARED_DIR/$name"
    url="$candidate_url/$name"
    expected_sha256="$(candidate_object_sha256 "$PREPARED_DIR" "$name")"

    echo "  $name"

    # 1. size (HEAD). With a local blob the reference size is the pre-upload
    # file; without one it is the downloaded reference copy's size, checked
    # after the full GET below (HEAD-vs-body consistency).
    actual_size="$(http_size "$url")" || {
        echo "    FAIL: could not fetch size (HEAD) from $url" >&2
        fail_count=$((fail_count + 1))
        return
    }

    if [[ -f "$local_file" ]]; then
        expected_size="$(stat -c %s "$local_file")"
        if [[ "$actual_size" != "$expected_size" ]]; then
            echo "    FAIL: size mismatch: expected $expected_size, got $actual_size" >&2
            fail_count=$((fail_count + 1))
            return
        fi
        echo "    ok: size $actual_size"

        # 2. full GET + sha256
        actual_sha256="$(http_get_sha256 "$url")" || {
            echo "    FAIL: full GET failed from $url" >&2
            fail_count=$((fail_count + 1))
            return
        }
    else
        # Metadata-only mode: download the object once; it becomes both the
        # subject of check 2 and the byte-level reference for check 3.
        local_file="$(mktemp /var/tmp/verify-remote-ref.XXXXXX)"
        register_cleanup "rm -f '$local_file'"
        echo "    (no local blob -- downloading reference copy)"
        http_get_to_file "$url" "$local_file" || {
            echo "    FAIL: full GET failed from $url" >&2
            fail_count=$((fail_count + 1))
            return
        }
        expected_size="$(stat -c %s "$local_file")"
        if [[ "$actual_size" != "$expected_size" ]]; then
            echo "    FAIL: HEAD Content-Length $actual_size != downloaded body size $expected_size" >&2
            fail_count=$((fail_count + 1))
            return
        fi
        echo "    ok: size $actual_size"
        actual_sha256="$(sha256sum "$local_file" | cut -d' ' -f1)"
    fi

    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        echo "    FAIL: sha256 mismatch: expected $expected_sha256, got $actual_sha256" >&2
        fail_count=$((fail_count + 1))
        return
    fi
    echo "    ok: sha256 $actual_sha256"

    # 3. >=2 representative range GETs: first 4KiB (or the whole object if
    # smaller) and a range starting past the midpoint, both compared against
    # the equivalent range read directly from the known-good local file.
    local r1_end r2_start r2_end r1_local r1_remote r2_local r2_remote
    r1_end=$(( expected_size > 4096 ? 4095 : expected_size - 1 ))
    r1_local="$(local_range_sha256 "$local_file" 0 "$r1_end")"
    r1_remote="$(http_range_sha256 "$url" 0 "$r1_end")" || {
        echo "    FAIL: range GET 0-$r1_end failed" >&2
        fail_count=$((fail_count + 1))
        return
    }
    if [[ "$r1_local" != "$r1_remote" ]]; then
        echo "    FAIL: range 0-$r1_end mismatch: expected $r1_local, got $r1_remote" >&2
        fail_count=$((fail_count + 1))
        return
    fi
    echo "    ok: range 0-$r1_end"

    if [[ "$expected_size" -gt 8192 ]]; then
        r2_start=$(( expected_size / 2 ))
        r2_end=$(( r2_start + 4095 < expected_size ? r2_start + 4095 : expected_size - 1 ))
    else
        r2_start=$(( expected_size > 1 ? expected_size / 2 : 0 ))
        r2_end=$(( expected_size - 1 ))
    fi
    r2_local="$(local_range_sha256 "$local_file" "$r2_start" "$r2_end")"
    r2_remote="$(http_range_sha256 "$url" "$r2_start" "$r2_end")" || {
        echo "    FAIL: range GET $r2_start-$r2_end failed" >&2
        fail_count=$((fail_count + 1))
        return
    }
    if [[ "$r2_local" != "$r2_remote" ]]; then
        echo "    FAIL: range $r2_start-$r2_end mismatch: expected $r2_local, got $r2_remote" >&2
        fail_count=$((fail_count + 1))
        return
    fi
    echo "    ok: range $r2_start-$r2_end"
}

count=0
while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    check_object "$name"
    count=$((count + 1))
done < <(candidate_object_names "$PREPARED_DIR")

[[ "$count" -gt 0 ]] || { echo "Error: SHA256SUMS in $PREPARED_DIR lists no objects" >&2; exit 1; }

if [[ "$fail_count" -gt 0 ]]; then
    echo "verify-remote: $fail_count/$count object(s) FAILED verification" >&2
    exit 1
fi
echo "verify-remote: all $count candidate object(s) verified OK"
