#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture coverage for authenticated immutable-digest promotion.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT_DIR/shared/bootc-secure/ci/promote-published-image.sh"
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
IMAGE="ghcr.io/frostyard/floe"
# The cases run with the default (trixie) suite unless a case sets one.
unset SNOSI_BOOTC_SECURE_SUITE
WORK=""
AUTH_FILE=""
PASS=0
FAIL=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

cleanup() { [[ -z "$WORK" ]] || rm -rf "$WORK"; }
trap cleanup EXIT

run_helper() { # image expected-digest auth-file
    local output status
    set +e
    output=$(PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" \
        EXPECTED_AUTH_FILE="$3" EXPECTED_DIGEST="$2" \
        "$HELPER" "$@" 2>&1)
    status=$?
    set -e
    printf '%s\n%s\n' "$status" "$output"
}

run_case() { # description expected-status image expected-digest auth-file
    local result status output
    : >"$WORK/commands"
    result=$(run_helper "$3" "$4" "$5")
    status=${result%%$'\n'*}
    output=${result#*$'\n'}
    if [[ $2 == success && $status -eq 0 ]] || [[ $2 == failure && $status -ne 0 ]]; then
        pass "$1"
    else
        fail "$1 ($output)"
    fi
}

WORK=$(mktemp -d)
mkdir -p "$WORK/bin"
AUTH_FILE="$WORK/config.json"
printf '{"auths":{}}\n' >"$AUTH_FILE"

cat >"$WORK/bin/skopeo" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'skopeo %s\n' "$*" >>"$COMMAND_LOG"
case "$1" in
    copy)
        [[ " $* " == *" --all "* ]]
        [[ " $* " == *" --src-authfile $EXPECTED_AUTH_FILE "* ]]
        [[ " $* " == *" --dest-authfile $EXPECTED_AUTH_FILE "* ]]
        [[ " $* " == *" docker://ghcr.io/frostyard/floe@$EXPECTED_DIGEST docker://ghcr.io/frostyard/floe:latest "* ]]
        [[ ${SKOPEO_COPY_FAIL:-0} != 1 ]]
        ;;
    inspect)
        [[ " $* " == *" --authfile $EXPECTED_AUTH_FILE "* ]]
        [[ " $* " == *" --format {{.Digest}} "* ]]
        [[ " $* " == *" docker://ghcr.io/frostyard/floe:latest "* ]]
        [[ ${SKOPEO_INSPECT_FAIL:-0} != 1 ]]
        printf '%s\n' "${LATEST_DIGEST:-$EXPECTED_DIGEST}"
        ;;
    *) exit 64 ;;
esac
EOF
chmod +x "$WORK/bin/skopeo"

run_case "authenticated immutable promotion succeeds" success "$IMAGE" "$DIGEST" "$AUTH_FILE"
grep -Fqx "skopeo copy --all --src-authfile $AUTH_FILE --dest-authfile $AUTH_FILE docker://$IMAGE@$DIGEST docker://$IMAGE:latest" "$WORK/commands" &&
    pass "copy has explicit source and destination auth" ||
    fail "copy has explicit source and destination auth"
grep -Fqx "skopeo inspect --authfile $AUTH_FILE --format {{.Digest}} docker://$IMAGE:latest" "$WORK/commands" &&
    pass "inspect has explicit auth and digest format" ||
    fail "inspect has explicit auth and digest format"

run_case "malformed repository is rejected" failure "ghcr.io/frostyard/untrusted" "$DIGEST" "$AUTH_FILE"
run_case "tagged repository is rejected" failure "$IMAGE:version" "$DIGEST" "$AUTH_FILE"
run_case "malformed digest is rejected" failure "$IMAGE" "sha256:not-a-digest" "$AUTH_FILE"
run_case "missing auth file is rejected" failure "$IMAGE" "$DIGEST" "$WORK/missing/config.json"
mkdir "$WORK/directory-auth"
run_case "directory auth path is rejected" failure "$IMAGE" "$DIGEST" "$WORK/directory-auth"
cp "$AUTH_FILE" "$WORK/auth.json"
run_case "non-config.json auth file is rejected" failure "$IMAGE" "$DIGEST" "$WORK/auth.json"
SKOPEO_COPY_FAIL=1 run_case "copy failure is propagated" failure "$IMAGE" "$DIGEST" "$AUTH_FILE"
SKOPEO_INSPECT_FAIL=1 run_case "inspect failure is propagated" failure "$IMAGE" "$DIGEST" "$AUTH_FILE"
LATEST_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    run_case "latest digest mismatch is rejected" failure "$IMAGE" "$DIGEST" "$AUTH_FILE"

# Only trixie moves latest (ADR-0038). A forky or unknown suite must refuse
# before any registry call, with a clear message and exit status 2.
run_suite_refusal() { # description suite expected-text
    local output status
    : >"$WORK/commands"
    set +e
    output=$(SNOSI_BOOTC_SECURE_SUITE=$2 PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" \
        EXPECTED_AUTH_FILE="$AUTH_FILE" EXPECTED_DIGEST="$DIGEST" \
        "$HELPER" "$IMAGE" "$DIGEST" "$AUTH_FILE" 2>&1)
    status=$?
    set -e
    if [[ $status -eq 2 && ! -s "$WORK/commands" && $output == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1 (status $status: $output)"
    fi
}
run_suite_refusal "forky suite never promotes to latest" forky \
    'refusing to promote a forky image to latest'
run_suite_refusal "unknown suite never promotes to latest" sid \
    'unsupported SNOSI_BOOTC_SECURE_SUITE: sid'
SNOSI_BOOTC_SECURE_SUITE=trixie run_case "explicit trixie suite promotes" success "$IMAGE" "$DIGEST" "$AUTH_FILE"
SNOSI_BOOTC_SECURE_SUITE='' run_case "empty suite promotes as trixie" success "$IMAGE" "$DIGEST" "$AUTH_FILE"

printf '# Results: %d passed, %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"
