#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Fixture test for shared/outformat/ab-root/tree/usr/libexec/snosi-firstboot:
# PATH-stubbed updex/flatpak record their invocations; seed/done/core.json
# paths come from the script's test-only env overrides. Covers: the no-seed
# and already-done no-ops, feature enablement fan-out, flathub remote + core
# set (deduplicated), retry semantics (any failure -> exit 1, NO done
# marker), and the success marker. No root, no network, no image build.
#
# Usage: ./test/snosi-firstboot-test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/shared/outformat/ab-root/tree/usr/libexec/snosi-firstboot"

PASS=0
FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1" "expected '$3', got '$2'"; }
assert_file() { [[ -f "$2" ]] && pass "$1" || fail "$1" "missing $2"; }
assert_no_file() { [[ ! -f "$2" ]] && pass "$1" || fail "$1" "unexpected $2"; }

WORK_DIR="$(mktemp -d /var/tmp/snosi-firstboot-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- PATH stubs -------------------------------------------------------------
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/updex" <<EOF
#!/bin/bash
echo "updex \$*" >>"$WORK_DIR/calls.log"
[[ ! -f "$WORK_DIR/updex-fail" ]] || exit 1
EOF
cat >"$WORK_DIR/bin/flatpak" <<EOF
#!/bin/bash
echo "flatpak \$*" >>"$WORK_DIR/calls.log"
[[ ! -f "$WORK_DIR/flatpak-fail" ]] || exit 1
EOF
chmod +x "$WORK_DIR/bin/updex" "$WORK_DIR/bin/flatpak"

# core.json fixture with a deliberate duplicate (the real list has carried
# them) -- the script must dedup.
cat >"$WORK_DIR/core.json" <<'EOF'
{"core": [
  {"name": "A", "id": "org.example.A"},
  {"name": "B", "id": "org.example.B"},
  {"name": "A again", "id": "org.example.A"}
]}
EOF

run_fb() { # seed-file
    : >"$WORK_DIR/calls.log"
    set +e
    # shellcheck disable=SC2034 # RUN_OUT kept for debugging failed asserts
    RUN_OUT="$(PATH="$WORK_DIR/bin:$PATH" \
        SNOSI_FIRSTBOOT_SEED="$1" \
        SNOSI_FIRSTBOOT_DONE="$WORK_DIR/done" \
        SNOSI_FIRSTBOOT_CORE_JSON="$WORK_DIR/core.json" \
        bash "$SCRIPT" 2>&1)"
    RUN_RC=$?
    set -e
}

echo "=== no-op paths ==="
run_fb "$WORK_DIR/absent.json"
assert_eq "no seed: exit 0" "$RUN_RC" "0"
assert_no_file "no seed: no done marker" "$WORK_DIR/done"

echo "=== full success path ==="
cat >"$WORK_DIR/seed.json" <<'EOF'
{"features": ["docker", "tailscale"], "core_flatpaks": true}
EOF
run_fb "$WORK_DIR/seed.json"
assert_eq "success: exit 0" "$RUN_RC" "0"
assert_file "success: done marker written" "$WORK_DIR/done"
assert_eq "success: both features enabled" \
    "$(grep -c '^updex --silent features enable' "$WORK_DIR/calls.log")" "2"
assert_eq "success: docker enabled with --now" \
    "$(grep -c '^updex --silent features enable docker --now$' "$WORK_DIR/calls.log")" "1"
assert_eq "success: flathub remote added" \
    "$(grep -c '^flatpak remote-add --system --if-not-exists flathub' "$WORK_DIR/calls.log")" "1"
assert_eq "success: core set installed DEDUPLICATED (2 unique ids)" \
    "$(grep -c '^flatpak install --system --noninteractive --or-update -y flathub' "$WORK_DIR/calls.log")" "2"

run_fb "$WORK_DIR/seed.json"
assert_eq "already done: exit 0" "$RUN_RC" "0"
assert_eq "already done: nothing invoked" "$(wc -l <"$WORK_DIR/calls.log")" "0"

echo "=== retry semantics ==="
rm -f "$WORK_DIR/done"
touch "$WORK_DIR/updex-fail"
run_fb "$WORK_DIR/seed.json"
assert_eq "updex failure: exit 1" "$RUN_RC" "1"
assert_no_file "updex failure: done marker NOT written" "$WORK_DIR/done"
assert_eq "updex failure: flatpaks still attempted (no early abort)" \
    "$(grep -c '^flatpak install' "$WORK_DIR/calls.log")" "2"
rm -f "$WORK_DIR/updex-fail"

touch "$WORK_DIR/flatpak-fail"
run_fb "$WORK_DIR/seed.json"
assert_eq "flatpak failure: exit 1" "$RUN_RC" "1"
assert_no_file "flatpak failure: done marker NOT written" "$WORK_DIR/done"
rm -f "$WORK_DIR/flatpak-fail"

echo "=== features-only seed (cayo shape) ==="
cat >"$WORK_DIR/seed2.json" <<'EOF'
{"features": ["incus"], "core_flatpaks": false}
EOF
run_fb "$WORK_DIR/seed2.json"
assert_eq "features-only: exit 0" "$RUN_RC" "0"
assert_eq "features-only: no flatpak calls" "$(grep -c '^flatpak' "$WORK_DIR/calls.log" || true)" "0"
assert_file "features-only: done marker written" "$WORK_DIR/done"

echo ""
echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
[[ "$FAIL" -eq 0 ]]
