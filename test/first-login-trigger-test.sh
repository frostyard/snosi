#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static guard for the first-login trigger (ADR-0028).
#
# Snow and Snowfield start chairlift's first run from exactly one XDG
# autostart entry, /etc/xdg/autostart/org.frostyard.ChairLift.FirstRun.desktop
# (Exec=/usr/bin/chairlift-first-run), and ship the application list
# /usr/share/snow/first-run/apps.json. Sundog and Floe have no first-login
# app. snow-first-setup retired. Base ships a guarded
# /etc/profile.d/snosi-brew.sh instead of first-setup's ~/.bashrc lines.
#
# It checks:
#   1. no tracked build input names snow-first-setup outside comments;
#   2. every product's composed trees (base mkosi.extra plus its composition's
#      ExtraTrees) pass shared/composition/first-login-check.py, the same
#      rules the build finalize applies;
#   3. the finalize is wired into every OCI composition, and every OCI
#      profile includes the composition it expects;
#   4. the shipped apps.json has chairlift's shape, and malformed lists fail;
#   5. the finalize itself, on fixture image trees (missing or
#      non-executable chairlift-first-run, a wrong Exec, zero or two
#      entries, an entry on Sundog or Floe, an unknown IMAGE_ID);
#   6. the brew profile.d file is shellcheck-clean and its guards hold.
#
# No root, no network, no image build.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$root/shared/composition/first-login-check.py"
finalize="$root/shared/composition/first-login.finalize"
apps="$root/shared/snow/tree/usr/share/snow/first-run/apps.json"
entry_rel="etc/xdg/autostart/org.frostyard.ChairLift.FirstRun.desktop"
brew_sh="$root/mkosi.images/base/mkosi.extra/etc/profile.d/snosi-brew.sh"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- 1. snow-first-setup is gone from every build input ----------------------
# Comments, prose, tests and this guard's checker may name it; nothing that
# installs or builds may.
hits=$(cd "$root" && git ls-files -z \
    | grep -zv -e '^docs/' -e '^\.memory/' -e '^test/' -e '\.md$' \
        -e '^shared/composition/first-login-check\.py$' \
    | xargs -0 grep -nIE '\bsnow-first-setup\b' 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [[ -z $hits ]]; then
    pass "no build input names snow-first-setup"
else
    fail "build inputs still name snow-first-setup:"
    printf '#   %s\n' "$hits" >&2
fi

# --- 2. composed trees pass the image rules ----------------------------------
# Each product gets the base tree and its composition's ExtraTrees, in order,
# plus a stand-in /usr/bin/chairlift-first-run (the deb supplies the real one
# at build time; the finalize checks it there).
compose() { # product composition -> root path on stdout
    local product=$1 composition=$2 dest="$tmp/compose-$1" tree
    mkdir -p "$dest"
    cp -a "$root/mkosi.images/base/mkosi.extra/." "$dest/"
    while IFS= read -r tree; do
        tree=${tree//%D/$root}
        [[ -d $tree ]] || { echo "missing ExtraTrees $tree" >&2; return 1; }
        cp -a "$tree/." "$dest/"
    done < <(sed -n 's/^ExtraTrees=//p' "$root/shared/composition/$composition/mkosi.conf")
    printf '%s\n' "$dest"
}
for pair in snow:snow snowfield:snow sundog:sundog floe:floe; do
    product=${pair%%:*} composition=${pair#*:}
    if ! dest=$(compose "$product" "$composition"); then
        fail "$product: compose its trees"
        continue
    fi
    if [[ $product == snow || $product == snowfield ]]; then
        mkdir -p "$dest/usr/bin"
        printf '#!/bin/sh\nexit 0\n' >"$dest/usr/bin/chairlift-first-run"
        chmod 0755 "$dest/usr/bin/chairlift-first-run"
    fi
    if out=$(python3 "$checker" image "$product" "$dest" 2>&1); then
        pass "$product composed trees: ${out#first-login-check: }"
    else
        fail "$product composed trees: $out"
    fi
done

# --- 3. wiring ----------------------------------------------------------------
for composition in snow sundog floe; do
    if grep -qx 'FinalizeScripts=%D/shared/composition/first-login.finalize' \
        "$root/shared/composition/$composition/mkosi.conf"; then
        pass "$composition composition wires first-login.finalize"
    else
        fail "$composition composition does not wire first-login.finalize"
    fi
done
for pair in snow:snow snowfield:snow sundog:sundog floe:floe; do
    product=${pair%%:*} composition=${pair#*:}
    if grep -qx "Include=%D/shared/composition/$composition/mkosi.conf" \
        "$root/mkosi.profiles/$product/mkosi.conf"; then
        pass "$product profile includes the $composition composition"
    else
        fail "$product profile does not include the $composition composition"
    fi
done
if grep -q 'shared/snow/tree' "$root/shared/composition/sundog/mkosi.conf" \
    "$root/shared/composition/floe/mkosi.conf"; then
    fail "Sundog or Floe composes shared/snow/tree (the first-run entry would ship)"
else
    pass "only the Snow composition carries shared/snow/tree"
fi
if [[ -x $finalize ]]; then
    pass "first-login.finalize is executable"
else
    fail "first-login.finalize is not executable"
fi
if [[ -x $checker ]]; then
    pass "first-login-check.py is executable"
else
    fail "first-login-check.py is not executable"
fi

# --- 4. apps.json shape -------------------------------------------------------
if out=$(cd "$root" && python3 "$checker" apps "${apps#"$root"/}" 2>&1); then
    pass "shipped apps.json: ${out#first-login-check: }"
else
    fail "shipped apps.json: $out"
fi
apps_case() { # description json [reason the rejection must name]
    local description=$1 json=$2 named=$3 out status=0
    printf '%s' "$json" >"$tmp/apps.json"
    out=$(python3 "$checker" apps "$tmp/apps.json" 2>&1) || status=$?
    if [[ $status -eq 0 ]]; then
        fail "apps.json self-check: $description was accepted"
    elif [[ $out == *"$named"* ]]; then
        pass "apps.json self-check: $description is rejected"
    else
        fail "apps.json self-check: $description is rejected for: $named (got: $out)"
    fi
}
apps_case "invalid JSON" '{"browsers": [' "invalid JSON"
apps_case "an array at the top" '[]' "non-empty object"
apps_case "an empty object" '{}' "non-empty object"
apps_case "an empty category" '{"office": []}' "non-empty list"
apps_case "an entry with no name" '{"office": [{"id": "org.libreoffice.LibreOffice"}]}' "has no name"
apps_case "a two-element id" '{"office": [{"name": "X", "id": "org.example"}]}' "invalid Flatpak"
apps_case "an element that starts with a digit" '{"office": [{"name": "X", "id": "org.1example.App"}]}' "invalid Flatpak"
apps_case "a dash before the last element" '{"office": [{"name": "X", "id": "org.ex-ample.App"}]}' "invalid Flatpak"
apps_case "a space in the id" '{"office": [{"name": "X", "id": "org.example.My App"}]}' "invalid Flatpak"
apps_case "a non-boolean active" '{"office": [{"name": "X", "id": "org.example.App", "active": "no"}]}' "non-boolean active"
apps_case "an unknown field" '{"office": [{"name": "X", "id": "org.example.App", "url": "x"}]}' "unknown fields"
apps_case "an id in two categories" \
    '{"office": [{"name": "X", "id": "org.example.App"}], "utilities": [{"name": "Y", "id": "org.example.App"}]}' \
    "appears in"
apps_case "a duplicate category key" \
    '{"office": [{"name": "X", "id": "org.example.App"}], "office": [{"name": "Y", "id": "org.example.Two"}]}' \
    "duplicate key"
printf '%s' '{"misc": [{"name": "X", "id": "io.gitlab.librewolf-community", "active": false}]}' >"$tmp/apps.json"
if python3 "$checker" apps "$tmp/apps.json" >/dev/null 2>&1; then
    pass "apps.json self-check: a dash in the last element and active=false pass"
else
    fail "apps.json self-check: a dash in the last element and active=false pass"
fi

# --- 5. the finalize on fixture image trees ----------------------------------
good_entry='[Desktop Entry]
Type=Application
Name=ChairLift First Run
Exec=/usr/bin/chairlift-first-run
NoDisplay=true'
make_image() { # name with_trigger(yes|no) -> root path
    local dest="$tmp/image-$1"
    rm -rf "$dest"
    mkdir -p "$dest/etc/xdg/autostart" "$dest/usr/bin" "$dest/usr/share/snow/first-run"
    printf '[Desktop Entry]\nType=Application\nName=Other\nExec=/usr/bin/other\n' \
        >"$dest/etc/xdg/autostart/org.example.Other.desktop"
    if [[ $2 == yes ]]; then
        printf '%s\n' "$good_entry" >"$dest/$entry_rel"
        printf '#!/bin/sh\nexit 0\n' >"$dest/usr/bin/chairlift-first-run"
        chmod 0755 "$dest/usr/bin/chairlift-first-run"
        cp "$apps" "$dest/usr/share/snow/first-run/apps.json"
    fi
    printf '%s\n' "$dest"
}
run_finalize() { # image_id buildroot -> output; status of the finalize
    BUILDROOT="$2" SRCDIR="$root" IMAGE_ID="$1" "$finalize" 2>&1
}
expect() { # description pass|reject image_id buildroot [text the rejection must name]
    local description=$1 want=$2 image_id=$3 dir=$4 named=${5:-} out status=0
    out=$(run_finalize "$image_id" "$dir") || status=$?
    if [[ $want == pass && $status -eq 0 ]]; then
        pass "finalize: $description passes"
    elif [[ $want == pass ]]; then
        fail "finalize: $description passes (got: $out)"
    elif [[ $status -eq 0 ]]; then
        fail "finalize: $description was not detected"
    elif [[ $out == *"$named"* ]]; then
        pass "finalize: $description is detected"
    else
        fail "finalize: $description is detected and names: $named (got: $out)"
    fi
}

dir=$(make_image snow-good yes)
expect "Snow with one chairlift trigger" pass snow "$dir"
expect "Snowfield with one chairlift trigger" pass snowfield "$dir"
printf '\n[Desktop Action Settings]\nName=Settings\nExec=/usr/bin/chairlift\n' >>"$dir/$entry_rel"
expect "a [Desktop Action] Exec beside the right entry Exec" pass snow "$dir"

dir=$(make_image no-binary yes)
rm "$dir/usr/bin/chairlift-first-run"
expect "a missing /usr/bin/chairlift-first-run" reject snow "$dir" "/usr/bin/chairlift-first-run is missing"

dir=$(make_image noexec yes)
chmod 0644 "$dir/usr/bin/chairlift-first-run"
expect "a non-executable chairlift-first-run" reject snowfield "$dir" "not an executable regular file"

dir=$(make_image dir-binary yes)
rm "$dir/usr/bin/chairlift-first-run"
mkdir -m 0755 "$dir/usr/bin/chairlift-first-run"
expect "a directory at /usr/bin/chairlift-first-run" reject snow "$dir" "not an executable regular file"

dir=$(make_image link-binary yes)
mv "$dir/usr/bin/chairlift-first-run" "$dir/usr/bin/chairlift-first-run.real"
ln -s /usr/bin/chairlift-first-run.real "$dir/usr/bin/chairlift-first-run"
expect "an absolute symlink resolved inside BUILDROOT" pass snow "$dir"

for bad_exec in '/usr/bin/chairlift --first-run' 'chairlift-first-run' \
    '/usr/bin/chairlift-first-run --force' '/usr/local/bin/chairlift-first-run'; do
    dir=$(make_image wrong-exec yes)
    sed -i "s|^Exec=.*|Exec=$bad_exec|" "$dir/$entry_rel"
    expect "Exec=$bad_exec" reject snow "$dir" "it must be exactly /usr/bin/chairlift-first-run"
done

dir=$(make_image no-exec-key yes)
sed -i '/^Exec=/d' "$dir/$entry_rel"
expect "a chairlift entry with no Exec" reject snow "$dir" "it must be exactly"

dir=$(make_image zero no)
expect "Snow with zero first-login entries" reject snow "$dir" "found 0: none"

dir=$(make_image two yes)
printf '[Desktop Entry]\nName=SNOW First Setup\nExec=snow-first-setup --autostart\nNoDisplay=true\n' \
    >"$dir/etc/xdg/autostart/org.frostyard.FirstSetup.autostart.desktop"
expect "Snow with chairlift and first-setup entries" reject snow "$dir" "found 2"

dir=$(make_image two-by-exec yes)
printf '[Desktop Entry]\nName=Setup\nExec=/usr/bin/chairlift-first-run\n' \
    >"$dir/etc/xdg/autostart/zz-renamed.desktop"
expect "a second entry under another name, found by Exec" reject snowfield "$dir" "found 2"

dir=$(make_image skel yes)
mkdir -p "$dir/etc/skel/.config/autostart"
printf '[Desktop Entry]\nName=Setup\nExec=chairlift --first-run\n' \
    >"$dir/etc/skel/.config/autostart/setup.desktop"
expect "a second entry in /etc/skel autostart" reject snow "$dir" "found 2"

dir=$(make_image first-setup-only no)
printf '[Desktop Entry]\nName=SNOW First Setup\nExec=snow-first-setup --autostart\n' \
    >"$dir/etc/xdg/autostart/org.frostyard.FirstSetup.autostart.desktop"
expect "Snow with only the first-setup entry" reject snow "$dir" "not /$entry_rel"

dir=$(make_image hidden yes)
printf 'Hidden=true\n' >>"$dir/$entry_rel"
expect "a hidden chairlift entry (no trigger)" reject snow "$dir" "found 0"

dir=$(make_image disabled-extra yes)
printf '[Desktop Entry]\nName=SNOW First Setup\nExec=snow-first-setup --autostart\nX-GNOME-Autostart-enabled=false\n' \
    >"$dir/etc/xdg/autostart/org.frostyard.FirstSetup.autostart.desktop"
expect "a disabled first-setup entry left beside the trigger" reject snow "$dir" "disabled first-login entries"

dir=$(make_image malformed yes)
printf 'garbage line\n' >>"$dir/$entry_rel"
expect "a malformed chairlift entry" reject snow "$dir" "not a key=value line"

dir=$(make_image no-apps yes)
rm "$dir/usr/share/snow/first-run/apps.json"
expect "a missing apps.json" reject snow "$dir" "cannot read /usr/share/snow/first-run/apps.json"

dir=$(make_image bad-apps yes)
printf '{"office": []}' >"$dir/usr/share/snow/first-run/apps.json"
expect "a malformed apps.json" reject snow "$dir" "non-empty list"

dir=$(make_image sundog-empty no)
expect "Sundog with no first-login entry" pass sundog "$dir"
expect "Floe with no first-login entry" pass floe "$dir"

dir=$(make_image sundog-entry yes)
expect "Sundog with the chairlift entry" reject sundog "$dir" "sundog must ship no first-login entry"
expect "Floe with the chairlift entry" reject floe "$dir" "floe must ship no first-login entry"

dir=$(make_image sundog-hidden no)
printf '%s\nHidden=true\n' "$good_entry" >"$dir/$entry_rel"
expect "Sundog with a hidden chairlift entry" reject sundog "$dir" "must ship no first-login entry"

dir=$(make_image unknown yes)
expect "an unknown IMAGE_ID" reject firn-installer "$dir" "no first-login rule"

out=$(env -u IMAGE_ID BUILDROOT="$dir" SRCDIR="$root" "$finalize" 2>&1) && status=0 || status=$?
if [[ $status -ne 0 && $out == *"IMAGE_ID not set"* ]]; then
    pass "finalize: a missing IMAGE_ID fails"
else
    fail "finalize: a missing IMAGE_ID fails (status $status: $out)"
fi

# --- 6. brew profile.d --------------------------------------------------------
if [[ -f $brew_sh ]]; then
    pass "base ships etc/profile.d/snosi-brew.sh"
else
    fail "base does not ship etc/profile.d/snosi-brew.sh"
fi
if ! command -v shellcheck >/dev/null; then
    fail "shellcheck is not installed"
elif shellcheck -s sh "$brew_sh"; then
    pass "snosi-brew.sh is shellcheck-clean (sh)"
else
    fail "snosi-brew.sh is not shellcheck-clean (sh)"
fi
# Run the real file with its brew path pointed at a fixture prefix, and with
# an `id` shim, so both guards are exercised without root or Homebrew.
fake="$tmp/brewprefix"
mkdir -p "$fake/bin" "$tmp/shim"
sed "s|/home/linuxbrew/.linuxbrew/bin/brew|$fake/bin/brew|g" "$brew_sh" >"$tmp/brew.sh"
if grep -q '/home/linuxbrew/.linuxbrew/bin/brew' "$tmp/brew.sh" \
    || [[ $(grep -c "\[ -x $fake/bin/brew \]" "$tmp/brew.sh") -ne 1 ]]; then
    fail "snosi-brew.sh must guard on [ -x /home/linuxbrew/.linuxbrew/bin/brew ] once"
else
    pass "snosi-brew.sh guards on [ -x /home/linuxbrew/.linuxbrew/bin/brew ]"
fi
printf '#!/bin/sh\necho "export SNOSI_BREW_TEST=loaded"\n' >"$fake/bin/brew"
# shellcheck disable=SC2016  # the shim expands SHIM_UID when it runs
printf '#!/bin/sh\necho "${SHIM_UID:-1000}"\n' >"$tmp/shim/id"
chmod 0755 "$tmp/shim/id"
brew_case() { # description expect(loaded|unset) uid brew_mode
    local description=$1 want=$2 uid=$3 mode=$4 got shell
    if [[ -e $fake/bin/brew ]]; then chmod "$mode" "$fake/bin/brew"; fi
    for shell in sh bash; do
        got=$(SHIM_UID=$uid PATH="$tmp/shim:$PATH" "$shell" -c \
            ". '$tmp/brew.sh'; printf '%s' \"\${SNOSI_BREW_TEST:-unset}\"" 2>&1) || got="error: $got"
        if [[ $got == "$want" ]]; then
            pass "snosi-brew.sh ($shell): $description"
        else
            fail "snosi-brew.sh ($shell): $description (want $want, got $got)"
        fi
    done
}
brew_case "a user with brew installed gets the environment" loaded 1000 0755
brew_case "root never takes the brew prefix" unset 0 0755
brew_case "no environment when brew is not executable" unset 1000 0644
rm "$fake/bin/brew"
brew_case "no environment and no error when brew is absent" unset 1000 0755

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
