#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture test for the suite map of shared/composition/var-audit.finalize
# (ADR-0037): a /var path that only one Debian suite ships goes in
# var-outcomes.<release>.txt beside the product map, and the audit reads that
# file only for its own $RELEASE. A trixie-only entry must not hide a forky
# path, and a suite map entry that matches nothing is stale like any other.
# No root, no image build: BUILDROOT and SRCDIR are temporary trees.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
audit="$root/shared/composition/var-audit.finalize"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

src=$tmp/src
mkdir -p "$src/shared/composition/floe"
printf 'lib/dpkg/**\timage-metadata\nlog/journal\ttmpfiles\n' \
    >"$src/shared/composition/floe/var-outcomes.txt"
printf '# trixie only\nlib/python/python3.13_installed\tdiscard\nlog/wtmp\tdiscard\n' \
    >"$src/shared/composition/floe/var-outcomes.trixie.txt"
printf 'lib/python/python3.14_installed\tdiscard\n' \
    >"$src/shared/composition/floe/var-outcomes.forky.txt"

make_root() { # name path...
    local dir=$tmp/$1 path
    shift
    rm -rf "$dir"
    mkdir -p "$dir/var/log/journal" "$dir/var/lib/dpkg"
    touch "$dir/var/lib/dpkg/status"
    for path in "$@"; do
        mkdir -p "$dir/var/$(dirname "$path")"
        touch "$dir/var/$path"
    done
    printf '%s\n' "$dir"
}

expect() { # description pass|reject release buildroot [text the output must name]
    local description=$1 want=$2 release=$3 buildroot=$4 named=${5:-}
    local status=0 out
    out=$(env -i PATH="$PATH" BUILDROOT="$buildroot" SRCDIR="$src" IMAGE_ID=floe \
        ${release:+RELEASE="$release"} bash "$audit" 2>&1) || status=$?
    if [[ $want == pass && $status -eq 0 ]]; then
        pass "$description"
    elif [[ $want == pass ]]; then
        fail "$description (expected a pass, got exit $status: $out)"
    elif [[ $status -eq 0 ]]; then
        fail "$description (expected a failure, got a pass: $out)"
    elif [[ -z $named || $out == *"$named"* ]]; then
        pass "$description"
    else
        fail "$description (the failure does not name '$named': $out)"
    fi
}

trixie_root=$(make_root trixie lib/python/python3.13_installed log/wtmp)
forky_root=$(make_root forky lib/python/python3.14_installed)

expect "a trixie /var passes with the product and trixie maps" pass trixie "$trixie_root"
if grep -qx $'discard\t/var/log/wtmp' "$trixie_root/usr/share/snosi/var-inventory.txt"; then
    pass "the inventory classifies a trixie-map path by its suite outcome"
else
    fail "the inventory classifies a trixie-map path by its suite outcome"
fi
expect "a forky /var passes with the product and forky maps" pass forky "$forky_root"

# The forky build must not read the trixie map: its entries would be stale,
# and a trixie entry must never classify a forky path.
expect "a trixie-only path in a forky /var is unclassified" reject forky \
    "$(make_root forky-wtmp lib/python/python3.14_installed log/wtmp)" "/var/log/wtmp"
expect "the trixie map does not apply to a forky build" reject forky \
    "$(make_root forky-py13 lib/python/python3.13_installed)" "python3.13_installed"

# A suite map entry that matches nothing is stale.
expect "a stale suite-map entry fails" reject forky "$(make_root forky-empty)" \
    "lib/python/python3.14_installed"
expect "a stale trixie-map entry fails a trixie build" reject trixie \
    "$(make_root trixie-no-wtmp lib/python/python3.13_installed)" "log/wtmp"

# A release without a suite map uses the product map alone.
expect "a release with no suite map uses the product map" pass sid "$(make_root sid)"

# The audit needs RELEASE, as mkosi sets it for every finalize script.
expect "an unset RELEASE fails" reject "" "$trixie_root" "RELEASE not set"

# A malformed or empty suite map fails closed, naming its own file.
cp "$src/shared/composition/floe/var-outcomes.forky.txt" "$tmp/forky.bak"
printf 'lib/python/python3.14_installed discard\n' >"$src/shared/composition/floe/var-outcomes.forky.txt"
expect "a suite-map row without a tab fails" reject forky "$forky_root" "var-outcomes.forky.txt:1"
printf '# only a comment\n' >"$src/shared/composition/floe/var-outcomes.forky.txt"
expect "an empty suite map fails" reject forky "$forky_root" "var-outcomes.forky.txt has no entries"
cp "$tmp/forky.bak" "$src/shared/composition/floe/var-outcomes.forky.txt"

# Every suite map in the repository names a release that the product supports.
shopt -s nullglob
for suite_map in "$root"/shared/composition/*/var-outcomes.*.txt; do
    release=${suite_map##*/var-outcomes.}
    release=${release%.txt}
    if [[ $release == trixie || $release == forky ]]; then
        pass "suite map ${suite_map#"$root"/} names a known release"
    else
        fail "suite map ${suite_map#"$root"/} names unknown release '$release'"
    fi
done

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
