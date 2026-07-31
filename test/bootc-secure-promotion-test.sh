#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture coverage for authenticated immutable-digest promotion.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT_DIR/shared/bootc-secure/ci/promote-published-image.sh"
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
IMAGE="ghcr.io/frostyard/cayo"
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
        [[ " $* " == *" docker://ghcr.io/frostyard/cayo@$EXPECTED_DIGEST docker://ghcr.io/frostyard/cayo:latest "* ]]
        [[ ${SKOPEO_COPY_FAIL:-0} != 1 ]]
        ;;
    inspect)
        [[ " $* " == *" --authfile $EXPECTED_AUTH_FILE "* ]]
        [[ " $* " == *" --format {{.Digest}} "* ]]
        [[ " $* " == *" docker://ghcr.io/frostyard/cayo:latest "* ]]
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

printf '# Results: %d passed, %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"
