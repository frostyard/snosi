#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Root-free fixture for shared/kernel/scripts/build-initramfs.sh.
#
# dracut 106 can exit 0 with an initramfs that has no libc and no dynamic
# loader, when its random temporary directory is named dracut.ko* (dracut-ng
# 5c53a810). Floe publish run 43079965647 failed that way. build_initramfs
# must detect that initramfs, run dracut again, and fail after its last try.
# Stubbed dracut and lsinitrd replay one listing per attempt.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/shared/kernel/scripts/build-initramfs.sh"
POSTINST="$ROOT_DIR/shared/kernel/scripts/postinst/mkosi.postinst.chroot"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() {
    local description=$1 expected=$2 actual=$3
    if [[ "$actual" == "$expected" ]]; then pass "$description"; else fail "$description (got '$actual')"; fi
}

# Listings in the format of dracut 106 lsinitrd (cpio -tv). The bad one is
# the floe listing of run 43079965647: the lib64 symlink and libsystemd-shared
# (installed by the systemd module) are there, libc.so.6 and the loader are not.
cat >"$work/good.list" <<'EOF'
lrwxrwxrwx   1 root     root            9 Apr 11  2025 lib64 -> usr/lib64
-rwxr-xr-x   1 root     root       225672 Apr 11  2025 usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
-rw-r--r--   1 root     root          283 Apr 11  2025 usr/lib/x86_64-linux-gnu/libc.so
-rwxr-xr-x   1 root     root      1995216 Apr 11  2025 usr/lib/x86_64-linux-gnu/libc.so.6
-rw-r--r--   1 root     root      6272296 Apr 11  2025 usr/lib/x86_64-linux-gnu/systemd/libsystemd-shared-262.so
EOF
cat >"$work/bad.list" <<'EOF'
lrwxrwxrwx   1 root     root            9 Apr 11  2025 lib64 -> usr/lib64
drwxr-xr-x   2 root     root            0 Apr 11  2025 usr/lib64
-rw-r--r--   1 root     root      6272296 Apr 11  2025 usr/lib/x86_64-linux-gnu/systemd/libsystemd-shared-262.so
EOF
# A file whose name only ends in libc.so.6 must not count.
cat >"$work/decoy.list" <<'EOF'
-rw-r--r--   1 root     root          100 Apr 11  2025 usr/share/doc/notlibc.so.6
-rw-r--r--   1 root     root          100 Apr 11  2025 usr/lib/x86_64-linux-gnu/libc.so.6.bak
EOF

mkdir -p "$work/bin"
# dracut stub: record the arguments, then write the listing of this attempt
# (line N of $DRACUT_PLAN for call N) as the "image".
cat >"$work/bin/dracut" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$DRACUT_LOG"
n=$(wc -l <"$DRACUT_LOG")
kind=$(sed -n "${n}p" "$DRACUT_PLAN")
cp "$FIXTURES/$kind.list" "${!#}"
EOF
cat >"$work/bin/lsinitrd" <<'EOF'
#!/bin/bash
cat "$1"
EOF
chmod +x "$work/bin/"*

# run_case NAME PLAN...: run build_initramfs in a fresh bash with one listing
# kind per dracut call. Sets OUT, STATUS and CALLS.
run_case() {
    local name=$1
    shift
    local dir="$work/$name"
    mkdir -p "$dir"
    printf '%s\n' "$@" >"$dir/plan"
    : >"$dir/dracut.log"
    set +e
    # shellcheck disable=SC2016 # $1 and $2 expand in the inner bash.
    OUT=$(env PATH="$work/bin:$PATH" FIXTURES="$work" \
        DRACUT_PLAN="$dir/plan" DRACUT_LOG="$dir/dracut.log" \
        bash -c 'source "$1"; build_initramfs 7.2.15+deb14-amd64 "$2"' \
        _ "$HELPER" "$dir/initramfs.img" 2>&1)
    STATUS=$?
    set -e
    CALLS=$(wc -l <"$dir/dracut.log")
    ARGS=$(head -n 1 "$dir/dracut.log")
}

run_case first-try good
assert_eq "good initramfs: exit 0" 0 "$STATUS"
assert_eq "good initramfs: 1 dracut run" 1 "$CALLS"
assert_eq "dracut arguments are unchanged" \
    "--force --no-hostonly --reproducible --zstd --verbose --kver 7.2.15+deb14-amd64 $work/first-try/initramfs.img" \
    "$ARGS"

run_case retry bad good
assert_eq "missing libc then good: exit 0" 0 "$STATUS"
assert_eq "missing libc then good: 2 dracut runs" 2 "$CALLS"
if grep -q 'attempt 1/3 has no libc.so.6' <<<"$OUT"; then
    pass "missing libc: warning names the attempt"
else
    fail "missing libc: warning names the attempt ($OUT)"
fi

run_case exhausted bad bad bad bad
assert_eq "missing libc 3 times: exit 1" 1 "$STATUS"
assert_eq "missing libc 3 times: exactly 3 dracut runs" 3 "$CALLS"
if grep -q 'ERROR: .*initramfs.img has no libc.so.6 after 3 dracut runs' <<<"$OUT"; then
    pass "missing libc 3 times: error names the image"
else
    fail "missing libc 3 times: error names the image ($OUT)"
fi

run_case decoy decoy decoy decoy
assert_eq "a libc.so.6 look-alike does not count" 1 "$STATUS"

# The postinst must build the initramfs only through the helper.
# shellcheck disable=SC2016 # The patterns match a literal $ in the postinst.
if grep -Eq '^[[:space:]]*source "\$SRCDIR/shared/kernel/scripts/build-initramfs\.sh"$' "$POSTINST" &&
    grep -Eq '^[[:space:]]*build_initramfs "\$KERNEL_VERSION" ' "$POSTINST"; then
    pass "postinst calls build_initramfs"
else
    fail "postinst calls build_initramfs"
fi
if grep -Eq '^[[:space:]]*dracut([[:space:]]|$)' "$POSTINST"; then
    fail "postinst has no bare dracut call"
else
    pass "postinst has no bare dracut call"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
