#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture coverage for the fail-closed remote secure-image verifier.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT_DIR/shared/bootc-secure/ci/verify-published-image.sh"
CONTRACT="$ROOT_DIR/shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json"
POLICY="$ROOT_DIR/shared/bootc-secure/tree/usr/lib/snosi/containers/bootc-policy.json"
ASSEMBLY_COMPATIBILITY=$(jq -er '.assembly.compatibility' "$CONTRACT")
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
IMAGE="ghcr.io/frostyard/floe"
VERSION="20260729010101"
LOCAL_REF="localhost/snosi-verified-floe:$VERSION"
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

assert_success() { # description command output
    if [[ $2 -eq 0 ]]; then
        pass "$1"
    else
        fail "$1 ($3)"
    fi
}

assert_failure() { # description command output
    if [[ $2 -ne 0 ]]; then
        pass "$1"
    else
        fail "$1 (unexpected success: $3)"
    fi
}

run_helper() { # image version digest local-ref auth-file
    local output status
    set +e
    output=$(PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" COPIED_POLICY="$WORK/copied-policy.json" EXPECTED_AUTH_FILE="$5" EXPECTED_DIGEST="$3" "$HELPER" "$@" 2>&1)
    status=$?
    set -e
    printf '%s\n%s\n' "$status" "$output"
}

run_case() { # description expected-status image version digest local-ref auth-file
    local result status output
    : >"$WORK/commands"
    result=$(run_helper "$3" "$4" "$5" "$6" "$7")
    status=${result%%$'\n'*}
    output=${result#*$'\n'}
    if [[ $2 == success ]]; then
        assert_success "$1" "$status" "$output"
    else
        assert_failure "$1" "$status" "$output"
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
    inspect)
        [[ " $* " == *" --authfile $EXPECTED_AUTH_FILE "* ]]
        if [[ " $* " == *" --format {{.Digest}} "* ]]; then
            printf '%s\n' "${TAG_DIGEST:-$EXPECTED_DIGEST}"
        else
            printf '%s\n' "$INSPECTION"
        fi
        ;;
    copy)
        while (($# > 0)); do
            case "$1" in
                --policy) cp "$2" "$COPIED_POLICY"; shift 2 ;;
                *) shift ;;
            esac
        done
        [[ ${SKOPEO_COPY_FAIL:-0} != 1 ]]
        ;;
    *) exit 64 ;;
esac
EOF
cat >"$WORK/bin/cosign" <<'EOF'
#!/bin/bash
set -euo pipefail
expected_dir=$(dirname -- "$EXPECTED_AUTH_FILE")
printf 'DOCKER_CONFIG=%s cosign %s\n' "${DOCKER_CONFIG:-}" "$*" >>"$COMMAND_LOG"
[[ ${DOCKER_CONFIG:-} == "$expected_dir" ]]
[[ ${COSIGN_VERIFY_FAIL:-0} != 1 ]]
EOF
cat >"$WORK/bin/sudo" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
exec "$@"
EOF
chmod +x "$WORK/bin/skopeo" "$WORK/bin/cosign" "$WORK/bin/sudo"

export INSPECTION
INSPECTION=$(jq -nc --arg digest "$DIGEST" --arg compatibility "$ASSEMBLY_COMPATIBILITY" \
    '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "true", "io.snosi.bootc.secureboot-assembly": $compatibility}}')

run_case "accepted immutable secure image is copied" success "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
grep -Fqx "skopeo inspect --authfile $AUTH_FILE docker://$IMAGE@$DIGEST" "$WORK/commands" && pass "Skopeo inspects immutable metadata with explicit auth" || fail "Skopeo inspects immutable metadata with explicit auth"
grep -Fqx "skopeo inspect --authfile $AUTH_FILE --format {{.Digest}} docker://$IMAGE:$VERSION" "$WORK/commands" && pass "Skopeo resolves the version tag with explicit auth" || fail "Skopeo resolves the version tag with explicit auth"
grep -Fqx "DOCKER_CONFIG=$(dirname -- "$AUTH_FILE") cosign verify --key $ROOT_DIR/cosign.pub $IMAGE@$DIGEST" "$WORK/commands" && pass "Cosign verifies the immutable image with the command-scoped auth config" || fail "Cosign verifies the immutable image with the command-scoped auth config"
grep -Fq "skopeo copy --src-authfile $AUTH_FILE --policy " "$WORK/commands" && grep -Fq -- "--registries.d " "$WORK/commands" && grep -Fq "docker://$IMAGE@$DIGEST containers-storage:$LOCAL_REF" "$WORK/commands" && pass "policy copy uses immutable source and root containers storage" || fail "policy copy uses immutable source and root containers storage"
if jq -e '.default == [{"type":"reject"}]' "$WORK/copied-policy.json" >/dev/null; then pass "copied policy retains global reject"; else fail "copied policy retains global reject"; fi
expected_policy_scopes=$(jq -c '.transports.docker | keys' "$POLICY")
if jq -e --arg key "$ROOT_DIR/cosign.pub" --argjson expected "$expected_policy_scopes" '
    (.transports.docker | keys) == $expected and
    all(.transports.docker[]; . == [{"type":"sigstoreSigned", "keyPath":$key, "signedIdentity":{"type":"matchRepository"}}])
' "$WORK/copied-policy.json" >/dev/null; then pass "copied policy retains one scoped Cosign rule per supported repository"; else fail "copied policy retains one scoped Cosign rule per supported repository"; fi
if jq -e '.transports["containers-storage"][""] == [{"type":"insecureAcceptAnything"}]' "$WORK/copied-policy.json" >/dev/null; then pass "copied policy retains the containers-storage exception"; else fail "copied policy retains the containers-storage exception"; fi
if [[ $(sed -n '1p' "$WORK/commands") == "skopeo inspect --authfile $AUTH_FILE docker://$IMAGE@$DIGEST" ]] && [[ $(sed -n '2p' "$WORK/commands") == "skopeo inspect --authfile $AUTH_FILE --format {{.Digest}} docker://$IMAGE:$VERSION" ]] && [[ $(sed -n '3p' "$WORK/commands") == "DOCKER_CONFIG=$(dirname -- "$AUTH_FILE") cosign verify --key $ROOT_DIR/cosign.pub $IMAGE@$DIGEST" ]] && [[ $(sed -n '5p' "$WORK/commands") == "skopeo copy --src-authfile $AUTH_FILE "* ]]; then pass "verification orders explicit metadata reads before Cosign before policy copy"; else fail "verification orders explicit metadata reads before Cosign before policy copy"; fi
grep -Fq "skopeo copy --src-authfile $AUTH_FILE --policy " "$WORK/commands" &&
        pass "root policy copy receives the explicit source auth file" ||
        fail "root policy copy receives the explicit source auth file"
if ! sed -n '1,2p' "$WORK/commands" | grep -Fq -- '--src-authfile'; then
    pass "inspect and Cosign do not receive the root copy auth option"
else
    fail "inspect and Cosign do not receive the root copy auth option"
fi
run_case "missing source auth file is rejected" failure \
    "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$WORK/missing-auth.json"
run_case "non-regular source auth path is rejected" failure \
    "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$WORK"
cp "$AUTH_FILE" "$WORK/auth.json"
run_case "non-config.json auth file is rejected" failure \
    "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$WORK/auth.json"

run_case "tagged image reference is rejected" failure "$IMAGE:$VERSION" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
run_case "wrong image repository is rejected" failure "ghcr.io/frostyard/untrusted" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
run_case "malformed digest is rejected" failure "$IMAGE" "$VERSION" "sha256:not-a-digest" "$LOCAL_REF" "$AUTH_FILE"
run_case "mismatched local reference is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "localhost/snosi-verified-snow:$VERSION" "$AUTH_FILE"
run_case "malformed version tag is rejected" failure "$IMAGE" "latest" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
TAG_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    run_case "version tag digest mismatch is rejected" failure \
    "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"

INSPECTION=$(jq -nc --arg digest "$DIGEST" --arg compatibility "$ASSEMBLY_COMPATIBILITY" \
    '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "false", "io.snosi.bootc.secureboot-assembly": $compatibility}}')
run_case "false secure capability is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
INSPECTION=$(jq -nc --arg digest "$DIGEST" --arg compatibility "$ASSEMBLY_COMPATIBILITY" \
    '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-assembly": $compatibility}}')
run_case "missing secure capability is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
INSPECTION=$(jq -nc --arg digest "$DIGEST" '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "true", "io.snosi.bootc.secureboot-assembly": "wrong"}}')
run_case "wrong secure assembly is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
INSPECTION=$(jq -nc --arg digest "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    --arg compatibility "$ASSEMBLY_COMPATIBILITY" \
    '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "true", "io.snosi.bootc.secureboot-assembly": $compatibility}}')
run_case "remote digest mismatch is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"

INSPECTION=$(jq -nc --arg digest "$DIGEST" --arg compatibility "$ASSEMBLY_COMPATIBILITY" \
    '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "true", "io.snosi.bootc.secureboot-assembly": $compatibility}}')
COSIGN_VERIFY_FAIL=1 run_case "failed Cosign verification is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
SKOPEO_COPY_FAIL=1 run_case "failed policy copy is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"

# SNOSI_BOOTC_SECURE_SUITE selects the contract and the tag form (ADR-0038).
# Forky verifies only forky-<timestamp> tags against the forky contract's
# assembly label; trixie (unset) never accepts a forky tag; an unknown suite
# fails before any registry call.
FORKY_CONTRACT="$ROOT_DIR/shared/bootc-secure/suite/forky/tree/usr/lib/snosi/bootc-secure.json"
FORKY_COMPATIBILITY=$(jq -er '.assembly.compatibility' "$FORKY_CONTRACT")
FORKY_VERSION="forky-$VERSION"
FORKY_LOCAL_REF="localhost/snosi-verified-floe:$FORKY_VERSION"
INSPECTION=$(jq -nc --arg digest "$DIGEST" --arg compatibility "$FORKY_COMPATIBILITY" \
    '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "true", "io.snosi.bootc.secureboot-assembly": $compatibility}}')
SNOSI_BOOTC_SECURE_SUITE=forky run_case "forky suite verifies a forky tag under the forky contract" success \
    "$IMAGE" "$FORKY_VERSION" "$DIGEST" "$FORKY_LOCAL_REF" "$AUTH_FILE"
grep -Fqx "skopeo inspect --authfile $AUTH_FILE --format {{.Digest}} docker://$IMAGE:$FORKY_VERSION" "$WORK/commands" &&
    grep -Fq "docker://$IMAGE@$DIGEST containers-storage:$FORKY_LOCAL_REF" "$WORK/commands" &&
    pass "forky suite resolves and copies the forky tag" ||
    fail "forky suite resolves and copies the forky tag"
SNOSI_BOOTC_SECURE_SUITE=forky run_case "forky suite rejects a bare 14-digit tag" failure \
    "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
SNOSI_BOOTC_SECURE_SUITE=forky run_case "forky suite rejects a local reference of another tag" failure \
    "$IMAGE" "$FORKY_VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
# The trixie label isolates the tag check: only the forky tag can reject here.
INSPECTION=$(jq -nc --arg digest "$DIGEST" --arg compatibility "$ASSEMBLY_COMPATIBILITY" \
    '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "true", "io.snosi.bootc.secureboot-assembly": $compatibility}}')
run_case "unset suite rejects a forky tag" failure \
    "$IMAGE" "$FORKY_VERSION" "$DIGEST" "$FORKY_LOCAL_REF" "$AUTH_FILE"
SNOSI_BOOTC_SECURE_SUITE='' run_case "empty suite rejects a forky tag" failure \
    "$IMAGE" "$FORKY_VERSION" "$DIGEST" "$FORKY_LOCAL_REF" "$AUTH_FILE"
INSPECTION=$(jq -nc --arg digest "$DIGEST" --arg compatibility "$FORKY_COMPATIBILITY" \
    '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "true", "io.snosi.bootc.secureboot-assembly": $compatibility}}')
SNOSI_BOOTC_SECURE_SUITE=sid run_case "unknown suite is rejected" failure \
    "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
if [[ ! -s "$WORK/commands" ]]; then
    pass "unknown suite makes no registry call"
else
    fail "unknown suite makes no registry call"
fi
if [[ $FORKY_COMPATIBILITY != "$ASSEMBLY_COMPATIBILITY" ]]; then
    # While the two contracts differ, each suite must reject the other's label:
    # this shows that the suite, not a fixed path, selects the contract.
    INSPECTION=$(jq -nc --arg digest "$DIGEST" --arg compatibility "$ASSEMBLY_COMPATIBILITY" \
        '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "true", "io.snosi.bootc.secureboot-assembly": $compatibility}}')
    SNOSI_BOOTC_SECURE_SUITE=forky run_case "forky suite rejects an image with the trixie assembly label" failure \
        "$IMAGE" "$FORKY_VERSION" "$DIGEST" "$FORKY_LOCAL_REF" "$AUTH_FILE"
    INSPECTION=$(jq -nc --arg digest "$DIGEST" --arg compatibility "$FORKY_COMPATIBILITY" \
        '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "true", "io.snosi.bootc.secureboot-assembly": $compatibility}}')
    run_case "trixie suite rejects an image with the forky assembly label" failure \
        "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
else
    pass "forky and trixie contracts carry one assembly label; the cross-label cases do not apply"
fi

if [[ -f "$HELPER" ]] && ! grep -Eiq "(skopeo|docker)[^#]*push|docker://[^[:space:]\"']+:latest" "$HELPER"; then
    pass "helper has no publication or mutable-tag operation"
else
    fail "helper has no publication or mutable-tag operation"
fi

printf '# Results: %d passed, %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"
