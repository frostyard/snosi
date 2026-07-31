#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture coverage for the fail-closed remote secure-image verifier.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT_DIR/shared/bootc-secure/ci/verify-published-image.sh"
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
IMAGE="ghcr.io/frostyard/cayo"
VERSION="20260729010101"
LOCAL_REF="localhost/snosi-verified-cayo:$VERSION"
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
    output=$(PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" COPIED_POLICY="$WORK/copied-policy.json" "$HELPER" "$@" 2>&1)
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
AUTH_FILE="$WORK/auth.json"
printf '{"auths":{}}\n' >"$AUTH_FILE"
cat >"$WORK/bin/skopeo" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'skopeo %s\n' "$*" >>"$COMMAND_LOG"
case "$1" in
    inspect) printf '%s\n' "$INSPECTION" ;;
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
printf 'cosign %s\n' "$*" >>"$COMMAND_LOG"
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
INSPECTION=$(jq -nc --arg digest "$DIGEST" '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "true", "io.snosi.bootc.secureboot-assembly": "bootc-1.16.3-storage-digest-v1"}}')

run_case "accepted immutable secure image is copied" success "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
grep -Fqx "cosign verify --key $ROOT_DIR/cosign.pub $IMAGE@$DIGEST" "$WORK/commands" && pass "Cosign verifies the immutable image with the committed key" || fail "Cosign verifies the immutable image with the committed key"
grep -Fq "skopeo copy --src-authfile $AUTH_FILE --policy " "$WORK/commands" && grep -Fq -- "--registries.d " "$WORK/commands" && grep -Fq "docker://$IMAGE@$DIGEST containers-storage:$LOCAL_REF" "$WORK/commands" && pass "policy copy uses immutable source and root containers storage" || fail "policy copy uses immutable source and root containers storage"
if jq -e '.default == [{"type":"reject"}]' "$WORK/copied-policy.json" >/dev/null; then pass "copied policy retains global reject"; else fail "copied policy retains global reject"; fi
if jq -e --arg key "$ROOT_DIR/cosign.pub" '
    [.transports.docker | keys[]] == ["ghcr.io/frostyard/cayo", "ghcr.io/frostyard/snow", "ghcr.io/frostyard/snowfield"] and
    [.transports.docker[][]] == [
        {"type":"sigstoreSigned", "keyPath":$key, "signedIdentity":{"type":"matchRepository"}},
        {"type":"sigstoreSigned", "keyPath":$key, "signedIdentity":{"type":"matchRepository"}},
        {"type":"sigstoreSigned", "keyPath":$key, "signedIdentity":{"type":"matchRepository"}}
    ]
' "$WORK/copied-policy.json" >/dev/null; then pass "copied policy retains exactly the three scoped Cosign rules"; else fail "copied policy retains exactly the three scoped Cosign rules"; fi
if jq -e '.transports["containers-storage"][""] == [{"type":"insecureAcceptAnything"}]' "$WORK/copied-policy.json" >/dev/null; then pass "copied policy retains the containers-storage exception"; else fail "copied policy retains the containers-storage exception"; fi
if [[ $(sed -n '1p' "$WORK/commands") == "skopeo inspect docker://$IMAGE@$DIGEST" ]] && [[ $(sed -n '2p' "$WORK/commands") == "cosign verify --key $ROOT_DIR/cosign.pub $IMAGE@$DIGEST" ]] && [[ $(sed -n '4p' "$WORK/commands") == "skopeo copy --src-authfile $AUTH_FILE "* ]]; then pass "verification orders inspect before Cosign before policy copy"; else fail "verification orders inspect before Cosign before policy copy"; fi
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

run_case "tagged image reference is rejected" failure "$IMAGE:$VERSION" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
run_case "wrong image repository is rejected" failure "ghcr.io/frostyard/untrusted" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
run_case "malformed digest is rejected" failure "$IMAGE" "$VERSION" "sha256:not-a-digest" "$LOCAL_REF" "$AUTH_FILE"
run_case "mismatched local reference is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "localhost/snosi-verified-snow:$VERSION" "$AUTH_FILE"
run_case "malformed version tag is rejected" failure "$IMAGE" "latest" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"

INSPECTION=$(jq -nc --arg digest "$DIGEST" '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "false", "io.snosi.bootc.secureboot-assembly": "bootc-1.16.3-storage-digest-v1"}}')
run_case "false secure capability is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
INSPECTION=$(jq -nc --arg digest "$DIGEST" '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-assembly": "bootc-1.16.3-storage-digest-v1"}}')
run_case "missing secure capability is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
INSPECTION=$(jq -nc --arg digest "$DIGEST" '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "true", "io.snosi.bootc.secureboot-assembly": "wrong"}}')
run_case "wrong secure assembly is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
INSPECTION=$(jq -nc --arg digest "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "true", "io.snosi.bootc.secureboot-assembly": "bootc-1.16.3-storage-digest-v1"}}')
run_case "remote digest mismatch is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"

INSPECTION=$(jq -nc --arg digest "$DIGEST" '{Digest: $digest, Labels: {"io.snosi.bootc.secureboot-capable": "true", "io.snosi.bootc.secureboot-assembly": "bootc-1.16.3-storage-digest-v1"}}')
COSIGN_VERIFY_FAIL=1 run_case "failed Cosign verification is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
SKOPEO_COPY_FAIL=1 run_case "failed policy copy is rejected" failure "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"

if [[ -f "$HELPER" ]] && ! grep -Eiq '(skopeo|docker)[^#]*(push|tag)|latest' "$HELPER"; then
    pass "helper has no publication or mutable-tag operation"
else
    fail "helper has no publication or mutable-tag operation"
fi

printf '# Results: %d passed, %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"
