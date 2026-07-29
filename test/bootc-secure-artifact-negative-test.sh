#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fail-closed mutation coverage for Task 5 trusted UKI and assembly inputs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSEMBLER="$ROOT_DIR/shared/bootc-secure/assemble-uki.sh"

if [[ ${1:-} != --fixtures ]]; then
    echo "Usage: $0 --fixtures" >&2
    exit 2
fi

"$ASSEMBLER" --negative-self-test
"$ASSEMBLER" --credential-negative-self-test
echo "bootc secure negative artifact fixtures passed"
