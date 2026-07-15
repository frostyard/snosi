#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Static publication guard for native A/B profiles (docs/native-ab-contracts.md
# §15, "Static publication guard"). This is a stricter, standalone companion
# to the config-marker subset already checked by
# test/native-ab-contracts-test.sh -- this script is meant to be the single
# place that grows the remaining §15 criteria as later phases land.
#
# What it inspects, for every directory mkosi.profiles/<name> whose name is
# exactly one of the production native profile names (cayo-ab, snow-ab,
# snowfield-ab -- docs/native-ab-contracts.md §1):
#
#   - The profile's own mkosi.conf, verbatim.
#   - Files under shared/native-ab-secure/** IF AND ONLY IF the profile's
#     mkosi.conf contains an [Include] line referencing that path. This is a
#     plain textual reachability check, not a real mkosi Include= resolver:
#     it does not walk arbitrary Include= chains, only this one documented
#     fragment directory named in the contract.
#
# Against that combined text it requires ALL of:
#   - ShimBootloader=signed
#   - SecureBoot=yes
#   - SignExpectedPcr=yes
#   - A reference to the NvPCR disable finalize script
#     (shared/cayo-ab-secure/finalize/disable-nvpcr.chroot, or its eventual
#     successor path under shared/native-ab-secure/).
#   - Inclusion of the ab-root outformat fragment
#     (shared/outformat/ab-root/mkosi.conf).
#   - The committed update pubring exists in-tree at
#     shared/native-ab/keys/import-pubring.gpg (docs/native-ab-contracts.md
#     §7; this path does not exist yet as of Phase 1, so any production
#     profile created before Phase 7 correctly fails this check).
#   - NO `KernelModules=` final-root filter line in the profile's OWN
#     mkosi.conf (docs/native-ab-contracts.md §9). Phase 3 removed the
#     dev-only virtio-only filter from the shared ab-root fragment entirely;
#     it now lives only in mkosi.profiles/cayo-ab-raw/mkosi.conf, the one
#     dev fixture permitted to carry it (never a production-named profile).
#     This check still only inspects the profile's OWN conf, not
#     shared/outformat/ab-root/mkosi.conf or the per-product channel
#     fragment it Includes (shared/native-ab/channels/<product>/mkosi.conf)
#     -- both are asserted filter-free unconditionally by
#     test/native-ab-contracts-test.sh instead, since that's true for every
#     consumer, not just production-named ones.
#
# If no directory named cayo-ab, snow-ab, or snowfield-ab exists yet (the
# case as of Phase 1), this exits 0 with a note: there is nothing to publish,
# so there is nothing to gate.
#
# Independently of the loop above, mkosi.profiles/cayo-ab-raw -- the
# permanent, never-published raw dev fixture (docs/native-ab-contracts.md
# §1) -- is HARD-FAILED if its mkosi.conf ever grows any of the publication
# markers (ShimBootloader=signed, SecureBoot=yes, SignExpectedPcr=yes). A raw
# fixture that picks those up would become indistinguishable from a
# production profile, which is exactly what the Phase 1 rename was meant to
# prevent.
set -euo pipefail

cd "$(dirname "$0")"

production_names=(cayo-ab snow-ab snowfield-ab)
pubring="shared/native-ab/keys/import-pubring.gpg"

fail=0
found_production=0

check_profile() { # name
    local name="$1"
    local conf="mkosi.profiles/$name/mkosi.conf"
    [[ -f "$conf" ]] || return 0
    found_production=1

    local combined
    combined="$(cat "$conf")"
    if grep -q 'shared/native-ab-secure' "$conf" 2>/dev/null; then
        combined+=$'\n'
        combined+="$(find shared/native-ab-secure -type f -exec cat {} + 2>/dev/null || true)"
    fi

    local ok=1
    grep -qE '^ShimBootloader=signed$' <<<"$combined" \
        || { echo "FAIL: $conf: missing ShimBootloader=signed" >&2; ok=0; }
    grep -qE '^SecureBoot=yes$' <<<"$combined" \
        || { echo "FAIL: $conf: missing SecureBoot=yes" >&2; ok=0; }
    grep -qE '^SignExpectedPcr=yes$' <<<"$combined" \
        || { echo "FAIL: $conf: missing SignExpectedPcr=yes" >&2; ok=0; }
    grep -q 'disable-nvpcr.chroot' <<<"$combined" \
        || { echo "FAIL: $conf: no reference to the NvPCR disable finalize script" >&2; ok=0; }
    grep -q 'shared/outformat/ab-root' <<<"$combined" \
        || { echo "FAIL: $conf: does not include the ab-root outformat fragment" >&2; ok=0; }
    [[ -f "$pubring" ]] \
        || { echo "FAIL: $conf: update pubring not committed at $pubring" >&2; ok=0; }
    if grep -qE '^KernelModules=' "$conf"; then
        echo "FAIL: $conf: production profiles must not filter final-root KernelModules=" >&2
        ok=0
    fi

    if ((ok)); then
        echo "PASS: $conf satisfies the native publication guard"
    else
        fail=1
    fi
}

for name in "${production_names[@]}"; do
    check_profile "$name"
done

if ((! found_production)); then
    echo "No production native profiles (cayo-ab, snow-ab, snowfield-ab) exist yet -- nothing to gate."
fi

raw_conf="mkosi.profiles/cayo-ab-raw/mkosi.conf"
if [[ -f "$raw_conf" ]]; then
    if grep -qE '^(ShimBootloader=signed|SecureBoot=yes|SignExpectedPcr=yes)$' "$raw_conf"; then
        echo "FAIL: $raw_conf: the raw dev fixture must never carry publication markers" >&2
        fail=1
    else
        echo "PASS: $raw_conf remains unpublishable"
    fi
fi

exit "$fail"
