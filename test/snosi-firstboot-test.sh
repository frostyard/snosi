#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Fixture test for shared/outformat/ab-root/tree/usr/libexec/snosi-firstboot:
# a PATH-stubbed updex records its invocations; seed/done paths come from the
# script's test-only env overrides. Covers: the no-seed and already-done
# no-ops, feature enablement fan-out, stale-catalog resilience, retry
# semantics (any failure -> exit 1, NO done marker), and the success marker.
# System Flatpaks are NOT this script's job anymore (firn provisions them at
# install time, ADR-0006); a regression guard checks core_flatpaks is ignored.
# No root, no network, no image build.
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
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1" "expected to find: $3"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && pass "$1" || fail "$1" "unexpected: $3"; }

WORK_DIR="$(mktemp -d /var/tmp/snosi-firstboot-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- PATH stubs -------------------------------------------------------------
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/updex" <<EOF
#!/bin/bash
echo "updex \$*" >>"$WORK_DIR/calls.log"
[[ ! -f "$WORK_DIR/updex-fail" ]] || exit 1
# "features list --json" answers with a fixed known set as a JSON array of
# {name,...} objects (the real updex --json shape), so the script's
# unknown-feature pre-check has something real to match against.
# (No backticks in this unquoted heredoc -- they would command-substitute.)
if [[ "\$*" == *"features list"* ]]; then
    if [[ -f "$WORK_DIR/updex-empty" ]]; then
        printf '[]\n'
    else
        printf '[{"name":"docker","enabled":false},{"name":"tailscale","enabled":false},{"name":"incus","enabled":false}]\n'
    fi
fi
EOF
# flatpak is deliberately NOT stubbed: the script must never invoke it. A
# stub on PATH would mask an accidental call; instead a bare `flatpak` would
# fail loudly if the removed code came back.
chmod +x "$WORK_DIR/bin/updex"

run_fb() { # seed-file
    : >"$WORK_DIR/calls.log"
    set +e
    # shellcheck disable=SC2034 # RUN_OUT kept for debugging failed asserts
    RUN_OUT="$(PATH="$WORK_DIR/bin:$PATH" \
        SNOSI_FIRSTBOOT_SEED="$1" \
        SNOSI_FIRSTBOOT_DONE="$WORK_DIR/done" \
        bash "$SCRIPT" 2>&1)"
    RUN_RC=$?
    set -e
}

echo "=== no-op paths ==="
run_fb "$WORK_DIR/absent.json"
assert_eq "no seed: exit 0" "$RUN_RC" "0"
assert_no_file "no seed: no done marker" "$WORK_DIR/done"

echo "=== full success path ==="
# core_flatpaks:true is present but must be IGNORED (firn owns flatpaks now).
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
assert_eq "regression: core_flatpaks ignored, no flatpak invoked" \
    "$(grep -c 'flatpak' "$WORK_DIR/calls.log" || true)" "0"
assert_not_contains "regression: done marker drops core_flatpaks field" \
    "$(cat "$WORK_DIR/done")" "core_flatpaks"
assert_contains "success: done marker records features" \
    "$(cat "$WORK_DIR/done")" 'features='

run_fb "$WORK_DIR/seed.json"
assert_eq "already done: exit 0" "$RUN_RC" "0"
assert_eq "already done: nothing invoked" "$(wc -l <"$WORK_DIR/calls.log")" "0"

echo "=== retry semantics ==="
rm -f "$WORK_DIR/done"
touch "$WORK_DIR/updex-fail"
run_fb "$WORK_DIR/seed.json"
assert_eq "updex failure: exit 1" "$RUN_RC" "1"
assert_no_file "updex failure: done marker NOT written" "$WORK_DIR/done"
rm -f "$WORK_DIR/updex-fail"

echo "=== unknown-feature skip (stale catalog resilience) ==="
rm -f "$WORK_DIR/done"
cat >"$WORK_DIR/seed3.json" <<'EOF3'
{"features": ["docker", "ghost-feature"]}
EOF3
run_fb "$WORK_DIR/seed3.json"
assert_eq "unknown feature: exit 0 (skipped, not failed)" "$RUN_RC" "0"
assert_file "unknown feature: done marker written (no retry-forever)" "$WORK_DIR/done"
assert_eq "unknown feature: known feature still enabled" \
    "$(grep -c '^updex --silent features enable docker --now$' "$WORK_DIR/calls.log")" "1"
assert_eq "unknown feature: ghost-feature never passed to enable" \
    "$(grep -c 'enable ghost-feature' "$WORK_DIR/calls.log" || true)" "0"
assert_contains "unknown feature: warning names it" "$RUN_OUT" "ghost-feature"
rm -f "$WORK_DIR/done"

echo "=== empty catalog fail-open (updex lists []) ==="
rm -f "$WORK_DIR/done"
touch "$WORK_DIR/updex-empty"
cat >"$WORK_DIR/seed4.json" <<'EOF4'
{"features": ["docker"]}
EOF4
run_fb "$WORK_DIR/seed4.json"
# known="" (empty []) disables the stale-feature pre-check: the seeded feature
# is passed straight to `enable` (fail-open), rather than being skipped.
assert_eq "empty catalog: exit 0" "$RUN_RC" "0"
assert_eq "empty catalog: feature still enabled (pre-check disabled)" \
    "$(grep -c '^updex --silent features enable docker --now$' "$WORK_DIR/calls.log")" "1"
rm -f "$WORK_DIR/updex-empty" "$WORK_DIR/done"

echo "=== features-only seed (cayo shape) ==="
cat >"$WORK_DIR/seed2.json" <<'EOF'
{"features": ["incus"]}
EOF
run_fb "$WORK_DIR/seed2.json"
assert_eq "features-only: exit 0" "$RUN_RC" "0"
assert_file "features-only: done marker written" "$WORK_DIR/done"

echo ""
echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
[[ "$FAIL" -eq 0 ]]
