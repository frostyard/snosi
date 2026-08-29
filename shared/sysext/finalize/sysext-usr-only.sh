#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Reject payload outside /usr in a sysext delta.
set -euo pipefail

if [[ ! -d "${BUILDROOT:-}" ]]; then
    echo "sysext-usr-only: BUILDROOT is not a directory" >&2
    exit 1
fi

if [[ -z "${IMAGE_ID:-}" ]]; then
    echo "sysext-usr-only: IMAGE_ID is not set" >&2
    exit 1
fi

offenders=()
for top_level in var opt; do
    payload_root="$BUILDROOT/$top_level"
    offending_path=

    if [[ -L "$payload_root" || (-e "$payload_root" && ! -d "$payload_root") ]]; then
        offending_path="/$top_level"
    elif [[ -d "$payload_root" ]]; then
        first_entry=$(find -P "$payload_root" -depth -mindepth 1 -print -quit)
        if [[ -n "$first_entry" ]]; then
            offending_path="/$top_level${first_entry#"$payload_root"}"
        fi
    fi

    [[ -z "$offending_path" ]] || offenders+=("$offending_path")
done

if ((${#offenders[@]} > 0)); then
    echo "sysext-usr-only: $IMAGE_ID contains payload outside /usr:" >&2
    printf '  %s\n' "${offenders[@]}" >&2
    echo "Sysext payloads must be /usr-only; relocate or remove each offending path." >&2
    exit 1
fi

echo "sysext-usr-only: $IMAGE_ID payload is confined to /usr"
