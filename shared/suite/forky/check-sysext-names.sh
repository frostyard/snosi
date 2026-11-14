#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Check the sysext file names of a forky build (ADR-0037).
#
# Usage: check-sysext-names.sh OUTPUT_DIR EXPECTED_ID...
#
# shared/sysext/postoutput/sysext-postoutput.sh names each sysext
# <id>_<version>_<os-version>_<arch>.raw[.<compression>], and a host matches
# only the files of its own suite through the %w (VERSION_ID) specifier of a
# sysupdate MatchPattern. A forky build must therefore make, for each
# expected sysext image id, exactly 1 versioned file with OS version 14, and
# no other versioned file. The unversioned mkosi output (<id>.raw.zst), the
# symlink <id> and the manifests (<id>.manifest, <id>.<version>.manifest.json)
# have no underscore-separated fields and are not checked.
#
# An id holds no underscore and a Debian version holds no underscore, so a
# versioned name has exactly 4 underscore-separated fields. A regular file
# with an underscore and a .raw suffix that does not have this shape fails.
set -euo pipefail

if (($# < 2)); then
    echo "usage: $0 OUTPUT_DIR EXPECTED_ID..." >&2
    exit 2
fi
dir=$1
shift
if [[ ! -d $dir ]]; then
    echo "::error::output directory $dir does not exist" >&2
    exit 2
fi

declare -A expected=() found=()
for id in "$@"; do
    if [[ -z $id || $id == *_* || $id == */* ]]; then
        echo "::error::expected sysext id '$id' is empty or holds '_' or '/'" >&2
        exit 2
    fi
    expected[$id]=1
done

errors=0
err() { echo "::error::$1" >&2; errors=$((errors + 1)); }

shopt -s nullglob
checked=0
for path in "$dir"/*_*.raw "$dir"/*_*.raw.*; do
    name=${path##*/}
    # The symlink <id> and the manifests never match these globs; a versioned
    # name that is a symlink is not a sysext file.
    [[ -L $path ]] && continue
    [[ -f $path ]] || continue
    if [[ ! $name =~ ^([^_]+)_([^_]+)_([^_]+)_([^_]+)\.raw(\.[a-z0-9]+)?$ ]]; then
        err "$name is not <id>_<version>_<os-version>_<arch>.raw[.<compression>]"
        continue
    fi
    id=${BASH_REMATCH[1]} osver=${BASH_REMATCH[3]}
    checked=$((checked + 1))
    if [[ -z ${expected[$id]:-} ]]; then
        err "$name belongs to sysext '$id', which the forky configuration does not build"
        continue
    fi
    if [[ $osver != 14 ]]; then
        err "$name names OS version $osver, not 14 (VERSION_ID of forky)"
        continue
    fi
    found[$id]=$((${found[$id]:-0} + 1))
    printf '%s\n' "$name"
done

for id in "${!expected[@]}"; do
    case ${found[$id]:-0} in
    1) ;;
    0) err "no versioned file for the expected sysext '$id'" ;;
    *) err "${found[$id]} versioned files for the sysext '$id'; exactly 1 is expected" ;;
    esac
done

if ((errors > 0)); then
    echo "forky sysext names: $errors error(s) in $checked versioned file(s), ${#expected[@]} sysext(s) expected" >&2
    exit 1
fi
echo "forky sysext names: $checked versioned file(s) checked, ${#expected[@]} sysext(s) expected, all OS version 14"
