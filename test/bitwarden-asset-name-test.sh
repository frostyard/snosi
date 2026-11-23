#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# The weekly sysext bump must download the Bitwarden desktop .deb under the
# name upstream publishes. From desktop-v2026.11.0 every asset carries a
# license prefix: `oss-` (open source, before: no prefix) or `bit-`
# (commercial, before: `commercial-`). snosi pins the open-source build.
#
# This runs the real "Update sysext checksums" step of check-dependencies.yml
# with a curl stub that serves only the names in the recorded 2026.11.0 asset
# list (404 otherwise), so the old `Bitwarden-<v>-amd64.deb` name fails here
# as it failed in CI. No network.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/check-dependencies.yml"
ASSETS="$ROOT_DIR/test/fixtures/bitwarden/desktop-v2026.11.0-assets.txt"
VERSION=2026.11.0
RELEASE_URL="https://github.com/bitwarden/clients/releases/download/desktop-v${VERSION}"
EXPECTED_ASSET="oss-Bitwarden-${VERSION}-amd64.deb"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

extract_run_step() {
    local name=$1 output=$2
    awk -v header="      - name: $name" '
        $0 == header { in_step = 1; next }
        in_step && $0 == "        run: |" { found = 1; in_run = 1; next }
        in_run && $0 == "" { print; next }
        in_run && substr($0, 1, 10) == "          " { print substr($0, 11); next }
        in_run { exit }
        END { if (!found) exit 1 }
    ' "$WORKFLOW" >"$output"
}

# The recorded list must show the rename, or the cases below prove nothing.
if grep -qx "$EXPECTED_ASSET" "$ASSETS" &&
   grep -qx "bit-Bitwarden-${VERSION}-amd64.deb" "$ASSETS" &&
   ! grep -qx "Bitwarden-${VERSION}-amd64.deb" "$ASSETS" &&
   ! grep -qx "commercial-Bitwarden-${VERSION}-amd64.deb" "$ASSETS"; then
    pass 'recorded 2026.11.0 asset list has the oss-/bit- names and no unprefixed .deb'
else
    fail 'recorded 2026.11.0 asset list has the oss-/bit- names and no unprefixed .deb'
fi

if ! extract_run_step 'Update sysext checksums' "$work/update.sh" || [[ ! -s "$work/update.sh" ]]; then
    fail 'extract the "Update sysext checksums" step'
    printf '# Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi

# curl stub: like `curl -f`, exit 22 with no body unless the URL is an asset
# of the recorded release; the body names the asset, so the SHA-256 shows
# which asset the step pinned.
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'EOF'
#!/bin/bash
out=""
url=""
while (($#)); do
    case "$1" in
        -o) out=$2; shift ;;
        -H|-w|--max-time|--retry|--retry-delay) shift ;;
        -*) ;;
        *) url=$1 ;;
    esac
    shift
done
name=${url##*/}
if [[ "${url%/*}" == "$STUB_RELEASE_URL" ]] && grep -v '^#' "$STUB_ASSETS" | grep -qxF -- "$name"; then
    if [[ -n "$out" ]]; then
        printf 'fixture:%s\n' "$name" >"$out"
    else
        printf 'fixture:%s\n' "$name"
    fi
    exit 0
fi
echo "curl: (22) The requested URL returned error: 404" >&2
exit 22
EOF
chmod +x "$work/bin/curl"

# Run a copy of the step in a scratch tree holding a copy of the pins file.
run_step() { # script tree
    local script=$1 tree=$2
    mkdir -p "$tree/shared/download"
    cp "$ROOT_DIR/shared/download/sysext-checksums.json" "$tree/shared/download/"
    (
        cd "$tree"
        env -i PATH="$work/bin:$PATH" HOME="$work" \
            STUB_RELEASE_URL="$RELEASE_URL" STUB_ASSETS="$ASSETS" \
            GITHUB_OUTPUT="$tree/output" GH_TOKEN=dummy \
            BITWARDEN_UPDATE=true BITWARDEN_VERSION="$VERSION" \
            bash --noprofile --norc -eo pipefail "$script"
    ) >"$tree/log" 2>&1
}

pins="$work/new/shared/download/sysext-checksums.json"
if run_step "$work/update.sh" "$work/new"; then
    pass 'update step downloads the Bitwarden 2026.11.0 .deb from the recorded asset list'
else
    fail 'update step downloads the Bitwarden 2026.11.0 .deb from the recorded asset list'
    sed 's/^/# /' "$work/new/log" >&2
fi

expected_sha=$(printf 'fixture:%s\n' "$EXPECTED_ASSET" | sha256sum | cut -d' ' -f1)
if [[ -f "$pins" ]] &&
   [[ "$(jq -r '.bitwarden.url' "$pins")" == "$RELEASE_URL/$EXPECTED_ASSET" ]] &&
   [[ "$(jq -r '.bitwarden.sha256' "$pins")" == "$expected_sha" ]] &&
   [[ "$(jq -r '.bitwarden.version' "$pins")" == "$VERSION" ]]; then
    pass "bitwarden pin is the open-source build ($EXPECTED_ASSET), its SHA-256 and version"
else
    fail "bitwarden pin is the open-source build ($EXPECTED_ASSET), its SHA-256 and version"
fi

if [[ -f "$pins" ]] &&
   [[ "$(jq -S 'del(.bitwarden)' "$pins")" == "$(jq -S 'del(.bitwarden)' "$ROOT_DIR/shared/download/sysext-checksums.json")" ]]; then
    pass 'no other pin changes'
else
    fail 'no other pin changes'
fi

# Control: the pre-2026.11.0 name pattern must fail against the same list,
# as it did in CI (run 44986294775), or this test cannot catch a revert.
sed 's|/oss-Bitwarden-\${VER}-amd64\.deb"|/Bitwarden-${VER}-amd64.deb"|' "$work/update.sh" >"$work/update-old.sh"
if cmp -s "$work/update.sh" "$work/update-old.sh"; then
    fail 'control: rewrite the step to the old Bitwarden-<v>-amd64.deb name'
elif run_step "$work/update-old.sh" "$work/old"; then
    fail 'control: the old Bitwarden-<v>-amd64.deb name fails against the recorded asset list'
else
    pass 'control: the old Bitwarden-<v>-amd64.deb name fails against the recorded asset list'
fi

printf '# Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
