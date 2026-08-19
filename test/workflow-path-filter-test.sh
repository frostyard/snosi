#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Keep documentation and standalone worker changes out of expensive image CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS="$ROOT_DIR/.github/workflows"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

trigger_block() { # workflow event
    local workflow=$1 event=$2
    awk -v header="  $event:" '
        $0 == header { in_event=1 }
        in_event && $0 ~ /^  [[:alnum:]_-]+:$/ && $0 != header { exit }
        in_event { print }
    ' "$workflow"
}

assert_ignored() { # description workflow event path
    local description=$1 workflow=$2 event=$3 path=$4 block
    block=$(trigger_block "$workflow" "$event")
    if [[ $block == *"- \"$path\""* ]]; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_not_ignored() { # description workflow event path
    local description=$1 workflow=$2 event=$3 path=$4 block
    block=$(trigger_block "$workflow" "$event")
    if [[ $block == *"- \"$path\""* ]]; then
        fail "$description"
    else
        pass "$description"
    fi
}

common_ignored_paths=(
    '**/*.md'
    '.agents/**'
    '.claude/**'
    '.knowledge/**'
    '.memory/**'
    'docs/**'
    'skills/**'
    'workers/**'
    '.github/workflows/deploy-native-installer-redirect.yml'
)

# Workflows that never run on push/PR (scheduled, dispatch-only, or
# issue/review-event) plus repository metadata: changing them cannot affect
# any push/PR-triggered build or contract job, so none of the expensive
# workflows may re-run for them (dependabot bumps these files weekly).
inert_ci_paths=(
    '.github/workflows/ai-fix-requested.yml'
    '.github/workflows/bootc-secure-nightly.yml'
    '.github/workflows/build-mechanics.yml'
    '.github/workflows/check-dependencies.yml'
    '.github/workflows/check-packages.yml'
    '.github/workflows/claude.yml'
    '.github/workflows/native-nightly.yml'
    '.github/workflows/nightly-compliance.yml'
    '.github/workflows/scorecard.yml'
    '.github/workflows/test-install.yml'
    '.github/workflows/triage.yml'
    '.github/ISSUE_TEMPLATE/**'
    '.github/prompts/**'
    '.github/actionlint.yaml'
    '.github/auto-qa-tuning.json'
    '.github/dependabot.yml'
    '.github/renovate.json5'
)

for name in build-images.yml build-native-images.yml build.yml; do
    workflow="$WORKFLOWS/$name"
    for event in push pull_request; do
        for path in "${common_ignored_paths[@]}"; do
            assert_ignored "$name $event ignores $path" "$workflow" "$event" "$path"
        done
    done
done

for name in build-images.yml build-native-images.yml build.yml test-bootc-secure.yml; do
    workflow="$WORKFLOWS/$name"
    for event in push pull_request; do
        for path in "${inert_ci_paths[@]}"; do
            assert_ignored "$name $event ignores inert $path" "$workflow" "$event" "$path"
        done
    done
done

# Load-bearing triggers that must never be ignored:
# - build.yml carries the canonical mkosi pin read by
#   shared/native-ab/ci/bootstrap-mkosi.sh (used by build-native-images.yml).
# - check-bootc-publication-guard.sh validates build-images.yml on every
#   test-bootc-secure contracts run.
for event in push pull_request; do
    assert_not_ignored "build-native-images $event still triggers on build.yml (mkosi pin source)" \
        "$WORKFLOWS/build-native-images.yml" "$event" '.github/workflows/build.yml'
    assert_not_ignored "bootc contracts $event still trigger on build-images.yml (publication guard input)" \
        "$WORKFLOWS/test-bootc-secure.yml" "$event" '.github/workflows/build-images.yml'
    assert_not_ignored "bootc contracts $event still trigger on docs/** (bootc-secure docs contracts)" \
        "$WORKFLOWS/test-bootc-secure.yml" "$event" 'docs/**'
    assert_not_ignored "bootc contracts $event still trigger on Markdown (docs/bootc-secure-*.md)" \
        "$WORKFLOWS/test-bootc-secure.yml" "$event" '**/*.md'
done

if [[ -f "$WORKFLOWS/claude.yml" || -f "$WORKFLOWS/claude-code-review.yml" ]]; then
    pass 'ACMM GitHub Actions AI integration workflow exists'
else
    fail 'ACMM GitHub Actions AI integration workflow exists'
fi

bootc_contract_ignored_paths=(
    'workers/**'
    '.github/workflows/deploy-native-installer-redirect.yml'
    '.agents/**'
    '.claude/**'
    '.knowledge/**'
    '.memory/**'
    'skills/**'
    'README.md'
    'AGENTS.md'
    'shared/download/package-versions.json'
    'latest-versions.txt'
    'shared/download/sysext-checksums.json'
    'shared/download/image-checksums.json'
)
for event in push pull_request; do
    for path in "${bootc_contract_ignored_paths[@]}"; do
        assert_ignored "bootc contracts $event ignores $path" \
            "$WORKFLOWS/test-bootc-secure.yml" "$event" "$path"
    done
done

if grep -Eq '^  push:' "$WORKFLOWS/scorecard.yml"; then
    fail 'Scorecard does not run after every push'
else
    pass 'Scorecard does not run after every push'
fi
if grep -Eq '^  schedule:' "$WORKFLOWS/scorecard.yml"; then
    pass 'Scorecard retains its weekly schedule'
else
    fail 'Scorecard retains its weekly schedule'
fi

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
