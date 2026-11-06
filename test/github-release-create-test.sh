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
        case $path in
            */compare/*)
                printf 'compare %s\n' "$path" >>"$state/compares"
                case $RELEASE_FIXTURE_CASE in
                    compare-fails) printf 'HTTP 500: Server Error\n' >&2; exit 1 ;;
                    no-diff-with-fallback) printf '%s\n' 'README.md' 'docs/design/ci-cd.md' ;;
                    *) printf '%s\n' '.github/workflows/validate.yml' 'docs/design/ci-cd.md' ;;
                esac
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

LAST_STATUS=0
LAST_STATE=''

run_case() { # case-name job-token fallback-token tag sha notes-file
    local name=$1 job=$2 fallback=$3 tag=$4 sha=$5 notes=$6 state status=0
    state="$work/state-$name"
    mkdir -p "$state"
    : >"$state/calls"
    : >"$state/creates"
    : >"$state/compares"
    : >"$state/verifies"
    RELEASE_FIXTURE_STATE="$state" \
        RELEASE_FIXTURE_CASE="$name" \
        RELEASE_FIXTURE_JOB_TOKEN="$MARKER_JOB_TOKEN" \
        RELEASE_FIXTURE_FALLBACK_TOKEN="$MARKER_FALLBACK_TOKEN" \
        RELEASE_FIXTURE_TARGET_SHA="$TARGET_SHA" \
        RELEASE_FIXTURE_OTHER_SHA="$OTHER_SHA" \
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

compares_called() {
    [[ -s "$1/compares" ]]
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

# b. Exact 403 plus a workflow difference retries with the fallback token.
run_case diff-with-fallback "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -eq 0 ]] &&
    [[ $(create_count "$LAST_STATE") -eq 2 ]] &&
    uses_fallback "$LAST_STATE" &&
    grep -Fq '::warning::' "$LAST_STATE/stderr" &&
    grep -Fq 'validate.yml' "$LAST_STATE/stderr"; then
    pass 'workflow difference retries with WORKFLOW_PAT and warns with the file name'
else
    fail 'workflow difference retries with WORKFLOW_PAT and warns with the file name'
fi

# c. The same 403 without a fallback token fails and names WORKFLOW_PAT.
run_case diff-no-fallback "$MARKER_JOB_TOKEN" '' "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -ne 0 ]] &&
    [[ $(create_count "$LAST_STATE") -eq 1 ]] &&
    ! uses_fallback "$LAST_STATE" &&
    grep -Fq '::error::' "$LAST_STATE/stderr" &&
    grep -Fq 'WORKFLOW_PAT' "$LAST_STATE/stderr"; then
    pass 'missing WORKFLOW_PAT fails the job with the required secret named'
else
    fail 'missing WORKFLOW_PAT fails the job with the required secret named'
fi

# d. No workflow difference means the 403 is a token or setting problem.
run_case no-diff-with-fallback "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -ne 0 ]] &&
    ! uses_fallback "$LAST_STATE" &&
    grep -Fq '::error::' "$LAST_STATE/stderr"; then
    pass 'a 403 without a workflow difference fails and never uses the fallback'
else
    fail 'a 403 without a workflow difference fails and never uses the fallback'
fi

# e. Any other failure is reported at once.
run_case other-error-with-fallback "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -ne 0 ]] &&
    ! compares_called "$LAST_STATE" &&
    ! uses_fallback "$LAST_STATE"; then
    pass 'a non-403 failure fails the job without a compare call or fallback'
else
    fail 'a non-403 failure fails the job without a compare call or fallback'
fi

# f. A failed compare call fails the job.
run_case compare-fails "$MARKER_JOB_TOKEN" "$MARKER_FALLBACK_TOKEN" "$TAG" "$TARGET_SHA" "$NOTES_FILE"
if [[ $LAST_STATUS -ne 0 ]] &&
    ! uses_fallback "$LAST_STATE" &&
    grep -Fq '::error::' "$LAST_STATE/stderr"; then
    pass 'a failed compare call fails the job and never uses the fallback'
else
    fail 'a failed compare call fails the job and never uses the fallback'
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
