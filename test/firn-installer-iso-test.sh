#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static Firn installer ISO sandbox and boot-entry contract. The old QEMU
# harness installed retired A/B products; it is not evidence for secure bootc
# installation.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ${1:-} != --static || $# -ne 1 ]]; then
    echo "BLOCKED: the former Firn ISO live harness installed retired A/B products. Secure bootc fresh-install proof belongs to Firn's lab matrix (core ADR-0031); run this script with --static for the ISO sandbox check." >&2
    exit 2
fi

grep -Fqx 'SandboxTrees=%D/shared/bootc-secure/package-manager' \
    "$root/shared/firn-installer/mkosi.conf" || {
    echo 'Firn ISO must use the bootc Forky sandbox' >&2
    exit 1
}

conf="$root/shared/firn-installer/mkosi.conf"
unpinned=$(grep -Fxc 'Packages=frostyard-firn' "$conf" || true)
any=$(grep -cE '^(Packages=|[[:space:]]+)frostyard-firn([[:space:]=/]|$)' "$conf" || true)
if [[ $unpinned -ne 1 || $any -ne 1 ]]; then
    echo 'Firn ISO must install exactly one unpinned Packages=frostyard-firn' >&2
    exit 1
fi

# Firn reads each image's org.frostyard.core-flatpaks label (firn
# ADR-0018); the retired ISO fallback gave every product Snow's set.
fallback=usr/share/firn/core-flatpaks.json
# grep -F >/dev/null, not -q: -q exits on the first match and, under
# pipefail, the upstream grep's SIGPIPE would make the match look false.
if grep -v '^[[:space:]]*#' "$conf" "$root/Justfile" | grep -F "$fallback" >/dev/null ||
    [[ -e "$root/shared/firn-installer/tree/$fallback" ]]; then
    echo "Firn ISO must not ship the retired /$fallback fallback" >&2
    exit 1
fi

# The graphical entry's frontend, unpinned like frostyard-firn
# (docs/adr/0022-installer-graphical-and-console-boot-entries.md).
gui_unpinned=$(grep -Fxc 'Packages=frostyard-firn-gui' "$conf" || true)
gui_any=$(grep -cE '^(Packages=|[[:space:]]+)frostyard-firn-gui([[:space:]=/]|$)' "$conf" || true)
if [[ $gui_unpinned -ne 1 || $gui_any -ne 1 ]]; then
    echo 'Firn ISO must install exactly one unpinned Packages=frostyard-firn-gui' >&2
    exit 1
fi

# GRUB offers both frontends; console is the default. Each entry selects its
# target with systemd.unit= and otherwise boots the same command line.
grub=$(sed -n "/^cat >\"\$WORK\/grub.cfg\" <<'EOF'\$/,/^EOF\$/p" \
    "$root/shared/firn-installer/tools/build-iso.sh")
entry_args() { # entry title -> its linux line, minus the target selector
    awk -v t="menuentry \"$1\"" 'index($0, t) == 1 {e = 1; next}
        e && /^}/ {exit} e && $1 == "linux" {print}' <<<"$grub"
}
graphical=$(entry_args 'Install snosi (graphical)')
console=$(entry_args 'Install snosi (console)')
if [[ $(grep -c '^menuentry ' <<<"$grub") -ne 2 ||
    $graphical != *' systemd.unit=firn-graphical.target' ||
    $console != *' systemd.unit=firn-console.target' ||
    ${graphical% systemd.unit=*} != "${console% systemd.unit=*}" ]]; then
    echo 'Firn ISO grub.cfg must have exactly the graphical and console entries, differing only in systemd.unit=' >&2
    exit 1
fi
if ! grep -qx 'set default=console' <<<"$grub" ||
    ! grep -qxE 'set timeout=[1-9][0-9]*' <<<"$grub"; then
    echo 'Firn ISO grub.cfg must show a timed menu that defaults to the console entry' >&2
    exit 1
fi

# Only firn-console.target starts the TUI on tty1 and only firn-graphical.target
# starts firn-gui; the serial TUI runs under both.
units="$root/shared/firn-installer/tree/usr/lib/systemd/system"
wants=$(cd "$units" && find . -path './*.wants/*' | sort)
for link in firn-console.target.wants/firn-kiosk.service \
    firn-graphical.target.wants/firn-gui.service \
    multi-user.target.wants/firn-kiosk-serial@ttyS0.service; do
    [[ -L "$units/$link" ]] || {
        echo "Firn ISO must enable $link" >&2
        exit 1
    }
done
if [[ $(grep -cE '/(firn-kiosk|firn-gui)\.service$' <<<"$wants") -ne 2 ]]; then
    echo 'Firn ISO must want the tty1 frontends only from their boot-entry targets' >&2
    exit 1
fi
grep -Fqx 'ln -sf /usr/lib/systemd/system/firn-console.target /etc/systemd/system/default.target' \
    "$root/shared/firn-installer/postinst/mkosi.postinst.chroot" || {
    echo 'Firn ISO default.target must be firn-console.target' >&2
    exit 1
}

# firn-gui.service hands tty1 to the TUI on every exit path. It must carry no
# Condition*: Conflicts= stops getty before Conditions are evaluated.
gui_unit="$units/firn-gui.service"
for line in OnFailure=firn-kiosk.service OnSuccess=firn-kiosk.service \
    RestartPreventExitStatus=77 ExecStart=/usr/lib/firn/firn-gui-session; do
    grep -Fqx "$line" "$gui_unit" || {
        echo "firn-gui.service must set $line" >&2
        exit 1
    }
done
if grep -qE '^Condition' "$gui_unit" ||
    ! grep -qx '        exit 77' "$root/shared/firn-installer/tree/usr/lib/firn/firn-gui-session"; then
    echo 'firn-gui.service must not be conditional; firn-gui-session exits 77 without a display' >&2
    exit 1
fi

echo 'Firn ISO static sandbox and boot-entry contract passed'
