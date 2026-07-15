#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Test-only wrapper functions around shared/native-installer/tree/usr/
# libexec/snosi-install's internal functions, for test/snosi-install-test.sh.
# Sourced AFTER the installer script itself (which guards its own `main`
# behind a `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` check, so sourcing it never
# runs the installer) inside a throwaway `bash -c` per call -- each call is
# its own process, so a wrapped function's `die` (a plain `exit 1`) only
# ends that one subprocess, never the test harness itself.
#
# Every wrapper prints its result to stdout as a single line (pipe-delimited
# where a function sets multiple output globals) so the caller can capture
# it with plain command substitution.
set -euo pipefail

t_resolve_target_disk() { # selector min_bytes self_device allow_file
    resolve_target_disk "$1" "$2" "$3" "$4"
    printf '%s|%s|%s|%s|%s\n' \
        "$RESOLVED_DISK_PATH" "$RESOLVED_DISK_MODEL" "$RESOLVED_DISK_SERIAL" \
        "$RESOLVED_DISK_SIZE" "$RESOLVED_DISK_REFUSAL"
}

t_find_installed_esp_and_var() { # disk(optional)
    find_installed_esp_and_var "${1:-}"
    printf '%s|%s|%s\n' "$RESTAGE_DISK" "$RESTAGE_ESP_PART" "$RESTAGE_VAR_PART"
}

t_fetch_verified_index() { # origin channel workdir
    fetch_verified_index "$1" "$2" "$3"
    printf '%s|%s\n' "$INDEX_FILE" "$INDEX_BASE_URL"
}

t_stream_download_verify() { # url expected_sha256 target
    stream_download_verify "$1" "$2" "$3"
    printf '%s\n' "$STREAM_DOWNLOAD_BYTES_WRITTEN"
}
