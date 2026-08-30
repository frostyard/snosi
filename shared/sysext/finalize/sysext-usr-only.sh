#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Reject sysext payload outside /usr.
#
# mkosi's sysext output copies exactly two trees from the buildroot into the
# published erofs: CopyFiles=/usr/ and CopyFiles=/opt/ (mkosi
# resources/repart/definitions/sysext.repart.d/10-root.conf). Everything else
# in the buildroot -- /var, /etc, /home, ... -- is build residue that never
# ships, so this guard does not inspect it: dpkg logs, package caches, and
# postinst-generated state under /var are inert here. /opt IS shipped, and
# at runtime it is a bind mount to /var/opt that sysext overlays shadow
# (see CLAUDE.md "Immutable Filesystem Constraints"), so any /opt payload is
# a contract violation: relocate it to /usr/lib/<package> with /usr/bin
# symlinks. The empty /opt mountpoint directory itself is permitted.
set -euo pipefail

if [[ ! -d "${BUILDROOT:-}" ]]; then
    echo "sysext-usr-only: BUILDROOT is not a directory" >&2
    exit 1
fi

if [[ -z "${IMAGE_ID:-}" ]]; then
    echo "sysext-usr-only: IMAGE_ID is not set" >&2
    exit 1
fi

payload_root="$BUILDROOT/opt"
offending_path=

if [[ -L "$payload_root" || (-e "$payload_root" && ! -d "$payload_root") ]]; then
    # /opt itself is a symlink or a file: both ship and both break the
    # runtime bind mount. -L is checked first so a symlink is never followed.
    offending_path="/opt"
elif [[ -d "$payload_root" ]]; then
    # -P: never follow symlinks, so a link pointing outside the buildroot is
    # reported by its own path and its target is never inspected.
    first_entry=$(find -P "$payload_root" -mindepth 1 -print -quit)
    if [[ -n "$first_entry" ]]; then
        offending_path="/opt${first_entry#"$payload_root"}"
    fi
fi

if [[ -n "$offending_path" ]]; then
    echo "sysext-usr-only: $IMAGE_ID contains payload outside /usr:" >&2
    echo "  $offending_path" >&2
    echo "Sysext payloads must be /usr-only: mkosi ships /opt in the sysext," \
         "and /opt is shadowed at runtime. Relocate it to /usr/lib/<package>" \
         "with symlinks in /usr/bin, or remove it." >&2
    exit 1
fi

echo "sysext-usr-only: $IMAGE_ID payload is confined to /usr"
