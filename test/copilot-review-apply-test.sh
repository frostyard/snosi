#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/copilot-review-apply.yml"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

awk '
    $0 == "        run: |" {
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
' "$WORKFLOW" >"$work/workflow-step.sh"

mkdir "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/bin/bash
touch "$GH_CALLED"
exit 99
EOF
chmod +x "$work/bin/gh"

run_without_token() {
    local event_name=$1
    local output_file=$2
    set +e
    env -u GH_TOKEN \
        GITHUB_EVENT_NAME="$event_name" \
        GH_CALLED="$work/gh-called" \
        PATH="$work/bin:$PATH" \
        PULL_NUMBER=1 \
        REVIEW_ID=2 \
        TARGET_REPOSITORY=frostyard/snosi \
        bash "$work/workflow-step.sh" >"$output_file" 2>&1
    RUN_STATUS=$?
    set -e
}

run_without_token pull_request_review "$work/automatic.out"
if [[ $RUN_STATUS -eq 0 ]]; then
    pass 'automatic review succeeds when the assignment token is absent'
else
    fail 'automatic review succeeds when the assignment token is absent'
fi
if grep -Fq '::warning::COPILOT_ASSIGNMENT_TOKEN is not configured; review feedback was not handed to Copilot' "$work/automatic.out"; then
    pass 'automatic review reports that the handoff was skipped'
else
    fail 'automatic review reports that the handoff was skipped'
fi
if [[ ! -e "$work/gh-called" ]]; then
    pass 'automatic review does not call GitHub without a token'
else
    fail 'automatic review does not call GitHub without a token'
fi

rm -f "$work/gh-called"
run_without_token workflow_dispatch "$work/manual.out"
if [[ $RUN_STATUS -eq 1 ]]; then
    pass 'manual dispatch fails when the assignment token is absent'
else
    fail 'manual dispatch fails when the assignment token is absent'
fi
if grep -Fq '::error::COPILOT_ASSIGNMENT_TOKEN is not configured' "$work/manual.out"; then
    pass 'manual dispatch reports the missing token as an error'
else
    fail 'manual dispatch reports the missing token as an error'
fi
if [[ ! -e "$work/gh-called" ]]; then
    pass 'manual dispatch does not call GitHub without a token'
else
    fail 'manual dispatch does not call GitHub without a token'
fi

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
