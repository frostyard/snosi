#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Prove secure update, rollback, and boot-count fallback across PCR key rotation.
set -euo pipefail

: "${SSH_PORT:=22}"
: "${SSH_TIMEOUT:=300}"
: "${SOURCE_PORT:=18082}"
: "${INCUS_PROJECT:=default}"
: "${INCUS_REMOTE:=}"
: "${KEEP_REMOTE:=0}"

usage() {
    cat >&2 <<EOF
Usage: $0 --yes CURRENT_PREFIX DUAL_PREFIX NEW_PREFIX OLD_PCR_CERT NEW_PCR_PUB RECOVERY_KEY SSH_TARGET SSH_KEY EXPECTED_MACHINE_ID INCUS_INSTANCE

The target must be a disposable, MOK-enrolled cayo-ab (or another production native profile) Incus VM already
running CURRENT_PREFIX with only the new TPM token. The destructive test installs
dual-signed DUAL_PREFIX and new-only NEW_PREFIX, verifies explicit rollback,
corrupts NEW_PREFIX, and force-restarts INCUS_INSTANCE until boot counting falls
back to DUAL_PREFIX. It never submits the recovery key during boot. An aborted
run may leave the ephemeral test update keyring installed on the disposable VM.

SSH_PORT, SSH_TIMEOUT, SOURCE_PORT, INCUS_PROJECT, INCUS_REMOTE, and KEEP_REMOTE
may be set in the environment. INCUS_REMOTE is the remote name without a colon.
EOF
    exit 2
}

[[ ${1:-} == --yes && $# -eq 11 ]] || usage
shift

for variable in SSH_PORT SOURCE_PORT SSH_TIMEOUT; do
    value=${!variable}
    [[ $value =~ ^[0-9]+$ && $value -ge 1 ]] || {
        echo "Error: $variable must be a positive integer" >&2
        exit 2
    }
done
[[ $SSH_PORT -le 65535 && $SOURCE_PORT -le 65535 ]] || {
    echo "Error: SSH_PORT and SOURCE_PORT must not exceed 65535" >&2
    exit 2
}
[[ $KEEP_REMOTE == 0 || $KEEP_REMOTE == 1 ]] || {
    echo "Error: KEEP_REMOTE must be 0 or 1" >&2
    exit 2
}

declare -a prefixes=() versions=() root_uuids=() verity_uuids=() uki_hashes=()
for arg in "$1" "$2" "$3"; do
    prefixes+=("$(realpath -m "$(dirname "$arg")")/$(basename "$arg")")
done
old_certificate=$(realpath "$4")
new_public_key=$(realpath "$5")
recovery_key=$(realpath "$6")
ssh_target=$7
ssh_key=$(realpath "$8")
expected_machine_id=$9
incus_instance=${10}
incus_target=$incus_instance
[[ -z $INCUS_REMOTE ]] || incus_target="$INCUS_REMOTE:$incus_instance"

for command in base64 cmp cut dpkg gpg grep incus jq openssl realpath scp \
    sfdisk sha256sum ssh stat xz; do
    command -v "$command" >/dev/null || {
        echo "Error: required command not found: $command" >&2
        exit 1
    }
done
for file in "$old_certificate" "$new_public_key" "$recovery_key" "$ssh_key"; do
    [[ -f $file ]] || { echo "Error: required file not found: $file" >&2; exit 1; }
done
[[ $expected_machine_id =~ ^[0-9a-f]{32}$ ]] || {
    echo "Error: EXPECTED_MACHINE_ID must be exactly 32 lowercase hex characters" >&2
    exit 1
}
[[ $incus_instance =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
    echo "Error: unsafe Incus instance name: $incus_instance" >&2
    exit 1
}
[[ -z $INCUS_REMOTE || $INCUS_REMOTE =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
    echo "Error: unsafe Incus remote name: $INCUS_REMOTE" >&2
    exit 1
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
workdir=$(mktemp -d /var/tmp/native-ab-secure-update-test.XXXXXX)
mkdir -p "$workdir/source" "$workdir/definitions" "$workdir/gnupg"
chmod 0700 "$workdir/gnupg"
remote_dir=/var/tmp/native-ab-secure-update
source_service=native-ab-secure-update-source.service
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

cleanup() {
    rm -rf "$workdir"
    guest "systemctl stop '$source_service' 2>/dev/null || true" 2>/dev/null || true
    guest "if test -e '$remote_dir/import-pubring.backup'; then install -m 0644 '$remote_dir/import-pubring.backup' /etc/systemd/import-pubring.gpg; elif test -e '$remote_dir/import-pubring.absent'; then rm -f /etc/systemd/import-pubring.gpg; fi" 2>/dev/null || true
    if [[ $KEEP_REMOTE != 1 ]]; then
        guest "rm -rf '$remote_dir'" 2>/dev/null || true
    else
        echo "KEEP_REMOTE=1: retained $remote_dir on $ssh_target"
    fi
}
trap cleanup EXIT

guest_version() {
    # shellcheck disable=SC2016  # IMAGE_VERSION expands in the guest.
    guest '. /usr/lib/os-release; printf "%s\n" "$IMAGE_VERSION"'
}

wait_for_guest() {
    local deadline=$((SECONDS + SSH_TIMEOUT))
    echo "Waiting up to ${SSH_TIMEOUT}s for SSH..."
    while (( SECONDS < deadline )); do
        if guest true 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    echo "Error: target did not return within ${SSH_TIMEOUT}s" >&2
    return 1
}

reboot_guest() {
    local previous_boot_id current_boot_id deadline
    previous_boot_id=$(guest 'cat /proc/sys/kernel/random/boot_id')
    guest 'systemctl reboot' || true
    deadline=$((SECONDS + SSH_TIMEOUT))
    echo "Waiting up to ${SSH_TIMEOUT}s for a new boot..."
    while (( SECONDS < deadline )); do
        if current_boot_id=$(guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) && \
            [[ $current_boot_id != "$previous_boot_id" ]]; then
            return 0
        fi
        sleep 2
    done
    echo "Error: target did not return with a new boot within ${SSH_TIMEOUT}s" >&2
    return 1
}

public_fingerprint() {
    openssl rsa -pubin -in "$1" -RSAPublicKey_out -outform DER 2>/dev/null | \
        sha256sum | cut -d' ' -f1
}

luks_metadata() {
    guest "cryptsetup luksDump --dump-json-metadata '$var_device'"
}

assert_new_only_token() {
    local metadata count encoded fingerprint
    metadata=$(luks_metadata)
    count=$(jq '[.tokens[] | select(.type == "systemd-tpm2")] | length' <<< "$metadata")
    [[ $count -eq 1 ]] || {
        echo "Error: expected exactly one TPM token, found $count" >&2
        return 1
    }
    encoded=$(jq -er '.tokens[] | select(.type == "systemd-tpm2") | .tpm2_pubkey' <<< "$metadata")
    fingerprint=$(printf '%s' "$encoded" | base64 -d | \
        openssl rsa -pubin -RSAPublicKey_out -outform DER 2>/dev/null | \
        sha256sum | cut -d' ' -f1)
    [[ $fingerprint == "$new_fingerprint" ]] || {
        echo "Error: sole TPM token uses $fingerprint, expected $new_fingerprint" >&2
        return 1
    }
    jq -e '
        .tokens[] | select(.type == "systemd-tpm2")
        | .["tpm2-pcrs"] == []
        and .tpm2_pubkey_pcrs == [11]
        and (has("tpm2-pcrlock") | not)
        and (.keyslots | length) == 1
    ' <<< "$metadata" >/dev/null || {
        echo "Error: TPM token does not use a single keyslot and signed PCR 11-only policy" >&2
        return 1
    }
}

partition_path() {
    local label=$1
    guest "lsblk -J -o PATH,PARTLABEL" | jq -er --arg label "$label" \
        '.. | objects | select(.partlabel? == $label) | .path'
}

matching_uki_entry() {
    local index=$1 hash path matches=0
    MATCHING_UKI_ENTRY=
    while read -r hash path; do
        [[ -n ${hash:-} ]] || continue
        if [[ $hash == "${uki_hashes[index]}" ]]; then
            MATCHING_UKI_ENTRY=${path##*/}
            matches=$((matches + 1))
        fi
    done < <(guest "find /boot/EFI/Linux -maxdepth 1 -type f -name 'cayo-ab_${versions[index]}*.efi' -exec sha256sum {} +")
    [[ $matches -eq 1 ]] || {
        echo "Error: found $matches installed UKIs for ${versions[index]} with the expected hash" >&2
        return 1
    }
}

verify_boot() {
    local index=$1 actual_version cmdline roothash running_entry running_hash health
    actual_version=$(guest_version)
    [[ $actual_version == "${versions[index]}" ]] || {
        echo "Error: booted $actual_version, expected ${versions[index]}" >&2
        return 1
    }
    guest "mokutil --sb-state | grep -qx 'SecureBoot enabled'"
    guest "bootctl --no-pager status | grep -q 'Measured UKI: yes'"
    guest "grep -Eq '\[(integrity|confidentiality)\]' /sys/kernel/security/lockdown"
    [[ $(guest 'findmnt -no SOURCE /var') == /dev/mapper/var ]]
    guest 'cryptsetup status var | grep -q "type:[[:space:]]*LUKS2"'
    # shellcheck disable=SC2016  # All substitutions expand in the guest.
    read -r running_entry running_hash < <(guest '
        entry=$(bootctl --no-pager status | sed -n "s/^[[:space:]]*Current Entry: //p")
        test -n "$entry" && test -f "/boot/EFI/Linux/$entry"
        hash=$(sha256sum "/boot/EFI/Linux/$entry")
        printf "%s %s\n" "$entry" "${hash%% *}"
    ')
    [[ $running_entry == cayo-ab_${versions[index]}*.efi && $running_hash == "${uki_hashes[index]}" ]] || {
        echo "Error: running UKI $running_entry has unexpected identity" >&2
        return 1
    }
    cmdline=$(guest 'cat /proc/cmdline')
    roothash=$(sed -n 's/.*\broothash=\([^ ]*\).*/\1/p' <<< "$cmdline")
    [[ ${roothash,,} == "${expected_roothashes[index]}" ]] || {
        echo "Error: running roothash $roothash, expected ${expected_roothashes[index]}" >&2
        return 1
    }
    assert_new_only_token
    # shellcheck disable=SC2016  # The loop variable expands in the guest.
    guest 'for unit in systemd-tpm2-setup-early.service systemd-tpm2-setup.service systemd-pcrproduct.service systemd-pcrlogin@0.service; do ! systemctl is-failed --quiet "$unit"; done'
    guest 'grep -qx var-persist /var/native-ab-secure-update-test'
    guest 'grep -qx etc-persist /etc/native-ab-secure-update-test'
    health=$(guest 'systemctl is-system-running --wait' || true)
    [[ $health == running || $health == degraded ]] || {
        echo "Error: system health is $health" >&2
        return 1
    }
    if [[ $health == degraded ]]; then
        guest 'systemctl --failed --no-pager' >&2 || true
    fi
}

install_update() {
    local index=$1 layout installed_root_uuid installed_verity_uuid
    echo "Installing secure update ${versions[index]}"
    guest "systemd-sysupdate --definitions='$remote_dir/definitions' --verify=yes update '${versions[index]}'"
    layout=$(guest 'lsblk -J -o PATH,PARTLABEL,PARTUUID')
    installed_root_uuid=$(jq -er --arg label "cayo_${versions[index]}_r" \
        '.. | objects | select(.partlabel? == $label) | .partuuid | ascii_downcase' <<< "$layout")
    installed_verity_uuid=$(jq -er --arg label "cayo_${versions[index]}_v" \
        '.. | objects | select(.partlabel? == $label) | .partuuid | ascii_downcase' <<< "$layout")
    [[ $installed_root_uuid == "${root_uuids[index]}" ]]
    [[ $installed_verity_uuid == "${verity_uuids[index]}" ]]
    matching_uki_entry "$index"
    guest "bootctl set-default '$MATCHING_UKI_ENTRY'"
}

start_source() {
    guest "systemctl stop '$source_service' 2>/dev/null || true; systemd-run --unit='$source_service' --property=Type=exec python3 -m http.server '$SOURCE_PORT' --bind 127.0.0.1 --directory '$remote_dir/source'"
    guest "curl --fail --silent --show-error 'http://127.0.0.1:$SOURCE_PORT/SHA256SUMS' >/dev/null"
}

capture_console() {
    local destination=$1
    incus --project "$INCUS_PROJECT" console "$incus_target" --show-log > "$destination" 2>/dev/null
}

wait_for_failed_new_boot_since() {
    local baseline=$1 current="$workdir/console.current" deadline
    local before_boots current_boots before_emergencies current_emergencies before_size current_size
    before_boots=$(grep -c "roothash=${expected_roothashes[2]}" "$baseline" || true)
    before_emergencies=$(grep -c 'Entering emergency mode' "$baseline" || true)
    before_size=$(stat -c %s "$baseline")
    deadline=$((SECONDS + SSH_TIMEOUT))
    while (( SECONDS < deadline )); do
        capture_console "$current"
        current_boots=$(grep -c "roothash=${expected_roothashes[2]}" "$current" || true)
        current_emergencies=$(grep -c 'Entering emergency mode' "$current" || true)
        current_size=$(stat -c %s "$current")
        if (( current_boots > before_boots && current_emergencies > before_emergencies )); then
            return 0
        fi
        # Incus normally appends its console log. Also handle a rotated log by
        # requiring both this N+3 roothash and an emergency marker in new data.
        if (( current_boots > 0 && current_emergencies > 0 )) && {
            (( current_size < before_size )) || ! cmp -s -n "$before_size" "$baseline" "$current";
        }; then
            return 0
        fi
        sleep 2
    done
    echo "Error: corrupt update did not reach emergency mode within ${SSH_TIMEOUT}s" >&2
    return 1
}

force_stop() {
    incus --project "$INCUS_PROJECT" stop "$incus_target" --force
}

start_instance() {
    incus --project "$INCUS_PROJECT" start "$incus_target"
}

declare -a expected_roothashes=()
for prefix in "${prefixes[@]}"; do
    manifest="${prefix}.manifest"
    raw="${prefix}.raw"
    uki="${prefix}.efi"
    root="${prefix}.cayo_@v.root.raw.raw"
    verity="${prefix}.cayo_@v.root-verity.raw.raw"
    for file in "$manifest" "$raw" "$uki" "$root" "$verity"; do
        [[ -f $file ]] || { echo "Error: required artifact not found: $file" >&2; exit 1; }
    done
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
    uki_hash=$(sha256sum "$uki")
    versions+=("$version")
    root_uuids+=("$root_uuid")
    verity_uuids+=("$verity_uuid")
    expected_roothashes+=("${root_uuid//-/}${verity_uuid//-/}")
    uki_hashes+=("${uki_hash%% *}")
done
for index in 1 2; do
    dpkg --compare-versions "${versions[index]}" gt "${versions[index-1]}" || {
        echo "Error: versions are not strictly increasing: ${versions[*]}" >&2
        exit 1
    }
done

openssl x509 -in "$old_certificate" -pubkey -noout > "$workdir/old.pub"
cp "$new_public_key" "$workdir/new.pub"
old_fingerprint=$(public_fingerprint "$workdir/old.pub")
new_fingerprint=$(public_fingerprint "$workdir/new.pub")
[[ $old_fingerprint != "$new_fingerprint" ]] || {
    echo "Error: old and new PCR keys are identical" >&2
    exit 1
}

"$script_dir/native-ab-secure-artifact-test.sh" \
    "${prefixes[0]}.manifest" "${prefixes[0]}.efi" "$old_certificate" "$new_public_key"
"$script_dir/native-ab-secure-artifact-test.sh" \
    "${prefixes[1]}.manifest" "${prefixes[1]}.efi" "$old_certificate" "$new_public_key"
"$script_dir/native-ab-secure-artifact-test.sh" \
    "${prefixes[2]}.manifest" "${prefixes[2]}.efi" '' "$new_public_key" single

incus_info=$(incus --project "$INCUS_PROJECT" info "$incus_target")
grep -q '^Type: virtual-machine$' <<< "$incus_info" || {
    echo "Error: Incus target is not a virtual machine: $incus_target" >&2
    exit 1
}
grep -q '^Status: RUNNING$' <<< "$incus_info" || {
    echo "Error: Incus target is not running: $incus_target" >&2
    exit 1
}
actual_machine_id=$(guest 'cat /etc/machine-id')
[[ $actual_machine_id == "$expected_machine_id" ]] || {
    echo "Error: target machine-id $actual_machine_id does not match explicit expected ID" >&2
    exit 1
}
[[ $(guest_version) == "${versions[0]}" ]] || {
    echo "Error: target is not running CURRENT_PREFIX ${versions[0]}" >&2
    exit 1
}
guest 'test -e /usr/lib/snosi/native-ab'
# shellcheck disable=SC2016  # command expands in the guest.
guest 'for command in bootctl cryptsetup curl findmnt jq mokutil python3 sha256sum systemd-sysupdate xz; do command -v "$command" >/dev/null || exit 1; done'
var_device=$(guest "lsblk -J -o PATH,PARTLABEL | jq -er '.. | objects | select(.partlabel? == \"var\") | .path'")
guest_with_input "$recovery_key" "cryptsetup open --test-passphrase --key-file=- '$var_device'"
assert_new_only_token

guest "printf '%s\n' var-persist > /var/native-ab-secure-update-test"
guest "printf '%s\n' etc-persist > /etc/native-ab-secure-update-test"
verify_boot 0
current_root_path=$(partition_path "cayo_${versions[0]}_r")

echo "Preparing signed secure updates ${versions[1]} and ${versions[2]}"
for index in 1 2; do
    prefix=${prefixes[index]}
    xz -T0 -c "${prefix}.cayo_@v.root.raw.raw" > \
        "$workdir/source/cayo_${versions[index]}_${root_uuids[index]}.root.raw.xz"
    xz -T0 -c "${prefix}.cayo_@v.root-verity.raw.raw" > \
        "$workdir/source/cayo_${versions[index]}_${verity_uuids[index]}.root-verity.raw.xz"
    cp "${prefix}.efi" "$workdir/source/cayo-ab_${versions[index]}.efi"
done
for file in "$workdir/source"/*; do
    name=${file##*/}
    hash=$(sha256sum "$file")
    printf '%s  %s\n' "${hash%% *}" "$name" >> "$workdir/source/SHA256SUMS"
done
gpg --homedir "$workdir/gnupg" --batch --passphrase '' --quick-generate-key \
    'snosi secure update test <native-ab-secure-update@invalid>' ed25519 sign 0
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
MatchPattern=cayo-ab_@v.efi
[Target]
Type=regular-file
Path=/EFI/Linux
PathRelativeTo=boot
MatchPattern=cayo-ab_@v+@l-@d.efi
MatchPattern=cayo-ab_@v+@l.efi
MatchPattern=cayo-ab_@v.efi
Mode=0444
TriesLeft=3
TriesDone=0
InstancesMax=2
EOF

guest "rm -rf '$remote_dir' && mkdir -p '$remote_dir/source' '$remote_dir/definitions'"
scp "${scp_options[@]}" -r "$workdir/source/." "$ssh_target:$remote_dir/source/"
scp "${scp_options[@]}" -r "$workdir/definitions/." "$ssh_target:$remote_dir/definitions/"
scp "${scp_options[@]}" "$workdir/import-pubring.gpg" "$ssh_target:$remote_dir/"
guest "if test -e /etc/systemd/import-pubring.gpg; then cp -a /etc/systemd/import-pubring.gpg '$remote_dir/import-pubring.backup'; else touch '$remote_dir/import-pubring.absent'; fi; install -m 0644 '$remote_dir/import-pubring.gpg' /etc/systemd/import-pubring.gpg"
start_source

install_update 1
dual_root_path=$(partition_path "cayo_${versions[1]}_r")
[[ $dual_root_path != "$current_root_path" ]] || {
    echo "Error: N+2 overwrote the running N+1 slot" >&2
    exit 1
}
reboot_guest
verify_boot 1
start_source

install_update 2
new_root_path=$(partition_path "cayo_${versions[2]}_r")
[[ $new_root_path == "$current_root_path" ]] || {
    echo "Error: N+3 did not reuse the inactive N+1 slot" >&2
    exit 1
}
reboot_guest
verify_boot 2

echo "Testing explicit rollback to dual-signed ${versions[1]}"
matching_uki_entry 1
guest "bootctl set-oneshot '$MATCHING_UKI_ENTRY'"
reboot_guest
verify_boot 1

echo "Returning to new-only ${versions[2]}"
matching_uki_entry 2
guest "bootctl set-oneshot '$MATCHING_UKI_ENTRY'"
reboot_guest
verify_boot 2

echo "Testing boot-count fallback from corrupt ${versions[2]} to ${versions[1]}"
bad_root_path=$(partition_path "cayo_${versions[2]}_r")
matching_uki_entry 2
[[ $MATCHING_UKI_ENTRY == "cayo-ab_${versions[2]}.efi" ]] || {
    echo "Error: N+3 was not blessed before boot-count re-arming: $MATCHING_UKI_ENTRY" >&2
    exit 1
}
rearmed_entry="cayo-ab_${versions[2]}+3-0.efi"
guest "mv '/boot/EFI/Linux/$MATCHING_UKI_ENTRY' '/boot/EFI/Linux/$rearmed_entry'; sync -f /boot; bootctl set-default '$rearmed_entry'; test -e '/boot/EFI/Linux/$rearmed_entry'"
guest "dd if=/dev/zero of='$bad_root_path' bs=4096 count=1 conv=fsync status=none"

for attempt in 1 2 3; do
    baseline="$workdir/console.before.$attempt"
    if [[ $attempt -eq 1 ]]; then
        capture_console "$baseline"
        guest 'systemctl reboot' || true
    else
        force_stop
        capture_console "$baseline"
        start_instance
    fi
    echo "Waiting for failed boot attempt $attempt of 3..."
    wait_for_failed_new_boot_since "$baseline"
done

force_stop
start_instance
wait_for_guest
verify_boot 1
guest "test -e /boot/EFI/Linux/cayo-ab_${versions[2]}+0-3.efi"

echo "Native A/B secure update passed: ${versions[0]} -> ${versions[1]} -> ${versions[2]} -> rollback/fallback ${versions[1]}"
