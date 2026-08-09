#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fetch and parse an APT Packages.gz index with bounded transfer time and
# decompressed size.

get_latest_package_version() (
    set -o pipefail

    local url="$1"
    local package="$2"
    local max_bytes="${3:-52428800}"
    local max_seconds="${4:-60}"
    local work_dir packages_file versions_file
    local pipeline_status=0
    local size latest="" version

    if [[ ! "$max_bytes" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: decompressed size limit must be a positive integer" >&2
        return 1
    fi
    if [[ ! "$max_seconds" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: transfer timeout must be a positive integer" >&2
        return 1
    fi

    work_dir="$(mktemp -d)" || return 1
    trap 'rm -rf "$work_dir"' EXIT
    packages_file="$work_dir/Packages"
    versions_file="$work_dir/versions"

    timeout --kill-after=5s "${max_seconds}s" \
        curl --retry 3 --connect-timeout 10 \
            --max-time "$max_seconds" --retry-max-time "$max_seconds" \
            --fail --silent --show-error --location "$url" |
        gzip -dc |
        head -c "$((max_bytes + 1))" >"$packages_file" ||
        pipeline_status=$?

    size="$(wc -c <"$packages_file")"
    if (( size > max_bytes )); then
        echo "ERROR: decompressed package index exceeds $max_bytes bytes" >&2
        return 1
    fi
    if (( pipeline_status != 0 )); then
        echo "ERROR: transfer or gzip validation failed for $url" >&2
        return 1
    fi

    awk -v package="$package" '
        /^Package: / { current = $2 }
        /^Version: / && current == package { print $2 }
    ' "$packages_file" >"$versions_file"

    while IFS= read -r version; do
        if [[ -z "$latest" ]] ||
            dpkg --compare-versions "$version" gt "$latest"; then
            latest="$version"
        fi
    done <"$versions_file"

    if [[ -z "$latest" ]]; then
        echo "ERROR: no version found for $package" >&2
        return 1
    fi
    printf '%s\n' "$latest"
)
