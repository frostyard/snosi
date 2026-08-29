#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Fixture regression test for shared/native-ab/ci/bootstrap-mkosi.sh, the ONE
# implementation of "how mkosi gets bootstrapped from the build.yml pin"
# (used by Justfile's `ensure-mkosi` recipe and build-native-images.yml's
# build-* jobs). Its companion guard shared/native-ab/ci/check-mkosi-pin.sh
# has a dedicated fixture test (test/check-mkosi-pin-test.sh); this script had
# none, and CI only ever runs it operationally against the network, so its
# input-validation and idempotency branches were unverified.
#
# This drives the real script via a symlink into a throwaway fixture repo, so
# its `dirname/../../..` root_dir resolves to the fixture (not this repo),
# exactly like check-mkosi-pin-test.sh. It covers every branch that does not
# require network: -h/--help, wrong argument count, missing build.yml, an
# unfindable (non-full-SHA / tag / absent) pin, and the idempotent no-op fast
# path (target already checked out at the pinned commit -> exit 0, no fetch).
#
# The remote fetch/checkout leg and the post-checkout verification branches
# (checked-out SHA mismatch, bin/mkosi not executable) are intentionally NOT
# exercised here because they clone github.com/systemd/mkosi -- the same
# reason test/check-mkosi-pin-test.sh does not run a real mkosi build. Those
# legs are covered operationally by the build-native-images.yml jobs.
#
# No root, no network, no mkosi build. Usage: ./test/bootstrap-mkosi-test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/shared/native-ab/ci/bootstrap-mkosi.sh"

[[ -f "$SCRIPT" ]] || {
    echo "bootstrap-mkosi-test: cannot find $SCRIPT" >&2
    exit 1
}

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; [[ $# -lt 2 ]] || printf '  %s\n' "$2" >&2; FAIL=$((FAIL + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

PIN_A="0123456789abcdef0123456789abcdef01234567"

# Build a throwaway repo layout and symlink the real script into it so that
# its `dirname/../../..` root_dir resolves to the fixture. A build.yml pin arg
# of "-" means "emit a build.yml with no systemd/mkosi line at all".
# Args: <dir> <build.yml pin>
make_fixture() {
    local dir=$1 build_pin=$2
    mkdir -p "$dir/.github/workflows" "$dir/shared/native-ab/ci"
    ln -s "$SCRIPT" "$dir/shared/native-ab/ci/bootstrap-mkosi.sh"
    {
        printf 'jobs:\n  build:\n    steps:\n'
        if [[ "$build_pin" != "-" ]]; then
            printf '      - uses: systemd/mkosi@%s\n' "$build_pin"
        fi
    } >"$dir/.github/workflows/build.yml"
}

# Run the fixture's script copy; capture stdout+stderr and exit status.
run_bootstrap() {
    local dir=$1
    shift
    set +e
    OUT=$(bash "$dir/shared/native-ab/ci/bootstrap-mkosi.sh" "$@" 2>&1)
    RC=$?
    set -e
}

# 1. --help prints usage and exits 2 without touching build.yml.
f="$work/help"
make_fixture "$f" "$PIN_A"
run_bootstrap "$f" --help
if [[ $RC -eq 2 ]] && grep -Fq 'Usage:' <<<"$OUT"; then
    pass '--help prints usage and exits 2'
else
    fail '--help prints usage and exits 2' "rc=$RC out=$OUT"
fi

# 1b. -h behaves identically to --help.
f="$work/h"
make_fixture "$f" "$PIN_A"
run_bootstrap "$f" -h
if [[ $RC -eq 2 ]] && grep -Fq 'Usage:' <<<"$OUT"; then
    pass '-h prints usage and exits 2'
else
    fail '-h prints usage and exits 2' "rc=$RC out=$OUT"
fi

# 2. No positional argument is a usage error.
f="$work/noargs"
make_fixture "$f" "$PIN_A"
run_bootstrap "$f"
if [[ $RC -eq 2 ]] && grep -Fq 'Usage:' <<<"$OUT"; then
    pass 'no target-dir argument is a usage error'
else
    fail 'no target-dir argument is a usage error' "rc=$RC out=$OUT"
fi

# 2b. A second positional argument is a usage error.
f="$work/twoargs"
make_fixture "$f" "$PIN_A"
run_bootstrap "$f" a b
if [[ $RC -eq 2 ]] && grep -Fq 'Usage:' <<<"$OUT"; then
    pass 'a second positional argument is a usage error'
else
    fail 'a second positional argument is a usage error' "rc=$RC out=$OUT"
fi

# 3. Missing build.yml fails closed (exit 1) before any network work.
f="$work/missing-build"
make_fixture "$f" "$PIN_A"
rm -f "$f/.github/workflows/build.yml"
run_bootstrap "$f" "$f/.mkosi"
if [[ $RC -eq 1 ]] && grep -Fq 'missing' <<<"$OUT"; then
    pass 'missing build.yml fails closed'
else
    fail 'missing build.yml fails closed' "rc=$RC out=$OUT"
fi

# 4. A build.yml with no systemd/mkosi pin line -> unfindable pin, exit 1.
f="$work/no-pin"
make_fixture "$f" "-"
run_bootstrap "$f" "$f/.mkosi"
if [[ $RC -eq 1 ]] && grep -Fq 'could not find' <<<"$OUT"; then
    pass 'build.yml with no systemd/mkosi line reports an unfindable pin'
else
    fail 'build.yml with no systemd/mkosi line reports an unfindable pin' "rc=$RC out=$OUT"
fi

# 4b. A non-hex ref (tag/branch) is not a SHA -> unfindable pin, exit 1.
# `systemd/mkosi@v25` yields no [0-9a-f]+ pin, so the fast path never fires and
# the fetch leg is never reached.
f="$work/tag"
make_fixture "$f" "v25"
run_bootstrap "$f" "$f/.mkosi"
if [[ $RC -eq 1 ]] && grep -Fq 'could not find' <<<"$OUT"; then
    pass 'non-hex tag ref is reported as an unfindable pin'
else
    fail 'non-hex tag ref is reported as an unfindable pin' "rc=$RC out=$OUT"
fi

# 5. Idempotent no-op fast path: target is already a git checkout whose HEAD
# equals the build.yml pin and which has an executable bin/mkosi -> exit 0
# with no fetch. We build such a checkout, read its real HEAD, and pin
# build.yml to exactly that SHA so the equality branch fires deterministically
# and offline.
f="$work/idempotent"
target="$f/.mkosi"
mkdir -p "$target/bin"
printf '#!/bin/sh\n' >"$target/bin/mkosi"
chmod +x "$target/bin/mkosi"
git init -q "$target"
git -C "$target" -c user.email=t@example.com -c user.name=t add -A
git -C "$target" -c user.email=t@example.com -c user.name=t commit -q -m seed
head=$(git -C "$target" rev-parse HEAD)
make_fixture "$f" "$head"
run_bootstrap "$f" "$target"
if [[ $RC -eq 0 ]] && grep -Fq 'already bootstrapped' <<<"$OUT"; then
    pass 'target already at the pinned commit is a no-op (exit 0, no fetch)'
else
    fail 'target already at the pinned commit is a no-op (exit 0, no fetch)' "rc=$RC out=$OUT"
fi

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
