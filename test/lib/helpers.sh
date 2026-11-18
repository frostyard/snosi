#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared test helpers for the snosi test suite.
# Source this from each test script to get the check() function,
# PASS/FAIL counters, and summary/exit logic.

PASS=0
FAIL=0

# check - Run a test and record the result.
# Usage: check "description" command [args...]
check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok - $desc"
        (( PASS++ )) || true
    else
        echo "not ok - $desc"
        (( FAIL++ )) || true
    fi
}

# expect_code <expected-exit> <cmd...> — succeeds iff cmd exits with the code.
expect_code() {
    local want="$1"; shift
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    [[ "$got" == "$want" ]]
}

# print_summary - Print results and exit with failure count.
# Call this at the end of each test script.
print_summary() {
    echo ""
    echo "# Results: $PASS passed, $FAIL failed, $(( PASS + FAIL )) total"
    exit "$FAIL"
}
