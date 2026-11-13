#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Retention for the Firn installer ISO namespace "isos/native/v1/"
# (ADR-0036). Deletes installer ISOs that fell out of the keep window, the
# stale ".candidate/<version>/" scratch a failed publication run left behind,
# and the ".history/<version>/" archived index pair of each ISO it deletes in
# the same run. The archived index of any other version is kept.
#
# The only payload it may delete is an object named exactly
# "snosi-installer_<14-digit version>_x86-64.iso" at the top of the
# namespace. Every other top-level object (for example historical
# "snosi-native-installer_*" media) is reported as unclassified and kept.
#
# What it keeps, always:
#   - every object named by the LIVE signed index (SHA256SUMS), which must
#     gpgv-verify against the pubring BEFORE anything is trusted. An index
#     that does not verify, lists more than one version, or names an object
#     that is not present means the namespace is in an unexpected state:
#     this script then refuses to delete anything.
#   - the current version plus the --keep-previous newest older versions
#     (default 2).
#   - every version NEWER than the current one (a promotion in flight);
#     reported and left for the operator.
#   - any object younger than --grace-hours (default 24), regardless of
#     class, so a publication run that is executing right now is never raced.
#   - the live version's own ".candidate/" dir, and anything this script
#     cannot classify (reported as such).
#
# Nothing is deleted unless --execute is given; the default is a dry run that
# prints the full decision list. With --execute:
#   - a plan that deletes more than --max-delete objects (default 30) is
#     refused with exit status 3 and nothing is deleted. A larger backlog is
#     an operator decision: read the printed list, then re-run with a
#     --max-delete that covers it.
#   - the live index is re-read immediately before deletion and must be
#     byte-identical to the one the plan was built from; a promotion landing
#     in between aborts the run untouched.
#
# Usage: retention.sh [--keep-previous N] [--grace-hours H] [--max-delete N]
#                     [--pubring <path>] [--execute] <dest>
#
#   dest      publication origin root, same addressing as promote.sh (a local
#             directory, or "rclone:<remote>:<bucket>").
set -euo pipefail

usage() {
    echo "Usage: $0 [--keep-previous N] [--grace-hours H] [--max-delete N] [--pubring <path>] [--execute] <dest>" >&2
    exit 2
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=shared/native-ab/publish/publish-lib.sh
source "$SCRIPT_DIR/publish-lib.sh"

PUBRING="$ROOT_DIR/shared/native-ab/keys/import-pubring.gpg"
KEEP_PREVIOUS=2
GRACE_HOURS=24
MAX_DELETE=30
EXECUTE=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
    --keep-previous)
        KEEP_PREVIOUS="$2"
        shift 2
        ;;
    --grace-hours)
        GRACE_HOURS="$2"
        shift 2
        ;;
    --pubring)
        PUBRING="$2"
        shift 2
        ;;
    --max-delete)
        MAX_DELETE="$2"
        shift 2
        ;;
    --execute)
        EXECUTE=1
        shift
        ;;
    -h | --help)
        usage
        ;;
    --)
        shift
        break
        ;;
    -*)
        echo "Error: unknown option: $1" >&2
        usage
        ;;
    *)
        POSITIONAL+=("$1")
        shift
        ;;
    esac
done
POSITIONAL+=("$@")
[[ ${#POSITIONAL[@]} -eq 1 ]] || usage
DEST="${POSITIONAL[0]}"

int_regex='^[0-9]+$'
[[ "$KEEP_PREVIOUS" =~ $int_regex ]] || { echo "Error: --keep-previous must be a non-negative integer" >&2; exit 1; }
[[ "$MAX_DELETE" =~ $int_regex ]] || { echo "Error: --max-delete must be a non-negative integer" >&2; exit 1; }
[[ "$GRACE_HOURS" =~ $int_regex ]] || { echo "Error: --grace-hours must be a non-negative integer" >&2; exit 1; }

command -v gpgv >/dev/null || { echo "Error: required command not found: gpgv" >&2; exit 1; }
[[ -s "$PUBRING" ]] || { echo "Error: pubring not found or empty: $PUBRING" >&2; exit 1; }

dest_parse "$DEST"
product_dir="isos/native/v1"
mode="DRY RUN"
[[ "$EXECUTE" == 0 ]] || mode="EXECUTE"
echo "Installer ISO retention ($product_dir/): keep current + $KEEP_PREVIOUS previous, ${GRACE_HOURS}h grace, at most $MAX_DELETE deletions [$mode]"

WORK_DIR="$(mktemp -d /var/tmp/retention.XXXXXX)"
register_cleanup "rm -rf '$WORK_DIR'"

# ---------------------------------------------------------------------------
# 1. The live signed index: read from the storage backend (not the edge),
#    gpgv-verified, exactly one version. Anything else: refuse.
# ---------------------------------------------------------------------------

live_sums="$WORK_DIR/SHA256SUMS"
live_sig="$WORK_DIR/SHA256SUMS.gpg"
dest_read_object "$product_dir/SHA256SUMS" "$live_sums" || {
    echo "Error: no live SHA256SUMS at $product_dir/ -- nothing has ever been promoted here, or the namespace is broken; refusing to touch it" >&2
    exit 1
}
dest_read_object "$product_dir/SHA256SUMS.gpg" "$live_sig" || {
    echo "Error: live SHA256SUMS exists at $product_dir/ but SHA256SUMS.gpg does not; refusing" >&2
    exit 1
}
gpgv --keyring "$PUBRING" "$live_sig" "$live_sums" 2>/dev/null || {
    echo "Error: live SHA256SUMS at $product_dir/ does not verify against $PUBRING; refusing to trust it" >&2
    exit 1
}

mapfile -t indexed_names < <(awk 'NF >= 2 {print $2}' "$live_sums")
[[ ${#indexed_names[@]} -gt 0 ]] || { echo "Error: live SHA256SUMS lists no objects; refusing" >&2; exit 1; }

# The one payload name this script manages. version_of prints the 14-digit
# version of such a name and nothing for any other name.
version_of() { # object-name -> 14-digit version, or empty
    [[ "$1" =~ ^snosi-installer_([0-9]{14})_x86-64\.iso$ ]] && echo "${BASH_REMATCH[1]}" || true
}

mapfile -t index_versions < <(for n in "${indexed_names[@]}"; do version_of "$n"; done | sort -u)
[[ ${#index_versions[@]} -eq 1 && -n "${index_versions[0]}" ]] || {
    echo "Error: live SHA256SUMS must advertise exactly one version, found: ${index_versions[*]:-none}; refusing" >&2
    exit 1
}
CURRENT="${index_versions[0]}"
echo "Live signed index verifies; current version $CURRENT (${#indexed_names[@]} objects)"

# ---------------------------------------------------------------------------
# 2. Listing and classification.
# ---------------------------------------------------------------------------

listing="$WORK_DIR/listing.tsv"
dest_list_objects "$product_dir" >"$listing"
[[ -s "$listing" ]] || { echo "Error: listing of $product_dir/ is empty although a live index exists; refusing" >&2; exit 1; }

# Every indexed object must actually be present; otherwise the namespace is
# not what the index says it is and nothing here should be trusted.
for n in "${indexed_names[@]}"; do
    grep -qF -- "	$product_dir/$n" "$listing" || {
        echo "Error: live SHA256SUMS names $n but no such object exists under $product_dir/; refusing" >&2
        exit 1
    }
done

now="$(date +%s)"
grace_seconds=$(( GRACE_HOURS * 3600 ))
declare -A indexed=()
for n in "${indexed_names[@]}"; do indexed["$n"]=1; done

# Published versions = distinct version tokens of top-level objects.
mapfile -t published_versions < <(
    awk -F'\t' -v p="$product_dir/" '{ rel=$3; sub("^" p, "", rel); if (rel !~ /\//) print rel }' "$listing" |
        while IFS= read -r n; do version_of "$n"; done | grep -v '^$' | sort -u
)
grep -qx -- "$CURRENT" <<<"$(printf '%s\n' "${published_versions[@]}")" || {
    echo "Error: current version $CURRENT has no top-level payload objects; refusing" >&2
    exit 1
}

declare -A keep_version=()
keep_version["$CURRENT"]=1
newer_versions=()
older_kept=0
# published_versions is ascending; walk from newest down.
for (( i=${#published_versions[@]}-1; i>=0; i-- )); do
    v="${published_versions[$i]}"
    if [[ "$v" > "$CURRENT" ]]; then
        keep_version["$v"]=1
        newer_versions+=("$v")
    elif [[ "$v" < "$CURRENT" && "$older_kept" -lt "$KEEP_PREVIOUS" ]]; then
        keep_version["$v"]=1
        older_kept=$(( older_kept + 1 ))
    fi
done
kept_list="$(printf '%s\n' "${!keep_version[@]}" | sort | paste -sd,)"
echo "Keep versions: $kept_list"
[[ ${#newer_versions[@]} -eq 0 ]] ||
    echo "NOTE: ${#newer_versions[@]} version(s) newer than the live index are present and kept (a promotion in flight -- operator decision): ${newer_versions[*]}"

# The installer ISOs this run deletes: outside the keep window and older
# than the grace. A ".history/<v>/" pair is deleted only with the ISO of v,
# so the archived index of any other version (for example the
# "snosi-native-installer" era, whose media stays unclassified) is kept.
declare -A iso_deleted=()
while IFS=$'\t' read -r mtime _ rel; do
    name="${rel#"$product_dir"/}"
    [[ "$name" != */* && -z "${indexed[$name]:-}" ]] || continue
    v="$(version_of "$name")"
    [[ -n "$v" && -z "${keep_version[$v]:-}" ]] || continue
    (( now - mtime >= grace_seconds )) || continue
    iso_deleted["$v"]=1
done <"$listing"

plan="$WORK_DIR/plan.tsv" # action \t class \t size \t relpath \t reason
: >"$plan"
while IFS=$'\t' read -r mtime size rel; do
    name="${rel#"$product_dir"/}"
    age=$(( now - mtime ))
    action=keep class=unclassified reason="no rule matched"
    if [[ "$name" == SHA256SUMS || "$name" == SHA256SUMS.gpg ]]; then
        class=index reason="live signed index"
    elif [[ -n "${indexed[$name]:-}" ]]; then
        class=current reason="named by the live signed index"
    elif [[ "$name" == .candidate/* ]]; then
        class=candidate
        v="${name#.candidate/}"; v="${v%%/*}"
        if [[ ! "$v" =~ ^[0-9]{14}$ ]]; then
            class=unclassified reason="candidate directory is not a version"
        elif [[ "$v" == "$CURRENT" ]]; then
            reason="candidate of the live version"
        elif [[ -n "${keep_version[$v]:-}" && "$v" > "$CURRENT" ]]; then
            reason="candidate of a newer version (kept, see NOTE)"
        elif (( age < grace_seconds )); then
            reason="younger than ${GRACE_HOURS}h grace"
        else
            action=delete reason="stale candidate $v, $(( age / 86400 ))d old"
        fi
    elif [[ "$name" == .history/* ]]; then
        class=history
        v="${name#.history/}"; v="${v%%/*}"
        if [[ ! "$v" =~ ^[0-9]{14}$ ]]; then
            class=unclassified reason="history directory is not a version"
        elif [[ -n "${keep_version[$v]:-}" ]]; then
            reason="archived index of kept version $v"
        elif [[ -z "${iso_deleted[$v]:-}" ]]; then
            reason="no installer ISO of version $v is deleted in this run"
        elif (( age < grace_seconds )); then
            reason="younger than ${GRACE_HOURS}h grace"
        else
            action=delete reason="archived index of pruned version $v"
        fi
    elif [[ "$name" != */* ]] && v="$(version_of "$name")" && [[ -n "$v" ]]; then
        class=published
        if [[ -n "${keep_version[$v]:-}" ]]; then
            reason="version $v inside keep window"
        elif [[ -z "${iso_deleted[$v]:-}" ]]; then
            reason="younger than ${GRACE_HOURS}h grace"
        else
            action=delete reason="version $v outside keep window"
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$action" "$class" "$size" "$rel" "$reason" >>"$plan"
done <"$listing"

# Belt and braces: the live index's objects can never be in the delete set,
# and every deleted key is a plain path inside the namespace.
while IFS=$'\t' read -r action _ _ rel _; do
    [[ "$action" == delete ]] || continue
    retention_check_relpath "$rel" || { echo "Error: refusing to delete an unsafe key: $rel" >&2; exit 1; }
    [[ "$rel" == "$product_dir"/* ]] || { echo "BUG: plan would delete $rel outside $product_dir/; aborting" >&2; exit 1; }
    name="${rel#"$product_dir"/}"
    [[ -z "${indexed[$name]:-}" ]] || { echo "BUG: plan would delete indexed object $rel; aborting" >&2; exit 1; }
done <"$plan"

# ---------------------------------------------------------------------------
# 3. Report.
# ---------------------------------------------------------------------------

echo ""
echo "Decisions ($product_dir/):"
awk -F'\t' '{ n[$1 FS $2]++; b[$1 FS $2]+=$3 } END { for (k in n) { split(k, a, FS); printf "  %-6s %-12s %6d object(s) %10.1f MiB\n", a[1], a[2], n[k], b[k]/1048576 } }' "$plan" | sort -k1,1r -k4,4nr
if grep -q $'^keep\tunclassified' "$plan"; then
    echo "WARNING: unclassified objects left untouched:"
    awk -F'\t' '$1 == "keep" && $2 == "unclassified" { print "  " $4 }' "$plan" | head -20
fi
del_list="$WORK_DIR/delete.txt"
awk -F'\t' '$1 == "delete" { print $4 }' "$plan" >"$del_list"
del_count="$(wc -l <"$del_list")"
del_bytes="$(awk -F'\t' '$1 == "delete" { b+=$3 } END { print b+0 }' "$plan")"
echo ""
echo "To delete: $del_count object(s), $(( del_bytes / 1048576 )) MiB"
if [[ "$del_count" -gt 0 ]]; then
    echo "Delete list:"
    awk -F'\t' '$1 == "delete" { printf "  %s  (%s)\n", $4, $5 }' "$plan"
fi

if [[ "$EXECUTE" == 0 ]]; then
    echo ""
    echo "Dry run: nothing deleted. Re-run with --execute to apply."
    exit 0
fi
[[ "$del_count" -gt 0 ]] || { echo "Nothing to delete."; exit 0; }
if (( del_count > MAX_DELETE )); then
    echo "" >&2
    echo "Refusing: the plan deletes $del_count object(s), more than --max-delete $MAX_DELETE. Nothing deleted." >&2
    echo "Review the delete list above, then re-run with --max-delete $del_count or higher." >&2
    exit 3
fi

# ---------------------------------------------------------------------------
# 4. Execute: the live index must not have moved since the plan was built.
# ---------------------------------------------------------------------------

recheck="$WORK_DIR/SHA256SUMS.recheck"
dest_read_object "$product_dir/SHA256SUMS" "$recheck" || { echo "Error: live SHA256SUMS vanished before deletion; aborting" >&2; exit 1; }
cmp -s "$live_sums" "$recheck" || { echo "Error: live SHA256SUMS changed while planning (a promotion landed); aborting untouched -- rerun" >&2; exit 1; }

echo ""
echo "Deleting $del_count object(s)..."
dest_delete_listed "$del_list"
echo "Deleted $del_count object(s), $(( del_bytes / 1048576 )) MiB freed from $product_dir/"
