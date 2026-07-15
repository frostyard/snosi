#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Publication naming/staging for the network-installer ISO (docs/native-ab-
# contracts.md "Installer ISO", §5 "isos/native/v1/" namespace). Sibling of
# prepare-native-publication.sh (OS product artifacts): produces the same
# shape of "prepared directory" -- an unsigned SHA256SUMS plus a
# publication-info.json pipeline record -- so the existing candidate/verify/
# promote/withdraw pipeline (publish-candidate.sh, verify-remote.sh,
# promote.sh, withdraw.sh) works against an ISO publication run completely
# unchanged, driven only by publication-info.json's "dest_path" field
# ("isos/native/v1", a FLAT namespace -- no per-product/x86-64 subpath,
# unlike the OS artifact tree, since there is exactly one installer, not one
# per product).
#
# Unlike prepare-native-publication.sh, this does not derive anything from
# a built mkosi manifest: the ISO is assembled entirely outside mkosi by
# shared/native-installer/tools/build-iso.sh, which already enforces the
# frozen public name (snosi-native-installer_<version>_x86-64.iso) and
# stamps the version into the ISO itself -- this script just stages that
# already-correctly-named file (plus its SHA256SUMS) for the publication
# pipeline, the same "prepare, then candidate/verify/promote" split every
# other native artifact goes through.
#
# Usage: prepare-iso-publication.sh <iso-path> <version> <dest-dir>
#
#   iso-path  the built ISO, e.g. output/snosi-native-installer_<version>_
#             x86-64.iso (shared/native-installer/tools/build-iso.sh's
#             output). Its basename MUST already be the frozen public name
#             for the given version -- this script refuses to "publish" a
#             mis-named file rather than silently renaming it.
#   version   14-digit UTC YYYYMMDDHHMMSS (docs/native-ab-contracts.md §2),
#             must match the version embedded in iso-path's filename.
#   dest-dir  directory to write <files> into directly (no product/x86-64
#             subdirectory -- the ISO namespace is flat).
set -euo pipefail

usage() {
    echo "Usage: $0 <iso-path> <version> <dest-dir>" >&2
    exit 2
}
[[ $# -eq 3 ]] || usage

ISO_PATH="$1"
VERSION="$2"
DEST_DIR="$3"

for command in sha256sum git; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done

[[ -f "$ISO_PATH" ]] || { echo "Error: ISO not found: $ISO_PATH" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]{14}$ ]] || { echo "Error: version must be exactly 14 digits: $VERSION" >&2; exit 1; }

expected_name="snosi-native-installer_${VERSION}_x86-64.iso"
actual_name="$(basename "$ISO_PATH")"
[[ "$actual_name" == "$expected_name" ]] || {
    echo "Error: ISO filename '$actual_name' does not match the frozen public name '$expected_name' for version $VERSION (docs/native-ab-contracts.md \"Installer ISO\")" >&2
    exit 1
}

declare -a PENDING_TMPFILES=()
cleanup_tmpfiles() {
    local f
    for f in "${PENDING_TMPFILES[@]+"${PENDING_TMPFILES[@]}"}"; do
        [[ -n "$f" && -e "$f" ]] && rm -f "$f"
    done
}
trap cleanup_tmpfiles EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

new_tmpfile() {
    local dst="$1"
    NEW_TMPFILE="$(mktemp --suffix=.tmp "${dst}.XXXXXX")"
    PENDING_TMPFILES+=("$NEW_TMPFILE")
}
commit_tmpfile() {
    local tmp="$1" dst="$2" i
    mv -f "$tmp" "$dst"
    for i in "${!PENDING_TMPFILES[@]}"; do
        [[ "${PENDING_TMPFILES[$i]}" == "$tmp" ]] && unset 'PENDING_TMPFILES[i]'
    done
}

mkdir -p "$DEST_DIR"

echo "Writing $DEST_DIR/$expected_name"
new_tmpfile "$DEST_DIR/$expected_name"
iso_tmp="$NEW_TMPFILE"
cp --sparse=always "$ISO_PATH" "$iso_tmp"
commit_tmpfile "$iso_tmp" "$DEST_DIR/$expected_name"

sums_file="$DEST_DIR/SHA256SUMS"
new_tmpfile "$sums_file"
sums_tmp="$NEW_TMPFILE"
(cd "$DEST_DIR" && sha256sum "$expected_name") >"$sums_tmp"
commit_tmpfile "$sums_tmp" "$sums_file"
echo "Writing $sums_file (unsigned; signing is the Phase 7 promotion step)"

# product == channel == "snosi-native-installer" here (unlike the OS
# artifact pipeline, where product/channel differ, e.g. "cayo"/"cayo-ab"):
# there is exactly one installer, not one per product, and this value must
# equal the literal prefix of the frozen object name itself
# (snosi-native-installer_<version>_x86-64.iso) so promote.sh's outgoing-
# index archival step (which greps SHA256SUMS for "<channel>_<14-digit
# version>") can find this publication type's own entries.
source_commit="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse HEAD 2>/dev/null || echo unknown)"
generated_at="$(date -u +%FT%TZ)"
iso_size="$(stat -c %s "$DEST_DIR/$expected_name")"

info_file="$DEST_DIR/publication-info.json"
new_tmpfile "$info_file"
info_tmp="$NEW_TMPFILE"
cat >"$info_tmp" <<EOF
{
  "product": "snosi-native-installer",
  "channel": "snosi-native-installer",
  "version": "$VERSION",
  "dest_path": "isos/native/v1",
  "artifacts": {
    "iso": {"name": "$expected_name", "size": $iso_size}
  },
  "source_commit": "$source_commit",
  "generated_at": "$generated_at"
}
EOF
commit_tmpfile "$info_tmp" "$info_file"
echo "Writing $info_file"

echo "ISO publication prepared: $DEST_DIR"
