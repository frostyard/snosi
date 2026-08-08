#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static, non-root fixtures for snosi-kargs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/mkosi.images/base/mkosi.extra/usr/bin/snosi-kargs"
ESP_LIBRARY="$ROOT_DIR/mkosi.images/base/mkosi.extra/usr/lib/snosi/esp.sh"
WORK=""
PASS=0
FAIL=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

cleanup() {
    [[ -z $WORK ]] || rm -rf -- "$WORK"
}
trap cleanup EXIT

setup_fixture() {
    cleanup
    WORK=$(mktemp -d)
    mkdir -p "$WORK/bin" "$WORK/state" "$WORK/esp" "$WORK/run"
    printf 'private\n' >"$WORK/state/signing.key"
    printf 'certificate\n' >"$WORK/state/signing.crt"
    chmod 600 "$WORK/state/signing.key"
    : >"$WORK/tool.log"

    cat >"$WORK/bin/mokutil" <<'EOF'
#!/bin/bash
case "$1" in
    --sb-state)
        if [[ ${SNOSI_TEST_SB_STATE:-enabled} == enabled ]]; then
            echo "SecureBoot enabled"
        else
            echo "SecureBoot disabled"
        fi
        ;;
    --test-key)
        [[ ${SNOSI_TEST_MOK_ENROLLED:-1} == 1 ]]
        ;;
    --generate-hash=*)
        printf 'fixture-hash\n'
        printf 'mokutil %s\n' "$*" >>"$SNOSI_TEST_TOOL_LOG"
        ;;
    --import)
        printf 'mokutil %s\n' "$*" >>"$SNOSI_TEST_TOOL_LOG"
        ;;
    *)
        exit 90
        ;;
esac
EOF

    cat >"$WORK/bin/openssl" <<'EOF'
#!/bin/bash
case "$1" in
    pkey)
        while [[ $# -gt 0 ]]; do
            if [[ $1 == -out ]]; then printf 'public\n' >"$2"; exit 0; fi
            shift
        done
        ;;
    x509)
        for arg in "$@"; do
            [[ $arg == -pubkey ]] && { printf 'public\n'; exit 0; }
        done
        while [[ $# -gt 0 ]]; do
            if [[ $1 == -out ]]; then printf 'der\n' >"$2"; exit 0; fi
            shift
        done
        ;;
    req)
        key=""
        cert=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -keyout) key=$2; shift 2 ;;
                -out) cert=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        printf 'private\n' >"$key"
        printf 'certificate\n' >"$cert"
        ;;
    *)
        exit 91
        ;;
esac
EOF

    cat >"$WORK/bin/ukify" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$SNOSI_TEST_UKIFY_ARGS"
output=""
signed=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) output=$2; shift 2 ;;
        --secureboot-private-key) signed=1; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n $output ]]
if [[ $signed -eq 1 ]]; then printf 'signed-addon\n' >"$output"; else printf 'unsigned-addon\n' >"$output"; fi
EOF

    cat >"$WORK/bin/sbverify" <<'EOF'
#!/bin/bash
[[ $1 == --cert && -f $2 && $(cat "$3") == signed-addon ]]
EOF

    cat >"$WORK/bin/sync" <<'EOF'
#!/bin/bash
count=0
[[ ! -f $SNOSI_TEST_SYNC_COUNT ]] || count=$(<"$SNOSI_TEST_SYNC_COUNT")
count=$((count + 1))
printf '%s' "$count" >"$SNOSI_TEST_SYNC_COUNT"
[[ ${SNOSI_TEST_SYNC_FAIL_ON:-0} != "$count" ]]
EOF

    chmod +x "$WORK/bin/"*
}

run_cli() {
    PATH="$WORK/bin:$PATH" \
    SNOSI_KARGS_TEST_NON_ROOT=1 \
    SNOSI_KARGS_STATE_DIR="$WORK/state" \
    SNOSI_KARGS_RUN_DIR="$WORK/run" \
    SNOSI_ESP_LIBRARY="$ESP_LIBRARY" \
    SNOSI_ESP_TEST_PATH="$WORK/esp" \
    SNOSI_TEST_TOOL_LOG="$WORK/tool.log" \
    SNOSI_TEST_UKIFY_ARGS="$WORK/ukify.args" \
    SNOSI_TEST_SYNC_COUNT="$WORK/sync.count" \
    "$SCRIPT" "$@"
}

assert_eq() { # description actual expected
    if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

assert_contains() { # description haystack needle
    if [[ $2 == *"$3"* ]]; then pass "$1"; else fail "$1 (missing '$3')"; fi
}

echo "# refusal matrix"
setup_fixture
for rejected in \
    root=/dev/vda2 rootfstype=ext4 rootflags=rw roothash=deadbeef \
    usrhash=deadbeef systemd.verity_root_data=/dev/vda2 rd.luks.uuid=deadbeef \
    composefs=deadbeef systemd.gpt_auto=no init=/bin/sh rd.break rd.shell \
    emergency systemd.unit=emergency.target systemd.unit=rescue.target \
    rd.systemd.unit=emergency.target rd.systemd.unit=rescue.target \
    "console=ttyS0 debug"; do
    if run_cli set --no-apply "$rejected" >/dev/null 2>&1; then
        fail "refuses $rejected"
    else
        pass "refuses $rejected"
    fi
done

PATH="$WORK/bin:$PATH" \
SNOSI_KARGS_TEST_NON_ROOT=1 \
SNOSI_KARGS_STATE_DIR="$WORK/state" \
SNOSI_KARGS_RUN_DIR="$WORK/run" \
SNOSI_ESP_LIBRARY="$ESP_LIBRARY" \
SNOSI_ESP_TEST_PATH="$WORK/esp" \
SNOSI_TEST_TOOL_LOG="$WORK/tool.log" \
SNOSI_TEST_UKIFY_ARGS="$WORK/ukify.args" \
SNOSI_TEST_SYNC_COUNT="$WORK/sync.count" \
python3 - "$SCRIPT" <<'PY'
import os
import pty
import sys

pid, fd = pty.fork()
if pid == 0:
    os.execve(
        sys.argv[1],
        [sys.argv[1], "set", "--force", "--no-apply", "root=/dev/vda2"],
        os.environ,
    )

transcript = b""
sent = False
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    transcript += chunk
    if not sent and b"Type exactly" in transcript:
        os.write(fd, b"I understand this may make the system unbootable\n")
        sent = True

_, status = os.waitpid(pid, 0)
exit_code = os.waitstatus_to_exitcode(status)
if exit_code != 0:
    sys.stderr.buffer.write(transcript)
    raise SystemExit(exit_code)
PY
assert_eq "interactive --force override persists a refused argument" \
    "$(cat "$WORK/state/args")" "root=/dev/vda2"

run_cli set --no-apply mitigations=off console=tty0
assert_eq "safe arguments persist one per line" \
    "$(cat "$WORK/state/args")" $'mitigations=off\nconsole=tty0'

echo "# mutation behavior"
run_cli add --no-apply console=tty0 debug
assert_eq "add deduplicates existing arguments" \
    "$(cat "$WORK/state/args")" $'mitigations=off\nconsole=tty0\ndebug'
run_cli remove --no-apply console=tty0
assert_eq "remove deletes exact arguments" \
    "$(cat "$WORK/state/args")" $'mitigations=off\ndebug'
run_cli clear --no-apply
assert_eq "clear leaves an empty persisted argument file" \
    "$(wc -c <"$WORK/state/args")" "0"
if run_cli clear unexpected >/dev/null 2>&1; then
    fail "clear rejects unexpected positional arguments"
else
    pass "clear rejects unexpected positional arguments"
fi

echo "# signed apply under enforced Secure Boot"
setup_fixture
run_cli set --no-apply mitigations=off driver.option=1
rm -f "$WORK/sync.count"
run_cli apply
addon="$WORK/esp/loader/addons/50-snosi-local.addon.efi"
assert_eq "signed addon is installed globally" "$(cat "$addon")" "signed-addon"
assert_eq "applied arguments are recorded" \
    "$(cat "$WORK/state/applied.args")" $'mitigations=off\ndriver.option=1'
status_out=$(run_cli status)
assert_contains "status reports a current applied addon" "$status_out" "Pending:     no"
if grep -Fxq -- '--linux' "$WORK/ukify.args"; then
    fail "ukify addon invocation omits --linux"
else
    pass "ukify addon invocation omits --linux"
fi
assert_contains "ukify receives both managed arguments" \
    "$(cat "$WORK/ukify.args")" $'--cmdline\nmitigations=off driver.option=1'
assert_contains "ukify signs with the selected private key" \
    "$(cat "$WORK/ukify.args")" "--secureboot-private-key"
printf 'tampered\n' >"$addon"
status_out=$(run_cli status)
assert_contains "status detects an externally modified addon" \
    "$status_out" "present, differs from last applied artifact"
assert_contains "modified addon is reported pending" "$status_out" "Pending:     yes"

echo "# Secure Boot decision matrix"
setup_fixture
run_cli set --no-apply debug
if SNOSI_TEST_MOK_ENROLLED=0 run_cli apply >/dev/null 2>&1; then
    fail "signed apply refuses an unenrolled certificate under Secure Boot"
else
    pass "signed apply refuses an unenrolled certificate under Secure Boot"
fi
[[ ! -e $WORK/esp/loader/addons/50-snosi-local.addon.efi ]] &&
    pass "unenrolled certificate failure writes no addon" ||
    fail "unenrolled certificate failure writes no addon"

if run_cli apply --unsigned >/dev/null 2>&1; then
    fail "unsigned apply is refused under Secure Boot"
else
    pass "unsigned apply is refused under Secure Boot"
fi

SNOSI_TEST_SB_STATE=disabled run_cli apply --unsigned
assert_eq "unsigned addon is allowed only with Secure Boot disabled" \
    "$(cat "$WORK/esp/loader/addons/50-snosi-local.addon.efi")" "unsigned-addon"
if grep -Fxq -- '--secureboot-private-key' "$WORK/ukify.args"; then
    fail "unsigned ukify invocation omits signing options"
else
    pass "unsigned ukify invocation omits signing options"
fi

echo "# dry-run and atomic replacement"
setup_fixture
run_cli set --no-apply debug
dry_out=$(run_cli apply --dry-run)
assert_contains "dry-run reports the global addon destination" "$dry_out" \
    "$WORK/esp/loader/addons/50-snosi-local.addon.efi"
[[ ! -e $WORK/esp/loader/addons/50-snosi-local.addon.efi ]] &&
    pass "dry-run does not install an addon" ||
    fail "dry-run does not install an addon"

mkdir -p "$WORK/esp/loader/addons"
printf 'old-addon\n' >"$WORK/esp/loader/addons/50-snosi-local.addon.efi"
rm -f "$WORK/sync.count"
if SNOSI_TEST_SYNC_FAIL_ON=3 run_cli apply >/dev/null 2>&1; then
    fail "post-replacement sync failure is surfaced"
else
    pass "post-replacement sync failure is surfaced"
fi
assert_eq "post-replacement sync failure restores the old addon" \
    "$(cat "$WORK/esp/loader/addons/50-snosi-local.addon.efi")" "old-addon"

rm -f "$WORK/sync.count"
if SNOSI_TEST_SYNC_FAIL_ON=1 run_cli revert >/dev/null 2>&1; then
    fail "revert sync failure is surfaced"
else
    pass "revert sync failure is surfaced"
fi
assert_eq "revert sync failure restores the active addon" \
    "$(cat "$WORK/esp/loader/addons/50-snosi-local.addon.efi")" "old-addon"

echo "# MOK enrollment argv"
setup_fixture
PATH="$WORK/bin:$PATH" \
SNOSI_KARGS_TEST_NON_ROOT=1 \
SNOSI_KARGS_STATE_DIR="$WORK/state" \
SNOSI_KARGS_RUN_DIR="$WORK/run" \
SNOSI_ESP_LIBRARY="$ESP_LIBRARY" \
SNOSI_ESP_TEST_PATH="$WORK/esp" \
SNOSI_TEST_TOOL_LOG="$WORK/tool.log" \
SNOSI_TEST_UKIFY_ARGS="$WORK/ukify.args" \
SNOSI_TEST_SYNC_COUNT="$WORK/sync.count" \
SNOSI_TEST_MOK_ENROLLED=0 \
python3 - "$SCRIPT" <<'PY'
import os
import pty
import sys

pid, fd = pty.fork()
if pid == 0:
    os.execve(sys.argv[1], [sys.argv[1], "key", "enroll"], os.environ)

buffer = b""
transcript = b""
sent_first = False
sent_second = False
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    buffer += chunk
    transcript += chunk
    if not sent_first and b"One-time MokManager password:" in buffer:
        os.write(fd, b"fixture-password\n")
        sent_first = True
        buffer = b""
    elif not sent_second and b"Repeat password:" in buffer:
        os.write(fd, b"fixture-password\n")
        sent_second = True
        buffer = b""

_, status = os.waitpid(pid, 0)
exit_code = os.waitstatus_to_exitcode(status)
if exit_code != 0:
    sys.stderr.buffer.write(transcript)
    raise SystemExit(exit_code)
PY
assert_contains "MOK enrollment uses mokutil --generate-hash" \
    "$(cat "$WORK/tool.log")" "mokutil --generate-hash=fixture-password"
assert_contains "MOK enrollment imports DER with the generated hash file" \
    "$(cat "$WORK/tool.log")" "mokutil --import"
assert_contains "MOK enrollment passes --hash-file" \
    "$(cat "$WORK/tool.log")" "--hash-file"

printf '\n# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
