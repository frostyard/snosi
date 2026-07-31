#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

REPOSITORY=${1:?Usage: $0 REPOSITORY IMAGE CURRENT_TAG OUTPUT_FILE}
IMAGE=${2:?Usage: $0 REPOSITORY IMAGE CURRENT_TAG OUTPUT_FILE}
CURRENT=${3:?Usage: $0 REPOSITORY IMAGE CURRENT_TAG OUTPUT_FILE}
OUTPUT=${4:?Usage: $0 REPOSITORY IMAGE CURRENT_TAG OUTPUT_FILE}

[[ $REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo "Error: invalid repository: $REPOSITORY" >&2; exit 1;
}
[[ $IMAGE =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo "Error: invalid image: $IMAGE" >&2; exit 1;
}
[[ $CURRENT =~ ^[0-9]{14}$ ]] || {
    echo "Error: invalid current Snow tag: $CURRENT" >&2; exit 1;
}
for command in gh oras jq; do
    command -v "$command" >/dev/null || { echo "Error: missing $command" >&2; exit 1; }
done

if ! release_bodies=$(gh api --paginate "/repos/$REPOSITORY/releases" --jq '.[].body // ""'); then
    echo "Error: failed to enumerate GitHub releases" >&2
    exit 1
fi

while IFS= read -r marker; do
    tag=${marker#<!-- snow-tag: }
    tag=${tag% -->}
    [[ $tag < $CURRENT ]] || continue

    if ! digest=$(oras resolve "$IMAGE:$tag"); then
        echo "Warning: failed to resolve released Snow tag $tag" >&2
        continue
    fi
    if [[ ! $digest =~ ^sha256:[A-Fa-f0-9]{64}$ ]]; then
        echo "Warning: released Snow tag $tag resolved to an invalid digest" >&2
        continue
    fi
    if ! discovery=$(oras discover --format json "$IMAGE@$digest"); then
        echo "Warning: failed to discover referrers for released Snow tag $tag" >&2
        continue
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"$discovery"; then
        echo "Warning: released Snow tag $tag returned malformed discovery JSON" >&2
        continue
    fi
    if ! jq -e '[.referrers[]? | select(.artifactType == "application/vnd.syft+json")] | length > 0' >/dev/null <<<"$discovery"; then
        echo "Warning: released Snow tag $tag has no Syft SBOM referrer" >&2
        continue
    fi

    printf 'previous=%s\ncurrent=%s\n' "$tag" "$CURRENT" >"$OUTPUT"
    exit 0
done < <(grep -oE '<!-- snow-tag: [0-9]{14} -->' <<<"$release_bodies")

printf 'skip=true\n' >"$OUTPUT"
echo "Warning: no prior released Snow tag with a Syft SBOM was found; skipping release" >&2
