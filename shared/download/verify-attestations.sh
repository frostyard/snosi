#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Verify the GitHub build-provenance attestation of pinned first-party .deb
# files (ADR-0024).
#
# Usage: verify-attestations.sh [KEY...]
#
# Each KEY names an entry of the checksums file that carries an `attestation`
# object ({"repository": "OWNER/REPO", "signer_workflow": "PATH"}). With no KEY,
# every entry that has an `attestation` object is checked, and it is an error
# when there is none. The script downloads each file through verified_download
# (so the pinned SHA-256 must match first) and then runs
#   gh attestation verify FILE --repo R --signer-workflow R/W \
#       --source-ref refs/tags/v<version> --deny-self-hosted-runners
#
# The checksums file is ${CHECKSUMS_FILE:-<this directory>/sysext-checksums.json}.
# ${GH:-gh} is the GitHub CLI; the caller supplies GH_TOKEN. The script fails
# closed: a missing field, a missing attestation for a named key, a failed
# download, a SHA-256 mismatch or a failed verify exits non-zero, after every
# key has been tried. It prints key names and outcomes only (gh output is
# printed only when a verify fails).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export CHECKSUMS_FILE="${CHECKSUMS_FILE:-$script_dir/sysext-checksums.json}"
# shellcheck source=/dev/null
source "$script_dir/verified-download.sh"

gh_bin="${GH:-gh}"

die() {
    printf 'verify-attestations: %s\n' "$*" >&2
    exit 1
}

[[ -f "$CHECKSUMS_FILE" ]] || die "checksums file not found: $CHECKSUMS_FILE"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v "$gh_bin" >/dev/null 2>&1 || die "GitHub CLI not found: $gh_bin"
jq -e 'type == "object"' "$CHECKSUMS_FILE" >/dev/null 2>&1 ||
    die "checksums file is not a JSON object: $CHECKSUMS_FILE"

# A key is a plain name: it becomes a file name, a log line and a list item, so
# it must not carry a newline, a slash or a space. The same rule is applied to
# the keys from the JSON file (in jq, before any list is built from them: a key
# with a newline would otherwise turn into 2 list items) and to the arguments.
# jq (Oniguruma) needs \A and \z, because its ^ and $ also match at a newline.
key_re_jq='\A[A-Za-z0-9][A-Za-z0-9._+-]*\z'
key_re_bash='^[A-Za-z0-9][A-Za-z0-9._+-]*$'

failed=0
fail_key() {
    printf 'FAIL %s: %s\n' "$1" "$2" >&2
    failed=1
}

keys=()
if (($# > 0)); then
    for arg in "$@"; do
        if [[ "$arg" =~ $key_re_bash ]]; then
            keys+=("$arg")
        else
            fail_key "$(printf '%q' "$arg")" "invalid key name"
        fi
    done
else
    # Entries that have an `attestation` field and a bad key name fail the run
    # (printed with @json, so a newline shows as \n and cannot split a line).
    bad=$(jq -c --arg re "$key_re_jq" '[to_entries[]
        | select((.value | type) == "object" and (.value | has("attestation")))
        | select(.key | test($re) | not)
        | .key]' "$CHECKSUMS_FILE") || die "cannot read $CHECKSUMS_FILE"
    if [[ "$bad" != "[]" ]]; then
        fail_key "$bad" "attested entries with invalid key names"
    fi
    mapfile -t keys < <(jq -r --arg re "$key_re_jq" 'to_entries[]
        | select((.value | type) == "object" and (.value | has("attestation")))
        | select(.key | test($re))
        | .key' "$CHECKSUMS_FILE")
    ((${#keys[@]} > 0)) || die "no entry with attestation metadata in $CHECKSUMS_FILE"
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

# Reads one string field of the current key's attestation object ('' if absent).
field() {
    jq -r --arg key "$key" --arg field "$1" '
        .[$key] as $e
        | if ($e | type) == "object" and ($e.attestation | type) == "object"
             and (($e.attestation[$field] // "") | type) == "string"
          then ($e.attestation[$field] // "") else "" end' "$CHECKSUMS_FILE"
}

for key in ${keys[@]+"${keys[@]}"}; do
    if ! jq -e --arg key "$key" '(.[$key] | type) == "object" and (.[$key].attestation | type) == "object"' \
        "$CHECKSUMS_FILE" >/dev/null 2>&1; then
        fail_key "$key" "no attestation metadata"
        continue
    fi
    repository=$(field repository)
    workflow=$(field signer_workflow)
    version=$(jq -r --arg key "$key" '.[$key].version // ""' "$CHECKSUMS_FILE")
    if [[ -z "$repository" || -z "$workflow" || -z "$version" ]]; then
        fail_key "$key" "attestation metadata is incomplete (repository, signer_workflow and version are required)"
        continue
    fi
    if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        fail_key "$key" "attestation repository is not OWNER/REPO"
        continue
    fi

    file="$work/$key.deb"
    if ! verified_download "$key" "$file" >/dev/null; then
        fail_key "$key" "download or SHA-256 check failed"
        continue
    fi

    log="$work/$key.log"
    if "$gh_bin" attestation verify "$file" \
        --repo "$repository" \
        --signer-workflow "$repository/$workflow" \
        --source-ref "refs/tags/v$version" \
        --deny-self-hosted-runners >"$log" 2>&1; then
        printf 'OK %s\n' "$key"
    else
        fail_key "$key" "attestation verification failed"
        sed 's/^/    /' "$log" >&2
    fi
    rm -f -- "$file" "$log"
done

((failed == 0)) || exit 1
printf 'verify-attestations: %d key(s) verified\n' "${#keys[@]}"
