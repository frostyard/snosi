#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Move the user-facing forky tag of a product repository to an already
# published, verified forky test image digest (ADR-0040).
#
# Usage: promote-forky-image.sh IMAGE EXPECTED_DIGEST AUTH_FILE
#
# The caller verifies the signature and the image version of
# IMAGE@EXPECTED_DIGEST first. This helper writes exactly 1 tag, IMAGE:forky,
# and never latest or any other tag; promote-published-image.sh moves latest,
# and only for trixie (ADR-0038).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=test/lib/bootc-secure-assertions.sh
source "$ROOT_DIR/test/lib/bootc-secure-assertions.sh"
# shellcheck source=shared/bootc-secure/compatibility.sh
source "$ROOT_DIR/shared/bootc-secure/compatibility.sh"

readonly FORKY_TAG=forky

# Only forky moves the forky tag. A trixie image must never reach it.
SUITE=$(snosi_bootc_secure_suite) || exit 2
if [[ $SUITE != forky ]]; then
    printf 'refusing to move the forky tag to a %s image: only forky moves the forky tag (ADR-0040)\n' \
        "$SUITE" >&2
    exit 2
fi

if [[ $# -ne 3 ]]; then
    printf 'usage: %s IMAGE EXPECTED_DIGEST AUTH_FILE\n' "${0##*/}" >&2
    exit 2
fi

IMAGE=$1
EXPECTED_DIGEST=$2
AUTH_FILE=$3

if ! valid_published_image "$IMAGE" ||
        ! valid_published_digest "$EXPECTED_DIGEST"; then
    printf 'invalid secure image reference\n' >&2
    exit 2
fi
if [[ ! -f $AUTH_FILE || ${AUTH_FILE##*/} != config.json ]]; then
    printf 'registry auth must be a regular config.json file\n' >&2
    exit 2
fi

skopeo copy --all \
    --src-authfile "$AUTH_FILE" --dest-authfile "$AUTH_FILE" \
    "docker://$IMAGE@$EXPECTED_DIGEST" "docker://$IMAGE:$FORKY_TAG"

forky_digest=$(skopeo inspect --authfile "$AUTH_FILE" \
    --format '{{.Digest}}' "docker://$IMAGE:$FORKY_TAG")
if [[ $forky_digest != "$EXPECTED_DIGEST" ]]; then
    printf '%s resolved to %s instead of %s\n' \
        "$FORKY_TAG" "$forky_digest" "$EXPECTED_DIGEST" >&2
    exit 1
fi
