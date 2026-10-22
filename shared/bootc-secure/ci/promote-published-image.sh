#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=test/lib/bootc-secure-assertions.sh
source "$ROOT_DIR/test/lib/bootc-secure-assertions.sh"

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
    "docker://$IMAGE@$EXPECTED_DIGEST" "docker://$IMAGE:latest"

latest_digest=$(skopeo inspect --authfile "$AUTH_FILE" \
    --format '{{.Digest}}' "docker://$IMAGE:latest")
if [[ $latest_digest != "$EXPECTED_DIGEST" ]]; then
    printf 'latest resolved to %s instead of %s\n' \
        "$latest_digest" "$EXPECTED_DIGEST" >&2
    exit 1
fi
