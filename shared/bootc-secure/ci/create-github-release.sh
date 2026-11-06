#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Create the GitHub release for a built image tag.
#
# GITHUB_TOKEN cannot create a tag when the `.github/workflows` tree of that
# commit differs from the tree on the default branch: the job token has no
# `workflows` permission and cannot get one. When gh reports exactly that 403
# and the two tree identities differ, the release is retried once with
# FALLBACK_TOKEN (the WORKFLOW_PAT secret). Every other failure fails the job.
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
    # GitHub refuses the tag when the `.github/workflows` tree of the target
    # commit differs from the one on the default branch. Compare the tree
    # identities: a compare file list misses a workflow renamed out of the
    # directory and stops at 300 files, so it cannot decide this.
    workflow_tree() { # ref; sets WORKFLOW_TREE_VALUE
        local tree_status=0 tree
        tree=$(GH_TOKEN=$GH_TOKEN gh api \
            "repos/$REPOSITORY/contents/.github?ref=$1" \
            --jq '[.[] | select(.name == "workflows" and .type == "dir") | .sha] | first // ""' \
            2>"$work/tree-stderr") || tree_status=$?
        if [[ $tree_status -ne 0 ]]; then
            show_stderr "$work/tree-stderr"
            echo "::error::Could not read the .github/workflows tree of $1 to classify the HTTP 403 from gh release create." >&2
            return 1
        fi
        if [[ -z $tree ]]; then
            tree='absent'
        fi
        WORKFLOW_TREE_VALUE=$tree
        return 0
    }

    workflow_tree "$TARGET_SHA" || exit 1
    target_tree=$WORKFLOW_TREE_VALUE
    workflow_tree "$DEFAULT_BRANCH" || exit 1
    branch_tree=$WORKFLOW_TREE_VALUE

    if [[ $target_tree == "$branch_tree" ]]; then
        echo "::error::gh release create failed with HTTP 403 but the .github/workflows tree is the same at $TARGET_SHA (tree $target_tree) and $DEFAULT_BRANCH (tree $branch_tree). This is not the workflow-file case; check the token and the repository settings (Settings > Actions > General > Workflow permissions, and any tag ruleset that blocks tag creation)." >&2
        exit 1
    fi

    difference="the .github/workflows tree differs between $TARGET_SHA (tree $target_tree) and $DEFAULT_BRANCH (tree $branch_tree)"

    if [[ -z $FALLBACK_TOKEN ]]; then
        echo "::error::GITHUB_TOKEN cannot create tag $TAG because $difference. Set the WORKFLOW_PAT secret (a token with the workflow scope) so this release can use it." >&2
        exit 1
    fi

    echo "::warning::$difference. Creating the release with WORKFLOW_PAT instead of GITHUB_TOKEN." >&2

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
