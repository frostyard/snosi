#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FINALIZE_SCRIPT="$ROOT_DIR/shared/sysext/finalize/sysext-usr-only.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

pass() {
    echo "PASS: $*"
}

# Run the guard against a freshly built buildroot delta. The caller populates
# "$WORK_DIR/buildroot" before invoking; this resets it each time.
reset_buildroot() {
    rm -rf "$WORK_DIR/buildroot"
    mkdir -p "$WORK_DIR/buildroot"
}

run_finalize() {
    local output
    if output=$(BUILDROOT="$WORK_DIR/buildroot" IMAGE_ID=test \
        "$FINALIZE_SCRIPT" 2>&1); then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
    RUN_OUTPUT="$output"
}

# 1. A /usr-only delta is accepted.
reset_buildroot
mkdir -p "$WORK_DIR/buildroot/usr/lib/example" "$WORK_DIR/buildroot/usr/bin"
printf '#!/bin/sh\n' > "$WORK_DIR/buildroot/usr/bin/example"
run_finalize
if [[ $RUN_STATUS -eq 0 ]]; then
    pass "delta with only /usr payload is accepted"
else
    fail "delta with only /usr payload is accepted: $RUN_OUTPUT"
fi

# 2. Empty /var and /opt mountpoint directories are permitted.
reset_buildroot
mkdir -p "$WORK_DIR/buildroot/usr/bin" "$WORK_DIR/buildroot/var" "$WORK_DIR/buildroot/opt"
run_finalize
if [[ $RUN_STATUS -eq 0 ]]; then
    pass "empty /var and /opt mountpoint directories are permitted"
else
    fail "empty /var and /opt mountpoint directories are permitted: $RUN_OUTPUT"
fi

# 2b. Empty nested directories carry no payload and are permitted (Debian
# packages routinely create an empty /var/lib/<pkg> state directory).
reset_buildroot
mkdir -p "$WORK_DIR/buildroot/var/lib/example" "$WORK_DIR/buildroot/opt/vendor"
run_finalize
if [[ $RUN_STATUS -eq 0 ]]; then
    pass "empty nested /var and /opt directories are permitted"
else
    fail "empty nested /var and /opt directories are permitted: $RUN_OUTPUT"
fi

# 3. A /var payload file is rejected and named.
reset_buildroot
mkdir -p "$WORK_DIR/buildroot/var/lib/example"
printf 'state\n' > "$WORK_DIR/buildroot/var/lib/example/state"
run_finalize
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/var/lib/example/state"* ]]; then
    pass "/var payload file is rejected and named"
else
    fail "/var payload file is rejected and named (status=$RUN_STATUS): $RUN_OUTPUT"
fi

# 4. An /opt payload file is rejected and named.
reset_buildroot
mkdir -p "$WORK_DIR/buildroot/opt/vendor/bin"
printf '#!/bin/sh\n' > "$WORK_DIR/buildroot/opt/vendor/bin/tool"
run_finalize
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/opt/vendor/bin/tool"* ]]; then
    pass "/opt payload file is rejected and named"
else
    fail "/opt payload file is rejected and named (status=$RUN_STATUS): $RUN_OUTPUT"
fi

# 5. A symlink under /opt is rejected without following it out of the delta.
reset_buildroot
mkdir -p "$WORK_DIR/buildroot/opt"
ln -s /usr/lib/vendor "$WORK_DIR/buildroot/opt/vendor"
run_finalize
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/opt/vendor"* ]]; then
    pass "/opt symlink payload is rejected and named"
else
    fail "/opt symlink payload is rejected and named (status=$RUN_STATUS): $RUN_OUTPUT"
fi

# 5b. The /opt mountpoint itself shipped as a symlink is rejected (find would
# not descend a command-line symlink, so this must be caught explicitly).
reset_buildroot
mkdir -p "$WORK_DIR/buildroot/usr/lib/stuff"
ln -s /usr/lib/stuff "$WORK_DIR/buildroot/opt"
run_finalize
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/opt"* ]]; then
    pass "/opt shipped as a symlink is rejected"
else
    fail "/opt shipped as a symlink is rejected (status=$RUN_STATUS): $RUN_OUTPUT"
fi

# 6. The failure output explains the /usr-only contract.
reset_buildroot
mkdir -p "$WORK_DIR/buildroot/opt/vendor"
printf 'x\n' > "$WORK_DIR/buildroot/opt/vendor/file"
run_finalize
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/usr-only"* ]]; then
    pass "failure output explains the /usr-only contract"
else
    fail "failure output explains the /usr-only contract: $RUN_OUTPUT"
fi

if (( failures > 0 )); then
    exit 1
fi

echo "sysext-usr-only-test: PASSED"
