#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Static validation of the frozen native A/B contracts defined in
# docs/native-ab-contracts.md. No root, no network, no image build.
#
# Known deviations between the current prototype and the frozen contract are
# tracked in test/native-ab-contracts-allow.txt (one "<path> <reason-tag>"
# per line). A violation not listed there fails the build; a listed entry
# whose file is gone or which no longer violates also fails the build
# (stale-entry check), so the allowlist shrinks to empty as later phases
# land instead of silently accumulating forever.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

allowlist_file="test/native-ab-contracts-allow.txt"

fail=0
checks=0

pass() { # message
    checks=$((checks + 1))
    printf 'PASS: %s\n' "$1"
}

fail_check() { # message
    checks=$((checks + 1))
    fail=1
    printf 'FAIL: %s\n' "$1" >&2
}

# ---------------------------------------------------------------------------
# Frozen constants (docs/native-ab-contracts.md)
# ---------------------------------------------------------------------------

products=(cayo snow snowfield)
version_regex='^[0-9]{14}$'
max_version_len=14
label_ceiling=30
sample_version="20260714150036"
os_url_prefix="https://repository.frostyard.org/os/native/v1"

channel_alt='(cayo|snow|snowfield)-ab'
version_re='[0-9]{14}'
uuid_re='[0-9a-fA-F-]+'
root_raw_re="^${channel_alt}_${version_re}_${uuid_re}\\.root\\.raw\\.xz\$"
root_verity_raw_re="^${channel_alt}_${version_re}_${uuid_re}\\.root-verity\\.raw\\.xz\$"
efi_re="^${channel_alt}_${version_re}\\.efi\$"
disk_raw_re="^${channel_alt}_${version_re}\\.disk\\.raw\\.xz\$"
manifest_re="^${channel_alt}_${version_re}\\.manifest\\.json\$"
sbom_re="^${channel_alt}_${version_re}\\.sbom\\.spdx\\.json\$"

# ---------------------------------------------------------------------------
# 1. Version grammar self-test
# ---------------------------------------------------------------------------

assert_matches() { # value regex label
    if [[ "$1" =~ $2 ]]; then
        pass "$3: '$1' matches"
    else
        fail_check "$3: '$1' should match but did not"
    fi
}

assert_no_match() { # value regex label
    if [[ "$1" =~ $2 ]]; then
        fail_check "$3: '$1' should NOT match but did"
    else
        pass "$3: '$1' correctly rejected"
    fi
}

assert_matches "20260714150036" "$version_regex" "version-grammar good"
assert_no_match "2026071410" "$version_regex" "version-grammar too-short"
assert_no_match "202607141500361" "$version_regex" "version-grammar 15-digits"
assert_no_match "20260714150036+r1" "$version_regex" "version-grammar suffixed"
assert_no_match "2026-07-14150036" "$version_regex" "version-grammar non-digit"

if [[ ${#sample_version} -ne max_version_len ]]; then
    fail_check "sample version length: expected $max_version_len, got ${#sample_version}"
else
    pass "sample version length is $max_version_len"
fi

# ---------------------------------------------------------------------------
# 2. Label ceiling: worst case for every product x suffix
# ---------------------------------------------------------------------------

worst_case_version=""
for ((i = 0; i < max_version_len; i++)); do
    worst_case_version+="9"
done

for product in "${products[@]}"; do
    for suffix in r v; do
        label="${product}_${worst_case_version}_${suffix}"
        len=${#label}
        if ((len > label_ceiling)); then
            fail_check "label ceiling: $label is $len code units, exceeds $label_ceiling"
        else
            pass "label ceiling: $label is $len code units (<= $label_ceiling)"
        fi
    done
done

# ---------------------------------------------------------------------------
# 3. Filename grammar self-test
# ---------------------------------------------------------------------------

sample_uuid="1e2d3c4b-0001-4a2b-8c3d-000000000000"

assert_matches "snow-ab_${sample_version}_${sample_uuid}.root.raw.xz" "$root_raw_re" "root.raw.xz good"
assert_no_match "snow-ab_${sample_version}_${sample_uuid}.root-verity.raw.xz" "$root_raw_re" "root.raw.xz rejects verity name"
assert_no_match "cayo_${sample_version}_${sample_uuid}.root.raw.xz" "$root_raw_re" "root.raw.xz rejects missing -ab"
assert_no_match "snow-ab_2026071415_${sample_uuid}.root.raw.xz" "$root_raw_re" "root.raw.xz rejects short version"

assert_matches "snow-ab_${sample_version}_${sample_uuid}.root-verity.raw.xz" "$root_verity_raw_re" "root-verity.raw.xz good"
assert_no_match "snow-ab_${sample_version}_${sample_uuid}.root.raw.xz" "$root_verity_raw_re" "root-verity.raw.xz rejects root name"

assert_matches "snowfield-ab_${sample_version}.efi" "$efi_re" "efi good"
assert_no_match "snowfield-ab_${sample_version}.efi.xz" "$efi_re" "efi rejects trailing extension"
assert_no_match "snowfield-ab_${sample_version}+r1.efi" "$efi_re" "efi rejects suffixed version"

assert_matches "cayo-ab_${sample_version}.disk.raw.xz" "$disk_raw_re" "disk.raw.xz good"
assert_no_match "cayo-ab_${sample_version}.disk.raw" "$disk_raw_re" "disk.raw.xz rejects missing .xz"

assert_matches "cayo-ab_${sample_version}.manifest.json" "$manifest_re" "manifest.json good"
assert_no_match "cayo-ab_${sample_version}.manifest.yaml" "$manifest_re" "manifest.json rejects wrong extension"

assert_matches "cayo-ab_${sample_version}.sbom.spdx.json" "$sbom_re" "sbom.spdx.json good"
assert_no_match "cayo-ab_${sample_version}.sbom.json" "$sbom_re" "sbom.spdx.json rejects missing .spdx"

# ---------------------------------------------------------------------------
# Allowlist plumbing
# ---------------------------------------------------------------------------

# actual_violations / allow_entries hold "<path> <tag>" strings.
actual_violations=()
allow_entries=()

record_violation() { # path tag
    actual_violations+=("$1 $2")
}

if [[ -f "$allowlist_file" ]]; then
    while IFS= read -r line; do
        # Strip comments and blank lines.
        stripped="${line%%#*}"
        stripped="${stripped#"${stripped%%[![:space:]]*}"}"
        stripped="${stripped%"${stripped##*[![:space:]]}"}"
        [[ -z "$stripped" ]] && continue
        allow_entries+=("$stripped")
    done < "$allowlist_file"
else
    fail_check "allowlist file missing: $allowlist_file"
fi

contains() { # needle array-name
    local needle="$1" name="$2[@]"
    local item
    for item in "${!name}"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# 4. *.transfer scan: OS transfers vs sysext (component-topology) transfers
# ---------------------------------------------------------------------------

ini_get() { # file section key
    awk -v section="$2" -v key="$3" '
        /^\[.*\]$/ { insec = ($0 == "["section"]") ; next }
        insec && index($0, key "=") == 1 { sub("^" key "=", ""); print; exit }
    ' "$1"
}

transfer_files=()
while IFS= read -r -d '' f; do
    transfer_files+=("$f")
done < <(find shared \
    mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d \
    mkosi.images/base/mkosi.extra/usr/lib/sysupdate.*.d \
    -name '*.transfer' -print0 2>/dev/null | sort -z)

if [[ ${#transfer_files[@]} -eq 0 ]]; then
    fail_check "transfer scan: found no *.transfer files (scan paths wrong?)"
else
    pass "transfer scan: found ${#transfer_files[@]} *.transfer files"
fi

for f in "${transfer_files[@]}"; do
    relpath="${f#"$root"/}"
    target_type="$(ini_get "$f" Target Type)"
    target_path="$(ini_get "$f" Target Path)"

    is_os_transfer=0
    if [[ "$target_type" == "partition" ]]; then
        is_os_transfer=1
    elif [[ "$target_type" == "regular-file" && "$target_path" == "/EFI/Linux" ]]; then
        is_os_transfer=1
    fi

    if ((is_os_transfer)); then
        verify="$(ini_get "$f" Transfer Verify)"
        if [[ "$verify" != "yes" ]]; then
            record_violation "$relpath" "missing-verify"
        fi

        source_path="$(ini_get "$f" Source Path)"
        match_pattern="$(ini_get "$f" Source MatchPattern)"
        # Source MatchPattern is channel-prefixed (<ImageId>-ab_@v...), not
        # product-prefixed -- derive the product by stripping the frozen
        # "-ab" channel suffix (docs/native-ab-contracts.md §1, §5).
        channel="$(sed -E 's/^([a-z]+-ab)_@v.*/\1/' <<<"$match_pattern")"
        product="${channel%-ab}"
        if [[ -z "$channel" || "$channel" == "$match_pattern" ]]; then
            record_violation "$relpath" "unparseable-match-pattern"
        else
            expected_prefix="${os_url_prefix}/${product}/x86-64/"
            if [[ "$source_path" != "$expected_prefix" ]]; then
                record_violation "$relpath" "legacy-url"
            fi
        fi
    else
        dirbase="$(basename "$(dirname "$f")")"
        if [[ "$dirbase" == "sysupdate.d" ]]; then
            record_violation "$relpath" "component-migration"
        fi
    fi
done

# ---------------------------------------------------------------------------
# 4b. Sysext component directory shape: every
#     mkosi.images/base/mkosi.extra/usr/lib/sysupdate.<name>.d/ must contain
#     exactly one <name>.transfer and one <name>.feature, and <name> must be
#     a safe component-name string.
# ---------------------------------------------------------------------------

component_name_re='^[a-zA-Z0-9_-]+$'
sysupdate_base_dir="mkosi.images/base/mkosi.extra/usr/lib"

component_dirs=()
while IFS= read -r -d '' d; do
    component_dirs+=("$d")
done < <(find "$sysupdate_base_dir" -mindepth 1 -maxdepth 1 -type d -name 'sysupdate.*.d' \
    -print0 2>/dev/null | sort -z)

if [[ ${#component_dirs[@]} -eq 0 ]]; then
    fail_check "component dir scan: found no $sysupdate_base_dir/sysupdate.*.d directories"
else
    pass "component dir scan: found ${#component_dirs[@]} sysupdate.<name>.d directories"
fi

for d in "${component_dirs[@]}"; do
    relpath="${d#"$root"/}"
    dirname_only="$(basename "$d")"
    name="${dirname_only#sysupdate.}"
    name="${name%.d}"

    if [[ ! "$name" =~ $component_name_re ]]; then
        fail_check "component dir naming: $relpath component name '$name' does not match $component_name_re"
        continue
    fi

    entries=()
    while IFS= read -r -d '' e; do
        entries+=("$(basename "$e")")
    done < <(find "$d" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | sort -z)

    entries_sorted="$(printf '%s\n' "${entries[@]}" | sort)"
    expected_sorted="$(printf '%s\n' "$name.feature" "$name.transfer" | sort)"

    if [[ "$entries_sorted" == "$expected_sorted" ]]; then
        pass "component dir shape: $relpath contains exactly $name.transfer + $name.feature"
    else
        fail_check "component dir shape: $relpath expected {$name.feature, $name.transfer}, found {${entries[*]:-empty}}"
    fi
done

# ---------------------------------------------------------------------------
# 5. Profile-name publishability check
# ---------------------------------------------------------------------------

for name in cayo-ab snow-ab snowfield-ab; do
    conf="mkosi.profiles/$name/mkosi.conf"
    [[ -f "$conf" ]] || continue
    # Phase 3: the config markers live in the shared, includable
    # shared/native-ab-secure/mkosi.conf fragment, not restated in each
    # profile's own file (see check-native-publication-guard.sh, which
    # follows the same reachability rule: this is a plain textual
    # reachability check on this one documented fragment, not a general
    # Include= resolver).
    combined="$(cat "$conf")"
    if grep -q 'shared/native-ab-secure' "$conf"; then
        combined+=$'\n'
        combined+="$(find "$root/shared/native-ab-secure" -type f -exec cat {} + 2>/dev/null || true)"
    fi
    ok=1
    grep -q '^SecureBoot=yes$' <<<"$combined" || ok=0
    grep -q '^ShimBootloader=signed$' <<<"$combined" || ok=0
    grep -q '^SignExpectedPcr=yes$' <<<"$combined" || ok=0
    if ((ok)); then
        pass "profile publishability: $conf satisfies the config-marker subset of the guard"
    else
        record_violation "$conf" "pending-rename"
    fi
done

# ---------------------------------------------------------------------------
# 6. GPT label check of actual repart definitions
# ---------------------------------------------------------------------------

repart_files=()
while IFS= read -r -d '' f; do
    repart_files+=("$f")
done < <(find shared -path '*/mkosi.repart/*.conf' -print0 2>/dev/null | sort -z)

if [[ ${#repart_files[@]} -eq 0 ]]; then
    fail_check "repart scan: found no shared/**/mkosi.repart/*.conf files"
else
    pass "repart scan: found ${#repart_files[@]} repart definitions"
fi

for f in "${repart_files[@]}"; do
    relpath="${f#"$root"/}"
    label_tmpl="$(grep -m1 '^Label=' "$f" | sed 's/^Label=//' || true)"
    [[ -z "$label_tmpl" ]] && continue
    [[ "$label_tmpl" == *"%A"* ]] || continue

    substituted="${label_tmpl//%A/$sample_version}"
    len=${#substituted}
    if ((len > label_ceiling)); then
        record_violation "$relpath" "pending-label-shortening"
    else
        pass "repart label: $relpath -> '$substituted' is $len code units (<= $label_ceiling)"
    fi
done

# ---------------------------------------------------------------------------
# 7. Channel fragment shape: shared/native-ab/channels/<product>/ carries the
#    6 repart defs + 3 OS transfers, ESP sized 1G, ImageId-based labels and
#    SplitNames; the generic shared/outformat/ab-root/ fragment carries none
#    of that (product-neutral disk/boot mechanics only).
# ---------------------------------------------------------------------------

expected_repart_defs=(00-esp.conf 10-root-verity.conf 11-root.conf
    20-root-verity-empty.conf 21-root-empty.conf 30-var.conf)
expected_transfers=(10-root-verity.transfer 20-root.transfer 90-uki.transfer)

for product in "${products[@]}"; do
    channel_dir="shared/native-ab/channels/$product"

    if [[ ! -d "$channel_dir" ]]; then
        fail_check "channel shape: $channel_dir does not exist"
        continue
    fi

    for def in "${expected_repart_defs[@]}"; do
        f="$channel_dir/mkosi.repart/$def"
        if [[ -f "$f" ]]; then
            pass "channel shape: $f present"
        else
            fail_check "channel shape: $f missing"
        fi
    done

    for tr in "${expected_transfers[@]}"; do
        f="$channel_dir/tree/usr/lib/sysupdate.d/$tr"
        if [[ -f "$f" ]]; then
            pass "channel shape: $f present"
        else
            fail_check "channel shape: $f missing"
        fi
    done

    # The 3 transfers above are only real once the channel's own tree/ is
    # actually wired via ExtraTrees= -- RepartDirectories= alone does not
    # compose it (caught live: native-ab-components-test.sh failed with
    # /usr/lib/sysupdate.d/ missing entirely from a built image because this
    # line was absent).
    channel_conf="$channel_dir/mkosi.conf"
    if [[ -f "$channel_conf" ]] && grep -qF "ExtraTrees=%D/$channel_dir/tree" "$channel_conf"; then
        pass "channel wiring: $channel_conf sets ExtraTrees= for its own tree/"
    else
        fail_check "channel wiring: $channel_conf does not set ExtraTrees=%D/$channel_dir/tree -- the channel's sysupdate.d transfers would never reach a built image"
    fi

    esp_conf="$channel_dir/mkosi.repart/00-esp.conf"
    if [[ -f "$esp_conf" ]]; then
        esp_min="$(ini_get "$esp_conf" Partition SizeMinBytes)"
        esp_max="$(ini_get "$esp_conf" Partition SizeMaxBytes)"
        if [[ "$esp_min" == "1G" && "$esp_max" == "1G" ]]; then
            pass "channel ESP size: $esp_conf is 1G/1G"
        else
            fail_check "channel ESP size: $esp_conf is ${esp_min:-<unset>}/${esp_max:-<unset>}, expected 1G/1G"
        fi
    fi

    root_verity_conf="$channel_dir/mkosi.repart/10-root-verity.conf"
    root_conf="$channel_dir/mkosi.repart/11-root.conf"
    if [[ -f "$root_verity_conf" ]]; then
        label="$(ini_get "$root_verity_conf" Partition Label)"
        if [[ "$label" == "${product}_%A_v" ]]; then
            pass "channel label: $root_verity_conf -> '$label'"
        else
            fail_check "channel label: $root_verity_conf -> '${label:-<unset>}', expected '${product}_%A_v'"
        fi
        split="$(ini_get "$root_verity_conf" Partition SplitName)"
        if [[ "$split" == "${product}_@v.root-verity.raw" ]]; then
            pass "channel SplitName: $root_verity_conf -> '$split'"
        else
            fail_check "channel SplitName: $root_verity_conf -> '${split:-<unset>}', expected '${product}_@v.root-verity.raw' (ImageId-based, not channel-based -- public artifact names come from the publisher, not mkosi's internal split output)"
        fi
    fi
    if [[ -f "$root_conf" ]]; then
        label="$(ini_get "$root_conf" Partition Label)"
        if [[ "$label" == "${product}_%A_r" ]]; then
            pass "channel label: $root_conf -> '$label'"
        else
            fail_check "channel label: $root_conf -> '${label:-<unset>}', expected '${product}_%A_r'"
        fi
        split="$(ini_get "$root_conf" Partition SplitName)"
        if [[ "$split" == "${product}_@v.root.raw" ]]; then
            pass "channel SplitName: $root_conf -> '$split'"
        else
            fail_check "channel SplitName: $root_conf -> '${split:-<unset>}', expected '${product}_@v.root.raw'"
        fi
    fi
done

generic_conf="shared/outformat/ab-root/mkosi.conf"
if grep -q '^RepartDirectories=' "$generic_conf"; then
    fail_check "generic fragment: $generic_conf must not carry RepartDirectories= (product-specific, moved to channels)"
else
    pass "generic fragment: $generic_conf carries no RepartDirectories="
fi
if grep -q '^KernelModules=' "$generic_conf"; then
    fail_check "generic fragment: $generic_conf must not carry KernelModules= (docs/native-ab-contracts.md §9)"
else
    pass "generic fragment: $generic_conf carries no KernelModules="
fi
generic_transfers=()
while IFS= read -r -d '' f; do
    generic_transfers+=("$f")
done < <(find shared/outformat/ab-root -name '*.transfer' -print0 2>/dev/null)
if [[ ${#generic_transfers[@]} -eq 0 ]]; then
    pass "generic fragment: shared/outformat/ab-root carries no *.transfer files"
else
    fail_check "generic fragment: shared/outformat/ab-root carries *.transfer files (moved to channels): ${generic_transfers[*]}"
fi
if [[ -d shared/outformat/ab-root/mkosi.repart ]]; then
    fail_check "generic fragment: shared/outformat/ab-root/mkosi.repart must not exist (product-specific, moved to channels)"
else
    pass "generic fragment: shared/outformat/ab-root carries no mkosi.repart directory"
fi

# ---------------------------------------------------------------------------
# Reconcile actual violations against the allowlist
# ---------------------------------------------------------------------------

for v in "${actual_violations[@]}"; do
    if contains "$v" allow_entries; then
        pass "allowlisted deviation: $v"
    else
        fail_check "unallowlisted contract violation: $v (add to $allowlist_file with a reason tag, or fix it)"
    fi
done

for e in "${allow_entries[@]}"; do
    path="${e%% *}"
    if [[ ! -e "$path" ]]; then
        fail_check "stale allowlist entry (file no longer exists): $e"
        continue
    fi
    if ! contains "$e" actual_violations; then
        fail_check "stale allowlist entry (no longer violates): $e"
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
if ((fail)); then
    echo "native-ab-contracts-test: FAILED ($checks checks run)" >&2
    exit 1
fi
echo "native-ab-contracts-test: PASSED ($checks checks run)"
