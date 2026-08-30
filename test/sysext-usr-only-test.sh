#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixtures for shared/sysext/finalize/sysext-usr-only.sh.
#
# The guard inspects /opt only: mkosi's sysext repart definition copies
# exactly /usr/ and /opt/ into the published image, so buildroot /var is
# build residue that never ships. When the .mkosi checkout is present the
# test also pins that packing contract, so a mkosi bump that starts shipping
# more of the buildroot fails here rather than silently widening the payload.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FINALIZE_SCRIPT="$ROOT_DIR/shared/sysext/finalize/sysext-usr-only.sh"
MKOSI_SYSEXT_REPART_DIR="$ROOT_DIR/.mkosi/mkosi/resources/repart/definitions/sysext.repart.d"
WORK_DIR="$(mktemp -d)"
BUILDROOT="$WORK_DIR/buildroot"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

pass() {
    echo "PASS: $*"
}

run_finalize() {
    local output

    if output=$(BUILDROOT="$BUILDROOT" IMAGE_ID=fixture "$FINALIZE_SCRIPT" 2>&1); then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
    RUN_OUTPUT="$output"
}

reset_buildroot() {
    rm -rf "$BUILDROOT"
    mkdir -p "$BUILDROOT/usr/bin" "$BUILDROOT/var" "$BUILDROOT/opt"
    printf '#!/bin/sh\n' >"$BUILDROOT/usr/bin/fixture"
}

# --- mkosi packing contract pin -------------------------------------------

if [[ -d "$MKOSI_SYSEXT_REPART_DIR" ]]; then
    copy_files=$(grep -h '^CopyFiles=' "$MKOSI_SYSEXT_REPART_DIR"/*.conf | sort -u | tr '\n' ' ')
    if [[ "$copy_files" == "CopyFiles=/opt/ CopyFiles=/usr/ " ]]; then
        pass "pinned mkosi sysext repart definition ships exactly /usr/ and /opt/"
    else
        fail "mkosi sysext repart definition changed its CopyFiles= set ($copy_files); the guard's /opt-only scope must be re-derived"
    fi
else
    echo "SKIP: no .mkosi checkout at $MKOSI_SYSEXT_REPART_DIR; mkosi packing contract not pinned"
fi

# --- guard behaviour --------------------------------------------------------

reset_buildroot
run_finalize
if [[ $RUN_STATUS -eq 0 ]]; then
    pass "/usr payload with empty /var and /opt mountpoints is accepted"
else
    fail "/usr payload was rejected: $RUN_OUTPUT"
fi

reset_buildroot
run_finalize_missing_opt() {
    rm -rf "$BUILDROOT/opt"
    run_finalize
}
run_finalize_missing_opt
if [[ $RUN_STATUS -eq 0 ]]; then
    pass "absent /opt directory is accepted"
else
    fail "absent /opt was rejected: $RUN_OUTPUT"
fi

reset_buildroot
mkdir -p "$BUILDROOT/var/log" "$BUILDROOT/var/lib/emacsen-common/state"
printf 'build log\n' >"$BUILDROOT/var/log/dpkg.log"
printf 'trigger state\n' >"$BUILDROOT/var/lib/emacsen-common/state/installed"
run_finalize
if [[ $RUN_STATUS -eq 0 && -e "$BUILDROOT/var/log/dpkg.log" ]]; then
    pass "buildroot /var residue is neither rejected nor modified (mkosi never ships it)"
else
    fail "buildroot /var residue produced the wrong result: status=$RUN_STATUS $RUN_OUTPUT"
fi

reset_buildroot
mkdir -p "$BUILDROOT/opt/fixture/bin"
printf '#!/bin/sh\n' >"$BUILDROOT/opt/fixture/bin/tool"
run_finalize
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/opt/fixture"* &&
    "$RUN_OUTPUT" == *"must be /usr-only"* ]]; then
    pass "/opt payload is rejected with the contract and offending path"
else
    fail "/opt payload produced the wrong result: $RUN_OUTPUT"
fi

reset_buildroot
mkdir -p "$BUILDROOT/opt/fixture/empty-dir"
run_finalize
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/opt/fixture"* ]]; then
    pass "nonempty /opt (subdirectory only) is rejected"
else
    fail "/opt subdirectory produced the wrong result: $RUN_OUTPUT"
fi

reset_buildroot
mkdir -p "$WORK_DIR/outside"
printf 'must not be inspected\n' >"$WORK_DIR/outside/host-path"
ln -s "$WORK_DIR/outside" "$BUILDROOT/opt/external-link"
run_finalize
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/opt/external-link"* &&
    "$RUN_OUTPUT" != *"host-path"* ]]; then
    pass "symlink payload is rejected without traversing outside the buildroot"
else
    fail "symlink payload produced the wrong result: $RUN_OUTPUT"
fi

reset_buildroot
rmdir "$BUILDROOT/opt"
ln -s "$WORK_DIR/outside" "$BUILDROOT/opt"
run_finalize
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"  /opt"* &&
    "$RUN_OUTPUT" != *"host-path"* ]]; then
    pass "/opt as a symlink is rejected without following it"
else
    fail "/opt symlink produced the wrong result: $RUN_OUTPUT"
fi

reset_buildroot
run_finalize_no_env() {
    local output
    if output=$(BUILDROOT="$WORK_DIR/does-not-exist" IMAGE_ID=fixture "$FINALIZE_SCRIPT" 2>&1); then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
    RUN_OUTPUT="$output"
}
run_finalize_no_env
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"BUILDROOT"* ]]; then
    pass "missing BUILDROOT fails closed"
else
    fail "missing BUILDROOT produced the wrong result: $RUN_OUTPUT"
fi

if ((failures > 0)); then
    exit 1
fi

echo "sysext-usr-only-test: PASSED"
