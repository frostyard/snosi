#!/bin/bash
# Drop built sysexts whose identity is already published, before repogen runs.
#
# Usage: drop-published.sh PACKAGES_DIR
# Environment (all required):
#   R2_ACCOUNT_ID, R2_BUCKET   the bucket the publish step writes to
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   the publish step's R2 key
# Writes publish=true|false and remaining=N to $GITHUB_OUTPUT when it is set.
#
# Why: repogen v0.7.0 (frostyard/repogen internal/utils/package_identity.go)
# fails the WHOLE publish when a rebuilt sysext has an identity that is
# already published with other bytes or another filename. --skip-duplicates
# skips only exact duplicates, and mkosi output is not byte-reproducible, so
# every main run that rebuilds an unchanged sysext would fail. The identity is
# NAME_VERSION_OSVERSION_ARCH: the filename without .raw and its compression
# suffix (.raw and .raw.zst of one identity conflict too).
#
# The published identities come from ext/<name>/SHA256SUMS read straight from
# R2 with the publish credentials, never from the CDN, which can serve stale
# metadata. Any read error fails this script, so the publish does not run on
# a guess. A name with no SHA256SUMS in R2 is a new sysext and stays.
#
# Known gap (same as with v0.4.1 skip-duplicates): a sysext whose content
# changed without a KEYPACKAGE version or SYSEXT_REVISION bump keeps its
# identity, so it is dropped here and does not republish.
set -euo pipefail

die() {
    echo "::error::drop-published: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: drop-published.sh PACKAGES_DIR"
packages_dir=$1
[[ -d $packages_dir ]] || die "packages directory does not exist: $packages_dir"
for var in R2_ACCOUNT_ID R2_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    [[ -n ${!var:-} ]] || die "$var is not set"
done

# strip_identity FILENAME -> NAME_VERSION_OSVERSION_ARCH, or nothing when the
# name is not a sysext payload. Mirrors repogen's stripCompressionSuffix and
# the .raw check in internal/generator/sysext/parser.go.
strip_identity() {
    local name=$1
    case $name in
    *.raw.zst | *.raw.xz | *.raw.gz) name=${name%.*} ;;
    esac
    case $name in
    *.raw) printf '%s\n' "${name%.raw}" ;;
    esac
}

# The same payload suffixes the publish-to-r2 action counts and repogen scans.
mapfile -d '' built < <(find "$packages_dir" -type f \( -name '*.raw' -o \
    -name '*.raw.zst' -o -name '*.raw.xz' -o -name '*.raw.gz' \) -print0 | sort -z)
if [[ ${#built[@]} -eq 0 ]]; then
    die "no sysext payloads in $packages_dir; the build produced nothing to publish"
fi

published=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/published-ext.XXXXXX")
trap 'rm -rf "$published"' EXIT

# Fetch only the SHA256SUMS of every ext/<name>/ in one listing. sync exits
# non-zero on any listing or transfer error; an absent ext/ prefix is an empty
# result, not an error.
aws s3 sync "s3://${R2_BUCKET}/ext" "$published" \
    --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
    --exclude '*' --include '*/SHA256SUMS' --only-show-errors ||
    die "could not read ext/*/SHA256SUMS from R2 bucket ${R2_BUCKET}"

remaining=0
dropped=0
for file in "${built[@]}"; do
    base=${file##*/}
    identity=$(strip_identity "$base")
    name=${identity%%_*}
    # A malformed name stays: repogen rejects it with a clear error.
    if [[ -z $identity || $name == "$identity" ]]; then
        remaining=$((remaining + 1))
        echo "keep $base (not a NAME_VERSION_OSVERSION_ARCH payload; repogen decides)"
        continue
    fi
    sums="$published/$name/SHA256SUMS"
    match=
    if [[ -f $sums ]]; then
        while read -r _digest listed _rest; do
            [[ -n ${listed:-} ]] || continue
            listed=${listed#\*}
            if [[ $(strip_identity "$listed") == "$identity" ]]; then
                match=$listed
                break
            fi
        done <"$sums"
    fi
    if [[ -n $match ]]; then
        rm -f -- "$file"
        dropped=$((dropped + 1))
        echo "drop $base (identity $identity already published as $match)"
    else
        remaining=$((remaining + 1))
        echo "keep $base (identity $identity not published)"
    fi
done

echo "drop-published: ${#built[@]} built, $dropped already published, $remaining to publish"
publish=false
if [[ $remaining -gt 0 ]]; then
    publish=true
fi
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    {
        echo "publish=$publish"
        echo "remaining=$remaining"
    } >>"$GITHUB_OUTPUT"
fi
