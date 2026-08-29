#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Fixture regression test for compare-images.sh, the repo's Docker/OCI image
# reproducibility comparison tool (referenced from docs/design/overview.md and
# docs/fable-audit.md). The script had zero references anywhere under test/ and
# is not invoked by any workflow under .github/workflows/ or by test/e2e/, so
# neither its argument-validation branches nor its dependency preflight were
# exercised by any suite -- every early-exit failure path was unverified.
#
# This test drives the REAL script across every branch that runs before any
# image extraction, so it needs no skopeo/diffoscope/docker, no network, and
# no root:
#   - usage on -h/--help (exit 0) and on error (exit 1)
#   - "Two image references are required" when fewer than two positionals given
#   - "Unknown option" for an unrecognized flag
#   - "Too many arguments" for a third positional
#   - the "<flag> requires a <kind> argument" guard for every value-taking flag
#   - check_dependencies() reporting missing required commands
#
# The dependency-preflight branch is made deterministic by running the script
# with a minimal PATH (only basename, needed at load time) so command -v finds
# none of skopeo/jq/tar/file/diffoscope regardless of what the host happens to
# have installed. Positional args use the oci: reference form so parse_args
# accepts them without touching the registry.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/compare-images.sh"

[[ -f "$SCRIPT" ]] || {
    echo "compare-images-test: cannot find $SCRIPT" >&2
    exit 1
}

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# Run the real script, capturing stdout+stderr and exit status. A leading
# PATH= assignment (env-style "NAME=VALUE" before the command) is applied to
# just this invocation so the dependency-preflight branch can be forced.
run() {
    set +e
    OUT=$(bash "$SCRIPT" "$@" 2>&1)
    RC=$?
    set -e
}

# Absolute bash path, resolved while PATH is still intact, so the reduced-PATH
# invocation below can still locate the interpreter itself.
BASH_BIN="$(command -v bash)"

# A minimal PATH containing only basename (which the script calls at load time
# to derive SCRIPT_NAME) but none of skopeo/jq/tar/file/diffoscope, so the
# dependency preflight reports them missing regardless of the host's tooling.
STUB_BIN="$(mktemp -d)"
trap 'rm -rf "$STUB_BIN"' EXIT
ln -s "$(command -v basename)" "$STUB_BIN/basename"

run_no_path() {
    set +e
    OUT=$(PATH="$STUB_BIN" "$BASH_BIN" "$SCRIPT" "$@" 2>&1)
    RC=$?
    set -e
}

expect() {
    local desc=$1 want_rc=$2 needle=$3
    if [[ "$RC" -eq "$want_rc" ]] && grep -Fq -- "$needle" <<<"$OUT"; then
        pass "$desc"
    else
        fail "$desc (rc=$RC want=$want_rc; output did not contain: $needle)"
    fi
}

# 1. --help / -h print usage and exit 0 without doing any work.
run --help
expect '--help prints usage and exits 0' 0 'Usage:'
run -h
expect '-h prints usage and exits 0' 0 'Usage:'

# 2. Fewer than two image references is an error.
run
expect 'no arguments is rejected' 1 'Two image references are required'
run oci:only-one
expect 'a single image reference is rejected' 1 'Two image references are required'

# 3. An unrecognized flag is rejected before anything else.
run --not-a-flag
expect 'unknown option is rejected' 1 'Unknown option: --not-a-flag'

# 4. A third positional argument is too many.
run oci:a oci:b oci:c
expect 'a third positional argument is rejected' 1 'Too many arguments'

# 5. Every value-taking flag fails closed when its value is omitted.
run --tmpdir
expect '--tmpdir without a value is rejected' 1 '--tmpdir requires a directory argument'
run --output
expect '--output without a value is rejected' 1 '--output requires a file argument'
run --format
expect '--format without a value is rejected' 1 '--format requires a format argument'
run --exclude
expect '--exclude without a value is rejected' 1 '--exclude requires a pattern argument'
run --max-diff-size
expect '--max-diff-size without a value is rejected' 1 '--max-diff-size requires a size argument'
run --max-report-size
expect '--max-report-size without a value is rejected' 1 '--max-report-size requires a size argument'

# 6. With valid positionals but the required tools absent from PATH, the
#    dependency preflight reports the missing commands and fails closed
#    (before any extraction).
run_no_path oci:a oci:b
expect 'missing required commands are reported' 1 'Missing required commands'

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
