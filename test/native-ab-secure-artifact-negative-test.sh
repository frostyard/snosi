#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Ensure malformed dual-signature metadata is rejected by the artifact validator.
set -euo pipefail

# OUTPUT_NAME selects which built profile's artifacts to validate (e.g.
# cayo-ab, snow-ab, snowfield-ab); defaults to cayo-ab, the successor to the
# retired cayo-ab-secure spike profile.
output_name=${OUTPUT_NAME:-cayo-ab}
manifest=${1:-output/$output_name.manifest}
uki=${2:-output/$output_name.efi}
previous_certificate=${3:-.snosi-private/history/pcr-signing-N.crt}
primary_public_key=${4:-.snosi-private/pcr-signing.pub}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for command in jq objcopy openssl; do
    command -v "$command" >/dev/null || {
        echo "Error: $command is required" >&2
        exit 1
    }
done
for file in "$manifest" "$uki" "$previous_certificate" "$primary_public_key"; do
    [[ -f "$file" ]] || { echo "Error: required file not found: $file" >&2; exit 1; }
done

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
validator="$script_dir/native-ab-secure-artifact-test.sh"

expect_rejected() {
    local description=$1 candidate=$2
    if "$validator" "$manifest" "$candidate" "$previous_certificate" \
        "$primary_public_key" > "$workdir/validator.log" 2>&1; then
        echo "Error: validator accepted $description" >&2
        return 1
    fi
    echo "Rejected $description"
}

"$validator" "$manifest" "$uki" "$previous_certificate" "$primary_public_key"
objcopy --dump-section ".pcrsig=$workdir/pcrsig" "$uki" "$workdir/dump.efi"
jq '.sha256[0].pol = .sha256[1].pol' "$workdir/pcrsig" > "$workdir/pcrsig-unpaired"
cp "$uki" "$workdir/missing-signature.efi"
objcopy --update-section ".pcrsig=$workdir/pcrsig-unpaired" "$workdir/missing-signature.efi"
expect_rejected "a transition UKI with an unpaired PCR policy signature" \
    "$workdir/missing-signature.efi"

openssl x509 -in "$previous_certificate" -pubkey -noout > "$workdir/old.pub"
if cmp -s "$workdir/old.pub" "$primary_public_key"; then
    echo "Error: old and primary PCR public keys are identical" >&2
    exit 1
fi
cp "$uki" "$workdir/old-pcrpkey.efi"
objcopy --update-section ".pcrpkey=$workdir/old.pub" "$workdir/old-pcrpkey.efi"
expect_rejected "a transition UKI publishing the old PCR key" \
    "$workdir/old-pcrpkey.efi"

echo "Native A/B secure negative artifact validation passed"
