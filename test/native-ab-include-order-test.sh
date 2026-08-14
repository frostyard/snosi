#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Enforce the secure-before-composition Include= ordering contract for the
# three production native A/B profiles (cayo-ab, snow-ab, snowfield-ab).
#
# ADR-0005 (docs/adr/0005-profiles-as-transport-kernel-selectors.md) makes the
# Include= order load-bearing: the secure posture fragment
# (shared/native-ab-secure/mkosi.conf) must resolve BEFORE the composition
# fragment (shared/composition/<product>/mkosi.conf) so that the secure
# fragment's FinalizeScripts= (disable-nvpcr.chroot) accumulate ahead of the
# composition fragment's image finalize (mkosi.finalize.chroot). mkosi merges
# list settings in Include= encounter order, so the arbiter is the RESOLVED
# configuration, not a read of the source files in isolation.
#
# Per ADR-0005 the authoritative view is `mkosi cat-config` / `mkosi summary`.
# When a mkosi binary is available (repository-local .mkosi/bin/mkosi is
# preferred) this test derives the FinalizeScripts= order from
# `mkosi ... cat-config`. When mkosi is not available -- as in the no-root,
# no-network CI validate job -- it falls back to resolving the profile's
# top-level [Include] list in encounter order and concatenating each included
# fragment's FinalizeScripts= entries, which reproduces mkosi's documented
# accumulation for exactly the two entries this contract governs.
#
# The test also proves the contract has teeth: it builds a reversed-order
# fixture of each profile and asserts the same check REJECTS it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The two FinalizeScripts= entries whose relative order defines the contract.
secure_marker="shared/native-ab-secure/finalize/disable-nvpcr.chroot"
composition_marker="shared/outformat/image/finalize/mkosi.finalize.chroot"

production_profiles=(cayo-ab snow-ab snowfield-ab)

mkosi=""
if [[ -x "$root/.mkosi/bin/mkosi" ]]; then
    mkosi="$root/.mkosi/bin/mkosi"
elif command -v mkosi >/dev/null 2>&1; then
    mkosi="mkosi"
fi

# Emit the resolved FinalizeScripts= order (one relative path per line) for a
# profile whose mkosi.conf lives at $1. When $2 is a mkosi binary the order is
# read from `cat-config`; otherwise it is resolved from the profile's top-level
# [Include] list. Both paths strip the leading %D/ so callers match on the
# repository-relative path.
resolved_finalize_order() {
    local conf="$1" mkosi_bin="${2:-}"

    if [[ -n "$mkosi_bin" ]]; then
        local profile_dir profile_name
        profile_dir="$(dirname "$conf")"
        profile_name="$(basename "$profile_dir")"
        # cat-config prints the merged configuration in resolution order; the
        # FinalizeScripts= lines therefore appear in accumulation order.
        (cd "$root" && "$mkosi_bin" --profile "$profile_name" cat-config 2>/dev/null) \
            | sed -n 's/^FinalizeScripts=//p' \
            | sed 's#^%D/##; s#^'"$root"'/##'
        return 0
    fi

    # Fallback: walk the profile's top-level Include= list in encounter order
    # and, for each included fragment, emit its FinalizeScripts= entries in file
    # order. This reproduces mkosi's list-setting accumulation for the two
    # markers this contract governs (the secure fragment carries no nested
    # includes that contribute FinalizeScripts, and it is the first include, so
    # its entry precedes every composition entry iff the source Include= order
    # is secure-before-composition).
    local include rel frag
    while IFS= read -r include; do
        rel="${include#Include=%D/}"
        frag="$root/$rel"
        [[ -f "$frag" ]] || continue
        sed -n 's/^FinalizeScripts=%D\///p' "$frag"
    done < <(grep '^Include=%D/' "$conf")
}

# Assert the secure marker precedes the composition marker in the given order.
# Returns 0 when the contract holds, 1 otherwise.
assert_secure_before_composition() {
    local order="$1" secure_idx="" composition_idx="" idx=0 line
    while IFS= read -r line; do
        [[ "$line" == "$secure_marker" && -z "$secure_idx" ]] && secure_idx=$idx
        [[ "$line" == "$composition_marker" && -z "$composition_idx" ]] && composition_idx=$idx
        idx=$((idx + 1))
    done <<<"$order"

    if [[ -z "$secure_idx" ]]; then
        echo "  secure FinalizeScripts marker ($secure_marker) not found in resolved order" >&2
        return 1
    fi
    if [[ -z "$composition_idx" ]]; then
        echo "  composition FinalizeScripts marker ($composition_marker) not found in resolved order" >&2
        return 1
    fi
    (( secure_idx < composition_idx ))
}

if [[ -n "$mkosi" ]]; then
    echo "Using mkosi at '$mkosi' (cat-config) to resolve FinalizeScripts order."
else
    echo "mkosi not available; resolving FinalizeScripts order from [Include] encounter order."
fi

failed=0

# Positive case: every production profile must satisfy the contract as shipped.
for name in "${production_profiles[@]}"; do
    conf="$root/mkosi.profiles/$name/mkosi.conf"
    if [[ ! -f "$conf" ]]; then
        echo "Missing production profile: $conf" >&2
        failed=1
        continue
    fi
    order="$(resolved_finalize_order "$conf" "$mkosi")"
    if assert_secure_before_composition "$order"; then
        echo "OK: $name resolves secure posture before composition."
    else
        echo "FAIL: $name does not resolve the secure posture fragment before the composition fragment (ADR-0005)." >&2
        failed=1
    fi
done

# Negative case: a reversed-order copy of each profile must be REJECTED. This
# proves the check fails when the ordering drifts, per ADR-0005's acceptance
# rule. The fixture only swaps the two governed Include= lines; nothing in the
# real tree changes. The mkosi-backed path is skipped for the fixture because
# mkosi resolves profiles by name from the repo's own mkosi.profiles/ tree, not
# from an out-of-tree fixture file; the include-resolution path validates the
# reversed order directly and is always exercised here.
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
for name in "${production_profiles[@]}"; do
    conf="$root/mkosi.profiles/$name/mkosi.conf"
    [[ -f "$conf" ]] || continue
    reversed="$fixture_dir/$name.mkosi.conf"
    # Swap the secure Include line with the immediately-following composition
    # Include line to model an ordering regression.
    awk '
        /^Include=%D\/shared\/native-ab-secure\/mkosi\.conf$/ { held = $0; next }
        /^Include=%D\/shared\/composition\// && held != "" {
            print $0; print held; held = ""; next
        }
        { print }
        END { if (held != "") print held }
    ' "$conf" >"$reversed"

    order="$(resolved_finalize_order "$reversed" "")"
    if assert_secure_before_composition "$order" 2>/dev/null; then
        echo "FAIL: reversed-order fixture for $name was accepted; the ordering check has no teeth." >&2
        failed=1
    else
        echo "OK: reversed-order fixture for $name is correctly rejected."
    fi
done

if (( failed )); then
    echo "Secure-before-composition Include= ordering contract violated." >&2
    exit 1
fi

echo "All production native A/B profiles resolve secure posture before composition."
