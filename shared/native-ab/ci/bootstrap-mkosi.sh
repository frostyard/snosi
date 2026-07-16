#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Fetches mkosi into a target directory at the exact commit pinned by
# .github/workflows/build.yml's `systemd/mkosi@<sha>` action -- this repo's
# single source of truth for the mkosi commit (Justfile's `mkosi_commit`
# greps that same line; see docs/plans/2026-07-14-bootc-native-ab-
# coexistence-plan.md "Mkosi Pin Governance": "CI must derive local and
# workflow mkosi from the same commit and fail if they diverge"). Idempotent:
# a no-op if the target directory is already checked out at that exact
# commit.
#
# This is the ONE implementation of "how mkosi gets bootstrapped from the
# build.yml pin", used by:
#   - Justfile's `ensure-mkosi` recipe (every local `just <target>` build)
#   - .github/workflows/build-native-images.yml's build-* jobs
# rather than two independent copies of the same six lines that could
# silently drift apart. shared/native-ab/ci/check-mkosi-pin.sh is the
# companion assertion script that this script's result actually matches the
# pin (defense in depth, not a replacement for this script's own
# idempotency check).
#
# Usage: bootstrap-mkosi.sh <target-dir>
set -euo pipefail

usage() {
    echo "Usage: $0 <target-dir>" >&2
    exit 2
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || usage
[[ $# -eq 1 ]] || usage
target_dir="$1"

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
build_yml="$root_dir/.github/workflows/build.yml"
[[ -f "$build_yml" ]] || { echo "Error: missing $build_yml" >&2; exit 1; }

# Same extraction Justfile's `mkosi_commit` uses -- keep these byte-identical.
pin="$(grep -m1 -oE 'systemd/mkosi@[0-9a-f]+' "$build_yml" | cut -d@ -f2 || true)"
[[ -n "$pin" ]] || {
    echo "Error: could not find a 'systemd/mkosi@<sha>' pin in $build_yml" >&2
    exit 1
}

if [[ -x "$target_dir/bin/mkosi" ]] &&
    [[ "$(git -C "$target_dir" rev-parse HEAD 2>/dev/null || true)" == "$pin" ]]; then
    echo "mkosi already bootstrapped at $pin in $target_dir"
    exit 0
fi

command -v python3 >/dev/null || { echo "Error: python3 is required to run mkosi" >&2; exit 1; }
command -v git >/dev/null || { echo "Error: git is required to bootstrap mkosi" >&2; exit 1; }

echo "Installing mkosi @ $pin (build.yml pin) into $target_dir"
rm -rf "$target_dir"
git init -q "$target_dir"
git -C "$target_dir" fetch -q --depth=1 https://github.com/systemd/mkosi.git "$pin"
git -C "$target_dir" checkout -q --detach FETCH_HEAD

actual="$(git -C "$target_dir" rev-parse HEAD)"
[[ "$actual" == "$pin" ]] || {
    echo "Error: checked out $actual in $target_dir, expected $pin" >&2
    exit 1
}
[[ -x "$target_dir/bin/mkosi" ]] || {
    echo "Error: $target_dir/bin/mkosi is not executable after checkout" >&2
    exit 1
}
echo "ok - mkosi bootstrapped at $pin"
