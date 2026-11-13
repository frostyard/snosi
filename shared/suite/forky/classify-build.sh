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

matched=0
for index in "${!gap_id[@]}"; do
    line=$(grep -F -m 1 -e "${gap_needle[index]}" "$log" || true)
    [[ -n $line ]] || continue
    matched=$((matched + 1))
    # shellcheck disable=SC2016 # Markdown backticks, not a command.
    printf 'ok - known forky gap `%s`: %s\n' "${gap_id[index]}" "${line#"${line%%[![:space:]]*}"}"
    if [[ -n ${gap_url[index]} ]]; then
        printf '  tracked at %s\n' "${gap_url[index]}"
    fi
done

if ((matched == 0)); then
    die "the forky build failed (outcome: $outcome) for a reason that no known gap explains; see the build log"
fi

printf 'ok - the forky build stopped at %d known gap(s); the wiring itself is unchanged\n' "$matched"
exit 0
