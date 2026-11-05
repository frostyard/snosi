#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixtures for shared/bootc-secure/finalize/coredump.finalize (ADR-0029,
# T857a) plus wiring checks: the secure composition installs
# systemd-coredump from the Forky family with libdw and libelf, ships the
# Storage=none drop-in, runs the guard, and all four product profiles include
# it. The fixture root copies the facts of the forky deb systemd-coredump
# 262-1 (core_pattern, suid_dumpable, the commented /etc main file). No root.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT_DIR/shared/bootc-secure/finalize/coredump.finalize"
SECURE_CONF="$ROOT_DIR/shared/bootc-secure/mkosi.conf"
DROPIN="$ROOT_DIR/shared/bootc-secure/tree/usr/lib/systemd/coredump.conf.d/50-snosi.conf"
WORK_DIR="$(mktemp -d)"
BUILDROOT="$WORK_DIR/root"
trap 'chmod -R u+rwX "$WORK_DIR" 2>/dev/null; rm -rf "$WORK_DIR"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "PASS: $*"; }

LIBDIR=usr/lib/x86_64-linux-gnu

reset_root() {
    rm -rf "$BUILDROOT"
    mkdir -p "$BUILDROOT/usr/lib/systemd/coredump.conf.d" "$BUILDROOT/usr/lib/sysctl.d" \
        "$BUILDROOT/etc/systemd" "$BUILDROOT/etc/sysctl.d" "$BUILDROOT/$LIBDIR"
    printf '#!/bin/sh\n' >"$BUILDROOT/usr/lib/systemd/systemd-coredump"
    chmod 755 "$BUILDROOT/usr/lib/systemd/systemd-coredump"
    # The deb's /etc main file: every value commented out.
    printf '[Coredump]\n#Storage=external\n#ProcessSizeMax=32G\n' >"$BUILDROOT/etc/systemd/coredump.conf"
    cp "$DROPIN" "$BUILDROOT/usr/lib/systemd/coredump.conf.d/50-snosi.conf"
    cat >"$BUILDROOT/usr/lib/sysctl.d/50-coredump.conf" <<'EOF'
kernel.core_pattern=|/usr/lib/systemd/systemd-coredump %P %u %g %s %t %c %h %d %F %I
kernel.core_pipe_limit=16
fs.suid_dumpable=2
EOF
    printf 'kernel.yama.ptrace_scope = 1\n' >"$BUILDROOT/etc/sysctl.conf"
    ln -s ../sysctl.conf "$BUILDROOT/etc/sysctl.d/99-sysctl.conf"
    : >"$BUILDROOT/$LIBDIR/libdw-0.192.so"
    ln -s libdw-0.192.so "$BUILDROOT/$LIBDIR/libdw.so.1"
    : >"$BUILDROOT/$LIBDIR/libelf-0.192.so"
    ln -s libelf-0.192.so "$BUILDROOT/$LIBDIR/libelf.so.1"
}

run() {
    if RUN_OUTPUT=$(BUILDROOT="$BUILDROOT" "$GUARD" 2>&1); then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
}

expect_pass() { # description
    run
    if [[ $RUN_STATUS -eq 0 ]]; then pass "$1"; else fail "$1 (exit $RUN_STATUS): $RUN_OUTPUT"; fi
}

expect_reject() { # description expected-substring
    run
    if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"coredump.finalize:"* && "$RUN_OUTPUT" == *"$2"* ]]; then
        pass "$1"
    else
        fail "$1 (exit $RUN_STATUS): $RUN_OUTPUT"
    fi
}

conf() { # relpath content
    mkdir -p "$(dirname "$BUILDROOT/$1")"
    printf '%s\n' "$2" >"$BUILDROOT/$1"
}

# --- pass -------------------------------------------------------------------
reset_root
expect_pass "the deb's files plus the snosi drop-in pass"

reset_root
conf usr/lib/systemd/coredump.conf.d/50-snosi.conf $'[Coredump]\nStorage = none\nProcessSizeMax = 1024M'
expect_pass "1024M and spaces around = pass"

reset_root
conf etc/systemd/coredump.conf.d/10-other.conf $'[Other]\nStorage=external\nProcessSizeMax=32G'
expect_pass "keys outside [Coredump] are ignored"

reset_root
rm "$BUILDROOT/$LIBDIR/libdw.so.1"
ln -s "/$LIBDIR/libdw-0.192.so" "$BUILDROOT/$LIBDIR/libdw.so.1"
expect_pass "an absolute library symlink resolves inside the image root"

# --- 1. the binary ----------------------------------------------------------
reset_root
rm "$BUILDROOT/usr/lib/systemd/systemd-coredump"
expect_reject "a missing systemd-coredump binary is rejected" "systemd-coredump is missing"

reset_root
chmod 644 "$BUILDROOT/usr/lib/systemd/systemd-coredump"
expect_reject "a binary that is not executable is rejected" "not executable"

# --- 2. coredump.conf -------------------------------------------------------
reset_root
rm "$BUILDROOT/usr/lib/systemd/coredump.conf.d/50-snosi.conf"
expect_reject "no Storage= setting (default external) is rejected" "Storage= resolves to 'default'"

reset_root
conf etc/systemd/coredump.conf.d/60-admin.conf $'[Coredump]\nStorage=external'
expect_reject "an /etc drop-in with Storage=external is rejected" "Storage= resolves to 'external'"

reset_root
conf usr/lib/systemd/coredump.conf.d/99-late.conf $'[Coredump]\nStorage=journal'
expect_reject "a later /usr drop-in with Storage=journal is rejected" "Storage= resolves to 'journal'"

reset_root
conf etc/systemd/coredump.conf $'[Coredump]\nStorage=external'
expect_reject "an /etc main file with Storage=external fails the plain order" "(plain order)"

reset_root
conf etc/systemd/coredump.conf.d/70-reset.conf $'[Coredump]\nStorage='
expect_reject "an empty Storage= (back to the default) is rejected" "Storage= resolves to 'default'"

reset_root
conf usr/lib/systemd/coredump.conf.d/50-snosi.conf $'[Coredump]\nStorage=none\nProcessSizeMax=2G'
expect_reject "ProcessSizeMax=2G is rejected" "above the 1G cap"

reset_root
conf usr/lib/systemd/coredump.conf.d/50-snosi.conf $'[Coredump]\nStorage=none\nProcessSizeMax=8388608T'
expect_reject "a size that overflows 64 bits (8388608T) is rejected" "above the 1G cap"

reset_root
conf usr/lib/systemd/coredump.conf.d/50-snosi.conf $'[Coredump]\nStorage=none\nProcessSizeMax=999999999999999G'
expect_reject "a 15-digit size in G is rejected" "above the 1G cap"

reset_root
conf usr/lib/systemd/coredump.conf.d/50-snosi.conf $'[Coredump]\nStorage=none\nProcessSizeMax=0900M'
expect_pass "a leading zero is read in base 10 (0900M passes)"

reset_root
conf usr/lib/systemd/coredump.conf.d/50-snosi.conf $'[Coredump]\nStorage=none\nProcessSizeMax=infinity'
expect_reject "ProcessSizeMax=infinity is rejected" "ProcessSizeMax= resolves to 'infinity'"

reset_root
conf usr/lib/systemd/coredump.conf.d/50-snosi.conf $'[Coredump]\nStorage=none'
expect_reject "no ProcessSizeMax= (default 32G) is rejected" "ProcessSizeMax= resolves to 'default'"

# --- 3. core_pattern --------------------------------------------------------
reset_root
sed -i 's/ %F//' "$BUILDROOT/usr/lib/sysctl.d/50-coredump.conf"
expect_reject "a core_pattern without %F is rejected" "lacks %F"

reset_root
sed -i 's/ %d//' "$BUILDROOT/usr/lib/sysctl.d/50-coredump.conf"
expect_reject "a core_pattern without %d is rejected" "lacks %d"

reset_root
conf etc/sysctl.d/60-core.conf 'kernel.core_pattern = core'
expect_reject "a later sysctl.d file that stops the pipe is rejected" "does not pipe to"

reset_root
rm "$BUILDROOT/usr/lib/sysctl.d/50-coredump.conf"
expect_reject "no core_pattern at all is rejected" "no sysctl.d file sets kernel.core_pattern"

# --- 4. fs.suid_dumpable ----------------------------------------------------
reset_root
conf etc/sysctl.d/90-dump.conf 'fs.suid_dumpable = 1'
expect_reject "fs.suid_dumpable=1 in etc/sysctl.d is rejected" "sets fs.suid_dumpable=1"

reset_root
conf usr/lib/sysctl.d/10-dump.conf '-fs/suid_dumpable=1'
expect_reject "fs/suid_dumpable=1 with a - prefix in usr/lib/sysctl.d is rejected" "sets fs.suid_dumpable=1"

reset_root
printf 'fs.suid_dumpable=1\n' >"$BUILDROOT/etc/sysctl.conf"
expect_reject "fs.suid_dumpable=1 behind the 99-sysctl.conf symlink is rejected" "sets fs.suid_dumpable=1"

# --- 5. libraries -----------------------------------------------------------
reset_root
rm "$BUILDROOT/$LIBDIR/libdw.so.1"
expect_reject "a missing libdw.so.1 is rejected" "libdw.so.1 is missing"

reset_root
rm "$BUILDROOT/$LIBDIR/libelf.so.1"
expect_reject "a missing libelf.so.1 is rejected" "libelf.so.1 is missing"

reset_root
rm "$BUILDROOT/$LIBDIR/libelf-0.192.so"
expect_reject "a dangling libelf.so.1 symlink is rejected" "libelf.so.1 is missing"

if RUN_OUTPUT=$(env -u BUILDROOT "$GUARD" 2>&1); then
    fail "missing BUILDROOT must fail closed"
else
    pass "missing BUILDROOT fails closed"
fi

# --- wiring -----------------------------------------------------------------
if grep -Fqx 'FinalizeScripts=%D/shared/bootc-secure/finalize/coredump.finalize' "$SECURE_CONF"; then
    pass "the secure composition runs the guard"
else
    fail "$SECURE_CONF must list FinalizeScripts=%D/shared/bootc-secure/finalize/coredump.finalize"
fi
if grep -qE '^[[:space:]]+systemd-coredump/forky$' "$SECURE_CONF"; then
    pass "systemd-coredump comes from the Forky systemd family"
else
    fail "$SECURE_CONF must select systemd-coredump/forky in the Forky family list"
fi
for package in libdw1t64 libelf1t64; do
    if grep -qE "^(Packages=|[[:space:]]+)$package$" "$SECURE_CONF"; then
        pass "$package is installed from Trixie"
    else
        fail "$SECURE_CONF must install $package (no suite suffix)"
    fi
done
if [[ "$(grep -vE '^[[:space:]]*(#|$)' "$DROPIN")" == $'[Coredump]\nStorage=none\nProcessSizeMax=1G' ]]; then
    pass "the drop-in sets exactly Storage=none and ProcessSizeMax=1G"
else
    fail "$DROPIN must set exactly Storage=none and ProcessSizeMax=1G"
fi
for profile in snow snowfield floe sundog; do
    if grep -Fqx 'Include=%D/shared/bootc-secure/mkosi.conf' "$ROOT_DIR/mkosi.profiles/$profile/mkosi.conf"; then
        pass "$profile includes the secure composition"
    else
        fail "mkosi.profiles/$profile/mkosi.conf must include shared/bootc-secure/mkosi.conf"
    fi
done

if ((failures > 0)); then
    echo "coredump-guard-test: $failures failure(s)" >&2
    exit 1
fi
echo "coredump-guard-test: PASSED"
