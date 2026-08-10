#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Verify that the repository exposes an ACMM-recognized policy-as-code entry point.
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

candidates=(
    "policies"
    ".github/policies"
    "kyverno"
    "conftest.yaml"
    "opa"
)

for relative in "${candidates[@]}"; do
    if [[ -e "$PROJECT_ROOT/$relative" ]]; then
        printf 'ok - policy-as-code entry point exists at %s\n' "$relative"
        exit 0
    fi
done

printf 'not ok - missing policy-as-code entry point (%s)\n' "${candidates[*]}" >&2
exit 1
