#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared finalize script for every base-built sysext: remove the product-owned
# Mesa runtime from the delta (shared/sysext/product-mesa-paths.txt).
#
# Why (issue #1318): every product pins its Mesa runtime from trixie-backports
# through its kernel fragment (shared/kernel/{backports,surface}/{trixie,forky}
# .conf). A sysext built against `base` installs those packages from plain
# trixie into its delta, and a merged delta copy shadow-downgrades the
# product's Mesa for the whole /usr (dev and incus carried Mesa 25.0.7 over the
# products' 26.1.6: with dev merged, OpenGL, EGL and GBM ran on 25.0.7 while
# Vulkan stayed on the product's 26.1.6).
#
# mkosi runs FinalizeScripts AFTER it unmounts the base overlay, so $BUILDROOT
# holds the delta (upper dir) only. A deletion here therefore cannot create an
# overlayfs whiteout and cannot hide a product file: it just leaves the delta
# without the path, and the product's own copy serves at merge time.
#
# Scope: wired only into sysexts whose BaseTrees is %O/base. gui-base-built
# sysexts must NOT run it: their sysext-no-divergent-libs.sh tripwire has to
# keep seeing Mesa if gui-base loses it (issue #781).
set -euo pipefail

PATHS_FILE="$SRCDIR/shared/sysext/product-mesa-paths.txt"
if [[ ! -f "$PATHS_FILE" ]]; then
    echo "sysext-strip-product-mesa: $PATHS_FILE not found" >&2
    exit 1
fi

[[ -d "$BUILDROOT/usr" ]] || {
    echo "sysext-strip-product-mesa: no /usr in the delta buildroot?" >&2
    exit 1
}

shopt -s nullglob
removed=0
patterns=0
declare -A prune=()

# Remove the directories the removals emptied, walking up from each one and
# stopping before $BUILDROOT/usr. rmdir refuses a non-empty directory, so a
# directory that still holds a file the product does not own stays.
prune_empty_dirs() { # start-dir
    local dir=$1
    while true; do
        case "$dir" in
            "$BUILDROOT"/usr/?*) ;;
            *) return 0 ;;
        esac
        [[ -d "$dir" && ! -L "$dir" ]] || return 0
        rmdir -- "$dir" 2>/dev/null || return 0
        echo "sysext-strip-product-mesa: removed empty directory ${dir#"$BUILDROOT"}"
        dir=$(dirname -- "$dir")
    done
}

while IFS= read -r glob; do
    glob="${glob%%#*}"
    glob="${glob#"${glob%%[![:space:]]*}"}"
    glob="${glob%"${glob##*[![:space:]]}"}"
    [[ -n "$glob" ]] || continue
    patterns=$((patterns + 1))
    for match in "$BUILDROOT/usr/"$glob; do
        # -e / -L keeps a dangling symlink (it must still go), while a
        # directory a glob happened to match is left for the prune pass.
        [[ -e "$match" || -L "$match" ]] || continue
        if [[ -d "$match" && ! -L "$match" ]]; then
            continue
        fi
        rm -f -- "$match"
        echo "sysext-strip-product-mesa: removed ${match#"$BUILDROOT"}"
        removed=$((removed + 1))
        prune["$(dirname -- "$match")"]=1
    done
done < "$PATHS_FILE"

if (( patterns == 0 )); then
    echo "sysext-strip-product-mesa: $PATHS_FILE contains no patterns; refusing to pass vacuously" >&2
    exit 1
fi

for dir in "${!prune[@]}"; do
    prune_empty_dirs "$dir"
done

echo "sysext-strip-product-mesa: ${IMAGE_ID:-sysext} delta stripped of $removed product Mesa path(s) ($patterns patterns checked)"
