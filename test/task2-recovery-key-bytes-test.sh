#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Regression for Task 2's file-versus-interactive LUKS recovery key bytes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
key_text='task-2-disposable-recovery-key'
work=$(mktemp -d)
mapper="task2-key-bytes-${BASHPID}"
trap 'cryptsetup close "$mapper" 2>/dev/null || true; rm -rf "$work"' EXIT

# Task 2 must create an exact passphrase, not a line-oriented key file.
if ! grep -Fq "printf '%s' 'task-2-disposable-recovery-key'" "$ROOT_DIR/test/bootc-secure-spike-test.sh"; then
    echo "FAIL: Task 2 recovery-key producer is not exact-byte printf '%s'" >&2
    exit 1
fi

printf '%s' "$key_text" >"$work/recovery.key"
chmod 600 "$work/recovery.key"
truncate -s 32M "$work/luks.raw"
cryptsetup luksFormat --type luks2 --batch-mode --key-file "$work/recovery.key" "$work/luks.raw"

cryptsetup open --test-passphrase --key-file "$work/recovery.key" "$work/luks.raw"
printf '%s' "$key_text" | cryptsetup open --test-passphrase --key-file - "$work/luks.raw"
if printf '%s\n' "$key_text" | cryptsetup open --test-passphrase --key-file - "$work/luks.raw"; then
    echo "FAIL: newline-terminated interactive-equivalent key unexpectedly unlocked LUKS" >&2
    exit 1
fi

echo "PASS: exact recovery bytes unlock via file and interactive input; newline bytes are rejected"
