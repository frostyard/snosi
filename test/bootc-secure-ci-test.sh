#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/shared/bootc-secure/ci/run-full-window.sh"

task123_fixture_coverage_is_present() { # workflow
    local workflow=$1
    grep -Fq 'run: ./test/bootc-secure-spike-test.sh --fixtures' "$workflow" \
        && grep -Fq 'run: sudo apt-get update && sudo apt-get install --yes cryptsetup' "$workflow" \
        && grep -Fq 'run: sudo ./test/task2-recovery-key-bytes-test.sh' "$workflow" \
        && grep -Fq 'run: python3 ./test/task3-console-pump-test.py' "$workflow"
}

workflow_invokes_static_coverage_test() { # workflow
    grep -Fq 'run: ./test/bootc-secure-ci-test.sh' "$1"
}

workflow_job_block() { # workflow job
    local workflow=$1 job=$2
    awk -v header="  $job:" '
        $0 == header { in_job=1 }
        in_job && $0 ~ /^  [[:alnum:]_-]+:$/ && $0 != header { exit }
        in_job { print }
    ' "$workflow"
}

self_hosted_job_is_main_only() { # workflow job
    local block
    block=$(workflow_job_block "$1" "$2")
    [[ $block == *'runs-on: [self-hosted,'* ]] \
        && [[ $block == *"github.ref == 'refs/heads/main'"* ]]
}

self_hosted_jobs() { # workflow directory
    local workflow
    for workflow in "$1"/*.yml; do
        awk -v workflow="$workflow" '
            /^  [[:alnum:]_-]+:$/ { job=$1; sub(/:$/, "", job) }
            /runs-on: \[self-hosted,/ { print workflow, job }
        ' "$workflow"
    done
}

all_self_hosted_jobs_are_main_only() { # workflow directory
    local workflow job found=0
    while read -r workflow job; do
        found=1
        self_hosted_job_is_main_only "$workflow" "$job" || return 1
    done < <(self_hosted_jobs "$1")
    ((found == 1))
}

all_self_hosted_jobs_avoid_repository_secrets() { # workflow directory
    local workflow job block found=0
    while read -r workflow job; do
        found=1
        block=$(workflow_job_block "$workflow" "$job")
        [[ $block != *'${{ secrets.'* ]] || return 1
    done < <(self_hosted_jobs "$1")
    ((found == 1))
}

self_hosted_job_uses_job_token() { # workflow job
    local block
    block=$(workflow_job_block "$1" "$2")
    [[ $block == *'GHCR_TOKEN: ${{ github.token }}'* ]] \
        && [[ $block != *'GHCR_TOKEN: ${{ secrets.'* ]]
}

workflow_job_selects_runc() { # workflow job
    local workflow=$1 job=$2 block
    block=$(awk -v header="  $job:" '
        $0 == header { in_job=1 }
        in_job && $0 ~ /^  [[:alnum:]_-]+:$/ && $0 != header { exit }
        in_job { print }
    ' "$workflow")
    [[ $block == *'- name: Configure Podman OCI runtime'* ]] \
        && [[ $block == *'runtime = "runc"'* ]] \
        && [[ $block == *"podman info --format '{{.Host.OCIRuntime.Name}}'"* ]] \
        && [[ $block == *'[[ $runtime == runc ]]'* ]] \
        && [[ $block == *'      - name: Build Image'* ]] \
        && [[ ${block%%'      - name: Build Image'*} == *'- name: Configure Podman OCI runtime'* ]]
}

PASS=0
FAIL=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert_true() { local description=$1; shift; if "$@"; then pass "$description"; else fail "$description"; fi; }
assert_false() { local description=$1; shift; if "$@"; then fail "$description"; else pass "$description"; fi; }
unconfigured_harness_blocks_cleanly() { # harness
    local output status
    set +e
    output=$(env -i PATH="$PATH" "$ROOT_DIR/test/$1" 2>&1)
    status=$?
    set -e
    [[ $status -eq 2 && $output == *'BLOCKED:'* && $output != *'Error: retaining'* ]]
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

refs="$work/refs.env"
cat >"$refs" <<'EOF'
OCI_REF=ghcr.io/frostyard/cayo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TRACKING_REF=ghcr.io/frostyard/cayo:secure-test
UPDATE_N1_REF=ghcr.io/frostyard/cayo@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
UPDATE_N2_REF=ghcr.io/frostyard/cayo@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
UPDATE_N1_VERSION=20260729123456
UPDATE_N2_VERSION=20260729123457
ROTATION_OLD_REF=ghcr.io/frostyard/cayo@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
ROTATION_TRANSITION_REF=ghcr.io/frostyard/cayo@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
ROTATION_NEW_REF=ghcr.io/frostyard/cayo@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
EOF
chmod 600 "$refs"

assert_true 'mode-0700 absolute state root is accepted' validate_state_root "$work"
chmod 755 "$work"
assert_false 'world-readable state root is rejected' validate_state_root "$work"
chmod 700 "$work"
assert_true 'plain known refs are sourced' load_refs_env "$refs"
assert_true 'known refs are available after sourcing' test "$OCI_REF" = 'ghcr.io/frostyard/cayo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
printf 'UNKNOWN=value\n' >>"$refs"
assert_false 'unknown refs variable is rejected' load_refs_env "$refs"
cp "$refs" "$work/unknown.env"
head -n -1 "$refs" >"$work/valid.env"
mv "$work/valid.env" "$refs"
chmod 600 "$refs"
printf 'OCI_REF=$(id)\n' >>"$refs"
assert_false 'command substitution is rejected' load_refs_env "$refs"
head -n -1 "$refs" >"$work/valid.env"
mv "$work/valid.env" "$refs"
chmod 600 "$refs"
printf 'OCI_REF =value\n' >>"$refs"
assert_false 'whitespace syntax is rejected' load_refs_env "$refs"
head -n -1 "$refs" >"$work/valid.env"
mv "$work/valid.env" "$refs"
chmod 600 "$refs"
chmod 644 "$refs"
assert_false 'world-readable refs are rejected' load_refs_env "$refs"
assert_true 'unconfigured secure install harness blocks without a cleanup retention diagnostic' \
    unconfigured_harness_blocks_cleanly bootc-secure-install-test.sh
assert_true 'unconfigured secure update harness blocks without a cleanup retention diagnostic' \
    unconfigured_harness_blocks_cleanly bootc-secure-update-test.sh
assert_true 'test-bootc-secure workflow runs Task 1-3 fixture coverage' \
    task123_fixture_coverage_is_present "$ROOT_DIR/.github/workflows/test-bootc-secure.yml"
assert_true 'validate workflow runs Task 1-3 fixture coverage' \
    task123_fixture_coverage_is_present "$ROOT_DIR/.github/workflows/validate.yml"
assert_true 'validate workflow runs the bootc secure CI wiring regression' \
    workflow_invokes_static_coverage_test "$ROOT_DIR/.github/workflows/validate.yml"
assert_true 'every self-hosted workflow job is restricted to main' \
    all_self_hosted_jobs_are_main_only "$ROOT_DIR/.github/workflows"
assert_true 'no self-hosted workflow job receives a repository secret' \
    all_self_hosted_jobs_avoid_repository_secrets "$ROOT_DIR/.github/workflows"
assert_true 'manual full-window uses only its job-scoped token for GHCR' \
    self_hosted_job_uses_job_token "$ROOT_DIR/.github/workflows/test-bootc-secure.yml" live-full-window
assert_true 'nightly full-window uses only its job-scoped token for GHCR' \
    self_hosted_job_uses_job_token "$ROOT_DIR/.github/workflows/bootc-secure-nightly.yml" live-full-window
assert_true 'secure-build selects and verifies the runc OCI runtime' \
    workflow_job_selects_runc "$ROOT_DIR/.github/workflows/build-images.yml" secure-build
assert_true 'mechanics-build selects and verifies the runc OCI runtime' \
    workflow_job_selects_runc "$ROOT_DIR/.github/workflows/build-images.yml" mechanics-build

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
