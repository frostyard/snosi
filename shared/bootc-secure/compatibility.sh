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

    # shellcheck disable=SC2034 # Outputs consumed by scripts sourcing this helper.
    BOOTC_SECURE_VERSION=$version
    # shellcheck disable=SC2034 # Outputs consumed by scripts sourcing this helper.
    BOOTC_SECURE_ASSEMBLY_COMPATIBILITY=$compatibility
}

# The Debian suite of the secure image (ADR-0037, ADR-0038). Unset or empty
# SNOSI_BOOTC_SECURE_SUITE selects trixie, the default suite; forky selects the
# forky contract copy and the forky-<timestamp> tag form. Any other value fails.
snosi_bootc_secure_suite() {
    local suite=${SNOSI_BOOTC_SECURE_SUITE:-trixie}

    case $suite in
        trixie|forky) printf '%s\n' "$suite" ;;
        *)
            printf 'Error: unsupported SNOSI_BOOTC_SECURE_SUITE: %s (expected trixie or forky)\n' \
                "$suite" >&2
            return 1
            ;;
    esac
}

snosi_bootc_secure_contract_path() { # root-dir
    local root=$1 suite

    suite=$(snosi_bootc_secure_suite) || return 1
    case $suite in
        trixie) printf '%s\n' "$root/shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json" ;;
        forky) printf '%s\n' "$root/shared/bootc-secure/suite/forky/tree/usr/lib/snosi/bootc-secure.json" ;;
    esac
}

# Trixie publishes bare 14-digit tags; forky publishes only forky-<14 digits>,
# so the two suites never share a tag namespace.
snosi_bootc_secure_valid_version_tag() { # tag
    local tag=${1:-} suite

    suite=$(snosi_bootc_secure_suite) || return 1
    case $suite in
        trixie) [[ $tag =~ ^[0-9]{14}$ ]] ;;
        forky) [[ $tag =~ ^forky-[0-9]{14}$ ]] ;;
    esac
}
