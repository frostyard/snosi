#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Fixture regression test for shared/native-ab/ci/check-mkosi-pin.sh, the
# Mkosi Pin Governance guard run by build-installer-iso.yml. That script's whole
# reason to exist is its *failure* branches -- rejecting a non-full-SHA pin
# and catching a build workflow that reintroduces a second, independently
# updated `systemd/mkosi@<sha>` pin -- yet in CI it only ever runs against the
# committed tree, so exclusively its success path is exercised. This test
# drives the real script (via a symlink into a throwaway fixture repo, so
# root_dir resolves to the fixture) across every branch: happy path, matching
# duplicate pin, divergent pin, short/non-hex/absent pin, missing workflow
# files, and the check-3 mkosi HEAD comparison (present-and-equal,
# present-and-stale, absent). Check 2 covers every workflow, not only the
# installer ISO workflow (#1285): a divergent pin or a tag ref in any other
# workflow must fail. No root, no network, no mkosi build.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/shared/native-ab/ci/check-mkosi-pin.sh"

[[ -f "$SCRIPT" ]] || {
    echo "check-mkosi-pin-test: cannot find $SCRIPT" >&2
    exit 1
}

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

PIN_A="0123456789abcdef0123456789abcdef01234567"
PIN_B="fedcba9876543210fedcba9876543210fedcba98"

# Build a throwaway repo layout and symlink the real script into it so that
# its `dirname/../../..` root_dir resolves to the fixture, not this repo.
# Args: <dir> <build.yml pin line> <installer pin line>
# A pin arg of "-" means "emit no systemd/mkosi line at all".
make_fixture() {
    local dir=$1 build_pin=$2 installer_pin=$3
    mkdir -p "$dir/.github/workflows" "$dir/shared/native-ab/ci"
    ln -s "$SCRIPT" "$dir/shared/native-ab/ci/check-mkosi-pin.sh"
    emit_workflow "$dir/.github/workflows/build.yml" "$build_pin"
    emit_workflow "$dir/.github/workflows/build-installer-iso.yml" "$installer_pin"
}

emit_workflow() {
    local file=$1 pin=$2
    {
        printf 'jobs:\n  build:\n    steps:\n'
        if [[ "$pin" != "-" ]]; then
            printf '      - uses: systemd/mkosi@%s\n' "$pin"
        fi
    } >"$file"
}

# Run the fixture's script copy; capture stdout+stderr and exit status.
run_guard() {
    local dir=$1
    shift
    set +e
    OUT=$(bash "$dir/shared/native-ab/ci/check-mkosi-pin.sh" "$@" 2>&1)
    RC=$?
    set -e
}

# 1. Happy path: valid full-SHA pin, build workflows carry no pin of their own.
f="$work/happy"
make_fixture "$f" "$PIN_A" "-"
run_guard "$f"
if [[ $RC -eq 0 ]] && grep -Fq 'Mkosi pin governance check passed.' <<<"$OUT"; then
    pass 'valid full-SHA pin with no build-workflow pins passes'
else
    fail 'valid full-SHA pin with no build-workflow pins passes'
fi

# 2. Build workflows may repeat the SAME pin without tripping the guard.
f="$work/matching"
make_fixture "$f" "$PIN_A" "$PIN_A"
run_guard "$f"
if [[ $RC -eq 0 ]] && grep -Fq 'Mkosi pin governance check passed.' <<<"$OUT"; then
    pass 'build workflows repeating the identical pin pass'
else
    fail 'build workflows repeating the identical pin pass'
fi

# 3. A divergent installer-iso workflow pin must fail.
f="$work/divergent-installer"
make_fixture "$f" "$PIN_A" "$PIN_B"
run_guard "$f"
if [[ $RC -ne 0 ]] && grep -Fq 'does not match' <<<"$OUT"; then
    pass 'divergent pin in build-installer-iso.yml is rejected'
else
    fail 'divergent pin in build-installer-iso.yml is rejected'
fi

# 4. A short (non-40-char) SHA is not an acceptable pin.
f="$work/short"
make_fixture "$f" "0123abc" "-"
run_guard "$f"
if [[ $RC -ne 0 ]] && grep -Fq 'not a full 40-character commit SHA' <<<"$OUT"; then
    pass 'short SHA pin is rejected'
else
    fail 'short SHA pin is rejected'
fi

# 5. A non-hex ref (tag/branch) yields no extractable pin at all.
f="$work/tag"
make_fixture "$f" "v25" "-"
run_guard "$f"
if [[ $RC -ne 0 ]] && grep -Fq 'could not find' <<<"$OUT"; then
    pass 'non-hex tag ref is reported as an unfindable pin'
else
    fail 'non-hex tag ref is reported as an unfindable pin'
fi

# 6. Missing build.yml fails closed.
f="$work/missing-build"
make_fixture "$f" "$PIN_A" "-"
rm -f "$f/.github/workflows/build.yml"
run_guard "$f"
if [[ $RC -ne 0 ]] && grep -Fq 'missing' <<<"$OUT"; then
    pass 'missing build.yml fails closed'
else
    fail 'missing build.yml fails closed'
fi

# 6b. Missing a build workflow file fails closed too.
f="$work/missing-installer"
make_fixture "$f" "$PIN_A" "-"
rm -f "$f/.github/workflows/build-installer-iso.yml"
run_guard "$f"
if [[ $RC -ne 0 ]] && grep -Fq 'missing' <<<"$OUT"; then
    pass 'missing build-installer-iso.yml fails closed'
else
    fail 'missing build-installer-iso.yml fails closed'
fi

# 7. Check 3 skips cleanly when the mkosi checkout is absent.
f="$work/no-checkout"
make_fixture "$f" "$PIN_A" "-"
run_guard "$f" "$f/.mkosi"
if [[ $RC -eq 0 ]] && grep -Fq 'not present yet' <<<"$OUT"; then
    pass 'absent mkosi checkout skips the HEAD comparison'
else
    fail 'absent mkosi checkout skips the HEAD comparison'
fi

# 7b. Check 3 passes when the checkout HEAD equals the pin.
f="$work/head-match"
checkout="$f/.mkosi"
mkdir -p "$checkout"
git init -q "$checkout"
git -C "$checkout" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m seed
head=$(git -C "$checkout" rev-parse HEAD)
make_fixture "$f" "$head" "-"
run_guard "$f" "$checkout"
if [[ $RC -eq 0 ]] && grep -Fq 'matches build.yml' <<<"$OUT"; then
    pass 'checkout HEAD equal to the pin passes check 3'
else
    fail 'checkout HEAD equal to the pin passes check 3'
fi

# 7c. Check 3 fails when the checkout HEAD is stale (!= pin).
f="$work/head-stale"
checkout="$f/.mkosi"
mkdir -p "$checkout"
git init -q "$checkout"
git -C "$checkout" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m seed
make_fixture "$f" "$PIN_A" "-"
run_guard "$f" "$checkout"
if [[ $RC -ne 0 ]] && grep -Fq 'expected' <<<"$OUT"; then
    pass 'stale checkout HEAD fails check 3'
else
    fail 'stale checkout HEAD fails check 3'
fi

# 8. --help/usage exits 2 without doing any work.
f="$work/usage"
make_fixture "$f" "$PIN_A" "-"
run_guard "$f" --help
if [[ $RC -eq 2 ]] && grep -Fq 'Usage:' <<<"$OUT"; then
    pass '--help prints usage and exits 2'
else
    fail '--help prints usage and exits 2'
fi

# 8b. More than one positional argument is a usage error.
f="$work/too-many-args"
make_fixture "$f" "$PIN_A" "-"
run_guard "$f" a b
if [[ $RC -eq 2 ]] && grep -Fq 'Usage:' <<<"$OUT"; then
    pass 'a second positional argument is a usage error'
else
    fail 'a second positional argument is a usage error'
fi

# 9. A divergent pin in a workflow other than build-installer-iso.yml must
# fail (#1285: check 2 only read the installer ISO workflow).
f="$work/divergent-images"
make_fixture "$f" "$PIN_A" "$PIN_A"
emit_workflow "$f/.github/workflows/build-images.yml" "$PIN_B"
run_guard "$f"
if [[ $RC -ne 0 ]] && grep -Fq 'build-images.yml pins systemd/mkosi@'"$PIN_B" <<<"$OUT"; then
    pass 'divergent pin in build-images.yml is rejected'
else
    fail 'divergent pin in build-images.yml is rejected'
fi

# 9b. A second, divergent pin in build.yml itself must fail (the pin is read
# from its first match only).
f="$work/divergent-build-second"
make_fixture "$f" "$PIN_A" "-"
printf '      - uses: systemd/mkosi@%s\n' "$PIN_B" >>"$f/.github/workflows/build.yml"
run_guard "$f"
if [[ $RC -ne 0 ]] && grep -Fq 'build.yml pins systemd/mkosi@'"$PIN_B" <<<"$OUT"; then
    pass 'second divergent pin in build.yml is rejected'
else
    fail 'second divergent pin in build.yml is rejected'
fi

# 9c. A tag or branch ref in another workflow is a divergence too.
f="$work/tag-validate"
make_fixture "$f" "$PIN_A" "-"
emit_workflow "$f/.github/workflows/validate.yml" "v25"
run_guard "$f"
if [[ $RC -ne 0 ]] && grep -Fq 'validate.yml pins systemd/mkosi@v25' <<<"$OUT"; then
    pass 'tag ref in validate.yml is rejected'
else
    fail 'tag ref in validate.yml is rejected'
fi

# 9d. A .yaml workflow is checked as well.
f="$work/divergent-yaml"
make_fixture "$f" "$PIN_A" "-"
emit_workflow "$f/.github/workflows/build-mechanics.yaml" "$PIN_B"
run_guard "$f"
if [[ $RC -ne 0 ]] && grep -Fq 'build-mechanics.yaml pins' <<<"$OUT"; then
    pass 'divergent pin in a .yaml workflow is rejected'
else
    fail 'divergent pin in a .yaml workflow is rejected'
fi

# 9e. Matching pins in several workflows pass, and the guard reports how many
# workflows it checked (build.yml, the installer ISO workflow and 2 others;
# a workflow with no mkosi pin is not counted).
f="$work/matching-many"
make_fixture "$f" "$PIN_A" "$PIN_A"
emit_workflow "$f/.github/workflows/build-images.yml" "$PIN_A"
emit_workflow "$f/.github/workflows/validate.yml" "$PIN_A"
emit_workflow "$f/.github/workflows/ci.yml" "-"
run_guard "$f"
if [[ $RC -eq 0 ]] && grep -Fq 'ok - 4 workflow(s) that name systemd/mkosi@' <<<"$OUT"; then
    pass 'matching pins in 4 workflows pass and the count is reported'
else
    fail 'matching pins in 4 workflows pass and the count is reported'
fi

# 9f. Quoted refs compare by the ref alone: a matching single- or
# double-quoted pin passes.
f="$work/quoted-matching"
make_fixture "$f" "$PIN_A" "-"
printf "      - uses: 'systemd/mkosi@%s'\n" "$PIN_A" >"$f/.github/workflows/build-images.yml"
printf '      - uses: "systemd/mkosi@%s" # main\n' "$PIN_A" >"$f/.github/workflows/validate.yml"
run_guard "$f"
if [[ $RC -eq 0 ]] && grep -Fq 'ok - 3 workflow(s) that name systemd/mkosi@' <<<"$OUT"; then
    pass 'matching single- and double-quoted pins pass'
else
    fail 'matching single- and double-quoted pins pass'
fi

# 9g. A divergent single-quoted ref is still rejected.
f="$work/quoted-divergent"
make_fixture "$f" "$PIN_A" "-"
printf "      - uses: 'systemd/mkosi@%s'\n" "$PIN_B" >"$f/.github/workflows/build-images.yml"
run_guard "$f"
if [[ $RC -ne 0 ]] && grep -Fq "build-images.yml pins systemd/mkosi@$PIN_B," <<<"$OUT"; then
    pass 'divergent single-quoted pin is rejected'
else
    fail 'divergent single-quoted pin is rejected'
fi

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
