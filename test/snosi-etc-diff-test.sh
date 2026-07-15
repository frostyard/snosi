#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static, non-root regression test for snosi-etc-diff.
#
# Drives the real script against fixture "pristine"/"live" trees via the
# SNOSI_ETC_DIFF_LIVE_ETC / SNOSI_ETC_DIFF_PRISTINE_ETC test-hook env vars
# (undocumented in --help; see the script header). Setting BOTH bypasses
# native-ab/bootc detection entirely and relaxes the EUID==0 requirement,
# so this exercises list/diff/restore logic without root, a bind mount, or
# an image build. Detection itself (marker file / bind mount) is not
# covered here — that needs an actual booted image and is out of scope for
# a static test.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$PROJECT_ROOT/mkosi.images/base/mkosi.extra/usr/bin/snosi-etc-diff"
WORK_DIR=""
PASS=0
FAIL=0

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

record_pass() {
    echo "ok - $1"
    (( PASS++ )) || true
}

record_fail() {
    echo "not ok - $1"
    if [[ $# -gt 1 ]]; then
        echo "  $2" >&2
    fi
    (( FAIL++ )) || true
}

assert_contains() { # desc haystack needle
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        record_pass "$desc"
    else
        record_fail "$desc" "expected to find: $needle"
    fi
}

assert_not_contains() { # desc haystack needle
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        record_pass "$desc"
    else
        record_fail "$desc" "expected NOT to find: $needle"
    fi
}

assert_eq() { # desc actual expected
    local desc="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        record_pass "$desc"
    else
        record_fail "$desc" "expected '$expected', got '$actual'"
    fi
}

# run_diff ARGS... -- runs the real script against the fixture trees with
# detection bypassed, without root.
run_diff() {
    SNOSI_ETC_DIFF_LIVE_ETC="$LIVE" SNOSI_ETC_DIFF_PRISTINE_ETC="$PRISTINE" "$SCRIPT" "$@"
}

# build_fixtures DIR — populates DIR/pristine and DIR/live with:
#   modified.conf   content differs (M)
#   deleted.conf     only in pristine (D)
#   added.conf       only in live (A)
#   mylink           symlink target differs (M)
#   permfile.conf    same content, different mode (M)
#   unchanged.conf   identical everywhere (no report)
build_fixtures() { # dir
    local dir="$1"
    mkdir -p "$dir/pristine" "$dir/live"

    printf 'pristine body\n' >"$dir/pristine/modified.conf"
    printf 'live body\n' >"$dir/live/modified.conf"

    printf 'gone\n' >"$dir/pristine/deleted.conf"

    printf 'new\n' >"$dir/live/added.conf"

    ln -s target-a "$dir/pristine/mylink"
    ln -s target-b "$dir/live/mylink"

    printf 'same content\n' >"$dir/pristine/permfile.conf"
    printf 'same content\n' >"$dir/live/permfile.conf"
    chmod 644 "$dir/pristine/permfile.conf"
    chmod 600 "$dir/live/permfile.conf"

    printf 'no drift\n' >"$dir/pristine/unchanged.conf"
    printf 'no drift\n' >"$dir/live/unchanged.conf"
    chmod 644 "$dir/pristine/unchanged.conf" "$dir/live/unchanged.conf"
}

[[ -f "$SCRIPT" ]] || { echo "Error: script not found: $SCRIPT" >&2; exit 1; }
[[ $EUID -ne 0 ]] || echo "note: running as root; test hooks would relax this requirement anyway" >&2

WORK_DIR="$(mktemp -d)"
build_fixtures "$WORK_DIR/list"
LIVE="$WORK_DIR/list/live"
PRISTINE="$WORK_DIR/list/pristine"

echo "# snosi-etc-diff list mode (--machine)"

out="$(run_diff --machine)"
assert_contains "D entry for deleted.conf" "$out" "$(printf 'D\tdeleted.conf')"
assert_contains "M entry for modified.conf" "$out" "$(printf 'M\tmodified.conf')"
assert_contains "M entry for mylink (symlink target)" "$out" "$(printf 'M\tmylink')"
assert_contains "M entry for permfile.conf (permissions)" "$out" "$(printf 'M\tpermfile.conf')"
assert_not_contains "A entry hidden without --added" "$out" "added.conf"
assert_not_contains "unchanged.conf not reported" "$out" "unchanged.conf"

out_added="$(run_diff --machine --added)"
assert_contains "A entry for added.conf shown with --added" "$out_added" "$(printf 'A\tadded.conf')"

echo "# snosi-etc-diff list mode (human, no args)"
human_out="$(run_diff)"
assert_contains "human listing reports modified.conf" "$human_out" "M /etc/modified.conf"
assert_contains "human listing reports deleted.conf" "$human_out" "D /etc/deleted.conf"

echo "# snosi-etc-diff path mode (single-path diff)"

modified_out="$(run_diff /etc/modified.conf)"
assert_contains "path mode flags modified.conf as M" "$modified_out" "M /etc/modified.conf"
assert_contains "path mode shows unified diff body" "$modified_out" "-pristine body"
assert_contains "path mode shows unified diff body" "$modified_out" "+live body"

deleted_out="$(run_diff /etc/deleted.conf)"
assert_contains "path mode flags deleted.conf as D" "$deleted_out" "D /etc/deleted.conf (deleted locally"

added_out="$(run_diff /etc/added.conf)"
assert_contains "path mode flags added.conf as A" "$added_out" "A /etc/added.conf (not in the image"

link_out="$(run_diff /etc/mylink)"
assert_contains "path mode flags mylink as M (symlink target)" "$link_out" "M /etc/mylink (symlink target)"

unchanged_out="$(run_diff /etc/unchanged.conf)"
assert_contains "path mode reports unchanged.conf as matching" "$unchanged_out" "/etc/unchanged.conf matches the image"

echo "# snosi-etc-diff --restore"

# Fresh copy so restore mutations don't affect the assertions above.
build_fixtures "$WORK_DIR/restore"
LIVE="$WORK_DIR/restore/live"
PRISTINE="$WORK_DIR/restore/pristine"

run_diff --restore /etc/modified.conf >/dev/null
assert_eq "restore overwrites modified.conf with pristine content" \
    "$(cat "$LIVE/modified.conf")" "pristine body"

run_diff --restore /etc/deleted.conf >/dev/null
assert_eq "restore recreates deleted.conf from pristine" \
    "$(cat "$LIVE/deleted.conf")" "gone"

run_diff --restore /etc/permfile.conf >/dev/null
restored_mode="$(stat -c '%a' "$LIVE/permfile.conf")"
assert_eq "restore fixes permfile.conf mode to match pristine" "$restored_mode" "644"

if run_diff --restore /etc/added.conf >/dev/null 2>"$WORK_DIR/restore-added.err"; then
    record_fail "restore refuses a locally-added path (not in the image)"
else
    record_pass "restore refuses a locally-added path (not in the image)"
fi
assert_contains "restore-refusal error names the path" \
    "$(cat "$WORK_DIR/restore-added.err")" "not in the image"

echo "# snosi-etc-diff resolve_pristine cleanup contract (real bootc bind-mount branch)"

# Unlike everything above, this drives the REAL bootc code path (no test
# hooks set), i.e. resolve_pristine()'s bind-mount + EXIT trap. That needs
# root (bind-mount + the script's own EUID check) and must never bind-mount
# the host's real /. So we run a wrapper copy of the script with the
# `mount --bind ... /` line's source swapped for a throwaway fixture
# directory that stands in for "/", and let the wrapper's own resolve_pristine
# bind-mount THAT.
HAVE_ROOT=0
SUDO=()
if [[ $EUID -eq 0 ]]; then
    HAVE_ROOT=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    HAVE_ROOT=1
    SUDO=(sudo -n)
fi

if [[ -e /usr/lib/snosi/native-ab ]]; then
    echo "ok - resolve_pristine cleanup contract # SKIP native-ab marker present on this host, can't force the bootc branch"
elif [[ $HAVE_ROOT -eq 0 ]]; then
    echo "ok - resolve_pristine cleanup contract # SKIP neither root nor passwordless sudo available"
else
    CONTRACT_DIR="$(mktemp -d)"
    FIXTURE_ROOT="$CONTRACT_DIR/fixture-root"
    mkdir -p "$FIXTURE_ROOT/etc"
    printf 'fixture pristine\n' >"$FIXTURE_ROOT/etc/probe.conf"

    WRAPPER="$CONTRACT_DIR/snosi-etc-diff-wrapper"
    sed "s#mount --bind -o ro / \"\$mnt\"#mount --bind -o ro \"$FIXTURE_ROOT\" \"\$mnt\"#; \
         s#mount --bind / \"\$mnt\"#mount --bind \"$FIXTURE_ROOT\" \"\$mnt\"#" \
        "$SCRIPT" >"$WRAPPER"
    chmod +x "$WRAPPER"

    # Sanity: the substitution actually landed (otherwise this "test" would
    # silently bind-mount the real host / via the unmodified script).
    if ! grep -q "mount --bind -o ro \"$FIXTURE_ROOT\"" "$WRAPPER"; then
        record_fail "cleanup-contract wrapper substitution applied" \
            "mount --bind line in $WRAPPER was not rewritten to the fixture root"
    else
        record_pass "cleanup-contract wrapper substitution applied"

        set +e
        "${SUDO[@]}" "$WRAPPER" --machine >"$CONTRACT_DIR/out.log" 2>"$CONTRACT_DIR/err.log"
        rc=$?
        set -e

        assert_eq "resolve_pristine bootc branch exits 0" "$rc" "0"

        leftover_mounts="$(grep -c 'snosi-etc-diff' /proc/mounts || true)"
        assert_eq "no leftover bind mount after run" "$leftover_mounts" "0"

        leftover_dirs="$(find /run -maxdepth 1 -name 'snosi-etc-diff.*' 2>/dev/null | wc -l)"
        assert_eq "no leftover /run tmp dir after run" "$leftover_dirs" "0"

        if [[ $rc -ne 0 ]]; then
            echo "  wrapper stderr:" >&2
            sed 's/^/    /' "$CONTRACT_DIR/err.log" >&2
        fi
    fi

    "${SUDO[@]}" rm -rf "$CONTRACT_DIR"
fi

echo ""
echo "# Results: $PASS passed, $FAIL failed, $(( PASS + FAIL )) total"
exit "$FAIL"
