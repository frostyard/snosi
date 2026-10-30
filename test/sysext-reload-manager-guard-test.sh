#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture suite for shared/sysext/finalize/sysext-reload-manager-guard.sh
# (snosi#1189): a sysext delta that ships anything under
# usr/lib/systemd/system must ship usr/lib/extension-release.d/
# extension-release.<ImageId> with the line EXTENSION_RELOAD_MANAGER=1, or
# PID 1 does not load its units until a reboot. A repository check applies the
# same rule to the mkosi.extra trees. See docs/design/sysexts.md "Service
# Activation Pattern (Upholds=)" and ADR-0026.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$root/shared/sysext/finalize/sysext-reload-manager-guard.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

UNITS=usr/lib/systemd/system
REL=usr/lib/extension-release.d/extension-release.testext
test_number=0
failures=0
delta=""

new_case() { # name -> fresh delta/ tree
    delta="$work/$1/delta"
    mkdir -p "$delta/usr/lib"
}

put() { # tree-root relative-path content...
    local f="$1/$2"
    shift 2
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$@" >"$f"
}

run_guard() { # -> sets out, status
    if out=$(BUILDROOT="$delta" IMAGE_ID=testext "$guard" 2>&1); then
        status=0
    else
        status=$?
    fi
}

check() { # name expected_status [expected_output ...]
    local name=$1 want_status=$2 want ok=1
    shift 2
    for want in "$@"; do
        [[ $out == *"$want"* ]] || ok=0
    done
    test_number=$((test_number + 1))
    if ((status == want_status && ok == 1)); then
        printf 'ok %d - %s\n' "$test_number" "$name"
    else
        printf 'not ok %d - %s\n' "$test_number" "$name"
        printf '# expected status %d, got %d\n' "$want_status" "$status"
        printf '# expected output to contain: %s\n' "$*"
        while IFS= read -r line; do printf '#   %s\n' "$line"; done <<<"$out"
        failures=$((failures + 1))
    fi
}

unit() { put "$delta" "$UNITS/app.service" '[Service]' 'ExecStart=/bin/true'; }

new_case no-units
put "$delta" usr/bin/tool '#!/bin/sh'
run_guard
check "no system units and no release file passes" 0 "testext OK (no system units"

new_case empty-units-dir
mkdir -p "$delta/$UNITS"
run_guard
check "empty system unit directory passes" 0 "OK (no system units"

new_case unit-and-key
unit
put "$delta" "$REL" '# comment' 'EXTENSION_RELOAD_MANAGER=1'
run_guard
check "unit with the key passes" 0 "testext OK (1 system unit entries, EXTENSION_RELOAD_MANAGER=1)"

new_case user-units
put "$delta" usr/lib/systemd/user/app.service '[Service]' 'ExecStart=/bin/true'
run_guard
check "only user units pass without a release file" 0 "OK (no system units"

new_case unit-no-file
unit
run_guard
check "unit without a release file fails" 1 "no /$REL" "snosi#1189"

new_case file-no-key
unit
put "$delta" "$REL" 'ID=testext'
run_guard
check "release file without the key fails" 1 "no line EXTENSION_RELOAD_MANAGER=1"

new_case key-zero
unit
put "$delta" "$REL" 'EXTENSION_RELOAD_MANAGER=0'
run_guard
check "EXTENSION_RELOAD_MANAGER=0 fails" 1 "no line EXTENSION_RELOAD_MANAGER=1"

new_case key-commented
unit
put "$delta" "$REL" '# EXTENSION_RELOAD_MANAGER=1'
run_guard
check "commented key fails" 1 "no line EXTENSION_RELOAD_MANAGER=1"

new_case key-other-image
unit
put "$delta" usr/lib/extension-release.d/extension-release.other 'EXTENSION_RELOAD_MANAGER=1'
run_guard
check "key in another image's release file fails" 1 "no /$REL"

new_case dropin-only
put "$delta" "$UNITS/multi-user.target.d/10-x.conf" '[Unit]' 'Upholds=app.service'
run_guard
check "drop-in only without a release file fails" 1 "no /$REL"

new_case dropin-and-key
put "$delta" "$UNITS/multi-user.target.d/10-x.conf" '[Unit]' 'Upholds=app.service'
put "$delta" "$REL" 'EXTENSION_RELOAD_MANAGER=1'
run_guard
check "drop-in with the key passes" 0 "OK (1 system unit entries"

# --- repository check -------------------------------------------------------
# Every tracked sysext whose mkosi.extra ships a system unit entry must ship the
# release file with the key. Package units (podman, code-server) are covered by
# the build-time guard; the tracked files here are the ones visible in git.
checked=0
bad=0
shopt -s nullglob dotglob
for units_dir in "$root"/mkosi.images/*/mkosi.extra/usr/lib/systemd/system; do
    entries=("$units_dir"/*)
    ((${#entries[@]} > 0)) || continue
    name=${units_dir#"$root"/mkosi.images/}
    name=${name%%/*}
    [[ $name != base ]] || continue
    checked=$((checked + 1))
    rel="$root/mkosi.images/$name/mkosi.extra/usr/lib/extension-release.d/extension-release.$name"
    if [[ ! -f $rel ]] || ! grep -qx 'EXTENSION_RELOAD_MANAGER=1' "$rel"; then
        echo "# $name ships system units but no extension-release.$name with EXTENSION_RELOAD_MANAGER=1"
        bad=$((bad + 1))
    fi
done
test_number=$((test_number + 1))
if ((checked > 0 && bad == 0)); then
    echo "ok $test_number - $checked sysexts with mkosi.extra system units ship the key"
else
    echo "not ok $test_number - every sysext with mkosi.extra system units ships EXTENSION_RELOAD_MANAGER=1 ($bad missing, $checked checked)"
    failures=$((failures + 1))
fi

# Every sysext that ships the key lists its release file in required-paths.txt.
missing=0
for rel in "$root"/mkosi.images/*/mkosi.extra/usr/lib/extension-release.d/extension-release.*; do
    name=${rel#"$root"/mkosi.images/}
    name=${name%%/*}
    grep -qxF "/usr/lib/extension-release.d/extension-release.$name" \
        "$root/mkosi.images/$name/required-paths.txt" || {
        echo "# $name: required-paths.txt does not list its extension-release file"
        missing=$((missing + 1))
    }
done
test_number=$((test_number + 1))
if ((missing == 0)); then
    echo "ok $test_number - every shipped extension-release file is in required-paths.txt"
else
    echo "not ok $test_number - required-paths.txt lists every extension-release file ($missing missing)"
    failures=$((failures + 1))
fi

# Every Overlay=yes sysext wires the guard.
wired=0
unwired=0
for config in "$root"/mkosi.images/*/mkosi.conf; do
    grep -Eq '^[[:space:]]*Overlay=yes' "$config" || continue
    if grep -E '^[[:space:]]*FinalizeScripts=' "$config" | grep -Fq 'sysext-reload-manager-guard.sh'; then
        wired=$((wired + 1))
    else
        unwired=$((unwired + 1))
        echo "# ${config%/mkosi.conf} does not wire sysext-reload-manager-guard.sh"
    fi
done
test_number=$((test_number + 1))
if ((wired > 0 && unwired == 0)); then
    echo "ok $test_number - $wired sysexts wire sysext-reload-manager-guard.sh"
else
    echo "not ok $test_number - every Overlay=yes sysext wires sysext-reload-manager-guard.sh ($unwired missing)"
    failures=$((failures + 1))
fi

echo
echo "# Results: $((test_number - failures)) passed, $failures failed, $test_number total"
((failures == 0))
