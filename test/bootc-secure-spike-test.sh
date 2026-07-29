#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Feasibility gate for bootc 1.16.3 UKIs sealed to a composefs rootfs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH="/usr/sbin:/sbin:$PATH"
if [[ -n ${SUDO_USER:-} ]]; then
    _secure_vm_user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    PATH="$_secure_vm_user_home/.local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
    export HOME="$_secure_vm_user_home"
else
    PATH="$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
fi
BOOTC_BIN="${BOOTC_SECURE_BOOTC:-bootc}"
# Task 2 uses the shared loopback lifecycle helper for its external filesystem.
source "$ROOT_DIR/test/lib/vm.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/test/lib/secure-vm.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/test/lib/ssh.sh"

PASS=0
FAIL=0
ROOTFS=""
PCR_PUBLIC=""
STAGED_UKI=""
INJECTED_UKI=""
BUILDAH_CONTAINER=""
BUILDAH_MOUNTPOINT=""
BUILDAH_IMAGE_REF=""
TASK2_WORK=""
TASK2_IMAGE_REF=""
TASK2_FIRST_IMAGE_REF=""
TASK2_FINAL_DIGEST=""
TASK3_QEMU_PID=""
TASK3_CONSOLE_PUMP_PID=""
: "${BOOTC_SECURE_KEEP_DIAGNOSTICS:=0}"

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

assert_failure() {
    local description=$1
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$description"
    else
        pass "$description"
    fi
}

assert_equals() {
    local description=$1 actual=$2 expected=$3
    if [[ "$actual" == "$expected" ]]; then
        pass "$description"
    else
        fail "$description (expected '$expected', got '$actual')"
    fi
}

expected_uki_path() { # rootfs kernel-version
    printf '%s/boot/EFI/Linux/%s.efi\n' "$1" "$2"
}

valid_composefs_digest() { # digest
    [[ $1 =~ ^[[:xdigit:]]{128}$ ]]
}

composefs_digest_from_cmdline() { # cmdline text
    local cmdline=$1 token value="" matches=0
    for token in $cmdline; do
        [[ $token == composefs=* ]] || continue
        value=${token#composefs=}
        value=${value%%,*}
        # composefs-rs marks missing fs-verity with a leading question mark.
        value=${value#\?}
        matches=$((matches + 1))
    done
    [[ $matches -eq 1 ]] || {
        echo "Error: expected exactly one composefs= kernel argument" >&2
        return 1
    }
    valid_composefs_digest "$value" || {
        echo "Error: composefs kernel argument is not a SHA-512 digest: $value" >&2
        return 1
    }
    printf '%s\n' "$value"
}

pcr_public_fingerprint() { # PEM public key
    local public_key=$1
    if python3 "$ROOT_DIR/test/lib/pubkey-fingerprint.py" "$public_key" 2>/dev/null; then
        return 0
    fi
    # The shared helper uses RSA PKCS#1 DER. Keep fixtures runnable where its
    # optional cryptography module is unavailable.
    openssl rsa -pubin -in "$public_key" -RSAPublicKey_out -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1
}

validate_pcr_signatures() { # pcrsig-json pcr-public-key
    local pcrsig=$1 pcr_public=$2 fingerprint
    fingerprint=$(pcr_public_fingerprint "$pcr_public")
    jq -e --arg fingerprint "$fingerprint" '
        .sha256 as $signatures
        | ($signatures | type == "array")
        and ($signatures | length == 4)
        and (($signatures | group_by(.pol)) | length == 4)
        and all($signatures[];
            (.pol | type == "string")
            and (.pkfp | type == "string")
            and .pkfp == $fingerprint)
    ' "$pcrsig" >/dev/null
}

validate_task3_tpm_token_policy() { # [luks-json], otherwise stdin
    jq -e '
        [.tokens[] | select(.type == "systemd-tpm2")] as $tokens
        | ($tokens | length == 1)
        and ($tokens[0]."tpm2-pcrs" == [])
        and ($tokens[0].tpm2_pubkey_pcrs == [11])
        and (($tokens[0] | has("tpm2-pcrlock")) | not)
    ' "${1:-/dev/stdin}" >/dev/null
}

cleanup() {
    local status=$?
    set +e
    [[ -z "$BUILDAH_MOUNTPOINT" || -z "$BUILDAH_CONTAINER" ]] || buildah umount "$BUILDAH_CONTAINER" >/dev/null 2>&1
    [[ -z "$BUILDAH_CONTAINER" ]] || buildah rm "$BUILDAH_CONTAINER" >/dev/null 2>&1
    [[ -z "$BUILDAH_IMAGE_REF" ]] || buildah rmi "$BUILDAH_IMAGE_REF" >/dev/null 2>&1
    [[ -z "$INJECTED_UKI" ]] || rm -f -- "$INJECTED_UKI"
    [[ -z "$STAGED_UKI" ]] || rm -f -- "$STAGED_UKI"
    [[ -z "$PCR_PUBLIC" ]] || rm -f -- "$PCR_PUBLIC"
    destroy_dps_luks_btrfs_root
    [[ -z "$TASK2_IMAGE_REF" ]] || buildah rmi "$TASK2_IMAGE_REF" >/dev/null 2>&1
    [[ -z "$TASK2_FIRST_IMAGE_REF" ]] || buildah rmi "$TASK2_FIRST_IMAGE_REF" >/dev/null 2>&1
    [[ -z "$TASK3_CONSOLE_PUMP_PID" ]] || kill "$TASK3_CONSOLE_PUMP_PID" >/dev/null 2>&1
    [[ -z "$TASK3_QEMU_PID" ]] || kill "$TASK3_QEMU_PID" >/dev/null 2>&1
    secure_vm_stop_swtpm
    if [[ "$BOOTC_SECURE_KEEP_DIAGNOSTICS" == 1 && -n "$TASK2_WORK" ]]; then
        echo "Task 3 diagnostics retained at $TASK2_WORK" >&2
    else
        [[ -z "$TASK2_WORK" ]] || rm -rf -- "$TASK2_WORK"
    fi
    return "$status"
}
trap cleanup EXIT

validate_credentials() { # mok-key mok-cert pcr-key [pcr-public-key]
    local mok_key=$1 mok_cert=$2 pcr_key=$3 pcr_public=${4:-}
    local work
    work=$(mktemp -d)

    [[ -f "$mok_key" && -f "$mok_cert" && -f "$pcr_key" ]] || {
        echo "Error: MOK key, MOK certificate, and PCR key must be regular files" >&2
        rm -rf "$work"
        return 1
    }
    openssl pkey -in "$mok_key" -pubout -out "$work/mok-key.pub" >/dev/null 2>&1
    openssl x509 -in "$mok_cert" -pubkey -noout >"$work/mok-cert.pub"
    cmp -s "$work/mok-key.pub" "$work/mok-cert.pub" || {
        echo "Error: MOK key does not match MOK certificate" >&2
        rm -rf "$work"
        return 1
    }
    openssl pkey -in "$pcr_key" -text -noout 2>/dev/null | grep -q 'Private-Key: (2048 bit' || {
        echo "Error: PCR key must be RSA-2048" >&2
        rm -rf "$work"
        return 1
    }
    openssl pkey -in "$pcr_key" -pubout -out "$work/pcr.pub" >/dev/null 2>&1
    if [[ -n "$pcr_public" ]]; then
        [[ -f "$pcr_public" ]] || { echo "Error: PCR public key is missing" >&2; rm -rf "$work"; return 1; }
        cmp -s "$work/pcr.pub" "$pcr_public" || {
            echo "Error: PCR key does not match PCR public key" >&2
            rm -rf "$work"
            return 1
        }
    fi
    rm -rf "$work"
}

discover_kernel() { # rootfs
    local rootfs=$1
    local -a kernels=()
    local kernel version
    [[ -d "$rootfs/usr/lib/modules" ]] || {
        echo "Error: no kernel directory under $rootfs/usr/lib/modules" >&2
        return 1
    }
    while IFS= read -r kernel; do kernels+=("$kernel"); done < <(
        printf '%s\n' "$rootfs"/usr/lib/modules/*/ | sed 's:/$::' | sort -V
    )
    [[ ${#kernels[@]} -eq 1 && -d ${kernels[0]:-} ]] || {
        echo "Error: expected exactly one kernel under $rootfs/usr/lib/modules" >&2
        return 1
    }
    kernel=${kernels[0]}
    version=${kernel##*/}
    [[ -f "$kernel/vmlinuz" && -f "$kernel/initramfs.img" ]] || {
        echo "Error: kernel $version must contain vmlinuz and initramfs.img" >&2
        return 1
    }
    printf '%s\t%s\t%s\n' "$version" "$kernel/vmlinuz" "$kernel/initramfs.img"
}

refuse_existing_uki() { # rootfs
    local rootfs=$1
    local -a ukis=()
    shopt -s nullglob
    ukis=("$rootfs"/boot/EFI/Linux/*.efi)
    shopt -u nullglob
    [[ ${#ukis[@]} -eq 0 ]] || {
        echo "Error: pre-existing UKI refused: ${ukis[*]}" >&2
        return 1
    }
}

validate_dps_layout() { # lsblk-json
    local layout=$1
    jq -e '
        def nodes: . as $node | $node, (($node.children // [])[] | nodes);
        [ .blockdevices[] | nodes ] as $nodes
        | any($nodes[];
            (.type == "part")
            and ((.parttype // "") | ascii_downcase == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
            and (.size == 1073741824)
            and (.fstype == "vfat"))
        and any($nodes[];
            (.type == "part")
            and ((.parttype // "") | ascii_downcase == "4f68bce3-e8cd-4db1-96e7-fbcaf984b709")
            and (.fstype == "crypto_LUKS")
            and ([ nodes | select(.type == "crypt") ] | length == 1)
            and ([ nodes | select(.fstype == "btrfs") ] | length >= 1))
    ' "$layout" >/dev/null
}

colocated_esp_from_lsblk() { # lsblk-json encrypted-root-backing-partition
    local layout=$1 backing_partition=$2 disk
    local -a esps=()
    disk=$(jq -er --arg backing_partition "$backing_partition" '
        def nodes: . as $node | $node, (($node.children // [])[] | nodes);
        [ .blockdevices[] | nodes
          | select(.path? == $backing_partition)
          | .pkname
        ] | unique
        | if length == 1 then .[0] else error("expected one backing disk") end
    ' "$layout") || return 1
    while IFS= read -r esp; do esps+=("$esp"); done < <(
        jq -er --arg disk "$disk" '
            def nodes: . as $node | $node, (($node.children // [])[] | nodes);
            .blockdevices[] | nodes
            | select(.type == "part"
                and .pkname == $disk
                and ((.parttype // "") | ascii_downcase == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"))
            | .path
        ' "$layout"
    )
    [[ ${#esps[@]} -eq 1 ]] || {
        echo "Error: expected exactly one EFI System Partition beside $backing_partition" >&2
        return 1
    }
    printf '%s\n' "${esps[0]}"
}

task3_bootctl_status() { # esp-mountpoint
    # status is informational and returns nonzero when optional EFI state is
    # unavailable; the explicit evidence checks below remain fail-closed.
    bootctl --esp-path="$1" --no-pager status || true
}

validate_task3_bootctl_status() { # status-text expected-uki-path
    grep -Fq 'Secure Boot: enabled' <<<"$1" \
        && grep -Fq 'Measured UKI: yes' <<<"$1" \
        && grep -Fq "$2" <<<"$1"
}

task3_copy_recovery_key() {
    vm_ssh 'umask 077; cat > /run/task3-recovery.key'
}

task3_remove_enrollment_credentials() {
    vm_ssh 'shred -u /run/task3-recovery.key /run/task3-pcr.pub'
}

task3_wait_for_new_boot() { # previous-boot-id
    local previous_boot_id=$1 current_boot_id deadline
    deadline=$((SECONDS + SSH_TIMEOUT))
    echo "Waiting up to ${SSH_TIMEOUT}s for a new boot..."
    while (( SECONDS < deadline )); do
        if current_boot_id=$(vm_ssh 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) \
            && [[ "$current_boot_id" != "$previous_boot_id" ]]; then
            echo "New boot available: $current_boot_id"
            return 0
        fi
        sleep 2
    done
    echo "Error: target did not return with a new boot within ${SSH_TIMEOUT}s" >&2
    return 1
}

validate_type2_uki_layout() { # esp-root deployment-id
    local esp_root=$1 deployment_id=$2
    local entry expected_uki efi_entries=0
    [[ $deployment_id =~ ^[[:xdigit:]]{128}$ ]] || return 1
    expected_uki="$esp_root/EFI/Linux/bootc/bootc_composefs-${deployment_id}.efi"
    [[ -f "$expected_uki" ]] || return 1
    shopt -s nullglob
    local -a entries=("$esp_root"/loader/entries/*.conf)
    shopt -u nullglob
    [[ ${#entries[@]} -gt 0 ]] || return 1
    for entry in "${entries[@]}"; do
        grep -Eq '^[[:space:]]*(linux|initrd)[[:space:]]+' "$entry" && return 1
        if grep -Eq "^[[:space:]]*efi[[:space:]]+/EFI/Linux/bootc/bootc_composefs-${deployment_id}\\.efi[[:space:]]*$" "$entry"; then
            efi_entries=$((efi_entries + 1))
        fi
    done
    [[ $efi_entries -eq 1 ]]
}

require_stable_oci_digest() { # first-pass-digest final-digest
    local first_digest=$1 final_digest=$2
    valid_composefs_digest "$first_digest"
    valid_composefs_digest "$final_digest"
    [[ "$first_digest" == "$final_digest" ]]
}

validate_task2_ukify_cmdline() { # cmdline expected-composefs-digest
    local cmdline=$1 expected_digest=$2 token composefs_count=0 rw_count=0 token_count=0
    valid_composefs_digest "$expected_digest" || return 1
    for token in $cmdline; do
        token_count=$((token_count + 1))
        [[ "$token" == rw ]] && rw_count=$((rw_count + 1))
        [[ "$token" == composefs=* ]] && composefs_count=$((composefs_count + 1))
        [[ "$token" != root=* && "$token" != luks.* && "$token" != rd.luks.* ]] || return 1
    done
    [[ $token_count -eq 2 && $rw_count -eq 1 && $composefs_count -eq 1 ]] || return 1
    [[ "$(composefs_digest_from_cmdline "$cmdline")" == "$expected_digest" ]]
}

installed_deployment_id() { # installed-root
    local root=$1
    local -a deployments=()
    shopt -s nullglob
    deployments=("$root"/state/deploy/[[:xdigit:]][[:xdigit:]]*)
    shopt -u nullglob
    [[ ${#deployments[@]} -eq 1 ]] || return 1
    basename "${deployments[0]}"
}

run_fixture_tests() {
    fixture_root=$(mktemp -d)

    mkdir -p "$fixture_root/rootfs/boot/EFI/Linux"
    touch "$fixture_root/rootfs/boot/EFI/Linux/old.efi"
    mkdir -p "$fixture_root/valid-root/usr/lib/modules/6.1.0-test"
    touch "$fixture_root/valid-root/usr/lib/modules/6.1.0-test/vmlinuz"
    touch "$fixture_root/valid-root/usr/lib/modules/6.1.0-test/initramfs.img"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$fixture_root/mok.key" >/dev/null 2>&1
    openssl req -new -x509 -key "$fixture_root/mok.key" -subj /CN=fixture-mok -days 1 \
        -out "$fixture_root/mok.crt" >/dev/null 2>&1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$fixture_root/pcr.key" >/dev/null 2>&1
    openssl pkey -in "$fixture_root/pcr.key" -pubout -out "$fixture_root/pcr.pub" >/dev/null 2>&1

    assert_failure "missing MOK credentials are rejected" \
        validate_credentials "$fixture_root/missing-mok.key" "$fixture_root/mok.crt" "$fixture_root/pcr.key"
    if validate_credentials "$fixture_root/mok.key" "$fixture_root/mok.crt" "$fixture_root/pcr.key"; then
        pass "matching MOK and RSA-2048 PCR credentials are accepted"
    else
        fail "matching MOK and RSA-2048 PCR credentials are accepted"
    fi
    assert_failure "a rootfs without a kernel is rejected" discover_kernel "$fixture_root/rootfs"
    assert_equals "exactly one kernel and initramfs are discovered" \
        "$(discover_kernel "$fixture_root/valid-root")" \
        $'6.1.0-test\t'"$fixture_root"$'/valid-root/usr/lib/modules/6.1.0-test/vmlinuz\t'"$fixture_root"$'/valid-root/usr/lib/modules/6.1.0-test/initramfs.img'
    assert_failure "a pre-existing UKI is rejected" refuse_existing_uki "$fixture_root/rootfs"
    assert_equals "expected UKI path is under EFI/Linux" \
        "$(expected_uki_path "$fixture_root/rootfs" "6.1.0-test")" \
        "$fixture_root/rootfs/boot/EFI/Linux/6.1.0-test.efi"
    assert_equals "composefs cmdline parsing removes the insecure suffix" \
        "$(composefs_digest_from_cmdline "quiet composefs=$(printf 'a%.0s' {1..128}),insecure")" \
        "$(printf 'a%.0s' {1..128})"
    assert_equals "composefs cmdline parsing removes the observed insecure prefix" \
        "$(composefs_digest_from_cmdline "quiet composefs=?$(printf 'b%.0s' {1..128})")" \
        "$(printf 'b%.0s' {1..128})"
    assert_failure "missing composefs cmdline is rejected" \
        composefs_digest_from_cmdline "quiet splash"
    assert_failure "non-SHA-512 composefs digest is rejected" valid_composefs_digest "not-a-digest"

    fixture_pcr_fp=$(pcr_public_fingerprint "$fixture_root/pcr.pub")
    jq -n --arg fp "$fixture_pcr_fp" '
        {sha256: [range(0; 4) | {pol: ("policy-" + tostring), pkfp: $fp}]}
    ' >"$fixture_root/pcrsig.json"
    if validate_pcr_signatures "$fixture_root/pcrsig.json" "$fixture_root/pcr.pub"; then
        pass "four distinct PCR policies signed by the published key are accepted"
    else
        fail "four distinct PCR policies signed by the published key are accepted"
    fi
    jq '.sha256[0].pkfp = "00"' "$fixture_root/pcrsig.json" >"$fixture_root/pcrsig-wrong-key.json"
    assert_failure "PCR signature fingerprint mismatch is rejected" \
        validate_pcr_signatures "$fixture_root/pcrsig-wrong-key.json" "$fixture_root/pcr.pub"
    jq '.sha256[3].pol = .sha256[2].pol' "$fixture_root/pcrsig.json" >"$fixture_root/pcrsig-duplicate-policy.json"
    assert_failure "duplicate PCR policy entries are rejected" \
        validate_pcr_signatures "$fixture_root/pcrsig-duplicate-policy.json" "$fixture_root/pcr.pub"

    cat >"$fixture_root/tpm-token.json" <<'EOF'
{"tokens":{"0":{"type":"systemd-tpm2","tpm2-pcrs":[],"tpm2_pubkey_pcrs":[11]}}}
EOF
    if validate_task3_tpm_token_policy "$fixture_root/tpm-token.json"; then
        pass "exactly one signed-PCR-11 TPM token is accepted"
    else
        fail "exactly one signed-PCR-11 TPM token is accepted"
    fi
    jq '.tokens["1"] = .tokens["0"]' "$fixture_root/tpm-token.json" >"$fixture_root/tpm-token-duplicate.json"
    assert_failure "duplicate systemd-tpm2 tokens are rejected" \
        validate_task3_tpm_token_policy "$fixture_root/tpm-token-duplicate.json"

    cat >"$fixture_root/layout.json" <<'EOF'
{"blockdevices":[{"name":"loop0","type":"disk","children":[{"name":"loop0p1","type":"part","parttype":"c12a7328-f81f-11d2-ba4b-00a0c93ec93b","size":1073741824,"fstype":"vfat"},{"name":"loop0p2","type":"part","parttype":"4f68bce3-e8cd-4db1-96e7-fbcaf984b709","size":2147483648,"fstype":"crypto_LUKS","children":[{"name":"cryptroot","type":"crypt","fstype":"crypto_LUKS","children":[{"name":"btrfs-root","type":"lvm","fstype":"btrfs"}]}]}]}]}
EOF
    if validate_dps_layout "$fixture_root/layout.json"; then
        pass "a 1 GiB ESP and DPS LUKS2/Btrfs root layout are accepted"
    else
        fail "a 1 GiB ESP and DPS LUKS2/Btrfs root layout are accepted"
    fi
    jq '(.blockdevices[0].children[0].size = 536870912)' "$fixture_root/layout.json" >"$fixture_root/layout-small-esp.json"
    assert_failure "an ESP smaller than 1 GiB is rejected" \
        validate_dps_layout "$fixture_root/layout-small-esp.json"

    cat >"$fixture_root/guest-block.json" <<'EOF'
{"blockdevices":[{"path":"/dev/vda","name":"vda","type":"disk","children":[{"path":"/dev/vda1","name":"vda1","pkname":"vda","type":"part","parttype":"c12a7328-f81f-11d2-ba4b-00a0c93ec93b"},{"path":"/dev/vda2","name":"vda2","pkname":"vda","type":"part","parttype":"4f68bce3-e8cd-4db1-96e7-fbcaf984b709","children":[{"path":"/dev/mapper/root","name":"root","pkname":"vda2","type":"crypt"}]}]}]}
EOF
    assert_equals "the unique ESP beside the encrypted root backing partition is selected" \
        "$(colocated_esp_from_lsblk "$fixture_root/guest-block.json" /dev/vda2)" "/dev/vda1"
    jq '(.blockdevices[0].children[0].parttype = "00000000-0000-0000-0000-000000000000")' \
        "$fixture_root/guest-block.json" >"$fixture_root/guest-block-no-esp.json"
    assert_failure "no colocated ESP is rejected" \
        colocated_esp_from_lsblk "$fixture_root/guest-block-no-esp.json" /dev/vda2
    jq '.blockdevices[0].children += [{"path":"/dev/vda3","name":"vda3","pkname":"vda","type":"part","parttype":"c12a7328-f81f-11d2-ba4b-00a0c93ec93b"}]' \
        "$fixture_root/guest-block.json" >"$fixture_root/guest-block-two-esp.json"
    assert_failure "multiple colocated ESPs are rejected" \
        colocated_esp_from_lsblk "$fixture_root/guest-block-two-esp.json" /dev/vda2

    mkdir -p "$fixture_root/fakebin"
    cat >"$fixture_root/fakebin/bootctl" <<'EOF'
#!/bin/sh
printf '%s\n' 'Secure Boot: enabled (user)' 'Measured UKI: yes' 'Stub: /EFI/Linux/fixture.efi'
exit 1
EOF
    chmod +x "$fixture_root/fakebin/bootctl"
    if status=$(PATH="$fixture_root/fakebin:$PATH" task3_bootctl_status /fixture-esp) \
        && validate_task3_bootctl_status "$status" /EFI/Linux/fixture.efi; then
        pass "bootctl status evidence is preserved when optional status probes make it exit nonzero"
    else
        fail "bootctl status evidence is preserved when optional status probes make it exit nonzero"
    fi
    original_vm_ssh=$(declare -f vm_ssh)
    vm_ssh() { printf '%s\n' "$*"; cat; }
    if copied=$(printf '%s' fixture-recovery | task3_copy_recovery_key) \
        && [[ "$copied" == $'umask 077; cat > /run/task3-recovery.key\nfixture-recovery' ]]; then
        pass "the recovery key is copied privately through the shared SSH helper"
    else
        fail "the recovery key is copied privately through the shared SSH helper"
    fi
    if cleaned=$(task3_remove_enrollment_credentials) \
        && [[ "$cleaned" == 'shred -u /run/task3-recovery.key /run/task3-pcr.pub' ]]; then
        pass "guest enrollment credentials are removed after use"
    else
        fail "guest enrollment credentials are removed after use"
    fi
    eval "$original_vm_ssh"
    original_vm_ssh=$(declare -f vm_ssh)
    vm_ssh() { printf '%s\n' new-boot-id; }
    if task3_wait_for_new_boot old-boot-id; then
        pass "the reboot wait requires a changed kernel boot ID"
    else
        fail "the reboot wait requires a changed kernel boot ID"
    fi
    eval "$original_vm_ssh"

    mkdir -p "$fixture_root/esp/EFI/Linux/bootc" "$fixture_root/esp/loader/entries"
    touch "$fixture_root/esp/EFI/Linux/bootc/bootc_composefs-$(printf 'c%.0s' {1..128}).efi"
    cat >"$fixture_root/esp/loader/entries/bootc.conf" <<EOF
title fixture
efi /EFI/Linux/bootc/bootc_composefs-$(printf 'c%.0s' {1..128}).efi
EOF
    if validate_type2_uki_layout "$fixture_root/esp" "$(printf 'c%.0s' {1..128})"; then
        pass "a Type #2 UKI BLS entry bound to the deployment is accepted"
    else
        fail "a Type #2 UKI BLS entry bound to the deployment is accepted"
    fi
    cat >"$fixture_root/esp/loader/entries/raw.conf" <<'EOF'
title raw fallback
linux /EFI/Linux/vmlinuz
initrd /EFI/Linux/initrd
EOF
    assert_failure "raw kernel and initrd BLS fallback is rejected" \
        validate_type2_uki_layout "$fixture_root/esp" "$(printf 'c%.0s' {1..128})"
    if require_stable_oci_digest "$(printf 'd%.0s' {1..128})" "$(printf 'd%.0s' {1..128})"; then
        pass "a final OCI image retaining its first-pass composefs ID is accepted"
    else
        fail "a final OCI image retaining its first-pass composefs ID is accepted"
    fi
    assert_failure "a final OCI image changing the first-pass composefs ID is rejected" \
        require_stable_oci_digest "$(printf 'd%.0s' {1..128})" "$(printf 'e%.0s' {1..128})"
    if validate_task2_ukify_cmdline "rw composefs=?$(printf 'f%.0s' {1..128})" "$(printf 'f%.0s' {1..128})"; then
        pass "Task 2 UKI cmdline carries rw plus only its composefs binding"
    else
        fail "Task 2 UKI cmdline carries rw plus only its composefs binding"
    fi
    assert_failure "Task 2 UKI cmdline rejects dynamic root identifiers" \
        validate_task2_ukify_cmdline "rw composefs=?$(printf 'f%.0s' {1..128}) root=/dev/vda2" "$(printf 'f%.0s' {1..128})"
    assert_failure "Task 2 UKI cmdline rejects dynamic LUKS identifiers" \
        validate_task2_ukify_cmdline "rw composefs=?$(printf 'f%.0s' {1..128}) rd.luks.uuid=luks-test" "$(printf 'f%.0s' {1..128})"

    printf 'dracut first error\nemergency\n' >"$fixture_root/console.raw"
    fixture_console_diagnostics="$(task3_console_diagnostics "$fixture_root/console.raw")"
    if [[ "$fixture_console_diagnostics" == *'dracut first error'* ]]; then
        pass "Task 3 diagnostics preserve complete raw console text"
    else
        fail "Task 3 diagnostics preserve complete raw console text"
    fi

    echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
    fixture_result=0
    [[ $FAIL -eq 0 ]] || fixture_result=1
    rm -rf "$fixture_root"
    return "$fixture_result"
}

require_prerequisites() {
    local missing=()
    local command
    for command in "$BOOTC_BIN" ukify sbverify objcopy objdump jq openssl buildah; do
        command -v "$command" >/dev/null 2>&1 || missing+=("$command")
    done
    [[ -d "$ROOTFS" ]] || missing+=("rootfs:$ROOTFS")
    [[ -n ${BOOTC_SECURE_MOK_KEY:-} && -f ${BOOTC_SECURE_MOK_KEY:-} ]] || missing+=("BOOTC_SECURE_MOK_KEY")
    [[ -n ${BOOTC_SECURE_MOK_CERT:-} && -f ${BOOTC_SECURE_MOK_CERT:-} ]] || missing+=("BOOTC_SECURE_MOK_CERT")
    [[ -n ${BOOTC_SECURE_PCR_KEY:-} && -f ${BOOTC_SECURE_PCR_KEY:-} ]] || missing+=("BOOTC_SECURE_PCR_KEY")
    if [[ ${#missing[@]} -ne 0 ]]; then
        echo "BLOCKED: real rootfs proof requires: ${missing[*]}" >&2
        return 2
    fi
}

require_task2_prerequisites() {
    local missing=()
    local command
    for command in podman sfdisk mkfs.vfat cryptsetup mkfs.btrfs losetup partprobe udevadm mount umount lsblk; do
        command -v "$command" >/dev/null 2>&1 || missing+=("$command")
    done
    if [[ ${#missing[@]} -ne 0 ]]; then
        echo "BLOCKED: encrypted DPS root proof requires: ${missing[*]}" >&2
        return 2
    fi
}

require_task3_prerequisites() {
    local missing=() command
    for command in qemu-system-x86_64 swtpm virt-fw-vars sbsign dpkg-deb apt-get ssh ssh-keygen cryptsetup; do
        command -v "$command" >/dev/null 2>&1 || missing+=("$command")
    done
    [[ -f "$SECURE_VM_OVMF_CODE" ]] || missing+=("$SECURE_VM_OVMF_CODE")
    [[ -f "$SECURE_VM_OVMF_VARS" ]] || missing+=("$SECURE_VM_OVMF_VARS")
    if [[ ${#missing[@]} -ne 0 ]]; then
        echo "BLOCKED: Secure Boot/TPM boot proof requires: ${missing[*]}" >&2
        return 2
    fi
}

composefs_digest() { # rootfs
    "$BOOTC_BIN" container compute-composefs-digest "$1" | tr -d '\n'
}

storage_composefs_digest() { # local-image-reference
    local image=$1
    podman run --rm --privileged --pid=host \
        -v /var/lib/containers:/var/lib/containers \
        --security-opt label=type:unconfined_t \
        "$image" \
        bootc container compute-composefs-digest-from-storage "$image" | tr -d '\n'
}

validate_uki() { # rootfs uki kernel initrd pcr-public-key expected-digest
(
    local rootfs=$1 uki=$2 kernel=$3 initrd=$4 pcr_public=$5 expected_digest=$6
    local work composefs_value cmdline
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT

    objcopy --dump-section ".cmdline=$work/cmdline" \
        --dump-section ".linux=$work/linux" \
        --dump-section ".initrd=$work/initrd" \
        --dump-section ".pcrpkey=$work/pcrpkey" \
        --dump-section ".pcrsig=$work/pcrsig" \
        "$uki" "$work/uki-copy.efi"
    cmp "$kernel" "$work/linux"
    cmp "$initrd" "$work/initrd"
    cmp "$pcr_public" "$work/pcrpkey"
    validate_pcr_signatures "$work/pcrsig" "$work/pcrpkey"
    objdump -h "$uki" | grep -q '[[:space:]]\.pcrpkey[[:space:]]'
    objdump -h "$uki" | grep -q '[[:space:]]\.pcrsig[[:space:]]'
    cmdline=$(tr '\0' ' ' <"$work/cmdline")
    composefs_value=$(composefs_digest_from_cmdline "$cmdline")
    [[ "$composefs_value" == "$expected_digest" ]] || {
        echo "Error: UKI composefs value '$composefs_value' does not match '$expected_digest'" >&2
        return 1
    }
    sbverify --cert "$BOOTC_SECURE_MOK_CERT" "$uki" >/dev/null
)
}

run_real_proof() {
    local kernel_info version kernel initrd installed_uki digest_before digest_after
    ROOTFS=${BOOTC_SECURE_ROOTFS:-$ROOT_DIR/output/cayo}
    require_prerequisites
    PCR_PUBLIC=$(mktemp)
    openssl pkey -in "$BOOTC_SECURE_PCR_KEY" -pubout -out "$PCR_PUBLIC" >/dev/null 2>&1
    validate_credentials "$BOOTC_SECURE_MOK_KEY" "$BOOTC_SECURE_MOK_CERT" "$BOOTC_SECURE_PCR_KEY" "$PCR_PUBLIC"
    kernel_info=$(discover_kernel "$ROOTFS")
    IFS=$'\t' read -r version kernel initrd <<<"$kernel_info"
    refuse_existing_uki "$ROOTFS"
    digest_before=$(composefs_digest "$ROOTFS")
    [[ "$digest_before" =~ ^[[:xdigit:]]{128}$ ]] || {
        echo "Error: bootc did not return a SHA-512 composefs digest: $digest_before" >&2
        return 1
    }

    STAGED_UKI=$(mktemp --suffix=.efi)
    "$BOOTC_BIN" container ukify --rootfs "$ROOTFS" --allow-missing-verity -- \
        --measure --output "$STAGED_UKI" \
        --secureboot-private-key "$BOOTC_SECURE_MOK_KEY" \
        --secureboot-certificate "$BOOTC_SECURE_MOK_CERT" \
        --pcr-private-key "$BOOTC_SECURE_PCR_KEY" \
        --pcrpkey "$PCR_PUBLIC"

    installed_uki=$(expected_uki_path "$ROOTFS" "$version")
    mkdir -p "$(dirname "$installed_uki")"
    INJECTED_UKI=$installed_uki
    cp "$STAGED_UKI" "$INJECTED_UKI"
    digest_after=$(composefs_digest "$ROOTFS")
    [[ "$digest_before" == "$digest_after" ]] || {
        echo "Error: injecting the UKI changed composefs digest" >&2
        return 1
    }
    validate_uki "$ROOTFS" "$INJECTED_UKI" "$kernel" "$initrd" "$PCR_PUBLIC" "$digest_after"

    BUILDAH_IMAGE_REF="localhost/snosi-bootc-secure-spike:$$"
    "$ROOT_DIR/shared/outformat/image/buildah-package.sh" "$ROOTFS" "$BUILDAH_IMAGE_REF"
    BUILDAH_CONTAINER=$(buildah from "$BUILDAH_IMAGE_REF")
    BUILDAH_MOUNTPOINT=$(buildah mount "$BUILDAH_CONTAINER")
    validate_uki "$BUILDAH_MOUNTPOINT" "$(expected_uki_path "$BUILDAH_MOUNTPOINT" "$version")" \
        "$kernel" "$initrd" "$PCR_PUBLIC" "$digest_after"
    echo "PASS: sealed UKI composefs binding and Buildah round-trip verified"
}

run_task2_live_proof() {
    local kernel_info version kernel initrd first_digest final_digest deployment_id layout_json uki
    require_task2_prerequisites
    # Task 1's directory-rootfs proof is complete. The two-pass OCI proof must
    # start with a pristine root so its first image has no injected UKI.
    [[ -n "$INJECTED_UKI" ]] && rm -f -- "$INJECTED_UKI"
    INJECTED_UKI=""
    refuse_existing_uki "$ROOTFS"
    TASK2_WORK=$(mktemp -d)
    TASK2_FIRST_IMAGE_REF="localhost/snosi-bootc-dps-first-pass:$$"
    TASK2_IMAGE_REF="localhost/snosi-bootc-dps-final:$$"
    kernel_info=$(discover_kernel "$ROOTFS")
    IFS=$'\t' read -r version kernel initrd <<<"$kernel_info"
    "$ROOT_DIR/shared/outformat/image/buildah-package.sh" "$ROOTFS" "$TASK2_FIRST_IMAGE_REF"
    first_digest=$(storage_composefs_digest "$TASK2_FIRST_IMAGE_REF")
    valid_composefs_digest "$first_digest" || {
        echo "Error: first-pass OCI composefs digest is not SHA-512: $first_digest" >&2
        return 1
    }
    ukify build \
        --linux "$kernel" \
        --initrd "$initrd" \
        --os-release "@$ROOTFS/usr/lib/os-release" \
        --cmdline "rw composefs=?$first_digest" \
        --uname "$version" \
        --pcrpkey "$PCR_PUBLIC" \
        --pcr-private-key "$BOOTC_SECURE_PCR_KEY" \
        --secureboot-private-key "$BOOTC_SECURE_MOK_KEY" \
        --secureboot-certificate "$BOOTC_SECURE_MOK_CERT" \
        --measure \
        --output "$TASK2_WORK/uki.efi"
    INJECTED_UKI=$(expected_uki_path "$ROOTFS" "$version")
    mkdir -p "$(dirname "$INJECTED_UKI")"
    cp "$TASK2_WORK/uki.efi" "$INJECTED_UKI"
    validate_uki "$ROOTFS" "$INJECTED_UKI" "$kernel" "$initrd" "$PCR_PUBLIC" "$first_digest"
    "$ROOT_DIR/shared/outformat/image/buildah-package.sh" "$ROOTFS" "$TASK2_IMAGE_REF"
    final_digest=$(storage_composefs_digest "$TASK2_IMAGE_REF")
    require_stable_oci_digest "$first_digest" "$final_digest" || {
        echo "Error: final OCI composefs digest changed from '$first_digest' to '$final_digest'" >&2
        return 1
    }
    printf '%s' 'task-2-disposable-recovery-key' >"$TASK2_WORK/recovery.key"
    chmod 600 "$TASK2_WORK/recovery.key"
    truncate -s 12G "$TASK2_WORK/disk.raw"
    create_dps_luks_btrfs_root "$TASK2_WORK/disk.raw" "$TASK2_WORK/root" "$TASK2_WORK/recovery.key"
    layout_json="$TASK2_WORK/layout.json"
    lsblk --json --bytes --output NAME,TYPE,PARTTYPE,SIZE,FSTYPE "$DPS_LOOP_DEVICE" >"$layout_json"
    validate_dps_layout "$layout_json" || {
        echo "Error: externally created encrypted DPS layout did not validate" >&2
        return 1
    }

    if ! podman run --rm --privileged --pid=host \
        -v /var/lib/containers:/var/lib/containers \
        -v /dev:/dev \
        -v "$DPS_ROOT_MOUNT:/target" \
        --security-opt label=type:unconfined_t \
        "$TASK2_IMAGE_REF" \
        bootc install to-filesystem \
        --generic-image \
        --skip-fetch-check \
        --composefs-backend \
        --allow-missing-verity \
        --bootloader systemd \
        --root-mount-spec "" \
        /target >"$TASK2_WORK/bootc-to-filesystem.log" 2>&1; then
        cat "$TASK2_WORK/bootc-to-filesystem.log" >&2
        return 1
    fi

    deployment_id=$(installed_deployment_id "$DPS_ROOT_MOUNT") || {
        echo "Error: expected exactly one installed composefs deployment" >&2
        return 1
    }
    [[ "$deployment_id" == "$final_digest" ]] || {
        echo "Error: installed deployment '$deployment_id' does not match final OCI digest '$final_digest'" >&2
        return 1
    }
    validate_type2_uki_layout "$DPS_ROOT_MOUNT/boot" "$deployment_id" || {
        echo "Error: bootc did not install a Type #2-only UKI layout" >&2
        return 1
    }
    uki="$DPS_ROOT_MOUNT/boot/EFI/Linux/bootc/bootc_composefs-${deployment_id}.efi"
    validate_uki "$DPS_ROOT_MOUNT" "$uki" "$kernel" "$initrd" "$PCR_PUBLIC" "$deployment_id"
    TASK2_FINAL_DIGEST=$final_digest
    echo "PASS: two-pass OCI UKI, encrypted DPS root, Type #2-only boot metadata, and composefs binding verified"
}

stage_task3_boot_chain() { # mounted-root workdir
    local root=$1 work=$2 package shim="" mmx="" loader="" candidate
    mkdir -p "$work/debs" "$work/extract"
    (
        cd "$work/debs"
        apt-get download shim-signed shim-helpers-amd64-signed >/dev/null
    )
    for package in "$work/debs"/*.deb; do
        dpkg-deb -x "$package" "$work/extract/$(basename "${package%.deb}")"
    done
    for candidate in "$work"/extract/*/usr/lib/shim/shimx64.efi.signed; do
        [[ -f "$candidate" ]] && shim=$candidate
    done
    for candidate in "$work"/extract/*/usr/lib/shim/mmx64.efi.signed; do
        [[ -f "$candidate" ]] && mmx=$candidate
    done
    for candidate in "$root/boot/EFI/systemd/systemd-bootx64.efi" \
        "$root/usr/lib/systemd/boot/efi/systemd-bootx64.efi"; do
        [[ -f "$candidate" ]] && loader=$candidate
    done
    [[ -f "$shim" && -f "$mmx" && -f "$loader" ]] || {
        echo "BLOCKED: Debian shim/MokManager or installed systemd-boot second-stage file is unavailable" >&2
        return 2
    }
    mount -o remount,rw "$root/boot" || {
        echo "BLOCKED: bootc left the Task 2 ESP read-only, so the shim chain cannot be installed" >&2
        return 2
    }
    mkdir -p "$root/boot/EFI/BOOT"
    cp "$shim" "$root/boot/EFI/BOOT/BOOTX64.EFI" || return 2
    cp "$mmx" "$root/boot/EFI/BOOT/mmx64.efi" || return 2
    # Shim resolves grubx64.efi beside itself. It is a MOK-signed systemd-boot PE.
    sbsign --key "$BOOTC_SECURE_MOK_KEY" --cert "$BOOTC_SECURE_MOK_CERT" \
        --output "$root/boot/EFI/BOOT/grubx64.efi" "$loader" || return 2
    sbverify --cert "$BOOTC_SECURE_MOK_CERT" "$root/boot/EFI/BOOT/grubx64.efi" >/dev/null
    sbverify --list "$root/boot/EFI/BOOT/BOOTX64.EFI" | grep -q 'Microsoft Corporation UEFI CA'
    sbverify --list "$root/boot/EFI/BOOT/mmx64.efi" | grep -q 'Debian Secure Boot'
    [[ ! -e "$root/boot/EFI/BOOT/fbx64.efi" ]] || {
        echo "BLOCKED: fbx64.efi is unsafe beside the removable-media shim" >&2
        return 2
    }
}

task3_start_vm() { # disk workdir
    local disk=$1 work=$2 pidfile="$2/qemu.pid"
    rm -f "$pidfile" "$work/serial.sock"
    qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 4096 -smp 2 \
        -drive "if=pflash,format=raw,unit=0,file=$work/OVMF_CODE.fd,readonly=on" \
        -drive "if=pflash,format=raw,unit=1,file=$work/OVMF_VARS.fd" \
        -drive "file=$disk,format=raw,if=virtio" \
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0 \
        -display none -vga none -chardev "socket,id=tpmchr,path=$SECURE_VM_TPM_SOCK" \
        -tpmdev emulator,id=tpm0,chardev=tpmchr -device tpm-crb,tpmdev=tpm0 \
        -chardev "socket,id=serial0,path=$work/serial.sock,server=on,wait=off" -serial chardev:serial0 \
        -monitor none -pidfile "$pidfile" -daemonize
    local i=0
    while [[ ! -S "$work/serial.sock" ]] && (( i++ < 50 )); do sleep 0.2; done
    [[ -S "$work/serial.sock" ]] || return 1
    TASK3_QEMU_PID="$(<"$pidfile")"
}

task3_stop_vm() {
    [[ -z "$TASK3_QEMU_PID" ]] || kill "$TASK3_QEMU_PID" 2>/dev/null || true
    local i=0
    while [[ -n "$TASK3_QEMU_PID" ]] && kill -0 "$TASK3_QEMU_PID" 2>/dev/null && (( i++ < 20 )); do sleep 0.2; done
    TASK3_QEMU_PID=""
}

task3_start_recovery_pump() { # socket log recovery-key
    python3 "$ROOT_DIR/test/lib/task3-console-pump.py" "$1" "$2" "$3" &
    TASK3_CONSOLE_PUMP_PID=$!
}

task3_capture_serial() { # socket log seconds
    python3 - "$1" "$2" "$3" <<'PY'
import socket, sys, time
path, log, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(path)
deadline = time.time() + seconds
with open(log, 'ab', buffering=0) as out:
    while time.time() < deadline:
        try: data = sock.recv(4096)
        except socket.timeout: continue
        if not data: break
        out.write(data)
PY
}

task3_console_diagnostics() { # console-log
    local console=$1
    [[ -f "$console" ]] || return 1
    echo "=== Task 3 complete console (raw text) ==="
    cat "$console"
    echo "=== Task 3 complete console (byte-safe escaped form) ==="
    python3 - "$console" <<'PY'
import sys
print(repr(open(sys.argv[1], 'rb').read()))
PY
}

task3_assert_esp() { # expected-uki-path
    local expected_uki=$1
    {
        echo 'set -euo pipefail'
        declare -f colocated_esp_from_lsblk
        declare -f task3_bootctl_status
        declare -f validate_task3_bootctl_status
        cat <<'EOF'
backing_partition=$(cryptsetup status root | awk '/^[[:space:]]*device:/{print $2; exit}')
[[ -n "$backing_partition" ]] || { echo "Error: root LUKS backing partition is unavailable" >&2; exit 1; }
lsblk -J -o PATH,TYPE,PARTTYPE,PKNAME > /run/task3-lsblk.json
esp=$(colocated_esp_from_lsblk /run/task3-lsblk.json "$backing_partition")
mountpoint=/run/task3-esp
cleanup() {
    umount "$mountpoint" 2>/dev/null || true
    rmdir "$mountpoint" 2>/dev/null || true
    rm -f /run/task3-lsblk.json
}
trap cleanup EXIT
mkdir "$mountpoint"
mount -o ro "$esp" "$mountpoint"
status=$(task3_bootctl_status "$mountpoint")
printf '%s\n' "$status"
validate_task3_bootctl_status "$status" "$1"
EOF
    } | ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" -i "$SSH_KEY" root@localhost bash -s -- "$expected_uki"
}

run_task3_live_proof() {
    local work="$TASK2_WORK/task3" disk="$TASK2_WORK/disk.raw" recovery="$TASK2_WORK/recovery.key"
    local negative_console sb lockdown cmdline var_device token failed boot_id recovery_rc=0
    require_task3_prerequisites
    mkdir -p "$work"
    SSH_PORT=2243
    SSH_TIMEOUT=300
    export SSH_PORT SSH_TIMEOUT
    ssh_keygen "$work"
    stage_task3_boot_chain "$DPS_ROOT_MOUNT" "$work"
    mount -o remount,rw "$DPS_ROOT_MOUNT" || {
        echo "BLOCKED: bootc left the Task 2 state filesystem read-only, so SSH cannot be seeded" >&2
        return 2
    }
    mkdir -p "$DPS_ROOT_MOUNT/state/os/default/var/roothome/.ssh"
    install -m 600 "${SSH_KEY}.pub" "$DPS_ROOT_MOUNT/state/os/default/var/roothome/.ssh/authorized_keys"
    destroy_dps_luks_btrfs_root || { echo "BLOCKED: cannot release Task 2 disk for QEMU" >&2; return 2; }

    secure_vm_prepare_ovmf "$work"
    secure_vm_start_swtpm "$work"
    task3_start_vm "$disk" "$work"
    task3_capture_serial "$work/serial.sock" "$work/console-negative.log" 20 || true
    negative_console="$(cat "$work/console-negative.log" 2>/dev/null || true)"
    task3_stop_vm
    secure_vm_stop_swtpm
    [[ "$negative_console" == *"Security Violation"* ]] || {
        echo "BLOCKED: fresh Microsoft-only varstore did not expose shim Security Violation for the MOK-signed second stage" >&2
        return 2
    }

    secure_vm_enroll_mok "$work/OVMF_VARS.fd" "$BOOTC_SECURE_MOK_CERT"
    virt-fw-vars -i "$work/OVMF_VARS.fd" -p | grep -q MokList || return 2
    secure_vm_start_swtpm "$work"
    task3_start_vm "$disk" "$work"
    task3_start_recovery_pump "$work/serial.sock" "$work/console.log" "$(<"$recovery")"
    # shellcheck disable=SC2034 # consumed by wait_for_ssh from ssh.sh.
    QEMU_CONSOLE_LOG="$work/console.log"
    wait_for_ssh || {
        task3_console_diagnostics "$work/console.log" >&2 || true
        echo "BLOCKED: MOK-enrolled Secure Boot did not reach SSH" >&2
        return 2
    }
    grep -q 'typed recovery passphrase' "$work/console.log" || return 2

    sb="$(vm_ssh 'mokutil --sb-state')"; [[ "$sb" == *'SecureBoot enabled'* ]] || return 2
    if ! task3_assert_esp "/EFI/Linux/bootc/bootc_composefs-${TASK2_FINAL_DIGEST}.efi" >"$work/esp-status.log" 2>&1; then
        cat "$work/esp-status.log" >&2
        echo "BLOCKED: temporary read-only ESP assertion failed" >&2
        return 2
    fi
    lockdown="$(vm_ssh 'cat /sys/kernel/security/lockdown')"; grep -Eq '\[(integrity|confidentiality)\]' <<<"$lockdown" || return 2
    cmdline="$(vm_ssh 'cat /proc/cmdline')"; [[ "$(composefs_digest_from_cmdline "$cmdline")" == "$TASK2_FINAL_DIGEST" ]] || return 2
    failed="$(vm_ssh 'systemctl --failed --no-legend')"; [[ -z "$failed" ]] || return 2
    var_device="$(vm_ssh "lsblk -J -o PATH,FSTYPE | jq -er '.. | objects | select(.fstype? == \"crypto_LUKS\") | .path'" || true)"
    scp "${SSH_OPTS[@]}" -P "$SSH_PORT" -i "$SSH_KEY" "$PCR_PUBLIC" root@localhost:/run/task3-pcr.pub
    task3_copy_recovery_key <"$recovery"
    vm_ssh "systemd-cryptenroll --unlock-key-file=/run/task3-recovery.key --tpm2-device=auto --tpm2-pcrs= --tpm2-pcrlock= --tpm2-public-key=/run/task3-pcr.pub --tpm2-public-key-pcrs=11 '$var_device'"
    token="$(vm_ssh "cryptsetup luksDump --dump-json-metadata '$var_device'")"
    validate_task3_tpm_token_policy <<<"$token" || return 2
    task3_remove_enrollment_credentials || true
    boot_id="$(vm_ssh 'cat /proc/sys/kernel/random/boot_id')"
    vm_ssh systemctl reboot || true
    task3_wait_for_new_boot "$boot_id" || { echo "BLOCKED: TPM-enrolled reboot required recovery input" >&2; return 2; }
    [[ "$(grep -c 'typed recovery passphrase' "$work/console.log")" == 1 ]] || return 2
    vm_ssh "cryptsetup open --test-passphrase --key-file=- '$var_device'" <"$recovery" || recovery_rc=$?
    [[ $recovery_rc -eq 0 ]] || return 2
    echo "PASS: shim/MOK Secure Boot chain, signed PCR 11 LUKS unlock, unattended reboot, and recovery unlock verified"
}

if [[ ${1:-} == --fixtures ]]; then
    run_fixture_tests
    exit $?
fi

run_fixture_tests
run_real_proof
run_task2_live_proof
run_task3_live_proof
