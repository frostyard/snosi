#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture coverage for promote-forky-image.sh (ADR-0040): it moves only the
# forky tag, only for the forky suite, and only to the expected digest.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT_DIR/shared/bootc-secure/ci/promote-forky-image.sh"
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
IMAGE="ghcr.io/frostyard/snow"
# The cases run with the forky suite unless a case sets another one.
export SNOSI_BOOTC_SECURE_SUITE=forky
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

# A refusal before any registry call: exit status 2 and an empty command log.
run_refusal() { # description image expected-digest auth-file
    local result status output
    : >"$WORK/commands"
    result=$(run_helper "$2" "$3" "$4")
    status=${result%%$'\n'*}
    output=${result#*$'\n'}
    if [[ $status -eq 2 && ! -s "$WORK/commands" ]]; then
        pass "$1"
    else
        fail "$1 (status $status: $output)"
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
        [[ " $* " == *" docker://ghcr.io/frostyard/snow@$EXPECTED_DIGEST docker://ghcr.io/frostyard/snow:forky "* ]]
        [[ ${SKOPEO_COPY_FAIL:-0} != 1 ]]
        ;;
    inspect)
        [[ " $* " == *" --authfile $EXPECTED_AUTH_FILE "* ]]
        [[ " $* " == *" --format {{.Digest}} "* ]]
        [[ " $* " == *" docker://ghcr.io/frostyard/snow:forky "* ]]
        [[ ${SKOPEO_INSPECT_FAIL:-0} != 1 ]]
        printf '%s\n' "${FORKY_DIGEST:-$EXPECTED_DIGEST}"
        ;;
    *) exit 64 ;;
esac
EOF
chmod +x "$WORK/bin/skopeo"

# Success: exactly 1 copy to :forky and 1 inspect of :forky, nothing else.
run_case "forky promotion succeeds" success "$IMAGE" "$DIGEST" "$AUTH_FILE"
expected_log="skopeo copy --all --src-authfile $AUTH_FILE --dest-authfile $AUTH_FILE docker://$IMAGE@$DIGEST docker://$IMAGE:forky
skopeo inspect --authfile $AUTH_FILE --format {{.Digest}} docker://$IMAGE:forky"
[[ $(cat "$WORK/commands") == "$expected_log" ]] &&
    pass "copies the digest to :forky only and checks :forky" ||
    fail "copies the digest to :forky only and checks :forky ($(cat "$WORK/commands"))"
grep -q 'latest' "$WORK/commands" &&
    fail "never names latest" ||
    pass "never names latest"

# Mismatch after the copy fails.
FORKY_DIGEST="$OTHER_DIGEST" \
    run_case "forky digest mismatch after the copy is rejected" failure "$IMAGE" "$DIGEST" "$AUTH_FILE"
SKOPEO_COPY_FAIL=1 run_case "copy failure is propagated" failure "$IMAGE" "$DIGEST" "$AUTH_FILE"
SKOPEO_INSPECT_FAIL=1 run_case "inspect failure is propagated" failure "$IMAGE" "$DIGEST" "$AUTH_FILE"

# Invalid references and auth files are refused before any registry call.
run_refusal "untrusted repository is rejected" "ghcr.io/frostyard/untrusted" "$DIGEST" "$AUTH_FILE"
run_refusal "tagged repository is rejected" "$IMAGE:forky" "$DIGEST" "$AUTH_FILE"
run_refusal "other registry is rejected" "docker.io/frostyard/snow" "$DIGEST" "$AUTH_FILE"
run_refusal "malformed digest is rejected" "$IMAGE" "sha256:not-a-digest" "$AUTH_FILE"
run_refusal "tag as digest is rejected" "$IMAGE" "forky-20261114000000" "$AUTH_FILE"
run_refusal "uppercase digest is rejected" "$IMAGE" "${DIGEST^^}" "$AUTH_FILE"
run_refusal "missing auth file is rejected" "$IMAGE" "$DIGEST" "$WORK/missing/config.json"
cp "$AUTH_FILE" "$WORK/auth.json"
run_refusal "non-config.json auth file is rejected" "$IMAGE" "$DIGEST" "$WORK/auth.json"

# Only forky moves :forky. Trixie (explicit, unset or empty) and an unknown
# suite refuse before any registry call, with exit status 2.
run_suite_refusal() { # description suite-value-or-UNSET expected-text
    local output status
    : >"$WORK/commands"
    set +e
    if [[ $2 == UNSET ]]; then
        output=$(unset SNOSI_BOOTC_SECURE_SUITE; PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" \
            EXPECTED_AUTH_FILE="$AUTH_FILE" EXPECTED_DIGEST="$DIGEST" \
            "$HELPER" "$IMAGE" "$DIGEST" "$AUTH_FILE" 2>&1)
    else
        output=$(SNOSI_BOOTC_SECURE_SUITE=$2 PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" \
            EXPECTED_AUTH_FILE="$AUTH_FILE" EXPECTED_DIGEST="$DIGEST" \
            "$HELPER" "$IMAGE" "$DIGEST" "$AUTH_FILE" 2>&1)
    fi
    status=$?
    set -e
    if [[ $status -eq 2 && ! -s "$WORK/commands" && $output == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1 (status $status: $output)"
    fi
}
run_suite_refusal "trixie suite never moves the forky tag" trixie \
    'refusing to move the forky tag to a trixie image'
run_suite_refusal "unset suite (trixie) never moves the forky tag" UNSET \
    'refusing to move the forky tag to a trixie image'
run_suite_refusal "empty suite (trixie) never moves the forky tag" '' \
    'refusing to move the forky tag to a trixie image'
run_suite_refusal "unknown suite never moves the forky tag" sid \
    'unsupported SNOSI_BOOTC_SECURE_SUITE: sid'

printf '# Results: %d passed, %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"
