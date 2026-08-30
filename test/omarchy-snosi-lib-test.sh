#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture test for shared/flurry/omarchy-overrides/bin/omarchy-snosi-lib.
#
# The library's snosi_pkg_present_one() is the package-presence resolution
# engine behind the omarchy-pkg-present / omarchy-pkg-missing override
# commands, which omarchy's menus use to gate app availability. It resolves an
# Arch-style package name against a Debian/Flurry image using, in order:
#   1. dpkg -s <name>                (image-installed debs)
#   2. command -v <name>             (sysext-merged binaries, not in dpkg db)
#   3. the same two checks with a trailing "-bin" stripped (AUR naming)
#   4. an explicit Arch->Debian alias table for names the rules above miss
# A regression in any of these branches silently mis-reports availability --
# the exact defect class root-caused 2026-08-26, where gating names like
# "voxtype-bin" never matched the shipped "voxtype" deb.
#
# Every dependency is stubbed offline and deterministically: `dpkg` is a PATH
# shim driven by $DPKG_INSTALLED, and `command -v` resolution is confined to a
# throwaway bin dir by running the function under a restricted PATH. No root,
# no network, no real package database.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=test/lib/helpers.sh
source "$SCRIPT_DIR/lib/helpers.sh"

LIB="$REPO_ROOT/shared/flurry/omarchy-overrides/bin/omarchy-snosi-lib"

WORKROOT="$(mktemp -d /var/tmp/omarchy-snosi-lib-test.XXXXXX)"
trap 'rm -rf "$WORKROOT"' EXIT

BIN="$WORKROOT/bin"
mkdir -p "$BIN"

# Fake dpkg: `dpkg -s <name>` exits 0 when <name> is listed (space separated)
# in $DPKG_INSTALLED, mirroring how the real dpkg -s exits 0 for an installed
# package and non-zero otherwise. Any other invocation fails.
cat > "$BIN/dpkg" <<'DPKG_STUB'
#!/bin/bash
pkg=""
prev=""
for arg in "$@"; do
    [[ "$prev" == "-s" ]] && pkg="$arg"
    prev="$arg"
done
[[ -n "$pkg" ]] || exit 2
for installed in ${DPKG_INSTALLED:-}; do
    [[ "$installed" == "$pkg" ]] && exit 0
done
exit 1
DPKG_STUB
chmod +x "$BIN/dpkg"

# Executables that exist on PATH but are NOT in the dpkg database, standing in
# for sysext-merged binaries that overlay /usr without touching the deb db.
: > "$BIN/snosi-onpath"
: > "$BIN/snosi-cmdbase"
chmod +x "$BIN/snosi-onpath" "$BIN/snosi-cmdbase"

# shellcheck source=/dev/null
source "$LIB"

# present <pkg>: run the resolver with command -v confined to the stub bin dir
# so the result depends only on $BIN contents and the exported $DPKG_INSTALLED.
# Runs in a subshell so the restricted PATH never leaks into the harness.
present() { ( PATH="$BIN"; snosi_pkg_present_one "$1" ); }
absent()  { ! present "$1"; }

# Branch 1 -- exact dpkg match.
export DPKG_INSTALLED="snosi-deb snosi-base code"
check "exact name installed via dpkg is present" present snosi-deb
check "name absent from dpkg, PATH and aliases is missing" absent snosi-not-there

# Branch 2 -- command -v (sysext-merged binary, absent from the dpkg db).
export DPKG_INSTALLED=""
check "name resolvable only via command -v is present" present snosi-onpath
check "unknown name with an empty dpkg db is missing" absent snosi-not-there

# Branch 3 -- trailing "-bin" stripped, then retried via dpkg and command -v.
export DPKG_INSTALLED="snosi-base"
check "<name>-bin resolves to <name> via dpkg" present snosi-base-bin
check "<name>-bin resolves to <name> via command -v" present snosi-cmdbase-bin
check "<name>-bin with neither base variant present is missing" absent snosi-ghost-bin

# Branch 4 -- explicit Arch->Debian alias table.
# libreoffice-fresh -> libreoffice: pure alias path (name does not end in -bin).
export DPKG_INSTALLED="libreoffice"
check "aliased name resolves via its dpkg target" present libreoffice-fresh
export DPKG_INSTALLED=""
check "aliased name is missing when its target is absent" absent libreoffice-fresh
# visual-studio-code-bin -> code: ends in -bin, but neither "visual-studio-code"
# nor its stripped form is present, so resolution must fall through the -bin
# strip to the alias table keyed on the original name.
export DPKG_INSTALLED="code"
check "aliased -bin name falls through the strip to its alias target" \
    present visual-studio-code-bin

print_summary
