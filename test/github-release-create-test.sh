#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Exercise the release creation token fallback with PATH stubs only.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/shared/bootc-secure/ci/create-github-release.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/build-images.yml"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

MARKER_JOB_TOKEN='marker-job-token-value-9f1c'
MARKER_FALLBACK_TOKEN='marker-fallback-token-value-4d7a'
REPOSITORY='frostyard/snosi'
TAG='2026-11-06.1'
TITLE='Build 2026-11-06 00:00:00 UTC'
TARGET_SHA='1111111111111111111111111111111111111111'
OTHER_SHA='2222222222222222222222222222222222222222'
DEFAULT_BRANCH='main'
NOTES_FILE="$work/changelog.md"
printf '# notes\n' >"$NOTES_FILE"

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'STUB'
#!/bin/bash
# gh stub: logs its arguments and the token class, never the token value.
set -euo pipefail
state=$RELEASE_FIXTURE_STATE
classify() {
    if [[ ${GH_TOKEN:-} == "$RELEASE_FIXTURE_JOB_TOKEN" ]]; then
        printf 'job\n'
    elif [[ ${GH_TOKEN:-} == "$RELEASE_FIXTURE_FALLBACK_TOKEN" ]]; then
        printf 'fallback\n'
    else
        printf 'unknown\n'
    fi
}
printf 'gh %s\n' "$*" >>"$state/calls"
case $1 in
    release)
        [[ ${2:-} == create ]] || { echo "unexpected gh: $*" >&2; exit 98; }
        token=$(classify)
        printf 'create token=%s arguments=%s\n' "$token" "$*" >>"$state/creates"
        case "$RELEASE_FIXTURE_CASE:$token" in
            other-error-with-fallback:*) printf 'HTTP 422: Validation Failed\n' >&2; exit 1 ;;
            fallback-fails:fallback) printf 'HTTP 422: Validation Failed\n' >&2; exit 1 ;;
            job-ok:job | tag-mismatch:job) exit 0 ;;
            *:fallback) exit 0 ;;
            *:job) printf 'HTTP 403: Resource not accessible by integration\n' >&2; exit 1 ;;
            *) printf 'unknown token class: %s\n' "$token" >&2; exit 97 ;;
        esac
        ;;
    api)
        path=${2:?}
        filter=${4:?}
        case $path in
            */contents/.github\?ref=*)
                ref=${path#*ref=}
                printf 'contents %s\n' "$ref" >>"$state/contents"
                case "$RELEASE_FIXTURE_CASE:$ref" in
                    contents-fail-branch:"$RELEASE_FIXTURE_DEFAULT_BRANCH")
                        printf 'HTTP 500: Server Error\n' >&2
                        exit 1
                        ;;
                    contents-fail-target:"$RELEASE_FIXTURE_TARGET_SHA")
                        printf 'HTTP 500: Server Error\n' >&2
                        exit 1
                        ;;
                esac
                # Run the real classification filter over the case payload.
                contents_payload "$RELEASE_FIXTURE_CASE" "$ref" | jq -r "$filter"
                ;;
            */commits/*)
                printf 'verify %s\n' "$path" >>"$state/verifies"
                case $RELEASE_FIXTURE_CASE in
                    tag-mismatch) printf '%s\n' "$RELEASE_FIXTURE_OTHER_SHA" ;;
                    *) printf '%s\n' "$RELEASE_FIXTURE_TARGET_SHA" ;;
                esac
                ;;
            *) echo "unexpected gh api: $*" >&2; exit 96 ;;
        esac
        ;;
    *) echo "unexpected gh: $*" >&2; exit 95 ;;
esac
STUB
chmod +x "$work/bin/gh"

# Payloads of `gh api repos/<repo>/contents/.github`: the .github entries.
cat >"$work/bin/contents_payload" <<'PAYLOAD'
#!/bin/bash
# contents_payload CASE REF: prints the .github entry list for the case.
set -euo pipefail
case_name=$1
ref=$2
branch=$RELEASE_FIXTURE_DEFAULT_BRANCH
entry() { printf '{"name":"%s","type":"%s","sha":"%s"}' "$1" "$2" "$3"; }
list() { local out='[' first=1 item; for item in "$@"; do [[ $first -eq 1 ]] || out+=','; out+=$item; first=0; done; printf '%s]\n' "$out"; }
case $case_name in
    no-diff-with-fallback | same-tree-other-entries)
        # Same workflows tree; only a sibling entry differs in one case.
        sibling='tree-sibling-a'
        [[ $case_name == same-tree-other-entries && $ref == "$branch" ]] && sibling='tree-sibling-b'
        list "$(entry workflows dir tree-same)" "$(entry ISSUE_TEMPLATE dir "$sibling")"
        ;;
    renamed-out-of-workflows)
        # The directory was renamed away on the default branch.
        if [[ $ref == "$branch" ]]; then
            list "$(entry ISSUE_TEMPLATE dir tree-sibling-b)"
        else
            list "$(entry workflows dir tree-target)" "$(entry ISSUE_TEMPLATE dir tree-sibling-b)"
        fi
        ;;
    *)
        if [[ $ref == "$branch" ]]; then
            list "$(entry workflows dir tree-branch)"
        else
            list "$(entry workflows dir tree-target)"
        fi
        ;;
esac
PAYLOAD
chmod +x "$work/bin/contents_payload"

LAST_STATUS=0
LAST_STATE=''

run_case() { # case-name job-token fallback-token tag sha notes-file
    local name=$1 job=$2 fallback=$3 tag=$4 sha=$5 notes=$6 state status=0
    state="$work/state-$name"
    mkdir -p "$state"
    : >"$state/calls"
    : >"$state/creates"
    : >"$state/contents"
    : >"$state/verifies"
    RELEASE_FIXTURE_STATE="$state" \
        RELEASE_FIXTURE_CASE="$name" \
        RELEASE_FIXTURE_JOB_TOKEN="$MARKER_JOB_TOKEN" \
        RELEASE_FIXTURE_FALLBACK_TOKEN="$MARKER_FALLBACK_TOKEN" \
        RELEASE_FIXTURE_TARGET_SHA="$TARGET_SHA" \
        RELEASE_FIXTURE_OTHER_SHA="$OTHER_SHA" \
        RELEASE_FIXTURE_DEFAULT_BRANCH="$DEFAULT_BRANCH" \
        GH_TOKEN="$job" \
        FALLBACK_TOKEN="$fallback" \
        PATH="$work/bin:$PATH" \
        "$SCRIPT" "$REPOSITORY" "$tag" "$TITLE" "$sha" "$notes" "$DEFAULT_BRANCH" \
        >"$state/stdout" 2>"$state/stderr" || status=$?
    LAST_STATUS=$status
    LAST_STATE=$state
}

create_count() {
    local count
    count=$(grep -c '^create ' "$1/creates" || true)
    printf '%s\n' "${count:-0}"
}

uses_fallback() {
    grep -q 'token=fallback' "$1/creates"
}

contents_called() {
    [[ -s "$1/contents" ]]
}

verifies_called() {
    [[ -s "$1/verifies" ]]
}

# a. The job token succeeds: one create, no fallback, tag verified.
run_case job-ok "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -eq 0 ]] &&
    [[ $(create_count "$LAST_STATE") -eq 1 ]] &&
    ! uses_fallback "$LAST_STATE" &&
    verifies_called "$LAST_STATE"; then
    pass 'job token creates the release and the tag is verified'
else
    fail 'job token creates the release and the tag is verified'
fi

# b. Exact 403 plus a differing workflows tree retries with the fallback token.
run_case diff-with-fallback "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -eq 0 ]] &&
    [[ $(create_count "$LAST_STATE") -eq 2 ]] &&
    uses_fallback "$LAST_STATE" &&
    grep -Fq '::warning::' "$LAST_STATE/stderr" &&
    grep -Fq 'tree-target' "$LAST_STATE/stderr" &&
    grep -Fq 'tree-branch' "$LAST_STATE/stderr"; then
    pass 'a differing workflows tree retries with WORKFLOW_PAT and warns with both tree identities'
else
    fail 'a differing workflows tree retries with WORKFLOW_PAT and warns with both tree identities'
fi

# c. The same 403 without a fallback token fails and names WORKFLOW_PAT.
run_case diff-no-fallback "$MARKER_JOB_TOKEN" '' "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -ne 0 ]] &&
    [[ $(create_count "$LAST_STATE") -eq 1 ]] &&
    ! uses_fallback "$LAST_STATE" &&
    grep -Fq '::error::' "$LAST_STATE/stderr" &&
    grep -Fq 'WORKFLOW_PAT' "$LAST_STATE/stderr" &&
    grep -Fq '.github/workflows tree differs' "$LAST_STATE/stderr"; then
    pass 'missing WORKFLOW_PAT fails the job with the required secret named'
else
    fail 'missing WORKFLOW_PAT fails the job with the required secret named'
fi

# d. An equal workflows tree means the 403 is a token or setting problem.
run_case no-diff-with-fallback "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -ne 0 ]] &&
    ! uses_fallback "$LAST_STATE" &&
    grep -Fq '::error::' "$LAST_STATE/stderr" &&
    grep -Fq 'the .github/workflows tree is the same' "$LAST_STATE/stderr"; then
    pass 'an equal workflows tree fails the 403 case and never uses the fallback'
else
    fail 'an equal workflows tree fails the 403 case and never uses the fallback'
fi

# e. Any other failure is reported at once.
run_case other-error-with-fallback "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -ne 0 ]] &&
    ! contents_called "$LAST_STATE" &&
    ! uses_fallback "$LAST_STATE"; then
    pass 'a non-403 failure fails the job without a tree read or fallback'
else
    fail 'a non-403 failure fails the job without a tree read or fallback'
fi

# f. A failed tree read of the target commit fails the job.
run_case contents-fail-target "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -ne 0 ]] &&
    ! uses_fallback "$LAST_STATE" &&
    grep -Fq 'Could not read the .github/workflows tree' "$LAST_STATE/stderr"; then
    pass 'a failed tree read of the built commit fails the job and never uses the fallback'
else
    fail 'a failed tree read of the built commit fails the job and never uses the fallback'
fi

# g. A tag that points at another commit fails the job.
run_case tag-mismatch "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -ne 0 ]] &&
    grep -Fq '::error::' "$LAST_STATE/stderr" &&
    grep -Fq "$OTHER_SHA" "$LAST_STATE/stderr"; then
    pass 'a tag that resolves to another commit fails the job'
else
    fail 'a tag that resolves to another commit fails the job'
fi

# h. A failed fallback retry fails the job.
run_case fallback-fails "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -ne 0 ]] && uses_fallback "$LAST_STATE"; then
    pass 'a failed WORKFLOW_PAT retry fails the job'
else
    fail 'a failed WORKFLOW_PAT retry fails the job'
fi

# i. Invalid arguments fail before any gh call.
bad_arguments=''
run_case bad-tag "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" '2026-11-6.1' "$TARGET_SHA" "$NOTES_FILE"
[[ $LAST_STATUS -ne 0 ]] && [[ ! -s "$LAST_STATE/calls" ]] || bad_arguments+='bad-tag '
run_case bad-sha "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" 'HEAD' "$NOTES_FILE"
[[ $LAST_STATUS -ne 0 ]] && [[ ! -s "$LAST_STATE/calls" ]] || bad_arguments+='bad-sha '
run_case missing-notes "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$work/absent-notes.md"
[[ $LAST_STATUS -ne 0 ]] && [[ ! -s "$LAST_STATE/calls" ]] || bad_arguments+='missing-notes '
if [[ -z $bad_arguments ]]; then
    pass 'invalid tag, commit and notes file fail before any gh call'
else
    fail "invalid arguments reached gh: $bad_arguments"
fi

# j. No output ever carries a token value.
run_case secrets-marker "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -ne 0 ]] || ! uses_fallback "$LAST_STATE"; then
    fail 'the fallback path runs while the token values stay hidden'
elif grep -rqF -e "$MARKER_JOB_TOKEN" -e "$MARKER_FALLBACK_TOKEN" "$work"/state-*; then
    fail 'a token value never appears in captured output or stub logs'
else
    pass 'a token value never appears in captured output or stub logs'
fi

# l. A workflows directory renamed away on the default branch: fallback runs.
run_case renamed-out-of-workflows "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -eq 0 ]] &&
    [[ $(create_count "$LAST_STATE") -eq 2 ]] &&
    uses_fallback "$LAST_STATE" &&
    grep -Fq 'tree-target' "$LAST_STATE/stderr" &&
    grep -Fq 'absent' "$LAST_STATE/stderr"; then
    pass 'a workflows directory renamed away on the default branch uses the fallback'
else
    fail 'a workflows directory renamed away on the default branch uses the fallback'
fi

# m. Equal workflows trees with other .github changes: no fallback.
run_case same-tree-other-entries "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -ne 0 ]] &&
    ! uses_fallback "$LAST_STATE" &&
    grep -Fq 'the .github/workflows tree is the same' "$LAST_STATE/stderr"; then
    pass 'an equal workflows tree is not a fallback case when other .github entries differ'
else
    fail 'an equal workflows tree is not a fallback case when other .github entries differ'
fi

# n. A failed tree read of the default branch fails the job.
run_case contents-fail-branch "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -ne 0 ]] &&
    ! uses_fallback "$LAST_STATE" &&
    grep -Fq "Could not read the .github/workflows tree of $DEFAULT_BRANCH" "$LAST_STATE/stderr"; then
    pass 'a failed tree read of the default branch fails the job and never uses the fallback'
else
    fail 'a failed tree read of the default branch fails the job and never uses the fallback'
fi

# The classification must use the contents API, never the compare endpoint.
if grep -rq '/compare/' "$work"/state-*/calls; then
    fail 'the script never calls the compare endpoint'
else
    pass 'the script never calls the compare endpoint'
fi

if grep -Fq '/compare/' "$SCRIPT"; then
    fail 'the script names no compare endpoint'
else
    pass 'the script names no compare endpoint'
fi

# k. Static wiring: the workflow calls the script and owns the only secret use.
extract_step() { # output
    awk '
        $0 == "      - name: Create GitHub Release" {
            in_step = 1
            found = 1
        }
        in_step && $0 ~ /^      - name: / && $0 != "      - name: Create GitHub Release" {
            exit
        }
        in_step { print }
        END { if (!found) exit 1 }
    ' "$WORKFLOW" >"$1"
}

if [[ ! -x $SCRIPT ]]; then
    fail 'shared/bootc-secure/ci/create-github-release.sh is executable'
fi
step_file="$work/release-step.yml"
if extract_step "$step_file"; then
    if grep -Fq 'gh release create' "$WORKFLOW"; then
        fail 'the workflow has no direct gh release create'
    else
        pass 'the workflow has no direct gh release create'
    fi
    # shellcheck disable=SC2016 # Match the literal workflow shell source.
    if grep -Fq './shared/bootc-secure/ci/create-github-release.sh "$GITHUB_REPOSITORY"' "$step_file"; then
        pass 'the Create GitHub Release step calls the release script'
    else
        fail 'the Create GitHub Release step calls the release script'
    fi
    secret_uses=$(grep -c 'secrets\.WORKFLOW_PAT' "$WORKFLOW" || true)
    if [[ ${secret_uses:-0} -eq 1 ]] &&
        grep -Fq 'secrets.WORKFLOW_PAT' "$step_file"; then
        pass 'secrets.WORKFLOW_PAT appears exactly once, inside the release step'
    else
        fail "secrets.WORKFLOW_PAT must appear exactly once in the release step (found ${secret_uses:-0})"
    fi
else
    fail 'the workflow has a Create GitHub Release step'
fi

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
