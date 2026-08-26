#!/bin/bash
# Fixture suite for the gui-base desktop-sysext contract (issue #781):
#  - shared/sysext/finalize/sysext-no-divergent-libs.sh behavior (a delta
#    carrying a product-divergent lib family fails the build; a clean delta
#    passes; an empty family list fails vacuous passes)
#  - static wiring parity: every sysext built against gui-base carries the
#    no-divergent-libs finalize, and vice versa (a tripwire without the
#    gui-base rebase, or a rebase without the tripwire, is half a fix —
#    the exact split-brain that let issue #781's class ship)
#  - gui-base image shape: internal-only (directory format, no transfer,
#    no postoutput), listed in the root build set
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/shared/sysext/finalize/sysext-no-divergent-libs.sh"
families="$root/shared/sysext/divergent-lib-families.txt"
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
}

# The script resolves the family list as $SRCDIR/shared/sysext/...; build a
# fake SRCDIR per case so tests never depend on (or mutate) the real file.
make_srcdir() { # name family-content -> path
    local d="$work/$1/src"
    mkdir -p "$d/shared/sysext"
    printf '%s\n' "$2" >"$d/shared/sysext/divergent-lib-families.txt"
    echo "$d"
}

make_delta() { # name -> path (empty /usr skeleton)
    local d="$work/$1/delta"
    mkdir -p "$d/usr/lib/x86_64-linux-gnu"
    echo "$d"
}

# --- case 1: clean delta passes -------------------------------------------
src=$(make_srcdir clean 'lib/*/libxkbcommon*.so*')
delta=$(make_delta clean)
touch "$delta/usr/lib/x86_64-linux-gnu/libfoo.so.1"
if out=$(BUILDROOT="$delta" SRCDIR="$src" IMAGE_ID=testext "$script" 2>&1); then
    ok "clean delta passes"
else
    fail "clean delta passes" "$out"
fi

# --- case 2: divergent lib fails, names the file --------------------------
src=$(make_srcdir dirty 'lib/*/libxkbcommon*.so*')
delta=$(make_delta dirty)
touch "$delta/usr/lib/x86_64-linux-gnu/libxkbcommon.so.0.0.0"
if out=$(BUILDROOT="$delta" SRCDIR="$src" IMAGE_ID=testext "$script" 2>&1); then
    fail "divergent lib fails the build" "$out"
elif [[ $out == *libxkbcommon.so.0.0.0* && $out == *"do not remove the pattern"* ]]; then
    ok "divergent lib fails the build and names the offender"
else
    fail "divergent lib failure output names the offender" "$out"
fi

# --- case 3: directory-family glob (pipewire modules dir) -----------------
src=$(make_srcdir dirglob 'lib/*/spa-0.2/*')
delta=$(make_delta dirglob)
mkdir -p "$delta/usr/lib/x86_64-linux-gnu/spa-0.2/support"
if out=$(BUILDROOT="$delta" SRCDIR="$src" IMAGE_ID=testext "$script" 2>&1); then
    fail "directory family glob fails the build" "$out"
else
    ok "directory family glob fails the build"
fi

# --- case 4: comments/blank lines ignored, empty list refuses -------------
src=$(make_srcdir empty '# only comments

# here')
delta=$(make_delta empty)
if out=$(BUILDROOT="$delta" SRCDIR="$src" IMAGE_ID=testext "$script" 2>&1); then
    fail "pattern-free family list refuses to pass" "$out"
elif [[ $out == *vacuously* ]]; then
    ok "pattern-free family list refuses to pass vacuously"
else
    fail "pattern-free family list error message" "$out"
fi

# --- case 5: missing family list fails ------------------------------------
delta=$(make_delta nofile)
if out=$(BUILDROOT="$delta" SRCDIR="$work/nofile/does-not-exist" IMAGE_ID=testext "$script" 2>&1); then
    fail "missing family list fails" "$out"
else
    ok "missing family list fails"
fi

# --- case 6: real family list is non-empty and covers the known families --
if [[ -f "$families" ]]; then
    ok "shipped divergent-lib-families.txt exists"
else
    fail "shipped divergent-lib-families.txt exists"
fi
for fam in libxkbcommon libpipewire libgbm libasound spa-0.2; do
    if grep -q "$fam" "$families"; then
        ok "family list covers $fam"
    else
        fail "family list covers $fam"
    fi
done

# --- case 7: wiring parity across mkosi.images ----------------------------
declare -a rebased=() wired=()
for conf in "$root"/mkosi.images/*/mkosi.conf; do
    img=$(basename "$(dirname "$conf")")
    uses_gui_base=no
    grep -q '^BaseTrees=%O/gui-base' "$conf" && uses_gui_base=yes
    # edge keeps its BaseTrees in an [Include]d fragment
    while IFS= read -r inc; do
        inc=${inc#Include=}
        inc=${inc//%D/$root}
        [[ -f $inc ]] && grep -q '^BaseTrees=%O/gui-base' "$inc" && uses_gui_base=yes
    done < <(grep '^Include=' "$conf" || true)
    has_tripwire=no
    grep -q 'sysext-no-divergent-libs.sh' <(grep '^FinalizeScripts=' "$conf") && has_tripwire=yes
    [[ $uses_gui_base == yes ]] && rebased+=("$img")
    [[ $has_tripwire == yes ]] && wired+=("$img")
    if [[ $uses_gui_base != "$has_tripwire" ]]; then
        fail "$img: gui-base rebase and no-divergent-libs tripwire must come together (BaseTrees=gui-base: $uses_gui_base, tripwire: $has_tripwire)"
    fi
done
if ((${#rebased[@]} > 0)); then
    ok "gui-base sysexts all carry the tripwire and vice versa (${#rebased[@]} images: ${rebased[*]})"
else
    fail "at least one sysext is built against gui-base"
fi

# every gui-base sysext must also depend on gui-base so mkosi orders builds
for img in "${rebased[@]}"; do
    if grep -q '^Dependencies=gui-base' "$root/mkosi.images/$img/mkosi.conf"; then
        ok "$img depends on gui-base"
    else
        fail "$img depends on gui-base"
    fi
done

# --- case 8: gui-base image shape -----------------------------------------
gb="$root/mkosi.images/gui-base/mkosi.conf"
if [[ -f $gb ]] && grep -q '^Format=directory' "$gb" &&
    ! grep -q 'PostOutputScripts' "$gb" && ! grep -q 'KEYPACKAGE' "$gb"; then
    ok "gui-base is an internal directory image (no postoutput, no KEYPACKAGE)"
else
    fail "gui-base is an internal directory image"
fi
if [[ ! -d "$root/mkosi.images/base/mkosi.extra/usr/lib/sysupdate.gui-base.d" ]]; then
    ok "gui-base has no sysupdate transfer (never published)"
else
    fail "gui-base has no sysupdate transfer"
fi
if awk '/^Dependencies=/{f=1} f&&/gui-base/{found=1} /^\[/{if(NR>1)f=0} END{exit !found}' "$root/mkosi.conf"; then
    ok "root mkosi.conf builds gui-base by default"
else
    fail "root mkosi.conf builds gui-base by default"
fi

echo
echo "# Results: $((test_number - failures)) passed, $failures failed, $test_number total"
((failures == 0))
