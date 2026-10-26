#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static guard: no image may enable GDM automatic or timed login.
#
# shared/snow/tree/etc/gdm3/daemon.conf used to set AutomaticLogin=snow for the
# old live ISO; commit e08311f retired snow-linux-live-setup.service, which
# created that user. No shipped image creates a user GDM could log in, so the
# Debian package default (all autologin lines commented) must stay. The Firn
# installer creates the only user an installed system has.
#
# This test rejects every non-comment line in a tracked file (outside docs/,
# .memory/, saved-unused/, test/ and *.md / *.svg) that names a GDM automatic
# or timed login key, with or without an '=': a build script can also uncomment
# the packaged keys with sed, or write them with echo or a heredoc. It reads the
# same scan function for the real tree and its fixtures.
#
# No root, no network, no image build.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

scan() { # root -> "ok - "/"not ok - " lines; status 1 on any not ok
    python3 - "$1" <<'PY'
import os
import re
import subprocess
import sys

root = os.path.abspath(sys.argv[1])
# Nothing here ships a GDM configuration; these trees are prose, dead code or
# the guard's own fixtures.
SKIP_DIRS = ("docs/", ".memory/", "saved-unused/", "test/")
SKIP_SUFFIXES = (".md", ".svg")
# The base names cover the Enable and Delay forms, and no '=' is required: a
# build script can also uncomment the packaged keys with sed.
# sed -i '/AutomaticLogin/s/^[[:space:]]*#[[:space:]]*//' /etc/gdm3/daemon.conf
KEYS = ("AutomaticLogin", "TimedLogin")
# A word start keeps a longer unrelated identifier from matching.
KEY = re.compile(r"\b(" + "|".join(KEYS) + r")", re.I)


def is_comment(line):
    stripped = line.lstrip()
    return stripped.startswith("#") or stripped.startswith(";")


listed = subprocess.run(
    ["git", "-C", root, "ls-files", "-z"], check=True, capture_output=True
).stdout.decode()
tracked = sorted(
    p for p in listed.split("\0")
    if p
    and not p.startswith(SKIP_DIRS)
    and not p.endswith(SKIP_SUFFIXES)
    and os.path.isfile(os.path.join(root, p))
)

hits = []
scanned = 0
for rel in tracked:
    scanned += 1
    with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
        for number, line in enumerate(f, start=1):
            if is_comment(line):
                continue
            match = KEY.search(line)
            if match:
                hits.append(
                    f"{rel}:{number}: names {match.group(1)}; GDM must not "
                    "name an "
                    "autologin user because no shipped image creates one; the "
                    "installer creates the only user"
                )

failed = False
for hit in hits:
    print(f"not ok - {hit}")
    failed = True
if scanned == 0:
    print("not ok - read 0 tracked files; the scanner is not reading the tree")
    failed = True
elif not hits:
    print(
        "ok - no tracked file outside docs/.memory/test/ names a GDM "
        f"automatic or timed login key ({scanned} files)"
    )
sys.exit(1 if failed else 0)
PY
}

# Negative self-checks: a guard that cannot fail is not a guard. Each fixture
# is a scratch copy of the tracked tree with one change, so the clean copy is
# the real tree and every case starts from real layouts.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

template="$tmp/template"
mkdir "$template"
git -C "$root" ls-files -z | tar -C "$root" --null -T - -cf - | tar -C "$template" -xf -
git -C "$template" init -q
git -C "$template" add -A

fixture() { # name -> path
    cp -a "$template" "$tmp/$1"
    printf '%s\n' "$tmp/$1"
}

indent() { # quote scan output under the "not ok - " lines
    local line
    while IFS= read -r line; do printf '#   %s\n' "$line"; done
}

expect() { # description pass|reject fixture [text the rejection must name]
    local description=$1 want=$2 dir=$3 named=${4:-} out status=0
    git -C "$dir" add -A
    out=$(scan "$dir" 2>&1) || status=$?
    if [[ $want == pass && $status -eq 0 ]]; then
        pass "self-check: $description passes"
    elif [[ $want == pass ]]; then
        fail "self-check: $description passes"
        indent <<<"$out" >&2
    elif [[ $status -eq 0 ]]; then
        fail "self-check: $description was not detected"
    elif [[ $out == *"not ok - $named"* ]]; then
        pass "self-check: $description is detected"
    else
        fail "self-check: $description is detected and names $named"
        indent <<<"$out" >&2
    fi
    rm -rf "$dir"
}

dir=$(fixture clean)
expect "a straight copy of the tree" pass "$dir"

# The retired live-ISO drop-in, put back.
dir=$(fixture daemon-conf)
mkdir -p "$dir/shared/snow/tree/etc/gdm3"
printf '[daemon]\nAutomaticLogin=snow\nAutomaticLoginEnable=True\n' \
    >"$dir/shared/snow/tree/etc/gdm3/daemon.conf"
expect "a re-added shared/snow/tree/etc/gdm3/daemon.conf" reject "$dir" \
    "shared/snow/tree/etc/gdm3/daemon.conf:2:"

# An indented key with spaces around the equals sign, in a new file.
dir=$(fixture custom-conf)
mkdir -p "$dir/shared/snow/tree/etc/gdm3"
printf '[daemon]\n  AutomaticLoginEnable = true\n' \
    >"$dir/shared/snow/tree/etc/gdm3/custom.conf"
expect "an indented AutomaticLoginEnable = in custom.conf" reject "$dir" \
    "shared/snow/tree/etc/gdm3/custom.conf:2:"

# A build script that writes the key instead of shipping a config file.
dir=$(fixture script-echo)
printf 'echo "TimedLoginEnable=true" >> /etc/gdm3/custom.conf\n' \
    >>"$dir/shared/snow/scripts/postinstall/snow.postinst.chroot"
expect "TimedLoginEnable=true echoed by snow.postinst.chroot" reject "$dir" \
    "shared/snow/scripts/postinstall/snow.postinst.chroot:"

# A build script that uncomments the packaged keys, with no '=' in its line.
dir=$(fixture script-sed)
printf '%s\n' "sed -i '/AutomaticLogin/s/^[[:space:]]*#[[:space:]]*//' /etc/gdm3/daemon.conf" \
    >>"$dir/mkosi.images/base/mkosi.postinst.chroot"
expect "a sed that uncomments AutomaticLogin in base postinst" reject "$dir" \
    "mkosi.images/base/mkosi.postinst.chroot:"

# Commented keys set nothing.
dir=$(fixture comments)
mkdir -p "$dir/shared/snow/tree/etc/gdm3"
printf '[daemon]\n# AutomaticLogin=user1\n;TimedLogin=x\n' \
    >"$dir/shared/snow/tree/etc/gdm3/custom.conf"
printf '# echo "TimedLoginDelay=5"\n' \
    >>"$dir/shared/snow/scripts/postinstall/snow.postinst.chroot"
expect "# and ; comments naming autologin keys" pass "$dir"

out=$(scan "$root" 2>&1) || true
while IFS= read -r line; do
    case $line in
        'ok - '*) pass "${line#ok - }" ;;
        'not ok - '*) fail "${line#not ok - }" ;;
        *) printf '%s\n' "$line" ;;
    esac
done <<<"$out"

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
