#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Exercise released Snow predecessor selection through controlled API fixtures.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT_DIR/shared/bootc-secure/ci/resolve-snow-release-predecessor.sh"
failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

write_fixtures() { # state
    local state=$1
    mkdir -p "$state/bin"

cat >"$state/bin/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$PREDECESSOR_FIXTURE_STATE/commands"
[[ $1 == api && $2 == --paginate && $3 == /repos/frostyard/snosi/releases && $4 == --jq && $5 == '.[].body // ""' ]]
[[ ${PREDECESSOR_FIXTURE_CASE:-} != github-pagination-failure ]] || exit 76
printf '%s\n' '<!-- native-ab-tag: 20260731130000 -->'
if [[ ${PREDECESSOR_FIXTURE_CASE:-} == reject-same-and-newer ]]; then
    printf '%s\n' '<!-- snow-tag: 20260731120000 -->'
fi
printf '%s\n' '<!-- snow-tag: 20260731114513 -->'
case ${PREDECESSOR_FIXTURE_CASE:-} in
    skip-incomplete-newer-marker|skip-missing-tag|skip-discovery-failure|skip-malformed-discovery|malformed-resolve-digest)
        printf '%s\n' '<!-- snow-tag: 20260731110000 -->'
        ;;
esac
cat <<'BODIES'
<!-- snow-tag: 20260727175908 -->
<!-- snow-tag: 20260720120000 -->
BODIES
EOF

    cat >"$state/bin/oras" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$PREDECESSOR_FIXTURE_STATE/commands"
image='ghcr.io/frostyard/snow'
case $1 in
    resolve)
        [[ $2 == "$image":* ]]
        tag=${2#*:}
        case "${PREDECESSOR_FIXTURE_CASE:-}:$tag" in
            skip-missing-tag:20260731110000) exit 44 ;;
            malformed-resolve-digest:20260731110000) printf 'not-a-sha256-digest\n' ;;
            *) printf 'sha256:%064d\n' "${tag: -1}" ;;
        esac
        ;;
    discover)
        [[ $2 == --format && $3 == json && $4 == "$image"@sha256:* ]]
        digest=${4##*:}
        case ${PREDECESSOR_FIXTURE_CASE:-}:$digest in
            skip-incomplete-newer-marker:*0) printf '{"referrers":[]}\n' ;;
            skip-discovery-failure:*0) exit 45 ;;
            skip-malformed-discovery:*0) printf '{not-json\n' ;;
            no-eligible-marker:*) printf '{"referrers":[]}\n' ;;
            *) printf '{"referrers":[{"artifactType":"application/vnd.syft+json"}]}\n' ;;
        esac
        ;;
    *) echo "unexpected oras invocation: $*" >&2; exit 99 ;;
esac
EOF
    chmod +x "$state/bin/gh" "$state/bin/oras"
}

run_success() { # case expected output
    local case_name=$1 expected=$2 work state output expected_output commands result status
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' RETURN
    state="$work/state"; output="$work/output"; expected_output="$work/expected-output"
    write_fixtures "$state"
    set +e
    result=$(PREDECESSOR_FIXTURE_STATE="$state" PREDECESSOR_FIXTURE_CASE="$case_name" PATH="$state/bin:$PATH" \
        "$RESOLVER" frostyard/snosi ghcr.io/frostyard/snow 20260731114513 "$output" 2>&1)
    status=$?
    set -e
    [[ $status -eq 0 ]] || fail "$case_name unexpectedly failed"
    [[ -f $output ]] || { fail "$case_name did not write output"; return; }
    printf '%s\n' "$expected" >"$expected_output"
    cmp -s "$expected_output" "$output" || fail "$case_name wrote unexpected output"
    commands=$(<"$state/commands")
    [[ $commands != *'repo tags'* ]] || fail "$case_name used unsafe oras repo tags fallback"
    if [[ $case_name == reject-same-and-newer ]]; then
        [[ $commands != *'resolve ghcr.io/frostyard/snow:20260731120000'* ]] ||
            fail "$case_name resolved a newer marker"
        [[ $commands != *'resolve ghcr.io/frostyard/snow:20260731114513'* ]] ||
            fail "$case_name resolved the current marker"
    fi
    case $case_name in
        malformed-resolve-digest)
            [[ $result == *'resolved to an invalid digest'* ]] ||
                fail "$case_name lacked malformed-digest warning"
            [[ $commands != *'discover --format json ghcr.io/frostyard/snow@not-a-sha256-digest'* ]] ||
                fail "$case_name attempted discovery for a malformed digest"
            ;;
        skip-incomplete-newer-marker)
            [[ $result == *'has no Syft SBOM referrer'* ]] ||
                fail "$case_name lacked no-SBOM warning"
            ;;
        skip-malformed-discovery)
            [[ $result == *'returned malformed discovery JSON'* ]] ||
                fail "$case_name lacked malformed-discovery warning"
            ;;
    esac
}

run_failure() { # case
    local case_name=$1 work state output status result
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' RETURN
    state="$work/state"; output="$work/output"
    write_fixtures "$state"
    set +e
    result=$(PREDECESSOR_FIXTURE_STATE="$state" PREDECESSOR_FIXTURE_CASE="$case_name" PATH="$state/bin:$PATH" \
        "$RESOLVER" frostyard/snosi ghcr.io/frostyard/snow 20260731114513 "$output" 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 ]] || fail "$case_name unexpectedly succeeded"
    [[ $result == *'failed to enumerate GitHub releases'* ]] || fail "$case_name lacked enumeration failure"
    [[ ! -e $output ]] || fail "$case_name wrote output after failed pagination"
}

expected=$'previous=20260727175908\ncurrent=20260731114513'
run_success newest-released-complete "$expected"
run_success skip-incomplete-newer-marker "$expected"
run_success skip-missing-tag "$expected"
run_success skip-discovery-failure "$expected"
run_success skip-malformed-discovery "$expected"
run_success malformed-resolve-digest "$expected"
run_success reject-same-and-newer "$expected"
run_success no-eligible-marker 'skip=true'
run_failure github-pagination-failure

[[ $failures -eq 0 ]] || exit 1
echo "bootc release predecessor fixtures passed"
