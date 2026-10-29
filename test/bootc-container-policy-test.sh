#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Verify the secure bootc OCI signature policy contract.
# shellcheck disable=SC2016 # The checks below intentionally match literal shell source.
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
POLICY="$PROJECT_ROOT/shared/bootc-secure/tree/etc/containers/policy.json"
# The strict signature policy the stager enforces, in immutable /usr (ADR-0025).
UPDATE_POLICY="$PROJECT_ROOT/shared/bootc-secure/tree/usr/lib/snosi/containers/bootc-policy.json"
BOOTC_POLICY_PATH=/usr/lib/snosi/containers/bootc-policy.json
SECURE_CONFIG="$PROJECT_ROOT/shared/bootc-secure/mkosi.conf"
REGISTRIES_CONFIG="$PROJECT_ROOT/shared/bootc-secure/tree/etc/containers/registries.d/frostyard.yaml"
USER_POLICY="$PROJECT_ROOT/shared/bootc-secure/tree/usr/share/snosi/containers/user-policy.json"
USER_TMPFILES="$PROJECT_ROOT/shared/bootc-secure/tree/usr/lib/user-tmpfiles.d/snosi-containers-policy.conf"
VM_LIB="$PROJECT_ROOT/test/lib/vm.sh"
UPDATER="$PROJECT_ROOT/mkosi.images/base/mkosi.extra/usr/libexec/bootc-update-stage"
UPDATER_UNIT="$PROJECT_ROOT/mkosi.images/base/mkosi.extra/usr/lib/systemd/system/bootc-update-stage.service"
SECURE_IMAGES=(cayo floe snow snowfield sundog)

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
require_file "$UPDATE_POLICY" "strict bootc update policy is shipped in /usr"
require_file "$PROJECT_ROOT/cosign.pub" "committed Cosign public key exists"
require_file "$USER_POLICY" "rootless container policy is shipped"
require_file "$USER_TMPFILES" "rootless container policy provisioning is shipped"

# verify_strict_policy FILE LABEL -- the strict update-policy contract. The
# same assertions run against the /usr update policy, which the stager
# enforces at pull time, so relaxing the system default cannot relax them.
verify_strict_policy() { # file label
    local file=$1 label=$2 image scope transport
    local -a expected_scopes=()

    if jq -e '.default == [{"type":"reject"}]' "$file" >/dev/null; then
        pass "$label rejects unlisted images"
    else
        fail "$label rejects unlisted images"
    fi

    for image in "${SECURE_IMAGES[@]}"; do
        scope="ghcr.io/frostyard/$image"
        if jq -e --arg scope "$scope" '
            .transports.docker[$scope] == [{
                "type": "sigstoreSigned",
                "keyPath": "/usr/lib/snosi/cosign.pub",
                "signedIdentity": {"type": "matchRepository"}
            }]
        ' "$file" >/dev/null; then
            pass "$label accepts valid $scope signatures"
        else
            fail "$label accepts valid $scope signatures"
        fi
    done

    if jq -e '.transports["containers-storage"][""] == [{"type":"insecureAcceptAnything"}]' "$file" >/dev/null; then
        pass "$label accepts previously policy-verified local storage images"
    else
        fail "$label accepts previously policy-verified local storage images"
    fi

    for image in "${SECURE_IMAGES[@]}"; do
        scope="ghcr.io/frostyard/${image}-wrong-repository"
        if jq -e --arg scope "$scope" '.transports.docker[$scope] == null' "$file" >/dev/null; then
            pass "$label rejects wrong repository $scope"
        else
            fail "$label rejects wrong repository $scope"
        fi
    done

    for image in "${SECURE_IMAGES[@]}"; do
        expected_scopes+=("ghcr.io/frostyard/$image")
    done
    if jq -e --args '(.transports.docker | keys) == $ARGS.positional' \
            "${expected_scopes[@]}" <"$file" >/dev/null; then
        pass "$label trusts only the supported exact GHCR repositories"
    else
        fail "$label trusts only the supported exact GHCR repositories"
    fi

    for transport in tarball docker-archive oci-archive dir oci; do
        if jq -e --arg t "$transport" '.transports[$t][""] == [{"type":"insecureAcceptAnything"}]' "$file" >/dev/null; then
            pass "$label accepts local $transport images"
        else
            fail "$label accepts local $transport images"
        fi
    done

    if jq -e '[.transports.docker[][] | select(.type != "sigstoreSigned")] | length == 0' "$file" >/dev/null; then
        pass "$label keeps every docker scope sigstoreSigned"
    else
        fail "$label keeps every docker scope sigstoreSigned"
    fi
    if jq -e '.transports.docker[""] == null' "$file" >/dev/null; then
        pass "$label has no catch-all docker scope"
    else
        fail "$label has no catch-all docker scope"
    fi
}

if [[ -f "$POLICY" && -f "$UPDATE_POLICY" ]] && command -v jq >/dev/null; then
    # The strict contract first, against the policy that gates updates.
    verify_strict_policy "$UPDATE_POLICY" "update policy"

    # Then the system policy. Its default now accepts ordinary workload
    # images (ADR-0025), so the checks that remain are the ones that keep the
    # five Frostyard product repositories signature-checked.
    if jq -e '.default == [{"type":"insecureAcceptAnything"}]' "$POLICY" >/dev/null; then
        pass "the system default accepts workload images"
    else
        fail "the system default accepts workload images"
    fi

    for image in "${SECURE_IMAGES[@]}"; do
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

    # LOCAL file transports are accepted so an operator can actually do image
    # work on an installed system -- podman load/import, dir:/oci: layouts.
    # The bytes are already on the machine and under their control; the trust
    # boundary this policy exists to enforce is the REGISTRY one.
    #
    # Blocking them was also inconsistent rather than strict: `podman build`
    # FROM scratch consults no transport, so arbitrary local images were always
    # constructible. The prohibition cost usability and bought nothing.
    if jq -e '.transports["containers-storage"][""] == [{"type":"insecureAcceptAnything"}]' "$POLICY" >/dev/null; then
        pass "previously policy-verified local storage images are accepted"
    else
        fail "previously policy-verified local storage images are accepted"
    fi
    for transport in tarball docker-archive oci-archive dir oci; do
        if jq -e --arg t "$transport" '.transports[$t][""] == [{"type":"insecureAcceptAnything"}]' "$POLICY" >/dev/null; then
            pass "local $transport images are accepted"
        else
            fail "local $transport images are accepted"
        fi
    done

    # The half that must NOT move. The permissive default must never turn into
    # an unsigned Frostyard pull: `docker` keeps exactly the supported
    # sigstoreSigned scopes.
    if jq -e '[.transports.docker[][] | select(.type != "sigstoreSigned")] | length == 0' "$POLICY" >/dev/null; then
        pass "every docker scope is still sigstoreSigned"
    else
        fail "every docker scope is still sigstoreSigned"
    fi
    if jq -e '.transports.docker[""] == null' "$POLICY" >/dev/null; then
        pass "no catch-all docker scope was introduced"
    else
        fail "no catch-all docker scope was introduced"
    fi

    # The two files differ only in their default. Anything else drift means the
    # stager and the system disagree about what a signed Frostyard image is.
    if jq -e --slurpfile other "$UPDATE_POLICY" \
            '.transports.docker == $other[0].transports.docker' "$POLICY" >/dev/null; then
        pass "the system policy trusts exactly the docker scopes the update policy trusts"
    else
        fail "the system policy trusts exactly the docker scopes the update policy trusts"
    fi
    if jq -e --slurpfile other "$UPDATE_POLICY" \
            '.transports == $other[0].transports' "$POLICY" >/dev/null; then
        pass "both policies accept the same transports"
    else
        fail "both policies accept the same transports"
    fi
else
    fail "policy is valid JSON (jq and both policies are required)"
fi

if [[ -f "$USER_POLICY" ]] && jq -e '
    . == {"default": [{"type": "insecureAcceptAnything"}]}
' "$USER_POLICY" >/dev/null; then
    pass "rootless users may pull arbitrary workload images"
else
    fail "rootless users may pull arbitrary workload images"
fi

if [[ -f "$USER_TMPFILES" ]] && \
        grep -Fqx 'd %h/.config/containers 0700 - - -' "$USER_TMPFILES" && \
        grep -Fqx 'C %h/.config/containers/policy.json 0600 - - - /usr/share/snosi/containers/user-policy.json' "$USER_TMPFILES"; then
    pass "rootless policy is provisioned without replacing user configuration"
else
    fail "rootless policy is provisioned without replacing user configuration"
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

verify_vm_registry_policy() {
    local expected
    expected=$(mktemp)
    # shellcheck source=test/lib/vm.sh
    source "$VM_LIB"
    create_registry_policy
    # The VM fixture reads the strict update policy, so a relaxed system
    # default can never widen the policy the install lane proves against.
    jq --arg key "$PROJECT_ROOT/cosign.pub" '
        .transports.docker |= with_entries(.value |= map(.keyPath = $key))
    ' "$UPDATE_POLICY" >"$expected"
    if cmp -s "$expected" "$IMAGE_POLICY"; then
        pass "VM registry policy derives from the strict update policy"
    else
        fail "VM registry policy derives from the strict update policy"
    fi
    rm -f "$expected"
    rm -rf "$IMAGE_POLICY_HOME"
    IMAGE_POLICY=""
    IMAGE_POLICY_HOME=""
}
verify_vm_registry_policy

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

# The stager's own pull is the gate that stages updates, so its policy path is
# a literal in immutable /usr with no environment override (ADR-0025).
policy_declarations=$(grep -Fxc "readonly BOOTC_POLICY=$BOOTC_POLICY_PATH" "$UPDATER" || true)
if [[ $policy_declarations == 1 ]]; then
    pass "updater pins the strict update policy path in immutable /usr"
else
    fail "updater pins the strict update policy path in immutable /usr (found ${policy_declarations} declarations)"
fi

mapfile -t updater_pull_lines < <(
    grep -E '(^|[^[:alnum:]_])podman pull' "$UPDATER" |
        grep -vE '^[[:space:]]*#' | grep -vE '^[[:space:]]*echo '
)
if (( ${#updater_pull_lines[@]} > 0 )); then
    strict_pulls=0
    for updater_line in "${updater_pull_lines[@]}"; do
        [[ $updater_line == *'--signature-policy "$BOOTC_POLICY"'* ]] && strict_pulls=$((strict_pulls + 1))
    done
    if (( strict_pulls == ${#updater_pull_lines[@]} )); then
        pass "every updater pull names the strict update policy"
    else
        fail "every updater pull names the strict update policy"
    fi
else
    fail "every updater pull names the strict update policy (no podman pull found)"
fi

if grep -Fq -- '--policy' "$UPDATER"; then
    fail "updater never uses the pull policy override"
else
    pass "updater never uses the pull policy override"
fi
if grep -Fq 'POLICY:-' "$UPDATER"; then
    fail "updater allows no environment override of its policy path"
else
    pass "updater allows no environment override of its policy path"
fi
if [[ -f "$UPDATER_UNIT" ]] && ! grep -q '^Environment' "$UPDATER_UNIT"; then
    pass "updater unit sets no environment for the stager"
else
    fail "updater unit sets no environment for the stager"
fi

# The run lock must come first: it has to be held before the EXIT trap and
# before the first `bootc status`, or two runs can still interleave.
lock_line=$(grep -n 'flock -n "\$lock_fd"' "$UPDATER" | head -1 | cut -d: -f1 || true)
trap_line=$(grep -n '^trap ' "$UPDATER" | head -1 | cut -d: -f1 || true)
first_status_line=$(grep -n 'bootc status --format json' "$UPDATER" | head -1 | cut -d: -f1 || true)
if [[ -n $lock_line && -n $trap_line && -n $first_status_line ]] && \
        (( lock_line < trap_line && lock_line < first_status_line )) && \
        grep -Fq 'exec {lock_fd}>"$RUN_DIR/update-stage.lock"' "$UPDATER"; then
    pass "updater takes its run lock before the trap and the first bootc status"
else
    fail "updater takes its run lock before the trap and the first bootc status (lock=${lock_line:-none} trap=${trap_line:-none} status=${first_status_line:-none})"
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
        status=$(jq -nc --arg staged "$staged" '{spec:{image:{image:"ghcr.io/frostyard/floe:latest",transport:"containers-storage"}},status:{booted:{image:{imageDigest:"sha256:booted"}},staged:{image:{imageDigest:$staged}},rollback:{image:{}}}}')
    else
        status=$(jq -nc '{spec:{image:{image:"ghcr.io/frostyard/floe:latest",transport:"containers-storage"}},status:{booted:{image:{imageDigest:"sha256:booted"}},staged:{},rollback:{image:{}}}}')
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

# make_stager_fixture DIR -- stub binaries for one stager run.
#
# The podman stub records the full argument list of every call in
# DIR/state/podman-calls (the policy assertions read it), answers `pull` with
# $PULLED_CONFIG_ID, and tells an inspect by image ID from an inspect by tag
# name: an inspect of $PULLED_CONFIG_ID prints the pulled ID; an inspect of any
# other reference prints DIR/state/tag-id when a test wrote one, else the
# pulled ID.
#
# The bootc stub records every call in DIR/state/bootc-calls and models the
# two-phase stage of bootc 1.17.1:
#   * a `status` read before any staging prints $BOOTC_STATUS_BEFORE;
#   * after a `--download-only` call it prints $BOOTC_STATUS_LOCKED;
#   * after a `--from-downloaded` call it prints $BOOTC_STATUS_UNLOCKED.
# The staging subcommand (upgrade or switch) goes to DIR/state/operation, and
# only a call that carries `--download-only` sets it, so the unlock call is
# never mistaken for a stage.
make_stager_fixture() { # dir
    local dir=$1
    mkdir -p "$dir/bin" "$dir/run" "$dir/state"
    cat >"$dir/bin/bootc" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FIXTURE_STATE/bootc-calls"
case $1 in
status)
    if grep -qF -- '--from-downloaded' "$FIXTURE_STATE/bootc-calls"; then
        printf '%s\n' "$BOOTC_STATUS_UNLOCKED"
    elif grep -qF -- '--download-only' "$FIXTURE_STATE/bootc-calls"; then
        printf '%s\n' "$BOOTC_STATUS_LOCKED"
    else
        printf '%s\n' "$BOOTC_STATUS_BEFORE"
    fi
    ;;
upgrade|switch)
    case " $* " in
    *' --download-only '*) printf '%s\n' "$1" >"$FIXTURE_STATE/operation" ;;
    esac
    ;;
*) exit 1 ;;
esac
EOF
    cat >"$dir/bin/podman" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FIXTURE_STATE/podman-calls"
case "$1" in
image)
    case "$2" in
    prune) exit 0 ;;
    inspect)
        # Args: image inspect --format FORMAT REF
        format=$4
        ref=${*: -1}
        case "$format" in
        *'{{.Digest}}'*) printf '%s\n' "$PULLED_MANIFEST" ;;
        *'{{.Id}}'*)
            # Inspect by image ID: the verified image itself.
            if [[ $ref == "$PULLED_CONFIG_ID" ]]; then
                printf '%s\n' "$PULLED_CONFIG_ID"
            elif [[ -f $FIXTURE_STATE/tag-id ]]; then
                # Inspect by tag name, with a tag the test moved.
                cat "$FIXTURE_STATE/tag-id"
            else
                printf '%s\n' "$PULLED_CONFIG_ID"
            fi
            ;;
        *'org.opencontainers.image.version'*) printf '%s\n' 20260814141627 ;;
        *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
    esac
    ;;
pull) printf '%s\n' "$PULLED_CONFIG_ID" ;;
# ADR-0014 packages.txt capture: bootc-update-stage runs `podman create`,
# `podman cp <cid>:/usr/share/frostyard/. <dir>`, `podman rm -f` before it
# stages. Serve a single fake packages.txt so the capture succeeds.
create) printf 'fakecid\n' ;;
rm) : ;;
cp)
    dest=$3
    mkdir -p "$dest"
    printf 'Listing... Done\nbash/now 5.2.37-2 amd64 [installed,local]\n' >"$dest/snow.packages.txt"
    ;;
*) exit 1 ;;
esac
EOF
    chmod +x "$dir/bin/bootc" "$dir/bin/podman"
}

# staged_status BOOTED STAGED TRANSPORT LOCKED -- one `bootc status --format
# json` document. STAGED empty means "no staged deployment"; LOCKED is true or
# false and appears as .status.staged.downloadOnly only when a deployment is
# staged.
staged_status() { # booted staged transport locked
    jq -nc --arg booted "$1" --arg staged "$2" --arg transport "$3" \
        --argjson locked "$4" '
        {spec: {image: {image: "ghcr.io/frostyard/snow:latest", transport: $transport}},
         status: {
            booted: {image: {imageDigest: $booted}},
            staged: (if $staged == ""
                     then {}
                     else {image: {imageDigest: $staged}, downloadOnly: $locked}
                     end),
            rollback: {image: {}}
         }}'
}

# run_stager WORK BEFORE LOCKED UNLOCKED [env...] -- run the stager in the
# fixture and set CASE_RC to its exit status.
run_stager() { # work before locked unlocked [env...]
    local work=$1 before=$2 locked=$3 unlocked=$4
    shift 4
    set +e
    PATH="$work/bin:$PATH" env "$@" \
        BOOTC_STATUS_BEFORE="$before" BOOTC_STATUS_LOCKED="$locked" \
        BOOTC_STATUS_UNLOCKED="$unlocked" FIXTURE_STATE="$work/state" \
        PULLED_MANIFEST="$manifest" PULLED_CONFIG_ID="$config_id" \
        SNOSI_STAGED_PACKAGES_LIB="$PROJECT_ROOT/mkosi.images/base/mkosi.extra/usr/lib/snosi/staged-packages.sh" \
        SNOSI_RUN_DIR="$work/run" "$UPDATER" >"$work/output" 2>&1
    CASE_RC=$?
    set -e
}

# assert_strict_pull FILE -- every recorded pull used the strict /usr policy
# and nothing else, and the packages capture never pulled.
assert_strict_pull() { # calls-file description
    local calls=$1 description=$2 pull_line
    pull_line=$(grep -E '^pull ' "$calls" | tail -n1 || true)
    if [[ $pull_line == "pull --quiet --signature-policy $BOOTC_POLICY_PATH ghcr.io/frostyard/snow:latest" ]]; then
        pass "$description pulls under the strict update policy"
    else
        fail "$description pulls under the strict update policy (pull call: '${pull_line:-none}')"
    fi
    if grep -Eq -- '(^| )--policy( |=)' "$calls"; then
        fail "$description adds no other policy flag to its pull"
    else
        pass "$description adds no other policy flag to its pull"
    fi
    if grep -Eq -- '^create .*--pull=never( |$)' "$calls"; then
        pass "$description captures packages without pulling again"
    else
        fail "$description captures packages without pulling again"
    fi
}

# assert_two_phase_stage CALLS DESCRIPTION -- one locked stage, then one
# unlock with `bootc upgrade --quiet --from-downloaded`, in that order. The
# reverse order, or a stage that is not locked, reopens the retag race.
assert_two_phase_stage() { # bootc-calls-file description
    local calls=$1 description=$2 stage_calls line first="" last=""
    local lock_count=0 unlock_count=0
    stage_calls=$(grep -E '^(upgrade|switch) ' "$calls" || true)
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        [[ $line == *'--download-only'* ]] && lock_count=$((lock_count + 1))
        [[ $line == *'--from-downloaded'* ]] && unlock_count=$((unlock_count + 1))
        [[ -z $first ]] && first=$line
        last=$line
    done <<<"$stage_calls"
    if (( lock_count == 1 && unlock_count == 1 )) &&
            [[ $first == *'--download-only'* ]] &&
            [[ $last == 'upgrade --quiet --from-downloaded' ]]; then
        pass "$description stages locked, then unlocks without a new fetch"
    else
        fail "$description stages locked, then unlocks without a new fetch (calls: ${stage_calls//$'\n'/ | })"
    fi
}

run_updater_digest_fixture() { # description booted staged-before staged-after expected-outcome expected-operation
    local description=$1 booted=$2 staged_before=$3 staged_after=$4
    local expected_outcome=$5 expected_operation=$6 work before locked unlocked rc operation
    local staged_by_bootc=${staged_after:-$staged_before}
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    make_stager_fixture "$work"
    before=$(staged_status "$booted" "$staged_before" containers-storage false)
    locked=$(staged_status "$booted" "$staged_by_bootc" containers-storage true)
    unlocked=$(staged_status "$booted" "$staged_by_bootc" containers-storage false)

    run_stager "$work" "$before" "$locked" "$unlocked"
    rc=$CASE_RC

    operation=$(cat "$work/state/operation" 2>/dev/null || true)
    if [[ $rc -eq 0 ]] && grep -Fqx "outcome=$expected_outcome" "$work/run/update-check" && \
            [[ "$operation" == "$expected_operation" ]]; then
        if [[ $expected_outcome == staged ]]; then
            if grep -Fqx "digest=$manifest" "$work/run/update-staged"; then
                pass "$description"
            else
                fail "$description (staged semaphore does not carry the manifest digest)"
            fi
        elif [[ ! -e $work/run/update-staged ]]; then
            pass "$description"
        else
            fail "$description (unexpected staged semaphore)"
        fi
    else
        fail "$description (rc=$rc outcome=$(sed -n 's/^outcome=//p' "$work/run/update-check" 2>/dev/null) operation=${operation:-none}; output: $(<"$work/output"))"
    fi

    # Only the run that really stages proves the pull flag and the two-phase
    # order: a failing stub never reaches them.
    if [[ $rc -eq 0 && "$operation" == upgrade ]]; then
        assert_strict_pull "$work/state/podman-calls" "stager"
        assert_two_phase_stage "$work/state/bootc-calls" "stager"
    fi
}

manifest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
old=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
replacement=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
config_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run_updater_digest_fixture "updater recognizes the pulled manifest as current" \
    "$manifest" '' '' current ''
run_updater_digest_fixture "updater recognizes the pulled manifest as already staged" \
    "$old" "$manifest" "$manifest" staged ''
run_updater_digest_fixture "updater verifies a newly staged manifest and reports success" \
    "$old" '' "$manifest" staged upgrade

# A tag that another root process replaces while bootc stages: the locked
# deployment is the replacement, not the verified image. It must stay locked,
# so bootc-finalize-staged never finalizes it and it never boots.
run_stager_retag_race_fixture() { # transport expected-operation description
    local transport=$1 expected_operation=$2 description=$3
    local work before locked unlocked rc operation
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    make_stager_fixture "$work"
    before=$(staged_status "$old" '' "$transport" false)
    locked=$(staged_status "$old" "$replacement" "$transport" true)
    unlocked=$(staged_status "$old" "$replacement" "$transport" false)

    run_stager "$work" "$before" "$locked" "$unlocked"
    rc=$CASE_RC

    operation=$(cat "$work/state/operation" 2>/dev/null || true)
    if [[ $rc -ne 0 ]] && grep -Fqx 'outcome=failed' "$work/run/update-check" && \
            [[ "$operation" == "$expected_operation" ]] && \
            [[ ! -e $work/run/update-staged ]] && \
            ! grep -Fq -- '--from-downloaded' "$work/state/bootc-calls" && \
            grep -Fq 'left locked, it will not apply' "$work/output"; then
        pass "a tag replaced while bootc stages is never unlocked ($description)"
    else
        fail "a tag replaced while bootc stages is never unlocked ($description) (rc=$rc outcome=$(sed -n 's/^outcome=//p' "$work/run/update-check" 2>/dev/null) operation=${operation:-none}; calls: $(tr '\n' '|' <"$work/state/bootc-calls" 2>/dev/null); output: $(<"$work/output"))"
    fi
}
run_stager_retag_race_fixture containers-storage upgrade "upgrade path"
run_stager_retag_race_fixture registry switch "switch path"

# A bootc that ignores `--download-only` leaves the deployment unlocked, so
# the guard the stage relies on does not exist. Do not report success.
run_stager_ignored_lock_fixture() {
    local work before locked unlocked rc operation
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    make_stager_fixture "$work"
    before=$(staged_status "$old" '' containers-storage false)
    locked=$(staged_status "$old" "$manifest" containers-storage false)
    unlocked=$(staged_status "$old" "$manifest" containers-storage false)

    run_stager "$work" "$before" "$locked" "$unlocked"
    rc=$CASE_RC

    operation=$(cat "$work/state/operation" 2>/dev/null || true)
    if [[ $rc -ne 0 ]] && grep -Fqx 'outcome=failed' "$work/run/update-check" && \
            [[ "$operation" == upgrade ]] && \
            [[ ! -e $work/run/update-staged ]] && \
            ! grep -Fq -- '--from-downloaded' "$work/state/bootc-calls" && \
            grep -Fq 'did not lock the staged deployment' "$work/output"; then
        pass "stager refuses to report success when bootc ignores --download-only"
    else
        fail "stager refuses to report success when bootc ignores --download-only (rc=$rc outcome=$(sed -n 's/^outcome=//p' "$work/run/update-check" 2>/dev/null) operation=${operation:-none}; output: $(<"$work/output"))"
    fi
}
run_stager_ignored_lock_fixture

# A previous run can stage locked and then fail before the unlock. The next
# run must unlock that deployment, or it never applies.
run_stager_locked_already_staged_fixture() {
    local work before locked unlocked rc operation
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    make_stager_fixture "$work"
    before=$(staged_status "$old" "$manifest" containers-storage true)
    locked=$(staged_status "$old" "$manifest" containers-storage true)
    unlocked=$(staged_status "$old" "$manifest" containers-storage false)

    run_stager "$work" "$before" "$locked" "$unlocked"
    rc=$CASE_RC

    operation=$(cat "$work/state/operation" 2>/dev/null || true)
    if [[ $rc -eq 0 ]] && grep -Fqx 'outcome=staged' "$work/run/update-check" && \
            [[ -z "$operation" ]] && \
            grep -Fqx "digest=$manifest" "$work/run/update-staged" && \
            grep -Fqx 'upgrade --quiet --from-downloaded' "$work/state/bootc-calls"; then
        pass "stager unlocks a download-only deployment left staged by an earlier run"
    else
        fail "stager unlocks a download-only deployment left staged by an earlier run (rc=$rc outcome=$(sed -n 's/^outcome=//p' "$work/run/update-check" 2>/dev/null) operation=${operation:-none}; calls: $(tr '\n' '|' <"$work/state/bootc-calls" 2>/dev/null); output: $(<"$work/output"))"
    fi
}
run_stager_locked_already_staged_fixture

# The stager runs as root and root can carry dotfiles and environment that
# point at a permissive policy. None of them may change its own pull: the
# strict policy path is a literal in immutable /usr (ADR-0025).
run_stager_hostile_env_fixture() {
    local work before locked unlocked rc pull_line permissive
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    make_stager_fixture "$work"
    before=$(staged_status "$old" '' containers-storage false)
    locked=$(staged_status "$old" "$manifest" containers-storage true)
    unlocked=$(staged_status "$old" "$manifest" containers-storage false)
    permissive="$work/permissive-policy.json"
    printf '{"default": [{"type": "insecureAcceptAnything"}]}\n' >"$permissive"
    mkdir -p "$work/home/.config/containers"
    cp "$permissive" "$work/home/.config/containers/policy.json"

    run_stager "$work" "$before" "$locked" "$unlocked" \
        HOME="$work/home" CONTAINERS_POLICY="$permissive" \
        SIGNATURE_POLICY="$permissive" BOOTC_POLICY="$permissive" \
        CONTAINERS_CONF="$permissive"
    rc=$CASE_RC

    if [[ $rc -eq 0 ]] && grep -Fqx 'outcome=staged' "$work/run/update-check"; then
        pass "stager cannot bypass its strict policy under a hostile environment"
    else
        fail "stager cannot bypass its strict policy under a hostile environment (rc=$rc outcome=$(sed -n 's/^outcome=//p' "$work/run/update-check" 2>/dev/null); output: $(<"$work/output"))"
    fi
    pull_line=$(grep -E '^pull ' "$work/state/podman-calls" | tail -n1 || true)
    if [[ $pull_line == "pull --quiet --signature-policy $BOOTC_POLICY_PATH ghcr.io/frostyard/snow:latest" ]]; then
        pass "stager keeps the strict update policy path under a hostile environment"
    else
        fail "stager keeps the strict update policy path under a hostile environment (pull call: '${pull_line:-none}')"
    fi
}
run_stager_hostile_env_fixture

# A local tag that moves between the verified pull and the staging command
# must not reach bootc at all: the cheap check refuses before any stage.
run_stager_tag_mismatch_fixture() {
    local work before locked unlocked rc operation
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    make_stager_fixture "$work"
    before=$(staged_status "$old" '' containers-storage false)
    locked=$(staged_status "$old" "$manifest" containers-storage true)
    unlocked=$(staged_status "$old" "$manifest" containers-storage false)
    printf '%s\n' "$replacement" >"$work/state/tag-id"

    run_stager "$work" "$before" "$locked" "$unlocked"
    rc=$CASE_RC

    operation=$(cat "$work/state/operation" 2>/dev/null || true)
    if [[ $rc -ne 0 ]] && grep -Fqx 'outcome=failed' "$work/run/update-check" && \
            [[ -z "$operation" ]] && \
            grep -Fq 'local tag no longer points at the verified image' "$work/output"; then
        pass "stager refuses a tag that no longer points at the verified image"
    else
        fail "stager refuses a tag that no longer points at the verified image (rc=$rc outcome=$(sed -n 's/^outcome=//p' "$work/run/update-check" 2>/dev/null) operation=${operation:-none}; output: $(<"$work/output"))"
    fi
}
run_stager_tag_mismatch_fixture

# Two stager runs must never overlap: the staged deployment is shared, and
# `--from-downloaded` unlocks whatever is staged when it runs. A run that finds
# the lock held exits 0, does nothing, and writes no check result.
run_stager_lock_fixture() {
    local work before locked unlocked rc held
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    make_stager_fixture "$work"
    before=$(staged_status "$old" '' containers-storage false)
    locked=$(staged_status "$old" "$manifest" containers-storage true)
    unlocked=$(staged_status "$old" "$manifest" containers-storage false)

    # Hold the same lock the stager takes, from this test process.
    exec {held}>"$work/run/update-stage.lock"
    flock -n "$held"
    run_stager "$work" "$before" "$locked" "$unlocked"
    rc=$CASE_RC
    exec {held}>&-

    if [[ $rc -eq 0 ]] && [[ ! -e $work/run/update-check ]] && \
            [[ ! -e $work/state/bootc-calls ]] && \
            ! grep -Fq 'pull ' "$work/state/podman-calls" 2>/dev/null && \
            grep -Fq 'not running concurrently' "$work/output"; then
        pass "a second stager run does not run while one holds the lock"
    else
        fail "a second stager run does not run while one holds the lock (rc=$rc check=$( [[ -e $work/run/update-check ]] && echo written || echo absent ); bootc calls: $(tr '\n' '|' <"$work/state/bootc-calls" 2>/dev/null); podman calls: $(tr '\n' '|' <"$work/state/podman-calls" 2>/dev/null); output: $(<"$work/output"))"
    fi
}
run_stager_lock_fixture

run_live_policy_proof() {
    local live_home host_policy update_policy wrong_key_policy wrong_identity_policy unsigned_policy wrong_key log
    local image policy_image workload=quay.io/libpod/alpine:latest
    local -a live_images=()
    local -a required=(podman jq openssl skopeo)
    local command

    for command in "${required[@]}"; do
        if ! command -v "$command" >/dev/null; then
            printf 'BLOCKED: live policy proof requires %s\n' "$command" >&2
            return 2
        fi
    done

    IFS=, read -r -a live_images <<<"${LIVE_IMAGES:-floe}"
    for image in "${live_images[@]}"; do
        # Cayo remains covered while its exact policy scope is retained for
        # late Phase 2 migrations. Phase 5 removes both together.
        case "$image" in
            cayo|floe|snow|snowfield|sundog) ;;
            *) printf 'BLOCKED: LIVE_IMAGES contains unsupported product %s\n' "$image" >&2; return 2 ;;
        esac
    done
    policy_image=${live_images[0]}

    live_home=$(mktemp -d)
    host_policy=$(mktemp)
    update_policy=$(mktemp)
    wrong_key_policy=$(mktemp)
    wrong_identity_policy=$(mktemp)
    unsigned_policy=$(mktemp)
    wrong_key=$(mktemp)
    log=$(mktemp)
    trap 'podman unshare rm -rf "$live_home" 2>/dev/null || true; rm -f "$host_policy" "$update_policy" "$wrong_key_policy" "$wrong_identity_policy" "$unsigned_policy" "$wrong_key" "$log"' RETURN

    mkdir -p "$live_home/.config/containers/registries.d"
    cp "$REGISTRIES_CONFIG" "$live_home/.config/containers/registries.d/frostyard.yaml"
    for image in "${live_images[@]}"; do
        if ! HOME="$live_home" skopeo inspect --no-creds \
            "docker://ghcr.io/frostyard/$image:latest" >"$log" 2>&1; then
            printf 'BLOCKED: ghcr.io/frostyard/%s:latest is not anonymously accessible\n' \
                "$image" >&2
            return 2
        fi
    done
    # Two policies stand in for the two shipped ones: the system policy (via
    # a HOME dotfile) and the strict update policy the stager names.
    jq --arg key "$PROJECT_ROOT/cosign.pub" '
        (.transports.docker[][] | select(.type == "sigstoreSigned").keyPath) = $key
    ' "$POLICY" >"$host_policy"
    jq --arg key "$PROJECT_ROOT/cosign.pub" '
        (.transports.docker[][] | select(.type == "sigstoreSigned").keyPath) = $key
    ' "$UPDATE_POLICY" >"$update_policy"
    cp "$host_policy" "$live_home/.config/containers/policy.json"
    openssl ecparam -name prime256v1 -genkey -noout | \
        openssl ec -pubout >"$wrong_key"
    jq --arg key "$wrong_key" '
        (.transports.docker[][] | select(.type == "sigstoreSigned").keyPath) = $key
    ' "$UPDATE_POLICY" >"$wrong_key_policy"
    jq --arg key "$PROJECT_ROOT/cosign.pub" '
        {default: [{type: "reject"}], transports: {docker: {"docker.io/library/busybox": [{type: "sigstoreSigned", keyPath: $key, signedIdentity: {type: "matchRepository"}}]}}}
    ' "$UPDATE_POLICY" >"$unsigned_policy"
    jq --arg key "$PROJECT_ROOT/cosign.pub" \
        --arg scope "ghcr.io/frostyard/$policy_image" '
        {default: [{type: "reject"}], transports: {docker: {($scope): [{type: "sigstoreSigned", keyPath: $key, signedIdentity: {type: "exactRepository", dockerRepository: "ghcr.io/frostyard/snow"}}]}}}
    ' "$UPDATE_POLICY" >"$wrong_identity_policy"

    expect_policy_accept() { # description policy image
        cp "$2" "$live_home/.config/containers/policy.json"
        if HOME="$live_home" podman pull "$3" >"$log" 2>&1; then
            pass "$1"
        else
            fail "$1 (unexpected rejection: $(<"$log"))"
        fi
    }

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

    for image in "${live_images[@]}"; do
        expect_policy_accept \
            "live Cosign v2.6.1 signature for ghcr.io/frostyard/$image is accepted by the system policy" \
            "$host_policy" "ghcr.io/frostyard/$image:latest"
        expect_policy_accept \
            "live Cosign v2.6.1 signature for ghcr.io/frostyard/$image is accepted by the update policy" \
            "$update_policy" "ghcr.io/frostyard/$image:latest"
        if HOME="$live_home" skopeo inspect "containers-storage:ghcr.io/frostyard/$image:latest" >/dev/null 2>&1; then
            pass "policy-verified ghcr.io/frostyard/$image is consumable from containers-storage"
        else
            fail "policy-verified ghcr.io/frostyard/$image is consumable from containers-storage"
        fi
    done

    # Rejections first: a pull of an image already in storage still runs the
    # policy, but a fresh store keeps the proof independent of that.
    expect_policy_rejection "an arbitrary workload image is rejected by the update policy" \
        "$update_policy" "$workload"
    # The stager's mechanism: --signature-policy wins over a permissive
    # dotfile policy of the calling account (ADR-0025).
    cp "$host_policy" "$live_home/.config/containers/policy.json"
    if HOME="$live_home" podman pull --signature-policy "$update_policy" "$workload" >"$log" 2>&1; then
        fail "--signature-policy overrides a permissive dotfile policy"
    elif grep -Eiq 'Source image rejected|policy.*reject' "$log"; then
        pass "--signature-policy overrides a permissive dotfile policy"
    else
        fail "--signature-policy overrides a permissive dotfile policy (missing policy diagnostic: $(<"$log"))"
    fi
    expect_policy_rejection "scoped unsigned image is rejected" "$unsigned_policy" docker.io/library/busybox:latest
    expect_policy_accept "an arbitrary workload image pulls under the system policy" \
        "$host_policy" "$workload"
    expect_policy_rejection "wrong Cosign key is rejected" "$wrong_key_policy" "ghcr.io/frostyard/$policy_image:latest"
    expect_policy_rejection "signature repository identity mismatch is rejected" "$wrong_identity_policy" "ghcr.io/frostyard/$policy_image:latest"
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
