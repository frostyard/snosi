#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Prove old-to-new signed-PCR key rotation on an enrolled disposable VM.
set -euo pipefail

: "${SSH_PORT:=22}"
: "${SSH_TIMEOUT:=300}"
: "${SOURCE_PORT:=18081}"
: "${KEEP_REMOTE:=0}"

usage() {
    cat >&2 <<EOF
Usage: $0 --yes ARTIFACT_PREFIX OLD_PCR_CERT NEW_PCR_PUB RECOVERY_KEY SSH_TARGET SSH_KEY EXPECTED_MACHINE_ID

The target must already boot cayo-ab-secure with its MOK enrolled and a working
vTPM. This destructive test installs ARTIFACT_PREFIX with systemd-sysupdate,
normalizes the LUKS TPM tokens to old-only, reboots, then normalizes to new-only
and reboots the identical UKI. It never submits the recovery key during boot.

SSH_PORT, SSH_TIMEOUT, SOURCE_PORT, and KEEP_REMOTE may be set in the environment.
EOF
    exit 2
}

[[ ${1:-} == --yes && $# -eq 8 ]] || usage
shift

[[ $SSH_PORT =~ ^[0-9]+$ && $SSH_PORT -ge 1 && $SSH_PORT -le 65535 ]] || {
    echo "Error: SSH_PORT must be between 1 and 65535" >&2
    exit 2
}
[[ $SOURCE_PORT =~ ^[0-9]+$ && $SOURCE_PORT -ge 1 && $SOURCE_PORT -le 65535 ]] || {
    echo "Error: SOURCE_PORT must be between 1 and 65535" >&2
    exit 2
}
[[ $SSH_TIMEOUT =~ ^[0-9]+$ && $SSH_TIMEOUT -ge 1 ]] || {
    echo "Error: SSH_TIMEOUT must be a positive integer" >&2
    exit 2
}
[[ $KEEP_REMOTE == 0 || $KEEP_REMOTE == 1 ]] || {
    echo "Error: KEEP_REMOTE must be 0 or 1" >&2
    exit 2
}

prefix=$(realpath -m "$(dirname "$1")")/$(basename "$1")
old_certificate=$(realpath "$2")
new_public_key=$(realpath "$3")
recovery_key=$(realpath "$4")
ssh_target=$5
ssh_key=$(realpath "$6")
expected_machine_id=$7

manifest="${prefix}.manifest"
raw="${prefix}.raw"
uki="${prefix}.efi"
root="${prefix}.cayo_@v.root.raw.raw"
verity="${prefix}.cayo_@v.root-verity.raw.raw"

for command in awk base64 cut gpg jq openssl realpath scp sfdisk sha256sum ssh xz; do
    command -v "$command" >/dev/null || {
        echo "Error: required command not found: $command" >&2
        exit 1
    }
done
for file in "$manifest" "$raw" "$uki" "$root" "$verity" \
    "$old_certificate" "$new_public_key" "$recovery_key" "$ssh_key"; do
    [[ -f "$file" ]] || { echo "Error: required file not found: $file" >&2; exit 1; }
done
[[ $expected_machine_id =~ ^[0-9a-f]{32}$ ]] || {
    echo "Error: EXPECTED_MACHINE_ID must be exactly 32 lowercase hex characters" >&2
    exit 1
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
workdir=$(mktemp -d)
mkdir -p "$workdir/source" "$workdir/definitions"
remote_dir=/var/tmp/native-ab-secure-rotation
remote_recovery_key=/run/native-ab-secure-rotation-recovery.key
source_service=native-ab-secure-rotation-source.service
ssh_options=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
    -o BatchMode=yes
    -p "$SSH_PORT"
    -i "$ssh_key"
)
scp_options=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
    -o BatchMode=yes
    -P "$SSH_PORT"
    -i "$ssh_key"
)

guest() {
    # shellcheck disable=SC2029  # Arguments are commands for the remote shell.
    ssh "${ssh_options[@]}" "$ssh_target" "$@"
}

guest_with_input() {
    local input=$1
    shift
    # shellcheck disable=SC2029  # Arguments are commands for the remote shell.
    ssh "${ssh_options[@]}" "$ssh_target" "$@" < "$input"
}

stage_recovery_key() {
    scp "${scp_options[@]}" "$recovery_key" "$ssh_target:$remote_recovery_key"
    guest "chmod 0600 '$remote_recovery_key'"
}

cleanup() {
    rm -rf "$workdir"
    guest "rm -f '$remote_recovery_key'" 2>/dev/null || true
    guest "systemctl stop '$source_service' 2>/dev/null || true" 2>/dev/null || true
    guest "if test -e '$remote_dir/import-pubring.backup'; then install -m 0644 '$remote_dir/import-pubring.backup' /etc/systemd/import-pubring.gpg; elif test -e '$remote_dir/import-pubring.absent'; then rm -f /etc/systemd/import-pubring.gpg; fi" 2>/dev/null || true
    if [[ $KEEP_REMOTE != 1 ]]; then
        guest "rm -rf '$remote_dir'" 2>/dev/null || true
    else
        echo "KEEP_REMOTE=1: retained $remote_dir on $ssh_target"
    fi
}
trap cleanup EXIT

public_fingerprint() {
    openssl rsa -pubin -in "$1" -RSAPublicKey_out -outform DER 2>/dev/null | \
        sha256sum | cut -d' ' -f1
}

guest_version() {
    # shellcheck disable=SC2016  # IMAGE_VERSION expands in the guest.
    guest '. /usr/lib/os-release; printf "%s\n" "$IMAGE_VERSION"'
}

matching_uki_entry() {
    local hash path matches=0
    MATCHING_UKI_ENTRY=
    while read -r hash path; do
        [[ -n ${hash:-} ]] || continue
        if [[ $hash == "$uki_hash" ]]; then
            MATCHING_UKI_ENTRY=${path##*/}
            matches=$((matches + 1))
        fi
    done < <(guest "find /boot/EFI/Linux -maxdepth 1 -type f -name 'cayo_${version}*.efi' -exec sha256sum {} +")
    [[ $matches -gt 0 ]] || return 1
    [[ $matches -eq 1 ]] || {
        echo "Error: found $matches installed transition UKIs with hash $uki_hash" >&2
        return 2
    }
}

assert_transition_not_activated() {
    local rc
    if guest "lsblk -J -o PARTLABEL | jq -e --arg root 'cayo_${version}_r' --arg verity 'cayo_${version}_v' '[.. | objects | .partlabel? // empty] | any(. == \$root or . == \$verity)'" >/dev/null; then
        echo "Error: rejected update activated a transition partition label" >&2
        return 1
    fi
    if matching_uki_entry; then
        echo "Error: rejected update installed the transition UKI" >&2
        return 1
    else
        rc=$?
        [[ $rc -eq 1 ]] || return "$rc"
    fi
}

assert_transition_not_bootable() {
    local rc
    if matching_uki_entry; then
        echo "Error: rejected update installed the transition UKI" >&2
        return 1
    else
        rc=$?
        [[ $rc -eq 1 ]] || return "$rc"
    fi
    [[ $(guest_version) != "$version" ]] || {
        echo "Error: rejected update changed the running version" >&2
        return 1
    }
}

expect_update_rejected() {
    local description=$1 activation_check=${2:-strict}
    echo "Failure injection: $description"
    if guest "systemd-sysupdate --definitions='$remote_dir/definitions' --verify=yes update '$version'"; then
        echo "Error: invalid secure update succeeded: $description" >&2
        return 1
    fi
    if [[ $activation_check == strict ]]; then
        assert_transition_not_activated
    else
        assert_transition_not_bootable
    fi
}

wait_for_new_boot() {
    local previous_boot_id=$1 current_boot_id deadline
    deadline=$((SECONDS + SSH_TIMEOUT))
    echo "Waiting up to ${SSH_TIMEOUT}s for a new boot..."
    while (( SECONDS < deadline )); do
        if current_boot_id=$(guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) && \
            [[ $current_boot_id != "$previous_boot_id" ]]; then
            echo "New boot available: $current_boot_id"
            return 0
        fi
        sleep 2
    done
    echo "Error: target did not return with a new boot within ${SSH_TIMEOUT}s" >&2
    return 1
}

reboot_guest() {
    local previous_boot_id
    previous_boot_id=$(guest 'cat /proc/sys/kernel/random/boot_id')
    guest 'systemctl reboot' || true
    wait_for_new_boot "$previous_boot_id"
}

luks_metadata() {
    guest "cryptsetup luksDump --dump-json-metadata '$var_device'"
}

locate_token() {
    local expected_fingerprint=$1 metadata=${2:-} id slots encoded fingerprint matches=0
    [[ -n $metadata ]] || metadata=$(luks_metadata)
    MATCHED_TOKEN_ID=
    MATCHED_KEY_SLOT=

    while IFS=$'\t' read -r id slots encoded; do
        [[ -n ${encoded:-} && $encoded != null ]] || continue
        fingerprint=$(printf '%s' "$encoded" | base64 -d | \
            openssl rsa -pubin -RSAPublicKey_out -outform DER 2>/dev/null | \
            sha256sum | cut -d' ' -f1)
        if [[ $fingerprint == "$expected_fingerprint" ]]; then
            [[ $slots != *,* ]] || {
                echo "Error: TPM token $id references multiple keyslots: $slots" >&2
                return 2
            }
            [[ $slots =~ ^[0-9]+$ ]] || {
                echo "Error: TPM token $id has invalid keyslot: $slots" >&2
                return 2
            }
            MATCHED_TOKEN_ID=$id
            MATCHED_KEY_SLOT=$slots
            matches=$((matches + 1))
        fi
    done < <(jq -r '
        .tokens | to_entries[]
        | select(.value.type == "systemd-tpm2")
        | [.key, (.value.keyslots | join(",")), .value.tpm2_pubkey]
        | @tsv
    ' <<< "$metadata")

    [[ $matches -le 1 ]] || {
        echo "Error: found $matches TPM tokens for public-key fingerprint $expected_fingerprint" >&2
        return 2
    }
    [[ $matches -eq 1 ]]
}

assert_token_policy() {
    local token_id=$1 metadata=$2
    jq -e --arg id "$token_id" '
        .tokens[$id]["tpm2-pcrs"] == []
        and .tokens[$id].tpm2_pubkey_pcrs == [11]
        and (.tokens[$id] | has("tpm2-pcrlock") | not)
    ' <<< "$metadata" >/dev/null || {
        echo "Error: TPM token $token_id does not use signed PCR 11-only policy" >&2
        return 1
    }
}

assert_only_tpm_token() {
    local expected_fingerprint=$1 metadata count
    metadata=$(luks_metadata)
    count=$(jq '[.tokens[] | select(.type == "systemd-tpm2")] | length' <<< "$metadata")
    [[ $count -eq 1 ]] || {
        echo "Error: expected exactly one TPM token, found $count" >&2
        return 1
    }
    locate_token "$expected_fingerprint" "$metadata" || {
        echo "Error: sole TPM token does not match $expected_fingerprint" >&2
        return 1
    }
    assert_token_policy "$MATCHED_TOKEN_ID" "$metadata"
}

wipe_token() {
    local expected_fingerprint=$1 description=$2 metadata
    metadata=$(luks_metadata)
    locate_token "$expected_fingerprint" "$metadata" || {
        echo "Error: cannot find $description TPM token" >&2
        return 1
    }
    assert_token_policy "$MATCHED_TOKEN_ID" "$metadata"
    echo "Wiping $description TPM token $MATCHED_TOKEN_ID, keyslot $MATCHED_KEY_SLOT"
    guest "systemd-cryptenroll --wipe-slot='$MATCHED_KEY_SLOT' '$var_device'"
    if locate_token "$expected_fingerprint" "$(luks_metadata)"; then
        echo "Error: $description TPM token remains after wipe" >&2
        return 1
    fi
    guest "cryptsetup open --test-passphrase --key-file='$remote_recovery_key' '$var_device'"
}

enroll_token() {
    local expected_fingerprint=$1 public_path=$2 description=$3 metadata
    metadata=$(luks_metadata)
    if locate_token "$expected_fingerprint" "$metadata"; then
        assert_token_policy "$MATCHED_TOKEN_ID" "$metadata"
        echo "$description TPM token already enrolled as $MATCHED_TOKEN_ID"
        return
    fi

    echo "Enrolling $description TPM token"
    guest "systemd-cryptenroll --unlock-key-file='$remote_recovery_key' --tpm2-device=auto --tpm2-pcrs= --tpm2-pcrlock= --tpm2-public-key='$public_path' --tpm2-public-key-pcrs=11 '$var_device'"
    metadata=$(luks_metadata)
    locate_token "$expected_fingerprint" "$metadata" || {
        echo "Error: $description TPM token was not enrolled" >&2
        return 1
    }
    assert_token_policy "$MATCHED_TOKEN_ID" "$metadata"
}

verify_transition_boot() {
    local expected_token_fingerprint=$1 actual_version cmdline roothash health
    local running_entry running_hash
    actual_version=$(guest_version)
    [[ $actual_version == "$version" ]] || {
        echo "Error: booted $actual_version, expected transition $version" >&2
        return 1
    }
    guest "mokutil --sb-state | grep -qx 'SecureBoot enabled'"
    guest "bootctl --no-pager status | grep -q 'Measured UKI: yes'"
    guest "grep -Eq '\[(integrity|confidentiality)\]' /sys/kernel/security/lockdown"
    [[ $(guest 'findmnt -no SOURCE /var') == /dev/mapper/var ]]
    guest 'cryptsetup status var | grep -q "type:[[:space:]]*LUKS2"'
    # Hash the entry firmware reports as running, not merely a matching ESP file.
    # shellcheck disable=SC2016  # All substitutions expand in the guest.
    read -r running_entry running_hash < <(guest '
        entry=$(bootctl --no-pager status | sed -n "s/^[[:space:]]*Current Entry: //p")
        test -n "$entry" && test -f "/boot/EFI/Linux/$entry"
        hash=$(sha256sum "/boot/EFI/Linux/$entry")
        printf "%s %s\n" "$entry" "${hash%% *}"
    ')
    [[ $running_entry == cayo_${version}*.efi && $running_hash == "$uki_hash" ]] || {
        echo "Error: running UKI $running_entry has hash $running_hash, expected $uki_hash" >&2
        return 1
    }

    cmdline=$(guest 'cat /proc/cmdline')
    roothash=$(sed -n 's/.*\broothash=\([^ ]*\).*/\1/p' <<< "$cmdline")
    [[ ${roothash,,} == "$expected_roothash" ]] || {
        echo "Error: running roothash $roothash, expected $expected_roothash" >&2
        return 1
    }
    assert_only_tpm_token "$expected_token_fingerprint"
    health=$(guest 'systemctl is-system-running --wait' || true)
    [[ $health == running || $health == degraded ]] || {
        echo "Error: system health is $health" >&2
        return 1
    }
    if [[ $health == degraded ]]; then
        guest 'systemctl --failed --no-pager' >&2 || true
    fi
}

version=$(jq -er '.config.version' "$manifest")
[[ $version =~ ^[A-Za-z0-9._+:-]+$ ]] || {
    echo "Error: unsafe image version in manifest: $version" >&2
    exit 1
}
layout=$(sfdisk --json "$raw")
root_uuid=$(jq -er --arg label "cayo_${version}_r" \
    '.partitiontable.partitions[] | select(.name == $label) | .uuid | ascii_downcase' <<< "$layout")
verity_uuid=$(jq -er --arg label "cayo_${version}_v" \
    '.partitiontable.partitions[] | select(.name == $label) | .uuid | ascii_downcase' <<< "$layout")
expected_roothash=${root_uuid//-/}${verity_uuid//-/}
uki_hash=$(sha256sum "$uki")
uki_hash=${uki_hash%% *}

openssl x509 -in "$old_certificate" -pubkey -noout > "$workdir/old.pub"
cp "$new_public_key" "$workdir/new.pub"
old_fingerprint=$(public_fingerprint "$workdir/old.pub")
new_fingerprint=$(public_fingerprint "$workdir/new.pub")
[[ $old_fingerprint != "$new_fingerprint" ]] || {
    echo "Error: old and new PCR keys are identical" >&2
    exit 1
}

"$script_dir/native-ab-secure-artifact-test.sh" \
    "$manifest" "$uki" "$old_certificate" "$new_public_key"

actual_machine_id=$(guest 'cat /etc/machine-id')
[[ $actual_machine_id == "$expected_machine_id" ]] || {
    echo "Error: target machine-id $actual_machine_id does not match explicit expected ID" >&2
    exit 1
}
guest 'test -e /usr/lib/snosi/native-ab'
# shellcheck disable=SC2016  # command expands in the guest.
guest 'for command in bootctl cryptsetup curl findmnt jq mokutil python3 sha256sum systemd-cryptenroll systemd-run systemd-sysupdate xz; do command -v "$command" >/dev/null || exit 1; done'
guest "rm -rf '$remote_dir' && mkdir -p '$remote_dir/source' '$remote_dir/definitions'"
scp "${scp_options[@]}" "$workdir/old.pub" "$workdir/new.pub" \
    "$ssh_target:$remote_dir/"
stage_recovery_key

var_device=$(guest "lsblk -J -o PATH,PARTLABEL | jq -er '.. | objects | select(.partlabel? == \"var\") | .path'")
guest_with_input "$recovery_key" \
    "cryptsetup open --test-passphrase --key-file=- '$var_device'"

echo "Preparing transition update $version"
xz -T0 -c "$root" > "$workdir/source/cayo_${version}_${root_uuid}.root.raw.xz"
xz -T0 -c "$verity" > "$workdir/source/cayo_${version}_${verity_uuid}.root-verity.raw.xz"
cp "$uki" "$workdir/source/cayo_${version}.efi"
for file in "$workdir/source"/*; do
    name=${file##*/}
    hash=$(sha256sum "$file")
    printf '%s  %s\n' "${hash%% *}" "$name" >> "$workdir/source/SHA256SUMS"
done
mkdir -p "$workdir/gnupg"
chmod 0700 "$workdir/gnupg"
gpg --homedir "$workdir/gnupg" --batch --passphrase '' --quick-generate-key \
    'snosi secure rotation test <native-ab-secure-rotation@invalid>' ed25519 sign 0
gpg --homedir "$workdir/gnupg" --batch --yes --detach-sign \
    -o "$workdir/source/SHA256SUMS.gpg" "$workdir/source/SHA256SUMS"
gpg --homedir "$workdir/gnupg" --batch --export > "$workdir/import-pubring.gpg"

cat > "$workdir/definitions/10-root-verity.transfer" <<EOF
[Transfer]
ProtectVersion=%A
Verify=yes
[Source]
Type=url-file
Path=http://127.0.0.1:$SOURCE_PORT/
MatchPattern=cayo_@v_@u.root-verity.raw.xz
[Target]
Type=partition
Path=auto
MatchPattern=cayo_@v_v
MatchPartitionType=root-verity
PartitionFlags=0
ReadOnly=yes
InstancesMax=2
EOF
cat > "$workdir/definitions/20-root.transfer" <<EOF
[Transfer]
ProtectVersion=%A
Verify=yes
[Source]
Type=url-file
Path=http://127.0.0.1:$SOURCE_PORT/
MatchPattern=cayo_@v_@u.root.raw.xz
[Target]
Type=partition
Path=auto
MatchPattern=cayo_@v_r
MatchPartitionType=root
PartitionFlags=0
ReadOnly=yes
InstancesMax=2
EOF
cat > "$workdir/definitions/90-uki.transfer" <<EOF
[Transfer]
ProtectVersion=%A
Verify=yes
[Source]
Type=url-file
Path=http://127.0.0.1:$SOURCE_PORT/
MatchPattern=cayo_@v.efi
[Target]
Type=regular-file
Path=/EFI/Linux
PathRelativeTo=boot
MatchPattern=cayo_@v+@l-@d.efi
MatchPattern=cayo_@v+@l.efi
MatchPattern=cayo_@v.efi
Mode=0444
TriesLeft=3
TriesDone=0
InstancesMax=2
EOF

scp "${scp_options[@]}" -r "$workdir/source/." "$ssh_target:$remote_dir/source/"
scp "${scp_options[@]}" -r "$workdir/definitions/." "$ssh_target:$remote_dir/definitions/"
scp "${scp_options[@]}" "$workdir/import-pubring.gpg" "$ssh_target:$remote_dir/"
guest "if test -e /etc/systemd/import-pubring.gpg; then cp -a /etc/systemd/import-pubring.gpg '$remote_dir/import-pubring.backup'; else touch '$remote_dir/import-pubring.absent'; fi; install -m 0644 '$remote_dir/import-pubring.gpg' /etc/systemd/import-pubring.gpg"
guest "systemctl stop '$source_service' 2>/dev/null || true; systemd-run --unit='$source_service' --property=Type=exec python3 -m http.server '$SOURCE_PORT' --bind 127.0.0.1 --directory '$remote_dir/source'"
guest "curl --fail --silent --show-error 'http://127.0.0.1:$SOURCE_PORT/SHA256SUMS' >/dev/null"

if matching_uki_entry; then
    echo "Transition $version is already installed"
else
    rc=$?
    [[ $rc -eq 1 ]] || exit "$rc"

    guest "cp '$remote_dir/source/SHA256SUMS' '$remote_dir/SHA256SUMS.valid'; printf '\n' >> '$remote_dir/source/SHA256SUMS'"
    expect_update_rejected "tampered signed manifest"
    guest "mv '$remote_dir/SHA256SUMS.valid' '$remote_dir/source/SHA256SUMS'"

    root_source="$remote_dir/source/cayo_${version}_${root_uuid}.root.raw.xz"
    guest "cp --reflink=auto '$root_source' '$remote_dir/root.raw.xz.valid'; printf x >> '$root_source'"
    # Earlier transfers may leave no-auto partial partition metadata. The UKI
    # entry point must not be committed, and the following valid update must
    # recover the same slots.
    expect_update_rejected "root payload checksum mismatch" nonbootable
    guest "mv '$remote_dir/root.raw.xz.valid' '$root_source'"
    guest "systemd-sysupdate --definitions='$remote_dir/definitions' --verify=yes vacuum"
    assert_transition_not_activated

    guest "systemd-sysupdate --definitions='$remote_dir/definitions' --verify=yes update '$version'"
    matching_uki_entry
fi
guest "bootctl set-default '$MATCHING_UKI_ENTRY'"

# Establish old-only before the first transition boot. The recovery key was
# proven above, and the transition UKI is already installed before any wipe.
enroll_token "$old_fingerprint" "$remote_dir/old.pub" old
if locate_token "$new_fingerprint" "$(luks_metadata)"; then
    wipe_token "$new_fingerprint" new
fi
assert_only_tpm_token "$old_fingerprint"

echo "Rebooting transition $version with only the old TPM token"
reboot_guest
verify_transition_boot "$old_fingerprint"

stage_recovery_key
enroll_token "$new_fingerprint" "$remote_dir/new.pub" new
locate_token "$old_fingerprint" "$(luks_metadata)" || {
    echo "Error: old TPM token disappeared before retirement" >&2
    exit 1
}
wipe_token "$old_fingerprint" old
assert_only_tpm_token "$new_fingerprint"

echo "Rebooting identical transition $version with only the new TPM token"
reboot_guest
verify_transition_boot "$new_fingerprint"

echo "Native A/B secure PCR rotation passed: old-only -> transition $version -> new-only"
