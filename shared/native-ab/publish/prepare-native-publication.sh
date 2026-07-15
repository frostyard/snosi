#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Native A/B publication naming pipeline (docs/native-ab-contracts.md §4, §5).
# Takes mkosi's internal split outputs for one built native profile and
# produces the frozen public artifact names in a per-product publish tree,
# ready for upload to the R2 namespace in §5. This script does NOT sign
# anything: SHA256SUMS here is unsigned (Phase 7's protected promotion step
# owns SHA256SUMS.gpg, per §7 "Protected signing architecture" / §4 "Both
# index files").
#
# Usage: prepare-native-publication.sh [--xz] <mkosi-output-dir> <profile-output-name> <dest-dir>
#
#   mkosi-output-dir     mkosi's OutputDirectory (e.g. "output")
#   profile-output-name  the built profile's Output= value (e.g. "cayo-ab");
#                         this is also expected to equal the channel name
#                         (<ImageId>-ab, §1) -- see the validation below,
#                         which is what makes this refuse to "publish" the
#                         cayo-ab-raw dev fixture.
#   dest-dir              directory to write <product>/x86-64/<files> into
#
# Product, channel, and version are derived from the artifacts themselves,
# never passed on the command line, so the produced names cannot drift from
# what was actually built:
#   - product  = the mkosi JSON manifest's .config.name (== ImageId=)
#   - version  = the mkosi JSON manifest's .config.version, validated against
#                the frozen ^[0-9]{14}$ grammar (§2)
#   - channel  = profile-output-name, validated to equal "<product>-ab" (§1)
#
# PARTUUIDs for the root/root-verity artifacts are read from the built disk's
# GPT via `sfdisk --json` (works on a plain regular file, no loop device, no
# root -- verified against a real 16GB disk image as an unprivileged user;
# prefer this over losetup, which does need root). Partitions are located by
# their repart Label= (<product>_<version>_r / _v, §3), matching the prior
# art in test/native-ab-update-test.sh.
#
# --xz compresses the root/root-verity/disk artifacts with `xz -T0` and
# appends .xz, matching the frozen §4 names exactly. Without --xz, the same
# base names are produced WITHOUT the .xz suffix -- this is a deliberate,
# intentionally-not-frozen fast path for local iteration and test fixtures
# (see test/native-publish-test.sh and native-ab-components-test.sh), not a
# second public contract. Only the --xz output is a valid §4 publication.
#
# NOT wired into PostOutputScripts=: see the "Why this is not wired into
# PostOutputScripts=" note near the bottom of this header block for why an
# automatic per-build invocation was rejected even though every individual
# permission concern (sfdisk root, OUTPUTDIR contents) checks out.
#
# Why this is not wired into PostOutputScripts=
# -----------------------------------------------
# docs/native-ab-contracts.md's own compression/copy step is meant to run
# once per PUBLICATION, not once per BUILD. PostOutputScripts= runs on every
# single `mkosi build` invocation -- every local dev iteration on cayo-ab,
# and every profile in the build-images.yml matrix (cayo-ab, snow-ab,
# snowfield-ab back to back on one runner). This script's job is to copy the
# multi-gigabyte root/root-verity/disk artifacts (5-23 GiB per product, see
# docs/native-ab-capacities.md) into a second location under $OUTPUTDIR
# before mkosi's own move step -- i.e. it would silently double per-build
# disk consumption on every build, published or not. That is exactly the
# failure mode recorded in CLAUDE.md/MEMORY.md as "CI Disk Exhaustion"
# (2026-06-03): intermittent build-images.yml failures from a full runner
# disk. sfdisk --json itself needs no root and is fast (verified: ~16ms
# against a real 16GB disk as an unprivileged user) -- the blocker is disk
# budget, not permissions. Kept manual + intended to run only in the (not
# yet built, Phase 7) protected publication/promotion job, which controls
# its own disk budget deliberately instead of inheriting every dev/CI
# build's.
set -euo pipefail

usage() {
    echo "Usage: $0 [--xz] <mkosi-output-dir> <profile-output-name> <dest-dir>" >&2
    exit 2
}

xz_enabled=0
if [[ "${1:-}" == "--xz" ]]; then
    xz_enabled=1
    shift
fi

[[ $# -eq 3 ]] || usage
OUTPUT_DIR="$1"
PROFILE_OUTPUT_NAME="$2"
DEST_DIR="$3"

for command in jq python3 sfdisk sha256sum git; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done
if [[ "$xz_enabled" == 1 ]]; then
    command -v xz >/dev/null || { echo "Error: --xz requested but xz not found" >&2; exit 1; }
fi

[[ -d "$OUTPUT_DIR" ]] || { echo "Error: mkosi output dir not found: $OUTPUT_DIR" >&2; exit 1; }
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

manifest_file="$OUTPUT_DIR/$PROFILE_OUTPUT_NAME.manifest"
[[ -f "$manifest_file" ]] || { echo "Error: manifest not found: $manifest_file" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Derive product/channel/version from the artifacts, and validate them
# against the frozen contract (docs/native-ab-contracts.md §1, §2).
# ---------------------------------------------------------------------------

product="$(jq -er '.config.name' "$manifest_file")"
version="$(jq -er '.config.version' "$manifest_file")"

version_regex='^[0-9]{14}$'
[[ "$version" =~ $version_regex ]] || {
    echo "Error: version '$version' from $manifest_file does not match the frozen grammar $version_regex (docs/native-ab-contracts.md §2)" >&2
    exit 1
}

channel="$PROFILE_OUTPUT_NAME"
expected_channel="${product}-ab"
[[ "$channel" == "$expected_channel" ]] || {
    echo "Error: profile-output-name '$channel' is not a publishable channel name; expected '$expected_channel' (<ImageId>-ab, docs/native-ab-contracts.md §1)." >&2
    echo "       Refusing to publish (this correctly rejects e.g. the cayo-ab-raw dev fixture, which must never be published)." >&2
    exit 1
}

echo "Product: $product  Channel: $channel  Version: $version"

# ---------------------------------------------------------------------------
# Locate mkosi's internal split outputs. These internal names (with the
# literal, un-substituted "@v" and the doubled ".raw.raw") are inputs only
# and are never copied out verbatim.
# ---------------------------------------------------------------------------

root_split="$OUTPUT_DIR/$PROFILE_OUTPUT_NAME.${product}_@v.root.raw.raw"
verity_split="$OUTPUT_DIR/$PROFILE_OUTPUT_NAME.${product}_@v.root-verity.raw.raw"
efi_file="$OUTPUT_DIR/$PROFILE_OUTPUT_NAME.efi"
disk_raw="$OUTPUT_DIR/$PROFILE_OUTPUT_NAME.raw"

for f in "$root_split" "$verity_split" "$efi_file" "$disk_raw"; do
    [[ -f "$f" ]] || { echo "Error: required mkosi split artifact not found: $f" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Extract root/root-verity PARTUUIDs from the built disk's GPT. sfdisk --json
# operates on a plain regular file -- no loop device, no root required.
# ---------------------------------------------------------------------------

gpt_json="$(sfdisk --json "$disk_raw")"

root_label="${product}_${version}_r"
verity_label="${product}_${version}_v"

root_partuuid="$(jq -er --arg label "$root_label" \
    '.partitiontable.partitions[] | select(.name == $label) | .uuid | ascii_downcase' <<<"$gpt_json")" ||
    { echo "Error: no partition named '$root_label' found in $disk_raw GPT" >&2; exit 1; }
verity_partuuid="$(jq -er --arg label "$verity_label" \
    '.partitiontable.partitions[] | select(.name == $label) | .uuid | ascii_downcase' <<<"$gpt_json")" ||
    { echo "Error: no partition named '$verity_label' found in $disk_raw GPT" >&2; exit 1; }

echo "root PARTUUID: $root_partuuid  verity PARTUUID: $verity_partuuid"

# ---------------------------------------------------------------------------
# Produce the frozen public names (docs/native-ab-contracts.md §4).
# ---------------------------------------------------------------------------

dest="$DEST_DIR/$product/x86-64"
mkdir -p "$dest"

xz_suffix=""
[[ "$xz_enabled" == 1 ]] && xz_suffix=".xz"

root_name="${channel}_${version}_${root_partuuid}.root.raw${xz_suffix}"
verity_name="${channel}_${version}_${verity_partuuid}.root-verity.raw${xz_suffix}"
efi_name="${channel}_${version}.efi"
disk_name="${channel}_${version}.disk.raw${xz_suffix}"
manifest_name="${channel}_${version}.manifest.json"

copy_or_compress() { # src dest
    local src="$1" dst="$2"
    if [[ "$xz_enabled" == 1 ]]; then
        xz -T0 -c "$src" > "$dst"
    else
        cp --sparse=always "$src" "$dst"
    fi
}

echo "Writing $dest/$root_name"
copy_or_compress "$root_split" "$dest/$root_name"
echo "Writing $dest/$verity_name"
copy_or_compress "$verity_split" "$dest/$verity_name"
echo "Writing $dest/$disk_name"
copy_or_compress "$disk_raw" "$dest/$disk_name"

echo "Writing $dest/$efi_name"
cp --sparse=always "$efi_file" "$dest/$efi_name"
echo "Writing $dest/$manifest_name"
cp "$manifest_file" "$dest/$manifest_name"

# ---------------------------------------------------------------------------
# SHA256SUMS -- unsigned. Signing (SHA256SUMS.gpg) is the Phase 7 protected
# promotion step (docs/native-ab-contracts.md §4, §7); this script only
# prepares candidate bytes.
# ---------------------------------------------------------------------------

sums_file="$dest/SHA256SUMS"
: > "$sums_file"
for name in "$root_name" "$verity_name" "$disk_name" "$efi_name" "$manifest_name"; do
    (cd "$dest" && sha256sum "$name") >> "$sums_file"
done
echo "Writing $sums_file (unsigned; signing is the Phase 7 promotion step)"

# ---------------------------------------------------------------------------
# publication-info.json -- small pipeline-consumption record.
# ---------------------------------------------------------------------------

source_commit="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse HEAD 2>/dev/null || echo unknown)"
generated_at="$(date -u +%FT%TZ)"

info_file="$dest/publication-info.json"
python3 - "$info_file" <<PYEOF
import json, os, sys

info_file = sys.argv[1]
dest = os.path.dirname(info_file)

def size(name):
    return os.path.getsize(os.path.join(dest, name))

data = {
    "product": "$product",
    "channel": "$channel",
    "version": "$version",
    "xz": bool($xz_enabled),
    "partuuids": {
        "root": "$root_partuuid",
        "verity": "$verity_partuuid",
    },
    "artifacts": {
        "root": {"name": "$root_name", "size": size("$root_name")},
        "root_verity": {"name": "$verity_name", "size": size("$verity_name")},
        "disk": {"name": "$disk_name", "size": size("$disk_name")},
        "efi": {"name": "$efi_name", "size": size("$efi_name")},
        "manifest": {"name": "$manifest_name", "size": size("$manifest_name")},
    },
    "source_commit": "$source_commit",
    "generated_at": "$generated_at",
}

with open(info_file, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF
echo "Writing $info_file"

echo "Native publication prepared: $dest"
