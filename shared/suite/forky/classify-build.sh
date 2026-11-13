#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Classify a forky mechanics build against the known gaps (ADR-0037).
#
# The forky suite is built beside trixie while Debian testing is still
# incomplete. A forky build may fail, but only for a reason that is written down
# in known-gaps.tsv: any other failure is a regression in the forky wiring, and
# the workflow must fail.
#
# Usage: classify-build.sh --outcome OUTCOME --log FILE --known-gaps TSV
#
#   OUTCOME   steps.<id>.outcome of the build step: success, failure, ...
#
# Exit 0 when the outcome is explained (a known gap, or a clean build with no
# gap left in the file), 1 when it is not. Lines that start with "ok - " or
# "not ok - " are the verdicts; the caller appends the output to
# $GITHUB_STEP_SUMMARY.
set -euo pipefail

outcome=""
log=""
gaps=""

usage() {
    printf 'usage: %s --outcome OUTCOME --log FILE --known-gaps TSV\n' \
        "${BASH_SOURCE[0]}" >&2
    exit 2
}

while (($# > 0)); do
    case $1 in
    --outcome) outcome=${2:-}; shift 2 || usage ;;
    --log) log=${2:-}; shift 2 || usage ;;
    --known-gaps) gaps=${2:-}; shift 2 || usage ;;
    *) usage ;;
    esac
done

[[ -n $outcome && -n $log && -n $gaps ]] || usage

die() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

[[ -f $gaps ]] || die "the known-gap file $gaps does not exist"

# Read the file once into three arrays: id, fixed string, tracking URL.
declare -a gap_id=() gap_needle=() gap_url=()
while IFS=$'\t' read -r id needle url; do
    [[ -n ${id:-} && ${id:0:1} != "#" ]] || continue
    [[ -n ${needle:-} ]] || die "gap $id in $gaps has no fixed string"
    gap_id+=("$id")
    gap_needle+=("$needle")
    gap_url+=("${url:-}")
done < <(grep -v '^[[:space:]]*#' "$gaps" || true)

if [[ $outcome == success ]]; then
    if ((${#gap_id[@]} > 0)); then
        printf 'not ok - the forky build passed, so these known gaps are closed; remove them from %s:\n' "$gaps"
        for index in "${!gap_id[@]}"; do
            # shellcheck disable=SC2016 # Markdown backticks, not a command.
            printf -- '- `%s` (%s) %s\n' \
                "${gap_id[index]}" "${gap_needle[index]}" "${gap_url[index]}"
        done
        exit 1
    fi
    printf 'ok - the forky build passed and %s lists no gap\n' "$gaps"
    exit 0
fi

[[ -f $log ]] || die "the build failed (outcome: $outcome) but $log does not exist"
if ((${#gap_id[@]} == 0)); then
    die "the forky build failed (outcome: $outcome) and $gaps lists no known gap"
fi

# Every apt error in the log must be explained. One known gap must not hide a
# new one behind it: apt reports all unresolvable packages of one install at
# once, so a single matched row proves nothing about the other lines.
mapfile -t errors < <(grep -E '^([^ ]+ )?E: ' "$log" | sed -E 's/^[^ ]+ (E: )/\1/' || true)
if ((${#errors[@]} == 0)); then
    die "the forky build failed (outcome: $outcome) without an apt error line; no known gap can explain it, see the build log"
fi

matched=0
unexplained=0
for error in "${errors[@]}"; do
    hit=""
    for index in "${!gap_id[@]}"; do
        if [[ $error == *"${gap_needle[index]}"* ]]; then
            hit=$index
            break
        fi
    done
    if [[ -z $hit ]]; then
        unexplained=$((unexplained + 1))
        printf 'not ok - no known gap explains: %s\n' "$error"
        continue
    fi
    matched=$((matched + 1))
    # shellcheck disable=SC2016 # Markdown backticks, not a command.
    printf 'ok - known forky gap `%s`: %s\n' "${gap_id[hit]}" "$error"
    if [[ -n ${gap_url[hit]} ]]; then
        printf '  tracked at %s\n' "${gap_url[hit]}"
    fi
done

if ((unexplained > 0)); then
    die "the forky build failed (outcome: $outcome) with $unexplained apt error(s) that no known gap explains"
fi

printf 'ok - the forky build stopped at %d apt error(s), each a known gap\n' "$matched"
exit 0
