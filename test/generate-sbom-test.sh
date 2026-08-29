#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Offline fixture test for shared/native-ab/publish/generate-sbom.sh.
#
# generate-sbom.sh derives a real SPDX 2.3 JSON SBOM from an mkosi
# ManifestFormat=json manifest (docs/native-ab-contracts.md §4). Until now the
# only coverage of it was the happy-path assertion in
# test/native-publication-pipeline-test.sh (it runs prepare-native-publication.sh
# end-to-end and checks that a valid sbom.spdx.json with >=1 package lands). That
# integration path never exercises the script directly, so none of its own
# validation branches or its SPDX structure/purl/SPDXID logic were tested:
#
#   - input validation: arg count/usage (exit 2), missing manifest (exit 1),
#     version not matching the 14-digit grammar (exit 1)
#   - SPDX document shape: spdxVersion/dataLicense, DOCUMENT->root DESCRIBES,
#     root->package CONTAINS relationships, root primaryPackagePurpose
#   - per-package handling: purl for deb vs. the generic fallback for other
#     types, SPDXID charset sanitization, duplicate-name SPDXID de-duplication,
#     skipping of nameless manifest entries
#   - atomic write: no leftover temp file next to the destination
#
# The script deliberately needs no external SBOM tool (syft etc.), so this test
# runs fully offline with a fake manifest fixture; it only needs jq + python3,
# which the script itself requires.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SBOM="$REPO_ROOT/shared/native-ab/publish/generate-sbom.sh"

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

assert_true() { # description command...
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc" "command failed: $*"
    fi
}

assert_false() { # description command...
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$desc" "command unexpectedly succeeded: $*"
    else
        pass "$desc"
    fi
}

# assert_exit - assert a command exits with a specific status code.
assert_exit() { # description expected_code command...
    local desc="$1" want="$2"
    shift 2
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    assert_eq "$desc" "$got" "$want"
}

print_summary() {
    echo ""
    echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
    exit "$FAIL"
}

for command in jq python3; do
    command -v "$command" >/dev/null || {
        echo "1..0 # SKIP required command not found: $command"
        exit 0
    }
done

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

CHANNEL="testchan"
VERSION="20240101000000"

# A fake manifest exercising every per-package branch:
#   - a normal deb, a deb whose name has SPDXID-illegal characters,
#   - a duplicate name (must get a de-duplicated SPDXID),
#   - a non-deb type (must fall back to the generic purl type),
#   - a nameless entry (must be skipped).
MANIFEST="$WORK/manifest.json"
cat > "$MANIFEST" <<'EOF'
{"packages":[
 {"name":"bash","version":"5.2-1","architecture":"amd64","type":"deb"},
 {"name":"lib+weird","version":"1.0","architecture":"amd64","type":"deb"},
 {"name":"bash","version":"5.2-2","architecture":"amd64","type":"deb"},
 {"name":"mystery","version":"9","architecture":"noarch","type":"oci"},
 {"version":"nameless-should-be-skipped"}
]}
EOF

# --- input validation --------------------------------------------------------

echo "=== generate-sbom.sh: input validation ==="

assert_exit "usage/exit 2 with too few args" 2 \
    "$SBOM" "$MANIFEST" "$WORK/a.json"
assert_exit "usage/exit 2 with too many args" 2 \
    "$SBOM" "$MANIFEST" "$WORK/a.json" "$CHANNEL" "$VERSION" extra
assert_exit "exit 1 when manifest is missing" 1 \
    "$SBOM" "$WORK/does-not-exist.json" "$WORK/a.json" "$CHANNEL" "$VERSION"
assert_exit "exit 1 when version is not 14 digits" 1 \
    "$SBOM" "$MANIFEST" "$WORK/a.json" "$CHANNEL" "2024010100000"
assert_exit "exit 1 when version has a non-digit" 1 \
    "$SBOM" "$MANIFEST" "$WORK/a.json" "$CHANNEL" "2024010100000x"
assert_true "no output file left behind after a validation failure" \
    bash -c '[[ ! -e "$1" ]]' _ "$WORK/a.json"

# --- happy path: document shape ---------------------------------------------

echo "=== generate-sbom.sh: SPDX document shape ==="

OUT="$WORK/out.sbom.spdx.json"
assert_true "generates an SBOM for a valid manifest (exit 0)" \
    "$SBOM" "$MANIFEST" "$OUT" "$CHANNEL" "$VERSION"
assert_true "output exists" test -f "$OUT"
assert_true "output is valid JSON" jq -e . "$OUT"
assert_true "no leftover .tmp temp file next to the destination (atomic write)" \
    bash -c 'compgen -G "'"$OUT"'.*" >/dev/null && exit 1 || exit 0'

assert_eq "spdxVersion is SPDX-2.3" "$(jq -r '.spdxVersion' "$OUT")" "SPDX-2.3"
assert_eq "dataLicense is CC0-1.0" "$(jq -r '.dataLicense' "$OUT")" "CC0-1.0"
assert_eq "document SPDXID is SPDXRef-DOCUMENT" \
    "$(jq -r '.SPDXID' "$OUT")" "SPDXRef-DOCUMENT"
assert_eq "document name is <channel>-<version>" \
    "$(jq -r '.name' "$OUT")" "${CHANNEL}-${VERSION}"
assert_eq "documentNamespace is anchored at repository.frostyard.org" \
    "$(jq -r '.documentNamespace | startswith("https://repository.frostyard.org/spdx/'"$CHANNEL"'/'"$VERSION"'-")' "$OUT")" "true"

# --- root (operating-system) package ----------------------------------------

echo "=== generate-sbom.sh: root package + relationships ==="

ROOT_ID="$(jq -r '.relationships[] | select(.spdxElementId=="SPDXRef-DOCUMENT" and .relationshipType=="DESCRIBES") | .relatedSpdxElement' "$OUT")"
assert_eq "exactly one DOCUMENT DESCRIBES relationship to the root" \
    "$(jq -r '[.relationships[] | select(.spdxElementId=="SPDXRef-DOCUMENT" and .relationshipType=="DESCRIBES")] | length' "$OUT")" "1"
assert_eq "root package versionInfo matches the requested version" \
    "$(jq -r --arg id "$ROOT_ID" '.packages[] | select(.SPDXID==$id) | .versionInfo' "$OUT")" "$VERSION"
assert_eq "root package name is the channel" \
    "$(jq -r --arg id "$ROOT_ID" '.packages[] | select(.SPDXID==$id) | .name' "$OUT")" "$CHANNEL"
assert_eq "root package primaryPackagePurpose is OPERATING-SYSTEM" \
    "$(jq -r --arg id "$ROOT_ID" '.packages[] | select(.SPDXID==$id) | .primaryPackagePurpose' "$OUT")" "OPERATING-SYSTEM"

# --- per-package handling ----------------------------------------------------

echo "=== generate-sbom.sh: per-package purl / SPDXID / skip logic ==="

# root + 4 named packages (the nameless entry is skipped).
assert_eq "nameless manifest entry is skipped (root + 4 named = 5 packages)" \
    "$(jq -r '.packages | length' "$OUT")" "5"
assert_eq "every named package has a CONTAINS relationship from the root" \
    "$(jq -r --arg id "$ROOT_ID" '[.relationships[] | select(.spdxElementId==$id and .relationshipType=="CONTAINS")] | length' "$OUT")" "4"

assert_eq "deb package gets a deb purl with arch qualifier" \
    "$(jq -r '.packages[] | select(.name=="bash" and .versionInfo=="5.2-1") | .externalRefs[0].referenceLocator' "$OUT")" \
    "pkg:deb/debian/bash@5.2-1?arch=amd64"
assert_eq "non-deb package falls back to the generic purl type" \
    "$(jq -r '.packages[] | select(.name=="mystery") | .externalRefs[0].referenceLocator' "$OUT")" \
    "pkg:generic/debian/mystery@9?arch=noarch"

assert_eq "SPDXID charset is sanitized (lib+weird -> lib-weird)" \
    "$(jq -r '[.packages[].SPDXID | select(. == "SPDXRef-Package-lib-weird")] | length' "$OUT")" "1"
assert_eq "duplicate package name gets a de-duplicated SPDXID (-2 suffix)" \
    "$(jq -r '[.packages[].SPDXID | select(. == "SPDXRef-Package-bash-2")] | length' "$OUT")" "1"
assert_eq "all SPDXIDs are unique" \
    "$(jq -r '[.packages[].SPDXID] | (length) as $n | (unique | length) == $n' "$OUT")" "true"

# --- empty-manifest edge case -----------------------------------------------

echo "=== generate-sbom.sh: empty package list ==="

EMPTY="$WORK/empty.json"
echo '{"packages":[]}' > "$EMPTY"
OUT_EMPTY="$WORK/empty.sbom.spdx.json"
assert_true "generates an SBOM for an empty package list" \
    "$SBOM" "$EMPTY" "$OUT_EMPTY" "$CHANNEL" "$VERSION"
assert_eq "empty manifest still yields just the root package" \
    "$(jq -r '.packages | length' "$OUT_EMPTY")" "1"

print_summary
