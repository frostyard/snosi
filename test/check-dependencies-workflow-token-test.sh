#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/check-dependencies.yml"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

extract_run_step() {
    local name=$1 output=$2
    awk -v header="      - name: $name" '
        $0 == header {
            in_step = 1
            next
        }
        in_step && $0 == "        run: |" {
            found = 1
            in_run = 1
            next
        }
        in_run && $0 == "" {
            print
            next
        }
        in_run && substr($0, 1, 10) == "          " {
            print substr($0, 11)
            next
        }
        in_run {
            exit
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$WORKFLOW" >"$output"
}

extract_run_step 'Check workflow update authorization' "$work/auth.sh"
extract_run_step 'Update image dependencies' "$work/update.sh"

GITHUB_OUTPUT="$work/auth-output"
WORKFLOW_PAT='' GITHUB_OUTPUT="$GITHUB_OUTPUT" bash "$work/auth.sh" >"$work/auth-log"
if grep -Fq 'can_update=false' "$GITHUB_OUTPUT" &&
    grep -Fq '::warning::WORKFLOW_PAT is not configured' "$work/auth-log"; then
    pass 'missing WORKFLOW_PAT disables workflow-file updates with a warning'
else
    fail 'missing WORKFLOW_PAT disables workflow-file updates with a warning'
fi

GITHUB_OUTPUT="$work/auth-output-present"
WORKFLOW_PAT=present GITHUB_OUTPUT="$GITHUB_OUTPUT" bash "$work/auth.sh"
if grep -Fq 'can_update=true' "$GITHUB_OUTPUT"; then
    pass 'configured WORKFLOW_PAT enables workflow-file updates'
else
    fail 'configured WORKFLOW_PAT enables workflow-file updates'
fi

make_fixture() {
    local fixture=$1
    mkdir -p \
        "$fixture/.github/workflows" \
        "$fixture/shared/download" \
        "$fixture/shared/outformat/image"
    cat >"$fixture/.github/workflows/build-images.yml" <<'EOF'
env:
  syft-version: v1.0.0
  cosign-release: "v2.0.0"
EOF
    printf '{}\n' >"$fixture/shared/download/image-checksums.json"
    printf 'CHUNKAH_IMAGE="quay.io/coreos/chunkah@sha256:%064d"\n' 0 \
        >"$fixture/shared/outformat/image/chunkah-package.sh"
    git -C "$fixture" init -q
    git -C "$fixture" config user.email fixture@example.invalid
    git -C "$fixture" config user.name fixture
    git -C "$fixture" add .
    git -C "$fixture" commit -qm fixture
}

run_update() {
    local fixture=$1 workflow_updates_enabled=$2 chunkah_update=$3
    local digest
    digest="sha256:$(printf '%064d' 1)"
    (
        cd "$fixture"
        GITHUB_OUTPUT="$fixture/output" \
            SYFT_UPDATE=true \
            SYFT_VERSION=v1.1.0 \
            COSIGN_UPDATE=false \
            CHUNKAH_UPDATE="$chunkah_update" \
            CHUNKAH_DIGEST="$digest" \
            WORKFLOW_UPDATES_ENABLED="$workflow_updates_enabled" \
            bash -e "$work/update.sh"
    )
}

fixture="$work/workflow-only-missing-token"
make_fixture "$fixture"
run_update "$fixture" false false
if git -C "$fixture" diff --quiet &&
    grep -Fq 'has_changes=false' "$fixture/output"; then
    pass 'workflow-only updates produce no change without WORKFLOW_PAT'
else
    fail 'workflow-only updates produce no change without WORKFLOW_PAT'
fi

fixture="$work/workflow-token-present"
make_fixture "$fixture"
run_update "$fixture" true false
if grep -Fq 'syft-version: v1.1.0' "$fixture/.github/workflows/build-images.yml" &&
    grep -Fq 'has_changes=true' "$fixture/output"; then
    pass 'workflow pin updates are applied when WORKFLOW_PAT is available'
else
    fail 'workflow pin updates are applied when WORKFLOW_PAT is available'
fi

fixture="$work/mixed-missing-token"
make_fixture "$fixture"
run_update "$fixture" false true
if grep -Fq 'syft-version: v1.0.0' "$fixture/.github/workflows/build-images.yml" &&
    grep -Fq "sha256:$(printf '%064d' 1)" "$fixture/shared/outformat/image/chunkah-package.sh" &&
    grep -Fq 'has_changes=true' "$fixture/output"; then
    pass 'non-workflow updates remain publishable without WORKFLOW_PAT'
else
    fail 'non-workflow updates remain publishable without WORKFLOW_PAT'
fi

if grep -Fq "if: steps.update.outputs.has_changes == 'true'" "$WORKFLOW"; then
    pass 'pull request creation requires an applied change'
else
    fail 'pull request creation requires an applied change'
fi

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
