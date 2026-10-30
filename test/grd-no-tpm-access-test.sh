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
#      a non-comment line whose key is SupplementaryGroups and whose value has
#      a word that decodes to tss. The value is split with systemd's own rules:
#      quotes group text, C escapes decode, and a line that ends with a
#      backslash is joined to the lines after it;
#   b. in any tracked sysusers.d/*.conf file: a non-comment line
#      "m gnome-remote-desktop tss", because that group membership gives the
#      same access. Its fields use the same splitter, so quoting and escapes
#      hide nothing either.
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
# systemd decodes C escapes in a unit or sysusers value (extract_first_word()
# with EXTRACT_UNQUOTE | EXTRACT_CUNESCAPE), so SupplementaryGroups="\x74ss"
# and m gnome-remote-desktop "\164ss" both name the tss group.
ESCAPES = {
    "a": "\a",
    "b": "\b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
    "v": "\v",
    "\\": "\\",
    '"': '"',
    "'": "'",
    "s": " ",
}
# Number of digits after the letter, and their base.
NUMERIC_ESCAPES = {"x": (2, 16), "u": (4, 16), "U": (8, 16)}
OCTAL_ESCAPE = (3, 8)
HEX_DIGITS = "0123456789abcdefABCDEF"
DIGITS = "01234567"
TSS = "tss"
CAUSE = (
    "gnome-remote-desktop must not get TPM access (group tss): 48.1 seals RDP "
    "credentials with Esys_ContextSave and Esys_ContextLoad, a TPM Reset at "
    "reboot invalidates the saved context, and the GKeyFile backend that "
    "needs no TPM survives reboots (snosi#1131)"
)


def is_comment(line):
    stripped = line.lstrip()
    return stripped.startswith("#") or stripped.startswith(";")


def escape(text, index):
    """Decode the escape whose backslash is at text[index].

    Returns (value, index after the escape). An unknown or incomplete escape
    keeps the character after the backslash, and a trailing lone backslash is
    dropped: a relaxed reading, so a malformed line is not a blind spot.
    """
    following = text[index + 1:]
    if not following:
        return "", len(text)
    kind = following[0]
    if kind in ESCAPES:
        return ESCAPES[kind], index + 2
    if kind in NUMERIC_ESCAPES:
        width, base = NUMERIC_ESCAPES[kind]
        body = following[1:1 + width]
        allowed = HEX_DIGITS
        # The letter and its digits, after the backslash itself.
        length = 1 + width
    elif kind in DIGITS:
        width, base = OCTAL_ESCAPE
        body = following[:width]
        allowed = DIGITS
        length = width
    else:
        return kind, index + 2
    if len(body) == width and all(ch in allowed for ch in body):
        value = int(body, base)
        if value <= 0x10FFFF:
            return chr(value), index + 1 + length
    return kind, index + 2


def words(value):
    """Split a systemd or sysusers value the way systemd does.

    systemd unquotes and cunescapes each word, so SupplementaryGroups="tss",
    SupplementaryGroups=video 'tss' and SupplementaryGroups=\\x74ss all grant
    the tss group. Escapes decode inside quotes as well as outside them, and an
    unterminated quote ends its word at the end of the line (best effort).
    """
    result = []
    current = []
    open_word = False
    quote = None
    index = 0
    while index < len(value):
        char = value[index]
        if quote is None and char.isspace():
            if open_word:
                result.append("".join(current))
                current = []
                open_word = False
            index += 1
            continue
        if quote is None and char in "'\"":
            quote = char
            open_word = True
            index += 1
            continue
        if quote is not None and char == quote:
            quote = None
            index += 1
            continue
        if char == "\\":
            text, index = escape(value, index)
            current.append(text)
            open_word = True
            continue
        current.append(char)
        open_word = True
        index += 1
    if open_word:
        result.append("".join(current))
    return result


def logical_lines(lines):
    """Yield (first physical line number, joined text) for systemd units.

    systemd drops a trailing backslash and joins the next line to it, and a
    comment line inside the continuation is ignored.
    """
    pending = None
    start = 0
    for number, line in enumerate(lines, start=1):
        if is_comment(line):
            continue
        text = line.rstrip("\n")
        if pending is None:
            start = number
        else:
            text = pending + text
        # Trailing whitespace is no part of a continuation marker.
        stripped = text.rstrip()
        if stripped.endswith("\\"):
            pending = stripped[:-1] + " "
            continue
        pending = None
        yield start, text
    if pending is not None:
        yield start, pending


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
        lines = f.readlines()
    if unit:
        for start, text in logical_lines(lines):
            match = GROUPS.match(text)
            if match and TSS in words(match.group(1)):
                hits.append(f"{rel}:{start}: {CAUSE}")
    if sysusers:
        for number, line in enumerate(lines, start=1):
            if is_comment(line):
                continue
            # sysusers.d(5): "m <user> <group>".
            if words(line)[:3] == ["m", "gnome-remote-desktop", TSS]:
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

# systemd unquotes every SupplementaryGroups word, so quoting hides nothing.
grd_system=shared/snow/tree/usr/lib/systemd/system/gnome-remote-desktop.service.d

dir=$(fixture quoted-double)
mkdir -p "$dir/$grd_system"
printf '[Service]\nSupplementaryGroups="tss"\n' >"$dir/$grd_system/10-quoted.conf"
expect "SupplementaryGroups=\"tss\" in a grd drop-in" reject "$dir" \
    "$grd_system/10-quoted.conf:2:"

dir=$(fixture quoted-single)
mkdir -p "$dir/$grd_system"
printf '[Service]\nSupplementaryGroups=video %s\n' "'tss'" \
    >"$dir/$grd_system/10-quoted.conf"
expect "SupplementaryGroups=video 'tss' in a grd drop-in" reject "$dir" \
    "$grd_system/10-quoted.conf:2:"

# systemd joins a line that ends with a backslash to the next line, and a
# comment inside the continuation is ignored. The first line is named.
dir=$(fixture continuation)
mkdir -p "$dir/$grd_system"
cat >"$dir/$grd_system/10-continued.conf" <<'EOF'
[Service]
SupplementaryGroups=video \
# a comment inside the continuation is ignored
  tss
EOF
expect "SupplementaryGroups=video \\ then a comment then tss" reject "$dir" \
    "$grd_system/10-continued.conf:2:"

# The same shape with a longer group name is a different group.
dir=$(fixture continuation-other)
mkdir -p "$dir/$grd_system"
cat >"$dir/$grd_system/10-continued.conf" <<'EOF'
[Service]
SupplementaryGroups=video \
  tsslike
EOF
expect "a continuation that ends in tsslike" pass "$dir"

# sysusers.d unquotes its fields too, so quoting hides nothing there either.
index=0
for variant in '"gnome-remote-desktop" tss' \
    'gnome-remote-desktop "tss"' \
    '"gnome-remote-desktop" "tss"'; do
    index=$((index + 1))
    dir=$(fixture "sysusers-quoted-$index")
    mkdir -p "$dir/shared/snow/tree/usr/lib/sysusers.d"
    printf 'm %s\n' "$variant" \
        >"$dir/shared/snow/tree/usr/lib/sysusers.d/gnome-remote-desktop.conf"
    expect "a quoted m $variant in a sysusers.d file" reject "$dir" \
        "shared/snow/tree/usr/lib/sysusers.d/gnome-remote-desktop.conf:1:"
done

# systemd decodes C escapes (\xHH, \NNN, \uHHHH, \UHHHHHHHH), so an escaped
# name is the same group. The heredocs are quoted, so the backslashes reach the
# fixture unchanged.
sysusers_path=shared/snow/tree/usr/lib/sysusers.d/gnome-remote-desktop.conf

dir=$(fixture sysusers-hex-group)
mkdir -p "$dir/shared/snow/tree/usr/lib/sysusers.d"
cat >"$dir/$sysusers_path" <<'EOF'
m gnome-remote-desktop "\x74ss"
EOF
expect 'm gnome-remote-desktop "\x74ss" in a sysusers.d file' reject "$dir" \
    "$sysusers_path:1:"

dir=$(fixture sysusers-hex-user)
mkdir -p "$dir/shared/snow/tree/usr/lib/sysusers.d"
cat >"$dir/$sysusers_path" <<'EOF'
m "\x67nome-remote-desktop" tss
EOF
expect 'm "\x67nome-remote-desktop" tss in a sysusers.d file' reject "$dir" \
    "$sysusers_path:1:"

dir=$(fixture unit-hex-bare)
mkdir -p "$dir/$grd_system"
cat >"$dir/$grd_system/10-hex.conf" <<'EOF'
[Service]
SupplementaryGroups=\x74ss
EOF
expect 'SupplementaryGroups=\x74ss in a grd drop-in' reject "$dir" \
    "$grd_system/10-hex.conf:2:"

dir=$(fixture unit-octal-quoted)
mkdir -p "$dir/$grd_system"
cat >"$dir/$grd_system/10-octal.conf" <<'EOF'
[Service]
SupplementaryGroups=video "\164ss"
EOF
expect 'SupplementaryGroups=video "\164ss" in a grd drop-in' reject "$dir" \
    "$grd_system/10-octal.conf:2:"

# An escaped longer name is still a different group.
dir=$(fixture unit-hex-longer)
mkdir -p "$dir/$grd_system"
cat >"$dir/$grd_system/10-hex.conf" <<'EOF'
[Service]
SupplementaryGroups="\x74sslike"
EOF
expect 'SupplementaryGroups="\x74sslike" in a grd drop-in' pass "$dir"

# An escaped backslash decodes to one word, video\tss, not to tss.
dir=$(fixture unit-backslash)
mkdir -p "$dir/$grd_system"
cat >"$dir/$grd_system/10-backslash.conf" <<'EOF'
[Service]
SupplementaryGroups=video\\tss
EOF
expect 'SupplementaryGroups=video\\tss in a grd drop-in' pass "$dir"

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
