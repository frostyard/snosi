#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Contract for the branch-only publication path in build-images.yml.
#
# A workflow_dispatch on a branch other than main exists only to publish ONE
# signed Snow version tag for a lab lifecycle test. That path must build snow
# alone and must not reach any main-only side effect: `latest` promotion, the
# R2 manifest upload, the snow-tag artifact, or the release job. Everything a
# lab test needs (immutable version tag, signature, SBOM, attestation,
# re-verification) stays.
#
# Static only: no network, no registry, no dispatch.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow_file="$ROOT_DIR/.github/workflows/build-images.yml"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

[[ -f $workflow_file ]] || {
    printf 'not ok - missing %s\n' "$workflow_file" >&2
    exit 1
}

job_block() { # job name
    awk -v header="  $1:" '
        $0 == header { capture = 1 }
        capture && /^  [A-Za-z0-9_-]+:$/ && $0 != header { exit }
        capture { print }
    ' "$workflow_file"
}

step_block() { # step name
    awk -v header="      - name: $1" '
        $0 == header { capture = 1 }
        capture && /^      - name: / && $0 != header { exit }
        capture { print }
    ' "$workflow_file"
}

step_count() { # step name
    grep -c -F -- "      - name: $1" "$workflow_file" || true
}

assert_step_condition() { # description step expected-condition
    local description=$1 name=$2 expected=$3 block
    if [[ $(step_count "$name") -ne 1 ]]; then
        fail "$description (expected exactly one step named $name)"
        return
    fi
    block=$(step_block "$name")
    if grep -Fqx "        if: $expected" <<<"$block"; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_step_ungated() { # description step
    local description=$1 name=$2 block
    if [[ $(step_count "$name") -ne 1 ]]; then
        fail "$description (expected exactly one step named $name)"
        return
    fi
    block=$(step_block "$name")
    if grep -Eq '^        if: ' <<<"$block"; then
        fail "$description"
    else
        pass "$description"
    fi
}

# 1. The dispatch trigger exists, and the branch path cannot read a dispatch
#    input that would widen it.
if grep -Fqx '  workflow_dispatch:' "$workflow_file"; then
    pass 'workflow_dispatch trigger is present'
else
    fail 'workflow_dispatch trigger is missing'
fi

secure=$(job_block secure-build)
if [[ -z $secure ]]; then
    printf 'not ok - missing secure-build job\n' >&2
    exit 1
fi

# 2. The job condition: main plus a branch dispatch, never a pull request.
condition=$(awk '
    /^    if: / { capture = 1 }
    capture && !/^    if: / && /^    [A-Za-z0-9_-]+:/ { exit }
    capture { print }
' <<<"$secure")

if grep -Fqx "      github.event_name != 'pull_request' &&" <<<"$condition"; then
    pass 'secure-build excludes pull requests'
else
    fail 'secure-build must exclude pull requests'
fi
if grep -Fq "      (github.ref == 'refs/heads/main' ||" <<<"$condition"; then
    pass 'secure-build keeps the main publication path'
else
    fail 'secure-build must keep the main publication path'
fi
if grep -Fq "      (github.event_name == 'workflow_dispatch' &&" <<<"$condition" &&
        grep -Fqx "      startsWith(github.ref, 'refs/heads/')))" <<<"$condition"; then
    pass 'secure-build allows a workflow_dispatch on a branch'
else
    fail 'secure-build must allow a workflow_dispatch on a branch'
fi
if grep -Fq "event_name == 'pull_request'" <<<"$condition"; then
    fail 'secure-build condition must not permit a pull request'
else
    pass 'secure-build condition permits no pull request'
fi
if [[ $(grep -c -F '||' <<<"$condition") -eq 1 ]]; then
    pass 'secure-build condition holds exactly one disjunction'
else
    fail 'secure-build condition must hold exactly one disjunction'
fi

# 3. The matrix: main gets all four products, any other ref gets snow alone.
include_line=$(grep -F '        include: ' <<<"$secure" || true)
if [[ $(wc -l <<<"$include_line") -eq 1 ]]; then
    pass 'secure-build has one matrix include expression'
else
    fail 'secure-build must have one matrix include expression'
fi
if grep -Fq "\${{ github.ref == 'refs/heads/main' &&" <<<"$include_line"; then
    pass 'the matrix is selected by the ref'
else
    fail 'the matrix must be selected by the ref'
fi
if grep -Fq 'fromJSON(' <<<"$include_line"; then
    pass 'the matrix uses explicit fromJSON product lists'
else
    fail 'the matrix must use explicit fromJSON product lists'
fi

main_part=${include_line%%||*}
off_main_part=${include_line#*|| }
main_profiles=$(grep -o '"profile":"[a-z]*"' <<<"$main_part" |
    cut -d'"' -f4 | sort | paste -sd' ' -)
off_main_profiles=$(grep -o '"profile":"[a-z]*"' <<<"$off_main_part" |
    cut -d'"' -f4 | sort | paste -sd' ' -)

if [[ $main_profiles == 'floe snow snowfield sundog' ]]; then
    pass 'main builds all four products'
else
    fail "main must build all four products (found: ${main_profiles:-none})"
fi
if [[ $off_main_profiles == 'snow' ]]; then
    pass 'a non-main ref builds snow alone'
else
    fail "a non-main ref must build snow alone (found: ${off_main_profiles:-none})"
fi
if grep -Eq 'inputs\.' <<<"${include_line}${condition}"; then
    fail 'the branch-dispatch path must not read workflow_dispatch inputs'
else
    pass 'the branch-dispatch path reads no dispatch inputs'
fi

# 4. Main-only side effects are gated on the ref, not only on the profile.
assert_step_condition 'latest promotion is main-only' \
    'Promote validated digest to latest' "github.ref == 'refs/heads/main'"
assert_step_condition 'the R2 manifest upload is main-only' \
    'Upload manifests to R2' "github.ref == 'refs/heads/main'"
assert_step_condition 'the snow-tag record is main-only' \
    'Record snow tag for release job' \
    "github.ref == 'refs/heads/main' && matrix.profile == 'snow'"
assert_step_condition 'the snow-tag artifact upload is main-only' \
    'Upload snow tag artifact' \
    "github.ref == 'refs/heads/main' && matrix.profile == 'snow'"

# 5. The release job stays push-on-main only, and keeps its artifact contract.
release=$(job_block release)
if [[ -z $release ]]; then
    fail 'missing release job'
else
    if grep -Fxq '    needs: secure-build' <<<"$release"; then
        pass 'release still needs the secure build'
    else
        fail 'release must still need the secure build'
    fi
    release_condition=$(awk '
        /^    if: / { capture = 1 }
        capture && !/^    if: / && /^    [A-Za-z0-9_-]+:/ { exit }
        capture { print }
    ' <<<"$release")
    if grep -Fq "github.event_name == 'push'" <<<"$release_condition" &&
            grep -Fq "github.ref == 'refs/heads/main'" <<<"$release_condition"; then
        pass 'release stays push-on-main only'
    else
        fail 'release must stay push-on-main only'
    fi
fi

# 6. What a lab test needs from a branch stays available: the immutable tag,
#    its signature, the SBOM, the attestation and the re-verification.
for name in \
    'Push immutable version tag' \
    'Sign immutable image digest' \
    'Upload SBOM' \
    'Sign SBOM' \
    'Attest build provenance' \
    'Re-verify key signature after attestation'; do
    assert_step_ungated "'$name' still runs on a branch" "$name"
done

# 7. No other side effect of the job reaches out off main. The job block is the
#    authoritative scope: the trigger filters live outside it.
no_other_side_effect=1
for token in 'cloudflare' 'Cloudflare' 'gh workflow run' 'dispatches' \
    'build-installer-iso' 'awslabs' 'rclone'; do
    if grep -Fq -- "$token" <<<"$secure"; then
        fail "secure-build must not reach '$token' at all"
        no_other_side_effect=0
    fi
done
((no_other_side_effect == 1)) &&
    pass 'secure-build reaches no other external side effect'

r2_steps=$(step_count 'Upload manifests to R2')
if [[ $r2_steps -eq 1 ]]; then
    pass 'exactly one R2 upload step exists'
else
    fail "exactly one R2 upload step must exist (found: $r2_steps)"
fi

printf '\n%d passing assertions, %d failures\n' "$PASS" "$FAIL"
((FAIL == 0))
