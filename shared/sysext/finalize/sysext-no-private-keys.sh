#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Reject build-time private keys in a sysext payload. mkosi packs only /usr
# and /opt into the published erofs (see sysext-usr-only.sh), so only those
# trees are scanned; the shared guard documents the rules.
set -euo pipefail

NO_PRIVATE_KEYS_ROOTS="usr opt" exec "$SRCDIR/shared/security/no-private-keys.finalize"
