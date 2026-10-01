#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture checks for the installed-image frostyard-nbc gate.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

expect() {
    local case_name=$1 expected=$2 file=$3 rc=0
    "$root/test/check-no-nbc-package.sh" "$file" 2> "$tmp/stderr" || rc=$?
    if [[ $rc -ne $expected ]]; then
        echo "FAIL: $case_name (expected $expected, got $rc)" >&2
        exit 1
    fi
    if [[ $expected -eq 1 ]] && ! grep -Fq 'frostyard-nbc is installed (Status: ' "$tmp/stderr"; then
        echo "FAIL: $case_name (missing rejection message)" >&2
        exit 1
    fi
}

printf 'Package: bash\nStatus: install ok installed\n\nPackage: frostyard-nbc-tools\nStatus: install ok installed\n' > "$tmp/clean"
printf 'Package: frostyard-nbc\nStatus: install ok installed\n' > "$tmp/installed"
printf 'Package: frostyard-nbc\nStatus: install ok unpacked\n' > "$tmp/unpacked"
printf 'Package: frostyard-nbc\nStatus: deinstall ok config-files\n' > "$tmp/config-files"
printf 'Package: frostyard-nbc\r\nStatus: install ok installed\r\n' > "$tmp/crlf"
printf 'Package: bash\r\nStatus: install ok installed\r\n\r\nPackage: frostyard-nbc\r\nStatus: install ok installed\r\n' > "$tmp/crlf-multiple"
printf 'Package: frostyard-nbc\r\nStatus: install ok installed\r\n\r\nPackage: bash\r\nStatus: install ok installed\r\n' > "$tmp/crlf-first"
printf 'Package: frostyard-nbc\r\nStatus: deinstall ok config-files\r\n' > "$tmp/crlf-config-files"
printf 'Package: frostyard-nbc\nStatus: install ok config-files\n' > "$tmp/install-config-files"
printf 'Package: frostyard-nbc\nStatus: install ok not-installed\n' > "$tmp/not-installed"
printf 'Package: frostyard-nbc\nStatus: purge ok config-files\n' > "$tmp/purge-config-files"
printf 'Package: frostyard-nbc\nStatus: install ok not-installed-extra\n' > "$tmp/invalid-state"
printf 'Package: frostyard-nbc\n' > "$tmp/no-status"
printf 'Package: frostyard-nbc\nStatus: \n' > "$tmp/empty-status"
printf 'Package: frostyard-nbc\nStatus: deinstall ok config-files\n\nPackage: frostyard-nbc\nStatus: install ok installed\n' > "$tmp/duplicate-rejected-last"
printf 'Package: frostyard-nbc\nStatus: install ok installed\n\nPackage: frostyard-nbc\nStatus: deinstall ok config-files\n' > "$tmp/duplicate-rejected-first"
: > "$tmp/empty"

expect prefix 0 "$tmp/clean"
expect installed 1 "$tmp/installed"
expect unpacked 1 "$tmp/unpacked"
expect config-files 0 "$tmp/config-files"
expect crlf 1 "$tmp/crlf"
expect crlf-multiple 1 "$tmp/crlf-multiple"
expect crlf-first 1 "$tmp/crlf-first"
expect crlf-config-files 0 "$tmp/crlf-config-files"
expect install-config-files 1 "$tmp/install-config-files"
expect not-installed 0 "$tmp/not-installed"
expect purge-config-files 0 "$tmp/purge-config-files"
expect invalid-state 1 "$tmp/invalid-state"
expect no-status 1 "$tmp/no-status"
expect empty-status 1 "$tmp/empty-status"
expect duplicate-rejected-last 1 "$tmp/duplicate-rejected-last"
expect duplicate-rejected-first 1 "$tmp/duplicate-rejected-first"
expect empty 2 "$tmp/empty"
expect missing 2 "$tmp/missing"

echo 'check-no-nbc-package tests passed'
