#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static guard: frostyard-firn-gui ships only on the Firn installer ISO.
#
# firn-gui (frostyard/firn#122) is a graphical installer that runs as root and
# erases a disk. Its desktop entry would give every installed desktop a
# launcher that can wipe a disk, so only the firn-installer profile
# (mkosi.profiles/firn-installer and the shared/firn-installer/ fragments it
# includes) may install it. Everywhere else this test rejects it:
#  - in any package setting of any tracked mkosi config (every *.conf, so
#    mkosi.conf, mkosi.conf.d/, profiles, images and shared fragments, plus
#    any Include= target), on the setting's first line or a continuation line,
#    by name, with an apt qualifier, as a local .deb or through a glob;
#  - in any mkosi build script (a *Scripts= target, mkosi.<phase>, *.chroot)
#    that installs packages by name with dpkg -i or apt;
#  - and it rejects any other config that Include=s the installer fragments,
#    which would hand an installed image the installer's package list.
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
import fnmatch
import os
import re
import subprocess
import sys
import textwrap

root = os.path.abspath(sys.argv[1])
PACKAGE = "frostyard-firn-gui"
INSTALLER_DIRS = ("shared/firn-installer", "mkosi.profiles/firn-installer")
INSTALLER_FILES = ("mkosi.profiles/firn-installer.conf",)
# Every mkosi setting that installs packages somewhere. RemovePackages= only
# removes, so listing frostyard-firn-gui there is harmless.
PACKAGE_SETTINGS = {
    "Packages",
    "BuildPackages",
    "VolatilePackages",
    "InitrdPackages",
    "InitrdVolatilePackages",
    "ToolsTreePackages",
}
PHASES = "configure|sync|prepare|build|postinst|finalize|postoutput|clean"
SCRIPT_SETTING = re.compile(r"(Configure|Sync|Prepare|Build|PostInstallation|Finalize|PostOutput|Clean)Scripts?")
SCRIPT_NAME = re.compile(rf"(^|/)mkosi\.({PHASES})(\.chroot)?$|(^|/)mkosi\.({PHASES})\.d/|\.chroot$")
# Debian package names use [a-z0-9.+-]. frostyard-firn-gui-dbg is another
# package; frostyard-firn-gui=1.0, :amd64, /forky and _1.0_amd64.deb are not.
NAME = re.compile(r"(?<![a-z0-9.+-])" + re.escape(PACKAGE) + r"(?![a-z0-9+-])", re.I)


def in_installer(rel):
    return rel in INSTALLER_FILES or any(rel == d or rel.startswith(d + "/") for d in INSTALLER_DIRS)


def names_package(token):
    if NAME.search(token):
        return True
    # A glob such as frostyard-firn* or frostyard-* selects it too.
    name = re.split(r"[=:/]", token, maxsplit=1)[0].lower()
    return any(c in name for c in "*?[") and fnmatch.fnmatchcase(PACKAGE, name)


def settings(rel):
    """Yield (line, setting, value) for each physical value line, read the
    way mkosi's parse_ini reads it: '#' starts a comment anywhere, blank and
    comment-only lines are skipped, and an indented line continues the
    previous setting."""
    with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
        lines = textwrap.dedent(f.read()).splitlines()
    section = setting = None
    for number, line in enumerate(lines, start=1):
        line = line.split("#", 1)[0]
        if not line.strip():
            continue
        if section and setting and line[0].isspace():
            yield number, setting, line.strip()
            continue
        setting = None
        line = line.strip()
        if line.startswith("["):
            section = line
        elif section:
            name, equals, value = line.partition("=")
            if equals:
                setting = name.strip()
                yield number, setting, value.strip()


def resolve(value, config):
    """Repo-relative path an Include= or *Scripts= entry names, or None."""
    here = os.path.dirname(os.path.join(root, config))
    value = value.replace("%D", root).replace("%C", here)
    rel = os.path.relpath(os.path.normpath(os.path.join(here, value)), root)
    return None if rel == ".." or rel.startswith("../") else rel


listed = subprocess.run(
    ["git", "-C", root, "ls-files", "-z"], check=True, capture_output=True
).stdout.decode()
# saved-unused/ is dead code excluded from builds.
tracked = sorted(
    p for p in listed.split("\0")
    if p and not p.startswith("saved-unused/") and os.path.isfile(os.path.join(root, p))
)
tracked_set = set(tracked)

configs = [p for p in tracked if p.endswith(".conf")]
queue = list(configs)
seen = set(queue)
scripts = {p for p in tracked if SCRIPT_NAME.search(p)}
package_hits, include_hits, script_hits = [], [], []
entries = 0
installer_names = set()

while queue:
    config = queue.pop(0)
    for number, setting, value in settings(config):
        if setting == "Include" or SCRIPT_SETTING.fullmatch(setting):
            for item in filter(None, (v.strip() for v in value.split(","))):
                rel = resolve(item, config)
                if rel is None:
                    continue
                if setting != "Include":
                    if rel in tracked_set:
                        scripts.add(rel)
                    continue
                if in_installer(rel) and not in_installer(config):
                    include_hits.append(f"{config}:{number}: Include={item} hands this image the Firn installer's package list")
                # An Include= target need not end in .conf; read it too.
                if rel in tracked_set and rel not in seen:
                    seen.add(rel)
                    queue.append(rel)
        elif setting in PACKAGE_SETTINGS:
            for token in filter(None, re.split(r"[\s,]+", value)):
                entries += 1
                if in_installer(config):
                    installer_names.add(re.split(r"[=:/]", token, maxsplit=1)[0])
                elif names_package(token):
                    package_hits.append(f"{config}:{number}: {setting}= lists {token}")

for script in sorted(scripts):
    if in_installer(script):
        continue
    with open(os.path.join(root, script), encoding="utf-8", errors="replace") as f:
        for number, line in enumerate(f, start=1):
            if not line.lstrip().startswith("#") and NAME.search(line):
                script_hits.append(f"{script}:{number}: build script names {PACKAGE}")

failed = False


def report(hits, message):
    global failed
    for hit in hits:
        print(f"not ok - {hit}; {PACKAGE} belongs only in shared/firn-installer/")
    if hits:
        failed = True
    else:
        print(f"ok - {message}")


# Non-vacuity: a scanner that reads no package lists passes everything.
if entries and "frostyard-firn" in installer_names:
    print(f"ok - parsed {entries} package entries from {len(seen)} mkosi configs, including the installer's frostyard-firn")
else:
    print(f"not ok - parsed {entries} package entries and did not find frostyard-firn in the Firn installer profile; the scanner is not reading package lists")
    failed = True
report(package_hits, f"no package setting outside the Firn installer profile lists {PACKAGE}")
report(include_hits, "no config outside the Firn installer profile includes its fragments")
report(script_hits, f"no build script outside the Firn installer profile names {PACKAGE} ({len(scripts)} scripts)")
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

mutate() { # file sed-script: a case whose edit changes nothing proves nothing
    cp "$1" "$tmp/before"
    sed -i "$2" "$1"
    if cmp -s "$1" "$tmp/before"; then
        fail "self-check fixture: $2 changed nothing in ${1#"$tmp"/*/}"
    fi
}

expect() { # description pass|reject fixture [text the rejection must name]
    local description=$1 want=$2 dir=$3 named=${4:-} out status=0
    git -C "$dir" add -A
    out=$(scan "$dir" 2>&1) || status=$?
    if [[ $want == pass && $status -eq 0 ]]; then
        pass "self-check: $description passes"
    elif [[ $want == pass ]]; then
        fail "self-check: $description passes"
        sed 's/^/#   /' <<<"$out" >&2
    elif [[ $status -eq 0 ]]; then
        fail "self-check: $description was not detected"
    elif [[ $out == *"not ok - $named"* ]]; then
        pass "self-check: $description is detected"
    else
        fail "self-check: $description is detected and names $named"
        sed 's/^/#   /' <<<"$out" >&2
    fi
    rm -rf "$dir"
}

dir=$(fixture clean)
expect "a straight copy of the tree" pass "$dir"

# The ISO may install it, from either installer location.
dir=$(fixture installer)
mutate "$dir/shared/firn-installer/mkosi.conf" 's/^Packages=frostyard-firn$/&\n         frostyard-firn-gui/'
printf '\n[Content]\nPackages=frostyard-firn-gui\n' >>"$dir/mkosi.profiles/firn-installer/mkosi.conf"
expect "frostyard-firn-gui in the Firn installer profile" pass "$dir"

# Comments, RemovePackages= and other firn packages install nothing.
dir=$(fixture comments)
printf '\n# frostyard-firn-gui stays on the ISO\n[Content]\nPackages=vim # frostyard-firn-gui\nRemovePackages=frostyard-firn-gui\n' \
    >>"$dir/mkosi.profiles/snow/mkosi.conf"
mutate "$dir/mkosi.images/podman/mkosi.conf" 's/^Packages=podman$/&\n  # frostyard-firn-gui\n         frostyard-firn-gui-dbg/'
printf '# not frostyard-firn-gui\n' >>"$dir/shared/snow/scripts/postinstall/snow.postinst.chroot"
expect "comments, RemovePackages= and frostyard-firn-gui-dbg" pass "$dir"

# An installed-image profile, on a Packages= first line.
dir=$(fixture profile)
printf '\n[Content]\nPackages=frostyard-firn-gui\n' >>"$dir/mkosi.profiles/snowfield/mkosi.conf"
expect "Packages=frostyard-firn-gui in the snowfield profile" reject "$dir" \
    "mkosi.profiles/snowfield/mkosi.conf:"

# A continuation line (tab-indented) in a shared product package fragment.
dir=$(fixture continuation)
mutate "$dir/shared/packages/snow/mkosi.conf" 's/^Packages=frostyard-chairlift$/&\n\tfrostyard-firn-gui/'
expect "a continuation line in shared/packages/snow" reject "$dir" "shared/packages/snow/mkosi.conf:7:"

# mkosi keeps a value going across blank and comment-only lines.
dir=$(fixture blank-continuation)
mutate "$dir/mkosi.images/base/mkosi.conf" 's/^Packages=erofs-utils$/&\n\n# desktop installer\n         frostyard-firn-gui/'
expect "a continuation after blank and comment lines in base" reject "$dir" "mkosi.images/base/mkosi.conf:"

# A sysext ships to every installed host that enables it.
dir=$(fixture sysext)
mutate "$dir/mkosi.images/podman/mkosi.conf" 's/^Packages=podman$/&\n         frostyard-firn-gui:amd64/'
expect "an arch-qualified entry in the podman sysext" reject "$dir" "mkosi.images/podman/mkosi.conf:"

# A mkosi.conf.d drop-in, in a comma list with a version pin.
dir=$(fixture conf-d)
mkdir -p "$dir/mkosi.conf.d"
printf '[Content]\nPackages=vim,frostyard-firn-gui=1.0\n' >"$dir/mkosi.conf.d/50-gui.conf"
expect "a pinned comma-list entry in mkosi.conf.d" reject "$dir" "mkosi.conf.d/50-gui.conf:2:"

# A single-file profile, through another package setting.
dir=$(fixture profile-file)
printf '[Content]\nVolatilePackages=frostyard-firn-gui/forky\n' >"$dir/mkosi.profiles/kiosk.conf"
expect "VolatilePackages= in mkosi.profiles/kiosk.conf" reject "$dir" "mkosi.profiles/kiosk.conf:2:"

# A glob that also selects frostyard-firn-gui.
dir=$(fixture glob)
printf '\n[Content]\nPackages=frostyard-firn*\n' >>"$dir/mkosi.profiles/floe/mkosi.conf"
expect "a frostyard-firn* glob in the floe profile" reject "$dir" "mkosi.profiles/floe/mkosi.conf:"

# An Include= target that is not a .conf file.
dir=$(fixture include-target)
mkdir -p "$dir/shared/packages/extra"
printf '[Content]\nBuildPackages=frostyard-firn-gui\n' >"$dir/shared/packages/extra/packages.inc"
printf 'Include=%%D/shared/packages/extra/packages.inc\n' >>"$dir/mkosi.profiles/sundog/mkosi.conf"
expect "an Include= target named packages.inc" reject "$dir" "shared/packages/extra/packages.inc:2:"

# An installed image inheriting the installer fragment.
dir=$(fixture include-installer)
printf 'Include=%%D/shared/firn-installer/mkosi.conf\n' >>"$dir/mkosi.profiles/sundog/mkosi.conf"
expect "the sundog profile including shared/firn-installer" reject "$dir" "mkosi.profiles/sundog/mkosi.conf:"

# A postinstall script installing it with apt.
dir=$(fixture script-apt)
printf 'apt-get install -y frostyard-firn-gui\n' >>"$dir/shared/snow/scripts/postinstall/snow.postinst.chroot"
expect "apt-get install in snow.postinst.chroot" reject "$dir" \
    "shared/snow/scripts/postinstall/snow.postinst.chroot:"

# A sysext postinst installing a downloaded .deb.
dir=$(fixture script-deb)
printf 'dpkg -i "$DEBS/frostyard-firn-gui_1.0_amd64.deb"\n' >>"$dir/mkosi.images/sunshine/mkosi.postinst.chroot"
expect "dpkg -i in the sunshine postinst" reject "$dir" "mkosi.images/sunshine/mkosi.postinst.chroot:"

# The non-vacuity control fires when the installer's package list is unread.
dir=$(fixture vacuous)
mutate "$dir/shared/firn-installer/mkosi.conf" 's/^Packages=frostyard-firn$/Packages=/'
expect "an unread installer package list" reject "$dir" "parsed "

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
