#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Keep build-time preset links in /etc, even with systemctl v263 or newer.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

checks=0
failures=0
ok() {
    checks=$((checks + 1))
    printf 'ok %d - %s\n' "$checks" "$1"
}
fail() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    printf 'not ok %d - %s\n' "$checks" "$1"
}

check_pin() { # config file
    awk '
        /^[[:space:]]*\[/ {
            section = $0
            sub(/#.*/, "", section)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
        }
        /^[[:space:]]*PresetVendor[[:space:]]*=/ {
            count++
            if (section == "[Content]" && $0 == "PresetVendor=no") pinned++
        }
        END { if (count != 1 || pinned != 1) exit 1 }
    ' "$1"
}

expect_pin() {
    local message="$1 must set exactly one PresetVendor=no in [Content]"
    if check_pin "$1"; then ok "$message"; else fail "$message"; fi
}

expect_pin mkosi.conf
expect_pin mkosi.images/base/mkosi.conf
expect_pin mkosi.images/gui-base/mkosi.conf

# Discover future non-overlay subimages from the Git index, not a fixed list.
git ls-files -z -- ':(glob)mkosi.images/*/mkosi.conf' >"$work/images"
expected=0
pinned=0
while IFS= read -r -d '' file; do
    if grep -Eq '^[[:space:]]*Overlay[[:space:]]*=[[:space:]]*yes[[:space:]]*(#.*)?$' "$file"; then
        continue
    fi
    expected=$((expected + 1))
    if check_pin "$file"; then
        pinned=$((pinned + 1))
    else
        printf '# %s: missing exactly one PresetVendor=no in [Content]\n' "$file"
    fi
done <"$work/images"
if ((expected > 0 && pinned == expected)); then
    ok "$pinned of $expected tracked non-overlay subimages set PresetVendor=no in [Content]"
else
    fail "$pinned of $expected tracked non-overlay subimages set PresetVendor=no in [Content] (need all and at least one)"
fi

git ls-files -z -- '*.conf' >"$work/configs"
configs=()
while IFS= read -r -d '' file; do configs+=("./$file"); done <"$work/configs"
if out=$(awk '
    /^[[:space:]]*PresetVendor[[:space:]]*=/ {
        line = $0
        sub(/#.*/, "", line)
        if (line !~ /^[[:space:]]*PresetVendor[[:space:]]*=[[:space:]]*no[[:space:]]*$/) {
            print FILENAME ":" FNR ": " $0
            bad = 1
        }
    }
    END { if (bad) exit 1 }
' "${configs[@]}" 2>&1); then
    ok 'no tracked .conf sets PresetVendor to a value other than no'
else
    fail 'tracked .conf files must not set PresetVendor to a value other than no'
    printf '# %s\n' "$out"
fi

# A command-line --preset-vendor= or a PresetVendor= in a workflow or script
# would override the pin for the whole build.
grep_status=0
out=$(git grep -n -I -E -e '--preset-vendor' -e 'PresetVendor' -- .github Justfile shared scripts 2>&1) ||
    grep_status=$?
if ((grep_status == 1)); then
    ok 'no workflow, Justfile, shared or scripts file sets --preset-vendor or PresetVendor'
else
    fail 'no workflow, Justfile, shared or scripts file sets --preset-vendor or PresetVendor'
    printf '# %s\n' "$out"
fi

cp mkosi.conf "$work/original.conf"
sed '/^PresetVendor=no$/d' "$work/original.conf" >"$work/missing.conf"
cp "$work/missing.conf" "$work/misplaced.conf"
printf '\n[Output]\nPresetVendor=no\n' >>"$work/misplaced.conf"
sed 's/^PresetVendor=no$/PresetVendor=auto/' "$work/original.conf" >"$work/auto.conf"

for mutation in missing misplaced auto; do
    if check_pin "$work/$mutation.conf"; then
        fail "self-test rejects $mutation PresetVendor pin"
    else
        ok "self-test rejects $mutation PresetVendor pin"
    fi
done

printf '\n# Results: %d passed, %d failed, %d total\n' "$((checks - failures))" "$failures" "$checks"
((failures == 0))
