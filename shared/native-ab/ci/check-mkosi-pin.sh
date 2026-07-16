#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Mkosi Pin Governance assertion (docs/plans/2026-07-14-bootc-native-ab-
# coexistence-plan.md, "Mkosi Pin Governance": "CI must derive local and
# workflow mkosi from the same commit and fail if they diverge").
#
# .github/workflows/build.yml's `uses: systemd/mkosi@<sha>` line is this
# repo's single source of truth for the pinned mkosi commit -- Justfile's
# `mkosi_commit` (used by `just ensure-mkosi`, and therefore every local
# `just cayo-ab`/`snow-ab`/`snowfield-ab`/etc. build) greps it directly, and
# .github/workflows/build-native-images.yml's build jobs bootstrap mkosi via
# shared/native-ab/ci/bootstrap-mkosi.sh, which greps the SAME line -- so
# there is exactly one implementation of "how mkosi gets bootstrapped", not
# a second copy that could silently diverge. This script is the explicit
# regression guard for that property, run as an actual CI step (not just
# implied by construction):
#
#   1. build.yml's pin parses as a plausible full git commit SHA (not a
#      short SHA, branch name, or tag -- those are not acceptable pins for
#      a format this repo treats as part of the published image contract,
#      per the plan's "Treat the mkosi commit as part of the published
#      image format, not merely a build tool version").
#   2. build-native-images.yml carries NO literal `systemd/mkosi@<sha>` pin
#      of its own. This is the specific defect this whole mechanism exists
#      to prevent -- e.g. someone later copy-pastes a `uses: systemd/
#      mkosi@...` step from build-images.yml into build-native-images.yml,
#      pinned to whatever commit build-images.yml happens to carry at that
#      moment, silently reintroducing a second, independently-updated pin.
#      If one is ever added, it must be byte-identical to build.yml's.
#   3. If a local mkosi checkout is present (i.e. this is running after
#      shared/native-ab/ci/bootstrap-mkosi.sh, in CI or locally), its
#      checked-out HEAD commit equals build.yml's pin exactly.
#
# No network access and no mkosi build required for checks 1-2; check 3 is
# skipped (not failed) when the checkout directory does not exist yet, so
# this script is safe to run standalone -- e.g. as a quick governance check
# before ever bootstrapping anything, or in a local dry run.
#
# Usage: check-mkosi-pin.sh [mkosi-checkout-dir]
#   mkosi-checkout-dir  defaults to .mkosi (Justfile's mkosi_dir)
set -euo pipefail

usage() {
    echo "Usage: $0 [mkosi-checkout-dir]" >&2
    exit 2
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || usage
[[ $# -le 1 ]] || usage

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
mkosi_checkout="${1:-$root_dir/.mkosi}"

build_yml="$root_dir/.github/workflows/build.yml"
native_yml="$root_dir/.github/workflows/build-native-images.yml"

[[ -f "$build_yml" ]] || { echo "Error: missing $build_yml" >&2; exit 1; }
[[ -f "$native_yml" ]] || { echo "Error: missing $native_yml" >&2; exit 1; }

# Same extraction Justfile's `mkosi_commit` / bootstrap-mkosi.sh use.
pin="$(grep -m1 -oE 'systemd/mkosi@[0-9a-f]+' "$build_yml" | cut -d@ -f2 || true)"
[[ -n "$pin" ]] || {
    echo "Error: could not find a 'systemd/mkosi@<sha>' pin in $build_yml" >&2
    exit 1
}
[[ "$pin" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Error: pin '$pin' from $build_yml is not a full 40-character commit SHA" >&2
    exit 1
}
echo "build.yml mkosi pin: $pin"

# Check 2: build-native-images.yml must not carry its own independent pin.
native_pins="$(grep -oE 'systemd/mkosi@[0-9a-f]+' "$native_yml" | cut -d@ -f2 | sort -u || true)"
if [[ -n "$native_pins" ]]; then
    while IFS= read -r native_pin; do
        [[ -z "$native_pin" ]] && continue
        if [[ "$native_pin" != "$pin" ]]; then
            echo "Error: .github/workflows/build-native-images.yml pins systemd/mkosi@$native_pin, which does not match build.yml's $pin -- these must never diverge (Mkosi Pin Governance)" >&2
            exit 1
        fi
    done <<<"$native_pins"
fi
echo "ok - build-native-images.yml carries no conflicting mkosi pin"

# Check 3: if mkosi has actually been bootstrapped, its HEAD must be the pin.
if [[ -d "$mkosi_checkout/.git" ]]; then
    actual="$(git -C "$mkosi_checkout" rev-parse HEAD)"
    if [[ "$actual" != "$pin" ]]; then
        echo "Error: $mkosi_checkout is checked out at $actual, expected $pin (build.yml's pin) -- bootstrap is stale or used a different source" >&2
        exit 1
    fi
    echo "ok - $mkosi_checkout HEAD ($actual) matches build.yml's pin"
else
    echo "note - $mkosi_checkout not present yet (bootstrap not run); skipping HEAD comparison"
fi

echo "Mkosi pin governance check passed."
