#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$root/check-duplicate-packages.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

test_number=0
failures=0

run_case() {
    local name=$1 expected_status=$2 expected_output=${3:-}
    local fixture="$work/case-$((test_number + 1))" output status

    mkdir -p "$fixture"
    CASE_ROOT=$fixture
    "$CASE_SETUP"
    git -C "$fixture" init -q
    git -C "$fixture" add .

    if output=$(SNOSI_DUPLICATE_PACKAGES_GUARD_ROOT="$fixture" "$guard" 2>&1); then
        status=0
    else
        status=$?
    fi

    test_number=$((test_number + 1))
    if [[ $status -eq $expected_status &&
        ( -z $expected_output || $output == *"$expected_output"* ) ]]; then
        printf 'ok %d - %s\n' "$test_number" "$name"
    else
        printf 'not ok %d - %s\n' "$test_number" "$name"
        printf '# expected status %d, got %d\n' "$expected_status" "$status"
        printf '# output: %s\n' "$output"
        failures=$((failures + 1))
    fi
}

write_conf() {
    local path=$1
    mkdir -p "$(dirname "$CASE_ROOT/$path")"
    cat >"$CASE_ROOT/$path"
}

setup_empty() { :; }
setup_single() { printf '[Content]\nPackages=alpha\n' | write_conf mkosi.profiles/test/mkosi.conf; }
setup_unique_multiline() {
    printf '[Content]\nPackages=alpha\n         beta\n' | write_conf mkosi.profiles/test/mkosi.conf
}
setup_duplicate_first_line() {
    printf '[Content]\nPackages=alpha\n         alpha\n' | write_conf mkosi.profiles/test/mkosi.conf
}
setup_duplicate_continuation() {
    printf '[Content]\nPackages=\n alpha\n beta\n alpha\n' | write_conf mkosi.images/test/mkosi.conf
}
setup_inline_comment_duplicate() {
    printf '[Content]\nPackages=alpha\n alpha # repeated\n' | write_conf shared/test/mkosi.conf
}
setup_comment_lines() {
    printf '[Content]\n# Packages=alpha\nPackages=alpha\n # alpha\n beta\n' |
        write_conf mkosi.profiles/test/mkosi.conf
}
setup_blank_line() {
    printf '[Content]\nPackages=alpha\n\n alpha\n' | write_conf mkosi.profiles/test/mkosi.conf
}
setup_section_boundary() {
    printf '[Content]\nPackages=alpha\n[Output]\n alpha\n' | write_conf mkosi.profiles/test/mkosi.conf
}
setup_multiple_blocks() {
    printf '[Content]\nPackages=alpha\nPackages=alpha\n' | write_conf mkosi.profiles/test/mkosi.conf
}
setup_tab_indentation() {
    printf '[Content]\nPackages=alpha\n\talpha\n' | write_conf mkosi.profiles/test/mkosi.conf
}
setup_saved_unused() {
    printf '[Content]\nPackages=alpha\n alpha\n' | write_conf saved-unused/test/mkosi.conf
}

printf '1..12\n'
CASE_SETUP=setup_empty run_case "empty repository passes" 0
CASE_SETUP=setup_single run_case "single package passes" 0
CASE_SETUP=setup_unique_multiline run_case "unique multiline packages pass" 0
CASE_SETUP=setup_duplicate_first_line run_case "duplicate first-line package is rejected" 1 "alpha: lines 2, 3"
CASE_SETUP=setup_duplicate_continuation run_case "duplicate continuation package is rejected" 1 "alpha: lines 3, 5"
CASE_SETUP=setup_inline_comment_duplicate run_case "inline comments do not hide duplicates" 1 "alpha: lines 2, 3"
CASE_SETUP=setup_comment_lines run_case "comment lines are ignored" 0
CASE_SETUP=setup_blank_line run_case "blank lines preserve a package list" 1 "alpha: lines 2, 4"
CASE_SETUP=setup_section_boundary run_case "a new section ends a package list" 0
CASE_SETUP=setup_multiple_blocks run_case "duplicates across package blocks are rejected" 1 "alpha: lines 2, 3"
CASE_SETUP=setup_tab_indentation run_case "tab-indented duplicates are rejected" 1 "alpha: lines 2, 3"
CASE_SETUP=setup_saved_unused run_case "saved-unused configurations are excluded" 0

exit "$failures"
