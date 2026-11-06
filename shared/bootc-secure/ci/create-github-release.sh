#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Create the GitHub release for a built image tag.
#
# GITHUB_TOKEN cannot create a tag when the workflow files at that commit
# differ from the workflow files on the default branch: the job token has no
# `workflows` permission and cannot get one. When gh reports exactly that 403
# and workflow files differ, the release is retried once with FALLBACK_TOKEN
# (the WORKFLOW_PAT secret). Every other failure fails the job.
set -euo pipefail

usage='Usage: create-github-release.sh REPOSITORY TAG TITLE TARGET_SHA NOTES_FILE DEFAULT_BRANCH'

REPOSITORY=${1:?$usage}
TAG=${2:?$usage}
TITLE=${3:?$usage}
TARGET_SHA=${4:?$usage}
NOTES_FILE=${5:?$usage}
DEFAULT_BRANCH=${6:?$usage}

for command in gh jq; do
    command -v "$command" >/dev/null || {
        echo "Error: missing $command" >&2; exit 1;
    }
done

[[ $REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo "Error: invalid repository: $REPOSITORY" >&2; exit 1;
}
[[ $TAG =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+$ ]] || {
    echo "Error: invalid release tag: $TAG" >&2; exit 1;
}
[[ $TARGET_SHA =~ ^[0-9a-f]{40}$ ]] || {
    echo "Error: invalid target commit: $TARGET_SHA" >&2; exit 1;
}
[[ -n $TITLE ]] || { echo "Error: empty release title" >&2; exit 1; }
[[ -f $NOTES_FILE && -r $NOTES_FILE ]] || {
    echo "Error: release notes file is not readable: $NOTES_FILE" >&2; exit 1;
}
[[ $DEFAULT_BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] || {
    echo "Error: invalid default branch: $DEFAULT_BRANCH" >&2; exit 1;
}
[[ -n ${GH_TOKEN:-} ]] || { echo "Error: GH_TOKEN is empty" >&2; exit 1; }
FALLBACK_TOKEN=${FALLBACK_TOKEN:-}

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

stderr_file="$work/stderr"

show_stderr() { # file
    [[ -s $1 ]] || return 0
    cat "$1" >&2
}

create_release() { # token
    local status=0
    GH_TOKEN=$1 gh release create "$TAG" \
        --repo "$REPOSITORY" \
        --target "$TARGET_SHA" \
        --title "$TITLE" \
        --notes-file "$NOTES_FILE" 2>"$stderr_file" || status=$?
    show_stderr "$stderr_file"
    return "$status"
}

status=0
create_release "$GH_TOKEN" || status=$?

if [[ $status -ne 0 ]]; then
    if ! grep -Fq 'HTTP 403: Resource not accessible by integration' "$stderr_file"; then
        echo "Error: gh release create failed with exit code $status" >&2
        exit "$status"
    fi

    # Only this exact 403 can come from the missing `workflows` permission.
    # Decide from the actual compare, never from a guess.
    compare_status=0
    differences=$(GH_TOKEN=$GH_TOKEN gh api \
        "repos/$REPOSITORY/compare/$TARGET_SHA...$DEFAULT_BRANCH" \
        --jq '.files[]?.filename' 2>"$work/compare-stderr") || compare_status=$?
    if [[ $compare_status -ne 0 ]]; then
        show_stderr "$work/compare-stderr"
        echo "::error::Could not compare $TARGET_SHA with $DEFAULT_BRANCH to classify the HTTP 403 from gh release create." >&2
        exit 1
    fi

    workflow_files=$(grep -E '^[.]github/workflows/' <<<"$differences" || true)
    if [[ -z $workflow_files ]]; then
        echo "::error::gh release create failed with HTTP 403 but no workflow file differs between $TARGET_SHA and $DEFAULT_BRANCH. This is not the workflow-file case; check the token and the repository settings (Settings > Actions > General > Workflow permissions, and any tag ruleset that blocks tag creation)." >&2
        exit 1
    fi

    names=${workflow_files//$'\n'/, }

    if [[ -z $FALLBACK_TOKEN ]]; then
        echo "::error::GITHUB_TOKEN cannot create tag $TAG because these workflow files differ between $TARGET_SHA and $DEFAULT_BRANCH: $names. Set the WORKFLOW_PAT secret (a token with the workflow scope) so this release can use it." >&2
        exit 1
    fi

    echo "::warning::Workflow files differ between $TARGET_SHA and $DEFAULT_BRANCH: $names. Creating the release with WORKFLOW_PAT instead of GITHUB_TOKEN." >&2

    status=0
    create_release "$FALLBACK_TOKEN" || status=$?
    if [[ $status -ne 0 ]]; then
        echo "Error: gh release create failed with WORKFLOW_PAT (exit code $status)" >&2
        exit "$status"
    fi
fi

# A tag that already existed keeps its old commit, so always check the target.
verify_status=0
resolved=$(GH_TOKEN=$GH_TOKEN gh api "repos/$REPOSITORY/commits/$TAG" \
    --jq .sha 2>"$work/verify-stderr") || verify_status=$?
if [[ $verify_status -ne 0 ]]; then
    show_stderr "$work/verify-stderr"
    echo "::error::Could not resolve tag $TAG in $REPOSITORY." >&2
    exit 1
fi
if [[ $resolved != "$TARGET_SHA" ]]; then
    echo "::error::Tag $TAG resolves to $resolved, not the built commit $TARGET_SHA." >&2
    exit 1
fi

echo "Release $TAG points at $TARGET_SHA"
