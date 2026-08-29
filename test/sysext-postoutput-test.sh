#!/usr/bin/env bash
# Fixture test for shared/sysext/postoutput/sysext-postoutput.sh.
#
# The script under test is a mkosi postoutput hook for sysext images. Driven
# entirely by environment variables (KEYPACKAGE, OUTPUTDIR, IMAGE_ID, RELEASE,
# and optional SYSEXT_REVISION) plus a JSON manifest in $OUTPUTDIR, it:
#   - validates that KEYPACKAGE is set and a "$IMAGE_ID.manifest" file exists,
#   - extracts the key package version and architecture from the manifest,
#   - encodes a Debian epoch ("5:1.2.3" -> "5+1.2.3") and appends an optional
#     "+rN" snosi revision,
#   - maps the mkosi RELEASE codename to a numeric OS_VERSION,
#   - copies the raw output to a versioned "<id>_<ver>_<os>_<arch>.<ext>" name,
#     repoints the "<id>" symlink at it, and writes a versioned manifest.
#
# Every branch here is network-free and root-free: fixtures are built in a
# throwaway $OUTPUTDIR and the script's own j/cp/ln/find calls operate only
# inside it. jq is a real dependency (already used across the suite).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=test/lib/helpers.sh
source "$SCRIPT_DIR/lib/helpers.sh"

SCRIPT="$REPO_ROOT/shared/sysext/postoutput/sysext-postoutput.sh"

WORKROOT="$(mktemp -d /var/tmp/sysext-postoutput-test.XXXXXX)"
trap 'rm -rf "$WORKROOT"' EXIT

IMAGE_ID="mysysext"
KEYPACKAGE="mypkg"

# write_manifest <dir> <version> <arch>
# Build a minimal mkosi-style manifest at <dir>/$IMAGE_ID.manifest. A "null"
# version or arch omits that field so the script's null checks fire.
write_manifest() {
    local dir="$1" version="$2" arch="$3"
    local pkg='[]' cfg='{}'
    if [[ "$version" != "null" ]]; then
        pkg=$(jq -n --arg n "$KEYPACKAGE" --arg v "$version" \
            '[{name:$n, version:$v}]')
    fi
    if [[ "$arch" != "null" ]]; then
        cfg=$(jq -n --arg a "$arch" '{architecture:$a}')
    fi
    jq -n --argjson packages "$pkg" --argjson config "$cfg" \
        '{packages:$packages, config:$config}' > "$dir/$IMAGE_ID.manifest"
}

# new_outputdir — a fresh, empty output directory for one scenario.
new_outputdir() {
    local d
    d="$(mktemp -d "$WORKROOT/out.XXXXXX")"
    printf '%s' "$d"
}

# run_postoutput <outputdir> — run the script with the given env, extra
# VAR=VALUE assignments may be prepended by the caller via `env`.
run_postoutput() {
    local outdir="$1"; shift
    # Defaults first, caller overrides ("$@") last so `env` gives them
    # precedence when the same variable (e.g. RELEASE) is reassigned.
    env \
        KEYPACKAGE="$KEYPACKAGE" \
        OUTPUTDIR="$outdir" \
        IMAGE_ID="$IMAGE_ID" \
        RELEASE="trixie" \
        "$@" \
        bash "$SCRIPT"
}

# expect_code <expected-exit> <cmd...> — succeeds iff cmd exits with the code.
expect_code() {
    local want="$1"; shift
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    [[ "$got" == "$want" ]]
}

# --- Input / manifest validation --------------------------------------------

missing_keypackage() {
    local out; out="$(new_outputdir)"
    env -u KEYPACKAGE OUTPUTDIR="$out" IMAGE_ID="$IMAGE_ID" RELEASE="trixie" \
        bash "$SCRIPT"
}
check "fails (exit 1) when KEYPACKAGE is unset" \
    expect_code 1 missing_keypackage

missing_manifest() {
    local out; out="$(new_outputdir)"
    run_postoutput "$out"
}
check "fails (exit 1) when no manifest file is present" \
    expect_code 1 missing_manifest

null_version() {
    local out; out="$(new_outputdir)"
    write_manifest "$out" null x86-64
    run_postoutput "$out"
}
check "fails (exit 1) when KEYPACKAGE version is absent from the manifest" \
    expect_code 1 null_version

null_arch() {
    local out; out="$(new_outputdir)"
    write_manifest "$out" 1.2.3 null
    : > "$out/$IMAGE_ID.raw"
    run_postoutput "$out"
}
check "fails (exit 1) when architecture is absent from the manifest config" \
    expect_code 1 null_arch

missing_output_file() {
    local out; out="$(new_outputdir)"
    write_manifest "$out" 1.2.3 x86-64
    run_postoutput "$out"
}
check "fails (exit 1) when no raw output file exists to rename" \
    expect_code 1 missing_output_file

# --- Happy path -------------------------------------------------------------

# happy_case <outdir> <version> <arch> <ext> [extra env...] — build a valid
# fixture and run the script, leaving artifacts in <outdir> for inspection.
happy_case() {
    local out="$1" version="$2" arch="$3" ext="$4"; shift 4
    write_manifest "$out" "$version" "$arch"
    printf 'payload' > "$out/$IMAGE_ID.$ext"
    run_postoutput "$out" "$@"
}

OUT_OK="$(new_outputdir)"
check "succeeds (exit 0) on a fully valid fixture" \
    expect_code 0 happy_case "$OUT_OK" 1.2.3 x86-64 raw

# trixie -> OS_VERSION 13; version 1.2.3; arch x86-64.
check "creates the versioned output file with mapped OS version" \
    test -f "$OUT_OK/${IMAGE_ID}_1.2.3_13_x86-64.raw"
check "repoints the <image-id> symlink at the versioned file" \
    test -L "$OUT_OK/$IMAGE_ID"
symlink_target_ok() {
    [[ "$(readlink "$OUT_OK/$IMAGE_ID")" == "${IMAGE_ID}_1.2.3_13_x86-64.raw" ]]
}
check "symlink target is the basename of the versioned file" symlink_target_ok
check "writes the versioned manifest" \
    test -f "$OUT_OK/$IMAGE_ID.1.2.3.manifest.json"
key_fields_ok() {
    local kp kv
    kp="$(jq -r '.config.key_package' "$OUT_OK/$IMAGE_ID.manifest")"
    kv="$(jq -r '.config.key_version' "$OUT_OK/$IMAGE_ID.manifest")"
    [[ "$kp" == "$KEYPACKAGE" && "$kv" == "1.2.3" ]]
}
check "records key_package and key_version in the manifest config" key_fields_ok

# --- Version transformation branches ----------------------------------------

OUT_EPOCH="$(new_outputdir)"
check "encodes a Debian epoch fixture (exit 0)" \
    expect_code 0 happy_case "$OUT_EPOCH" "5:1.2.3" x86-64 raw
check "epoch ':' is rewritten to '+' in the output filename" \
    test -f "$OUT_EPOCH/${IMAGE_ID}_5+1.2.3_13_x86-64.raw"

OUT_REV="$(new_outputdir)"
check "applies SYSEXT_REVISION fixture (exit 0)" \
    expect_code 0 happy_case "$OUT_REV" 1.2.3 x86-64 raw SYSEXT_REVISION=2
check "SYSEXT_REVISION appends '+rN' to the version" \
    test -f "$OUT_REV/${IMAGE_ID}_1.2.3+r2_13_x86-64.raw"

# --- RELEASE codename mapping -----------------------------------------------

OUT_FORKY="$(new_outputdir)"
check "maps RELEASE=forky to OS version 14" \
    expect_code 0 happy_case "$OUT_FORKY" 1.2.3 x86-64 raw RELEASE=forky
check "forky output file carries OS version 14" \
    test -f "$OUT_FORKY/${IMAGE_ID}_1.2.3_14_x86-64.raw"

OUT_UNKNOWN="$(new_outputdir)"
check "passes an unknown RELEASE codename through verbatim" \
    expect_code 0 happy_case "$OUT_UNKNOWN" 1.2.3 x86-64 raw RELEASE=exotic
check "unknown RELEASE is used as the OS version verbatim" \
    test -f "$OUT_UNKNOWN/${IMAGE_ID}_1.2.3_exotic_x86-64.raw"

# --- Compression-extension discovery ----------------------------------------

OUT_ZST="$(new_outputdir)"
check "discovers a compressed raw.zst output (exit 0)" \
    expect_code 0 happy_case "$OUT_ZST" 1.2.3 x86-64 raw.zst
check "preserves the raw.zst compression extension on the versioned file" \
    test -f "$OUT_ZST/${IMAGE_ID}_1.2.3_13_x86-64.raw.zst"

print_summary
