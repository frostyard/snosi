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

assert_contains() { # description haystack needle
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1" "expected to find: $3"
    fi
}

# assert_no_tmp_leftovers description dir -- fails if any *.tmp temp file
# from the publisher's atomic-write scheme is still present under dir.
assert_no_tmp_leftovers() { # description dir
    local desc="$1" dir="$2" leftovers
    if [[ ! -d "$dir" ]]; then
        pass "$desc"
        return
    fi
    leftovers="$(find "$dir" -name '*.tmp' 2>/dev/null)"
    if [[ -z "$leftovers" ]]; then
        pass "$desc"
    else
        fail "$desc" "leftover temp files: $leftovers"
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

# build_fixture_dup_label - like build_fixture, but the disk's GPT has TWO
# partitions sharing the root label (exercises the finding-1 regression: two
# GPT partitions matching the same versioned label must not concatenate
# their PARTUUIDs into the output filename -- the publisher must fail
# loudly instead).
#
# Usage: build_fixture_dup_label <dir> <product> <profile-output-name> <version>
build_fixture_dup_label() {
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

start=34, size=50, type=L, name="${product}_${version}_r"
start=100, size=50, type=L, name="${product}_${version}_r"
start=200, size=50, type=L, name="${product}_${version}_v"
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
# 5. Negative: missing required artifact, one case per artifact class (root
#    split, verity split, disk raw, .efi, manifest) -- not just .efi.
# ---------------------------------------------------------------------------

missing_artifact_cases=(
    "efi|cayo-ab.efi"
    "root split|cayo-ab.cayo_@v.root.raw.raw"
    "verity split|cayo-ab.cayo_@v.root-verity.raw.raw"
    "disk raw|cayo-ab.raw"
    "manifest|cayo-ab.manifest"
)

missing_case_n=0
for case_entry in "${missing_artifact_cases[@]}"; do
    missing_case_n=$((missing_case_n + 1))
    case_desc="${case_entry%%|*}"
    case_relpath="${case_entry#*|}"

    fixture_dir="$WORK_DIR/fixture-missing-$missing_case_n"
    build_fixture "$fixture_dir" cayo cayo-ab "2026071415000${missing_case_n}"
    rm -f "$fixture_dir/$case_relpath"
    dest_dir="$WORK_DIR/dest-missing-$missing_case_n"

    set +e
    out="$("$PUBLISHER" "$fixture_dir" cayo-ab "$dest_dir" 2>&1)"
    rc=$?
    set -e
    echo "$out"
    if [[ $rc -ne 0 ]]; then
        pass "missing $case_desc artifact ($case_relpath) is rejected"
    else
        fail "missing $case_desc artifact ($case_relpath) is rejected" "publisher exited 0"
    fi
    assert_file_absent "missing $case_desc artifact: nothing published" "$dest_dir/cayo"
done

# ---------------------------------------------------------------------------
# 6. Negative: two GPT partitions sharing the same root label must be
#    rejected, not silently concatenated into the output filename (finding 1
#    regression coverage -- see require_single_partition() in the publisher).
# ---------------------------------------------------------------------------

fixture_duplabel="$WORK_DIR/fixture-duplabel"
build_fixture_dup_label "$fixture_duplabel" cayo cayo-ab 20260714150010
dest_duplabel="$WORK_DIR/dest-duplabel"
set +e
out_duplabel="$("$PUBLISHER" "$fixture_duplabel" cayo-ab "$dest_duplabel" 2>&1)"
rc_duplabel=$?
set -e
echo "$out_duplabel"
if [[ $rc_duplabel -ne 0 ]]; then
    pass "two GPT partitions sharing the root label are rejected"
else
    fail "two GPT partitions sharing the root label are rejected" "publisher exited 0"
fi
assert_contains "duplicate-label error names the exact match count" "$out_duplabel" "expected exactly 1 partition"
assert_file_absent "duplicate-label fixture: nothing published" "$dest_duplabel/cayo"

# ---------------------------------------------------------------------------
# 7. Negative: interrupted write leaves no final-named partial file (finding
#    2 regression coverage). A fake, deliberately slow `xz` stand-in is put
#    ahead of the real one on PATH: it writes a partial payload, signals
#    readiness via a sentinel file, then blocks. The harness waits for the
#    sentinel (i.e. waits until the publisher is genuinely mid-compression),
#    kills the fake-xz process directly -- the same failure shape as an
#    OOM-kill or ENOSPC mid-write, and the only way to actually interrupt a
#    foreground child, since bash defers a script's own trapped signals
#    until the current foreground command finishes -- and asserts the
#    publisher's atomic-write scheme left neither a truncated file under the
#    final public name nor a leftover temp file.
# ---------------------------------------------------------------------------

fixture_interrupt="$WORK_DIR/fixture-interrupt"
build_fixture "$fixture_interrupt" cayo cayo-ab 20260714150020
dest_interrupt="$WORK_DIR/dest-interrupt"

fakebin="$WORK_DIR/fakebin"
mkdir -p "$fakebin"
sentinel="$WORK_DIR/xz-sentinel"
cat > "$fakebin/xz" <<'EOF'
#!/bin/bash
# Fake slow xz stand-in for the interrupted-write test. The no-op EXIT trap
# below disables bash's "exec into last command" tail-call optimization, so
# this process keeps running as THIS script (matchable via `pgrep -f` by
# path) instead of being silently replaced in place by /usr/bin/sleep before
# the harness can find and kill it.
trap ':' EXIT
printf 'PARTIAL-DATA-NOT-REAL-XZ\n'
: > "${FAKE_XZ_SENTINEL:?}"
sleep 30
EOF
chmod +x "$fakebin/xz"
rm -f "$sentinel"

(
    PATH="$fakebin:$PATH"
    export PATH
    FAKE_XZ_SENTINEL="$sentinel"
    export FAKE_XZ_SENTINEL
    "$PUBLISHER" --xz "$fixture_interrupt" cayo-ab "$dest_interrupt" >"$WORK_DIR/interrupt-publisher.log" 2>&1
) &
interrupt_pid=$!

sentinel_ready=0
for _ in $(seq 1 100); do
    [[ -e "$sentinel" ]] && { sentinel_ready=1; break; }
    sleep 0.1
done

if [[ "$sentinel_ready" == 1 ]]; then
    pass "interrupted-write: fake xz reached the sentinel (mid-compression)"
else
    fail "interrupted-write: fake xz reached the sentinel (mid-compression)" "sentinel never appeared"
fi

fake_xz_pid="$(pgrep -f "$fakebin/xz" | head -1)"
if [[ -n "$fake_xz_pid" ]]; then
    kill -TERM "$fake_xz_pid"
    pass "interrupted-write: sent TERM to the in-flight fake xz process"
else
    fail "interrupted-write: sent TERM to the in-flight fake xz process" "could not find fake xz pid"
fi

set +e
wait "$interrupt_pid"
interrupt_rc=$?
set -e
cat "$WORK_DIR/interrupt-publisher.log"
if [[ $interrupt_rc -ne 0 ]]; then
    pass "interrupted-write: publisher exits non-zero when the compressor is killed"
else
    fail "interrupted-write: publisher exits non-zero when the compressor is killed" "publisher exited 0"
fi

# The root artifact is first in the write order, so it is the one caught
# mid-write. Compute the exact final name the same way the publisher does
# (same fixture, same GPT) so this is an exact-path check, not a glob that
# would trivially "pass" against a literal asterisk in the filename.
pub_dir_interrupt="$dest_interrupt/cayo/x86-64"
interrupt_root_uuid="$(jq -er '.partitiontable.partitions[] | select(.name == "cayo_20260714150020_r") | .uuid | ascii_downcase' \
    <(sfdisk --json "$fixture_interrupt/cayo-ab.raw"))"
assert_file_absent "interrupted-write: no final-named root artifact left behind" \
    "$pub_dir_interrupt/cayo-ab_20260714150020_${interrupt_root_uuid}.root.raw.xz"
assert_no_tmp_leftovers "interrupted-write: no leftover *.tmp files under dest" "$dest_interrupt"

# ---------------------------------------------------------------------------
# 8. Negative: usage errors
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
