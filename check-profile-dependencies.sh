#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

mkosi=mkosi
if [[ -x .mkosi/bin/mkosi ]]; then
    mkosi=.mkosi/bin/mkosi
fi

# Discover the bootc image profiles instead of hardcoding them. A profile is a
# bootc image profile when its mkosi.conf composes the bootc-secure fragment
# (shared/bootc-secure/mkosi.conf) -- the same set the bootc publication guard
# gates (cayo, snow, snowfield today). New bootc image profiles are picked up
# automatically; the native A/B (*-ab) and installer profiles compose different
# fragments and are intentionally excluded from this "depend only on base" check.
profiles=()
for conf in mkosi.profiles/*/mkosi.conf; do
    [[ -e "$conf" ]] || continue
    if grep -q 'shared/bootc-secure/mkosi\.conf' "$conf"; then
        profiles+=("$(basename "$(dirname "$conf")")")
    fi
done

# Discover the sysext images instead of hardcoding them. A mkosi.images entry is
# a sysext when its mkosi.conf declares Format=sysext. This excludes the base OS
# image (Format=directory) and automatically covers newly added sysexts, so a
# profile that regresses into pulling one in cannot slip past the guard because
# its name was never added to a hand-maintained list.
sysexts=()
for conf in mkosi.images/*/mkosi.conf; do
    [[ -e "$conf" ]] || continue
    if grep -qE '^[[:space:]]*Format=sysext[[:space:]]*$' "$conf"; then
        sysexts+=("$(basename "$(dirname "$conf")")")
    fi
done

# Refuse to pass vacuously: an empty discovery (wrong working directory, renamed
# layout, glob failure) would otherwise turn this guard into a silent no-op.
if (( ${#profiles[@]} == 0 )); then
    echo "No bootc image profiles discovered under mkosi.profiles/ (expected at least one composing shared/bootc-secure/mkosi.conf)." >&2
    exit 1
fi
if (( ${#sysexts[@]} == 0 )); then
    echo "No sysext images discovered under mkosi.images/ (expected at least one declaring Format=sysext)." >&2
    exit 1
fi

failed=0

for profile in "${profiles[@]}"; do
    summary=$("$mkosi" -f --profile "$profile" summary)

    for sysext in "${sysexts[@]}"; do
        if grep -q "^IMAGE: ${sysext}$" <<<"$summary"; then
            echo "Profile ${profile} unexpectedly includes sysext dependency ${sysext}." >&2
            failed=1
        fi
    done
done

if (( failed )); then
    exit 1
fi

echo "Profile builds depend only on base."
