#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared finalize script for sysext images: fail the build if any path listed
# in mkosi.images/<image>/required-paths.txt is missing from the buildroot.
#
# Guards against publishing structurally broken sysexts. The incus sysext
# published on 2026-07-01 (1+7.2-debian13-202607011055) was missing the entire
# incus-base/incus-client payload — no incusd, no incus CLI, no units — most
# likely an APT repo publish race with strict versioned Depends. Nothing in
# the pipeline noticed; the image shipped and installs enabled a non-functional
# sysext. This check makes that class of failure a build error.
set -euo pipefail

if [[ -z "${IMAGE_ID:-}" ]]; then
    echo "sysext-required-paths: IMAGE_ID is not set" >&2
    exit 1
fi

PATHS_FILE="$SRCDIR/mkosi.images/$IMAGE_ID/required-paths.txt"
if [[ ! -f "$PATHS_FILE" ]]; then
    echo "sysext-required-paths: $PATHS_FILE not found; every sysext must declare its required paths" >&2
    exit 1
fi

# A path passes if it exists in the buildroot. Absolute symlinks would resolve
# against the build host, so re-anchor one level of absolute-symlink target
# inside the buildroot before giving up.
path_present() {
    local p="$BUILDROOT$1"
    [[ -e "$p" ]] && return 0
    if [[ -L "$p" ]]; then
        local target
        target=$(readlink "$p")
        [[ "$target" == /* && -e "$BUILDROOT$target" ]] && return 0
    fi
    return 1
}

missing=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    if ! path_present "$line"; then
        missing+=("$line")
    fi
done < "$PATHS_FILE"

if (( ${#missing[@]} > 0 )); then
    echo "sysext-required-paths: $IMAGE_ID is missing required paths:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo "The sysext build is incomplete (missing packages or failed relocation); refusing to produce a broken extension." >&2
    exit 1
fi

echo "sysext-required-paths: all $(grep -cve '^[[:space:]]*\(#\|$\)' "$PATHS_FILE") required paths present in $IMAGE_ID"
