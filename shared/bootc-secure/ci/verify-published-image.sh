#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Verify a signed immutable secure image before any mutable-tag promotion.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
POLICY="$ROOT_DIR/shared/bootc-secure/tree/etc/containers/policy.json"
REGISTRIES="$ROOT_DIR/shared/bootc-secure/tree/etc/containers/registries.d/frostyard.yaml"

if [[ $# -ne 4 ]]; then
    printf 'usage: %s IMAGE VERSION_TAG EXPECTED_DIGEST LOCAL_REF\n' "${0##*/}" >&2
    exit 2
fi

IMAGE=$1
VERSION_TAG=$2
EXPECTED_DIGEST=$3
LOCAL_REF=$4

if [[ ! $IMAGE =~ ^ghcr\.io/frostyard/(cayo|snow|snowfield)$ ]]; then
    printf 'invalid secure image reference\n' >&2
    exit 2
fi

IMAGE_NAME=${BASH_REMATCH[1]}
if [[ ! $VERSION_TAG =~ ^[0-9]{14}$ ]] ||
        [[ ! $EXPECTED_DIGEST =~ ^sha256:[a-f0-9]{64}$ ]]; then
    printf 'invalid secure image reference\n' >&2
    exit 2
fi

if [[ ! $LOCAL_REF =~ ^localhost/snosi-verified-${IMAGE_NAME}:${VERSION_TAG}$ ]]; then
    printf 'invalid local verification reference\n' >&2
    exit 2
fi

inspection=$(skopeo inspect "docker://$IMAGE@$EXPECTED_DIGEST")
jq -e --arg digest "$EXPECTED_DIGEST" '
    .Digest == $digest and
    .Labels["io.snosi.bootc.secureboot-capable"] == "true" and
    .Labels["io.snosi.bootc.secureboot-assembly"] == "bootc-1.16.3-storage-digest-v1"
' <<<"$inspection" >/dev/null

work=$(mktemp -d)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

jq --arg key "$ROOT_DIR/cosign.pub" '
    .transports.docker |= with_entries(.value |= map(.keyPath = $key))
' "$POLICY" >"$work/policy.json"
mkdir -p "$work/registries.d"
cp "$REGISTRIES" "$work/registries.d/frostyard.yaml"

cosign verify --key "$ROOT_DIR/cosign.pub" "$IMAGE@$EXPECTED_DIGEST" >/dev/null
sudo skopeo copy --policy "$work/policy.json" --registries.d "$work/registries.d" \
    "docker://$IMAGE@$EXPECTED_DIGEST" "containers-storage:$LOCAL_REF"
