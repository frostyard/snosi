#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck disable=SC2016 # The source checks below match literal shell text.
# Stub suite for mkosi.images/base/mkosi.extra/usr/bin/snosi-stream (ADR-0042).
#
# The command switches a bootc machine between the 2 streams of its product
# with the stager's own guarantees: a podman pull under the strict update
# policy in immutable /usr, the stager's run lock, and staging that is verified
# while locked and only then unlocked. Every failure must stop the command
# before it stages, and no failure may reboot.
#
# PATH stubs for `bootc`, `podman` and `systemctl` record their full argv (1
# call per line) and serve fixture `bootc status --format json` documents, so
# the status can change after a switch or an upgrade call. The fixture
# os-release sits behind the paired test hook SNOSI_STREAM_TEST_HOOKS=1 and
# SNOSI_STREAM_OS_RELEASE. No root, network, image build or real deployment.
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$PROJECT_ROOT/mkosi.images/base/mkosi.extra/usr/bin/snosi-stream"
# The strict update policy path the stager uses; a literal in immutable /usr.
POLICY_PATH=/usr/lib/snosi/containers/bootc-policy.json
TARGET_TRIXIE=ghcr.io/frostyard/snow:latest
TARGET_FORKY=ghcr.io/frostyard/snow:forky

booted_digest=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
manifest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
other_manifest=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
DEFAULT_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OTHER_ID=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

failures=0

pass() {
    printf 'ok - %s\n' "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failures=$((failures + 1))
}

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT
bin="$tmp_root/bin"
mkdir -p "$bin"

# --- stubs ------------------------------------------------------------------

cat >"$bin/bootc" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$FIXTURE_STATE/bootc-calls"
printf 'bootc %s\n' "$*" >>"$FIXTURE_STATE/all-calls"
case ${1-} in
status)
    if [[ ${FAIL_BOOTC_STATUS:-0} == 1 ]]; then
        echo 'error: failed to connect to the booted system' >&2
        exit 1
    fi
    # The status follows the calls made so far, so a switch or an upgrade
    # changes what the next read reports.
    if grep -qF -- '--from-downloaded' "$FIXTURE_STATE/bootc-calls"; then
        file=status-unlocked
    elif grep -qE -- '^(switch|upgrade) ' "$FIXTURE_STATE/bootc-calls"; then
        file=status-locked
    else
        file=status-before
    fi
    [[ -f $FIXTURE_STATE/$file ]] || file=status-before
    cat "$FIXTURE_STATE/$file"
    ;;
switch | upgrade)
    if [[ ${FAIL_BOOTC_STEP:-none} == "$1" ]]; then
        echo "error: $1 failed" >&2
        exit 1
    fi
    ;;
rollback)
    if [[ ${FAIL_BOOTC_STEP:-none} == rollback ]]; then
        echo 'error: rollback failed' >&2
        exit 1
    fi
    ;;
*)
    echo "bootc stub: unsupported call: $*" >&2
    exit 1
    ;;
esac
STUB

cat >"$bin/podman" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$FIXTURE_STATE/podman-calls"
printf 'podman %s\n' "$*" >>"$FIXTURE_STATE/all-calls"
case ${1-} in
image)
    case ${2-} in
    prune) exit 0 ;;
    inspect)
        format=${4-}
        ref=${5-}
        case $format in
        *'{.Digest}'*) printf '%s\n' "${INSPECT_DIGEST:-$DEFAULT_DIGEST}" ;;
        *'{.Id}'*)
            # An inspect by image ID names the verified image itself; an
            # inspect by tag serves a tag the test moved.
            if [[ $ref == "${PULLED_ID:-$DEFAULT_ID}" ]]; then
                printf '%s\n' "${PULLED_ID:-$DEFAULT_ID}"
            elif [[ -f $FIXTURE_STATE/tag-id ]]; then
                cat "$FIXTURE_STATE/tag-id"
            else
                printf '%s\n' "${PULLED_ID:-$DEFAULT_ID}"
            fi
            ;;
        *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
    esac
    ;;
pull)
    if [[ ${FAIL_PULL:-0} == 1 ]]; then
        echo 'Error: Source image rejected: A signature was required, but no signature exists' >&2
        exit 1
    fi
    printf '%s\n' "${PULLED_ID:-$DEFAULT_ID}"
    ;;
*)
    echo "podman stub: unsupported call: $*" >&2
    exit 1
    ;;
esac
STUB

cat >"$bin/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$FIXTURE_STATE/systemctl-calls"
printf 'systemctl %s\n' "$*" >>"$FIXTURE_STATE/all-calls"
STUB

chmod +x "$bin/bootc" "$bin/podman" "$bin/systemctl"

# A PATH with no bootc at all: "not a bootc-managed system".
no_bootc_bin="$tmp_root/no-bootc-bin"
mkdir -p "$no_bootc_bin"
ln -s "$bin/podman" "$no_bootc_bin/podman"
ln -s "$bin/systemctl" "$no_bootc_bin/systemctl"

# --- fixture helpers --------------------------------------------------------

# make_status SPEC_IMAGE STAGED_DIGEST STAGED_LOCKED ROLLBACK_REF ROLLBACK_DIGEST
#             ROLLBACK_QUEUED -- one `bootc status --format json` document.
make_status() { # spec staged locked rb-ref rb-digest queued
    jq -nc --arg spec_image "$1" --arg booted "$booted_digest" --arg staged "$2" \
        --argjson locked "$3" --arg rb_ref "$4" --arg rb_digest "$5" \
        --argjson queued "$6" '
        {spec: {image: {image: $spec_image, transport: "containers-storage"}},
         status: {
            booted: {image: {image: {image: $spec_image}, version: "20261115010101",
                             imageDigest: $booted}},
            staged: (if $staged == "" then {}
                     else {image: {image: {image: $spec_image}, version: "20261116010101",
                                   imageDigest: $staged},
                           downloadOnly: $locked}
                     end),
            rollback: (if $rb_digest == "" then {}
                       else {image: {image: {image: $rb_ref}, version: "20261114010101",
                                     imageDigest: $rb_digest}}
                       end),
            rollbackQueued: $queued
         }}'
}

case_number=0

# new_work -- a fresh fixture: empty call logs, an os-release for Snow and a
# status with no staged and no rollback deployment, following trixie.
new_work() {
    case_number=$((case_number + 1))
    work="$tmp_root/case-$case_number"
    mkdir -p "$work/bin" "$work/state" "$work/run"
    : >"$work/state/bootc-calls"
    : >"$work/state/podman-calls"
    : >"$work/state/systemctl-calls"
    : >"$work/state/all-calls"
    printf 'IMAGE_ID=snow\nIMAGE_VERSION=20261115010101\n' >"$work/os-release"
    status "$TARGET_TRIXIE" '' false '' '' false >"$work/state/status-before"
    os_release="$work/os-release"
    run_bin=$bin
    hooks_value=1
    lock_wait=1800
    env_extra=()
}

# status -- write a status document for the next read (the arguments are those
# of make_status).
status() {
    make_status "$@"
}

stream_run() {
    local -a env_args=(
        "SNOSI_RUN_DIR=$work/run"
        "FIXTURE_STATE=$work/state"
        "DEFAULT_ID=$DEFAULT_ID"
        "DEFAULT_DIGEST=$manifest"
        "SNOSI_STREAM_OS_RELEASE=$os_release"
    )
    [[ -n $hooks_value ]] && env_args+=("SNOSI_STREAM_TEST_HOOKS=$hooks_value")
    [[ -n $lock_wait ]] && env_args+=("SNOSI_STREAM_LOCK_WAIT=$lock_wait")
    if (( ${#env_extra[@]} > 0 )); then
        env_args+=("${env_extra[@]}")
    fi
    set +e
    env "${env_args[@]}" "PATH=$run_bin:$PATH" "$SCRIPT" "$@" \
        >"$work/output" 2>"$work/error"
    rc=$?
    set -e
}

check_rc() { # expected description
    if [[ $rc -eq $1 ]]; then
        pass "$2"
    else
        fail "$2 (rc=$rc, expected $1; stdout: $(<"$work/output"); stderr: $(<"$work/error"))"
    fi
}

check_stdout() { # needle description
    if grep -Fq -- "$1" "$work/output"; then
        pass "$2"
    else
        fail "$2 (stdout: $(<"$work/output"))"
    fi
}

check_stderr() { # needle description
    if grep -Fq -- "$1" "$work/error"; then
        pass "$2"
    else
        fail "$2 (stderr: $(<"$work/error"))"
    fi
}

check_stdout_matches() { # regex description
    if grep -Eq -- "$1" "$work/output"; then
        pass "$2"
    else
        fail "$2 (stdout: $(<"$work/output"))"
    fi
}

check_no_call() { # log needle description
    if grep -Fq -- "$2" "$work/state/$1-calls"; then
        fail "$3 (calls: $(tr '\n' '|' <"$work/state/$1-calls"))"
    else
        pass "$3"
    fi
}

check_no_podman_calls() { # description
    if [[ -s $work/state/podman-calls ]]; then
        fail "$1 (podman calls: $(tr '\n' '|' <"$work/state/podman-calls"))"
    else
        pass "$1"
    fi
}

check_no_reboot() { # description
    if [[ -s $work/state/systemctl-calls ]]; then
        fail "$1 (systemctl calls: $(tr '\n' '|' <"$work/state/systemctl-calls"))"
    else
        pass "$1"
    fi
}

# check_podman_calls DESCRIPTION EXPECTED... -- the recorded podman argv, in
# order and exactly.
check_podman_calls() { # description expected-line...
    local description=$1
    shift
    local -a actual=() expected=("$@")
    mapfile -t actual < <(grep -v '^$' "$work/state/podman-calls" || true)
    local i ok=1
    if [[ ${#actual[@]} -ne ${#expected[@]} ]]; then
        ok=0
    else
        for i in "${!expected[@]}"; do
            [[ ${actual[$i]} == "${expected[$i]}" ]] || ok=0
        done
    fi
    if [[ $ok -eq 1 ]]; then
        pass "$description"
    else
        fail "$description (podman calls: $(tr '\n' '|' <"$work/state/podman-calls"); expected: ${expected[*]})"
    fi
}

# check_stage_calls DESCRIPTION EXPECTED... -- only the calls that change the
# deployment (switch, upgrade, rollback), in order and exactly.
check_stage_calls() { # description expected-line...
    local description=$1
    shift
    local -a actual=() expected=("$@")
    mapfile -t actual < <(grep -E '^(switch|upgrade|rollback)( |$)' "$work/state/bootc-calls" || true)
    local i ok=1
    if [[ ${#actual[@]} -ne ${#expected[@]} ]]; then
        ok=0
    else
        for i in "${!expected[@]}"; do
            [[ ${actual[$i]} == "${expected[$i]}" ]] || ok=0
        done
    fi
    if [[ $ok -eq 1 ]]; then
        pass "$description"
    else
        fail "$description (stage calls: $(tr '\n' '|' <"$work/state/bootc-calls"); expected: ${expected[*]})"
    fi
}

# check_order DESCRIPTION EXPECTED... -- every call of every stub except
# `bootc status`, across commands, in order and exactly: the pull comes before
# the switch, and a reboot only after the unlock or the rollback.
check_order() { # description expected-line...
    local description=$1
    shift
    local -a actual=() expected=("$@")
    mapfile -t actual < <(grep -vE '^(bootc status|$)' "$work/state/all-calls" || true)
    local i ok=1
    if [[ ${#actual[@]} -ne ${#expected[@]} ]]; then
        ok=0
    else
        for i in "${!expected[@]}"; do
            [[ ${actual[$i]} == "${expected[$i]}" ]] || ok=0
        done
    fi
    if [[ $ok -eq 1 ]]; then
        pass "$description"
    else
        fail "$description (calls: $(tr '\n' '|' <"$work/state/all-calls"); expected: ${expected[*]})"
    fi
}

# --- usage and hooks --------------------------------------------------------

new_work
stream_run --bogus
check_rc 2 "an unknown argument is a usage error"
check_stderr 'Usage: snosi-stream' "the usage error prints the usage on stderr"
check_no_call bootc status "a usage error runs no bootc command"

new_work
stream_run --reboot
check_rc 2 "--reboot without a stream is a usage error"

new_work
stream_run forky trixie
check_rc 2 "2 streams are a usage error"

new_work
stream_run --reboot forky --help
check_rc 0 "--help exits 0"
check_stdout 'Usage: snosi-stream' "--help prints the usage on stdout"

new_work
hooks_value=2
stream_run
check_rc 2 "any SNOSI_STREAM_TEST_HOOKS value but 0 or 1 is refused"

new_work
hooks_value=0
stream_run forky
check_rc 1 "SNOSI_STREAM_TEST_HOOKS=0 leaves the root check in force"
check_no_call podman pull "a refused non-root run pulls nothing"

new_work
hooks_value=''
stream_run
if [[ $EUID -eq 0 ]]; then
    printf 'skip - the root check cannot be exercised as root\n'
else
    check_rc 1 "without the hook a non-root run is refused"
    check_stderr 'snosi-stream: must run as root' "the refusal names the root requirement"
    check_no_call bootc status "a refused non-root run calls no stub"
fi

# --- the product ------------------------------------------------------------

new_work
printf 'IMAGE_ID=debian\n' >"$os_release"
stream_run forky
check_rc 1 "an unsupported IMAGE_ID is refused"
check_no_call podman pull "an unsupported IMAGE_ID pulls nothing"
check_stage_calls "an unsupported IMAGE_ID stages nothing"

new_work
printf 'IMAGE_ID=\n' >"$os_release"
stream_run forky
check_rc 1 "an empty IMAGE_ID is refused"
check_no_call podman pull "an empty IMAGE_ID pulls nothing"

new_work
os_release="$work/absent-os-release"
stream_run forky
check_rc 1 "a missing os-release is refused"
check_stderr "$os_release" "the refusal names the os-release file"

# --- not a bootc-managed system ---------------------------------------------

new_work
run_bin=$no_bootc_bin
stream_run forky
check_rc 1 "a system without bootc is refused"
check_stderr 'not a bootc-managed system' "the refusal says the system is not bootc-managed"
check_no_call podman pull "a system without bootc pulls nothing"

new_work
env_extra=(FAIL_BOOTC_STATUS=1)
stream_run forky
check_rc 1 "a failed bootc status is refused"
check_stderr 'not a bootc-managed system' "a failed bootc status is not bootc-managed"
check_no_call podman pull "a failed bootc status pulls nothing"

new_work
jq -nc --arg digest "$booted_digest" '{
    spec: {image: {}},
    status: {booted: {image: {imageDigest: $digest}}, staged: {}, rollback: {}}
}' >"$work/state/status-before"
stream_run forky
check_rc 1 "a bootc status with no image reference is refused"
check_no_call podman pull "an empty image spec pulls nothing"

# --- status mode ------------------------------------------------------------

new_work
stream_run
check_rc 0 "status mode exits 0"
check_stdout_matches '^Product:[[:space:]]+snow$' "status mode prints the product"
check_stdout 'ghcr.io/frostyard/snow:latest (containers-storage)' \
    "status mode prints the followed image with its transport"
check_stdout_matches '^Stream:[[:space:]]+trixie$' "a :latest reference is the trixie stream"
check_stdout_matches '^Booted:[[:space:]]+ghcr.io/frostyard/snow:latest' \
    "status mode prints the booted deployment"
check_stdout_matches '^Staged:[[:space:]]+none$' "status mode prints a missing deployment as none"
check_stdout_matches '^Rollback:[[:space:]]+none$' "status mode prints a missing rollback as none"
check_no_podman_calls "status mode calls no podman at all"
check_no_call bootc switch "status mode stages nothing"

new_work
status "$TARGET_FORKY" '' false '' '' false >"$work/state/status-before"
stream_run
check_rc 0 "status mode on forky exits 0"
check_stdout_matches '^Stream:[[:space:]]+forky$' "a :forky reference is the forky stream"

new_work
status "$TARGET_FORKY" "$manifest" true "$TARGET_TRIXIE" "$other_manifest" false \
    >"$work/state/status-before"
stream_run
check_rc 0 "status mode shows a staged deployment"
check_stdout_matches '^Staged:[[:space:]]+ghcr.io/frostyard/snow:forky' \
    "status mode prints the staged deployment reference"
check_stdout_matches '^Rollback:[[:space:]]+ghcr.io/frostyard/snow:latest' \
    "status mode prints the rollback deployment reference"

new_work
status 'ghcr.io/frostyard/snow:testing' '' false '' '' false >"$work/state/status-before"
stream_run
check_rc 0 "status mode on another reference exits 0"
check_stdout_matches '^Stream:[[:space:]]+other$' "any other reference is the other stream"

# --- already on the target --------------------------------------------------

new_work
status "$TARGET_FORKY" '' false '' '' false >"$work/state/status-before"
stream_run forky --reboot
check_rc 0 "a machine that already follows the target exits 0"
check_stdout "$TARGET_FORKY" "the already-following message names the target"
check_no_call podman pull "a machine that already follows the target pulls nothing"
check_stage_calls "a machine that already follows the target stages nothing"
check_no_reboot "a machine that already follows the target does not reboot, even with --reboot"

new_work
status "$TARGET_FORKY" "$manifest" true '' '' false >"$work/state/status-before"
stream_run forky
check_rc 0 "already following with a staged deployment exits 0"
check_stdout 'applies at the next reboot' "already following says a staged deployment applies at the next reboot"
check_no_reboot "already following with a staged deployment does not reboot"

# --- a queued rollback ------------------------------------------------------

new_work
status "$TARGET_FORKY" '' false "$TARGET_TRIXIE" "$other_manifest" true \
    >"$work/state/status-before"
stream_run trixie --reboot
check_rc 1 "a queued rollback is refused"
check_stderr 'rollback is queued' "the refusal names the queued rollback"
check_no_call podman pull "a queued rollback pulls nothing"
check_no_reboot "a queued rollback does not reboot"

# --- the happy paths --------------------------------------------------------

new_work
status "$TARGET_TRIXIE" '' false '' '' false >"$work/state/status-before"
status "$TARGET_FORKY" "$manifest" true '' '' false >"$work/state/status-locked"
status "$TARGET_FORKY" "$manifest" false '' '' false >"$work/state/status-unlocked"
stream_run forky
check_rc 0 "a forky switch succeeds"
check_podman_calls "a forky switch pulls under the strict policy and verifies the tag" \
    'image prune -f' \
    "pull --quiet --signature-policy $POLICY_PATH $TARGET_FORKY" \
    "image inspect --format {{.Digest}} $DEFAULT_ID" \
    "image inspect --format {{.Id}} $TARGET_FORKY" \
    'image prune -f'
check_stage_calls "a forky switch stages locked and then unlocks without a new fetch" \
    "switch --quiet --download-only --transport containers-storage $TARGET_FORKY" \
    'upgrade --quiet --from-downloaded'
check_no_reboot "a forky switch without --reboot does not reboot"
check_stdout 'Reboot to apply: sudo systemctl reboot' \
    "a forky switch without --reboot prints the reboot step"

new_work
status "$TARGET_FORKY" '' false '' '' false >"$work/state/status-before"
status "$TARGET_TRIXIE" "$manifest" true '' '' false >"$work/state/status-locked"
status "$TARGET_TRIXIE" "$manifest" false '' '' false >"$work/state/status-unlocked"
stream_run trixie --reboot
check_rc 0 "a trixie switch with --reboot succeeds"
check_podman_calls "a trixie switch pulls :latest under the strict policy" \
    'image prune -f' \
    "pull --quiet --signature-policy $POLICY_PATH $TARGET_TRIXIE" \
    "image inspect --format {{.Digest}} $DEFAULT_ID" \
    "image inspect --format {{.Id}} $TARGET_TRIXIE" \
    'image prune -f'
check_stage_calls "a trixie switch stages locked and then unlocks without a new fetch" \
    "switch --quiet --download-only --transport containers-storage $TARGET_TRIXIE" \
    'upgrade --quiet --from-downloaded'
check_order "a trixie switch pulls, checks, stages locked, unlocks, then reboots" \
    'podman image prune -f' \
    "podman pull --quiet --signature-policy $POLICY_PATH $TARGET_TRIXIE" \
    "podman image inspect --format {{.Digest}} $DEFAULT_ID" \
    "podman image inspect --format {{.Id}} $TARGET_TRIXIE" \
    "bootc switch --quiet --download-only --transport containers-storage $TARGET_TRIXIE" \
    'bootc upgrade --quiet --from-downloaded' \
    'podman image prune -f' \
    'systemctl reboot'
if [[ $(tail -n1 "$work/state/systemctl-calls") == 'reboot' ]] &&
        [[ $(grep -c '^reboot$' "$work/state/systemctl-calls") == 1 ]]; then
    pass "--reboot runs systemctl reboot after the upgrade"
else
    fail "--reboot runs systemctl reboot after the upgrade (calls: $(tr '\n' '|' <"$work/state/systemctl-calls"))"
fi

# --- a failed pull ----------------------------------------------------------

new_work
env_extra=(FAIL_PULL=1)
stream_run forky --reboot
check_rc 1 "a failed pull fails the command"
check_stderr 'nothing was pulled or staged' "a failed pull says nothing was staged"
if [[ $(grep -cE '^pull ' "$work/state/podman-calls") == 1 ]] &&
        [[ $(grep -cE '^image inspect' "$work/state/podman-calls") == 0 ]]; then
    pass "a failed pull inspects nothing"
else
    fail "a failed pull inspects nothing (calls: $(tr '\n' '|' <"$work/state/podman-calls"))"
fi
check_stage_calls "a failed pull stages nothing"
check_no_reboot "a failed pull does not reboot, even with --reboot"

# --- a pulled image that is not the verified one ----------------------------

new_work
env_extra=(PULLED_ID=not-an-image-id)
stream_run forky
check_rc 1 "a pull that prints no valid image ID fails"
check_stage_calls "an invalid image ID stages nothing"

new_work
env_extra=(INSPECT_DIGEST=not-a-digest)
stream_run forky
check_rc 1 "a pulled image with no valid manifest digest fails"
check_stage_calls "an invalid manifest digest stages nothing"

new_work
printf '%s\n' "$OTHER_ID" >"$work/state/tag-id"
stream_run forky
check_rc 1 "a local tag that moved fails"
check_stderr 'local tag no longer points at the verified image' \
    "the refusal names the moved tag"
check_stage_calls "a moved local tag stages nothing"

# --- staging that does not verify -------------------------------------------

new_work
status "$TARGET_FORKY" "$other_manifest" true '' '' false >"$work/state/status-locked"
stream_run forky --reboot
check_rc 1 "a staged digest that is not the pulled digest fails"
check_stderr 'left locked, it will not apply' "the refusal says the wrong deployment stays locked"
if ! grep -Fq -- '--from-downloaded' "$work/state/bootc-calls"; then
    pass "a wrongly staged deployment is never unlocked"
else
    fail "a wrongly staged deployment is never unlocked (calls: $(tr '\n' '|' <"$work/state/bootc-calls"))"
fi
check_no_reboot "a wrongly staged deployment does not reboot, even with --reboot"

new_work
status "$TARGET_FORKY" "$manifest" false '' '' false >"$work/state/status-locked"
stream_run forky --reboot
check_rc 1 "a staged deployment that is not download-only fails"
check_stderr 'did not lock the staged deployment' "the refusal says bootc did not lock it"
check_no_reboot "an unlocked stage does not reboot, even with --reboot"

new_work
status "$TARGET_FORKY" "$manifest" true '' '' false >"$work/state/status-locked"
status "$TARGET_FORKY" "$manifest" true '' '' false >"$work/state/status-unlocked"
stream_run forky --reboot
check_rc 1 "a deployment that is still download-only after the unlock fails"
check_stderr 'still download-only after unlock' "the refusal says it will not apply"
check_no_reboot "a still-locked deployment does not reboot, even with --reboot"

new_work
env_extra=(FAIL_BOOTC_STEP=switch)
stream_run forky --reboot
check_rc 1 "a failed bootc switch fails the command"
check_no_reboot "a failed bootc switch does not reboot, even with --reboot"

# --- the rollback branch ----------------------------------------------------

new_work
status "$TARGET_FORKY" '' false "$TARGET_TRIXIE" "$manifest" false \
    >"$work/state/status-before"
stream_run trixie
check_rc 0 "the way back to trixie rolls back when the pulled image is the rollback deployment"
check_stage_calls "the rollback branch runs bootc rollback and never a switch" \
    'rollback'
check_no_reboot "a rollback without --reboot does not reboot"
check_stdout 'Reboot to apply: sudo systemctl reboot' "a rollback prints the reboot step"

new_work
status "$TARGET_FORKY" '' false "$TARGET_TRIXIE" "$manifest" false \
    >"$work/state/status-before"
stream_run trixie --reboot
check_rc 0 "a rollback with --reboot succeeds"
check_stage_calls "a rollback with --reboot runs bootc rollback and never a switch" \
    'rollback'
check_order "the rollback branch pulls, rolls back, then reboots" \
    'podman image prune -f' \
    "podman pull --quiet --signature-policy $POLICY_PATH $TARGET_TRIXIE" \
    "podman image inspect --format {{.Digest}} $DEFAULT_ID" \
    'bootc rollback' \
    'systemctl reboot'
if [[ $(tail -n1 "$work/state/systemctl-calls") == reboot ]]; then
    pass "--reboot reboots after the rollback"
else
    fail "--reboot reboots after the rollback (calls: $(tr '\n' '|' <"$work/state/systemctl-calls"))"
fi

# The pulled digest is the rollback deployment's, but that deployment
# follows another reference: a rollback would leave the machine off-stream.
new_work
status "$TARGET_FORKY" '' false 'ghcr.io/frostyard/snow:forky-old' "$manifest" false \
    >"$work/state/status-before"
stream_run trixie --reboot
check_rc 1 "a rollback deployment on another reference is refused"
check_stderr 'not ghcr.io/frostyard/snow:latest' \
    "the refusal names the foreign rollback reference"
check_stage_calls "a foreign rollback deployment neither rolls back nor switches"
check_no_reboot "a refused rollback does not reboot, even with --reboot"

# --- the stager's lock ------------------------------------------------------

new_work
status "$TARGET_FORKY" "$manifest" true '' '' false >"$work/state/status-locked"
status "$TARGET_FORKY" "$manifest" false '' '' false >"$work/state/status-unlocked"
lock_wait=1
exec {held}>"$work/run/update-stage.lock"
flock -n "$held"
stream_run forky
exec {held}>&-
check_rc 1 "a held update-stage.lock makes the command fail after its wait"
check_stderr 'update-stage.lock' "the failure names the stager's lock"
check_stdout 'waiting up to 1s' "the command says it waits for the running stager"
check_no_call podman pull "a command that could not take the lock pulls nothing"
check_stage_calls "a command that could not take the lock stages nothing"

# --- the command's own source ----------------------------------------------

policy_lines=$(grep -Fxc "readonly BOOTC_POLICY=$POLICY_PATH" "$SCRIPT" || true)
if [[ $policy_lines == 1 ]]; then
    pass "the command pins the strict update policy path exactly once"
else
    fail "the command pins the strict update policy path exactly once (found ${policy_lines})"
fi

pull_lines=$(grep -E '(^|[^[:alnum:]_])podman pull' "$SCRIPT" |
    grep -vE '^[[:space:]]*#' | grep -vE '^[[:space:]]*echo ' || true)
if [[ -n $pull_lines ]] &&
        [[ $(grep -c . <<<"$pull_lines") == $(grep -cF -- '--signature-policy "$BOOTC_POLICY"' <<<"$pull_lines") ]]; then
    pass "every podman pull in the command names the strict update policy"
else
    fail "every podman pull in the command names the strict update policy (lines: ${pull_lines:-none})"
fi

if grep -Fq -- '--policy' "$SCRIPT"; then
    fail "the command never uses the pull policy override"
else
    pass "the command never uses the pull policy override"
fi

if grep -Fq 'POLICY:-' "$SCRIPT"; then
    fail "the command allows no environment override of its policy path"
else
    pass "the command allows no environment override of its policy path"
fi

if grep -Fq 'exec {lock_fd}>"$RUN_DIR/update-stage.lock"' "$SCRIPT"; then
    pass "the command takes the stager's update-stage.lock"
else
    fail "the command takes the stager's update-stage.lock"
fi

if (( failures > 0 )); then
    printf '\n%d failed\n' "$failures"
    exit 1
fi
printf '\nall checks passed\n'
