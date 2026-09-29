#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared finalize script for every sysext: fail the build if the delta ships
# any path the base image owns (shared/sysext/base-owned-paths.txt).
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
    exit 1
fi

echo "sysext-no-base-owned: ${IMAGE_ID:-sysext} delta clean ($patterns base-owned patterns checked)"
