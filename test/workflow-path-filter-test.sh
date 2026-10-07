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

path_filter_block() { # workflow event filter
    local workflow=$1 event=$2 filter=$3
    trigger_block "$workflow" "$event" | awk -v header="    $filter:" '
        $0 == header { in_filter=1; next }
        in_filter && $0 ~ /^    [[:alnum:]_-]+:$/ { exit }
        in_filter { print }
    '
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

assert_included() { # description workflow event path
    local description=$1 workflow=$2 event=$3 path=$4 block
    block=$(path_filter_block "$workflow" "$event" paths)
    if [[ $block == *"- \"$path\""* ]]; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_positive_path_filter() { # description workflow event
    local description=$1 workflow=$2 event=$3 block
    block=$(trigger_block "$workflow" "$event")
    if [[ $block == *"    paths:"* && $block != *"    paths-ignore:"* ]]; then
        pass "$description"
    else
        fail "$description"
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
    '.github/workflows/build-installer-iso.yml'
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

for name in build-images.yml build.yml; do
    workflow="$WORKFLOWS/$name"
    for event in push pull_request; do
        for path in "${common_ignored_paths[@]}"; do
            assert_ignored "$name $event ignores $path" "$workflow" "$event" "$path"
        done
    done
done

for name in build-images.yml build.yml test-bootc-secure.yml; do
    workflow="$WORKFLOWS/$name"
    for event in push pull_request; do
        for path in "${inert_ci_paths[@]}"; do
            assert_ignored "$name $event ignores inert $path" "$workflow" "$event" "$path"
        done
    done
done


installer_iso_inputs=(
    '.github/workflows/build-installer-iso.yml'
    '.github/workflows/build.yml'
    'cosign.pub'
    'mkosi.conf'
    'mkosi.version'
    'mkosi.profiles/firn-installer/**'
    'mkosi.sandbox/**'
    'mkosi.tools.sandbox/**'
    'shared/download/image-checksums.json'
    'shared/download/sysext-checksums.json'
    'shared/download/verified-download.sh'
    'shared/firn-installer/**'
    'shared/native-ab/ci/**'
    'shared/native-ab/keys/import-pubring.gpg'
    'shared/native-ab/keys/mok-2026.crt'
    'shared/native-ab/publish/**'
    'shared/bootc-secure/package-manager/**'
    'test/lib/vm.sh'
    'test/native-iso-boot-smoke-test.sh'
)
assert_positive_path_filter 'build-installer-iso.yml push uses only a positive path filter' \
    "$WORKFLOWS/build-installer-iso.yml" push
for path in "${installer_iso_inputs[@]}"; do
    assert_included "build-installer-iso.yml push includes $path" \
        "$WORKFLOWS/build-installer-iso.yml" push "$path"
done

# A stale ISO input silently suppresses rebuilds; a stale run-step path fails
# only after the publication workflow starts. Check both against the checkout.
if python3 - "$ROOT_DIR" "$WORKFLOWS/build-installer-iso.yml" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
workflow = Path(sys.argv[2]).read_text()
paths = re.findall(r'\./(?:shared|test)/[A-Za-z0-9_./-]+', workflow)
paths += re.findall(r'^\s+- "((?:shared|test)/[^"]+)"$', workflow, re.M)
missing = []
for path in paths:
    path = path.removeprefix('./')
    # A trailing /** denotes a directory, not a concrete file.
    fixed = path[:-3] if path.endswith('/**') else path
    if not (root / fixed).exists():
        missing.append(path)
if missing:
    print('missing installer workflow inputs: ' + ', '.join(sorted(set(missing))), file=sys.stderr)
    sys.exit(1)
PY
then
    pass 'installer ISO workflow script references and input paths exist'
else
    fail 'installer ISO workflow script references and input paths exist'
fi

# Load-bearing triggers that must never be ignored:
# - build.yml carries the canonical mkosi pin read by
#   shared/native-ab/ci/bootstrap-mkosi.sh (used by the installer ISO build).
# - check-bootc-publication-guard.sh validates build-images.yml on every
#   test-bootc-secure contracts run.
for event in push pull_request; do
    assert_not_ignored "bootc contracts $event still trigger on build-images.yml (publication guard input)" \
        "$WORKFLOWS/test-bootc-secure.yml" "$event" '.github/workflows/build-images.yml'
    assert_not_ignored "bootc contracts $event still trigger on docs/** (bootc-secure docs contracts)" \
        "$WORKFLOWS/test-bootc-secure.yml" "$event" 'docs/**'
    assert_not_ignored "bootc contracts $event still trigger on Markdown (docs/bootc-secure-*.md)" \
        "$WORKFLOWS/test-bootc-secure.yml" "$event" '**/*.md'
done

# The Forky systemd sentinel (shared/download/forky-versions.json) records an
# acknowledged family version that no build reads. Its PR must still build the
# secure bootc profiles on the new family. Sysexts never install from Forky.
forky_sentinel='shared/download/forky-versions.json'
for event in push pull_request; do
    assert_not_ignored "build-images.yml $event still triggers on the Forky systemd sentinel" \
        "$WORKFLOWS/build-images.yml" "$event" "$forky_sentinel"
    assert_ignored "build.yml $event ignores the Forky systemd sentinel" \
        "$WORKFLOWS/build.yml" "$event" "$forky_sentinel"
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
    '.github/workflows/build-installer-iso.yml'
    'README.md'
    'AGENTS.md'
    'shared/download/package-versions.json'
    'latest-versions.txt'
    'shared/download/sysext-checksums.json'
    'shared/download/image-checksums.json'
    'shared/download/forky-versions.json'
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
