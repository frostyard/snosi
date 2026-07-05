#!/bin/bash
# Hard CI gate: shipped runtime payloads must never delete paths from /etc
# on an installed system.
#
# Why: on bootc/composefs installs, bootc-finalize-staged merges the live
# /etc into the new deployment at shutdown. Any path REMOVED from the live
# /etc relative to the booted image makes that merge fail (bootc <= 1.16.3:
# "error: Merging: a path led outside of the filesystem"), and the staged
# update is silently discarded — the machine keeps booting the old image
# forever while the updater reports success. The classic trigger is a unit
# running `systemctl disable` on itself at runtime, which deletes its
# .wants symlink from /etc (see the enable-incus-agent.service incident,
# 2026-07-05). Run-once semantics must use a /var marker file instead:
# `ConditionPathExists=!/var/lib/<unit>.done` + `ExecStartPost=touch ...`.
# See CLAUDE.md "Runtime service enablement changes are forbidden".
#
# What it scans: every git-tracked file inside an image payload directory
# (any `mkosi.extra/` dir or `shared/**/tree/` dir) — these files ship
# verbatim into images and everything executable in them runs at RUNTIME.
# Build-time scripts (*.chroot, mkosi.postinst, mkosi.finalize, ...) live
# outside payload dirs and are intentionally not scanned: `systemctl
# enable` at build time is the correct way to set enablement state.
#
# Escape hatch: append `# etc-guard-allow: <reason>` to a flagged line if
# it is provably safe (e.g. it only touches paths created at runtime that
# never shipped in the image /etc).
set -euo pipefail

cd "$(dirname "$0")"

fail=0

flag() { # file lineno line reason
    printf '%s:%s: %s\n    %s\n' "$1" "$2" "$4" "$3"
    fail=1
}

# systemctl verbs that create/delete enablement state under /etc, plus
# deb-systemd-helper (dpkg's equivalent). `enable` only creates symlinks —
# safe for the /etc merge itself — but enablement state must be
# image-defined (presets / build-time enable), so it is banned alongside
# the deleting verbs (disable, revert, unmask, preset).
unit_state_re='(systemctl|deb-systemd-helper)([[:space:]]+--?[[:alnum:]=/-]+)*[[:space:]]+(disable|enable|revert|unmask|preset|preset-all)\b'

# Filesystem deletion/rename aimed at /etc.
rm_etc_re='\b(rm|rmdir|unlink)\b[^#]*[[:space:]=]/etc/'
mv_etc_re='\bmv\b[[:space:]]+(-[[:alnum:]-]+[[:space:]]+)*/etc/'
find_etc_re='\bfind\b[^#]*[[:space:]]/etc[^#]*-delete'

while IFS= read -r -d '' f; do
    case "$f" in
        */mkosi.extra/*|mkosi.extra/*|shared/*/tree/*) ;;
        *) continue ;;
    esac
    [ -f "$f" ] || continue

    n=0
    while IFS= read -r line; do
        n=$((n + 1))
        # Skip comments (shell scripts and unit files) and explicit opt-outs.
        case "$line" in
            *etc-guard-allow*) continue ;;
        esac
        stripped="${line#"${line%%[![:space:]]*}"}"
        case "$stripped" in
            '#'*|';'*) continue ;;
        esac

        if [[ $line =~ $unit_state_re ]]; then
            flag "$f" "$n" "$line" \
                "runtime systemctl enable/disable mutates /etc; use a preset (enable) or a /var marker file (run-once)"
        fi
        if [[ $line =~ $rm_etc_re || $line =~ $mv_etc_re || $line =~ $find_etc_re ]]; then
            flag "$f" "$n" "$line" \
                "runtime deletion/rename under /etc breaks the bootc /etc merge at update finalize"
        fi

        # tmpfiles.d removal types targeting /etc (r/R remove, D empties).
        case "$f" in
            *tmpfiles.d/*)
                if [[ $line =~ ^[[:space:]]*[rRD]!?[-+=~^]*[[:space:]]+/etc ]]; then
                    flag "$f" "$n" "$line" \
                        "tmpfiles removal type targeting /etc runs at every boot and breaks the bootc /etc merge"
                fi
                ;;
        esac
    done < "$f"
done < <(git ls-files -z)

if [ "$fail" -ne 0 ]; then
    echo
    echo "Runtime /etc mutation check FAILED — see CLAUDE.md 'Runtime service" >&2
    echo "enablement changes are forbidden' for rationale and the marker-file pattern." >&2
fi
exit "$fail"
