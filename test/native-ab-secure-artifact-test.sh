#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

# OUTPUT_NAME selects which built profile's artifacts to validate (e.g.
# cayo-ab, snow-ab, snowfield-ab); defaults to cayo-ab, the successor to the
# retired cayo-ab-secure spike profile.
output_name=${OUTPUT_NAME:-cayo-ab}
manifest=${1:-output/$output_name.manifest}
uki=${2:-output/$output_name.efi}
previous_certificate=${3:-}
primary_public_key=${4:-.snosi-private/pcr-signing.pub}
signature_mode=${5:-}

if [[ -n "$signature_mode" && "$signature_mode" != single ]]; then
    echo "Error: signature mode must be 'single' when specified" >&2
    exit 2
fi

for command in dpkg jq lsinitrd objcopy objdump; do
    command -v "$command" >/dev/null || {
        echo "Error: $command is required" >&2
        exit 1
    }
done
[[ -f "$manifest" ]] || { echo "Error: missing manifest: $manifest" >&2; exit 1; }
[[ -f "$uki" ]] || { echo "Error: missing UKI: $uki" >&2; exit 1; }

systemd_version=$(jq -er '.packages[] | select(.name == "systemd") | .version' "$manifest")
if ! dpkg --compare-versions "$systemd_version" ge 261; then
    echo "Error: secure image requires systemd 261 or newer, found $systemd_version" >&2
    exit 1
fi

packages=(
    libnss-myhostname libnss-mymachines libnss-systemd libpam-systemd
    libsystemd-shared libsystemd0 libudev1 systemd systemd-boot
    systemd-boot-efi systemd-boot-tools systemd-container systemd-cryptsetup
    systemd-repart systemd-resolved systemd-sysv systemd-timesyncd systemd-tpm
    udev
)
for package in "${packages[@]}"; do
    version=$(jq -er --arg package "$package" \
        '.packages[] | select(.name == $package) | .version' "$manifest")
    if [[ "$version" != "$systemd_version" ]]; then
        echo "Error: $package is $version, expected $systemd_version" >&2
        exit 1
    fi
done

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
initrd="$workdir/initrd"
listing="$workdir/initrd.list"
objcopy --dump-section ".initrd=$initrd" "$uki" "$workdir/uki.copy"
lsinitrd "$initrd" > "$listing"

grep -q 'usr/bin/systemd-cryptsetup$' "$listing"
grep -q 'libcryptsetup-token-systemd-tpm2\.so$' "$listing"
grep -q 'libsystemd-shared-261\.so$' "$listing"
grep -q 'libtss2-esys\.so' "$listing"
if grep -q 'libsystemd-shared-257\.so' "$listing"; then
    echo "Error: systemd 257 private library leaked into the secure initrd" >&2
    exit 1
fi

sections=$(objdump -h "$uki")
grep -q '[[:space:]]\.pcrpkey[[:space:]]' <<< "$sections"
grep -q '[[:space:]]\.pcrsig[[:space:]]' <<< "$sections"

if [[ -n "$previous_certificate" ]]; then
    for command in cmp cut openssl sha256sum; do
        command -v "$command" >/dev/null || {
            echo "Error: $command is required for dual-signature validation" >&2
            exit 1
        }
    done
    [[ -f "$previous_certificate" ]] || {
        echo "Error: missing previous PCR certificate: $previous_certificate" >&2
        exit 1
    }
    [[ -f "$primary_public_key" ]] || {
        echo "Error: missing primary PCR public key: $primary_public_key" >&2
        exit 1
    }

    pcrpkey="$workdir/pcrpkey"
    pcrsig="$workdir/pcrsig"
    objcopy --dump-section ".pcrpkey=$pcrpkey" --dump-section ".pcrsig=$pcrsig" \
        "$uki" "$workdir/uki-pcr.copy"
    cmp "$primary_public_key" "$pcrpkey"

    previous_fp=$(openssl x509 -in "$previous_certificate" -pubkey -noout | \
        openssl rsa -pubin -RSAPublicKey_out -outform DER 2>/dev/null | \
        sha256sum | cut -d' ' -f1)
    primary_fp=$(openssl rsa -pubin -in "$primary_public_key" \
        -RSAPublicKey_out -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
    jq -e --arg previous "$previous_fp" --arg primary "$primary_fp" '
        .sha256 as $signatures
        | ($signatures | length) == 8
        and (([$signatures[].pkfp] | unique | sort)
            == ([$previous, $primary] | sort))
        and (($signatures | group_by(.pol)) | length) == 4
        and all($signatures | group_by(.pol)[];
            length == 2
            and (([.[].pkfp] | unique | sort)
                == ([$previous, $primary] | sort)))
    ' "$pcrsig" >/dev/null
elif [[ "$signature_mode" == single ]]; then
    for command in cmp cut openssl sha256sum; do
        command -v "$command" >/dev/null || {
            echo "Error: $command is required for single-signature validation" >&2
            exit 1
        }
    done
    [[ -f "$primary_public_key" ]] || {
        echo "Error: missing primary PCR public key: $primary_public_key" >&2
        exit 1
    }

    pcrpkey="$workdir/pcrpkey"
    pcrsig="$workdir/pcrsig"
    objcopy --dump-section ".pcrpkey=$pcrpkey" --dump-section ".pcrsig=$pcrsig" \
        "$uki" "$workdir/uki-pcr.copy"
    cmp "$primary_public_key" "$pcrpkey"

    primary_fp=$(openssl rsa -pubin -in "$primary_public_key" \
        -RSAPublicKey_out -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
    jq -e --arg primary "$primary_fp" '
        .sha256 as $signatures
        | ($signatures | length) == 4
        and ([$signatures[].pol] | unique | length) == 4
        and all($signatures[]; .pkfp == $primary)
    ' "$pcrsig" >/dev/null
fi

echo "Native A/B secure artifact validation passed (systemd $systemd_version)"
