#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Verify that an image carries org.opencontainers.image.version as both the
# OCI manifest annotation and the image config label, and that both equal the
# expected version (frostyard/snosi#1125).
#
# bootc reads the image version from the manifest annotation. A config label
# alone leaves `bootc status` reporting a null version, so both are required.
#
# Usage: check-image-version.sh IMAGE_REF EXPECTED_VERSION [AUTH_FILE]
#
# IMAGE_REF is a skopeo transport reference, for example
#   containers-storage:ghcr.io/frostyard/snow:20261024123456
#   docker://ghcr.io/frostyard/snow@sha256:...
set -euo pipefail

readonly VERSION_KEY="org.opencontainers.image.version"
readonly OCI_INDEX_MEDIA_TYPE="application/vnd.oci.image.index.v1+json"
readonly DOCKER_MANIFEST_LIST_MEDIA_TYPE="application/vnd.docker.distribution.manifest.list.v2+json"

usage() {
    echo "Usage: $(basename "$0") IMAGE_REF EXPECTED_VERSION [AUTH_FILE]" >&2
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
    usage
    exit 2
fi
IMAGE_REF="$1"
EXPECTED_VERSION="$2"
AUTH_FILE="${3:-}"
if [[ -z $EXPECTED_VERSION ]]; then
    usage
    exit 2
fi

skopeo_inspect() { # raw|config
    local mode=$1
    if [[ -n $AUTH_FILE ]]; then
        skopeo inspect "--$mode" --authfile "$AUTH_FILE" "$IMAGE_REF"
    else
        skopeo inspect "--$mode" "$IMAGE_REF"
    fi
}

if ! manifest=$(skopeo_inspect raw); then
    echo "::error::cannot read the manifest of $IMAGE_REF" >&2
    exit 1
fi

media_type=$(jq -r '.mediaType // ""' <<<"$manifest" 2>/dev/null) || media_type=""
if [[ $media_type == "$OCI_INDEX_MEDIA_TYPE" || $media_type == "$DOCKER_MANIFEST_LIST_MEDIA_TYPE" ]] ||
    jq -e 'has("manifests")' <<<"$manifest" >/dev/null 2>&1; then
    echo "::error::$IMAGE_REF is an image index or manifest list; expected a single image manifest" >&2
    exit 1
fi

if ! jq -e --arg key "$VERSION_KEY" --arg value "$EXPECTED_VERSION" \
    '.annotations[$key] == $value' <<<"$manifest" >/dev/null 2>&1; then
    observed=$(jq -r --arg key "$VERSION_KEY" '.annotations[$key] // "<missing>"' <<<"$manifest" 2>/dev/null) ||
        observed="<unreadable>"
    echo "::error::$IMAGE_REF has manifest annotation $VERSION_KEY '$observed', expected '$EXPECTED_VERSION'" >&2
    exit 1
fi

if ! config=$(skopeo_inspect config); then
    echo "::error::cannot read the config of $IMAGE_REF" >&2
    exit 1
fi

if ! jq -e --arg key "$VERSION_KEY" --arg value "$EXPECTED_VERSION" \
    '.config.Labels[$key] == $value' <<<"$config" >/dev/null 2>&1; then
    observed=$(jq -r --arg key "$VERSION_KEY" '.config.Labels[$key] // "<missing>"' <<<"$config" 2>/dev/null) ||
        observed="<unreadable>"
    echo "::error::$IMAGE_REF has config label $VERSION_KEY '$observed', expected '$EXPECTED_VERSION'" >&2
    exit 1
fi

echo "image version annotation and label: $EXPECTED_VERSION"
