#!/bin/bash
# Hard CI gate: no tracked path may be at or under usr/lib/user-tmpfiles.d,
# and no tracked user-tmpfiles.d rule may name .config/containers.
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
# What it scans: every git-tracked path, not only image payload directories,
# and file contents under any user-tmpfiles.d directory. This does not inspect
# ExtraTrees= target mappings, build-script output, or package payloads.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard_root=${SNOSI_USER_TMPFILES_GUARD_ROOT:-$script_dir}
if ! cd "$guard_root"; then
    echo "check-user-tmpfiles-guard: cannot enter guard root: $guard_root" >&2
    exit 2
fi
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "check-user-tmpfiles-guard: guard root is not a Git work tree: $guard_root" >&2
    exit 2
fi

tracked_paths=$(mktemp)
trap 'rm -f "$tracked_paths"' EXIT
if ! git ls-files -z >"$tracked_paths"; then
    echo "check-user-tmpfiles-guard: cannot list tracked paths" >&2
    exit 2
fi

fail=0
checked=0

while IFS= read -r -d '' f; do
    checked=$((checked + 1))
    case "$f" in
        usr/lib/user-tmpfiles.d|*/usr/lib/user-tmpfiles.d|usr/lib/user-tmpfiles.d/*|*/usr/lib/user-tmpfiles.d/*)
            printf '%s: systemd-tmpfiles --user never reads /usr/lib/user-tmpfiles.d; user scope reads only XDG config and data dirs such as /usr/share/user-tmpfiles.d; snosi#1265\n' "$f"
            fail=1
            ;;
    esac
    case "$f" in
        user-tmpfiles.d/*|*/user-tmpfiles.d/*)
            if [[ -f "$f" ]] && grep -Fq -- '.config/containers' "$f"; then
                printf '%s: user tmpfiles rule names .config/containers; a per-user container policy hides /etc/containers/policy.json, losing Frostyard signature checks and later system-policy changes; snosi#1265\n' "$f"
                fail=1
            fi
            ;;
    esac
done <"$tracked_paths"

if [ "$fail" -ne 0 ]; then
    echo
    echo "check-user-tmpfiles-guard: violations found. See https://github.com/frostyard/snosi/issues/1265."
    exit 1
fi
echo "check-user-tmpfiles-guard: OK ($checked tracked paths checked)"
