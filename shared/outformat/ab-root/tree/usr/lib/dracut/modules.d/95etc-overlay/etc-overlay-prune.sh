#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# snosi_prune_stale_requires UPPER SYSROOT
#
# Remove `.requires` enablement symlinks from the persistent /etc overlay
# upper when the required unit no longer exists anywhere the booting image
# can load it from. Sourced by etc-overlay-mount.sh in the initrd (dracut
# provides info()) and by test/etc-overlay-prune-test.sh (which stubs it).
#
# Why this must happen in the initrd, before the /etc overlay is assembled:
# PID 1's very first transaction starts default.target, and a Requires= on
# a unit that cannot be loaded makes that whole transaction invalid — the
# boot dies at "Failed to isolate default target" before any service (so
# any runtime cleanup) can run and before the journal can persist. First
# boot's preset pass writes RequiredBy= [Install] links into the persistent
# upper, so retiring such a unit from the image bricks every install whose
# first boot enabled it. Root-caused live 2026-08-12: e08311f retired
# snow-linux-live-setup.service (RequiredBy=multi-user.target and
# display-manager.service) and image 20260812205454 failed all three
# counted boots on an enrolled snow-ab machine, falling back to the
# previous slot. See docs/adr/0013.
#
# Scope is deliberately `.requires` ONLY — never widen this to `.wants`:
# - A dangling Wants is harmless to the transaction, and sysext-provided
#   units are legitimately absent from the pristine root at this point in
#   boot; pruning wants would silently disable every enabled sysext
#   service on every boot.
# - Any `.requires` link this prunes names a unit absent from the image
#   /usr, the image /etc lower, AND the persistent upper. If PID 1's
#   initial transaction reached it the boot was already lost, so pruning
#   strictly converts a bricked boot into a booting system minus a
#   dependency that could not have been satisfied anyway.
#
# systemd resolves *.requires/ links by SYMLINK NAME through the unit
# search path (the link target is only convention), so existence is checked
# by unit name, with template instances falling back to their template
# file. A name present only as a symlink (alias or mask) counts as
# existing: overriding an admin's mask is not this function's business.

snosi_prune_stale_requires() {
    _upper="$1"
    _root="$2"
    for _lnk in "$_upper"/systemd/system/*.requires/*; do
        [ -L "$_lnk" ] || continue
        _unit="${_lnk##*/}"
        case "$_unit" in
        *@*.*) _tmpl="${_unit%%@*}@.${_unit##*.}" ;;
        *) _tmpl="$_unit" ;;
        esac
        _found=
        for _dir in \
            "$_root/usr/lib/systemd/system" \
            "$_root/usr/local/lib/systemd/system" \
            "$_root/.etc.lower/systemd/system" \
            "$_upper/systemd/system"; do
            if [ -e "$_dir/$_unit" ] || [ -L "$_dir/$_unit" ] ||
                [ -e "$_dir/$_tmpl" ] || [ -L "$_dir/$_tmpl" ]; then
                _found=1
                break
            fi
        done
        [ -n "$_found" ] && continue
        info "snosi-etc-overlay: pruning stale hard dependency ${_lnk#"$_upper"}: $_unit is not shipped by this image"
        # Best-effort visibility for the booted system (drift inspection);
        # /run/snosi is the org-standard runtime state dir (core ADR-0004).
        # The whole block is silenced: the redirection itself fails when
        # unprivileged (the fixture test), and that error precedes any
        # per-command stderr redirect.
        { mkdir -p /run/snosi &&
            printf '%s\n' "${_lnk#"$_upper"}" >>/run/snosi/etc-requires-pruned; } 2>/dev/null || :
        rm -f "$_lnk"
    done
}
