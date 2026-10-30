#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static guard: the gnome-remote-desktop system daemons must not get TPM access.
#
# PR #1141 gave the daemons the tss group with a SupplementaryGroups=tss drop-in
# in shared/snow/tree/usr/lib/systemd/system/gnome-remote-desktop.service.d/ and
# .../gnome-remote-desktop-configuration.service.d/; PR #1191
# deleted both. The cause: gnome-remote-desktop 48.1 seals the RDP credentials
# in the TPM. src/grd-tpm.c:432 persists the sealed object with
# Esys_ContextSave, and src/grd-tpm.c:517 restores it with Esys_ContextLoad. A
# TPM Reset, which every normal reboot does, invalidates that saved context, so
# after a reboot the daemon logs
#   Esys_ContextLoad failed: tpm:parameter(1):integrity check failed
# and headless RDP has no credentials until someone sets them again. Without TPM
# access the daemon uses the upstream GKeyFile backend, which survives reboots.
# Issue #1131 (closed, not planned) tracks this. This guard can change only when
# upstream persists the sealed blobs and loads them with Esys_Load, or reboot
# evidence proves persistence.
#
# This test rejects, outside docs/, .memory/, saved-unused/, test/ and *.md:
#   a. in any tracked file whose path has a directory component named
#      gnome-remote-desktop*.service.d, or whose base name is
#      gnome-remote-desktop*.service (any tree, system or user, /usr or /etc):
#      a non-comment line whose key is SupplementaryGroups and whose value
#      names tss as a whitespace-separated word;
#   b. in any tracked sysusers.d/*.conf file: a non-comment line
#      "m gnome-remote-desktop tss", because that group membership gives the
#      same access.
# It reads the same scan function for the real tree and its fixtures.
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
# Nothing here ships a remote-desktop unit; these trees are prose, dead code or
# the guard's own fixtures.
SKIP_DIRS = ("docs/", ".memory/", "saved-unused/", "test/")
SKIP_SUFFIXES = (".md",)
# A drop-in directory of either system daemon, in any tree and either scope.
DROPIN_DIR = re.compile(r"^gnome-remote-desktop.*\.service\.d$")
# The unit file itself, which can carry the key in its own [Service] section.
UNIT_FILE = re.compile(r"^gnome-remote-desktop.*\.service$")
SYSUSERS_DIR = "sysusers.d"
# The key is case-sensitive in systemd, and spaces around the '=' are allowed.
GROUPS = re.compile(r"^\s*SupplementaryGroups\s*=\s*(.*)$")
# A whitespace-separated word, so an unrelated group such as 'tsslike' (or
# 'foo-tss') does not match.
TSS = re.compile(r"(?:^|\s)tss(?=\s|$)")
# sysusers.d(5): "m <user> <group>"; any whitespace separates the fields.
MEMBER = re.compile(r"^\s*m\s+gnome-remote-desktop\s+tss(?=\s|$)")
CAUSE = (
    "gnome-remote-desktop must not get TPM access (group tss): 48.1 seals RDP "
    "credentials with Esys_ContextSave and Esys_ContextLoad, a TPM Reset at "
    "reboot invalidates the saved context, and the GKeyFile backend that "
    "needs no TPM survives reboots (snosi#1131)"
)


def is_comment(line):
    stripped = line.lstrip()
    return stripped.startswith("#") or stripped.startswith(";")


def is_grd_unit(rel):
    parts = rel.split("/")
    return bool(
        UNIT_FILE.match(parts[-1])
        or any(DROPIN_DIR.match(part) for part in parts[:-1])
    )


def is_sysusers_conf(rel):
    parts = rel.split("/")
    return parts[-1].endswith(".conf") and SYSUSERS_DIR in parts[:-1]


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
    unit = is_grd_unit(rel)
    sysusers = is_sysusers_conf(rel)
    if not (unit or sysusers):
        continue
    with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
        for number, line in enumerate(f, start=1):
            if is_comment(line):
                continue
            if unit:
                match = GROUPS.match(line)
                if match and TSS.search(match.group(1)):
                    hits.append(f"{rel}:{number}: {CAUSE}")
                    continue
            if sysusers and MEMBER.match(line):
                hits.append(f"{rel}:{number}: {CAUSE}")

failed = False
for hit in hits:
    print(f"not ok - {hit}")
    failed = True
if scanned == 0:
    print("not ok - read 0 tracked files; the scanner is not reading the tree")
    failed = True
elif not hits:
    print(
        "ok - no tracked gnome-remote-desktop unit or sysusers.d file gives "
        f"the daemons the tss group ({scanned} files)"
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

# Both drop-ins PR #1141 added, put back with their 3-line shape.
for unit in gnome-remote-desktop.service gnome-remote-desktop-configuration.service; do
    dir=$(fixture "tpm-$unit")
    dropin="$dir/shared/snow/tree/usr/lib/systemd/system/$unit.d"
    mkdir -p "$dropin"
    {
        printf '# Give the daemons access to the tss-owned TPM device.\n'
        printf '[Service]\n'
        printf 'SupplementaryGroups=tss\n'
    } >"$dropin/10-tpm-access.conf"
    expect "a re-added $unit.d/10-tpm-access.conf" reject "$dir" \
        "shared/snow/tree/usr/lib/systemd/system/$unit.d/10-tpm-access.conf:3:"
done

# A user-unit drop-in with spaces around the '=' and tss among other groups.
dir=$(fixture user-dropin)
mkdir -p "$dir/shared/snow/tree/usr/lib/systemd/user/gnome-remote-desktop-headless.service.d"
printf '[Service]\n  SupplementaryGroups = video tss\n' \
    >"$dir/shared/snow/tree/usr/lib/systemd/user/gnome-remote-desktop-headless.service.d/10-tpm.conf"
expect "an indented SupplementaryGroups = video tss in a user drop-in" reject "$dir" \
    "shared/snow/tree/usr/lib/systemd/user/gnome-remote-desktop-headless.service.d/10-tpm.conf:2:"

# An /etc drop-in in a tree, which an image can ship the same way.
dir=$(fixture etc-dropin)
mkdir -p "$dir/shared/snow/tree/etc/systemd/system/gnome-remote-desktop.service.d"
printf '[Service]\nSupplementaryGroups=tss\n' \
    >"$dir/shared/snow/tree/etc/systemd/system/gnome-remote-desktop.service.d/10-tpm-access.conf"
expect "a re-added /etc .../gnome-remote-desktop.service.d drop-in" reject "$dir" \
    "shared/snow/tree/etc/systemd/system/gnome-remote-desktop.service.d/10-tpm-access.conf:2:"

# A group membership in sysusers.d gives the same access as the drop-in.
dir=$(fixture sysusers)
mkdir -p "$dir/shared/snow/tree/usr/lib/sysusers.d"
printf 'u gnome-remote-desktop - "GNOME Remote Desktop" /var/lib/gnome-remote-desktop\n' \
    >"$dir/shared/snow/tree/usr/lib/sysusers.d/gnome-remote-desktop.conf"
printf 'm   gnome-remote-desktop\ttss\n' \
    >>"$dir/shared/snow/tree/usr/lib/sysusers.d/gnome-remote-desktop.conf"
expect "m gnome-remote-desktop tss in a sysusers.d file" reject "$dir" \
    "shared/snow/tree/usr/lib/sysusers.d/gnome-remote-desktop.conf:2:"

# A commented key sets nothing.
dir=$(fixture comments)
mkdir -p "$dir/shared/snow/tree/usr/lib/systemd/system/gnome-remote-desktop.service.d"
printf '[Service]\n# SupplementaryGroups=tss\n;SupplementaryGroups=tss\n' \
    >"$dir/shared/snow/tree/usr/lib/systemd/system/gnome-remote-desktop.service.d/10-comment.conf"
expect "# and ; comments naming SupplementaryGroups=tss" pass "$dir"

# The same key in an unrelated unit is not this daemon's.
dir=$(fixture other-unit)
mkdir -p "$dir/shared/snow/tree/usr/lib/systemd/system/foo.service.d"
printf '[Service]\nSupplementaryGroups=tss\n' \
    >"$dir/shared/snow/tree/usr/lib/systemd/system/foo.service.d/10-tpm-access.conf"
expect "SupplementaryGroups=tss in foo.service.d" pass "$dir"

# A longer group name is a different group.
dir=$(fixture tsslike)
mkdir -p "$dir/shared/snow/tree/usr/lib/systemd/system/gnome-remote-desktop.service.d"
printf '[Service]\nSupplementaryGroups=tsslike\n' \
    >"$dir/shared/snow/tree/usr/lib/systemd/system/gnome-remote-desktop.service.d/10-group.conf"
expect "SupplementaryGroups=tsslike in a grd drop-in" pass "$dir"

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
