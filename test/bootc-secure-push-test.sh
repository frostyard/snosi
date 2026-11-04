#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture coverage for immutable GHCR push retry and fail-closed checks.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT_DIR/shared/bootc-secure/ci/push-immutable-image.sh"
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
IMAGE="ghcr.io/frostyard/floe"
TAG="20260301000000"
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
if [[ ${SKOPEO_CHECK_ERROR:-0} == 1 ]];
then
    printf 'unexpected registry error\n' >&2
    exit 1
fi
case " $* " in
    *" --raw "*)
        if [[ ${SKOPEO_TAG_EXISTS:-0} == 1 ]]; then
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
}

run_helper() {
    local stdout="$WORK/stdout" stderr="$WORK/stderr" status
    set +e
    PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" PUSH_COUNT="$WORK/push-count" \
        EXPECTED_DIGEST="$DIGEST" EXPECTED_IMAGE="$IMAGE" EXPECTED_TAG="$TAG" \
        SNOSI_PUSH_ATTEMPTS="${SNOSI_PUSH_ATTEMPTS_VALUE:-3}" \
        SNOSI_PUSH_RETRY_DELAY="${SNOSI_PUSH_RETRY_DELAY_VALUE:-0}" \
        PUSH_FAIL_ALWAYS="${PUSH_FAIL_ALWAYS:-0}" \
        PUSH_FAIL_ONCE="${PUSH_FAIL_ONCE:-0}" \
        SKOPEO_TAG_EXISTS="${SKOPEO_TAG_EXISTS:-0}" \
        SKOPEO_CHECK_ERROR="${SKOPEO_CHECK_ERROR:-0}" \
        MALFORMED_DIGEST="${MALFORMED_DIGEST:-}" \
        REGISTRY_DIGEST="${REGISTRY_DIGEST:-}" \
        "$HELPER" "$IMAGE" "$TAG" >"$stdout" 2>"$stderr"
    status=$?
    set -e
    printf '%s\n' "$status"
}

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
SKOPEO_TAG_EXISTS=1
result=$(run_helper)
PUSH_FAIL_ONCE=0
SKOPEO_TAG_EXISTS=0
if [[ $result -ne 0 ]] && [[ $(cat "$WORK/push-count") -eq 1 ]] &&
        grep -Fq 'tag exists after a failed push; an immutable tag must not move' "$WORK/stderr"; then
    pass "a tag that exists after failure stops the retry"
else
    fail "a tag that exists after failure stops the retry"
fi

reset_state
PUSH_FAIL_ONCE=1
SKOPEO_CHECK_ERROR=1
result=$(run_helper)
PUSH_FAIL_ONCE=0
SKOPEO_CHECK_ERROR=0
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

printf '# Results: %d passed, %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"
