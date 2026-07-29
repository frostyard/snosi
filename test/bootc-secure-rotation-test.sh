#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Task 10 secure bootc key-rotation runner contract.
set -euo pipefail

PASS=0
FAIL=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert_true() { local description=$1; shift; if "$@"; then pass "$description"; else fail "$description"; fi; }
assert_false() { local description=$1; shift; if "$@"; then fail "$description"; else pass "$description"; fi; }

rotation_phase() {
    case $1 in
        old-only|dual-pcr|new-pcr|mok-overlap|new-mok|old-trust-removed) return 0 ;;
        *) return 1 ;;
    esac
}

phase_marker() {
    printf 'BOOTC_SECURE_ROTATION: %s: complete\n' "$1"
}

marker_is_exact() { [[ $1 == "$2" ]]; }
mode_0600() { [[ -f $1 && $(stat -c '%a' "$1") == 600 ]]; }
valid_digest_ref() { [[ $1 =~ ^ghcr\.io/frostyard/(cayo|snow|snowfield)@sha256:[[:xdigit:]]{64}$ ]]; }
state_value() { jq -er --arg key "$2" '.[$key]' "$1"; }

install_state_is_safe() { # Task 9 install-state manifest
    local state=$1 expected
    mode_0600 "$state" || return 1
    expected='["accepted_oci_ref","mok_cert","ovmf_code","ovmf_vars","pcr_public","profile","recovery_key","schema","ssh_key","target_disk","tpm_socket","tpm_state","tracking_ref"]'
    jq -e --argjson expected "$expected" '
        (keys | sort) == $expected and .schema == 1 and
        ([.profile, .tracking_ref, .accepted_oci_ref, .target_disk, .ovmf_code,
          .ovmf_vars, .tpm_state, .tpm_socket, .recovery_key, .mok_cert,
          .pcr_public, .ssh_key] | all(type == "string" and length > 0)) and
        ([.recovery_key, .mok_cert, .pcr_public, .ssh_key] | all(startswith("/"))) and
        ([.. | strings | select(test("(passphrase|private[ _-]?key|secret)"; "i"))] | length == 0)
    ' "$state" >/dev/null
}

rotation_inputs_are_valid() {
    local state=$BOOTC_SECURE_ROTATION_STATE profile accepted
    install_state_is_safe "$state" || return 1
    profile=$(state_value "$state" profile) || return 1
    accepted=$(state_value "$state" accepted_oci_ref) || return 1
    valid_digest_ref "$accepted" && [[ $accepted == "ghcr.io/frostyard/$profile@"* ]] || return 1
    for ref in "$ROTATION_OLD_REF" "$ROTATION_TRANSITION_REF" "$ROTATION_NEW_REF"; do
        valid_digest_ref "$ref" && [[ $ref == "ghcr.io/frostyard/$profile@"* ]] || return 1
    done
    [[ $ROTATION_OLD_REF != "$ROTATION_TRANSITION_REF" && $ROTATION_OLD_REF != "$ROTATION_NEW_REF" && $ROTATION_TRANSITION_REF != "$ROTATION_NEW_REF" ]] || return 1
    for identity in "$ROTATION_OLD_MOK_CERT" "$ROTATION_NEW_MOK_CERT" "$ROTATION_OLD_PCR_PUBLIC" "$ROTATION_NEW_PCR_PUBLIC"; do
        [[ -f $identity ]] || return 1
    done
    mode_0600 "$(state_value "$state" recovery_key)" && [[ -x $BOOTC_SECURE_ROTATION_COMMAND ]]
}

require_live_inputs() {
    local missing=()
    rotation_inputs_are_valid || missing+=("mode-0600 Task 9 install state, recovery credential, matching immutable old/transition/new refs, and public MOK/PCR identities")
    [[ -x $BOOTC_SECURE_ROTATION_COMMAND ]] || missing+=("BOOTC_SECURE_ROTATION_COMMAND")
    ((${#missing[@]})) || return 0
    printf 'BLOCKED: Task 10 bootc rotation proof requires: %s\n' "${missing[*]}" >&2
    return 2
}

run_phase() {
    local phase=$1 output status
    shift
    set +e
    output=$("$BOOTC_SECURE_ROTATION_COMMAND" --phase "$phase" "$@" 2>&1)
    status=$?
    set -e
    [[ $status -eq 0 ]] || { printf '%s\n' "$output" >&2; return 1; }
    grep -Fqx "$(phase_marker "$phase")" <<<"$output" || return 1
    [[ $output != *NOOP* && $output != *no-op* ]] || return 1
    if [[ $phase == old-trust-removed ]]; then
        grep -Fqx 'BOOTC_SECURE_ROTATION: old-trust-removed: old-mok-rejected' <<<"$output"
        grep -Fqx 'BOOTC_SECURE_ROTATION: old-trust-removed: recovery-ready' <<<"$output"
    fi
}

run_fixtures() {
    local work state old transition new output
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN

    assert_true 'all six rotation phases are recognized' rotation_phase dual-pcr
    assert_false 'unknown rotation phases are rejected' rotation_phase remove-everything
    assert_true 'exact phase markers are accepted' marker_is_exact \
        'BOOTC_SECURE_ROTATION: dual-pcr: complete' "$(phase_marker dual-pcr)"
    assert_false 'wrapped phase markers are rejected' marker_is_exact \
        'prefix BOOTC_SECURE_ROTATION: dual-pcr: complete' "$(phase_marker dual-pcr)"
    old="ghcr.io/frostyard/cayo@sha256:$(printf 'a%.0s' {1..64})"
    transition="ghcr.io/frostyard/cayo@sha256:$(printf 'b%.0s' {1..64})"
    new="ghcr.io/frostyard/cayo@sha256:$(printf 'c%.0s' {1..64})"
    state="$work/install-state.json"
    printf '%s\n' "{\"schema\":1,\"profile\":\"cayo\",\"tracking_ref\":\"ghcr.io/frostyard/cayo:secure-test\",\"accepted_oci_ref\":\"$old\",\"target_disk\":\"/tmp/disk\",\"ovmf_code\":\"/tmp/code\",\"ovmf_vars\":\"/tmp/vars\",\"tpm_state\":\"/tmp/tpm\",\"tpm_socket\":\"/tmp/tpm/socket\",\"recovery_key\":\"$work/recovery\",\"mok_cert\":\"$work/installed-mok.crt\",\"pcr_public\":\"$work/installed-pcr.pub\",\"ssh_key\":\"/tmp/id\"}" >"$state"
    printf recovery >"$work/recovery"; chmod 600 "$work/recovery" "$state"
    for identity in old-mok.crt new-mok.crt old-pcr.pub new-pcr.pub installed-mok.crt installed-pcr.pub; do printf public >"$work/$identity"; done
    printf '%s\n' '#!/bin/bash' 'phase=$2' 'printf "%s\\n" "$phase" >>"${ROTATION_PHASE_LOG:?}"' 'printf "BOOTC_SECURE_ROTATION: %s: complete\\n" "$phase"' 'if [[ $phase == old-trust-removed ]]; then printf "%s\\n" "BOOTC_SECURE_ROTATION: old-trust-removed: old-mok-rejected" "BOOTC_SECURE_ROTATION: old-trust-removed: recovery-ready"; fi' >"$work/runner"
    chmod +x "$work/runner"
    BOOTC_SECURE_ROTATION_STATE=$state
    BOOTC_SECURE_ROTATION_COMMAND="$work/runner"
    ROTATION_OLD_REF=$old; ROTATION_TRANSITION_REF=$transition; ROTATION_NEW_REF=$new
    ROTATION_OLD_MOK_CERT="$work/old-mok.crt"; ROTATION_NEW_MOK_CERT="$work/new-mok.crt"
    ROTATION_OLD_PCR_PUBLIC="$work/old-pcr.pub"; ROTATION_NEW_PCR_PUBLIC="$work/new-pcr.pub"
    : >"$work/phases"
    ROTATION_PHASE_LOG="$work/phases"; export ROTATION_PHASE_LOG
    assert_true 'safe mode-0600 Task 9 state is accepted' install_state_is_safe "$state"
    assert_true 'marked runner completes the required phase protocol' run_phase old-only
    BOOTC_SECURE_ROTATION_COMMAND=/bin/true; assert_false '/bin/true is rejected without its phase marker' run_phase old-only
    BOOTC_SECURE_ROTATION_COMMAND=/bin/false; assert_false '/bin/false is rejected by its failure status' run_phase old-only
    printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "BOOTC_SECURE_ROTATION: old-only: complete NOOP"' >"$work/noop-runner"; chmod +x "$work/noop-runner"
    BOOTC_SECURE_ROTATION_COMMAND="$work/noop-runner"; assert_false 'no-op marked runner is rejected' run_phase old-only; BOOTC_SECURE_ROTATION_COMMAND="$work/runner"
    assert_true 'complete matching rotation inputs are accepted' rotation_inputs_are_valid
    : >"$work/phases"
    assert_true 'live runner invokes all six phases in order' run_live
    assert_true 'runner receives the frozen phase order' cmp -s <(printf '%s\n' old-only dual-pcr new-pcr mok-overlap new-mok old-trust-removed) "$work/phases"
    chmod 644 "$state"; assert_false 'wrong state mode is rejected' rotation_inputs_are_valid; chmod 600 "$state"
    chmod 644 "$work/recovery"; assert_false 'wrong recovery credential mode is rejected' rotation_inputs_are_valid; chmod 600 "$work/recovery"
    ROTATION_NEW_REF='ghcr.io/frostyard/cayo:latest'; assert_false 'tags are rejected' rotation_inputs_are_valid; ROTATION_NEW_REF=$new
    ROTATION_NEW_REF="ghcr.io/frostyard/snow@sha256:$(printf 'd%.0s' {1..64})"; assert_false 'cross-repository refs are rejected' rotation_inputs_are_valid; ROTATION_NEW_REF=$new
    ROTATION_NEW_REF=$old; assert_false 'equal digests are rejected' rotation_inputs_are_valid; ROTATION_NEW_REF=$new
    rm "$work/new-pcr.pub"; assert_false 'missing public identities are rejected' rotation_inputs_are_valid; printf public >"$work/new-pcr.pub"
    jq '.secret = "private key"' "$state" >"$work/unsafe-state.json"; chmod 600 "$work/unsafe-state.json"; BOOTC_SECURE_ROTATION_STATE="$work/unsafe-state.json"
    assert_false 'secret-bearing manifest keys are rejected' rotation_inputs_are_valid
    BOOTC_SECURE_ROTATION_STATE=$state
    output=$(BOOTC_SECURE_ROTATION_STATE='' BOOTC_SECURE_ROTATION_COMMAND='' ROTATION_OLD_REF='' ROTATION_TRANSITION_REF='' ROTATION_NEW_REF='' ROTATION_OLD_MOK_CERT='' ROTATION_NEW_MOK_CERT='' ROTATION_OLD_PCR_PUBLIC='' ROTATION_NEW_PCR_PUBLIC='' require_live_inputs 2>&1) || true
    [[ $output == BLOCKED:* ]] && pass 'missing live inputs block rather than pass' || fail 'missing live inputs block rather than pass'
    printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
    [[ $FAIL -eq 0 ]]
}

run_live() {
    local phase
    local phases=(old-only dual-pcr new-pcr mok-overlap new-mok old-trust-removed)
    require_live_inputs
    for phase in "${phases[@]}"; do
        run_phase "$phase" \
            --state "$BOOTC_SECURE_ROTATION_STATE" \
            --old-ref "$ROTATION_OLD_REF" \
            --transition-ref "$ROTATION_TRANSITION_REF" \
            --new-ref "$ROTATION_NEW_REF" \
            --old-mok-cert "$ROTATION_OLD_MOK_CERT" \
            --new-mok-cert "$ROTATION_NEW_MOK_CERT" \
            --old-pcr-public "$ROTATION_OLD_PCR_PUBLIC" \
            --new-pcr-public "$ROTATION_NEW_PCR_PUBLIC"
    done
}

: "${BOOTC_SECURE_ROTATION_STATE:=}"
: "${BOOTC_SECURE_ROTATION_COMMAND:=}"
: "${ROTATION_OLD_REF:=}"
: "${ROTATION_TRANSITION_REF:=}"
: "${ROTATION_NEW_REF:=}"
: "${ROTATION_OLD_MOK_CERT:=}"
: "${ROTATION_NEW_MOK_CERT:=}"
: "${ROTATION_OLD_PCR_PUBLIC:=}"
: "${ROTATION_NEW_PCR_PUBLIC:=}"

if [[ ${1:-} == --fixtures ]]; then run_fixtures; exit $?; fi
[[ $# -eq 0 ]] || { echo "Usage: $0 [--fixtures]" >&2; exit 2; }
run_live
