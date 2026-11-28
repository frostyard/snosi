#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared finalize script for every sysext: fail the build if the delta ships
# any path reserved to the base image (shared/sysext/base-owned-paths.txt)
# or any non-directory copy of a path in its base tree.
#
# Why (#1011, #1015): base carries the VM runtime (qemu, OVMF, SeaBIOS) that
# systemd-vmspawn needs on every product. Because every sysext builds against
# base, its delta normally omits those packages -- but not when the sysext
# pulls a family member base lacks, when apt upgrades a base package into
# the delta, or when base stops carrying it. A delta copy then overlays the
# image's runtime for the whole merged /usr, and qemu refuses to load modules
# from a different build after base's next point release. This is the
# all-sysext counterpart of the gui-base-only sysext-no-divergent-libs.sh.
set -euo pipefail

PATHS_FILE="$SRCDIR/shared/sysext/base-owned-paths.txt"
if [[ ! -f "$PATHS_FILE" ]]; then
    echo "sysext-no-base-owned: $PATHS_FILE not found" >&2
    exit 1
fi

[[ -d "$BUILDROOT/usr" ]] || {
    echo "sysext-no-base-owned: no /usr in the delta buildroot?" >&2
    exit 1
}

shopt -s nullglob
offenders=()
patterns=0
while IFS= read -r glob; do
    glob="${glob%%#*}"
    glob="${glob#"${glob%%[![:space:]]*}"}"
    glob="${glob%"${glob##*[![:space:]]}"}"
    [[ -n "$glob" ]] || continue
    patterns=$((patterns + 1))
    for match in "$BUILDROOT/usr/"$glob; do
        # A pattern without wildcards (bin/kvm) expands to itself even when
        # absent; nullglob only drops unmatched wildcard patterns. -L keeps
        # dangling symlinks; -e also keeps overlayfs whiteouts (character
        # devices), which would hide base's copy.
        [[ -e "$match" || -L "$match" ]] || continue
        offenders+=("${match#"$BUILDROOT"}")
    done
done < "$PATHS_FILE"

if (( patterns == 0 )); then
    echo "sysext-no-base-owned: $PATHS_FILE contains no patterns; refusing to pass vacuously" >&2
    exit 1
fi

status=0
if (( ${#offenders[@]} > 0 )); then
    echo "sysext-no-base-owned: ${IMAGE_ID:-sysext} delta ships paths the base image owns:" >&2
    printf '  %s\n' "${offenders[@]}" >&2
    cat >&2 <<'EOF'
The base image owns these (mkosi.images/base/mkosi.conf); a delta copy
overlays every product's copy for the whole merged /usr. Either this sysext
pulls a package from the same family that base does not carry, apt upgraded
a base package into the delta, or base stopped shipping it. Drop the package
from the sysext, add it to base, or re-triage the pattern in
shared/sysext/base-owned-paths.txt -- do not remove the pattern to make the
build pass.
EOF
    status=1
else
    echo "sysext-no-base-owned: ${IMAGE_ID:-sysext} delta clean ($patterns base-owned patterns checked)"
fi

# Base-tree resolution mirrors sysext-upholds-guard.sh. The overlay is
# unmounted before FinalizeScripts run, so BUILDROOT contains only the delta.
die() {
    echo "sysext-no-base-owned: $*" >&2
    exit 1
}

SRC=${SRCDIR:-}
base=""
if [[ -n ${SNOSI_SYSEXT_BASE_TREE:-} ]]; then
    base=$SNOSI_SYSEXT_BASE_TREE
elif [[ -n ${MKOSI_CONFIG:-} && -f ${MKOSI_CONFIG} ]]; then
    command -v jq >/dev/null || die "jq is required to read \$MKOSI_CONFIG ($MKOSI_CONFIG)"
    host_base=$(jq -r '(.BaseTrees // [])[0] // "" | if type == "object" then (.Source // "") else . end' "$MKOSI_CONFIG")
    if [[ -n $host_base && -n $SRC ]]; then
        while IFS= read -r source; do
            [[ -n $source ]] || continue
            source=${source%/}
            if [[ $host_base == "$source" ]]; then
                base=$SRC
                break
            elif [[ $host_base == "$source"/* ]]; then
                base=$SRC/${host_base#"$source"/}
                break
            fi
        done < <(jq -r '(.BuildSources // [])[] | select(.Target == null) | .Source' "$MKOSI_CONFIG")
    fi
fi
if [[ -z $base ]]; then
    [[ -n $SRC ]] || die "cannot locate the base tree: SRCDIR is not set"
    base=$SRC/output/base
fi
[[ -d $base ]] || die "base tree $base is not a directory; refusing to pass vacuously (is the base image built to \$SRCDIR/output/base?)"

check_base_tree_copies() {
    local rel count=0
    while IFS= LC_ALL=C read -r -d '' rel; do
        [[ -e "$base/usr/$rel" || -L "$base/usr/$rel" ]] || continue
        count=$((count + 1))
        if (( count == 1 )); then
            echo "sysext-no-base-owned: ${IMAGE_ID:-sysext} delta ships copies of base-tree paths:" >&2
        fi
        if (( count <= 50 )); then
            printf '  /usr/%s\n' "$rel" >&2
        fi
    done
    if (( count == 0 )); then
        return 0
    fi
    if (( count > 50 )); then
        printf '  ... and %d more\n' "$((count - 50))" >&2
    fi
    cat >&2 <<'EOF'
mkosi keeps the files of every reinstalled Packages= entry of an Overlay=yes
image (mkosi 00c7f0bc8). Drop from this sysext's Packages= each package that
its base tree (base or gui-base) already ships. Never add a base package to
a sysext's Packages=.
EOF
    return 1
}

# Keep symlinks (even broken ones) and devices; skip only real directories.
# Sort before filtering: the subset of copies stays in the same byte order.
if find -P "$BUILDROOT/usr" -mindepth 1 ! -type d -printf '%P\0' |
    LC_ALL=C sort -z | check_base_tree_copies; then
    echo "sysext-no-base-owned: ${IMAGE_ID:-sysext} delta clean (no base-tree copies)"
else
    status=1
fi
exit "$status"
