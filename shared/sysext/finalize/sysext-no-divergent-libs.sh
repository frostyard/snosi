#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared finalize script for gui-base-built (desktop-app) sysexts: fail the
# build if the delta ships any shared library from a product-divergent
# family (shared/sysext/divergent-lib-families.txt).
#
# Why (issue #781): app sysext deltas omit only packages their BUILD BASE
# already has. A delta copy of a lib that a desktop product ships from a
# different suite shadow-downgrades the product's version for the whole
# merged /usr — chatgpt/claude-desktop deltas built against `base` shipped
# trixie libxkbcommon 1.7 over the backports 1.13 of a since-retired
# Hyprland desktop product and killed its compositor (root-caused live
# 2026-08-25). gui-base keeps those families out of the
# delta by construction; this tripwire catches the two ways the
# construction can silently rot: gui-base losing a package, or apt
# UPGRADING a lib into the delta because the app began requiring a newer
# version than gui-base carries. Both are re-triage events, so this fails
# the build rather than warning.
#
# Scope: wired only into sysexts whose BaseTrees is %O/gui-base. Server
# sysexts (incus with its qemu GUI libs, needed on cayo) legitimately carry
# some of these families and must NOT get this check.
set -euo pipefail

FAMILIES_FILE="$SRCDIR/shared/sysext/divergent-lib-families.txt"
if [[ ! -f "$FAMILIES_FILE" ]]; then
    echo "sysext-no-divergent-libs: $FAMILIES_FILE not found" >&2
    exit 1
fi

[[ -d "$BUILDROOT/usr" ]] || {
    echo "sysext-no-divergent-libs: no /usr in the delta buildroot?" >&2
    exit 1
}

shopt -s nullglob globstar
offenders=()
patterns=0
while IFS= read -r glob; do
    glob="${glob%%#*}"
    glob="${glob#"${glob%%[![:space:]]*}"}"
    glob="${glob%"${glob##*[![:space:]]}"}"
    [[ -n "$glob" ]] || continue
    patterns=$((patterns + 1))
    # Globs are relative to the delta's /usr; a trailing dir glob (…/*)
    # matches direct children, which is enough to flag the family.
    for match in "$BUILDROOT/usr/"$glob; do
        offenders+=("${match#"$BUILDROOT"}")
    done
done < "$FAMILIES_FILE"

if (( patterns == 0 )); then
    echo "sysext-no-divergent-libs: $FAMILIES_FILE contains no patterns; refusing to pass vacuously" >&2
    exit 1
fi

if (( ${#offenders[@]} > 0 )); then
    echo "sysext-no-divergent-libs: ${IMAGE_ID:-sysext} delta ships product-divergent library files:" >&2
    printf '  %s\n' "${offenders[@]}" >&2
    cat >&2 <<'EOF'
These families are pinned from backports/forky by at least one desktop
product; a delta copy shadow-downgrades the product's version for the whole
merged /usr (issue #781). Either gui-base lost the owning package, or apt
pulled a newer version into the delta because this app now requires more
than gui-base carries. Fix gui-base (mkosi.images/gui-base/mkosi.conf) or
re-triage the family — do not remove the pattern to make the build pass.
EOF
    exit 1
fi

echo "sysext-no-divergent-libs: ${IMAGE_ID:-sysext} delta clean ($patterns family patterns checked)"
