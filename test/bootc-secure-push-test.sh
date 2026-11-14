#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture coverage for immutable GHCR push retry and fail-closed checks.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT_DIR/shared/bootc-secure/ci/push-immutable-image.sh"
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
IMAGE="ghcr.io/frostyard/floe"
TAG="20260301000000"
# The cases above the suite cases run with the default (trixie) suite.
unset SNOSI_BOOTC_SECURE_SUITE
WORK=""
PASS=0
FAIL=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() { [[ -z "$WORK" ]] || rm -rf "$WORK"; }
trap cleanup EXIT

WORK=$(mktemp -d)
mkdir -p "$WORK/bin"
: >"$WORK/commands"
: >"$WORK/push-count"
: >"$WORK/raw-count"

cat >"$WORK/bin/buildah" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'buildah %s\n' "$*" >>"$COMMAND_LOG"
printf 'Getting image source signatures\n'
printf 'Copying blob sha256:test to registry\n'
printf 'Writing manifest to image destination\n'
count=$(cat "$PUSH_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$PUSH_COUNT"
if [[ ${PUSH_FAIL_ALWAYS:-0} == 1 ]] ||
        [[ ${PUSH_FAIL_ONCE:-0} == 1 && $count -eq 1 ]]; then
    printf 'uploading layer chunked: StatusCode: 400, "<html>edge fault</html>"\n' >&2
    exit 125
fi
for arg in "$@"; do
    case "$arg" in
        --digestfile=*) printf '%s\n' "${MALFORMED_DIGEST:-$EXPECTED_DIGEST}" >"${arg#--digestfile=}" ;;
    esac
done
EOF
chmod +x "$WORK/bin/buildah"

cat >"$WORK/bin/skopeo" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'skopeo %s\n' "$*" >>"$COMMAND_LOG"
case " $* " in
    *" --raw "*)
        raw_count=$(cat "$RAW_COUNT")
        raw_count=$((raw_count + 1))
        printf '%s\n' "$raw_count" >"$RAW_COUNT"
        if [[ ${SKOPEO_CHECK_ERROR_FROM:-0} -ne 0 && $raw_count -ge ${SKOPEO_CHECK_ERROR_FROM:-0} ]]; then
            printf 'unexpected registry error\n' >&2
            exit 1
        fi
        if [[ ${SKOPEO_TAG_EXISTS_FROM:-0} -ne 0 && $raw_count -ge ${SKOPEO_TAG_EXISTS_FROM:-0} ]]; then
            printf '{"digest":"%s"}\n' "$EXPECTED_DIGEST"
            exit 0
        fi
        printf 'manifest unknown: %s\n' "${REGISTRY_TAG:-$EXPECTED_IMAGE:$EXPECTED_TAG}" >&2
        exit 1
        ;;
    *" --format "*)
        printf 'skopeo registry warning\n' >&2
        ;;
esac
printf '%s\n' "${REGISTRY_DIGEST:-$EXPECTED_DIGEST}"
EOF
chmod +x "$WORK/bin/skopeo"

reset_state() {
    : >"$WORK/commands"
    printf '0\n' >"$WORK/push-count"
    printf '0\n' >"$WORK/raw-count"
}

run_helper() {
    local stdout="$WORK/stdout" stderr="$WORK/stderr" status
    set +e
    PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" PUSH_COUNT="$WORK/push-count" RAW_COUNT="$WORK/raw-count" \
        EXPECTED_DIGEST="$DIGEST" EXPECTED_IMAGE="$IMAGE" EXPECTED_TAG="$TAG" \
        SNOSI_PUSH_ATTEMPTS="${SNOSI_PUSH_ATTEMPTS_VALUE:-3}" \
        SNOSI_PUSH_RETRY_DELAY="${SNOSI_PUSH_RETRY_DELAY_VALUE:-0}" \
        PUSH_FAIL_ALWAYS="${PUSH_FAIL_ALWAYS:-0}" \
        PUSH_FAIL_ONCE="${PUSH_FAIL_ONCE:-0}" \
        SKOPEO_TAG_EXISTS_FROM="${SKOPEO_TAG_EXISTS_FROM:-0}" \
        SKOPEO_CHECK_ERROR_FROM="${SKOPEO_CHECK_ERROR_FROM:-0}" \
        MALFORMED_DIGEST="${MALFORMED_DIGEST:-}" \
        REGISTRY_DIGEST="${REGISTRY_DIGEST:-}" \
        "$HELPER" "$IMAGE" "$TAG" >"$stdout" 2>"$stderr"
    status=$?
    set -e
    printf '%s\n' "$status"
}

reset_state
SKOPEO_TAG_EXISTS_FROM=1
result=$(run_helper)
SKOPEO_TAG_EXISTS_FROM=0
if [[ $result -ne 0 ]] && [[ $(cat "$WORK/push-count") -eq 0 ]]; then
    pass "existing tag at entry is rejected without pushing"
else
    fail "existing tag at entry is rejected without pushing"
fi

reset_state
PUSH_FAIL_ONCE=1
result=$(run_helper)
PUSH_FAIL_ONCE=0
if [[ $result -eq 0 ]] && [[ $(cat "$WORK/stdout") == "$DIGEST" ]]; then
    push_count=$(cat "$WORK/push-count")
    if [[ $push_count -eq 2 ]]; then
        pass "first push failure retries once and prints the digest"
    else
        fail "first push failure retries once (got $push_count pushes)"
    fi
else
    fail "first push failure retries once (status $result)"
fi

sed -E 's#--digestfile=[^ ]+#--digestfile=<DIGEST>#' "$WORK/commands" >"$WORK/operations"
cat >"$WORK/expected-operations" <<EOF
skopeo inspect --raw docker://$IMAGE:$TAG
buildah push --compression-format=zstd:chunked --digestfile=<DIGEST> $IMAGE:$TAG docker://$IMAGE:$TAG
skopeo inspect --raw docker://$IMAGE:$TAG
buildah push --compression-format=zstd:chunked --digestfile=<DIGEST> $IMAGE:$TAG docker://$IMAGE:$TAG
skopeo inspect --format {{.Digest}} docker://$IMAGE:$TAG
EOF
if diff -u "$WORK/expected-operations" "$WORK/operations" >/dev/null; then
    pass "retry uses the required buildah and skopeo command order"
else
    fail "retry uses the required buildah and skopeo command order"
fi

reset_state
PUSH_FAIL_ALWAYS=1
SNOSI_PUSH_ATTEMPTS_VALUE=3
result=$(run_helper)
PUSH_FAIL_ALWAYS=0
if [[ $result -ne 0 ]] && [[ $(cat "$WORK/push-count") -eq 3 ]]; then
    pass "all push attempts fail with a bounded retry"
else
    fail "all push attempts fail with a bounded retry"
fi

reset_state
PUSH_FAIL_ONCE=1
SKOPEO_TAG_EXISTS_FROM=2
result=$(run_helper)
PUSH_FAIL_ONCE=0
SKOPEO_TAG_EXISTS_FROM=0
if [[ $result -ne 0 ]] && [[ $(cat "$WORK/push-count") -eq 1 ]] &&
        grep -Fq 'immutable tag must not move' "$WORK/stderr"; then
    pass "a tag that exists after failure stops the retry"
else
    fail "a tag that exists after failure stops the retry"
fi

reset_state
PUSH_FAIL_ONCE=1
SKOPEO_CHECK_ERROR_FROM=2
result=$(run_helper)
PUSH_FAIL_ONCE=0
SKOPEO_CHECK_ERROR_FROM=0
if [[ $result -ne 0 ]] && [[ $(cat "$WORK/push-count") -eq 1 ]]; then
    pass "an unknown tag-check error stops the retry"
else
    fail "an unknown tag-check error stops the retry"
fi

reset_state
REGISTRY_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
result=$(run_helper)
REGISTRY_DIGEST=""
if [[ $result -ne 0 ]]; then
    pass "registry digest mismatch is rejected"
else
    fail "registry digest mismatch is rejected"
fi

reset_state
MALFORMED_DIGEST="not-a-digest"
result=$(run_helper)
MALFORMED_DIGEST=""
if [[ $result -ne 0 ]]; then
    pass "malformed push digest file is rejected"
else
    fail "malformed push digest file is rejected"
fi

reset_state
result=$(run_helper)
plain_status=$result
if [[ $plain_status -eq 0 ]] && [[ $(cat "$WORK/stdout") == "$DIGEST" ]]; then
    pass "valid push fixture succeeds"
else
    fail "valid push fixture succeeds"
fi

for invalid_case in image tag attempts delay; do
    reset_state
    case "$invalid_case" in
        image)
            set +e
            PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" PUSH_COUNT="$WORK/push-count" \
                EXPECTED_DIGEST="$DIGEST" SNOSI_PUSH_RETRY_DELAY=0 \
                "$HELPER" "ghcr.io/frostyard/untrusted" "$TAG" >/dev/null 2>&1
            status=$?
            set -e
            ;;
        tag)
            set +e
            PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" PUSH_COUNT="$WORK/push-count" \
                EXPECTED_DIGEST="$DIGEST" SNOSI_PUSH_RETRY_DELAY=0 \
                "$HELPER" "$IMAGE" "2026" >/dev/null 2>&1
            status=$?
            set -e
            ;;
        attempts)
            set +e
            PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" PUSH_COUNT="$WORK/push-count" \
                EXPECTED_DIGEST="$DIGEST" SNOSI_PUSH_ATTEMPTS=6 SNOSI_PUSH_RETRY_DELAY=0 \
                "$HELPER" "$IMAGE" "$TAG" >/dev/null 2>&1
            status=$?
            set -e
            ;;
        delay)
            set +e
            PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" PUSH_COUNT="$WORK/push-count" \
                EXPECTED_DIGEST="$DIGEST" SNOSI_PUSH_RETRY_DELAY=301 \
                "$HELPER" "$IMAGE" "$TAG" >/dev/null 2>&1
            status=$?
            set -e
            ;;
    esac
    if [[ $status -ne 0 ]] && [[ $(cat "$WORK/push-count") -eq 0 ]]; then
        pass "invalid $invalid_case is rejected without pushing"
    else
        fail "invalid $invalid_case is rejected without pushing"
    fi
done

reset_state
result=$(run_helper)
if [[ $result -eq 0 ]] && grep -Fq "buildah push --compression-format=zstd:chunked --digestfile=" "$WORK/commands" &&
        grep -Fq " $IMAGE:$TAG docker://$IMAGE:$TAG" "$WORK/commands"; then
    pass "push command contains compression, digest file, and exact source/destination"
else
    fail "push command contains compression, digest file, and exact source/destination"
fi

# SNOSI_BOOTC_SECURE_SUITE selects the tag form (ADR-0038): trixie (unset or
# empty) pushes only 14-digit tags, forky pushes only forky-<14 digits>, and an
# unknown suite pushes nothing.
run_suite_helper() { # suite|-unset- tag
    local suite=$1 tag=$2 status
    local -a suite_env=(env SNOSI_BOOTC_SECURE_SUITE="$suite")
    [[ $suite != -unset- ]] || suite_env=(env -u SNOSI_BOOTC_SECURE_SUITE)
    reset_state
    set +e
    "${suite_env[@]}" PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" PUSH_COUNT="$WORK/push-count" \
        RAW_COUNT="$WORK/raw-count" EXPECTED_DIGEST="$DIGEST" EXPECTED_IMAGE="$IMAGE" EXPECTED_TAG="$tag" \
        SNOSI_PUSH_RETRY_DELAY=0 \
        "$HELPER" "$IMAGE" "$tag" >"$WORK/stdout" 2>"$WORK/stderr"
    status=$?
    set -e
    printf '%s\n' "$status"
}

assert_suite_push() { # description suite tag
    local result
    result=$(run_suite_helper "$2" "$3")
    if [[ $result -eq 0 ]] && [[ $(cat "$WORK/stdout") == "$DIGEST" ]] &&
            grep -Eq "^buildah push --compression-format=zstd:chunked --digestfile=[^ ]+ $IMAGE:$3 docker://$IMAGE:$3\$" "$WORK/commands"; then
        pass "$1"
    else
        fail "$1 (status $result: $(cat "$WORK/stderr"))"
    fi
}

assert_suite_refused() { # description suite tag expected-text
    local result
    result=$(run_suite_helper "$2" "$3")
    if [[ $result -eq 2 ]] && [[ $(cat "$WORK/push-count") -eq 0 ]] && [[ ! -s "$WORK/commands" ]] &&
            grep -Fq "$4" "$WORK/stderr"; then
        pass "$1"
    else
        fail "$1 (status $result: $(cat "$WORK/stderr"))"
    fi
}

FORKY_TAG="forky-$TAG"
assert_suite_push "forky suite pushes a forky-<timestamp> tag" forky "$FORKY_TAG"
assert_suite_push "explicit trixie suite pushes a 14-digit tag" trixie "$TAG"
assert_suite_push "unset suite pushes a 14-digit tag" -unset- "$TAG"
assert_suite_refused "forky suite rejects a bare 14-digit tag" forky "$TAG" 'invalid immutable image tag for suite forky'
assert_suite_refused "forky suite rejects a short forky tag" forky "forky-2026" 'invalid immutable image tag for suite forky'
assert_suite_refused "unset suite rejects a forky tag" -unset- "$FORKY_TAG" 'invalid immutable image tag for suite trixie'
assert_suite_refused "empty suite rejects a forky tag" '' "$FORKY_TAG" 'invalid immutable image tag for suite trixie'
assert_suite_refused "trixie suite rejects latest" trixie latest 'invalid immutable image tag for suite trixie'
assert_suite_refused "unknown suite pushes nothing" sid "$TAG" 'unsupported SNOSI_BOOTC_SECURE_SUITE: sid'
assert_suite_refused "unknown suite pushes nothing for a forky tag" sid "$FORKY_TAG" 'unsupported SNOSI_BOOTC_SECURE_SUITE: sid'

printf '# Results: %d passed, %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"
