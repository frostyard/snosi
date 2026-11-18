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
    cp "$fixture/.github/workflows/build-images.yml" "$fixture/.github/workflows/forky-publish.yml"
    # Forky installs Cosign for publication and again for promotion.
    printf '  cosign-release: "v2.0.0"\n' >>"$fixture/.github/workflows/forky-publish.yml"
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
    local fixture=$1 workflow_updates_enabled=$2 chunkah_update=$3 dependency=${4:-syft}
    local digest
    digest="sha256:$(printf '%064d' 1)"
    (
        cd "$fixture"
        GITHUB_OUTPUT="$fixture/output" \
            PATH="$work/bin:$PATH" \
            SYFT_UPDATE="$([[ "$dependency" == syft || "$dependency" == both ]] && echo true || echo false)" \
            SYFT_VERSION=v1.1.0 \
            COSIGN_UPDATE="$([[ "$dependency" == cosign || "$dependency" == both ]] && echo true || echo false)" \
            COSIGN_VERSION=v2.1.0 \
            CHUNKAH_UPDATE="$chunkah_update" \
            CHUNKAH_DIGEST="$digest" \
            WORKFLOW_UPDATES_ENABLED="$workflow_updates_enabled" \
            bash -e "$work/update.sh"
    )
}

# Cosign also downloads the installer binary. Keep these fixtures offline.
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then
        printf 'fixture cosign binary\n' >"$2"
        exit 0
    fi
    shift
done
exit 1
EOF
chmod +x "$work/bin/curl"

fixture="$work/workflow-only-missing-token"
make_fixture "$fixture"
run_update "$fixture" false false
if git -C "$fixture" diff --quiet &&
    grep -Fq 'has_changes=false' "$fixture/output"; then
    pass 'workflow-only updates produce no change without WORKFLOW_PAT'
else
    fail 'workflow-only updates produce no change without WORKFLOW_PAT'
fi

for dependency in syft cosign both; do
    fixture="$work/workflow-token-present-$dependency"
    make_fixture "$fixture"
    run_update "$fixture" true false "$dependency"
    expected_syft=v1.0.0
    expected_cosign=v2.0.0
    if [[ "$dependency" == syft || "$dependency" == both ]]; then
        expected_syft=v1.1.0
    fi
    if [[ "$dependency" == cosign || "$dependency" == both ]]; then
        expected_cosign=v2.1.0
    fi
    for workflow in build-images forky-publish; do
        expected_cosign_count=1
        if [[ "$workflow" == forky-publish ]]; then
            expected_cosign_count=2
        fi
        if [[ $(grep -Fc "syft-version: $expected_syft" "$fixture/.github/workflows/$workflow.yml") == 1 ]] &&
            [[ $(grep -Fc "cosign-release: \"$expected_cosign\"" "$fixture/.github/workflows/$workflow.yml") == "$expected_cosign_count" ]] &&
            grep -Fq 'has_changes=true' "$fixture/output"; then
            pass "$dependency updates the expected pins in $workflow with WORKFLOW_PAT"
        else
            fail "$dependency updates the expected pins in $workflow with WORKFLOW_PAT"
        fi
    done
done

# Exercise 0 and expected+1 matches in each target, for each dependency.
# A failed preflight must leave both workflows byte-identical to their inputs.
for dependency in syft cosign; do
    case "$dependency" in
        syft) pin='syft-version: v1.0.0' ;;
        cosign) pin='cosign-release: "v2.0.0"' ;;
    esac
    for workflow in build-images forky-publish; do
        expected_count=1
        if [[ "$dependency" == cosign && "$workflow" == forky-publish ]]; then
            expected_count=2
        fi
        for count in 0 "$((expected_count + 1))"; do
            fixture="$work/bad-count-$dependency-$workflow-$count"
            make_fixture "$fixture"
            target="$fixture/.github/workflows/$workflow.yml"
            if [[ "$count" == 0 ]]; then
                grep -Fv "$pin" "$target" >"$fixture/changed"
                mv "$fixture/changed" "$target"
            else
                printf '  %s\n' "$pin" >>"$target"
            fi
            cp "$fixture/.github/workflows/build-images.yml" "$fixture/build-images.before"
            cp "$fixture/.github/workflows/forky-publish.yml" "$fixture/forky-publish.before"
            if run_update "$fixture" true false "$dependency" >"$fixture/log" 2>&1; then
                fail "$dependency rejects $count matches in $workflow"
            elif grep -Fq "in .github/workflows/$workflow.yml, found $count" "$fixture/log" &&
                cmp -s "$fixture/build-images.before" "$fixture/.github/workflows/build-images.yml" &&
                cmp -s "$fixture/forky-publish.before" "$fixture/.github/workflows/forky-publish.yml"; then
                pass "$dependency rejects $count matches in $workflow before editing either workflow"
            else
                fail "$dependency rejects $count matches in $workflow before editing either workflow"
            fi
        done
    done
done

fixture="$work/mixed-missing-token"
make_fixture "$fixture"
run_update "$fixture" false true both
if git -C "$fixture" diff --quiet -- .github/workflows &&
    jq -e '.["cosign-installer"].version == "2.1.0"' "$fixture/shared/download/image-checksums.json" >/dev/null &&
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
