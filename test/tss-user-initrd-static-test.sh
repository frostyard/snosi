#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# snosi#723: the TPM tmpfiles/udev rules shipped by tpm2-tss reference the `tss`
# user and group, and they are processed inside the initrd on TPM-backed
# encrypted-root systems. The 95tss-user dracut module must carry those entries
# into the initramfs, and every TPM-enabled dracut profile must enable it.
#
# Static contract only: no root, no network, no image build. The end-to-end
# boot-journal assertion (a QEMU/physical boot showing none of the "Unknown
# user `tss`" messages) needs KVM and is intentionally not run in CI, matching
# every other QEMU harness in this repo.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module="$root/mkosi.images/base/mkosi.extra/usr/lib/dracut/modules.d/95tss-user/module-setup.sh"

[[ -f "$module" ]] || { echo "missing 95tss-user dracut module: $module" >&2; exit 1; }

# The module must inject the tss passwd and group entries into the initramfs.
grep -q '\^tss:' "$module" \
    || { echo "95tss-user does not select the tss passwd/group entries" >&2; exit 1; }
grep -q 'initdir/etc/passwd' "$module" \
    || { echo "95tss-user does not append tss to the initramfs /etc/passwd" >&2; exit 1; }
grep -q 'initdir/etc/group' "$module" \
    || { echo "95tss-user does not append tss to the initramfs /etc/group" >&2; exit 1; }

# It must depend on tpm2-tss so it installs after the module that ships the TPM
# tmpfiles/udev rules and creates the initramfs /etc/passwd.
grep -Eq '^[[:space:]]*echo tpm2-tss' "$module" \
    || { echo "95tss-user must depend on the tpm2-tss dracut module" >&2; exit 1; }

# Every TPM-enabled dracut profile must force-add the module. These are the
# exact dracut.conf.d files that enable tpm2-tss today; if tpm2-tss is enabled
# but tss-user is not, the initrd regresses to the snosi#723 failure.
tpm_confs=(
    "mkosi.images/base/mkosi.extra/usr/lib/dracut/dracut.conf.d/20-tpm-luks.conf"
    "shared/snow/tree/usr/lib/dracut/dracut.conf.d/20-tpm-luks.conf"
    "shared/floe/tree/usr/lib/dracut/dracut.conf.d/20-tpm-luks.conf"
    "shared/suite/forky/base-tree/usr/lib/dracut/dracut.conf.d/20-tpm-luks.conf"
    "shared/suite/forky/floe-tree/usr/lib/dracut/dracut.conf.d/20-tpm-luks.conf"
)
for conf in "${tpm_confs[@]}"; do
    path="$root/$conf"
    [[ -f "$path" ]] || { echo "missing TPM dracut conf: $conf" >&2; exit 1; }
    if grep -Eq 'add_dracutmodules\+=.*\btpm2-tss\b' "$path"; then
        grep -Eq 'add_dracutmodules\+=.*\btss-user\b' "$path" \
            || { echo "$conf enables tpm2-tss but not the tss-user module (snosi#723)" >&2; exit 1; }
    fi
done

# dracut 112 (forky) renamed the module systemd-pcrphase to systemd-pcrextend,
# after systemd 255 renamed the binary; dracut 106 (trixie) knows only
# systemd-pcrphase. A module name that dracut does not know fails the kernel
# postinst ("Module 'systemd-pcrphase' cannot be found", forky mechanics run
# 43527271965). Each forky copy must equal its trixie copy with that one name
# changed, and each trixie copy keeps the old name (ADR-0037).
forky_pairs=(
    "mkosi.images/base/mkosi.extra:shared/suite/forky/base-tree"
    "shared/floe/tree:shared/suite/forky/floe-tree"
)
rel=usr/lib/dracut/dracut.conf.d/20-tpm-luks.conf
for pair in "${forky_pairs[@]}"; do
    trixie="$root/${pair%%:*}/$rel"
    forky="$root/${pair#*:}/$rel"
    grep -Eq 'add_dracutmodules\+=.*\bsystemd-pcrphase\b' "$trixie" \
        || { echo "${pair%%:*}/$rel must name systemd-pcrphase (dracut 106 on trixie)" >&2; exit 1; }
    if grep -Eq '\bsystemd-pcrphase\b' "$forky"; then
        echo "${pair#*:}/$rel names systemd-pcrphase, which dracut 112 on forky does not know" >&2
        exit 1
    fi
    expected=$(sed 's/\bsystemd-pcrphase\b/systemd-pcrextend/' "$trixie")
    [[ $(cat "$forky") == "$expected" ]] \
        || { echo "${pair#*:}/$rel must equal ${pair%%:*}/$rel with systemd-pcrphase renamed to systemd-pcrextend" >&2; exit 1; }
done

echo "tss-user initrd static contract OK"
