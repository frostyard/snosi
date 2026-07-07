#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared finalize script for sysext images: strip icon-theme.cache files from
# the sysext delta.
#
# A GTK icon cache is a singleton index of an ENTIRE theme directory. If a
# sysext package pulls in icons, the gtk-update-icon-cache dpkg trigger
# regenerates the cache inside the (merged) buildroot and the file lands in
# this sysext's upper layer — snapshotting base + this sysext's icons at
# build time. Merged on a host, that copy shadows the theme's cache for the
# whole /usr overlay and masks every icon it doesn't contain: other sysexts'
# icons and any base icons newer than this sysext build. The base image
# deliberately ships NO hicolor cache (see shared/outformat finalize) so GTK
# scans the theme directories; a cache smuggled in by any sysext would
# silently reintroduce the masking. No layer may ship one.
set -euo pipefail

# For Overlay=yes images $BUILDROOT is the sysext delta (upper layer), so
# this deletes only caches the sysext build itself created.
find "$BUILDROOT/usr/share/icons" -name icon-theme.cache -type f -print -delete 2>/dev/null || true

echo "sysext-strip-icon-cache: done for ${IMAGE_ID:-unknown}"
