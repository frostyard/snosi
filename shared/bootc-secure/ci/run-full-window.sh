#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Run externally prepared Task 9/10 evidence without accepting executable input.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly REF_NAMES=(
    OCI_REF TRACKING_REF UPDATE_N1_REF UPDATE_N2_REF UPDATE_N1_VERSION UPDATE_N2_VERSION
    ROTATION_OLD_REF ROTATION_TRANSITION_REF ROTATION_NEW_REF
)

validate_state_root() {
    local state_root=$1
    [[ $state_root == /* && -d $state_root ]] || return 1
    [[ $(stat -c '%a' "$state_root") == 700 && $(stat -c '%u' "$state_root") == $(id -u) ]]
}

load_refs_env() {
    local refs=$1 line name value allowed
    local -A seen=()
    [[ -f $refs && ! -L $refs ]] || return 1
    [[ $(stat -c '%a' "$refs") == 600 && $(stat -c '%u' "$refs") == $(id -u) ]] || return 1

    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9.:/@+_-]*)$ ]] || return 1
        name=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        allowed=0
        for name in "${REF_NAMES[@]}"; do
            [[ ${BASH_REMATCH[1]} == "$name" ]] && allowed=1
        done
        ((allowed)) || return 1
        [[ ! -v "seen[${BASH_REMATCH[1]}]" ]] || return 1
        seen[${BASH_REMATCH[1]}]=1
        [[ -n $value || $line == *= ]] || return 1
    done <"$refs"

    for name in "${REF_NAMES[@]}"; do
        printf -v "$name" '%s' ''
        # shellcheck disable=SC2163 # The value of name is the variable to export.
        export "$name"
    done
    # Validation above permits only literal NAME=value assignments.
    # shellcheck disable=SC1090
    source "$refs"
}

run_full_window() {
    local state_root=$1 profile=$2
    validate_state_root "$state_root" || {
        echo "Error: state_root must be an absolute mode-0700 directory owned by the runner" >&2
        return 1
    }
    case $profile in cayo|snow|snowfield) ;; *) echo "Error: unsupported profile: $profile" >&2; return 1;; esac
    load_refs_env "$state_root/refs.env" || {
        echo "Error: refs.env must be a runner-owned mode-0600 plain NAME=value file with known names only" >&2
        return 1
    }

    PROFILE="$profile" \
    DAKOTA_ISO="$state_root/dakota.iso" \
    OCI_REF="$OCI_REF" \
    MOK_CERT="$state_root/mok.crt" \
    PCR_PUBLIC="$state_root/pcr.pub" \
    RECOVERY_KEY="$state_root/recovery.key" \
    TARGET_DISK="$state_root/target.raw" \
    BOOTC_SECURE_INSTALLER="$state_root/installer" \
    BOOTC_SECURE_NEGATIVE_COMMAND="$state_root/negative-runner" \
    BOOTC_SECURE_RECOVERY_COMMAND="$state_root/recovery-runner" \
    BOOTC_SECURE_INSTALL_STATE="$state_root/install-state.json" \
    TRACKING_REF="$TRACKING_REF" \
    KEEP_VM=1 \
    "$ROOT_DIR/test/bootc-secure-install-test.sh"

    BOOTC_SECURE_INSTALL_STATE="$state_root/install-state.json" \
    BOOTC_SECURE_UPDATE_PUBLISH_COMMAND="$state_root/publisher" \
    BOOTC_SECURE_UPDATE_NEGATIVE_COMMAND="$state_root/update-negative-runner" \
    UPDATE_N1_REF="$UPDATE_N1_REF" \
    UPDATE_N2_REF="$UPDATE_N2_REF" \
    UPDATE_N1_VERSION="$UPDATE_N1_VERSION" \
    UPDATE_N2_VERSION="$UPDATE_N2_VERSION" \
    KEEP_VM=1 \
    "$ROOT_DIR/test/bootc-secure-update-test.sh"

    BOOTC_SECURE_ROTATION_STATE="$state_root/install-state.json" \
    BOOTC_SECURE_ROTATION_COMMAND="$state_root/rotation-runner" \
    ROTATION_OLD_REF="$ROTATION_OLD_REF" \
    ROTATION_TRANSITION_REF="$ROTATION_TRANSITION_REF" \
    ROTATION_NEW_REF="$ROTATION_NEW_REF" \
    ROTATION_OLD_MOK_CERT="$state_root/mok.crt" \
    ROTATION_NEW_MOK_CERT="$state_root/mok.crt" \
    ROTATION_OLD_PCR_PUBLIC="$state_root/pcr.pub" \
    ROTATION_NEW_PCR_PUBLIC="$state_root/pcr.pub" \
    "$ROOT_DIR/test/bootc-secure-rotation-test.sh"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    [[ $# -eq 2 ]] || { echo "Usage: $0 STATE_ROOT PROFILE" >&2; exit 2; }
    run_full_window "$1" "$2"
fi
