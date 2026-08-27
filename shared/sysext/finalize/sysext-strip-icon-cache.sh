#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared finalize script for sysext images: strip shadow-the-singleton caches
# (icon-theme.cache, gschemas.compiled) from the sysext delta.
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
#
# /usr/share/glib-2.0/schemas/gschemas.compiled has the same shape: GSettings
# reads ONE compiled cache per schema directory, so a sysext-shipped copy
# shadows the base image's complete cache for the whole merged /usr. When an
# app deb drops schema XML into the buildroot and glib-compile-schemas is
# present there (it is in gui-base via libglib2.0-bin), libglib2.0-0t64's
# dpkg trigger compiles a cache from the BUILD BASE's schema set into this
# sysext's upper layer. Merged on a host it masks every schema the build base
# lacked (org.gnome.SessionManager, org.gnome.shell, org.gnome.mutter, the
# snow zz0-* overrides, ...) and gnome-session aborts with "Settings schema
# 'org.gnome.SessionManager' is not installed" — GDM crash-loops to a bare
# cursor (root-caused 2026-08-26 on claude-desktop 1.37937.1 + chatgpt
# 26.820.60940, the first builds after #784 moved them onto gui-base). The
# base image always ships a full, freshly compiled cache (shared/outformat
# image finalize), and sysext-shipped schema XML never takes effect anyway
# (docs/design/sysexts.md), so stripping loses nothing.
set -euo pipefail

# For Overlay=yes images $BUILDROOT is the sysext delta (upper layer), so
# this deletes only caches the sysext build itself created.
find "$BUILDROOT/usr/share/icons" -name icon-theme.cache -type f -print -delete 2>/dev/null || true
find "$BUILDROOT/usr/share/glib-2.0/schemas" -name gschemas.compiled -type f -print -delete 2>/dev/null || true

echo "sysext-strip-icon-cache: done for ${IMAGE_ID:-unknown}"
