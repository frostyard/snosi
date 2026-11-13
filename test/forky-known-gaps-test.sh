#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture test for shared/suite/forky/classify-build.sh (ADR-0037).
#
# The forky mechanics workflow passes only when a failed build stops at a known
# gap, and fails when a passing build still lists one. A classifier that cannot
# say "no" is not a gate, so every branch is exercised here with a fixture log.
#
# No root, no network, no build.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
classify=$root/shared/suite/forky/classify-build.sh

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

gaps=$tmp/known-gaps.tsv
cat >"$gaps" <<'TSV'
# a comment line
G1	Unable to locate package bootc	https://example.invalid/1
G1b	Unable to locate package libgpgme11t64	https://example.invalid/1
G1c	for 'libostree-1-1' was not found	https://example.invalid/1
TSV

empty_gaps=$tmp/empty-gaps.tsv
printf '# no gaps are known\n' >"$empty_gaps"

broken_gaps=$tmp/broken-gaps.tsv
printf 'G9\n' >"$broken_gaps"

expect() { # description pass|reject outcome log gaps [text the output must name]
    local description=$1 want=$2 outcome=$3 log=$4 gapfile=$5 named=${6:-}
    local status=0 out
    out=$("$classify" --outcome "$outcome" --log "$log" --known-gaps "$gapfile" 2>&1) || status=$?
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

# The gap file is read, not the log: each row explains its own line.
printf 'E: %s\n' "Unable to locate package bootc" >"$tmp/gap-g1.log"
expect "gap G1 explains its own failure" pass failure "$tmp/gap-g1.log" "$gaps" G1
printf 'E: %s\n' "Unable to locate package libgpgme11t64" >"$tmp/gap-g1b.log"
expect "gap G1b explains its own failure" pass failure "$tmp/gap-g1b.log" "$gaps" G1b
printf "E: %s\n" "Version '2026.6-frostyard202611042030~deb13' for 'libostree-1-1' was not found" >"$tmp/gap-g1c.log"
expect "gap G1c explains its own failure" pass failure "$tmp/gap-g1c.log" "$gaps" G1c

# All three at once, as apt reports them in one install (run 43487370180).
printf 'E: %s\n' "Unable to locate package bootc" "Unable to locate package libgpgme11t64" \
    "Version '2026.6-frostyard202611042030~deb13' for 'libostree-1-1' was not found" >"$tmp/gap-all.log"
expect "every apt error of one install is a known gap" pass failure "$tmp/gap-all.log" "$gaps" G1c

# One known gap must not hide a new one: every apt error needs a row.
printf 'E: %s\n' "Unable to locate package libgpgme11t64" "Unable to locate package something-new" >"$tmp/mixed.log"
expect "a known gap beside an unknown apt error fails" reject failure "$tmp/mixed.log" "$gaps" "something-new"

# A failure with no apt error line (a script, a finalize guard) is never a gap.
printf 'something failed in a finalize script\n' >"$tmp/no-apt.log"
expect "a failure without an apt error fails" reject failure "$tmp/no-apt.log" "$gaps" "without an apt error line"

# A failure no row explains fails the workflow.
printf 'E: something nobody wrote down\n' >"$tmp/unknown.log"
expect "an unexplained failure fails" reject failure "$tmp/unknown.log" "$gaps" "no known gap explains"

# No known gap at all, and a failure: fail.
expect "a failure with no known gap fails" reject failure "$tmp/unknown.log" "$empty_gaps" "lists no known gap"

# A missing build log fails closed.
expect "a missing build log fails" reject failure "$tmp/absent.log" "$gaps" "does not exist"

# A malformed row fails closed rather than being skipped, on a failed and on a
# passing build alike: the file is validated before any classification.
expect "a malformed gap row fails" reject failure "$tmp/unknown.log" "$broken_gaps" "exactly 3 tab-separated fields"
expect "a malformed gap row fails a passing build" reject success "$tmp/unused.log" "$broken_gaps" "exactly 3 tab-separated fields"

printf 'G2\tUnable to locate package bootc\n' >"$tmp/no-url.tsv"
expect "a row without a tracking URL fails" reject failure "$tmp/gap-g1.log" "$tmp/no-url.tsv" "exactly 3 tab-separated fields"

# Two tabs with nothing between them: a tab IFS would merge the empty field
# and read the URL as the fixed string.
printf 'G2\t\thttps://example.invalid/2\n' >"$tmp/empty-needle.tsv"
expect "a row with an empty fixed string fails" reject failure "$tmp/unknown.log" "$tmp/empty-needle.tsv" "has no fixed string"

printf 'G2\t \thttps://example.invalid/2\n' >"$tmp/blank-needle.tsv"
expect "a row with a blank fixed string fails" reject failure "$tmp/unknown.log" "$tmp/blank-needle.tsv" "has no fixed string"

printf 'G2\tUnable to locate package bootc\tnot-a-url\n' >"$tmp/bad-url.tsv"
expect "a row whose tracking URL is not https fails" reject failure "$tmp/gap-g1.log" "$tmp/bad-url.tsv" "no https tracking URL"

printf 'G2\tUnable to locate package bootc\thttps://example.invalid/2\textra\n' >"$tmp/four-fields.tsv"
expect "a row with a 4th field fails" reject failure "$tmp/gap-g1.log" "$tmp/four-fields.tsv" "exactly 3 tab-separated fields"

# A last row with no newline is still a row: it explains its gap, and a
# passing build fails while it is listed.
printf '# comment\nG2\tUnable to locate package bootc\thttps://example.invalid/2' >"$tmp/no-newline.tsv"
expect "a last row without a newline explains its gap" pass failure "$tmp/gap-g1.log" "$tmp/no-newline.tsv" G2
expect "a last row without a newline is a stale gap on a clean build" reject success "$tmp/unused.log" "$tmp/no-newline.tsv" "remove them"

# A clean build with a gap still listed fails: the row is stale.
expect "a clean build with a stale gap fails" reject success "$tmp/unused.log" "$gaps" "remove them"

# A clean build with no gap passes.
expect "a clean build with no known gap passes" pass success "$tmp/unused.log" "$empty_gaps"

# The checked-in file is what the workflow reads: it must parse and explain the
# apt errors of the last forky build (run 43505892957: the forky bootc pair is
# published, and the trixie pin of shared/packages/bootc does not match it).
checked_in=$root/shared/suite/forky/known-gaps.tsv
if [[ ! -f $checked_in ]]; then
    fail "$checked_in is missing"
else
    printf 'E: %s\n' \
        "Version '1.17.3-frostyard202611042030~deb13' for 'bootc' was not found" \
        "Unable to locate package libgpgme11t64" \
        "Version '2026.6-frostyard202611042030~deb13' for 'libostree-1-1' was not found" \
        >"$tmp/shipped.log"
    if out=$("$classify" --outcome failure --log "$tmp/shipped.log" --known-gaps "$checked_in" 2>&1); then
        if [[ $out == *"gap \`G1\`"* && $out == *"gap \`G1b\`"* && $out == *"gap \`G1c\`"* ]]; then
            pass "the checked-in known-gaps.tsv explains the bootc pin gaps as G1, G1b and G1c"
        else
            fail "the checked-in known-gaps.tsv did not report G1, G1b and G1c: $out"
        fi
    else
        fail "the checked-in known-gaps.tsv does not explain the bootc pin gaps: $out"
    fi
fi

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
