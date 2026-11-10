#!/bin/bash
# Hard CI gate: no tracked path may contain usr/lib/user-tmpfiles.d/.
#
# Why: systemd-tmpfiles --user never reads /usr/lib/user-tmpfiles.d; user
# scope reads only XDG config and data directories such as
# /usr/share/user-tmpfiles.d. The container-policy rule at the unread path
# never ran. It must not simply move to /usr/share/user-tmpfiles.d: a
# per-user policy would hide /etc/containers/policy.json, losing Frostyard
# signature checks on manual pulls and later system-policy changes.
# See https://github.com/frostyard/snosi/issues/1265 and tmpfiles.d(5):
# https://www.freedesktop.org/software/systemd/man/262/tmpfiles.d.html
#
# What it scans: every git-tracked path, not only image payload directories.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard_root=${SNOSI_USER_TMPFILES_GUARD_ROOT:-$script_dir}
cd "$guard_root"

fail=0

while IFS= read -r -d '' f; do
    case "$f" in
        usr/lib/user-tmpfiles.d/*|*/usr/lib/user-tmpfiles.d/*)
            printf '%s: systemd-tmpfiles --user never reads /usr/lib/user-tmpfiles.d; user scope reads only XDG config and data dirs such as /usr/share/user-tmpfiles.d; snosi#1265\n' "$f"
            fail=1
            ;;
    esac
done < <(git ls-files -z)

if [ "$fail" -ne 0 ]; then
    echo
    echo "check-user-tmpfiles-guard: violations found. See https://github.com/frostyard/snosi/issues/1265."
    exit 1
fi
echo "check-user-tmpfiles-guard: OK"
