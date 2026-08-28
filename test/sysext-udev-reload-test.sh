#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture suite for the post-merge udev/module contract.
#
# The bug this pins: systemd-sysext.service carries only
# `Before=sysinit.target` and NO ordering against systemd-udevd.service, and
# udev wins in practice, so udev parses its rules BEFORE a sysext's
# /usr/lib/udev/rules.d/ entries exist and never looks again. voxtype shipped
# 80-uinput.rules that was consequently never applied on any boot:
# /dev/uinput stayed root:root 0600, ydotoold died "failed to open uinput
# device: Permission denied", and dictation transcribed but typed nothing.
#
# Covers:
#  - shared/sysext/tree/usr/lib/snosi/sysext-udev-reload behavior: the
#    load-bearing command ORDER (rules reload strictly before the modprobe
#    that creates the device), fail-closed on reload/modules-load failure,
#    and tolerance of an advisory `udevadm settle` timeout
#  - static wiring parity: every sysext whose required-paths.txt claims a
#    udev rule or a modules-load entry must also wire the shared payload and
#    the Upholds= activation drop-in, and vice versa (either half alone is
#    the same silent no-op the fix exists to end)
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/shared/sysext/tree/usr/lib/snosi/sysext-udev-reload"
unit="$root/shared/sysext/tree/usr/lib/systemd/system/snosi-sysext-udev-reload.service"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

test_number=0
failures=0

ok() {
    test_number=$((test_number + 1))
    echo "ok $test_number - $1"
}

fail() {
    test_number=$((test_number + 1))
    failures=$((failures + 1))
    echo "not ok $test_number - $1"
    [[ -n ${2:-} ]] && sed "s/^/#   /" <<<"$2"
    return 0
}

# Build a PATH-shadowing udevadm stub that appends each invocation to a log.
# udevadm_rc controls the exit status of `udevadm settle` only.
make_stubs() { # name settle_rc modules_load_rc -> bindir
    local bin="$work/$1/bin"
    mkdir -p "$bin"
    cat >"$bin/udevadm" <<EOF
#!/bin/bash
printf 'udevadm %s\n' "\$*" >>"$work/$1/calls"
[[ \$1 == settle ]] && exit $2
exit 0
EOF
    cat >"$bin/modules-load-stub" <<EOF
#!/bin/bash
printf 'modules-load\n' >>"$work/$1/calls"
exit $3
EOF
    chmod +x "$bin/udevadm" "$bin/modules-load-stub"
    : >"$work/$1/calls"
    echo "$bin"
}

run_script() { # name settle_rc modules_load_rc -> sets rc, out; writes calls
    local bin
    bin=$(make_stubs "$1" "$2" "$3")
    set +e
    out=$(PATH="$bin:$PATH" SNOSI_MODULES_LOAD="$bin/modules-load-stub" \
        bash "$script" 2>&1)
    rc=$?
    set -e
    calls=$(cat "$work/$1/calls")
}

# --- case 1: happy path runs every step ------------------------------------
run_script happy 0 0
if ((rc == 0)); then
    ok "happy path exits 0"
else
    fail "happy path exits 0" "rc=$rc
$out"
fi

expected='udevadm control --reload
udevadm settle --timeout=30
modules-load
udevadm trigger --action=add --subsystem-match=misc
udevadm settle --timeout=30'
if [[ $calls == "$expected" ]]; then
    ok "runs reload -> settle -> modules-load -> trigger -> settle, in order"
else
    fail "runs reload -> settle -> modules-load -> trigger -> settle, in order" \
        "got:
$calls
want:
$expected"
fi

# The ordering above is the whole fix: a modprobe that lands BEFORE the rules
# reload creates the device while udev still has the pre-merge ruleset, which
# is exactly the boot-time race being worked around. Pin it explicitly so a
# future reshuffle cannot silently reintroduce it.
reload_line=$(grep -n '^udevadm control --reload$' <<<"$calls" | cut -d: -f1)
modprobe_line=$(grep -n '^modules-load$' <<<"$calls" | cut -d: -f1)
if ((reload_line < modprobe_line)); then
    ok "rules reload precedes the module load that creates the device"
else
    fail "rules reload precedes the module load that creates the device" "$calls"
fi

# --- case 2: settle timeout is advisory, not fatal --------------------------
run_script settle_timeout 1 0
if ((rc == 0)) && grep -q 'settle timed out' <<<"$out"; then
    ok "udevadm settle timeout warns and continues"
else
    fail "udevadm settle timeout warns and continues" "rc=$rc
$out"
fi
if grep -qx 'modules-load' <<<"$calls"; then
    ok "settle timeout does not skip the module load"
else
    fail "settle timeout does not skip the module load" "$calls"
fi

# --- case 3: a module that will not load is fail-closed ---------------------
run_script modprobe_fail 0 1
if ((rc != 0)); then
    ok "modules-load failure fails the unit (never a silent no-typing boot)"
else
    fail "modules-load failure fails the unit (never a silent no-typing boot)" "$out"
fi

# --- case 4: udevadm control --reload failure is fail-closed ----------------
bin=$(make_stubs reload_fail 0 0)
cat >"$bin/udevadm" <<EOF
#!/bin/bash
printf 'udevadm %s\n' "\$*" >>"$work/reload_fail/calls"
[[ \$1 == control ]] && exit 1
exit 0
EOF
chmod +x "$bin/udevadm"
set +e
out=$(PATH="$bin:$PATH" SNOSI_MODULES_LOAD="$bin/modules-load-stub" \
    bash "$script" 2>&1)
rc=$?
set -e
if ((rc != 0)) && ! grep -qx 'modules-load' "$work/reload_fail/calls"; then
    ok "reload failure aborts before creating devices under a stale ruleset"
else
    fail "reload failure aborts before creating devices under a stale ruleset" \
        "rc=$rc
$(cat "$work/reload_fail/calls")"
fi

# --- case 5: the unit is ordered ahead of any user session -----------------
if grep -qx 'Before=multi-user.target' "$unit"; then
    ok "unit is ordered before multi-user.target"
else
    fail "unit is ordered before multi-user.target" \
        "ydotool.service and friends run in the graphical session; the node
must already be fixed by then"
fi
if grep -q '^After=.*reload-sysext\.service' "$unit" &&
    grep -q '^After=.*systemd-udevd\.service' "$unit"; then
    ok "unit runs after the post-merge daemon-reload and after udevd"
else
    fail "unit runs after the post-merge daemon-reload and after udevd" \
        "$(grep '^After=' "$unit" || echo '(no After=)')"
fi
# A preset would be silently dropped at PID 1 scan time (the unit is still
# inside an unmerged overlay), which is the whole reason for the Upholds
# pattern -- so the unit must NOT carry an [Install] section of its own.
if ! grep -q '^\[Install\]' "$unit"; then
    ok "unit has no [Install] section (activation is Upholds=, not a preset)"
else
    fail "unit has no [Install] section (activation is Upholds=, not a preset)" \
        "$(cat "$unit")"
fi

# --- case 6: static wiring parity across every tracked sysext ---------------
# Consumers are DERIVED, not allowlisted: a sysext that claims a udev rule or
# a modules-load entry in required-paths.txt needs the post-merge reload, and
# nothing else does.
tree_wiring='ExtraTrees=%D/shared/sysext/tree'
shared_paths=(
    /usr/lib/snosi/sysext-udev-reload
    /usr/lib/systemd/system/snosi-sysext-udev-reload.service
)
parity_failures=0
consumers=()
mapfile -t configs < <(
    git -C "$root" ls-files -- 'mkosi.images/*/mkosi.conf' |
        while IFS= read -r c; do
            grep -Eq '^[[:space:]]*Overlay[[:space:]]*=[[:space:]]*yes[[:space:]]*$' \
                "$root/$c" && printf '%s\n' "$c"
        done
)
((${#configs[@]} > 0)) || fail "found tracked Overlay=yes sysext configs" "none"

for config in "${configs[@]}"; do
    name=${config#mkosi.images/}
    name=${name%/mkosi.conf}
    paths="$root/mkosi.images/$name/required-paths.txt"
    [[ -f $paths ]] || continue

    needs=no
    grep -Eq '^[[:space:]]*/usr/lib/(udev/rules\.d|modules-load\.d)/' "$paths" &&
        needs=yes
    wired=no
    grep -Fq "$tree_wiring" "$root/$config" && wired=yes
    dropin="$root/mkosi.images/$name/mkosi.extra/usr/lib/systemd/system/multi-user.target.d/10-$name.conf"

    if [[ $needs == yes ]]; then
        consumers+=("$name")
        [[ $wired == yes ]] || {
            fail "$name: claims udev rules/modules-load but is missing $tree_wiring"
            parity_failures=$((parity_failures + 1))
        }
        if [[ -f $dropin ]] &&
            grep -q 'Upholds=.*snosi-sysext-udev-reload\.service' "$dropin"; then
            :
        else
            fail "$name: missing Upholds=snosi-sysext-udev-reload.service in 10-$name.conf"
            parity_failures=$((parity_failures + 1))
        fi
        for p in "${shared_paths[@]}"; do
            grep -qx "$p" "$paths" || {
                fail "$name: required-paths.txt must list $p"
                parity_failures=$((parity_failures + 1))
            }
        done
    elif [[ $wired == yes ]]; then
        fail "$name: wires $tree_wiring but claims no udev rule or modules-load entry"
        parity_failures=$((parity_failures + 1))
    fi
done

if ((parity_failures == 0)); then
    ok "udev-reload wiring parity holds for all ${#configs[@]} sysexts (consumers: ${consumers[*]:-none})"
fi
# The derived set is necessary but not sufficient: a sysext may ship udev
# rules from a deb without naming one in required-paths.txt. Keep at least
# the two known consumers in the set so an accidental required-paths edit
# cannot quietly empty the check.
for expected in voxtype sunshine; do
    if printf '%s\n' "${consumers[@]}" | grep -qx "$expected"; then
        ok "$expected is detected as a udev-reload consumer"
    else
        fail "$expected is detected as a udev-reload consumer" \
            "required-paths.txt no longer claims a udev rule or modules-load entry"
    fi
done

echo "1..$test_number"
((failures == 0)) || exit 1
