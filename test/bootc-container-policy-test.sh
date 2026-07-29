#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Verify the secure bootc OCI signature policy contract.
# shellcheck disable=SC2016 # The checks below intentionally match literal shell source.
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
POLICY="$PROJECT_ROOT/shared/bootc-secure/tree/etc/containers/policy.json"
SECURE_CONFIG="$PROJECT_ROOT/shared/bootc-secure/mkosi.conf"
REGISTRIES_CONFIG="$PROJECT_ROOT/shared/bootc-secure/tree/etc/containers/registries.d/frostyard.yaml"
VM_LIB="$PROJECT_ROOT/test/lib/vm.sh"
UPDATER="$PROJECT_ROOT/mkosi.images/base/mkosi.extra/usr/libexec/bootc-update-stage"

failures=0

pass() {
    printf 'ok - %s\n' "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failures=$((failures + 1))
}

require_file() {
    local path=$1 description=$2
    if [[ -f "$path" ]]; then
        pass "$description"
    else
        fail "$description ($path is missing)"
    fi
}

require_file "$POLICY" "secure bootc policy is shipped"
require_file "$PROJECT_ROOT/cosign.pub" "committed Cosign public key exists"

if [[ -f "$POLICY" ]] && command -v jq >/dev/null; then
    if jq -e '.default == [{"type":"reject"}]' "$POLICY" >/dev/null; then
        pass "unlisted images are rejected"
    else
        fail "unlisted images are rejected"
    fi

    for image in cayo snow snowfield; do
        scope="ghcr.io/frostyard/$image"
        if jq -e --arg scope "$scope" '
            .transports.docker[$scope] == [{
                "type": "sigstoreSigned",
                "keyPath": "/usr/lib/snosi/cosign.pub",
                "signedIdentity": {"type": "matchRepository"}
            }]
        ' "$POLICY" >/dev/null; then
            pass "valid $scope signatures are accepted"
        else
            fail "valid $scope signatures are accepted"
        fi
    done

    if jq -e '.transports["containers-storage"][""] == [{"type":"insecureAcceptAnything"}]' "$POLICY" >/dev/null; then
        pass "previously policy-verified local storage images are accepted"
    else
        fail "previously policy-verified local storage images are accepted"
    fi

    for image in cayo snow snowfield; do
        scope="ghcr.io/frostyard/${image}-wrong-repository"
        if jq -e --arg scope "$scope" '.transports.docker[$scope] == null' "$POLICY" >/dev/null; then
            pass "wrong repository $scope is rejected"
        else
            fail "wrong repository $scope is rejected"
        fi
    done

    if jq -e '[.transports.docker | keys[] | select(startswith("ghcr.io/frostyard/"))] == ["ghcr.io/frostyard/cayo", "ghcr.io/frostyard/snow", "ghcr.io/frostyard/snowfield"]' "$POLICY" >/dev/null; then
        pass "only the three supported GHCR repositories are trusted"
    else
        fail "only the three supported GHCR repositories are trusted"
    fi
else
    fail "policy is valid JSON (jq and the policy are required)"
fi

if grep -Fqx 'ExtraTrees=%D/cosign.pub:/usr/lib/snosi/cosign.pub' "$SECURE_CONFIG"; then
    pass "secure image ships the committed Cosign key"
else
    fail "secure image ships the committed Cosign key"
fi

if [[ -f "$REGISTRIES_CONFIG" ]] && grep -Fqx '    use-sigstore-attachments: true' "$REGISTRIES_CONFIG"; then
    pass "Cosign signature attachments are enabled for GHCR"
else
    fail "Cosign signature attachments are enabled for GHCR"
fi

if grep -Fqx 'IMAGE_IS_FIXTURE="${IMAGE_IS_FIXTURE:-0}"' "$VM_LIB" && \
        grep -Fqx '        IMAGE_IS_FIXTURE=0' "$VM_LIB" && \
        grep -Fqx '        IMAGE_IS_FIXTURE=1' "$VM_LIB" && \
        grep -Fqx '    if [[ "$IMAGE_IS_FIXTURE" == "1" ]]; then' "$VM_LIB"; then
    pass "only local fixtures receive the isolated permissive policy"
else
    fail "only local fixtures receive the isolated permissive policy"
fi

if grep -Fq -- '--skip-fetch-check' "$VM_LIB"; then
    fail "secure install path does not skip fetch verification"
else
    pass "secure install path does not skip fetch verification"
fi

if grep -Fq 'podman pull --policy' "$VM_LIB"; then
    fail "registry test pulls use Podman's configured policy path"
else
    pass "registry test pulls use Podman's configured policy path"
fi

if grep -Fqx '        podman_env=(HOME="$IMAGE_POLICY_HOME")' "$VM_LIB" && \
        grep -Fq 'env "${podman_env[@]}" podman run' "$VM_LIB"; then
    pass "registry install uses the storage that enforced its policy"
else
    fail "registry install uses the storage that enforced its policy"
fi

if grep -Fqx 'RUN_DIR=${SNOSI_RUN_DIR:-/run/snosi}' "$UPDATER"; then
    pass "updater exposes isolated runtime state for behavioral tests"
else
    fail "updater exposes isolated runtime state for behavioral tests"
fi

run_updater_fixture() { # staged digest or empty
    local staged=$1 work status rc
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    mkdir "$work/bin" "$work/run"
    cat >"$work/bin/bootc" <<'EOF'
#!/bin/bash
[[ $1 == status ]] && printf '%s\n' "$BOOTC_STATUS"
EOF
    cat >"$work/bin/podman" <<'EOF'
#!/bin/bash
[[ $1 == image ]] && exit 0
echo 'Source image rejected: A signature was required, but no signature exists' >&2
exit 1
EOF
    chmod +x "$work/bin/bootc" "$work/bin/podman"
    if [[ -n "$staged" ]]; then
        status=$(jq -nc --arg staged "$staged" '{spec:{image:{image:"ghcr.io/frostyard/cayo:latest",transport:"containers-storage"}},status:{booted:{image:{imageDigest:"sha256:booted"}},staged:{image:{imageDigest:$staged}},rollback:{image:{}}}}')
    else
        status=$(jq -nc '{spec:{image:{image:"ghcr.io/frostyard/cayo:latest",transport:"containers-storage"}},status:{booted:{image:{imageDigest:"sha256:booted"}},staged:{},rollback:{image:{}}}}')
    fi
    printf 'stale=yes\n' >"$work/run/update-staged"
    set +e
    PATH="$work/bin:$PATH" BOOTC_STATUS="$status" SNOSI_RUN_DIR="$work/run" "$UPDATER" >/dev/null 2>&1
    rc=$?
    set -e
    if [[ $rc -eq 0 ]] || ! grep -Fqx 'outcome=failed' "$work/run/update-check"; then
        fail "updater records failed pull"
        return
    fi
    if [[ -n "$staged" ]]; then
        if grep -Fqx "digest=$staged" "$work/run/update-staged"; then pass "updater reasserts real staged deployment after pull failure"; else fail "updater reasserts real staged deployment after pull failure"; fi
    else
        if [[ ! -e "$work/run/update-staged" ]]; then pass "updater clears stale semaphore without staged deployment"; else fail "updater clears stale semaphore without staged deployment"; fi
    fi
}
run_updater_fixture sha256:already-staged
run_updater_fixture ''

run_live_policy_proof() {
    local live_home host_policy wrong_key_policy wrong_identity_policy unsigned_policy wrong_key log
    local image
    local -a live_images=()
    local -a required=(podman jq openssl skopeo)
    local command

    for command in "${required[@]}"; do
        if ! command -v "$command" >/dev/null; then
            printf 'BLOCKED: live policy proof requires %s\n' "$command" >&2
            return 2
        fi
    done

    live_home=$(mktemp -d)
    host_policy=$(mktemp)
    wrong_key_policy=$(mktemp)
    wrong_identity_policy=$(mktemp)
    unsigned_policy=$(mktemp)
    wrong_key=$(mktemp)
    log=$(mktemp)
    trap 'podman unshare rm -rf "$live_home" 2>/dev/null || true; rm -f "$host_policy" "$wrong_key_policy" "$wrong_identity_policy" "$unsigned_policy" "$wrong_key" "$log"' RETURN

    mkdir -p "$live_home/.config/containers/registries.d"
    cp "$REGISTRIES_CONFIG" "$live_home/.config/containers/registries.d/frostyard.yaml"
    jq --arg key "$PROJECT_ROOT/cosign.pub" '
        (.transports.docker[][] | select(.type == "sigstoreSigned").keyPath) = $key
    ' "$POLICY" >"$host_policy"
    cp "$host_policy" "$live_home/.config/containers/policy.json"
    openssl ecparam -name prime256v1 -genkey -noout | \
        openssl ec -pubout >"$wrong_key"
    jq --arg key "$wrong_key" '
        (.transports.docker[][] | select(.type == "sigstoreSigned").keyPath) = $key
    ' "$POLICY" >"$wrong_key_policy"
    jq --arg key "$PROJECT_ROOT/cosign.pub" '
        {default: [{type: "reject"}], transports: {docker: {"docker.io/library/busybox": [{type: "sigstoreSigned", keyPath: $key, signedIdentity: {type: "matchRepository"}}]}}}
    ' "$POLICY" >"$unsigned_policy"
    jq --arg key "$PROJECT_ROOT/cosign.pub" '
        {default: [{type: "reject"}], transports: {docker: {"ghcr.io/frostyard/cayo": [{type: "sigstoreSigned", keyPath: $key, signedIdentity: {type: "exactRepository", dockerRepository: "ghcr.io/frostyard/snow"}}]}}}
    ' "$POLICY" >"$wrong_identity_policy"

    expect_policy_rejection() { # description policy image
        cp "$2" "$live_home/.config/containers/policy.json"
        if HOME="$live_home" podman pull "$3" >"$log" 2>&1; then
            fail "$1"
        elif grep -Eiq 'signature.*(required|invalid|not accepted)|Source image rejected|policy.*reject' "$log"; then
            pass "$1"
        else
            fail "$1 (missing policy/signature diagnostic: $(<"$log"))"
        fi
    }

    IFS=, read -r -a live_images <<<"${LIVE_IMAGES:-cayo}"
    for image in "${live_images[@]}"; do
        case "$image" in
            cayo|snow|snowfield) ;;
            *) printf 'BLOCKED: LIVE_IMAGES contains unsupported product %s\n' "$image" >&2; return 2 ;;
        esac
        if HOME="$live_home" podman pull "ghcr.io/frostyard/$image:latest" >/dev/null 2>&1; then
            pass "live Cosign v2.6.1 signature for ghcr.io/frostyard/$image is accepted"
        else
            fail "live Cosign v2.6.1 signature for ghcr.io/frostyard/$image is accepted"
        fi
        if HOME="$live_home" skopeo inspect "containers-storage:ghcr.io/frostyard/$image:latest" >/dev/null 2>&1; then
            pass "policy-verified ghcr.io/frostyard/$image is consumable from containers-storage"
        else
            fail "policy-verified ghcr.io/frostyard/$image is consumable from containers-storage"
        fi
    done

    expect_policy_rejection "scoped unsigned image is rejected" "$unsigned_policy" docker.io/library/busybox:latest
    expect_policy_rejection "wrong Cosign key is rejected" "$wrong_key_policy" ghcr.io/frostyard/cayo:latest
    expect_policy_rejection "signature repository identity mismatch is rejected" "$wrong_identity_policy" ghcr.io/frostyard/cayo:latest
}

if [[ "${RUN_LIVE:-0}" == "1" ]]; then
    run_live_policy_proof || {
        status=$?
        (( status == 2 )) && exit 2
        exit "$status"
    }
else
    printf 'note: set RUN_LIVE=1 to verify published Cosign v2.6.1 signatures with Podman\n'
fi

if (( failures > 0 )); then
    exit 1
fi
