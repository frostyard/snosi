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

common_ignored_paths=(
    '**/*.md'
    '.claude/**'
    '.knowledge/**'
    '.memory/**'
    'skills/**'
    'yeti/**'
    'workers/**'
    '.github/workflows/deploy-native-installer-redirect.yml'
)

for name in build-images.yml build-native-images.yml build.yml; do
    workflow="$WORKFLOWS/$name"
    for event in push pull_request; do
        for path in "${common_ignored_paths[@]}"; do
            assert_ignored "$name $event ignores $path" "$workflow" "$event" "$path"
        done
    done
done

if [[ -f "$WORKFLOWS/claude.yml" || -f "$WORKFLOWS/claude-code-review.yml" ]]; then
    pass 'ACMM GitHub Actions AI integration workflow exists'
else
    fail 'ACMM GitHub Actions AI integration workflow exists'
fi

for event in push pull_request; do
    assert_ignored "bootc contracts $event ignores standalone worker code" \
        "$WORKFLOWS/test-bootc-secure.yml" "$event" 'workers/**'
    assert_ignored "bootc contracts $event ignores worker deploy workflow" \
        "$WORKFLOWS/test-bootc-secure.yml" "$event" \
        '.github/workflows/deploy-native-installer-redirect.yml'
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
