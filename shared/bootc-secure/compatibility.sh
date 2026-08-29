#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later

snosi_bootc_secure_load_compatibility() { # contract
    local contract=$1 values version compatibility minimum_version

    [[ -r $contract ]] || {
        printf 'Error: bootc secure contract is unreadable: %s\n' "$contract" >&2
        return 1
    }
    values=$(jq -er '[
        .assembly.bootc_version,
        .assembly.compatibility,
        .installer.minimum_versions.bootc
    ] | @tsv' "$contract") || {
        printf 'Error: bootc secure contract lacks compatibility fields\n' >&2
        return 1
    }
    IFS=$'\t' read -r version compatibility minimum_version <<<"$values"
    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
            [[ $minimum_version != "$version" ]] ||
            [[ $compatibility != "bootc-$version-storage-digest-v1" ]]; then
        printf 'Error: inconsistent bootc secure compatibility fields\n' >&2
        return 1
    fi

    BOOTC_SECURE_VERSION=$version
    BOOTC_SECURE_ASSEMBLY_COMPATIBILITY=$compatibility
}
