#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Phase 5/6 QEMU validation: fully automated Secure Boot + TPM (+ desktop,
# when the payload has one; + Surface module-trust, when the kernel is
# Surface) validation for a native A/B product (default snow-ab; also
# accepts cayo-ab and snowfield-ab). Step 5's
# desktop assertions (graphical.target, gdm.service, notify-send, the
# hicolor icon-cache sysext fixture) are gated on HAS_DESKTOP, derived from
# IMAGE_ID: snow and snowfield compose the GNOME desktop payload, cayo does
# not and skips Step 5 entirely -- see the HAS_DESKTOP derivation below and
# docs/native-ab-contracts.md / CLAUDE.md's per-profile package-set mapping.
# Step 3c (Surface module-trust under lockdown -- signed in-tree module
# loads, unsigned out-of-tree module is rejected) is gated on
# IMAGE_ID == snowfield specifically (Phase 6,
# docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md "Snowfield
# Native A/B"); test/snowfield-artifact-test.sh (Surface kernel/module/
# firmware/initrd static checks) likewise only runs for snowfield-ab. Every
# OTHER step (Secure Boot chain, TPM enrollment/auto-unlock, first-boot
# preset parity, secure update hop, recovery unlock) is profile-neutral and
# runs unconditionally. Coverage note: only the snow-ab (desktop) path had
# been run end-to-end through this QEMU harness as of Phase 5; Phase 6 added
# the first snowfield-ab (desktop + Surface kernel) run, and the Phase 6
# review follow-up (2026-07-15) added the first cayo-ab (server, no-desktop)
# run -- green (47/47), proving the Step-5-skipped control flow and that the
# backports kernel tolerates the shared secure fragment's explicit
# `lockdown=integrity` (its own SB->lockdown wiring and the explicit
# parameter coexist; the unconditional lockdown assertion passed). That run
# also root-caused a real profile difference: cayo's initrd has no plymouth
# (server payload), so the passphrase prompt is systemd's raw TTY agent
# shape with a trailing "(press TAB for no echo)" hint -- see the console
# pump's prompt_re comment. No MokManager interaction: the Snosi MOK
# is pre-enrolled into an OVMF varstore with `virt-fw-vars --add-mok`,
# starting from OVMF_VARS_4M.ms.fd (Microsoft keys already enrolled ->
# Secure Boot enforced), paired with OVMF_CODE_4M.secboot.fd and an attached
# swtpm TPM2 socket device.
#
# Sequence (docs/native-ab-contracts.md is the frozen naming/policy
# reference; CLAUDE.md "Native A/B Prototype" / "Native Security Contract"
# document the secure-chain invariants this test proves at runtime):
#
#   1. Build two real versions (N, N+1) of $PROFILE via the pinned .mkosi
#      checkout, mirroring test/native-ab-updateux-test.sh's build_profile.
#   2. Install N to a raw disk FILE (test-only) via
#      test/cayo-ab-install-spike.sh --allow-file --yes --encrypt-var
#      --recovery-key-file <fresh>. Deliberately does NOT pass
#      --mok-certificate: that flag drives `mokutil --import`, which talks
#      to the HOST's live EFI variable store -- wrong (and refused by the
#      spike script itself for --allow-file targets) for a loopback install
#      on a dev machine. MOK enrollment instead targets the GUEST's OVMF
#      varstore directly via virt-fw-vars (see vm_prepare_ovmf below) --
#      exactly the mechanism this test's own header describes, and the spike
#      script needed no changes for it.
#   3. First boot under enforced Secure Boot + swtpm: /var has no TPM token
#      yet, so the initrd's crypt dracut module prompts for the recovery
#      passphrase on the serial console (console=ttyS0 is already in the
#      generic KernelCommandLine). A Python console pump (no expect/socat on
#      this host; see below) types it once, automatically, the first time an
#      ask-password-shaped prompt appears. Asserts: Secure Boot enabled,
#      shim -> MOK-signed systemd-boot -> MOK-signed UKI chain actually
#      loaded (bootctl status "Measured UKI: yes"), kernel lockdown active,
#      /var is LUKS2, /etc overlay mounted, no failed units, first-boot
#      preset parity (reuses test/tests/05-firstboot-presets.sh verbatim,
#      the same TEST_LIB_DIR/helpers.sh remote-execution pattern
#      test/bootc-install-test.sh already uses), no NvPCR consumer failures.
#   4. In-guest TPM enrollment mirroring test/native-ab-secure-rotation-test.sh's
#      enroll_token EXACTLY: --tpm2-pcrs= (empty raw-PCR set) +
#      --tpm2-public-key=<pcr-signing.pub> --tpm2-public-key-pcrs=11 (signed
#      PCR 11 policy). Reboots; the ONLY assertion of success is that SSH
#      comes back inside the normal timeout with ZERO serial input fed --
#      if the initrd needed a passphrase, the boot would hang at the prompt
#      and wait_for_ssh would time out.
#   5. Desktop assertions on the TPM-unlocked boot, ONLY when HAS_DESKTOP=1
#      (IMAGE_ID in snow, snowfield -- see the derivation below; skipped
#      entirely for cayo, which has no desktop payload):
#      graphical.target, gdm.service, a logind seat, notify-send, the
#      fresh-/var tmpfiles targets, dpkg-query, and a minimal ad hoc sysext
#      (plain-directory form, not a raw disk image -- systemd-sysext(8)
#      merges directories under /var/lib/extensions/ identically to raw
#      images; this avoids building and loop-mounting an erofs/squashfs
#      just to prove the icon-cache contract) exercising the CLAUDE.md
#      hicolor icon-cache rule.
#      Separately (unconditional, profile-neutral, but its own assertions
#      are already gated on IMAGE_ID == snow specifically -- snow-linux-live
#      is a snow-branded live-media concept, not a general desktop one):
#      snow-linux-live-setup.service's corrected live-media gate (see the
#      "real bug found and fixed" note in the report/CLAUDE.md) -- on a
#      native install with no snow-linux.live=1 on the command line, the
#      unit must be ConditionResult=no / inactive, never active and never
#      failed. Presets, tmpfiles ownership, dpkg-query-availability-of-the-
#      relocation-symlink, and the NvPCR journal check all remain
#      unconditional profile-neutral assertions regardless of HAS_DESKTOP.
#   6. Secure update hop: publish N+1 through the real publication pipeline
#      to a local HTTP origin signed with an ephemeral GPG key that the
#      guest trusts via its SHIPPED vendor keyring ONLY -- the ephemeral
#      public ring is baked into the built images at build time over the
#      committed production pubring, at BOTH /usr/lib/systemd names, via
#      two mkosi CLI --extra-tree flags (see build_profile), and NO
#      /etc/systemd/import-pubring.* override is ever installed (asserted).
#      This makes the hop verify through systemd 261's real vendor path,
#      /usr/lib/systemd/import-pubring.pgp -- the exact link the 2026-07-17
#      outage proved untested (commit 91718d7): every other harness boots
#      cayo-ab-raw, whose Trixie systemd 257 still reads the old .gpg
#      vendor name, and/or injects the /etc override. Then run
#      /usr/libexec/snosi-sysupdate-stage, reboot with zero serial input
#      (proving the signed PCR 11 policy survives a real UKI change -- the
#      entire point of signed-vs-raw PCR policy), and assert N+1 booted
#      under enforced Secure Boot with TPM auto-unlock intact, /etc upper +
#      /var persistence markers survived, and the N rollback entry is still
#      present (InstancesMax=2).
#      6c. Negative half of the shipped-trust-path proof: a fabricated
#      newer-version index signed by a VALID but untrusted key (fresh
#      ephemeral "wrong" key) must be rejected through that same shipped
#      keyring -- stager fails closed (outcome=failed, nothing staged,
#      version unchanged), then the origin is restored to N+1's good index.
#   7. Recovery unlock check (non-destructive): the recovery keyslot still
#      opens the volume via `cryptsetup open --test-passphrase`.
#
#   --full-window (Phase 5 exit criterion; default OFF, default-mode
#   behavior above is completely unchanged when omitted) extends steps 6-7
#   with the rest of the N..N+3 update window, still under enforced Secure
#   Boot + TPM auto-unlock throughout, mirroring the SB-off prior art in
#   test/native-ab-update-test.sh and test/native-ab-secure-update-test.sh
#   (Incus-based) but with host-side corruption/inspection instead of
#   guest-side, and this script's own custom QEMU/swtpm/serial plumbing:
#     8. Build N+2 and N+3 (two more real builds -- four total for the
#        whole run) and secure-update-hop N+1 -> N+2 the same way step 6 did
#        N -> N+1: publish, stage via snosi-sysupdate-stage, reboot with
#        zero serial input. Asserts the usual post-update invariants (SB
#        enforced, measured UKI, TPM auto-unlock, single TPM token,
#        /var+/etc persistence) plus InstancesMax=2 slot accounting: N is
#        vacuumed (root partition labels are exactly {N+1, N+2} afterward)
#        and N+2 physically reuses the GPT slot N occupied.
#     9. Secure-update-hop N+2 -> N+3 identically: labels become exactly
#        {N+2, N+3}, N+1 is vacuumed, and N+3 reuses N+1's freed slot.
#    10. Explicit rollback: from N+3, `bootctl set-oneshot` the N+2 UKI
#        entry (whatever its current on-disk name is -- blessed or not),
#        reboot with zero serial input, assert N+2 boots with TPM unlock
#        still working, then a second zero-input reboot returns to the
#        persistent default (N+3 again, no second oneshot needed).
#    11. Boot-count fallback: re-arm N+3's ESP entry to the counting name
#        `<channel>_<N+3>+3-0.efi` (systemd-boot boot-counting convention,
#        docs/native-ab-contracts.md), then corrupt N+3's root partition
#        FROM THE HOST while the VM is fully powered off (a host-side
#        losetup + `dd` over the first 4096 bytes of the GPT slot, not the
#        guest-side write the SB-off prior art uses -- the guest is down
#        for this). Power-cycle three times (a guest stuck in dracut's
#        emergency shell never reboots itself): each cycle boots, is polled
#        for a NEW "Entering emergency mode" console marker, is forced back
#        off, and is inspected via a second host-side loop-mount of the ESP
#        (FAT) partition to confirm the counting suffix decremented exactly
#        as expected (+2-1, +1-2, +0-3) -- all while the VM is off, so this
#        never races a live QEMU writer. The fourth power-cycle boots to
#        completion: systemd-boot's own tries-exhausted logic must select
#        N+2 automatically (no oneshot, no operator action), still under
#        enforced Secure Boot with unattended TPM unlock and /var+/etc
#        state intact; the exhausted N+3 entry must remain on the ESP named
#        `+0-3` (never deleted, never silently retried again).
#    NvPCR journal coverage: assert_nvpcr_journal_clean runs after EVERY
#    boot that reaches SSH -- first boot (step 3), the TPM-enrollment
#    reboot (step 4b), the N->N+1 hop (step 6b), and, via the shared
#    assert_post_update_common helper, every --full-window hop (steps 9-10),
#    both explicit-rollback boots (step 10b), and the boot-count-fallback
#    recovery boot (step 11) -- not merely re-checked once after the window
#    completes, since journalctl -b only ever sees the CURRENT boot and an
#    end-of-run check alone would silently miss failures on every earlier
#    boot. Step 7's recovery-keyslot check runs at the very end regardless
#    of --full-window, so it is a true "does recovery still work after
#    everything above" check in --full-window mode, not merely a
#    post-step-6 checkpoint.
#
# Usage: sudo ./test/native-ab-secure-boot-test.sh [--full-window]
# Env overrides: PROFILE (default snow-ab; also accepts cayo-ab),
# IMAGE_ID/CHANNEL (derived from PROFILE by default), SSH_PORT (2225),
# SOURCE_PORT (18095), SSH_TIMEOUT/BOOT_TIMEOUT (300s), VM_MEMORY (4096),
# VM_CPUS (4), KEEP_VM (0), SKIP_BUILD/BUILD_N_DIR/BUILD_N1_DIR (reuse
# prebuilt artifacts, same contract as test/native-ab-updateux-test.sh --
# but SKIP_BUILD=1 here ALSO requires SIGNING_GNUPGHOME, the gnupg homedir
# from the run that built those artifacts, since its public keyring is
# baked into them; KEEP_VM=1 preserves it at <workdir>/gnupg),
# BUILD_N2_DIR/BUILD_N3_DIR (same SKIP_BUILD=1 reuse contract, only
# consulted with --full-window).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FULL_WINDOW=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full-window) FULL_WINDOW=1; shift ;;
        *)
            echo "Error: unknown argument: $1" >&2
            echo "Usage: $0 [--full-window]" >&2
            exit 2
            ;;
    esac
done

: "${KEEP_VM:=0}"
: "${SOURCE_PORT:=18095}"
: "${SSH_PORT:=2225}"
: "${SSH_TIMEOUT:=300}"
: "${BOOT_TIMEOUT:=420}"
: "${VM_MEMORY:=4096}"
: "${VM_CPUS:=4}"
: "${SKIP_BUILD:=0}"
: "${BUILD_N_DIR:=}"
: "${BUILD_N1_DIR:=}"
: "${BUILD_N2_DIR:=}"
: "${BUILD_N3_DIR:=}"
: "${SIGNING_GNUPGHOME:=}"

: "${PROFILE:=snow-ab}"
if [[ -z "${IMAGE_ID:-}" ]]; then
    IMAGE_ID="${PROFILE%-ab}"
fi
: "${CHANNEL:=${IMAGE_ID}-ab}"

# Step 5's assertions (graphical.target, gdm.service, notify-send, the
# hicolor icon-cache sysext fixture, ...) are GNOME-desktop-specific. Both
# snow-ab and snowfield-ab compose the snow desktop payload (see
# production_composition in test/native-ab-static-test.sh: cayo-ab=cayo,
# snow-ab=snow, snowfield-ab=snow) -- snowfield only swaps the kernel
# variant (Surface vs backports), not the package set -- while cayo-ab has
# no desktop at all. Derive the gate from IMAGE_ID (snow|snowfield) rather
# than a literal "snow" comparison so a future PROFILE=snowfield-ab run
# takes Step 5 too; cayo-ab correctly skips it.
case "$IMAGE_ID" in
    snow | snowfield) HAS_DESKTOP=1 ;;
    *) HAS_DESKTOP=0 ;;
esac

# This dev host is itself an immutable snosi image (read-only /usr sysext
# overlay); swtpm and virt-firmware cannot be `apt-get install`ed here (see
# the report). They live under linuxbrew (fixed system path) and the
# invoking user's pip --user site -- resolved via $SUDO_USER's home, not
# plain $HOME, since this script requires root (below) and a plain `sudo`
# invocation (the documented Usage:) resets $HOME to /root, which does not
# have the pip --user install.
real_home="$HOME"
if [[ -n "${SUDO_USER:-}" ]]; then
    real_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
fi
export PATH="$real_home/.local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
# virt-fw-vars is a `pip install --user` console-script wrapper: the
# interpreter resolves its OWN user site-packages directory from $HOME at
# import time (not from PATH), so a plain `sudo` invocation (which resets
# $HOME to /root) finds the wrapper via PATH above but then fails with
# "ModuleNotFoundError: No module named 'virt'" -- confirmed live. Exporting
# HOME here (not just PATH) fixes site-packages resolution; nothing else in
# this script depends on root's real $HOME for anything security-sensitive.
export HOME="$real_home"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ssh.sh"

WORK_DIR=""
HTTP_PID=""
QEMU_PID=""
CONSOLE_PUMP_PID=""
SWTPM_PID=""
loop=""
var_mapper=""
PASS=0
FAIL=0

pass() { # description
    echo "ok - $1"
    PASS=$((PASS + 1))
}

fail() { # description [detail]
    echo "not ok - $1" >&2
    [[ $# -lt 2 ]] || echo "  $2" >&2
    FAIL=$((FAIL + 1))
}

assert_eq() { # description actual expected
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1" "expected '$3', got '$2'"
    fi
}

assert_true() { # description command...
    local desc="$1"
    shift
    if "$@"; then
        pass "$desc"
    else
        fail "$desc" "command failed: $*"
    fi
}

assert_false() { # description command...
    local desc="$1"
    shift
    if "$@"; then
        fail "$desc" "command unexpectedly succeeded: $*"
    else
        pass "$desc"
    fi
}

assert_contains() { # description haystack needle
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1" "expected to find: $3 -- got: $2"
    fi
}

# assert_nvpcr_journal_clean description -- fails if the boot currently
# reachable via SSH logged any NvPCR-related error. journalctl -b only ever
# sees the CURRENT boot's journal, so this must be called once per boot,
# right after SSH comes back, to actually cover every boot in the flow -- a
# single check re-run only after the LAST boot of a multi-reboot sequence
# would silently miss NvPCR failures on every earlier boot (root-caused in
# review: only 3 of ~9 boots were checked before this helper existed).
# journalctl itself prints a literal "-- No entries --" banner (not empty
# stdout) when --grep finds nothing (confirmed live) -- assert the absence
# of the substring, not an exact-empty match against journalctl's own
# human-readable "nothing found" banner.
assert_nvpcr_journal_clean() { # description
    local desc="$1" nvpcr_journal
    nvpcr_journal="$(vm_ssh "journalctl -b -p err --grep=nvpcr --no-pager" 2>/dev/null || true)"
    assert_false "$desc" bash -c "grep -qi nvpcr <<<'$nvpcr_journal'"
}

print_summary() {
    echo ""
    echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
    exit "$FAIL"
}

cleanup() {
    [[ -z "$var_mapper" ]] || cryptsetup close "$var_mapper" 2>/dev/null || true
    [[ -z "$loop" ]] || losetup -d "$loop" 2>/dev/null || true
    [[ -z "$HTTP_PID" ]] || kill "$HTTP_PID" 2>/dev/null || true
    [[ -z "$CONSOLE_PUMP_PID" ]] || kill "$CONSOLE_PUMP_PID" 2>/dev/null || true
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        local i=0
        while kill -0 "$QEMU_PID" 2>/dev/null && (( i++ < 20 )); do sleep 0.5; done
        kill -9 "$QEMU_PID" 2>/dev/null || true
    fi
    [[ -z "$SWTPM_PID" ]] || kill "$SWTPM_PID" 2>/dev/null || true
    if [[ "$KEEP_VM" == 1 ]]; then
        echo "KEEP_VM=1: leaving $WORK_DIR in place"
        return
    fi
    [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# mkosi build helpers (mirrors test/native-ab-updateux-test.sh)
# ---------------------------------------------------------------------------
resolve_mkosi() {
    local commit dir
    commit="$(grep -m1 -oE 'systemd/mkosi@[0-9a-f]+' "$ROOT_DIR/.github/workflows/build.yml" | cut -d@ -f2)"
    dir="$ROOT_DIR/.mkosi"
    MKOSI="$dir/bin/mkosi"
    if [[ -x "$MKOSI" && "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$commit" ]]; then
        echo "Using pinned mkosi @ $commit ($dir)"
        return
    fi
    command -v python3 >/dev/null || { echo "Error: python3 is required to run mkosi" >&2; exit 1; }
    echo "Installing mkosi @ $commit into $dir"
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth=1 https://github.com/systemd/mkosi.git "$commit"
    git -C "$dir" checkout -q --detach FETCH_HEAD
}

build_profile() { # dest_dir
    local dest="$1"
    mkdir -p "$dest"
    echo "Building $PROFILE -> $dest (started $(date -u +%FT%TZ))"
    "$MKOSI" clean -ff
    # Bake the ephemeral TEST keyring over the committed production pubring
    # at BOTH shipped names (see the "shipped vendor keyring" comment in
    # Step 6): CLI list-setting values append AFTER config-file values
    # (.mkosi/mkosi/config.py finalize_value: `cfg_value + v`) and
    # install_extra_trees copies trees in list order with plain overwriting
    # `cp`, so these two pairs win over the committed pair from
    # shared/outformat/ab-root/mkosi.conf. The committed file itself is
    # never touched; the guest asserts the swap took (sha256 comparison)
    # before the first stage.
    "$MKOSI" --profile "$PROFILE" \
        --extra-tree "$WORK_DIR/import-pubring.gpg:/usr/lib/systemd/import-pubring.gpg" \
        --extra-tree "$WORK_DIR/import-pubring.gpg:/usr/lib/systemd/import-pubring.pgp" \
        build
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.manifest" "$dest/"
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.raw" "$dest/"
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.efi" "$dest/"
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.${IMAGE_ID}_@v.root.raw.raw" "$dest/"
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.${IMAGE_ID}_@v.root-verity.raw.raw" "$dest/"
    # The product-curated feature catalog (features-catalog.finalize) is a
    # REQUIRED publication artifact since the sysext feature catalog landed
    # (prepare-native-publication.sh hard-fails without it). The build emits
    # it as <IMAGE_ID>.features.json, not <Output>-prefixed.
    cp "$ROOT_DIR/output/${IMAGE_ID}.features.json" "$dest/$PROFILE.features.json"
    echo "Build done -> $dest (finished $(date -u +%FT%TZ))"
}

sign_sums() { # dir
    gpg --homedir "$WORK_DIR/gnupg" --batch --yes --detach-sign \
        -o "$1/SHA256SUMS.gpg" "$1/SHA256SUMS"
}

publish_version() { # build_dir -> sets publish_dest
    local build_dir="$1" stage
    stage="$(mktemp -d "$WORK_DIR/publish-src.XXXXXX")"
    for suffix in manifest raw efi "${IMAGE_ID}_@v.root.raw.raw" "${IMAGE_ID}_@v.root-verity.raw.raw"; do
        ln -s "$build_dir/$PROFILE.$suffix" "$stage/$CHANNEL.$suffix"
    done
    # The feature catalog is looked up as <product>.features.json, where
    # product is the manifest's .config.name (= IMAGE_ID) -- NOT the
    # channel-prefixed name the other staged artifacts use.
    ln -s "$build_dir/$PROFILE.features.json" "$stage/${IMAGE_ID}.features.json"
    "$ROOT_DIR/shared/native-ab/publish/prepare-native-publication.sh" --xz \
        "$stage" "$CHANNEL" "$WORK_DIR/publish-out"
    publish_dest="$WORK_DIR/publish-out/$IMAGE_ID/x86-64"
    sign_sums "$publish_dest"
}

guest_version() {
    vm_ssh ". /usr/lib/os-release; echo \"\$IMAGE_VERSION\""
}

# partition_path label -- host-visible-from-guest /dev path of the GPT
# partition with the given PARTLABEL, via the guest's own lsblk (mirrors
# test/native-ab-update-test.sh's helper of the same name). Used by
# --full-window to prove physical slot reuse across InstancesMax=2 vacuum.
partition_path() { # label
    local label="$1"
    vm_ssh "lsblk -J -o PATH,PARTLABEL" | jq -er --arg label "$label" \
        '.. | objects | select(.partlabel? == $label) | .path'
}

# root_labels_now -- sorted list of "<version>" tokens for every currently
# present "${IMAGE_ID}_<version>_r" partition (the dynamic root slots, §3).
root_labels_now() {
    vm_ssh "lsblk -J -o PARTLABEL" | jq -r --arg prefix "${IMAGE_ID}_" '
        .. | objects | select(.partlabel? != null)
        | select(.partlabel | startswith($prefix))
        | select(.partlabel | endswith("_r"))
        | .partlabel' | sed -E "s/^${IMAGE_ID}_(.*)_r\$/\\1/" | LC_ALL=C sort
}

# assert_root_slot_versions description expected_version... -- asserts the
# currently-present root slots are EXACTLY the given version set (InstancesMax=2
# vacuum accounting), not merely a superset or subset.
assert_root_slot_versions() { # description expected_version...
    local desc="$1"
    shift
    local expected actual
    expected="$(printf '%s\n' "$@" | LC_ALL=C sort)"
    actual="$(root_labels_now)"
    assert_eq "$desc" "$actual" "$expected"
}

# ---------------------------------------------------------------------------
# OVMF + MOK pre-enrollment + swtpm + QEMU (custom -- NOT test/lib/vm.sh:
# that library has no TPM/Secure-Boot/interactive-serial support)
# ---------------------------------------------------------------------------
OVMF_CODE_SRC=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.ms.fd

vm_prepare_ovmf() { # workdir mok_cert -> writes workdir/OVMF_CODE.fd, workdir/OVMF_VARS.fd
    local wd="$1" cert="$2" guid
    [[ -f "$OVMF_CODE_SRC" ]] || { echo "Error: missing $OVMF_CODE_SRC" >&2; exit 1; }
    [[ -f "$OVMF_VARS_SRC" ]] || { echo "Error: missing $OVMF_VARS_SRC" >&2; exit 1; }
    cp "$OVMF_CODE_SRC" "$wd/OVMF_CODE.fd"
    cp "$OVMF_VARS_SRC" "$wd/OVMF_VARS.fd"
    guid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    echo "Pre-enrolling Snosi MOK ($cert) into OVMF varstore as owner GUID $guid"
    virt-fw-vars --inplace "$wd/OVMF_VARS.fd" --add-mok "$guid" "$cert"
    # Confirm MokList and Secure Boot enablement landed before we ever boot.
    local printed
    printed="$(virt-fw-vars -i "$wd/OVMF_VARS.fd" -p 2>&1)"
    assert_contains "OVMF varstore has a MokList after pre-enrollment" "$printed" "MokList"
    assert_contains "OVMF varstore has SecureBootEnable ON (Microsoft PK present)" "$printed" "SecureBootEnable"
}

vm_prepare_swtpm() { # workdir -> sets TPM_SOCK, starts swtpm in background
    local wd="$1"
    mkdir -p "$wd/tpm"
    # (Re)startable: --tpmstate keeps ALL TPM state (including the sealed
    # data behind the enrolled LUKS token) in $wd/tpm across swtpm restarts,
    # so this function must NEVER wipe that directory -- only remove the
    # stale control socket/pidfile a previous (now dead) swtpm left behind,
    # so the socket-appearance wait below observes the NEW daemon, not a
    # leftover socket inode from the old one.
    rm -f "$wd/tpm/swtpm-ctrl.sock" "$wd/tpm/swtpm.pid"
    # QEMU's "-tpmdev emulator,chardev=..." integration expects the chardev
    # to point at swtpm's CONTROL channel (--ctrl): swtpm negotiates the
    # actual TPM command channel over that connection itself (an fd handoff
    # under the hood). A separate --server socket is for exposing the raw
    # TPM command channel directly (e.g. over TCP to an unrelated
    # consumer) -- pointing QEMU at that instead of --ctrl was tried first
    # and reproducibly hung QEMU at startup (2 threads, 0% CPU, state S,
    # zero vCPU threads ever created) since QEMU never got the handshake it
    # expects; --ctrl only, confirmed working end-to-end.
    swtpm socket --tpm2 --tpmstate "dir=$wd/tpm" \
        --ctrl "type=unixio,path=$wd/tpm/swtpm-ctrl.sock" \
        --pid "file=$wd/tpm/swtpm.pid" \
        --log "file=$wd/tpm/swtpm.log,level=1" \
        -d
    local i=0
    while [[ ! -S "$wd/tpm/swtpm-ctrl.sock" ]] && (( i++ < 50 )); do sleep 0.2; done
    [[ -S "$wd/tpm/swtpm-ctrl.sock" ]] || { echo "Error: swtpm control socket did not appear" >&2; exit 1; }
    SWTPM_PID="$(cat "$wd/tpm/swtpm.pid")"
    TPM_SOCK="$wd/tpm/swtpm-ctrl.sock"
    echo "swtpm running (PID $SWTPM_PID, control socket $TPM_SOCK)"
}

# vm_boot disk workdir -- (re)starts the QEMU process against an EXISTING
# $wd/OVMF_CODE.fd / $wd/OVMF_VARS.fd (the MOK pre-enrollment and any
# LoaderEntryOneShot/LoaderEntryDefault NVRAM state MUST persist across a
# power-cycle, so this never re-copies from the pristine OVMF source -- only
# vm_prepare_ovmf does that, once, at the very first boot). Used both for
# the very first boot (via vm_start_secure below) and, in --full-window
# mode, to power-cycle a stopped VM for each boot-count fallback attempt --
# a virtio-gpu device is attached (GDM needs a GPU node to bind to even
# with -display none). The serial console is a bidirectional UNIX socket
# (not test/lib/vm.sh's file-backed chardev) so console_pump (below) can
# both log and type into it; each call creates a FRESH socket (the previous
# QEMU process, if any, must already be gone -- see vm_force_stop).
#
# swtpm lifecycle (root-caused live in the first --full-window run, after
# 113 green assertions): swtpm terminates itself when its QEMU client goes
# away -- QEMU's tpm-emulator backend shuts the daemon down over the ctrl
# channel on exit, so the moment vm_force_stop kills QEMU the ctrl socket
# vanishes ("Failed to connect to '.../swtpm-ctrl.sock': No such file or
# directory" on the next launch, observed on fallback attempt 1/3). Every
# guest-initiated reboot before that kept ONE long-lived QEMU process
# alive, which is why the N..N+3 hops and explicit rollback never hit it.
# Therefore: every vm_boot re-arms swtpm if it is not currently running,
# against the SAME persistent --tpmstate directory (vm_prepare_swtpm never
# wipes it), so the TPM's sealed state -- and with it the enrolled LUKS
# token -- survives every power-cycle. Reinitializing the TPM state here
# instead would break unattended unlock for the rest of the run.
vm_boot() { # disk workdir
    local disk="$1" wd="$2"
    if [[ -z "$SWTPM_PID" ]] || ! kill -0 "$SWTPM_PID" 2>/dev/null; then
        echo "swtpm is not running (died with the previous QEMU); re-arming it on the persistent TPM state"
        vm_prepare_swtpm "$wd"
    fi
    SERIAL_SOCK="$wd/serial.sock"
    rm -f "$SERIAL_SOCK"
    local pidfile="$wd/qemu.pid"
    rm -f "$pidfile"
    # NOTE (netdev below): no hostfwd for $SOURCE_PORT -- QEMU user-mode/
    # slirp networking already lets the guest reach the host's 10.0.2.2
    # gateway on ANY port the host is listening on for GUEST-initiated
    # connections (the local publish HTTP server in Step 6); hostfwd= only
    # matters for HOST-initiated connections into the guest (SSH, below).
    # Adding a self-referential hostfwd=tcp::$SOURCE_PORT-:$SOURCE_PORT was
    # tried first and broke Step 6 (curl: (52) Empty reply from server): it
    # made QEMU itself bind and listen on the HOST's $SOURCE_PORT (to
    # forward into the unused guest port of the same number), which raced/
    # shadowed the real Python http.server trying to bind that same host
    # port for the publish origin.
    qemu-system-x86_64 \
        -machine q35 \
        -enable-kvm -cpu host \
        -m "$VM_MEMORY" -smp "$VM_CPUS" \
        -drive "if=pflash,format=raw,unit=0,file=$wd/OVMF_CODE.fd,readonly=on" \
        -drive "if=pflash,format=raw,unit=1,file=$wd/OVMF_VARS.fd" \
        -drive "file=$disk,format=raw,if=virtio" \
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -device virtio-gpu-pci \
        -display none \
        -vga none \
        -chardev "socket,id=tpmchr,path=$TPM_SOCK" \
        -tpmdev emulator,id=tpm0,chardev=tpmchr \
        -device tpm-crb,tpmdev=tpm0 \
        -chardev "socket,id=serial0,path=$SERIAL_SOCK,server=on,wait=off" \
        -serial chardev:serial0 \
        -monitor none \
        -pidfile "$pidfile" \
        -daemonize
    local i=0
    while [[ ! -S "$SERIAL_SOCK" ]] && (( i++ < 50 )); do sleep 0.2; done
    [[ -S "$SERIAL_SOCK" ]] || { echo "Error: QEMU serial socket did not appear" >&2; exit 1; }
    QEMU_PID="$(cat "$pidfile")"
    echo "VM (re)started (QEMU PID $QEMU_PID, SSH port $SSH_PORT)"
}

# vm_start_secure disk workdir mok_cert -- first boot only: prepares a fresh
# OVMF varstore (MOK pre-enrollment) and a fresh swtpm, then calls vm_boot.
vm_start_secure() { # disk workdir mok_cert
    local disk="$1" wd="$2" cert="$3"
    vm_prepare_ovmf "$wd" "$cert"
    vm_prepare_swtpm "$wd"
    vm_boot "$disk" "$wd"
    echo "VM started under enforced Secure Boot + swtpm"
}

# vm_force_stop -- power off the guest and fully stop the QEMU process.
# Used only by --full-window's boot-count fallback loop, which must
# power-cycle between attempts: a guest stuck in dracut's emergency shell
# (corrupted root, no network in the initrd) never reboots itself, so a
# graceful in-guest `systemctl reboot` (reboot_guest, below) is not an
# option there. Tries a graceful `systemctl poweroff` first (this is the
# path taken for the one legitimate graceful stop, right before the first
# corruption); when the guest is unreachable (already hung in the initrd
# shell) that attempt harmlessly times out via SSH_OPTS' ConnectTimeout and
# this falls through to a hard kill, exactly like the EXIT trap's cleanup.
vm_force_stop() {
    stop_console_pump
    vm_ssh systemctl poweroff >/dev/null 2>&1 || true
    local i=0
    while [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null && (( i++ < 30 )); do sleep 1; done
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        i=0
        while kill -0 "$QEMU_PID" 2>/dev/null && (( i++ < 20 )); do sleep 0.5; done
        kill -9 "$QEMU_PID" 2>/dev/null || true
    fi
    QEMU_PID=""
    rm -f "$WORK_DIR/serial.sock" "$WORK_DIR/qemu.pid"
}

# start_console_pump workdir recovery_key -- launches a Python process that
# connects to the serial UNIX socket, tees everything to $workdir/console.log,
# and -- the ONE interactive step this whole harness needs, since neither
# expect nor socat exist on this host -- types $recovery_key + Enter the
# FIRST time (and only the first time) a systemd-ask-password-shaped
# "...passphrase...:" prompt appears on the console. Runs for the lifetime
# of the QEMU process (guest `systemctl reboot` does not restart QEMU, so
# one pump covers every boot in this test); later boots never see a prompt
# (TPM auto-unlock), so the guard never fires again -- confirmed by grepping
# console.log for the prompt string after each subsequent boot.
start_console_pump() { # workdir recovery_key
    local wd="$1" key="$2"
    python3 - "$SERIAL_SOCK" "$wd/console.log" "$key" > "$wd/console-pump.log" 2>&1 <<'PYEOF' &
import re, socket, sys, time

sock_path, log_path, key = sys.argv[1], sys.argv[2], sys.argv[3]

for attempt in range(50):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        break
    except OSError:
        time.sleep(0.2)
else:
    print("ERROR: could not connect to serial socket", file=sys.stderr)
    sys.exit(1)

s.settimeout(1.0)
# Match a systemd-ask-password-shaped prompt sitting at the END of the
# console buffer (i.e. the guest is waiting for input right now). Two real
# shapes exist, root-caused on the first-ever cayo-ab run (2026-07-15):
# snow-ab/snowfield-ab initrds carry plymouth (desktop payload), whose
# console prompt ends at the colon and matched the original ':\s*$' anchor;
# cayo-ab (server, no plymouth) gets systemd's raw TTY agent prompt --
# exact observed bytes:
#   \x1b[0;1;39mPlease enter passphrase for disk var: (press TAB for no echo) \x1b[0m
# -- where the '(press TAB for no echo)' hint plus the trailing ANSI SGR
# reset sit AFTER the colon, so a bare ':\s*$' can never match and the pump
# never typed (first boot wedged at the passphrase prompt until the SSH
# timeout). Allow only whitespace, ANSI SGR sequences, and that exact hint
# after the colon: anything else (real output following an old prompt)
# still correctly prevents a match.
prompt_re = re.compile(
    rb'[Ee]nter[^\n]*pass ?(?:phrase|word)[^\n]*:'
    rb'(?:\s|\x1b\[[0-9;]*m|\(press TAB for no echo\))*$'
)
buf = bytearray()
sent = False
last_rx = time.time()
with open(log_path, "ab", buffering=0) as log:
    while True:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            chunk = None  # no data within 1s; distinct from a real EOF below
        if chunk == b"":
            # Peer closed the connection (QEMU exited) -- stop spinning.
            break
        if chunk:
            log.write(chunk)
            buf.extend(chunk)
            if len(buf) > 8192:
                del buf[:-8192]
            last_rx = time.time()
        if not sent and (time.time() - last_rx) > 0.6 and prompt_re.search(bytes(buf)):
            time.sleep(0.3)  # let the prompt line fully settle
            s.sendall(key.encode() + b"\r\n")
            log.write(b"\n[console_pump: typed recovery passphrase]\n")
            sent = True
PYEOF
    CONSOLE_PUMP_PID=$!
    echo "Console pump started (PID $CONSOLE_PUMP_PID), logging to $wd/console.log"
}

# stop_console_pump -- kill and reap the current console pump, if any.
# Needed before every vm_force_stop/vm_boot power-cycle: the pump holds a
# client connection to the OLD serial socket, which vm_boot immediately
# unlinks and recreates fresh.
stop_console_pump() {
    if [[ -n "$CONSOLE_PUMP_PID" ]]; then
        kill "$CONSOLE_PUMP_PID" 2>/dev/null || true
        wait "$CONSOLE_PUMP_PID" 2>/dev/null || true
    fi
    CONSOLE_PUMP_PID=""
}

reboot_guest() { # -- reboot with ZERO serial input; a hang here means the
                  # initrd needed a passphrase it did not get (TPM failed).
    vm_ssh systemctl reboot || true
    sleep 5
    wait_for_ssh
}

# ---------------------------------------------------------------------------
# --full-window helpers (N+2/N+3 hops, explicit rollback, boot-count
# fallback). Defined unconditionally (cheap) but only called when
# FULL_WINDOW=1.
# ---------------------------------------------------------------------------

# wait_for_emergency previous_count -- polls the CUMULATIVE console.log
# (console_pump always appends in "ab" mode, and is restarted-but-not-
# truncated across every vm_boot in the fallback loop) for a NEW "Entering
# emergency mode" occurrence beyond $previous_count. Prints the new
# cumulative count on success (the caller threads it into the next call so
# each attempt only matches its OWN new occurrence, not a stale one from an
# earlier attempt). Mirrors test/native-ab-update-test.sh's
# wait_for_failed_boot, adapted to this script's single growing log file
# instead of vm.sh's per-process QEMU_CONSOLE_LOG.
wait_for_emergency() { # previous_count
    local previous_count="$1" deadline current_count
    deadline=$((SECONDS + BOOT_TIMEOUT))
    while (( SECONDS < deadline )); do
        current_count="$(grep -c 'Entering emergency mode' "$WORK_DIR/console.log" 2>/dev/null || true)"
        if (( current_count > previous_count )); then
            echo "$current_count"
            return 0
        fi
        sleep 2
    done
    echo "Error: corrupted boot did not reach emergency mode within ${BOOT_TIMEOUT}s" >&2
    echo "=== console.log tail ===" >&2
    tail -100 "$WORK_DIR/console.log" >&2 || true
    return 1
}

# esp_uki_entry version -- sets ESP_UKI_ENTRY to the sole ESP filename
# matching "${CHANNEL}_<version>*.efi" (tolerates a bare blessed name or any
# boot-counting suffix, whatever is actually on disk right now -- mirrors
# test/native-ab-secure-update-test.sh's matching_uki_entry, minus the
# content-hash disambiguation that script needs for dual-signed rotation
# artifacts, which do not exist in this run: every version here has a
# unique 14-digit timestamp, so a filename-prefix match is unambiguous).
esp_uki_entry() { # version
    local version="$1" listing
    listing="$(vm_ssh "find /boot/EFI/Linux -maxdepth 1 -type f -name '${CHANNEL}_${version}*.efi' -printf '%f\n'")"
    local -a matches=()
    mapfile -t matches <<<"$listing"
    if [[ ${#matches[@]} -ne 1 || -z "${matches[0]}" ]]; then
        echo "Error: expected exactly one ESP UKI entry for $version, found: $listing" >&2
        exit 1
    fi
    ESP_UKI_ENTRY="${matches[0]}"
}

# host_inspect_esp description name -- loop-mounts the disk image's ESP
# (FAT) partition read-only FROM THE HOST (the VM must already be fully
# powered off -- vm_force_stop) and asserts /EFI/Linux contains exactly the
# given filename. Used between boot-count fallback attempts to observe the
# counting suffix decrement without ever touching the guest (which is
# unreachable while corrupted anyway). Reuses the global `loop` var and
# $WORK_DIR/mnt exactly like the Step 1-2 install-time mount, so the EXIT
# trap cleans up a stuck loop device on any failure here too.
host_inspect_esp() { # description name
    local desc="$1" name="$2" espdev listing
    loop="$(losetup --find --show --partscan "$DISK_IMAGE")"
    udevadm settle
    espdev="$(lsblk -nrpo NAME,PARTLABEL "$loop" | awk '$2 == "esp" { print $1 }')"
    [[ -n "$espdev" ]] || { echo "Error: could not locate ESP partition on $loop" >&2; exit 1; }
    mount -o ro "$espdev" "$WORK_DIR/mnt"
    listing="$(ls "$WORK_DIR/mnt/EFI/Linux")"
    umount "$WORK_DIR/mnt"
    losetup -d "$loop"
    loop=""
    echo "Host-side ESP listing ($desc): $listing"
    assert_contains "$desc" "$listing" "$name"
}

# host_corrupt_root_partition version -- FROM THE HOST, with the VM fully
# powered off, zeroes the first 4096 bytes of the GPT partition labeled
# "${IMAGE_ID}_<version>_r" (matches the corruption test/native-ab-update-
# test.sh and test/native-ab-secure-update-test.sh use, just applied to the
# host-visible loop device instead of a guest-visible /dev path, since the
# guest is not running for this step). Writing straight to the partition
# node bypasses the dm-verity mapper entirely -- verity only checks reads,
# never blocks writes to the raw block device underneath it -- which is
# exactly the corruption boot-count fallback is meant to detect.
host_corrupt_root_partition() { # version
    local version="$1" rootdev
    loop="$(losetup --find --show --partscan "$DISK_IMAGE")"
    udevadm settle
    rootdev="$(lsblk -nrpo NAME,PARTLABEL "$loop" | awk -v l="${IMAGE_ID}_${version}_r" '$2 == l { print $1 }')"
    [[ -n "$rootdev" ]] || { echo "Error: could not locate root partition ${IMAGE_ID}_${version}_r on $loop" >&2; exit 1; }
    dd if=/dev/zero of="$rootdev" bs=4096 count=1 conv=fsync status=none
    losetup -d "$loop"
    loop=""
    echo "Corrupted root partition for $version on the host ($rootdev, first 4096 bytes zeroed, VM was off)"
}

# assert_post_update_common expected_version description_prefix -- the
# invariants every post-hop/rollback/fallback boot in --full-window must
# satisfy: booted the expected version, Secure Boot still enforced, a
# MOK-signed UKI was actually measured, /var still auto-unlocked via the
# TPM mapper with exactly one systemd-tpm2 token, both persistence markers
# survived, system health is running/degraded, and the console pump never
# had to type a passphrase again (proves the signed PCR 11 policy survived
# whichever UKI is now booted). Requires $var_device (set once in Step 4)
# and the Step 6 persistence markers to already be in place.
assert_post_update_common() { # expected_version description_prefix
    local expected="$1" prefix="$2" booted sb bstatus vs dump tcount mv em health prompt_count
    booted="$(guest_version)"
    assert_eq "$prefix: booted version is $expected" "$booted" "$expected"
    sb="$(vm_ssh 'mokutil --sb-state' || true)"
    assert_contains "$prefix: Secure Boot still enabled" "$sb" "SecureBoot enabled"
    bstatus="$(vm_ssh 'bootctl --no-pager status' || true)"
    assert_contains "$prefix: Measured UKI: yes" "$bstatus" "Measured UKI: yes"
    vs="$(vm_ssh 'findmnt -no SOURCE /var' || true)"
    assert_eq "$prefix: /var still auto-unlocked via the TPM mapper" "$vs" "/dev/mapper/var"
    dump="$(vm_ssh "cryptsetup luksDump --dump-json-metadata '$var_device'")"
    tcount="$(jq '[.tokens[] | select(.type == "systemd-tpm2")] | length' <<<"$dump")"
    assert_eq "$prefix: still exactly one systemd-tpm2 LUKS token" "$tcount" "1"
    mv="$(vm_ssh 'cat /var/lib/native-ab-secure-boot-test.marker' || true)"
    assert_eq "$prefix: /var persistence marker survived" "$mv" "native-ab-secure-boot-test-var-marker"
    em="$(vm_ssh 'tail -1 /etc/issue' || true)"
    assert_eq "$prefix: /etc overlay upper marker survived" "$em" "native-ab-secure-boot-test etc marker"
    health="$(vm_ssh 'systemctl is-system-running --wait' || true)"
    assert_true "$prefix: system health is running or degraded" \
        bash -c "[[ '$health' == running || '$health' == degraded ]]"
    prompt_count="$(grep -c 'typed recovery passphrase' "$WORK_DIR/console.log" || true)"
    assert_eq "$prefix: still no passphrase prompt (signed PCR 11 policy held)" "$prompt_count" "1"
    assert_nvpcr_journal_clean "$prefix: no NvPCR-related journal errors"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for command in jq losetup mount xz python3 qemu-system-x86_64 gpg git sfdisk curl \
    cryptsetup openssl virt-fw-vars swtpm objcopy objdump dpkg lsinitrd wipefs; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done
[[ $EUID -eq 0 ]] || { echo "Error: must run as root" >&2; exit 1; }
[[ -f "$ROOT_DIR/mkosi.key" && -f "$ROOT_DIR/mkosi.crt" ]] || {
    echo "Error: missing $ROOT_DIR/mkosi.key / mkosi.crt (dev Secure Boot signing keys)" >&2
    exit 1
}
[[ -f "$ROOT_DIR/.snosi-private/pcr-signing.pub" ]] || {
    echo "Error: missing $ROOT_DIR/.snosi-private/pcr-signing.pub (dev PCR signing public key)" >&2
    exit 1
}

trap cleanup EXIT
WORK_DIR="$(mktemp -d /var/tmp/native-ab-secure-boot-test.XXXXXX)"
mkdir -p "$WORK_DIR/mnt" "$WORK_DIR/gnupg" "$WORK_DIR/publish-out" "$WORK_DIR/overrides" "$WORK_DIR/tests"
chmod 700 "$WORK_DIR/gnupg"

# The ephemeral update-signing key must exist BEFORE the builds:
# build_profile bakes its public keyring into every built image over the
# committed production pubring (whose private half is offline-only --
# shared/native-ab/keys/README.md -- so the fixture origin can no longer be
# signed with a key the stock shipped ring trusts). See the "shipped vendor
# keyring" comment in Step 6 for the full trust-path rationale. With
# SKIP_BUILD=1 the prebuilt images already contain SOME baked ring, so the
# matching gnupg homedir must be supplied instead of generating a fresh key
# that could never verify against them.
if [[ "$SKIP_BUILD" == 1 ]]; then
    [[ -n "$SIGNING_GNUPGHOME" ]] || {
        echo "Error: SKIP_BUILD=1 requires SIGNING_GNUPGHOME (the gnupg homedir whose key was baked into the prebuilt images)" >&2
        exit 1
    }
    cp -a "$SIGNING_GNUPGHOME/." "$WORK_DIR/gnupg/"
else
    gpg --homedir "$WORK_DIR/gnupg" --batch --passphrase '' --quick-generate-key \
        'snosi native A/B secure-boot test <native-ab-secure-boot-test@invalid>' ed25519 sign 0
fi
gpg --homedir "$WORK_DIR/gnupg" --batch --export > "$WORK_DIR/import-pubring.gpg"

echo "=== Step 0: build N and N+1 (this takes tens of minutes) ==="
if [[ "$SKIP_BUILD" == 1 ]]; then
    [[ -n "$BUILD_N_DIR" && -n "$BUILD_N1_DIR" ]] || {
        echo "Error: SKIP_BUILD=1 requires BUILD_N_DIR and BUILD_N1_DIR" >&2
        exit 1
    }
    echo "SKIP_BUILD=1: reusing prebuilt artifacts at $BUILD_N_DIR and $BUILD_N1_DIR"
else
    resolve_mkosi
    BUILD_N_DIR="$WORK_DIR/build-n"
    BUILD_N1_DIR="$WORK_DIR/build-n1"
    build_profile "$BUILD_N_DIR"
    build_profile "$BUILD_N1_DIR"
fi

for f in manifest raw efi features.json "${IMAGE_ID}_@v.root.raw.raw" "${IMAGE_ID}_@v.root-verity.raw.raw"; do
    [[ -f "$BUILD_N_DIR/$PROFILE.$f" ]] || { echo "Error: missing N artifact: $f" >&2; exit 1; }
    [[ -f "$BUILD_N1_DIR/$PROFILE.$f" ]] || { echo "Error: missing N+1 artifact: $f" >&2; exit 1; }
done

n_version="$(jq -er '.config.version' "$BUILD_N_DIR/$PROFILE.manifest")"
n1_version="$(jq -er '.config.version' "$BUILD_N1_DIR/$PROFILE.manifest")"
echo "N=$n_version  N+1=$n1_version"
[[ "$n_version" != "$n1_version" ]] || { echo "Error: N and N+1 builds produced the same version" >&2; exit 1; }
[[ "$n1_version" > "$n_version" ]] || { echo "Error: N+1 version is not newer than N" >&2; exit 1; }

echo ""
echo "=== Static artifact validation (reuses test/native-ab-secure-artifact-test.sh) ==="
OUTPUT_NAME="$PROFILE" "$SCRIPT_DIR/native-ab-secure-artifact-test.sh" \
    "$BUILD_N_DIR/$PROFILE.manifest" "$BUILD_N_DIR/$PROFILE.efi" "" \
    "$ROOT_DIR/.snosi-private/pcr-signing.pub" single
pass "N artifact passes the secure-artifact single-signature contract"

# Surface-specific artifact checks (Phase 6, snowfield-ab only -- manifest
# kernel/firmware package identity, UKI-embedded kernel version, module dir,
# firmware completeness, initrd content; see test/snowfield-artifact-test.sh).
if [[ "$IMAGE_ID" == snowfield ]]; then
    echo ""
    echo "=== Static artifact validation (test/snowfield-artifact-test.sh) ==="
    snowfield_root_raw="$BUILD_N_DIR/$PROFILE.${IMAGE_ID}_@v.root.raw.raw"
    OUTPUT_NAME="$PROFILE" IMAGE_ID="$IMAGE_ID" "$SCRIPT_DIR/snowfield-artifact-test.sh" \
        "$BUILD_N_DIR/$PROFILE.manifest" "$BUILD_N_DIR/$PROFILE.efi" \
        "$snowfield_root_raw"
    pass "N artifact passes the Surface-specific artifact contract"
fi

# ===========================================================================
# Step 1-2: install N to a raw disk FILE with an encrypted /var, no
# --mok-certificate (see the header comment on why)
# ===========================================================================
echo ""
echo "=== Step 1-2: install N to a raw disk file (--encrypt-var, no TPM at install time) ==="

DISK_IMAGE="$WORK_DIR/disk.raw"
image_size="$(stat -c %s "$BUILD_N_DIR/$PROFILE.raw")"
image_sha256="$(sha256sum "$BUILD_N_DIR/$PROFILE.raw" | cut -d' ' -f1)"
truncate -s "$image_size" "$DISK_IMAGE"
recovery_key_file="$WORK_DIR/recovery.key"

"$SCRIPT_DIR/cayo-ab-install-spike.sh" --allow-file --yes \
    --encrypt-var --recovery-key-file "$recovery_key_file" \
    "$BUILD_N_DIR/$PROFILE.raw" "$image_sha256" "$DISK_IMAGE"
pass "installer completed against a same-size raw disk file"
[[ -s "$recovery_key_file" ]] || { echo "Error: installer did not write a recovery key" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Inject the test SSH key into the freshly installed /var/roothome/.ssh
# (root.mount bind-mounts /root -> /var/roothome, mkosi.images/base) before
# first boot -- opening the just-created LUKS /var with the installer's own
# recovery key file, entirely offline, no serial interaction needed for
# this part.
# ---------------------------------------------------------------------------
ssh_keygen "$WORK_DIR"
loop="$(losetup --find --show --partscan "$DISK_IMAGE")"
udevadm settle
var_part="$(lsblk -nrpo NAME,PARTLABEL "$loop" | awk '$2 == "var" { print $1 }')"
[[ -n "$var_part" ]] || { echo "Error: could not locate the var partition on $loop" >&2; exit 1; }
var_mapper="snosi-secure-boot-test-var-$$"
cryptsetup open --key-file "$recovery_key_file" "$var_part" "$var_mapper"
mount "/dev/mapper/$var_mapper" "$WORK_DIR/mnt"
mkdir -p "$WORK_DIR/mnt/roothome/.ssh"
cp "${SSH_KEY}.pub" "$WORK_DIR/mnt/roothome/.ssh/authorized_keys"
chmod 700 "$WORK_DIR/mnt/roothome/.ssh"
chmod 600 "$WORK_DIR/mnt/roothome/.ssh/authorized_keys"
umount "$WORK_DIR/mnt"
cryptsetup close "$var_mapper"
var_mapper=""
losetup -d "$loop"
loop=""

# ===========================================================================
# Step 3: first boot under enforced Secure Boot + swtpm; automate the
# recovery-passphrase prompt on the serial console
# ===========================================================================
echo ""
echo "=== Step 3: first boot (Secure Boot + swtpm, no TPM token yet) ==="

recovery_key="$(cat "$recovery_key_file")"
vm_start_secure "$DISK_IMAGE" "$WORK_DIR" "$ROOT_DIR/mkosi.crt"
start_console_pump "$WORK_DIR" "$recovery_key"

if ! SSH_TIMEOUT="$BOOT_TIMEOUT" wait_for_ssh; then
    echo "=== console.log (first boot did not reach SSH) ===" >&2
    tail -200 "$WORK_DIR/console.log" >&2 || true
    echo "BLOCKED: first boot never reached SSH -- see console.log above for the actual prompt text/failure" >&2
    exit 1
fi
assert_true "console pump typed the recovery passphrase during first boot" \
    grep -q 'typed recovery passphrase' "$WORK_DIR/console.log"

booted_version="$(guest_version)"
assert_eq "booted version is N" "$booted_version" "$n_version"
vm_ssh 'systemctl is-system-running --wait' >/dev/null || true

sb_state="$(vm_ssh 'mokutil --sb-state' || true)"
assert_contains "mokutil reports Secure Boot enabled" "$sb_state" "SecureBoot enabled"

bootctl_status="$(vm_ssh 'bootctl --no-pager status' || true)"
assert_contains "bootctl status: Secure Boot enabled" "$bootctl_status" "Secure Boot: enabled"
assert_contains "bootctl status: measured UKI (MOK-signed chain actually loaded)" "$bootctl_status" "Measured UKI: yes"

lockdown="$(vm_ssh 'cat /sys/kernel/security/lockdown' || true)"
echo "lockdown: $lockdown"
assert_true "kernel lockdown is in integrity or confidentiality mode" \
    bash -c "grep -Eq '\[(integrity|confidentiality)\]' <<<'$lockdown'"

var_source="$(vm_ssh 'findmnt -no SOURCE /var' || true)"
assert_eq "/var is mounted from the LUKS mapper device" "$var_source" "/dev/mapper/var"
assert_true "cryptsetup status var reports LUKS2" \
    vm_ssh 'cryptsetup status var | grep -Eq "type:[[:space:]]*LUKS2"'

etc_source="$(vm_ssh 'findmnt -no FSTYPE /etc' || true)"
assert_eq "/etc is an overlay mount" "$etc_source" "overlay"

failed_units="$(vm_ssh 'systemctl --failed --no-legend' || true)"
assert_eq "no failed systemd units on first boot" "$failed_units" ""

assert_nvpcr_journal_clean "no NvPCR-related journal errors on first boot"
assert_eq "systemd-pcrproduct.service is masked" \
    "$(vm_ssh 'systemctl is-enabled systemd-pcrproduct.service' || true)" "masked"

# ===========================================================================
# Step 3c (snowfield-ab only): empirical Surface module-trust decision under
# enforced lockdown (Phase 6,
# docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md "Snowfield
# Native A/B" -- "First inspect the packaged kernel configuration, module
# signatures, and signer trust under lockdown ... Re-sign only modules that
# actually fail trust validation or are out-of-tree"). Runs on first boot:
# lockdown is already confirmed active immediately above, and this needs no
# TPM enrollment/update state, only a root shell. See
# docs/native-ab-contracts.md §7 for where the resulting decision is
# recorded.
# ===========================================================================
if [[ "$IMAGE_ID" == snowfield ]]; then
    echo ""
    echo "=== Step 3c: Surface module-trust validation (lockdown) ==="

    builtin_keys="$(vm_ssh 'keyctl show %:.builtin_trusted_keys' || true)"
    echo "builtin_trusted_keys:"
    echo "$builtin_keys"
    assert_contains "guest builtin trusted keyring holds an asymmetric (module-signing) key" \
        "$builtin_keys" "asymmetric"

    kver="$(vm_ssh 'uname -r')"
    echo "booted kernel: $kver"

    # (a) A signed in-tree module that needs no hardware to load
    # successfully: isofs registers a filesystem type at module_init time
    # and never probes hardware, so insmod succeeds unconditionally (no
    # CD-ROM device required) -- the brief's own "filesystem module from the
    # surface kernel tree" example.
    isofs_signer="$(vm_ssh 'modinfo -F signer isofs' || true)"
    echo "isofs.ko signer: $isofs_signer"
    assert_eq "isofs.ko is signed by the kernel's own build-time key" \
        "$isofs_signer" "Build time autogenerated kernel key"

    # Strengthen the keyring check above: don't just confirm the keyring
    # holds *an* asymmetric key -- bind the SPECIFIC signing certificate.
    # Pitfall (measured live on a snosi host + on the extracted snow-ab UKI
    # and Surface vmlinuz, 2026-07-15): `modinfo -F sig_key` prints the
    # signing certificate's SERIAL NUMBER (the module's PKCS#7 signerInfo
    # identifies its signer by issuer+serial -- confirmed by parsing a real
    # module signature with `openssl pkcs7 -print`), while the trailing hex
    # in a `keyctl show` keyring entry is the same certificate's Subject
    # Key Identifier (SKID). Those are two structurally different values
    # that never match textually, so "grep sig_key in keyctl output" is NOT
    # a valid check. Instead, extract the actual embedded signing
    # certificate host-side from the .linux payload of the very UKI the
    # guest booted, and assert both halves of the chain against it:
    #   guest module sig_key         == cert serial  (module -> cert)
    #   guest builtin keyring entry  == cert SKID    (cert -> keyring)
    # Everything is normalized to lowercase colon-free hex first. The
    # cryptographic (not just textual) binding is separately proven by the
    # signed-module load + unsigned-module rejection below: insmod IS the
    # kernel verifying that sig_key against its builtin keyring.
    objcopy -O binary --only-section=.linux "$BUILD_N_DIR/$PROFILE.efi" "$WORK_DIR/uki-linux.bin"
    cert_ids="$(python3 - "$WORK_DIR/uki-linux.bin" "$isofs_signer" <<'CERTEOF'
import re
import subprocess
import sys

image_path, expected_cn = sys.argv[1], sys.argv[2]
data = open(image_path, "rb").read()

# The system certificate list lives in the DECOMPRESSED kernel image; find
# the payload by compression magic (zstd is what current Debian backports
# and linux-surface kernels use; the others are kept so a compression
# switch fails loudly here instead of silently).
magics = [
    (b"\x28\xb5\x2f\xfd", ["zstd", "-dc"]),
    (b"\x1f\x8b\x08", ["gzip", "-dc"]),
    (b"\xfd7zXZ\x00", ["xz", "-dc"]),
    (b"\x02\x21\x4c\x18", ["lz4", "-dc"]),
]
vm = None
for magic, cmd in magics:
    off = data.find(magic)
    if 0 <= off < 131072:
        # Trailing data after the stream makes the decompressor exit
        # non-zero AFTER emitting the full payload; judge by output size,
        # not exit code.
        p = subprocess.run(cmd, input=data[off:], capture_output=True)
        if len(p.stdout) > len(data):
            vm = p.stdout
            break
if vm is None:
    sys.exit("ERROR: no decompressible kernel payload found in " + image_path)

matches = []
for m in re.finditer(rb"\x30\x82(..)\x30\x82", vm, re.DOTALL):
    length = int.from_bytes(m.group(1), "big") + 4
    if not 300 <= length <= 4096:
        continue
    p = subprocess.run(
        ["openssl", "x509", "-inform", "DER", "-noout", "-subject",
         "-serial", "-ext", "subjectKeyIdentifier"],
        input=vm[m.start():m.start() + length], capture_output=True)
    if p.returncode != 0:
        continue
    out = p.stdout.decode()
    if "CN=" + expected_cn + "\n" not in out and "CN = " + expected_cn + "\n" not in out:
        continue
    serial = re.search(r"^serial=([0-9A-Fa-f]+)$", out, re.M)
    skid = re.search(r"Subject Key Identifier:\s*\n\s*([0-9A-Fa-f:]+)", out)
    if serial and skid:
        matches.append((serial.group(1).lower(),
                        skid.group(1).replace(":", "").lower()))
uniq = sorted(set(matches))
if len(uniq) != 1:
    sys.exit("ERROR: expected exactly 1 embedded '%s' certificate, found %d: %r"
             % (expected_cn, len(uniq), uniq))
print("serial=" + uniq[0][0])
print("skid=" + uniq[0][1])
CERTEOF
)"
    cert_serial="$(sed -n 's/^serial=//p' <<<"$cert_ids")"
    cert_skid="$(sed -n 's/^skid=//p' <<<"$cert_ids")"
    echo "embedded signing cert (from the booted UKI's .linux): serial=$cert_serial skid=$cert_skid"
    [[ -n "$cert_serial" && -n "$cert_skid" ]] || { echo "Error: could not extract the embedded signing certificate" >&2; exit 1; }

    isofs_sig_key="$(vm_ssh 'modinfo -F sig_key isofs' || true)"
    echo "isofs.ko sig_key: $isofs_sig_key"
    isofs_sig_key_norm="$(tr -d ':' <<<"$isofs_sig_key" | tr '[:upper:]' '[:lower:]')"
    assert_eq "isofs.ko sig_key equals the UKI-embedded signing cert's serial (module -> cert)" \
        "$isofs_sig_key_norm" "$cert_serial"

    builtin_keys_norm="$(tr -d ':' <<<"$builtin_keys" | tr '[:upper:]' '[:lower:]')"
    assert_true "builtin trusted keyring entry ID equals that cert's SKID (cert -> keyring)" \
        bash -c "grep -qF '$cert_skid' <<<'$builtin_keys_norm'"

    vm_ssh 'modprobe -v isofs' >/dev/null 2>&1
    lsmod_after_isofs="$(vm_ssh 'lsmod' || true)"
    assert_true "a signed in-tree module (isofs) loads successfully under lockdown" \
        bash -c "grep -qE '^isofs[[:space:]]' <<<'$lsmod_after_isofs'"
    vm_ssh 'rmmod isofs' >/dev/null 2>&1 || true

    # (b) A genuine Surface in-tree module -- confirm it carries the SAME
    # build-time signer as the profile-neutral isofs check above (the real
    # question this step answers: are Surface modules signed by a
    # kernel-trusted key, or would they need re-signing with the Snosi MOK).
    surface_signer="$(vm_ssh 'modinfo -F signer surface_aggregator' || true)"
    echo "surface_aggregator.ko signer: $surface_signer"
    assert_eq "surface_aggregator.ko is signed by the SAME kernel build-time key as isofs.ko" \
        "$surface_signer" "$isofs_signer"

    # ...and at fingerprint level, not just signer-CN level: the sig_key
    # (cert serial, see above) must be identical too, i.e. the same
    # per-build certificate signed both the core and the Surface module.
    surface_sig_key="$(vm_ssh 'modinfo -F sig_key surface_aggregator' || true)"
    surface_sig_key_norm="$(tr -d ':' <<<"$surface_sig_key" | tr '[:upper:]' '[:lower:]')"
    assert_eq "surface_aggregator.ko sig_key fingerprint equals isofs.ko's (same per-build cert)" \
        "$surface_sig_key_norm" "$isofs_sig_key_norm"

    # (c) A deliberately UNSIGNED trivial out-of-tree module, built in-guest
    # against the exact running kernel's headers (gcc/make/linux-headers-
    # surface are all present in the built image -- confirmed during Phase
    # 6 authoring). No module-signing private key exists in the guest, so
    # this module can never be anything but unsigned -- proves signature
    # enforcement is actually active, not merely configured.
    vm_ssh 'rm -rf /root/trivial-mod && mkdir -p /root/trivial-mod'
    vm_ssh "cat > /root/trivial-mod/trivial.c" <<'EOF'
#include <linux/module.h>
#include <linux/kernel.h>
MODULE_LICENSE("GPL");
static int __init trivial_init(void) { return 0; }
static void __exit trivial_exit(void) { }
module_init(trivial_init);
module_exit(trivial_exit);
EOF
    vm_ssh "printf 'obj-m += trivial.o\nall:\n\t\$(MAKE) -C /lib/modules/%s/build M=\$(PWD) modules\n' '$kver' > /root/trivial-mod/Makefile"

    build_out=""
    build_rc=0
    build_out="$(vm_ssh 'cd /root/trivial-mod && make 2>&1')" || build_rc=$?
    echo "$build_out"
    assert_eq "trivial out-of-tree module builds successfully against linux-headers-surface" "$build_rc" "0"

    unsigned_signer="$(vm_ssh 'modinfo -F signer /root/trivial-mod/trivial.ko' || true)"
    echo "trivial.ko signer: '$unsigned_signer'"
    assert_eq "the freshly built module is genuinely unsigned (no signer field)" "$unsigned_signer" ""

    insmod_out=""
    insmod_rc=0
    insmod_out="$(vm_ssh 'insmod /root/trivial-mod/trivial.ko 2>&1')" || insmod_rc=$?
    echo "insmod trivial.ko: rc=$insmod_rc: $insmod_out"
    assert_true "loading the unsigned module is REJECTED under enforced lockdown" \
        bash -c "[[ $insmod_rc -ne 0 ]]"

    dmesg_reject="$(vm_ssh 'dmesg | tail -20' || true)"
    echo "dmesg tail after rejected insmod:"
    echo "$dmesg_reject"

    assert_nvpcr_journal_clean "no NvPCR-related journal errors after the module-trust check"
fi

# --- snow-linux-live-setup.service: corrected live-media gate ---
if [[ "$IMAGE_ID" == snow ]]; then
    live_active="$(vm_ssh 'systemctl show -P ActiveState snow-linux-live-setup.service' || true)"
    live_result="$(vm_ssh 'systemctl show -P Result snow-linux-live-setup.service' || true)"
    live_cond="$(vm_ssh 'systemctl show -P ConditionResult snow-linux-live-setup.service' || true)"
    assert_eq "snow-linux-live-setup.service did not run on a native install (ActiveState)" "$live_active" "inactive"
    assert_eq "snow-linux-live-setup.service ConditionResult is no (no snow-linux.live=1 on cmdline)" "$live_cond" "no"
    assert_true "snow-linux-live-setup.service Result is not failed" \
        bash -c "[[ '$live_result' != failed ]]"
    assert_false "no passwordless 'snow' user was created on this native install" \
        vm_ssh 'id -u snow'
fi

# --- first-boot preset parity: reuse test/tests/05-firstboot-presets.sh verbatim ---
echo ""
echo "=== Step 3b: first-boot preset parity (test/tests/05-firstboot-presets.sh) ==="
vm_ssh 'mkdir -p /tmp/test-lib'
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" "$SCRIPT_DIR/lib/helpers.sh" root@localhost:/tmp/test-lib/helpers.sh
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" "$SCRIPT_DIR/tests/05-firstboot-presets.sh" root@localhost:/tmp/05-firstboot-presets.sh
set +e
presets_out="$(vm_ssh 'TEST_LIB_DIR=/tmp/test-lib bash /tmp/05-firstboot-presets.sh' 2>&1)"
set -e
echo "$presets_out"
# test/tests/05-firstboot-presets.sh was written for the bootc profiles and
# requires EVERY manifest-recorded enablement symlink to be recreated by
# presets. Reusing it verbatim against a native secure profile surfaces
# three EXPECTED misses, confirmed live and root-caused (not weakened away,
# not assumed):
#   - timers.target.wants/bootc-update-stage.timer,
#     timers.target.wants/nbc-update-download.timer: permanently MASKED on
#     every native profile (docs/native-ab-contracts.md, native updater
#     isolation; confirmed elsewhere in this suite by
#     test/native-ab-components-test.sh's check_masked_timer) -- a masked
#     unit's .wants/ symlink can never be recreated by a preset pass, by
#     design, regardless of what the manifest (captured generically for
#     every profile) expects.
#   - local-fs.target.wants/run-lock.mount: this profile's Forky systemd
#     261 (shared/native-ab-secure/mkosi.conf) no longer ships a
#     run-lock.mount unit at all -- confirmed live (`dpkg -L systemd` on
#     the booted image has no run-lock.mount, and /run/lock is already a
#     plain directory under the API-mounted /run tmpfs, no separate mount
#     needed). The shared enablement-manifest.txt was captured against
#     whatever systemd version was in the tree at that finalize step; a
#     unit newer systemd no longer ships can never be recreated either.
# Assert the missing set is EXACTLY these three (not merely a subset, and
# not "any failure is fine") and that they are the ONLY failure the shared
# script reported -- any other regression still fails this test.
expected_missing=$'/etc/systemd/system/local-fs.target.wants/run-lock.mount\n/etc/systemd/system/timers.target.wants/bootc-update-stage.timer\n/etc/systemd/system/timers.target.wants/nbc-update-download.timer'
actual_missing="$(grep '^# MISSING: ' <<<"$presets_out" | sed 's/^# MISSING: //' | LC_ALL=C sort)"
assert_eq "05-firstboot-presets.sh's missing set is exactly the three known native/Forky exceptions" \
    "$actual_missing" "$expected_missing"
assert_eq "05-firstboot-presets.sh reports exactly 1 failure (only the known exceptions)" \
    "$(grep -oE '[0-9]+ failed' <<<"$presets_out" | grep -oE '^[0-9]+')" "1"
# The run-lock.mount allowlist entry above is a string match against
# 05-firstboot-presets.sh's MISSING report -- that alone can't distinguish
# "this Forky systemd genuinely ships no run-lock.mount unit" from "some
# unrelated preset regression happens to produce the same path string".
# Re-confirm structurally, in the guest, that the unit file itself is
# absent from the booted systemd package (not merely un-enabled):
run_lock_unit_count="$(vm_ssh 'dpkg -L systemd | grep -c "/run-lock\.mount$"' || true)"
assert_eq "systemd package ships no run-lock.mount unit on this Forky build (structural re-check, not just the MISSING string)" \
    "$run_lock_unit_count" "0"
assert_false "run-lock.mount unit file does not exist anywhere under /usr/lib/systemd/system" \
    vm_ssh 'test -e /usr/lib/systemd/system/run-lock.mount'

# ===========================================================================
# Step 4: in-guest TPM enrollment mirroring native-ab-secure-rotation-test.sh
# ===========================================================================
echo ""
echo "=== Step 4: in-guest TPM enrollment (signed PCR 11, empty raw-PCR set) ==="

var_device="$(vm_ssh "lsblk -J -o PATH,PARTLABEL | jq -er '.. | objects | select(.partlabel? == \"var\") | .path'")"
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" \
    "$ROOT_DIR/.snosi-private/pcr-signing.pub" root@localhost:/run/pcr-signing.pub
vm_ssh "install -m 0600 /dev/null /run/native-ab-secure-boot-test-recovery.key"
guest_with_input() { # input_file command...
    local input="$1"
    shift
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" -i "$SSH_KEY" root@localhost "$@" < "$input"
}
guest_with_input "$recovery_key_file" "cat > /run/native-ab-secure-boot-test-recovery.key"

enroll_out=""
enroll_rc=0
enroll_out="$(vm_ssh "systemd-cryptenroll --unlock-key-file=/run/native-ab-secure-boot-test-recovery.key --tpm2-device=auto --tpm2-pcrs= --tpm2-pcrlock= --tpm2-public-key=/run/pcr-signing.pub --tpm2-public-key-pcrs=11 '$var_device'" 2>&1)" || enroll_rc=$?
echo "$enroll_out"
assert_eq "systemd-cryptenroll (signed PCR 11, empty raw-PCR set) succeeds" "$enroll_rc" "0"
vm_ssh "shred -u /run/native-ab-secure-boot-test-recovery.key /run/pcr-signing.pub" || true

luks_dump="$(vm_ssh "cryptsetup luksDump --dump-json-metadata '$var_device'")"
tpm_token_count="$(jq '[.tokens[] | select(.type == "systemd-tpm2")] | length' <<<"$luks_dump")"
assert_eq "exactly one systemd-tpm2 LUKS token after enrollment" "$tpm_token_count" "1"
token_policy_ok="$(jq -r '
    [.tokens[] | select(.type == "systemd-tpm2")][0]
    | (."tpm2-pcrs" == []) and (.tpm2_pubkey_pcrs == [11]) and (has("tpm2-pcrlock") | not)
' <<<"$luks_dump")"
assert_eq "TPM token uses signed PCR 11-only policy (empty raw-PCR set)" "$token_policy_ok" "true"

echo ""
echo "=== Step 4b: reboot with ZERO serial input -- TPM must auto-unlock /var ==="
reboot_guest
booted_version="$(guest_version)"
assert_eq "still booted version N after the TPM-enrolled reboot" "$booted_version" "$n_version"
prompt_count_after_enroll="$(grep -c 'typed recovery passphrase' "$WORK_DIR/console.log" || true)"
assert_eq "console pump never had to type a passphrase again after TPM enrollment" "$prompt_count_after_enroll" "1"
var_source="$(vm_ssh 'findmnt -no SOURCE /var' || true)"
assert_eq "/var is still mounted from the LUKS mapper after unattended TPM unlock" "$var_source" "/dev/mapper/var"
assert_nvpcr_journal_clean "no NvPCR-related journal errors after the TPM-enrolled reboot"

# ===========================================================================
# Step 5: post-TPM-unlock assertions. tmpfiles ownership and dpkg-query are
# profile-neutral (fresh-/var tmpfiles rules and the /var/lib/dpkg
# relocation symlink apply to every profile, cayo included) and always run;
# the GNOME-desktop-specific checks (graphical.target, gdm.service, a
# logind seat, notify-send, the hicolor-icon-cache sysext fixture) are
# gated on HAS_DESKTOP below and skipped for cayo-ab.
# ===========================================================================
echo ""
echo "=== Step 5: post-TPM-unlock assertions ==="

var_home_owner="$(vm_ssh "stat -c '%U:%G %a' /var/home" || true)"
assert_eq "/var/home exists with expected fresh-tmpfiles ownership/mode" "$var_home_owner" "root:root 755"
var_roothome_owner="$(vm_ssh "stat -c '%U:%G %a' /var/roothome" || true)"
assert_eq "/var/roothome exists with expected fresh-tmpfiles ownership/mode" "$var_roothome_owner" "root:root 700"
var_opt_owner="$(vm_ssh "stat -c '%U:%G %a' /var/opt" || true)"
assert_eq "/var/opt exists with expected fresh-tmpfiles ownership/mode" "$var_opt_owner" "root:root 755"

dpkg_link_target="$(vm_ssh 'readlink /var/lib/dpkg' || true)"
assert_eq "/var/lib/dpkg is the factory dpkg relocation symlink" "$dpkg_link_target" "../../usr/lib/sysimage/dpkg"
dpkg_query_out="$(vm_ssh "dpkg-query -W -f='\${Package} \${Version}\n' systemd" || true)"
assert_true "dpkg-query works against the relocated /var/lib/dpkg" \
    bash -c "[[ -n '$dpkg_query_out' ]]"
echo "dpkg-query systemd: $dpkg_query_out"

if [[ "$HAS_DESKTOP" -eq 1 ]]; then
    echo ""
    echo "=== Step 5a: desktop assertions ==="

    # wait_for_ssh only proves the SSH port is open, not that the graphical
    # session has finished starting (GNOME/GDM take longer than sshd on a
    # desktop image) -- settle on system-running (or a bounded wait) before
    # asserting graphical.target, or this races and flakes (observed live: SSH
    # reachable while graphical.target was still activating).
    vm_ssh 'systemctl is-system-running --wait' >/dev/null || true

    graphical_state="$(vm_ssh 'systemctl show -P ActiveState graphical.target' || true)"
    assert_eq "graphical.target is active" "$graphical_state" "active"
    gdm_state="$(vm_ssh 'systemctl show -P ActiveState gdm.service' || true)"
    assert_eq "gdm.service is active" "$gdm_state" "active"
    seat_listing="$(vm_ssh 'loginctl list-seats --no-legend' || true)"
    assert_contains "a logind seat exists" "$seat_listing" "seat0"
    assert_true "notify-send is present (libnotify-bin, graphical package set)" \
        vm_ssh 'command -v notify-send'

    # --- minimal ad hoc sysext fixture: plain-directory form (systemd-sysext(8)
    # merges directories exactly like raw images; no erofs/squashfs build or
    # guest-side loop mount needed to prove the icon-cache contract). ---
    echo ""
    echo "=== Step 5b: ad hoc sysext fixture (hicolor icon-cache contract) ==="
    guest_os_id="$(vm_ssh '. /etc/os-release; echo "$ID"')"
    [[ -n "$guest_os_id" ]] || { echo "Error: could not read guest ID= from os-release" >&2; exit 1; }
    # The image also sets SYSEXT_LEVEL (confirmed live: "SYSEXT_LEVEL=1.0" on
    # this build). Per os-release(5)/extension-release semantics, when the host
    # declares SYSEXT_LEVEL, systemd-sysext requires the extension to declare a
    # matching one too -- ID= alone is not sufficient and the merge silently
    # reports "No suitable extensions found (1 ignored due to incompatible
    # image(s))" (observed live). Real snosi sysexts already set this; mirror
    # it here instead of hardcoding "1.0".
    guest_sysext_level="$(vm_ssh '. /etc/os-release; echo "$SYSEXT_LEVEL"')"
    fixture="$WORK_DIR/sysext-fixture"
    mkdir -p "$fixture/usr/lib/extension-release.d" \
        "$fixture/usr/share/applications" \
        "$fixture/usr/share/icons/hicolor/48x48/apps"
    {
        echo "ID=$guest_os_id"
        [[ -z "$guest_sysext_level" ]] || echo "SYSEXT_LEVEL=$guest_sysext_level"
    } > "$fixture/usr/lib/extension-release.d/extension-release.native-ab-secure-boot-test"
    cat > "$fixture/usr/share/applications/native-ab-secure-boot-test.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=native-ab-secure-boot-test fixture
Exec=/bin/true
Icon=native-ab-secure-boot-test
NoDisplay=true
EOF
    # A minimal but syntactically valid 1x1 PNG (hicolor only cares that a file
    # with the right name/path exists to be indexed).
    python3 -c "
import base64, pathlib
png = base64.b64decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
)
pathlib.Path('$fixture/usr/share/icons/hicolor/48x48/apps/native-ab-secure-boot-test.png').write_bytes(png)
"
    vm_ssh 'mkdir -p /var/lib/extensions/native-ab-secure-boot-test'
    scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" -r "$fixture/." \
        root@localhost:/var/lib/extensions/native-ab-secure-boot-test/

    merge_out=""
    merge_rc=0
    merge_out="$(vm_ssh 'systemd-sysext merge' 2>&1)" || merge_rc=$?
    echo "$merge_out"
    assert_eq "systemd-sysext merge succeeds with the fixture present" "$merge_rc" "0"
    # `systemd-sysext status` lists, per hierarchy, either "none" (nothing
    # merged) or the merged extension name(s) + a SINCE timestamp -- there is
    # no literal "active" column in its output (confirmed live); the extension
    # name appearing in the /usr row IS the "merged and active" signal.
    sysext_status="$(vm_ssh 'systemd-sysext status --no-pager' || true)"
    assert_contains "systemd-sysext status shows the fixture merged into /usr" "$sysext_status" "native-ab-secure-boot-test"
    assert_false "the /usr hierarchy no longer reports 'none' once merged" \
        bash -c "grep -qE '^/usr[[:space:]]+none[[:space:]]' <<<'$sysext_status'"
    desktop_listing="$(vm_ssh 'ls /usr/share/applications' || true)"
    assert_contains "fixture .desktop entry visible in merged /usr/share/applications" \
        "$desktop_listing" "native-ab-secure-boot-test.desktop"
    assert_false "no hicolor icon-theme.cache exists after merge (CLAUDE.md icon-cache rule)" \
        vm_ssh 'test -e /usr/share/icons/hicolor/icon-theme.cache'
    vm_ssh 'systemd-sysext unmerge'

else
    echo ""
    echo "=== Step 5a/5b: desktop assertions skipped -- IMAGE_ID=$IMAGE_ID has no desktop payload ==="
fi
# ===========================================================================
# Step 6: secure update hop N -> N+1 under enforced Secure Boot
# ===========================================================================
echo ""
echo "=== Step 6: secure update hop (publish N+1, stage, reboot) ==="

# Persistence marker written now (in /var, survives reboots+updates) and in
# the /etc overlay upper (survives reboots+updates, NOT the image's lower).
vm_ssh 'echo native-ab-secure-boot-test-var-marker > /var/lib/native-ab-secure-boot-test.marker'
vm_ssh "printf '\nnative-ab-secure-boot-test etc marker\n' >> /etc/issue"

# The ephemeral signing key already exists: it is generated (or restored
# from SIGNING_GNUPGHOME under SKIP_BUILD=1) BEFORE the Step 0 builds, since
# build_profile bakes its public half into every built image.
publish_version "$BUILD_N1_DIR"

cat > "$WORK_DIR/overrides/10-root-verity.transfer" <<EOF
[Transfer]
ProtectVersion=%A
Verify=yes

[Source]
Type=url-file
Path=http://10.0.2.2:${SOURCE_PORT}/os/
MatchPattern=${CHANNEL}_@v_@u.root-verity.raw.xz

[Target]
Type=partition
Path=auto
MatchPattern=${IMAGE_ID}_@v_v
MatchPartitionType=root-verity
PartitionFlags=0
ReadOnly=yes
InstancesMax=2
EOF
cat > "$WORK_DIR/overrides/20-root.transfer" <<EOF
[Transfer]
ProtectVersion=%A
Verify=yes

[Source]
Type=url-file
Path=http://10.0.2.2:${SOURCE_PORT}/os/
MatchPattern=${CHANNEL}_@v_@u.root.raw.xz

[Target]
Type=partition
Path=auto
MatchPattern=${IMAGE_ID}_@v_r
MatchPartitionType=root
PartitionFlags=0
ReadOnly=yes
InstancesMax=2
EOF
cat > "$WORK_DIR/overrides/90-uki.transfer" <<EOF
[Transfer]
ProtectVersion=%A
Verify=yes

[Source]
Type=url-file
Path=http://10.0.2.2:${SOURCE_PORT}/os/
MatchPattern=${CHANNEL}_@v.efi

[Target]
Type=regular-file
Path=/EFI/Linux
PathRelativeTo=boot
MatchPattern=${CHANNEL}_@v+@l-@d.efi
MatchPattern=${CHANNEL}_@v+@l.efi
MatchPattern=${CHANNEL}_@v.efi
Mode=0444
TriesLeft=3
TriesDone=0
InstancesMax=2
EOF

vm_ssh 'mkdir -p /etc/sysupdate.d'
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" \
    "$WORK_DIR/overrides/10-root-verity.transfer" \
    "$WORK_DIR/overrides/20-root.transfer" \
    "$WORK_DIR/overrides/90-uki.transfer" \
    root@localhost:/etc/sysupdate.d/

# ---------------------------------------------------------------------------
# Shipped vendor keyring (the reason THIS harness, not a cayo-ab-raw one,
# carries this coverage): systemd 261 -- which only the production profiles
# run -- reads the vendor update keyring at
# /usr/lib/systemd/import-pubring.pgp, with NO legacy .gpg fallback for the
# /usr path (commit 91718d7). Trixie's systemd 257, which cayo-ab-raw
# boots, still reads the OLD /usr/lib/systemd/import-pubring.gpg name, so
# no cayo-ab-raw harness (updateux/components/update/publication) can
# exercise this link -- which is exactly how shipping only .gpg produced a
# total signature-verification outage on real installs while every QEMU
# harness passed via its /etc/systemd/import-pubring.gpg override. This
# harness therefore installs NO /etc pubring override at all: the upcoming
# stage must verify using ONLY the /usr vendor keyring baked at build time
# (see build_profile), and Step 6c proves the negative (a wrong-key-signed
# index is rejected through the same shipped ring).
# ---------------------------------------------------------------------------
assert_false "no /etc/systemd/import-pubring.gpg override (shipped trust path only)" \
    vm_ssh 'test -e /etc/systemd/import-pubring.gpg'
assert_false "no /etc/systemd/import-pubring.pgp override (shipped trust path only)" \
    vm_ssh 'test -e /etc/systemd/import-pubring.pgp'
ephemeral_ring_hash="$(sha256sum "$WORK_DIR/import-pubring.gpg")"
ephemeral_ring_hash="${ephemeral_ring_hash%% *}"
guest_pgp_hash="$(vm_ssh 'sha256sum /usr/lib/systemd/import-pubring.pgp 2>/dev/null' | awk '{print $1}' || true)"
assert_eq "shipped /usr/lib/systemd/import-pubring.pgp is the baked ephemeral test ring" \
    "$guest_pgp_hash" "$ephemeral_ring_hash"
guest_gpg_hash="$(vm_ssh 'sha256sum /usr/lib/systemd/import-pubring.gpg 2>/dev/null' | awk '{print $1}' || true)"
assert_eq "shipped /usr/lib/systemd/import-pubring.gpg twin matches the baked ring" \
    "$guest_gpg_hash" "$ephemeral_ring_hash"
# Canary for the 261 semantic itself: the import machinery that sysupdate
# spawns must reference the vendor .pgp name. If a future systemd renames
# the vendor path yet again, this pinpoints it instead of leaving only an
# opaque verification failure.
pull_refs_pgp="$(vm_ssh "grep -al 'import-pubring.pgp' /usr/lib/systemd/systemd-pull /usr/lib/systemd/systemd-sysupdate 2>/dev/null" || true)"
assert_true "guest systemd's import machinery references the vendor .pgp name (261 semantics)" \
    bash -c "[[ -n '$pull_refs_pgp' ]]"

# Serve publish_dest itself (.../$IMAGE_ID/x86-64) as the HTTP root under
# an "os" symlink so it matches the transfer files' Path=.../os/ exactly
# (same indirection test/native-ab-updateux-test.sh uses) -- serving
# publish-out/$IMAGE_ID directly would put the real files one level deeper,
# at /x86-64/..., not /os/... (caught live: first attempt 404/empty-replied
# against the wrong path).
mkdir -p "$WORK_DIR/http-root"
ln -s "$publish_dest" "$WORK_DIR/http-root/os"
python3 -m http.server "$SOURCE_PORT" --bind 0.0.0.0 --directory "$WORK_DIR/http-root" \
    >"$WORK_DIR/http.log" 2>&1 &
HTTP_PID=$!
vm_ssh "curl --fail --silent --show-error 'http://10.0.2.2:${SOURCE_PORT}/os/SHA256SUMS' >/dev/null"

stager_out=""
stager_rc=0
stager_out="$(vm_ssh '/usr/libexec/snosi-sysupdate-stage' 2>&1)" || stager_rc=$?
echo "$stager_out"
assert_eq "snosi-sysupdate-stage stages N+1" "$stager_rc" "0"

echo ""
echo "=== Step 6b: reboot into N+1 with ZERO serial input -- signed PCR 11 must survive the new UKI ==="
reboot_guest
rebooted_version="$(guest_version)"
assert_eq "booted version is N+1 after the secure update hop" "$rebooted_version" "$n1_version"
prompt_count_after_update="$(grep -c 'typed recovery passphrase' "$WORK_DIR/console.log" || true)"
assert_eq "still no passphrase prompt after the N+1 reboot (PCR 11 signed policy survived the new UKI)" \
    "$prompt_count_after_update" "1"

sb_state="$(vm_ssh 'mokutil --sb-state' || true)"
assert_contains "N+1: Secure Boot still enabled" "$sb_state" "SecureBoot enabled"
bootctl_status="$(vm_ssh 'bootctl --no-pager status' || true)"
assert_contains "N+1: Measured UKI: yes (new MOK-signed UKI actually loaded)" "$bootctl_status" "Measured UKI: yes"
var_source="$(vm_ssh 'findmnt -no SOURCE /var' || true)"
assert_eq "N+1: /var still auto-unlocked via the TPM mapper" "$var_source" "/dev/mapper/var"
assert_nvpcr_journal_clean "no NvPCR-related journal errors after the N+1 update reboot"

luks_dump="$(vm_ssh "cryptsetup luksDump --dump-json-metadata '$var_device'")"
tpm_token_count="$(jq '[.tokens[] | select(.type == "systemd-tpm2")] | length' <<<"$luks_dump")"
assert_eq "N+1: still exactly one systemd-tpm2 LUKS token (no re-enrollment happened)" "$tpm_token_count" "1"

marker_value="$(vm_ssh 'cat /var/lib/native-ab-secure-boot-test.marker' || true)"
assert_eq "/var persistence marker survived the update" "$marker_value" "native-ab-secure-boot-test-var-marker"
etc_marker="$(vm_ssh 'tail -1 /etc/issue' || true)"
assert_eq "/etc overlay upper marker survived the update" "$etc_marker" "native-ab-secure-boot-test etc marker"

esp_listing="$(vm_ssh 'ls /boot/EFI/Linux' || true)"
echo "ESP listing after update: $esp_listing"
assert_contains "N's UKI is still present in the ESP (InstancesMax=2 rollback entry)" "$esp_listing" "${CHANNEL}_${n_version}"
assert_contains "N+1's UKI is present in the ESP" "$esp_listing" "${CHANNEL}_${n1_version}"
layout_after_update="$(vm_ssh 'lsblk -J -o PARTLABEL' || echo "{}")"
n_root_still_present="$(jq --arg l "${IMAGE_ID}_${n_version}_r" \
    '[.. | objects | select(.partlabel? == $l)] | length' <<<"$layout_after_update")"
assert_eq "N's root partition slot (rollback target) is still present" "$n_root_still_present" "1"

health="$(vm_ssh 'systemctl is-system-running --wait' || true)"
assert_true "system health is running or degraded after the secure update" \
    bash -c "[[ '$health' == running || '$health' == degraded ]]"

# ===========================================================================
# Step 6c: wrong-key-signed index fails closed through the SAME shipped
# vendor keyring. Negative half of the shipped-trust-path proof: Step 6
# proved a pull verifies with no /etc override; this proves that success
# was actual signature enforcement, not verification silently not
# happening. This is the 2026-07-17 outage's exact failure-mode class -- a
# structurally valid signature that no key in the effective keyring can
# check ("gpg: Can't check signature: No public key").
# ===========================================================================
echo ""
echo "=== Step 6c: index signed by an untrusted key is rejected via the shipped keyring ==="

cp "$publish_dest/SHA256SUMS" "$WORK_DIR/sha256sums.n1-good"
cp "$publish_dest/SHA256SUMS.gpg" "$WORK_DIR/sha256sums.gpg.n1-good"

# Fabricate a version newer than the running N+1 by hardlinking N+1's own
# published bytes under new names (test/native-ab-updateux-test.sh's Step 4
# trick: no extra multi-gigabyte build, and check-new MUST attempt to trust
# the index rather than silently no-opping as "nothing newer").
wrong_fake_version="$(printf '%014d' "$((n1_version + 1))")"
n1_root_real="$(find "$publish_dest" -maxdepth 1 -name "${CHANNEL}_${n1_version}_*.root.raw.xz")"
n1_verity_real="$(find "$publish_dest" -maxdepth 1 -name "${CHANNEL}_${n1_version}_*.root-verity.raw.xz")"
wrong_root_uuid="$(basename "$n1_root_real" | sed -E "s/^${CHANNEL}_${n1_version}_([0-9a-fA-F-]+)\.root\.raw\.xz\$/\\1/")"
wrong_verity_uuid="$(basename "$n1_verity_real" | sed -E "s/^${CHANNEL}_${n1_version}_([0-9a-fA-F-]+)\.root-verity\.raw\.xz\$/\\1/")"
ln "$n1_root_real" "$publish_dest/${CHANNEL}_${wrong_fake_version}_${wrong_root_uuid}.root.raw.xz"
ln "$n1_verity_real" "$publish_dest/${CHANNEL}_${wrong_fake_version}_${wrong_verity_uuid}.root-verity.raw.xz"
ln "$publish_dest/${CHANNEL}_${n1_version}.efi" "$publish_dest/${CHANNEL}_${wrong_fake_version}.efi"
(cd "$publish_dest" && sha256sum \
    "${CHANNEL}_${wrong_fake_version}_${wrong_root_uuid}.root.raw.xz" \
    "${CHANNEL}_${wrong_fake_version}_${wrong_verity_uuid}.root-verity.raw.xz" \
    "${CHANNEL}_${wrong_fake_version}.efi") >> "$publish_dest/SHA256SUMS"

mkdir -p "$WORK_DIR/gnupg-wrong"
chmod 700 "$WORK_DIR/gnupg-wrong"
gpg --homedir "$WORK_DIR/gnupg-wrong" --batch --passphrase '' --quick-generate-key \
    'snosi secure-boot test WRONG key <native-ab-secure-boot-test-wrong@invalid>' ed25519 sign 0
gpg --homedir "$WORK_DIR/gnupg-wrong" --batch --yes --detach-sign \
    -o "$publish_dest/SHA256SUMS.gpg" "$publish_dest/SHA256SUMS"
# Distinguish this leg from a corrupted-bytes tamper case (updateux Step 4):
# the signature must be cryptographically VALID -- just made by a key the
# shipped vendor keyring does not contain.
assert_true "wrong-key signature is itself a valid signature (by the wrong key)" \
    gpg --homedir "$WORK_DIR/gnupg-wrong" --verify \
    "$publish_dest/SHA256SUMS.gpg" "$publish_dest/SHA256SUMS"

stager_out=""
stager_rc=0
stager_out="$(vm_ssh '/usr/libexec/snosi-sysupdate-stage' 2>&1)" || stager_rc=$?
echo "$stager_out"
assert_true "stager exits non-zero on the wrong-key-signed index" \
    bash -c "[[ $stager_rc -ne 0 ]]"
check_content="$(vm_ssh 'cat /run/snosi/update-check' 2>/dev/null || true)"
assert_contains "update-check reports outcome=failed on the wrong-key index" \
    "$check_content" "outcome=failed"
assert_false "nothing staged from the wrong-key index" \
    vm_ssh 'test -e /run/snosi/update-staged'
layout_after_wrong_key="$(vm_ssh 'lsblk -J -o PARTLABEL' || echo "{}")"
wrong_fake_count="$(jq --arg l "${IMAGE_ID}_${wrong_fake_version}_r" \
    '[.. | objects | select(.partlabel? == $l)] | length' <<<"$layout_after_wrong_key")"
assert_eq "no partition labeled with the wrong-key fake version" "$wrong_fake_count" "0"
still_n1="$(guest_version)"
assert_eq "running version unchanged after the wrong-key rejection" "$still_n1" "$n1_version"

# Restore the origin to its known-good N+1 state: --full-window continues
# from here (publish_version for N+2 would regenerate the index anyway, but
# the fake hardlinks must not linger in the served directory either).
rm -f "$publish_dest/${CHANNEL}_${wrong_fake_version}_${wrong_root_uuid}.root.raw.xz" \
    "$publish_dest/${CHANNEL}_${wrong_fake_version}_${wrong_verity_uuid}.root-verity.raw.xz" \
    "$publish_dest/${CHANNEL}_${wrong_fake_version}.efi"
mv "$WORK_DIR/sha256sums.n1-good" "$publish_dest/SHA256SUMS"
mv "$WORK_DIR/sha256sums.gpg.n1-good" "$publish_dest/SHA256SUMS.gpg"

# ===========================================================================
# Steps 8-11 (--full-window only): N+2, N+3, explicit rollback, boot-count
# fallback -- see the header comment for the full narrative. Default-mode
# behavior above this point is completely unchanged; everything below is
# gated on FULL_WINDOW.
# ===========================================================================
if [[ "$FULL_WINDOW" == 1 ]]; then
    echo ""
    echo "=== Step 8: build N+2 and N+3 ($PROFILE) ==="

    # N's root slot must be captured NOW -- it is still present (Step 6's
    # own "N's root partition slot is still present" assertion just above
    # confirmed it), but InstancesMax=2 vacuums it the moment N+2 installs.
    n_root_path="$(partition_path "${IMAGE_ID}_${n_version}_r")"

    if [[ "$SKIP_BUILD" == 1 ]]; then
        [[ -n "$BUILD_N2_DIR" && -n "$BUILD_N3_DIR" ]] || {
            echo "Error: SKIP_BUILD=1 --full-window requires BUILD_N2_DIR and BUILD_N3_DIR" >&2
            exit 1
        }
        echo "SKIP_BUILD=1: reusing prebuilt artifacts at $BUILD_N2_DIR and $BUILD_N3_DIR"
    else
        BUILD_N2_DIR="$WORK_DIR/build-n2"
        BUILD_N3_DIR="$WORK_DIR/build-n3"
        build_profile "$BUILD_N2_DIR"
        build_profile "$BUILD_N3_DIR"
    fi
    for f in manifest raw efi features.json "${IMAGE_ID}_@v.root.raw.raw" "${IMAGE_ID}_@v.root-verity.raw.raw"; do
        [[ -f "$BUILD_N2_DIR/$PROFILE.$f" ]] || { echo "Error: missing N+2 artifact: $f" >&2; exit 1; }
        [[ -f "$BUILD_N3_DIR/$PROFILE.$f" ]] || { echo "Error: missing N+3 artifact: $f" >&2; exit 1; }
    done
    n2_version="$(jq -er '.config.version' "$BUILD_N2_DIR/$PROFILE.manifest")"
    n3_version="$(jq -er '.config.version' "$BUILD_N3_DIR/$PROFILE.manifest")"
    echo "N+2=$n2_version  N+3=$n3_version"
    [[ "$n2_version" > "$n1_version" ]] || { echo "Error: N+2 version is not newer than N+1" >&2; exit 1; }
    [[ "$n3_version" > "$n2_version" ]] || { echo "Error: N+3 version is not newer than N+2" >&2; exit 1; }

    echo ""
    echo "=== Step 9: secure update hop N+1 -> N+2 ==="
    # N+1's slot must be captured before it, in turn, gets vacuumed by N+3.
    n1_root_path="$(partition_path "${IMAGE_ID}_${n1_version}_r")"

    publish_version "$BUILD_N2_DIR"
    ln -sfn "$publish_dest" "$WORK_DIR/http-root/os"
    vm_ssh "curl --fail --silent --show-error 'http://10.0.2.2:${SOURCE_PORT}/os/SHA256SUMS' >/dev/null"
    stager_out=""
    stager_rc=0
    stager_out="$(vm_ssh '/usr/libexec/snosi-sysupdate-stage' 2>&1)" || stager_rc=$?
    echo "$stager_out"
    assert_eq "snosi-sysupdate-stage stages N+2" "$stager_rc" "0"
    reboot_guest
    assert_post_update_common "$n2_version" "N+1->N+2"
    assert_root_slot_versions "N+1->N+2: root slots are exactly {N+1, N+2}" "$n1_version" "$n2_version"
    n2_root_path="$(partition_path "${IMAGE_ID}_${n2_version}_r")"
    assert_eq "N+2 physically reused N's freed root slot (InstancesMax=2 vacuum)" "$n2_root_path" "$n_root_path"

    echo ""
    echo "=== Step 10: secure update hop N+2 -> N+3 ==="
    publish_version "$BUILD_N3_DIR"
    ln -sfn "$publish_dest" "$WORK_DIR/http-root/os"
    vm_ssh "curl --fail --silent --show-error 'http://10.0.2.2:${SOURCE_PORT}/os/SHA256SUMS' >/dev/null"
    stager_out=""
    stager_rc=0
    stager_out="$(vm_ssh '/usr/libexec/snosi-sysupdate-stage' 2>&1)" || stager_rc=$?
    echo "$stager_out"
    assert_eq "snosi-sysupdate-stage stages N+3" "$stager_rc" "0"
    reboot_guest
    assert_post_update_common "$n3_version" "N+2->N+3"
    assert_root_slot_versions "N+2->N+3: root slots are exactly {N+2, N+3}" "$n2_version" "$n3_version"
    n3_root_path="$(partition_path "${IMAGE_ID}_${n3_version}_r")"
    assert_eq "N+3 physically reused N+1's freed root slot (InstancesMax=2 vacuum)" "$n3_root_path" "$n1_root_path"
    # (no separate NvPCR check here: assert_post_update_common above already
    # checked this boot's journal via assert_nvpcr_journal_clean)

    echo ""
    echo "=== Step 10b: explicit rollback N+3 -> N+2, then back to N+3 ==="
    esp_uki_entry "$n2_version"
    n2_uki_entry="$ESP_UKI_ENTRY"
    vm_ssh "bootctl set-oneshot '$n2_uki_entry'"
    reboot_guest
    assert_post_update_common "$n2_version" "explicit rollback N+3->N+2"
    reboot_guest
    assert_post_update_common "$n3_version" "rollback: return to persistent default N+3"

    echo ""
    echo "=== Step 11: boot-count fallback (re-arm N+3, corrupt from the host, 3 failed + 1 recovery boot) ==="
    esp_uki_entry "$n3_version"
    [[ "$ESP_UKI_ENTRY" == "${CHANNEL}_${n3_version}.efi" ]] || {
        echo "Error: N+3 was not blessed (no boot-counting suffix) before re-arming: $ESP_UKI_ENTRY" >&2
        exit 1
    }
    rearmed_entry="${CHANNEL}_${n3_version}+3-0.efi"
    vm_ssh "mv '/boot/EFI/Linux/$ESP_UKI_ENTRY' '/boot/EFI/Linux/$rearmed_entry'; sync -f /boot; bootctl set-default '$rearmed_entry'; test -e '/boot/EFI/Linux/$rearmed_entry'"
    pass "N+3 UKI re-armed to +3-0 for boot-count fallback testing"

    vm_force_stop
    host_corrupt_root_partition "$n3_version"
    host_inspect_esp "ESP shows N+3 re-armed at +3-0 before any failed boot attempt" "${CHANNEL}_${n3_version}+3-0.efi"

    # Seed the baseline from the ACTUAL pre-existing count in the cumulative
    # console.log, not a hardcoded 0: console_pump has been appending to the
    # same log file since the very first boot (step 3), across every reboot
    # in the run so far, so an unrelated "Entering emergency mode" earlier
    # in the run (e.g. a transient dracut hiccup on a prior boot that still
    # went on to reach SSH) would otherwise be silently double-counted as
    # this loop's own first match. Mirrors wait_for_emergency's own counting
    # expression.
    emergency_count="$(grep -c 'Entering emergency mode' "$WORK_DIR/console.log" 2>/dev/null || true)"
    for attempt in 1 2 3; do
        echo "Boot-count fallback attempt $attempt/3: power-cycling into corrupted N+3..."
        vm_boot "$DISK_IMAGE" "$WORK_DIR"
        start_console_pump "$WORK_DIR" "$recovery_key"
        emergency_count="$(wait_for_emergency "$emergency_count")" || {
            echo "BLOCKED: attempt $attempt did not reach dracut emergency mode" >&2
            exit 1
        }
        pass "boot-count fallback attempt $attempt reached dracut emergency mode (corrupted N+3 root failed verity)"
        vm_force_stop
        expected_suffix="+$((3 - attempt))-${attempt}"
        host_inspect_esp "ESP shows N+3 tries decremented after failed attempt $attempt ($expected_suffix)" \
            "${CHANNEL}_${n3_version}${expected_suffix}.efi"
    done

    echo "Fourth power-cycle: tries exhausted, systemd-boot must fall back to N+2 automatically"
    vm_boot "$DISK_IMAGE" "$WORK_DIR"
    start_console_pump "$WORK_DIR" "$recovery_key"
    if ! SSH_TIMEOUT="$BOOT_TIMEOUT" wait_for_ssh; then
        echo "=== console.log (fallback boot never reached SSH) ===" >&2
        tail -200 "$WORK_DIR/console.log" >&2 || true
        echo "BLOCKED: fourth power-cycle never reached SSH -- systemd-boot did not fall back to N+2" >&2
        exit 1
    fi
    assert_post_update_common "$n2_version" "boot-count fallback"
    esp_listing_after_fallback="$(vm_ssh 'ls /boot/EFI/Linux' || true)"
    echo "ESP listing after fallback: $esp_listing_after_fallback"
    assert_contains "N+3's exhausted entry ends at +0-3 after automatic fallback" \
        "$esp_listing_after_fallback" "${CHANNEL}_${n3_version}+0-3.efi"
    # (no separate NvPCR check here: assert_post_update_common above already
    # checked this boot's journal via assert_nvpcr_journal_clean)
fi

# ===========================================================================
# Step 7: recovery unlock check (non-destructive)
# ===========================================================================
echo ""
echo "=== Step 7: recovery keyslot still opens the volume (non-destructive) ==="
guest_with_input "$recovery_key_file" "cryptsetup open --test-passphrase --key-file=- '$var_device'"
pass "recovery keyslot still opens /var (cryptsetup open --test-passphrase)"

echo ""
if [[ "$FULL_WINDOW" == 1 ]]; then
    echo "Native A/B secure-boot/TPM/desktop full-window validation: N=$n_version -> N+1=$n1_version -> N+2=$n2_version -> N+3=$n3_version, rollback to N+2, boot-count fallback to N+2 ($PROFILE)"
else
    echo "Native A/B secure-boot/TPM/desktop validation: N=$n_version -> N+1=$n1_version ($PROFILE)"
fi
print_summary
