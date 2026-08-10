#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Assemble the pinned bootc-1.16.3 compatibility UKI. This is deliberately not
# an upstream-stable interface: buildah-package.sh supplies the OCI digest.
set -euo pipefail
umask 077

readonly EXPECTED_BOOTC_VERSION="1.16.3"
readonly CANDIDATE_UKIFY_MOK_KEY=/run/snosi-ukify-mok.key
readonly CANDIDATE_UKIFY_MOK_CERT=/run/snosi-ukify-mok.crt
readonly CANDIDATE_UKIFY_PCR_KEY=/run/snosi-ukify-pcr.key
readonly CANDIDATE_UKIFY_PREVIOUS_KEY=/run/snosi-ukify-previous-pcr.key
readonly CANDIDATE_UKIFY_WORK=/run/snosi-ukify-work
readonly CANDIDATE_UKIFY_LINUX="$CANDIDATE_UKIFY_WORK/linux"
readonly CANDIDATE_UKIFY_INITRD="$CANDIDATE_UKIFY_WORK/initrd"

die() { echo "Error: $*" >&2; exit 1; }
valid_digest() { [[ ${1:-} =~ ^[[:xdigit:]]{128}$ ]]; }

discover_kernel() { # rootfs
    local root=$1 path version
    local -a kernels=()
    shopt -s nullglob
    kernels=("$root"/usr/lib/modules/*)
    shopt -u nullglob
    [[ ${#kernels[@]} -eq 1 && -d ${kernels[0]:-} ]] || die "expected exactly one kernel under $root/usr/lib/modules"
    path=${kernels[0]}; version=${path##*/}
    [[ -f "$path/vmlinuz" && -f "$path/initramfs.img" ]] || die "kernel $version lacks vmlinuz or initramfs.img"
    printf '%s\t%s\t%s\n' "$version" "$path/vmlinuz" "$path/initramfs.img"
}

refuse_existing_uki() { # rootfs
    local root=$1
    local -a ukis=()
    shopt -s nullglob
    ukis=("$root"/boot/EFI/Linux/*.efi)
    shopt -u nullglob
    [[ ${#ukis[@]} -eq 0 ]] || die "pre-existing UKI refused"
}

validate_keypair() ( # private-key certificate description
    local key=$1 cert=$2 description=$3 work
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' RETURN
    [[ -f "$key" && -f "$cert" ]] || die "$description credentials must be regular files"
    openssl pkey -in "$key" -pubout -out "$work/key.pub" >/dev/null 2>&1 || die "invalid $description private key"
    openssl x509 -in "$cert" -pubkey -noout >"$work/cert.pub" 2>/dev/null || die "invalid $description certificate"
    cmp -s "$work/key.pub" "$work/cert.pub" || die "$description private key does not match certificate"
)

validate_pcr_key() ( # private-key public-key
    local key=$1 public=$2 work
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' RETURN
    [[ -f "$key" && -f "$public" ]] || die "PCR credentials must be regular files"
    openssl pkey -in "$key" -pubout -out "$work/key.pub" >/dev/null 2>&1 || die "invalid PCR private key"
    openssl pkey -pubin -in "$public" -pubout -out "$work/public.pub" >/dev/null 2>&1 || die "invalid PCR public key"
    cmp -s "$work/key.pub" "$work/public.pub" || die "PCR private key does not match public key"
    openssl pkey -in "$1" -text -noout 2>/dev/null | grep -q 'Private-Key: (2048 bit' || die "PCR key must be RSA-2048"
)

validate_root_contract() { # rootfs
    local root=$1 contract
    contract="$root/usr/lib/snosi/bootc-secure.json"
    [[ -f "$contract" ]] || die "missing bootc secure rootfs contract"
    jq -e '.schema == 1 and .mok_certificate == "/usr/lib/snosi/mok.crt" and .pcr_public_key == "/usr/lib/snosi/pcr-signing.pub" and .encrypted_root_mapper == "root" and .systemd_suite == "forky" and ((has("assembly") | not) or .assembly == {compatibility: "bootc-1.16.3-storage-digest-v1", bootc_version: "1.16.3", storage_digest_command: "bootc container compute-composefs-digest-from-storage", ukify: "direct-two-pass"})' "$contract" >/dev/null || die "unexpected bootc secure rootfs contract"
}

# The gate tracks only caller-owned private keys. Generic PEM scans reject
# harmless package examples and cannot prove that the protected keys are absent.
credential_gate_init() { # gate private-key [private-key...]
    local gate=$1 key fingerprint raw_fingerprint size
    shift
    : >"$gate/fingerprints"
    : >"$gate/raw-fingerprints"
    for key in "$@"; do
        [[ -n "$key" ]] || continue
        fingerprint=$(openssl pkey -in "$key" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
        printf '%s\n' "$fingerprint" >>"$gate/fingerprints"
        size=$(stat -c '%s' "$key")
        raw_fingerprint=$(sha256sum "$key" | cut -d' ' -f1)
        printf '%s\t%s\n' "$size" "$raw_fingerprint" >>"$gate/raw-fingerprints"
        printf '%s\n' "$key" >>"$gate/paths"
    done
}

credential_gate_has_fingerprint() { # gate fingerprint
    grep -Fqx -- "$2" "$1/fingerprints"
}

credential_gate_check_pem() { # gate surface location PEM-on-stdin
    local gate=$1 surface=$2 location=$3 fingerprint
    fingerprint=$(openssl pkey -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1) || return 0
    credential_gate_has_fingerprint "$gate" "$fingerprint" || return 0
    die "caller-owned credential found in $surface: $location"
}

credential_gate_scan_stream() { # gate surface location; content on stdin
    local gate=$1 surface=$2 location=$3 line block="" in_key=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $in_key -eq 0 && $line =~ ^-----BEGIN\ ([A-Z]+\ )*PRIVATE\ KEY-----$ ]]; then
            block="$line"$'\n'; in_key=1
        elif [[ $in_key -eq 1 ]]; then
            block+="$line"$'\n'
            if [[ $line =~ ^-----END\ ([A-Z]+\ )*PRIVATE\ KEY-----$ ]]; then
                printf '%s' "$block" | credential_gate_check_pem "$gate" "$surface" "$location" || return 1
                block=""; in_key=0
            fi
        fi
    done
}

credential_gate_scan_file() { # gate surface display-path file
    local gate=$1 surface=$2 location=$3 file=$4 fingerprint
    fingerprint=$(openssl pkey -in "$file" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1) || fingerprint=""
    if [[ -n "$fingerprint" ]] && credential_gate_has_fingerprint "$gate" "$fingerprint"; then
        die "caller-owned credential found in $surface: $location"
    fi
    credential_gate_scan_stream "$gate" "$surface" "$location" <"$file"
}

credential_gate_scan_tree() { # gate surface tree
    local gate=$1 surface=$2 tree=$3 file size raw_fingerprint fingerprint
    # Exact raw copies are found in bulk by size and digest. Canonical parsing
    # below is limited to PEM candidates, avoiding an OpenSSL process for every
    # package file while still detecting re-encoded caller-owned credentials.
    while IFS=$'\t' read -r size raw_fingerprint; do
        while IFS= read -r -d '' file; do
            fingerprint=$(sha256sum "$file" | cut -d' ' -f1)
            [[ $fingerprint == "$raw_fingerprint" ]] || continue
            die "caller-owned credential found in $surface: ${file#"$tree"/}"
        done < <(find "$tree" -type f -size "${size}c" -print0)
    done <"$gate/raw-fingerprints"
    # PEM private keys are small. Large exact copies are already covered by the
    # raw-size/digest pass, so avoid reading kernel and image payloads as text.
    while IFS= read -r -d '' file; do
        grep -aEq '^-----BEGIN ([A-Z]+ )*PRIVATE KEY-----$' "$file" || continue
        credential_gate_scan_file "$gate" "$surface" "${file#"$tree"/}" "$file" || return 1
    done < <(find "$tree" -type f -size -1025k -print0)
}

credential_gate_scan_image() ( # gate OCI-image
    local gate=$1 image=$2 container mountpoint
    container=""; mountpoint=""
    trap '[[ -z "$mountpoint" ]] || buildah umount "$container" >/dev/null 2>&1; [[ -z "$container" ]] || buildah rm "$container" >/dev/null 2>&1' EXIT
    # jq restores escaped OCI label/config strings only in a pipe; no secret is
    # written to disk and the scanner reports only the image reference.
    buildah inspect --type image "$image" | jq -r '.. | strings?' |
        credential_gate_scan_stream "$gate" "OCI config or labels" "$image" || return 1
    container=$(buildah from "$image")
    mountpoint=$(buildah mount "$container")
    credential_gate_scan_tree "$gate" "mounted OCI filesystem" "$mountpoint"
)

redact_credentials() { # private-key [private-key...]; input/output stream
    local key line in_key=0
    local -a keys=("$@")
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $in_key -eq 1 ]]; then
            [[ $line =~ ^-----END\ ([A-Z]+\ )*PRIVATE\ KEY-----$ ]] && in_key=0
            continue
        fi
        if [[ $line =~ ^-----BEGIN\ ([A-Z]+\ )*PRIVATE\ KEY-----$ ]]; then
            printf '%s\n' '[redacted credential value]'
            in_key=1
            continue
        fi
        for key in "${keys[@]}"; do
            [[ -n "$key" ]] || continue
            line=${line//"$key"/[redacted credential path]}
        done
        printf '%s\n' "$line"
    done
}

pcr_fingerprint() { openssl rsa -pubin -in "$1" -RSAPublicKey_out -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1; }

validate_pcrsig() { # json primary-public [previous-public]
    local json=$1 primary=$2 previous=${3:-} primary_fp previous_fp count
    primary_fp=$(pcr_fingerprint "$primary")
    previous_fp=""
    [[ -z "$previous" ]] || previous_fp=$(pcr_fingerprint "$previous")
    count=4; [[ -z "$previous" ]] || count=8
    jq -e --arg primary "$primary_fp" --arg previous "$previous_fp" --argjson count "$count" '
        .sha256 as $s | ($s | type == "array" and length == $count)
        and (($s | group_by(.pol) | map(length) | all(. == (if $previous == "" then 1 else 2 end))))
        and all($s[]; (.pkfp == $primary or (.pkfp == $previous and $previous != "")))
        and (if $previous == "" then true else all($s | group_by(.pol)[]; ([.[].pkfp] | sort) == ([$primary, $previous] | sort)) end)
    ' "$json" >/dev/null || die "PCR signature set does not match the requested signer mode"
}

validate_uki() ( # uki kernel initrd MOK-cert primary-pub digest [previous-pub]
    local uki=$1 kernel=$2 initrd=$3 mok=$4 primary=$5 digest=$6 previous=${7:-} work cmdline section count sections
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' RETURN
    sections=$(objdump -h "$uki") || die "UKI section table is unreadable"
    for section in .cmdline .linux .initrd .pcrpkey .pcrsig; do
        count=$(awk -v wanted="$section" '$2 == wanted { count++ } END { print count + 0 }' <<<"$sections")
        [[ $count -eq 1 ]] || die "UKI must contain exactly one $section section"
    done
    objcopy --dump-section ".cmdline=$work/cmdline" --dump-section ".linux=$work/linux" \
        --dump-section ".initrd=$work/initrd" --dump-section ".pcrpkey=$work/pcrpkey" \
        --dump-section ".pcrsig=$work/pcrsig" "$uki" "$work/copy.efi" >/dev/null 2>&1 || die "UKI lacks required trusted sections"
    cmp -s "$kernel" "$work/linux" || die "UKI kernel section mismatch"
    cmp -s "$initrd" "$work/initrd" || die "UKI initrd section mismatch"
    cmp -s "$primary" "$work/pcrpkey" || die "UKI PCR public-key section mismatch"
    cmdline=$(tr '\0' ' ' <"$work/cmdline")
    [[ "$cmdline" == "rw composefs=?$digest" ]] || die "UKI command line is not the pinned composefs-only shape"
    validate_pcrsig "$work/pcrsig" "$work/pcrpkey" "$previous"
    sbverify --cert "$mok" "$uki" >/dev/null || die "UKI MOK Authenticode signature failed"
)

prepare_systemd_boot_source() { # rootfs mok-key mok-cert
    local root=$1 mok_key=$2 mok_cert=$3 loader out
    for loader in "$root/boot/EFI/systemd/systemd-bootx64.efi" "$root/usr/lib/systemd/boot/efi/systemd-bootx64.efi"; do
        [[ -f "$loader" ]] && break
    done
    [[ -f ${loader:-} ]] || die "systemd-boot EFI binary is unavailable"
    # This source is present before the first OCI digest is calculated. The
    # runtime reconciler cannot use /boot because the ESP can shadow it.
    out="$root/usr/lib/snosi/bootc/systemd-bootx64.efi"
    [[ ! -e "$out" ]] || die "pre-existing immutable systemd-boot source refused"
    mkdir -p "$(dirname "$out")"
    sbsign --key "$mok_key" --cert "$mok_cert" --output "$out" "$loader" >/dev/null
    sbverify --cert "$mok_cert" "$out" >/dev/null || die "systemd-boot MOK signature failed"
}

sign_systemd_boot() { # rootfs mok-cert
    local root=$1 mok_cert=$2 source out
    source="$root/usr/lib/snosi/bootc/systemd-bootx64.efi"
    out="$root/boot/EFI/BOOT/grubx64.efi"
    [[ -f "$source" ]] || die "immutable signed systemd-boot source is unavailable"
    [[ ! -e "$out" ]] || die "pre-existing signed systemd-boot refused"
    sbverify --cert "$mok_cert" "$source" >/dev/null || die "immutable systemd-boot source MOK signature failed"
    mkdir -p "$(dirname "$out")"
    install -m 0644 "$source" "$out"
    sbverify --cert "$mok_cert" "$out" >/dev/null || die "systemd-boot MOK signature failed"
}

common_credential_owner() { # credential [credential...]
    local owner file file_owner
    owner=$(stat -c '%u:%g' "$1") || die "cannot stat candidate credential"
    for file in "$@"; do
        [[ -n $file ]] || continue
        file_owner=$(stat -c '%u:%g' "$file") || die "cannot stat candidate credential"
        [[ $file_owner == "$owner" ]] || die "candidate credential owners differ"
    done
    printf '%s\n' "$owner"
}

run_candidate_ukify() { # image work log mok-key mok-cert pcr-key previous-key -- ukify-args...
    local image=$1 work=$2 log=$3 mok_key=$4 mok_cert=$5 pcr_key=$6 previous_key=$7 status owner
    local -a podman_args pipeline_status
    [[ -n $image ]] || die "candidate ukify image is missing"
    shift 7
    [[ ${1:-} == -- ]] || die "candidate ukify argument separator is missing"
    shift
    if ! owner=$(common_credential_owner "$mok_key" "$mok_cert" "$pcr_key" "$previous_key"); then
        die "candidate credential owner validation failed"
    fi
    chown "$owner" "$work" || die "cannot set candidate ukify work owner"

    podman_args=(run --rm --network=none --cap-drop=all --user "$owner"
        --security-opt label=type:unconfined_t
        --entrypoint=/usr/bin/ukify
        --volume "$mok_key:$CANDIDATE_UKIFY_MOK_KEY:ro"
        --volume "$mok_cert:$CANDIDATE_UKIFY_MOK_CERT:ro"
        --volume "$pcr_key:$CANDIDATE_UKIFY_PCR_KEY:ro"
        --volume "$work:$CANDIDATE_UKIFY_WORK:rw")
    [[ -z $previous_key ]] || podman_args+=(
        --volume "$previous_key:$CANDIDATE_UKIFY_PREVIOUS_KEY:ro")

    podman "${podman_args[@]}" "$image" "$@" 2>&1 |
        redact_credentials "$mok_key" "$pcr_key" "$previous_key" \
            "$CANDIDATE_UKIFY_MOK_KEY" "$CANDIDATE_UKIFY_PCR_KEY" \
            "$CANDIDATE_UKIFY_PREVIOUS_KEY" |
        tee "$log" >&2
    pipeline_status=("${PIPESTATUS[@]}")
    status=${pipeline_status[0]}
    [[ $status -eq 0 ]] || return "$status"
    [[ ${pipeline_status[1]} -eq 0 && ${pipeline_status[2]} -eq 0 ]] || {
        echo "Error: candidate ukify diagnostics could not be retained" >&2
        return 1
    }
    [[ -s $work/uki.efi ]] || {
        echo "Error: candidate ukify produced no UKI" >&2
        return 1
    }
}

rootfs_image_path() { # rootfs host-path
    local root input_root=${1%/} input=$2 relative current component candidate target path links=0
    root=$(realpath -e "$1") || die "rootfs path cannot be resolved: $1"
    if [[ $input == "$root/"* ]]; then
        relative=${input#"$root/"}
    elif [[ $input == "$input_root/"* ]]; then
        relative=${input#"$input_root/"}
    else
        die "path is outside rootfs: $input"
    fi
    current=$root
    while [[ -n $relative ]]; do
        component=${relative%%/*}
        if [[ $relative == */* ]]; then relative=${relative#*/}; else relative=""; fi
        [[ -z $component || $component == . ]] && continue
        if [[ $component == .. ]]; then
            current=$(dirname "$current")
            continue
        fi
        candidate="$current/$component"
        if [[ -L $candidate ]]; then
            target=$(readlink "$candidate")
            links=$((links + 1)); [[ $links -le 40 ]] || die "too many rootfs symlinks"
            if [[ $target == /* ]]; then
                current=$root
                target=${target#/}
            else
                current=$(dirname "$candidate")
            fi
            relative="$target${relative:+/$relative}"
        else
            current=$candidate
        fi
    done
    path=$(realpath -e "$current") || die "rootfs path cannot be resolved: $input"
    [[ $path == "$root/"* ]] || die "path is outside rootfs: $path"
    relative=${path#"$root/"}
    printf '/%s\n' "$relative"
}

rootfs_source_path() { # rootfs discovered-host-path
    local root=$1 source=$2 canonical_root image_path
    canonical_root=$(realpath -e "$root") || die "rootfs path cannot be resolved: $root"
    image_path=$(rootfs_image_path "$root" "$source")
    printf '%s%s\n' "$canonical_root" "$image_path"
}

stage_public_kernel_inputs() { # rootfs kernel initrd work-directory
    local root=$1 kernel=$2 initrd=$3 work=$4 source_kernel source_initrd
    source_kernel=$(rootfs_source_path "$root" "$kernel")
    source_initrd=$(rootfs_source_path "$root" "$initrd")
    [[ -f "$source_kernel" && -f "$source_initrd" ]] || die "canonical kernel inputs must be regular files"
    install -m 0644 "$source_kernel" "$work/linux"
    install -m 0644 "$source_initrd" "$work/initrd"
    cmp -s "$source_kernel" "$work/linux" || die "staged kernel differs from canonical rootfs source"
    cmp -s "$source_initrd" "$work/initrd" || die "staged initrd differs from canonical rootfs source"
}

verify_exposed_kernel_inputs() { # rootfs kernel initrd work-directory
    local root=$1 kernel=$2 initrd=$3 work=$4 source_kernel source_initrd
    source_kernel=$(rootfs_source_path "$root" "$kernel")
    source_initrd=$(rootfs_source_path "$root" "$initrd")
    cmp -s "$source_kernel" "$work/linux" || die "candidate changed staged kernel input"
    cmp -s "$source_initrd" "$work/initrd" || die "candidate changed staged initrd input"
}

verify_exposed_pcr_public_keys() { # active-public work-directory [previous-public]
    local active=$1 work=$2 previous=${3:-}
    cmp -s "$active" "$work/pcr.pub" || die "candidate changed active PCR public key"
    [[ -z $previous ]] || cmp -s "$previous" "$work/previous.pub" ||
        die "candidate changed previous PCR public key"
}

candidate_ukify_args() { # rootfs kernel initrd digest version previous-key output-array
    local root=$1 kernel=$2 initrd=$3 digest=$4 version=$5 previous_key=$6 output_name=$7
    local -n output="$output_name"
    rootfs_image_path "$root" "$kernel" >/dev/null
    rootfs_image_path "$root" "$initrd" >/dev/null
    output=(build --linux "$CANDIDATE_UKIFY_LINUX" --initrd "$CANDIDATE_UKIFY_INITRD"
        --os-release @/usr/lib/os-release --cmdline "rw composefs=?$digest"
        --uname "$version" --pcr-private-key "$CANDIDATE_UKIFY_PCR_KEY"
        --secureboot-private-key "$CANDIDATE_UKIFY_MOK_KEY"
        --secureboot-certificate "$CANDIDATE_UKIFY_MOK_CERT" --measure
        --output "$CANDIDATE_UKIFY_WORK/uki.efi")
    if [[ -n "$previous_key" ]]; then
        output+=(--pcr-private-key "$CANDIDATE_UKIFY_PREVIOUS_KEY"
            --pcrpkey "$CANDIDATE_UKIFY_WORK/pcr.pub"
            --phases "enter-initrd,enter-initrd:leave-initrd,enter-initrd:leave-initrd:sysinit,enter-initrd:leave-initrd:sysinit:ready"
            --phases "enter-initrd,enter-initrd:leave-initrd,enter-initrd:leave-initrd:sysinit,enter-initrd:leave-initrd:sysinit:ready")
    else
        output+=(--pcrpkey "$CANDIDATE_UKIFY_WORK/pcr.pub")
    fi
}

assemble() { # rootfs mok-key mok-cert pcr-key pcr-cert [previous-pcr-cert]
    local root=$1 mok_key=$2 mok_cert=$3 pcr_key=$4 pcr_cert=$5 previous_cert=${6:-}
    local previous_key=${SNOSI_BOOTC_PREVIOUS_PCR_KEY:-} digest kernel_info version kernel initrd canonical_kernel canonical_initrd work gate primary_public previous_public uki ukify_status ukify_image
    local -a ukify_args
    [[ -d "$root" ]] || die "rootfs directory is missing"
    validate_keypair "$mok_key" "$mok_cert" "MOK"
    validate_pcr_key "$pcr_key" "$pcr_cert"
    if [[ -n "$previous_cert" ]]; then
        [[ -n "$previous_key" ]] || die "dual-PCR mode requires SNOSI_BOOTC_PREVIOUS_PCR_KEY"
        validate_pcr_key "$previous_key" "$previous_cert"
    elif [[ -n "$previous_key" ]]; then
        die "SNOSI_BOOTC_PREVIOUS_PCR_KEY requires PREVIOUS_PCR_CERT"
    fi
    gate=$(mktemp -d)
    work=""
    trap 'rm -rf -- "$gate"; [[ -z "$work" ]] || rm -rf -- "$work"' RETURN
    credential_gate_init "$gate" "$mok_key" "$pcr_key" "$previous_key"
    digest=${SNOSI_BOOTC_SECURE_COMPOSEFS_DIGEST:-}
    valid_digest "$digest" || die "missing or invalid pre-injection OCI composefs digest"
    [[ ${SNOSI_BOOTC_SECURE_BOOTC_VERSION:-} == "$EXPECTED_BOOTC_VERSION" ]] || die "assembly requires pinned bootc $EXPECTED_BOOTC_VERSION"
    validate_root_contract "$root"
    credential_gate_scan_tree "$gate" rootfs "$root"
    refuse_existing_uki "$root"
    kernel_info=$(discover_kernel "$root")
    IFS=$'\t' read -r version kernel initrd <<<"$kernel_info"
    canonical_kernel=$(rootfs_source_path "$root" "$kernel")
    canonical_initrd=$(rootfs_source_path "$root" "$initrd")
    ukify_image=${SNOSI_BOOTC_SECURE_UKIFY_IMAGE:-}
    [[ -n $ukify_image ]] || die "missing first-pass candidate image for ukify"
    work=$(mktemp -d)
    openssl pkey -in "$pcr_key" -pubout -out "$gate/pcr.pub" >/dev/null
    primary_public="$gate/pcr.pub"; previous_public=""
    install -m 0644 "$primary_public" "$work/pcr.pub"
    if [[ -n "$previous_cert" ]]; then
        openssl pkey -pubin -in "$previous_cert" -pubout -out "$gate/previous.pub"
        previous_public="$gate/previous.pub"
        install -m 0644 "$previous_public" "$work/previous.pub"
    fi
    stage_public_kernel_inputs "$root" "$kernel" "$initrd" "$work"
    candidate_ukify_args "$root" "$kernel" "$initrd" "$digest" "$version" "$previous_key" ukify_args
    credential_gate_scan_tree "$gate" "ukify work directory before candidate execution" "$work"
    set +e
    run_candidate_ukify "$ukify_image" "$work" "$work/ukify.log" \
        "$mok_key" "$mok_cert" "$pcr_key" "$previous_key" -- \
        "${ukify_args[@]}"
    ukify_status=$?
    set -e
    [[ $ukify_status -eq 0 ]] || die "ukify failed"
    verify_exposed_kernel_inputs "$root" "$kernel" "$initrd" "$work"
    verify_exposed_pcr_public_keys "$primary_public" "$work" "$previous_public"
    credential_gate_scan_tree "$gate" "ukify work directory after candidate execution" "$work"
    credential_gate_scan_file "$gate" "sanitized ukify log" ukify.log "$work/ukify.log"
    uki="$root/boot/EFI/Linux/$version.efi"
    mkdir -p "$(dirname "$uki")"
    install -m 0644 "$work/uki.efi" "$uki"
    sign_systemd_boot "$root" "$mok_cert"
    validate_uki "$uki" "$canonical_kernel" "$canonical_initrd" "$mok_cert" "$primary_public" "$digest" "$previous_public"
    credential_gate_scan_tree "$gate" rootfs "$root"
}

remove_injected() { # rootfs
    local root=$1 kernel_info version
    kernel_info=$(discover_kernel "$root")
    IFS=$'\t' read -r version _ <<<"$kernel_info"
    rm -f -- "$root/boot/EFI/Linux/$version.efi" "$root/boot/EFI/BOOT/grubx64.efi" \
        "$root/usr/lib/snosi/bootc/systemd-bootx64.efi"
}

candidate_ukify_self_test() (
    local top root work key cert pcr log args mok_mount cert_mount pcr_mount work_mount empty_args status
    local -a fixture_args expected_args
    top=$(mktemp -d); trap 'rm -rf -- "$top"' RETURN
    root="$top/root"; work="$top/work-single"; log="$work/ukify.log"; args="$top/podman.args"
    mkdir -p "$root/usr/lib/modules/one" "$work" "$top/bin"
    touch "$root/usr/lib/modules/one/vmlinuz" "$root/usr/lib/modules/one/initramfs.img"
    key="$top/mok.key"; cert="$top/mok.crt"; pcr="$top/pcr.key"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$key" >/dev/null 2>&1
    openssl req -new -x509 -key "$key" -subj /CN=mok -days 1 -out "$cert" >/dev/null 2>&1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$pcr" >/dev/null 2>&1
    openssl pkey -in "$pcr" -pubout -out "$work/pcr.pub" >/dev/null
    cat >"$top/bin/stat" <<'EOF'
#!/bin/bash
if [[ ${3:-} == "$CANDIDATE_UKIFY_TEST_MISMATCH" ]]; then printf '999:999\n'; else /usr/bin/stat "$@"; fi
EOF
    chmod +x "$top/bin/stat"
    if (PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_MISMATCH="$pcr" common_credential_owner "$key" "$cert" "$pcr") >/dev/null 2>&1; then
        die "candidate unequal credential owners accepted"
    fi
    candidate_ukify_args "$root" "$root/usr/lib/modules/one/vmlinuz" "$root/usr/lib/modules/one/initramfs.img" \
        fixture one "" fixture_args
    expected_args=(build --linux /run/snosi-ukify-work/linux --initrd /run/snosi-ukify-work/initrd
        --os-release @/usr/lib/os-release --cmdline 'rw composefs=?fixture' --uname one
        --pcr-private-key "$CANDIDATE_UKIFY_PCR_KEY" --secureboot-private-key "$CANDIDATE_UKIFY_MOK_KEY"
        --secureboot-certificate "$CANDIDATE_UKIFY_MOK_CERT" --measure --output "$CANDIDATE_UKIFY_WORK/uki.efi"
        --pcrpkey "$CANDIDATE_UKIFY_WORK/pcr.pub")
    [[ ${#fixture_args[@]} -eq ${#expected_args[@]} ]] || die "candidate ukify arguments have an unexpected length"
    for index in "${!expected_args[@]}"; do
        [[ ${fixture_args[index]} == "${expected_args[index]}" ]] || die "candidate ukify argument translation is incorrect"
    done
    cat >"$top/bin/podman" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" >"$CANDIDATE_UKIFY_TEST_ARGS"
expected=(run --rm --network=none --cap-drop=all --user "$(id -u):$(id -g)" --security-opt label=type:unconfined_t --entrypoint=/usr/bin/ukify)
for expected_arg in "${expected[@]}"; do
    [[ ${1:-} == "$expected_arg" ]] || exit 87
    shift
done
for target in /run/snosi-ukify-mok.key:ro /run/snosi-ukify-mok.crt:ro /run/snosi-ukify-pcr.key:ro /run/snosi-ukify-work:rw; do
    [[ ${1:-} == --volume && ${2:-} == *:"$target" ]] || exit 89
    [[ $target != /run/snosi-ukify-work:rw ]] || host_work=${2%:/run/snosi-ukify-work:rw}
    shift 2
done
if [[ ${1:-} == --volume ]]; then
    [[ ${2:-} == *:/run/snosi-ukify-previous-pcr.key:ro ]] || exit 90
    shift 2
fi
[[ ${1:-} == localhost/snosi-bootc-secure-first-fixture ]] || exit 91
[[ -n ${host_work:-} ]] || exit 88
[[ $(/usr/bin/stat -c '%u:%g' "$host_work") == "$(id -u):$(id -g)" ]] || exit 92
if [[ ${CANDIDATE_UKIFY_TEST_PODMAN_UNAVAILABLE:-0} == 1 ]]; then
    echo 'candidate ukify image is unavailable' >&2
    exit 127
fi
if [[ ${CANDIDATE_UKIFY_TEST_FAIL:-0} == 1 ]]; then
    echo "candidate ukify failed at /run/snosi-ukify-pcr.key" >&2
    exit 86
fi
if [[ ${CANDIDATE_UKIFY_TEST_OVERWRITE_ACTIVE_PUB:-0} == 1 ]]; then
    printf 'candidate-mutated-active-public-key\n' >"$host_work/pcr.pub"
fi
if [[ ${CANDIDATE_UKIFY_TEST_OVERWRITE_PREVIOUS_PUB:-0} == 1 ]]; then
    printf 'candidate-mutated-previous-public-key\n' >"$host_work/previous.pub"
fi
if [[ ${CANDIDATE_UKIFY_TEST_OVERWRITE_LINUX:-0} == 1 ]]; then
    printf 'candidate-mutated-linux\n' >"$host_work/linux"
fi
if [[ ${CANDIDATE_UKIFY_TEST_OVERWRITE_INITRD:-0} == 1 ]]; then
    printf 'candidate-mutated-initrd\n' >"$host_work/initrd"
fi
if [[ ${CANDIDATE_UKIFY_TEST_NO_OUTPUT:-0} != 1 ]]; then
    if [[ ${CANDIDATE_UKIFY_TEST_EMPTY_OUTPUT:-0} == 1 ]]; then
        : >"$host_work/uki.efi"
    else
        printf 'fixture uki\n' >"$host_work/uki.efi"
    fi
fi
printf 'safe diagnostic; key path %s\n' /run/snosi-ukify-pcr.key >&2
cat "$CANDIDATE_UKIFY_TEST_PRIVATE_KEY" >&2
EOF
    chmod +x "$top/bin/podman"
    local mismatch_work="$top/work-owner-mismatch" mismatch_output mismatch_owner
    mkdir "$mismatch_work"
    mismatch_owner=$(/usr/bin/stat -c '%u:%g' "$mismatch_work")
    set +e
    mismatch_output=$(PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_MISMATCH="$pcr" \
        CANDIDATE_UKIFY_TEST_ARGS="$top/podman-owner-mismatch.args" CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" \
        run_candidate_ukify localhost/snosi-bootc-secure-first-fixture "$mismatch_work" \
        "$mismatch_work/ukify.log" "$key" "$cert" "$pcr" "" -- build 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 ]] || die "candidate unequal credential owners reached Podman"
    grep -Fq -- 'candidate credential owner validation failed' <<<"$mismatch_output" ||
        die "candidate unequal credential owners lacked validation diagnostic"
    [[ $(/usr/bin/stat -c '%u:%g' "$mismatch_work") == "$mismatch_owner" ]] ||
        die "candidate unequal credential owners changed work ownership"
    [[ ! -e "$top/podman-owner-mismatch.args" ]] ||
        die "candidate unequal credential owners invoked Podman"
    empty_args="$top/podman-empty.args"
    if (PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_ARGS="$empty_args" CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" \
        run_candidate_ukify "" "$work" "$top/empty.log" "$key" "$cert" "$pcr" "" -- build) >"$top/empty-output" 2>&1; then
        die "candidate ukify accepted an empty image"
    fi
    [[ ! -e "$empty_args" ]] || die "candidate ukify ran Podman without an image"
    grep -Fq -- 'candidate ukify image is missing' "$top/empty-output" || die "candidate ukify empty-image diagnostic is missing"
    local unavailable_work="$top/work-podman-unavailable" unavailable_log="$top/podman-unavailable.log"
    mkdir "$unavailable_work"
    set +e
    PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_ARGS="$top/podman-unavailable.args" CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" \
        CANDIDATE_UKIFY_TEST_PODMAN_UNAVAILABLE=1 \
        run_candidate_ukify localhost/snosi-bootc-secure-first-fixture "$unavailable_work" "$unavailable_log" "$key" "$cert" "$pcr" "" -- build
    status=$?
    set -e
    [[ $status -eq 127 ]] || die "candidate ukify did not propagate unavailable Podman status"
    grep -Fq -- 'candidate ukify image is unavailable' "$unavailable_log" || die "candidate ukify unavailable diagnostic was not retained"
    PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_ARGS="$args" CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" \
        run_candidate_ukify localhost/snosi-bootc-secure-first-fixture "$work" "$log" "$key" "$cert" "$pcr" "" -- \
        "${fixture_args[@]}"
    mok_mount="$key:/run/snosi-ukify-mok.key:ro"; cert_mount="$cert:/run/snosi-ukify-mok.crt:ro"
    pcr_mount="$pcr:/run/snosi-ukify-pcr.key:ro"; work_mount="$work:/run/snosi-ukify-work:rw"
    if ! grep -Fqx -- localhost/snosi-bootc-secure-first-fixture "$args" || ! grep -Fqx -- "$mok_mount" "$args" ||
        ! grep -Fqx -- "$cert_mount" "$args" || ! grep -Fqx -- "$pcr_mount" "$args" || ! grep -Fqx -- "$work_mount" "$args"; then
        die "candidate ukify single-key mounts are incorrect"
    fi
    ! grep -q -- snosi-ukify-previous-pcr.key "$args" || die "candidate ukify mounted previous key in single-key mode"
    local seen_image=0 podman_arg
    local writable_mounts=0
    while IFS= read -r podman_arg; do
        [[ $seen_image -eq 0 || ( $podman_arg != "$root"* && $podman_arg != "$work"* ) ]] ||
            die "candidate ukify passed a host rootfs or work path"
        [[ $podman_arg == localhost/snosi-bootc-secure-first-fixture ]] && seen_image=1
        [[ $podman_arg == *:rw ]] && writable_mounts=$((writable_mounts + 1))
    done <"$args"
    [[ $writable_mounts -eq 1 ]] || die "candidate ukify has more than one writable mount"
    [[ -s "$work/uki.efi" ]] || die "candidate ukify fixture produced no UKI"
    if ! grep -Fq -- 'safe diagnostic' "$log" || grep -Fq -- "$pcr" "$log" ||
        grep -Fq -- /run/snosi-ukify-pcr.key "$log" || grep -Fq -- 'BEGIN PRIVATE KEY' "$log"; then
        die "candidate ukify fixture log was not redacted"
    fi
    [[ $(rootfs_image_path "$root/" "$root//usr/lib/modules/one/vmlinuz") == /usr/lib/modules/one/vmlinuz ]] ||
        die "rootfs path translation failed"
    if (rootfs_image_path "$root" "$work/outside") >/dev/null 2>&1; then
        die "outside-rootfs path accepted"
    fi
    mkdir "$top/outside"
    touch "$top/outside/vmlinuz"
    ln -s ../outside/vmlinuz "$root/relative-escape"
    ln -s "$top/outside/vmlinuz" "$root/absolute-escape"
    ln -s usr/lib/modules/one/vmlinuz "$root/internal-link"
    ln -s /usr/lib/modules/one/vmlinuz "$root/absolute-internal-link"
    if (rootfs_image_path "$root" "$root/relative-escape") >/dev/null 2>&1; then
        die "relative rootfs symlink escape accepted"
    fi
    if (rootfs_image_path "$root" "$root/absolute-escape") >/dev/null 2>&1; then
        die "absolute rootfs symlink escape accepted"
    fi
    [[ $(rootfs_image_path "$root" "$root/internal-link") == /usr/lib/modules/one/vmlinuz ]] ||
        die "internal rootfs symlink translation failed"
    [[ $(rootfs_image_path "$root" "$root/absolute-internal-link") == /usr/lib/modules/one/vmlinuz ]] ||
        die "absolute internal rootfs symlink translation failed"

    # The source is mode 0600; unprivileged fixtures cannot emulate root ownership.
    # The candidate receives public, byte-identical work copies instead.
    printf 'fixture kernel bytes\n' >"$root/usr/lib/modules/one/vmlinuz"
    printf 'fixture initrd bytes\n' >"$root/usr/lib/modules/one/initramfs.img"
    chmod 0600 "$root/usr/lib/modules/one/vmlinuz" "$root/usr/lib/modules/one/initramfs.img"
    local staged_work="$top/work-staged-inputs"
    mkdir "$staged_work"
    stage_public_kernel_inputs "$root" "$root/absolute-internal-link" \
        "$root/usr/lib/modules/one/initramfs.img" "$staged_work"
    [[ $(/usr/bin/stat -c '%a' "$staged_work/linux") == 644 && $(/usr/bin/stat -c '%a' "$staged_work/initrd") == 644 ]] ||
        die "staged public kernel inputs are not mode 0644"
    cmp -s "$root/usr/lib/modules/one/vmlinuz" "$staged_work/linux" || die "staged kernel differs from source"
    cmp -s "$root/usr/lib/modules/one/initramfs.img" "$staged_work/initrd" || die "staged initrd differs from source"
    verify_exposed_kernel_inputs "$root" "$root/absolute-internal-link" \
        "$root/usr/lib/modules/one/initramfs.img" "$staged_work"
    printf 'candidate-mutated-linux\n' >"$staged_work/linux"
    if (verify_exposed_kernel_inputs "$root" "$root/absolute-internal-link" \
        "$root/usr/lib/modules/one/initramfs.img" "$staged_work") >/dev/null 2>&1; then
        die "candidate kernel input overwrite accepted"
    fi
    cp "$root/usr/lib/modules/one/vmlinuz" "$staged_work/linux"
    printf 'candidate-mutated-initrd\n' >"$staged_work/initrd"
    if (verify_exposed_kernel_inputs "$root" "$root/absolute-internal-link" \
        "$root/usr/lib/modules/one/initramfs.img" "$staged_work") >/dev/null 2>&1; then
        die "candidate initrd input overwrite accepted"
    fi

    cp "$root/usr/lib/modules/one/vmlinuz" "$staged_work/linux"
    cp "$root/usr/lib/modules/one/initramfs.img" "$staged_work/initrd"
    PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_ARGS="$top/podman-overwrite-linux.args" \
        CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" CANDIDATE_UKIFY_TEST_OVERWRITE_LINUX=1 \
        run_candidate_ukify localhost/snosi-bootc-secure-first-fixture "$staged_work" \
        "$staged_work/ukify.log" "$key" "$cert" "$pcr" "" -- build
    if (verify_exposed_kernel_inputs "$root" "$root/absolute-internal-link" \
        "$root/usr/lib/modules/one/initramfs.img" "$staged_work") >/dev/null 2>&1; then
        die "candidate kernel overwrite through work mount accepted"
    fi
    cp "$root/usr/lib/modules/one/vmlinuz" "$staged_work/linux"
    cp "$root/usr/lib/modules/one/initramfs.img" "$staged_work/initrd"
    PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_ARGS="$top/podman-overwrite-initrd.args" \
        CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" CANDIDATE_UKIFY_TEST_OVERWRITE_INITRD=1 \
        run_candidate_ukify localhost/snosi-bootc-secure-first-fixture "$staged_work" \
        "$staged_work/ukify.log" "$key" "$cert" "$pcr" "" -- build
    if (verify_exposed_kernel_inputs "$root" "$root/absolute-internal-link" \
        "$root/usr/lib/modules/one/initramfs.img" "$staged_work") >/dev/null 2>&1; then
        die "candidate initrd overwrite through work mount accepted"
    fi

    local previous="$top/previous.key" protected="$top/protected" overwrite_work="$top/work-overwrite-active"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$previous" >/dev/null 2>&1
    mkdir "$protected" "$overwrite_work"
    cp "$work/pcr.pub" "$protected/pcr.pub"; cp "$protected/pcr.pub" "$overwrite_work/pcr.pub"
    PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_ARGS="$top/podman-overwrite-active.args" CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" \
        CANDIDATE_UKIFY_TEST_OVERWRITE_ACTIVE_PUB=1 \
        run_candidate_ukify localhost/snosi-bootc-secure-first-fixture "$overwrite_work" "$overwrite_work/ukify.log" "$key" "$cert" "$pcr" "" -- build
    if (verify_exposed_pcr_public_keys "$protected/pcr.pub" "$overwrite_work") >/dev/null 2>&1; then
        die "candidate active PCR public-key overwrite accepted"
    fi

    local previous_protected="$protected/previous.pub" overwrite_dual_work="$top/work-overwrite-previous"
    mkdir "$overwrite_dual_work"
    openssl pkey -in "$previous" -pubout -out "$previous_protected" >/dev/null
    cp "$protected/pcr.pub" "$overwrite_dual_work/pcr.pub"; cp "$previous_protected" "$overwrite_dual_work/previous.pub"
    PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_ARGS="$top/podman-overwrite-previous.args" CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" \
        CANDIDATE_UKIFY_TEST_OVERWRITE_PREVIOUS_PUB=1 \
        run_candidate_ukify localhost/snosi-bootc-secure-first-fixture "$overwrite_dual_work" "$overwrite_dual_work/ukify.log" "$key" "$cert" "$pcr" "$previous" -- build
    if (verify_exposed_pcr_public_keys "$protected/pcr.pub" "$overwrite_dual_work" "$previous_protected") >/dev/null 2>&1; then
        die "candidate previous PCR public-key overwrite accepted"
    fi

    local tee_work="$top/work-tee-failure" tee_log="$top/not-a-log"
    mkdir "$tee_work" "$tee_log"
    set +e
    PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_ARGS="$top/podman-tee-failure.args" CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" \
        run_candidate_ukify localhost/snosi-bootc-secure-first-fixture "$tee_work" "$tee_log" "$key" "$cert" "$pcr" "" -- build
    status=$?
    set -e
    [[ $status -ne 0 ]] || die "candidate ukify accepted a tee failure"

    local redaction_work="$top/work-redaction-failure"
    mkdir "$redaction_work"
    set +e
    (
        redact_credentials() {
            local line
            while IFS= read -r line || [[ -n $line ]]; do :; done
            return 73
        }
        PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_ARGS="$top/podman-redaction-failure.args" CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" \
            run_candidate_ukify localhost/snosi-bootc-secure-first-fixture "$redaction_work" "$redaction_work/ukify.log" "$key" "$cert" "$pcr" "" -- build
    )
    status=$?
    set -e
    [[ $status -eq 1 ]] || die "candidate ukify did not map redaction status"
    [[ -f "$top/podman-redaction-failure.args" ]] || die "candidate ukify redaction fixture did not run Podman"
    [[ -f "$redaction_work/ukify.log" ]] || die "candidate ukify redaction fixture did not reach tee"

    local dual_work="$top/work-dual" dual_args="$top/podman-dual.args"
    local -a dual_ukify_args
    mkdir "$dual_work"; openssl pkey -in "$pcr" -pubout -out "$dual_work/pcr.pub" >/dev/null
    candidate_ukify_args "$root" "$root/usr/lib/modules/one/vmlinuz" "$root/usr/lib/modules/one/initramfs.img" \
        fixture one "$previous" dual_ukify_args
    PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_ARGS="$dual_args" CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" \
        run_candidate_ukify localhost/snosi-bootc-secure-first-fixture "$dual_work" "$dual_work/ukify.log" "$key" "$cert" "$pcr" "$previous" -- \
        "${dual_ukify_args[@]}"
    if ! grep -Fqx -- "$previous:/run/snosi-ukify-previous-pcr.key:ro" "$dual_args" ||
        ! grep -Fqx -- /run/snosi-ukify-previous-pcr.key "$dual_args"; then
        die "candidate ukify dual-key mount is incorrect"
    fi

    local case_work case_log status
    for case_name in fail no-output empty-output; do
        case_work="$top/work-$case_name"; case_log="$case_work/ukify.log"; mkdir "$case_work"
        set +e
        case "$case_name" in
            fail) PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_ARGS="$top/podman-$case_name.args" CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" CANDIDATE_UKIFY_TEST_FAIL=1 run_candidate_ukify localhost/snosi-bootc-secure-first-fixture "$case_work" "$case_log" "$key" "$cert" "$pcr" "" -- build --output /run/snosi-ukify-work/uki.efi ;;
            no-output) PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_ARGS="$top/podman-$case_name.args" CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" CANDIDATE_UKIFY_TEST_NO_OUTPUT=1 run_candidate_ukify localhost/snosi-bootc-secure-first-fixture "$case_work" "$case_log" "$key" "$cert" "$pcr" "" -- build --output /run/snosi-ukify-work/uki.efi ;;
            empty-output) PATH="$top/bin:$PATH" CANDIDATE_UKIFY_TEST_ARGS="$top/podman-$case_name.args" CANDIDATE_UKIFY_TEST_PRIVATE_KEY="$pcr" CANDIDATE_UKIFY_TEST_EMPTY_OUTPUT=1 run_candidate_ukify localhost/snosi-bootc-secure-first-fixture "$case_work" "$case_log" "$key" "$cert" "$pcr" "" -- build --output /run/snosi-ukify-work/uki.efi ;;
        esac
        status=$?
        set -e
        [[ ! -e "$case_work/uki.efi" || ! -s "$case_work/uki.efi" ]] || die "candidate ukify $case_name reused an output"
        case "$case_name" in
            fail)
                if [[ $status -ne 86 ]] || ! grep -Fq -- 'candidate ukify failed at [redacted credential path]' "$case_log" ||
                    grep -Fq -- /run/snosi-ukify-pcr.key "$case_log" || grep -Fq -- 'BEGIN PRIVATE KEY' "$case_log"; then
                    die "candidate ukify failure status or redaction is incorrect"
                fi
                ;;
            *)
                [[ $status -ne 0 ]] ||
                    die "candidate ukify $case_name did not fail closed"
                ;;
        esac
    done
)

self_test() {
    local work key cert pcr pcr_cert rc=0
    work=$(mktemp -d); trap 'rm -rf -- "$work"' RETURN
    mkdir -p "$work/root/boot/EFI/Linux" "$work/root/usr/lib/modules/one"
    mkdir -p "$work/root/usr/lib/snosi"
    cat >"$work/root/usr/lib/snosi/bootc-secure.json" <<'EOF'
{"schema":1,"mok_certificate":"/usr/lib/snosi/mok.crt","pcr_public_key":"/usr/lib/snosi/pcr-signing.pub","encrypted_root_mapper":"root","systemd_suite":"forky"}
EOF
    validate_root_contract "$work/root"
    touch "$work/root/boot/EFI/Linux/old.efi"
    if (refuse_existing_uki "$work/root") >/dev/null 2>&1; then rc=1; fi
    rm "$work/root/boot/EFI/Linux/old.efi"
    if (discover_kernel "$work/root") >/dev/null 2>&1; then rc=1; fi
    touch "$work/root/usr/lib/modules/one/vmlinuz" "$work/root/usr/lib/modules/one/initramfs.img"
    discover_kernel "$work/root" >/dev/null
    mkdir "$work/root/usr/lib/modules/two"
    if (discover_kernel "$work/root") >/dev/null 2>&1; then rc=1; fi
    rmdir "$work/root/usr/lib/modules/two"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/mok.key" >/dev/null 2>&1
    openssl req -new -x509 -key "$work/mok.key" -subj /CN=mok -days 1 -out "$work/mok.crt" >/dev/null 2>&1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/pcr.key" >/dev/null 2>&1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/previous.key" >/dev/null 2>&1
    openssl pkey -in "$work/pcr.key" -pubout -out "$work/pcr.pub" >/dev/null
    validate_keypair "$work/mok.key" "$work/mok.crt" MOK
    validate_pcr_key "$work/pcr.key" "$work/pcr.pub"
    candidate_ukify_self_test
    return "$rc"
}

credential_self_test() {
    local work gate redacted
    work=$(mktemp -d); trap 'rm -rf -- "$work"' RETURN
    mkdir -p "$work/root/usr/share/doc/fixture" "$work/state" "$work/bin" "$work/mount"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/mok.key" >/dev/null 2>&1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/pcr.key" >/dev/null 2>&1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/previous.key" >/dev/null 2>&1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/example.key" >/dev/null 2>&1
    gate=$(mktemp -d); trap 'rm -rf -- "$work" "$gate"' RETURN
    credential_gate_init "$gate" "$work/mok.key" "$work/pcr.key" "$work/previous.key"
    printf 'not a private key\n' >"$work/root/non-key"
    # shellcheck disable=SC2016 # Fixture script expands this in its own process.
    printf '%s\n' '#!/bin/bash' 'touch "$OPENSSL_CALLED"; exit 99' >"$work/bin/openssl"
    chmod +x "$work/bin/openssl"
    OPENSSL_CALLED="$work/openssl-called" PATH="$work/bin:$PATH" credential_gate_scan_tree "$gate" rootfs "$work/root"
    [[ ! -e "$work/openssl-called" ]] || die "credential scan invoked OpenSSL for a non-key file"
    rm "$work/bin/openssl"
    cp "$work/example.key" "$work/root/usr/share/doc/fixture/example.key"
    credential_gate_scan_tree "$gate" rootfs "$work/root"
    redacted=$(printf 'ukify: --secureboot-private-key %s\n%s\ndiagnostic retained\n' "$work/mok.key" "$(<"$work/mok.key")" |
        redact_credentials "$work/mok.key" "$work/pcr.key")
    [[ $redacted == *'diagnostic retained'* && $redacted != *"$work/mok.key"* && $redacted != *'BEGIN PRIVATE KEY'* ]] ||
        die "credential redaction fixture failed"
    # shellcheck disable=SC2016 # Fixture script expands these in its own process.
    printf '%s\n' '#!/bin/bash' \
        'case $1 in inspect) cat "$BUILD_GATE_METADATA" ;; from) printf fixture-container ;; mount) printf "%s\n" "$BUILD_GATE_MOUNT" ;; umount|rm) : ;; esac' >"$work/bin/buildah"
    chmod +x "$work/bin/buildah"
    jq -n --arg key "$(<"$work/example.key")" '{config:{Labels:{example:$key}}}' >"$work/metadata.json"
    cp "$work/example.key" "$work/mount/example.key"
    BUILD_GATE_METADATA="$work/metadata.json" BUILD_GATE_MOUNT="$work/mount" PATH="$work/bin:$PATH" \
        credential_gate_scan_image "$gate" fixture-image
}

credential_negative_self_test() {
    local work gate
    work=$(mktemp -d); trap 'rm -rf -- "$work"' RETURN
    mkdir -p "$work/root" "$work/state" "$work/mount" "$work/bin"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/mok.key" >/dev/null 2>&1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/pcr.key" >/dev/null 2>&1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/previous.key" >/dev/null 2>&1
    gate=$(mktemp -d); trap 'rm -rf -- "$work" "$gate"' RETURN
    credential_gate_init "$gate" "$work/mok.key" "$work/pcr.key" "$work/previous.key"
    cp "$work/mok.key" "$work/root/rootfs-copy"
    if (credential_gate_scan_tree "$gate" rootfs "$work/root") >/dev/null 2>&1; then die "rootfs exact credential fixture accepted"; fi
    cp "$work/pcr.key" "$work/state/retained-log"
    if (credential_gate_scan_tree "$gate" "retained temporary state" "$work/state") >/dev/null 2>&1; then die "temporary-state exact credential fixture accepted"; fi
    cp "$work/mok.key" "$work/mount/layer-copy"
    jq -n '{config:{Labels:{safe:"value"}}}' >"$work/metadata.json"
    # shellcheck disable=SC2016 # Fixture script expands these in its own process.
    printf '%s\n' '#!/bin/bash' \
        'case $1 in inspect) cat "$BUILD_GATE_METADATA" ;; from) printf fixture-container ;; mount) printf "%s\n" "$BUILD_GATE_MOUNT" ;; umount|rm) : ;; esac' >"$work/bin/buildah"
    chmod +x "$work/bin/buildah"
    if BUILD_GATE_METADATA="$work/metadata.json" BUILD_GATE_MOUNT="$work/mount" PATH="$work/bin:$PATH" \
        credential_gate_scan_image "$gate" fixture-image >/dev/null 2>&1; then die "mounted OCI exact credential fixture accepted"; fi
    rm "$work/mount/layer-copy"
    jq -n --arg key "$(<"$work/previous.key")" '{config:{Labels:{leak:$key}}}' >"$work/metadata.json"
    if BUILD_GATE_METADATA="$work/metadata.json" BUILD_GATE_MOUNT="$work/mount" PATH="$work/bin:$PATH" \
        credential_gate_scan_image "$gate" fixture-image >/dev/null 2>&1; then die "OCI config exact credential fixture accepted"; fi
}

scan_image() { # OCI-image MOK-key PCR-key [previous-PCR-key]
    local image=$1 mok_key=$2 pcr_key=$3 previous_key=${4:-} gate
    gate=$(mktemp -d)
    trap 'rm -rf -- "$gate"' RETURN
    credential_gate_init "$gate" "$mok_key" "$pcr_key" "$previous_key"
    credential_gate_scan_image "$gate" "$image"
}

negative_self_test() {
    self_test
    local work fp section
    work=$(mktemp -d); trap 'rm -rf -- "$work"' RETURN
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/key" >/dev/null 2>&1
    openssl pkey -in "$work/key" -pubout -out "$work/pub" >/dev/null
    fp=$(pcr_fingerprint "$work/pub")
    printf 'kernel' >"$work/kernel"; printf 'initrd' >"$work/initrd"; touch "$work/uki"
    printf 'rw composefs=?%0128d' 0 >"$work/uki.cmdline"
    cp "$work/kernel" "$work/uki.linux"; cp "$work/initrd" "$work/uki.initrd"; cp "$work/pub" "$work/uki.pcrpkey"
    jq -n --arg fp "$fp" '{sha256: [range(0; 4) | {pol: ("phase-" + tostring), pkfp: $fp}]}' >"$work/uki.pcrsig"
    mkdir "$work/bin"
    cat >"$work/bin/objcopy" <<'EOF'
#!/bin/bash
set -euo pipefail
input=${@: -2:1}
while [[ $# -gt 0 ]]; do
    [[ $1 == --dump-section ]] || { shift; continue; }
    spec=$2; section=${spec%%=*}; target=${spec#*=}
    cp "${input}.${section#.}" "$target"
    shift 2
done
EOF
    cat >"$work/bin/objdump" <<'EOF'
#!/bin/bash
set -euo pipefail
input=${@: -1}
index=0
for section in cmdline linux initrd pcrpkey pcrsig; do
    printf ' %d .%s 00000000\n' "$index" "$section"
    (( index += 1 ))
    if [[ -e "$input.duplicate-$section" ]]; then
        printf ' %d .%s 00000000\n' "$index" "$section"
        (( index += 1 ))
    fi
done
EOF
    cat >"$work/bin/sbverify" <<'EOF'
#!/bin/bash
[[ ! -e "${@: -1}.bad-signature" ]]
EOF
    chmod +x "$work/bin/objcopy" "$work/bin/objdump" "$work/bin/sbverify"
    PATH="$work/bin:$PATH" validate_uki "$work/uki" "$work/kernel" "$work/initrd" "$work/cert" "$work/pub" "$(printf '%0128d' 0)"
    for section in cmdline linux initrd pcrpkey pcrsig; do
        cp "$work/uki.$section" "$work/uki.$section.saved"
        printf 'mutated' >"$work/uki.$section"
        if (PATH="$work/bin:$PATH" validate_uki "$work/uki" "$work/kernel" "$work/initrd" "$work/cert" "$work/pub" "$(printf '%0128d' 0)") >/dev/null 2>&1; then
            die "mutation fixture accepted UKI .$section mutation"
        fi
        mv "$work/uki.$section.saved" "$work/uki.$section"
    done
    touch "$work/uki.duplicate-pcrsig"
    if (PATH="$work/bin:$PATH" validate_uki "$work/uki" "$work/kernel" "$work/initrd" "$work/cert" "$work/pub" "$(printf '%0128d' 0)") >/dev/null 2>&1; then
        die "mutation fixture accepted duplicate UKI .pcrsig sections"
    fi
    rm "$work/uki.duplicate-pcrsig"
    touch "$work/uki.bad-signature"
    if (PATH="$work/bin:$PATH" validate_uki "$work/uki" "$work/kernel" "$work/initrd" "$work/cert" "$work/pub" "$(printf '%0128d' 0)") >/dev/null 2>&1; then
        die "mutation fixture accepted UKI Authenticode mutation"
    fi
}

validate() { # rootfs image mok-cert pcr-cert [previous-pcr-cert]
    local root=$1 image=$2 mok=$3 pcr=$4 previous=${5:-} version kernel initrd canonical_kernel canonical_initrd digest uki loader source work
    validate_root_contract "$root"
    kernel_info=$(discover_kernel "$root"); IFS=$'\t' read -r version kernel initrd <<<"$kernel_info"
    canonical_kernel=$(rootfs_source_path "$root" "$kernel")
    canonical_initrd=$(rootfs_source_path "$root" "$initrd")
    uki="$root/boot/EFI/Linux/$version.efi"; [[ -f "$uki" ]] || die "missing assembled UKI"
    loader="$root/boot/EFI/BOOT/grubx64.efi"; [[ -f "$loader" ]] || die "missing signed systemd-boot"
    source="$root/usr/lib/snosi/bootc/systemd-bootx64.efi"; [[ -f "$source" ]] || die "missing immutable signed systemd-boot source"
    sbverify --cert "$mok" "$loader" >/dev/null || die "systemd-boot MOK Authenticode signature failed"
    sbverify --cert "$mok" "$source" >/dev/null || die "immutable systemd-boot source MOK Authenticode signature failed"
    cmp -s "$source" "$loader" || die "ESP second stage differs from immutable signed systemd-boot source"
    digest=$(podman run --rm --privileged --pid=host -v /var/lib/containers:/var/lib/containers --security-opt label=type:unconfined_t "$image" bootc container compute-composefs-digest-from-storage "$image" | tr -d '\n')
    valid_digest "$digest" || die "storage digest interface did not return SHA-512"
    work=$(mktemp -d); trap 'rm -rf -- "$work"' RETURN
    openssl pkey -pubin -in "$pcr" -pubout -out "$work/pcr.pub"
    [[ -z "$previous" ]] || openssl pkey -pubin -in "$previous" -pubout -out "$work/previous.pub"
    validate_uki "$uki" "$canonical_kernel" "$canonical_initrd" "$mok" "$work/pcr.pub" "$digest" "${previous:+$work/previous.pub}"
}

case ${1:-} in
    --prepare-systemd-boot-source)
        shift
        [[ $# -eq 3 ]] || die "usage: $0 --prepare-systemd-boot-source ROOTFS MOK_KEY MOK_CERT"
        prepare_systemd_boot_source "$@"
        ;;
    --self-test) self_test ;;
    --credential-self-test) credential_self_test ;;
    --credential-negative-self-test) credential_negative_self_test ;;
    --scan-image) shift; scan_image "$@" ;;
    --negative-self-test) negative_self_test ;;
    --validate) shift; validate "$@" ;;
    --remove-injected) shift; remove_injected "$@" ;;
    '') die "Usage: $0 ROOTFS MOK_KEY MOK_CERT PCR_KEY PCR_CERT [PREVIOUS_PCR_CERT]" ;;
    *) assemble "$@" ;;
esac
