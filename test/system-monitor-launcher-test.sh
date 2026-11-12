#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static guard: the Snow system monitor launcher must name a shipped program.
#
# Logomenu's "System Monitor" item runs /usr/libexec/missioncenter-helper (the
# default of its menu-button-system-monitor key). Snow and Snowfield ship the
# Debian gnome-system-monitor package; the Mission Center Flatpak left the
# core Flatpak sets. This test fails when:
#  - shared/packages/snow/mkosi.conf does not install gnome-system-monitor,
#    or a RemovePackages= setting names it;
#  - the helper does not exec /usr/bin/gnome-system-monitor, or calls flatpak;
#  - a tracked file outside docs/, .memory/, test/ and *.md names
#    io.missioncenter.MissionCenter (a Flatpak list, a folder or favourite
#    entry, a launcher).
#
# No root, no network, no image build.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packages="$root/shared/packages/snow/mkosi.conf"
helper="$root/shared/snow/tree/usr/libexec/missioncenter-helper"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# Print each package of each Packages= or RemovePackages= setting (first and
# continuation lines) as "<setting> <package>". Comments end a setting.
settings() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[A-Za-z]+=/ {
            split($0, kv, "=")
            key = kv[1]
            sub(/^[A-Za-z]+=/, "")
        }
        /^[[:space:]]*$/ { key = ""; next }
        key != "" { for (i = 1; i <= NF; i++) print key, $i }
    ' "$1"
}

# Read the settings once: grep -q in a pipe can end awk early (SIGPIPE), and
# pipefail would turn that into a false failure.
listed=$(settings "$packages")

if grep -qx 'Packages gnome-system-monitor' <<<"$listed"; then
    pass "snow package list installs gnome-system-monitor"
else
    fail "snow package list installs gnome-system-monitor"
fi

if grep -qx 'RemovePackages gnome-system-monitor' <<<"$listed"; then
    fail "no RemovePackages= setting names gnome-system-monitor"
else
    pass "no RemovePackages= setting names gnome-system-monitor"
fi

if [[ -x "$helper" ]] && grep -qx 'exec /usr/bin/gnome-system-monitor "\$@"' "$helper"; then
    pass "missioncenter-helper execs /usr/bin/gnome-system-monitor"
else
    fail "missioncenter-helper execs /usr/bin/gnome-system-monitor"
fi

if grep -v '^[[:space:]]*#' "$helper" | grep -q 'flatpak'; then
    fail "missioncenter-helper does not call flatpak"
else
    pass "missioncenter-helper does not call flatpak"
fi

mapfile -t named < <(
    git -C "$root" ls-files -z |
        tr '\0' '\n' |
        grep -Ev '^(docs/|\.memory/|test/)|\.md$' |
        while IFS= read -r path; do
            [[ -f "$root/$path" ]] || continue
            if grep -q 'io\.missioncenter\.MissionCenter' "$root/$path"; then
                printf '%s\n' "$path"
            fi
        done
)
if ((${#named[@]} == 0)); then
    pass "no shipped file names io.missioncenter.MissionCenter"
else
    fail "no shipped file names io.missioncenter.MissionCenter: ${named[*]}"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
