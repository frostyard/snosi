#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared writable-ESP discovery for Snosi runtime tools.

SNOSI_ESP_TYPE="${SNOSI_ESP_TYPE:-c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
SNOSI_ESP_MOUNTPOINT=""
# shellcheck disable=SC2034 # Exported to callers that need the source device.
SNOSI_ESP_DEVICE=""
SNOSI_ESP_MOUNTED_HERE=0
SNOSI_ESP_LAYOUT=""

snosi_esp_error() {
    printf 'snosi ESP: %s\n' "$*" >&2
}

snosi_esp_device_beside() { # lsblk-json backing-partition
    local layout=$1 backing_partition=$2 disk
    local -a esps=()

    disk=$(jq -er --arg backing_partition "$backing_partition" '
        def nodes: . as $node | $node, (($node.children // [])[] | nodes);
        [ .blockdevices[] | nodes | select(.path? == $backing_partition) | .pkname ]
        | unique | if length == 1 then .[0] else error("expected one backing disk") end
    ' "$layout") || return 1

    while IFS= read -r esp; do esps+=("$esp"); done < <(
        jq -er --arg disk "$disk" --arg esp_type "$SNOSI_ESP_TYPE" '
            def nodes: . as $node | $node, (($node.children // [])[] | nodes);
            .blockdevices[] | nodes
            | select(.type == "part" and .pkname == $disk
                and ((.parttype // "") | ascii_downcase == $esp_type)) | .path
        ' "$layout"
    )
    [[ ${#esps[@]} -eq 1 ]] || {
        snosi_esp_error "expected one EFI System Partition beside $backing_partition"
        return 1
    }
    printf '%s\n' "${esps[0]}"
}

snosi_esp_resolve() { # runtime-directory [encrypted-root-mapper]
    local run_dir=$1 root_mapper=${2:-root}
    local candidate mount_options backing esp
    local -a mounted=()

    SNOSI_ESP_MOUNTPOINT=""
    SNOSI_ESP_DEVICE=""
    SNOSI_ESP_MOUNTED_HERE=0
    SNOSI_ESP_LAYOUT=""

    # Test hook used only by non-root fixture tests.
    if [[ -n ${SNOSI_ESP_TEST_PATH:-} ]]; then
        [[ -d $SNOSI_ESP_TEST_PATH ]] || {
            snosi_esp_error "test ESP path is not a directory: $SNOSI_ESP_TEST_PATH"
            return 1
        }
        SNOSI_ESP_MOUNTPOINT=$SNOSI_ESP_TEST_PATH
        return 0
    fi

    if candidate=$(bootctl --print-esp-path 2>/dev/null); then
        [[ $candidate == /* && -d $candidate ]] || {
            snosi_esp_error "bootctl returned an invalid ESP path: $candidate"
            return 1
        }
        mount_options=$(findmnt -rn -T "$candidate" -o OPTIONS | head -1)
        [[ -n $mount_options ]] || {
            snosi_esp_error "bootctl ESP path is not mounted: $candidate"
            return 1
        }
        [[ ,$mount_options, != *,ro,* ]] || {
            snosi_esp_error "EFI System Partition is mounted read-only: $candidate"
            return 1
        }
        SNOSI_ESP_MOUNTPOINT=$candidate
        # shellcheck disable=SC2034 # Exported to callers.
        SNOSI_ESP_DEVICE=$(findmnt -rn -T "$candidate" -o SOURCE | head -1)
        return 0
    fi

    backing=$(cryptsetup status "$root_mapper" |
        awk '/^[[:space:]]*device:/{print $2; exit}')
    [[ $backing == /dev/* ]] || {
        snosi_esp_error "bootctl found no mounted ESP and encrypted root mapper '$root_mapper' has no backing device"
        return 1
    }

    mkdir -p "$run_dir"
    SNOSI_ESP_LAYOUT="$run_dir/lsblk.json"
    lsblk -J -o PATH,TYPE,PARTTYPE,PKNAME >"$SNOSI_ESP_LAYOUT"
    esp=$(snosi_esp_device_beside "$SNOSI_ESP_LAYOUT" "$backing") || return 1
    # shellcheck disable=SC2034 # Exported to callers.
    SNOSI_ESP_DEVICE=$esp

    while IFS=' ' read -r candidate mount_options; do
        mounted+=("$candidate"$'\t'"$mount_options")
    done < <(findmnt -rn -S "$esp" -o TARGET,OPTIONS)
    [[ ${#mounted[@]} -le 1 ]] || {
        snosi_esp_error "EFI System Partition has ambiguous existing mounts"
        return 1
    }
    if [[ ${#mounted[@]} -eq 1 ]]; then
        IFS=$'\t' read -r SNOSI_ESP_MOUNTPOINT mount_options <<<"${mounted[0]}"
        [[ ,$mount_options, != *,ro,* ]] || {
            snosi_esp_error "EFI System Partition is already mounted read-only; refusing to remount or modify it"
            return 1
        }
        return 0
    fi

    SNOSI_ESP_MOUNTPOINT="$run_dir/esp"
    mkdir -p "$SNOSI_ESP_MOUNTPOINT"
    mount -o rw "$esp" "$SNOSI_ESP_MOUNTPOINT"
    SNOSI_ESP_MOUNTED_HERE=1
}

snosi_esp_cleanup() {
    set +e
    if [[ $SNOSI_ESP_MOUNTED_HERE -eq 1 && -n $SNOSI_ESP_MOUNTPOINT ]]; then
        umount "$SNOSI_ESP_MOUNTPOINT" >/dev/null 2>&1
        rmdir "$SNOSI_ESP_MOUNTPOINT" >/dev/null 2>&1
    fi
    [[ -z $SNOSI_ESP_LAYOUT ]] || rm -f -- "$SNOSI_ESP_LAYOUT"
    SNOSI_ESP_MOUNTED_HERE=0
    set -e
}
