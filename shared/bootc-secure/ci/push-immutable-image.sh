#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=test/lib/bootc-secure-assertions.sh
source "$ROOT_DIR/test/lib/bootc-secure-assertions.sh"

if [[ $# -ne 2 ]]; then
    printf 'usage: %s IMAGE TAG\n' "${0##*/}" >&2
    exit 2
fi

IMAGE=$1
TAG=$2

if ! valid_published_image "$IMAGE"; then
    printf 'invalid secure image reference: %s\n' "$IMAGE" >&2
    exit 2
fi
if [[ ! $TAG =~ ^[0-9]{14}$ ]]; then
    printf 'invalid immutable image tag: %s\n' "$TAG" >&2
    exit 2
fi

SNOSI_PUSH_ATTEMPTS_RAW=${SNOSI_PUSH_ATTEMPTS:-3}
if [[ ! $SNOSI_PUSH_ATTEMPTS_RAW =~ ^[0-9]+$ ]]; then
    printf 'SNOSI_PUSH_ATTEMPTS must be an integer from 1 to 5\n' >&2
    exit 2
fi
SNOSI_PUSH_ATTEMPTS=$((10#$SNOSI_PUSH_ATTEMPTS_RAW))
if (( SNOSI_PUSH_ATTEMPTS < 1 || SNOSI_PUSH_ATTEMPTS > 5 )); then
    printf 'SNOSI_PUSH_ATTEMPTS must be an integer from 1 to 5\n' >&2
    exit 2
fi
SNOSI_PUSH_RETRY_DELAY_RAW=${SNOSI_PUSH_RETRY_DELAY:-30}
if [[ ! $SNOSI_PUSH_RETRY_DELAY_RAW =~ ^[0-9]+$ ]]; then
    printf 'SNOSI_PUSH_RETRY_DELAY must be an integer from 0 to 300\n' >&2
    exit 2
fi
SNOSI_PUSH_RETRY_DELAY=$((10#$SNOSI_PUSH_RETRY_DELAY_RAW))
if (( SNOSI_PUSH_RETRY_DELAY < 0 || SNOSI_PUSH_RETRY_DELAY > 300)); then
    printf 'SNOSI_PUSH_RETRY_DELAY must be an integer from 0 to 300\n' >&2
    exit 2
fi

TEMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT
DIGEST_FILE="$TEMP_DIR/image-digest"

attempt=1
while (( attempt <= SNOSI_PUSH_ATTEMPTS)); do
    rm -f "$DIGEST_FILE"

    if buildah push --compression-format=zstd:chunked \
            --digestfile="$DIGEST_FILE" \
            "$IMAGE:$TAG" "docker://$IMAGE:$TAG" >&2; then
        if [[ ! -f $DIGEST_FILE ]]; then
            printf 'buildah push succeeded without a digest file\n' >&2
            exit 1
        fi
        if ! DIGEST=$(cat "$DIGEST_FILE"); then
            printf 'failed to read push digest file\n' >&2
            exit 1
        fi
        if ! valid_published_digest "$DIGEST"; then
            printf 'invalid pushed digest: %s\n' "$DIGEST" >&2
            exit 1
        fi

        REGISTRY_ERROR="$TEMP_DIR/registry-inspect.err"
        : >"$REGISTRY_ERROR"
        if ! REGISTRY_DIGEST=$(skopeo inspect --format '{{.Digest}}' "docker://$IMAGE:$TAG" 2>"$REGISTRY_ERROR"); then
            printf 'failed to inspect registry digest\n' >&2
            cat "$REGISTRY_ERROR" >&2
            exit 1
        fi
        if [[ $REGISTRY_DIGEST != "$DIGEST" ]]; then
            printf 'registry digest %s differs from pushed digest %s\n' \
                "$REGISTRY_DIGEST" "$DIGEST" >&2
            exit 1
        fi

        printf '%s\n' "$DIGEST"
        exit 0
    fi

    printf '::warning::Push attempt %d of %d failed for %s:%s\n' \
        "$attempt" "$SNOSI_PUSH_ATTEMPTS" "$IMAGE" "$TAG" >&2

    if (( attempt == SNOSI_PUSH_ATTEMPTS)); then
        printf '::error::Push failed after %d attempt(s) for %s:%s\n' \
            "$attempt" "$IMAGE" "$TAG" >&2
        exit 1
    fi

    sleep "$((SNOSI_PUSH_RETRY_DELAY * attempt))"

    if ! SKOPEO_OUTPUT=$(skopeo inspect --raw "docker://$IMAGE:$TAG" 2>&1); then
        if grep -qi 'manifest unknown' <<<"$SKOPEO_OUTPUT"; then
            :
        else
            printf 'tag existence check failed closed: %s\n' "$SKOPEO_OUTPUT" >&2
            exit 1
        fi
    else
        printf 'tag exists after a failed push; an immutable tag must not move; see runbooks/image-publication-failure.md\n' >&2
        exit 1
    fi

    attempt=$((attempt + 1))
done
