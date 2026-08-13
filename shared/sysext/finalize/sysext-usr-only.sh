#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared finalize script for sysext images: fail the build if the sysext delta
# ships any payload under /var or /opt.
#
# ADR-0004 rule 1 makes sysext payloads /usr-only: packages that install to
# /opt are relocated to /usr/lib/<pkg> in the image postinst chroot, and /var
# is per-machine runtime state that a read-only /usr overlay cannot own. Until
# now that rule was only convention plus mkosi's sysext format — nothing
# rejected a stray /var or /opt entry, so a new package or a botched
# /opt->/usr relocation could smuggle content outside /usr and no check would
# notice. Such content is silently dropped or shadowed at merge time (opt.mount
# binds /opt to /var/opt), so the sysext ships looking correct while the files
# never take effect. This makes that class of failure a build error, the same
# fail-closed posture as sysext-required-paths.sh.
#
# Payload here means any file, symlink, or other non-directory entry below
# /var or /opt (a non-empty directory is caught through the entries it holds).
# Empty directory structure is permitted: many Debian packages create an empty
# /var/lib/<pkg> state directory at install time, which carries no payload and
# is legitimately (re)created at runtime by tmpfiles.d — so directories alone
# are not a violation, matching the mountpoint-directory carve-out below.
set -euo pipefail

if [[ -z "${BUILDROOT:-}" || ! -d "$BUILDROOT" ]]; then
    echo "sysext-usr-only: BUILDROOT is not set to a directory" >&2
    exit 1
fi

# For Overlay=yes images $BUILDROOT is the sysext delta (upper layer), so this
# only inspects files this sysext build produced — never host paths, and it
# never follows symlinks out of the delta.
violations=()
for top in var opt; do
    dir="$BUILDROOT/$top"
    # A missing mountpoint is fine. The mountpoint directory itself is
    # permitted only as a real directory; a symlink or any non-directory
    # shipped AT /var or /opt is itself payload — find below would not
    # descend a command-line symlink, so reject it explicitly.
    if [[ -L "$dir" || ( -e "$dir" && ! -d "$dir" ) ]]; then
        violations+=("/$top")
        continue
    fi
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' entry; do
        violations+=("/${entry#"$BUILDROOT/"}")
    done < <(find "$dir" -mindepth 1 ! -type d -print0)
done

if (( ${#violations[@]} > 0 )); then
    echo "sysext-usr-only: ${IMAGE_ID:-unknown} ships payload outside /usr:" >&2
    printf '  %s\n' "${violations[@]}" >&2
    echo "Sysexts are /usr-only overlays (ADR-0004): relocate /opt payloads to /usr/lib/<pkg> in the postinst chroot, and never ship /var runtime state in an extension. Refusing to produce a sysext whose files would be dropped or shadowed at merge time." >&2
    exit 1
fi

echo "sysext-usr-only: ${IMAGE_ID:-unknown} ships no /var or /opt payload"
