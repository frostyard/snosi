#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Static, non-root regression test for
# shared/native-ab/publish/prepare-native-publication.sh (docs/native-ab-
# contracts.md §4, §5). Builds a synthetic, tiny mkosi-output-dir fixture
# (fake GPT via `truncate` + `sfdisk` script mode -- no loop device, no
# root -- and a fake JSON manifest) so CI validates the naming/derivation
# logic without a real multi-gigabyte image build. Real usage against an
# actual cayo-ab build output is validated separately (see the phase 3
# task report; not part of this fast CI check).
#
# Usage: ./test/native-publish-test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISHER="$ROOT_DIR/shared/native-ab/publish/prepare-native-publication.sh"

WORK_DIR=""
PASS=0
FAIL=0

pass() { # description
    echo "ok - $1"
    PASS=$((PASS + 1))
}

fail() { # description [detail]
    echo "not ok - $1" >&2
    [[ $# -lt 2 ]] || echo "  $2" >&2
    FAIL=$((FAIL + 1))
}

assert_eq() { # description actual expected
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1" "expected '$3', got '$2'"
    fi
}

assert_file_exists() { # description path
    if [[ -f "$2" ]]; then
        pass "$1"
    else
        fail "$1" "missing: $2"
    fi
}

assert_file_absent() { # description path
    if [[ ! -e "$2" ]]; then
        pass "$1"
    else
        fail "$1" "unexpectedly present: $2"
    fi
}

cleanup() {
    [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for command in jq python3 sfdisk sha256sum git xz; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done

WORK_DIR="$(mktemp -d /var/tmp/native-publish-test.XXXXXX)"

# build_fixture - a plain-file GPT (sfdisk script mode, no root/loop device)
# plus a fake mkosi JSON manifest and dummy split artifacts, named exactly
# the way mkosi's own outputs are named for a profile whose Output= is
# $profile_output_name and whose ImageId is $product.
#
# Usage: build_fixture <dir> <product> <profile-output-name> <version>
build_fixture() {
    local dir="$1" product="$2" profile_output_name="$3" version="$4"
    mkdir -p "$dir"

    python3 - "$dir/$profile_output_name.manifest" "$product" "$version" <<'PYEOF'
import json, sys
path, product, version = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({"config": {"name": product, "version": version}}, open(path, "w"))
PYEOF

    printf 'root payload\n' > "$dir/$profile_output_name.${product}_@v.root.raw.raw"
    printf 'verity payload\n' > "$dir/$profile_output_name.${product}_@v.root-verity.raw.raw"
    printf 'efi payload\n' > "$dir/$profile_output_name.efi"
    truncate -s 2M "$dir/$profile_output_name.raw"

    cat > "$dir/sfdisk-script.txt" <<EOF
label: gpt
unit: sectors

start=34, size=100, type=L, name="${product}_${version}_r"
start=200, size=100, type=L, name="${product}_${version}_v"
EOF
    sfdisk "$dir/$profile_output_name.raw" < "$dir/sfdisk-script.txt" >/dev/null
}

# ---------------------------------------------------------------------------
# 1. Happy path, no --xz
# ---------------------------------------------------------------------------

fixture1="$WORK_DIR/fixture1"
build_fixture "$fixture1" cayo cayo-ab 20260714150000
dest1="$WORK_DIR/dest1"

out1="$("$PUBLISHER" "$fixture1" cayo-ab "$dest1" 2>&1)"
rc1=$?
echo "$out1"
assert_eq "no-xz run exits 0" "$rc1" "0"

pub_dir1="$dest1/cayo/x86-64"
root_uuid="$(jq -er '.partitiontable.partitions[] | select(.name == "cayo_20260714150000_r") | .uuid | ascii_downcase' <(sfdisk --json "$fixture1/cayo-ab.raw"))"
verity_uuid="$(jq -er '.partitiontable.partitions[] | select(.name == "cayo_20260714150000_v") | .uuid | ascii_downcase' <(sfdisk --json "$fixture1/cayo-ab.raw"))"

assert_file_exists "no-xz: root artifact present, no .xz suffix" \
    "$pub_dir1/cayo-ab_20260714150000_${root_uuid}.root.raw"
assert_file_absent "no-xz: root artifact has no .xz counterpart" \
    "$pub_dir1/cayo-ab_20260714150000_${root_uuid}.root.raw.xz"
assert_file_exists "no-xz: root-verity artifact present" \
    "$pub_dir1/cayo-ab_20260714150000_${verity_uuid}.root-verity.raw"
assert_file_exists "no-xz: disk artifact present, no .xz suffix" \
    "$pub_dir1/cayo-ab_20260714150000.disk.raw"
assert_file_exists "no-xz: efi artifact present" "$pub_dir1/cayo-ab_20260714150000.efi"
assert_file_exists "no-xz: manifest.json artifact present" "$pub_dir1/cayo-ab_20260714150000.manifest.json"
assert_file_exists "no-xz: SHA256SUMS present" "$pub_dir1/SHA256SUMS"
assert_file_absent "no-xz: SHA256SUMS.gpg NOT produced (unsigned; Phase 7 promotion step)" \
    "$pub_dir1/SHA256SUMS.gpg"
assert_file_exists "no-xz: publication-info.json present" "$pub_dir1/publication-info.json"

if (cd "$pub_dir1" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
    pass "no-xz: SHA256SUMS verifies against produced files"
else
    fail "no-xz: SHA256SUMS verifies against produced files"
fi

info_product="$(jq -er '.product' "$pub_dir1/publication-info.json")"
info_channel="$(jq -er '.channel' "$pub_dir1/publication-info.json")"
info_version="$(jq -er '.version' "$pub_dir1/publication-info.json")"
# Not -e: jq's -e flag treats a JSON `false` output as a failing exit status
# (documented jq behavior: exit 1 if the last output is false or null), and
# .xz is a real boolean here, not a "did jq find a value" probe.
info_xz="$(jq -r '.xz' "$pub_dir1/publication-info.json")"
info_root_uuid="$(jq -er '.partuuids.root' "$pub_dir1/publication-info.json")"
info_verity_uuid="$(jq -er '.partuuids.verity' "$pub_dir1/publication-info.json")"
assert_eq "publication-info.json product" "$info_product" "cayo"
assert_eq "publication-info.json channel" "$info_channel" "cayo-ab"
assert_eq "publication-info.json version" "$info_version" "20260714150000"
assert_eq "publication-info.json xz is false" "$info_xz" "false"
assert_eq "publication-info.json root partuuid matches GPT" "$info_root_uuid" "$root_uuid"
assert_eq "publication-info.json verity partuuid matches GPT" "$info_verity_uuid" "$verity_uuid"

# ---------------------------------------------------------------------------
# 2. Happy path, --xz: verify exact names against the frozen §4 grammar
#    (same regexes as test/native-ab-contracts-test.sh, kept in lockstep --
#    a naming drift in either script should fail CI).
# ---------------------------------------------------------------------------

channel_alt='(cayo|snow|snowfield)-ab'
version_re='[0-9]{14}'
uuid_re='[0-9a-fA-F-]+'
root_raw_re="^${channel_alt}_${version_re}_${uuid_re}\\.root\\.raw\\.xz\$"
root_verity_raw_re="^${channel_alt}_${version_re}_${uuid_re}\\.root-verity\\.raw\\.xz\$"
efi_re="^${channel_alt}_${version_re}\\.efi\$"
disk_raw_re="^${channel_alt}_${version_re}\\.disk\\.raw\\.xz\$"
manifest_re="^${channel_alt}_${version_re}\\.manifest\\.json\$"

dest2="$WORK_DIR/dest2"
out2="$("$PUBLISHER" --xz "$fixture1" cayo-ab "$dest2" 2>&1)"
rc2=$?
echo "$out2"
assert_eq "--xz run exits 0" "$rc2" "0"

pub_dir2="$dest2/cayo/x86-64"
root_name="cayo-ab_20260714150000_${root_uuid}.root.raw.xz"
verity_name="cayo-ab_20260714150000_${verity_uuid}.root-verity.raw.xz"
disk_name="cayo-ab_20260714150000.disk.raw.xz"
efi_name="cayo-ab_20260714150000.efi"
manifest_name="cayo-ab_20260714150000.manifest.json"

assert_file_exists "--xz: root.raw.xz present" "$pub_dir2/$root_name"
assert_file_exists "--xz: root-verity.raw.xz present" "$pub_dir2/$verity_name"
assert_file_exists "--xz: disk.raw.xz present" "$pub_dir2/$disk_name"
assert_file_exists "--xz: efi present" "$pub_dir2/$efi_name"
assert_file_exists "--xz: manifest.json present" "$pub_dir2/$manifest_name"

check_regex() { # description name regex
    if [[ "$2" =~ $3 ]]; then
        pass "$1"
    else
        fail "$1" "'$2' does not match $3"
    fi
}
check_regex "--xz root name matches frozen §4 grammar" "$root_name" "$root_raw_re"
check_regex "--xz root-verity name matches frozen §4 grammar" "$verity_name" "$root_verity_raw_re"
check_regex "--xz disk name matches frozen §4 grammar" "$disk_name" "$disk_raw_re"
check_regex "--xz efi name matches frozen §4 grammar" "$efi_name" "$efi_re"
check_regex "--xz manifest name matches frozen §4 grammar" "$manifest_name" "$manifest_re"

if (cd "$pub_dir2" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
    pass "--xz: SHA256SUMS verifies against produced (compressed) files"
else
    fail "--xz: SHA256SUMS verifies against produced (compressed) files"
fi

if (cd "$pub_dir2" && xz -t "$root_name" && xz -t "$verity_name" && xz -t "$disk_name"); then
    pass "--xz: root/verity/disk artifacts are valid xz streams"
else
    fail "--xz: root/verity/disk artifacts are valid xz streams"
fi

# ---------------------------------------------------------------------------
# 3. Negative: profile-output-name that is not a publishable channel (e.g.
#    the never-published *-ab-raw dev fixture) must be REJECTED, not
#    silently "published" under the wrong name.
# ---------------------------------------------------------------------------

fixture_raw="$WORK_DIR/fixture-raw"
build_fixture "$fixture_raw" cayo cayo-ab-raw 20260714150000
dest3="$WORK_DIR/dest3"
set +e
out3="$("$PUBLISHER" "$fixture_raw" cayo-ab-raw "$dest3" 2>&1)"
rc3=$?
set -e
echo "$out3"
if [[ $rc3 -ne 0 ]]; then
    pass "dev-fixture profile name (cayo-ab-raw) is rejected"
else
    fail "dev-fixture profile name (cayo-ab-raw) is rejected" "publisher exited 0"
fi
assert_file_absent "dev-fixture profile name: nothing published" "$dest3/cayo"

# ---------------------------------------------------------------------------
# 4. Negative: version grammar violation (docs/native-ab-contracts.md §2)
# ---------------------------------------------------------------------------

fixture_badver="$WORK_DIR/fixture-badver"
build_fixture "$fixture_badver" cayo cayo-ab 2026071415
dest4="$WORK_DIR/dest4"
set +e
out4="$("$PUBLISHER" "$fixture_badver" cayo-ab "$dest4" 2>&1)"
rc4=$?
set -e
echo "$out4"
if [[ $rc4 -ne 0 ]]; then
    pass "short (10-digit) version is rejected"
else
    fail "short (10-digit) version is rejected" "publisher exited 0"
fi

# ---------------------------------------------------------------------------
# 5. Negative: missing required split artifact
# ---------------------------------------------------------------------------

fixture_missing="$WORK_DIR/fixture-missing"
build_fixture "$fixture_missing" cayo cayo-ab 20260714150001
rm -f "$fixture_missing/cayo-ab.efi"
dest5="$WORK_DIR/dest5"
set +e
out5="$("$PUBLISHER" "$fixture_missing" cayo-ab "$dest5" 2>&1)"
rc5=$?
set -e
echo "$out5"
if [[ $rc5 -ne 0 ]]; then
    pass "missing .efi artifact is rejected"
else
    fail "missing .efi artifact is rejected" "publisher exited 0"
fi

# ---------------------------------------------------------------------------
# 6. Negative: usage errors
# ---------------------------------------------------------------------------

set +e
"$PUBLISHER" >/dev/null 2>&1
rc_usage=$?
set -e
if [[ $rc_usage -eq 2 ]]; then
    pass "no arguments exits with usage code 2"
else
    fail "no arguments exits with usage code 2" "got exit $rc_usage"
fi

echo ""
echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
exit "$FAIL"
