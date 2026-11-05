#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""First-login trigger contract (ADR-0028).

Snow and Snowfield start chairlift's first run at the first graphical login
from exactly one XDG autostart entry,
/etc/xdg/autostart/org.frostyard.ChairLift.FirstRun.desktop, with
Exec=/usr/bin/chairlift-first-run. frostyard-chairlift ships that program; a
stale chairlift from APT would leave the entry with no target. Sundog and
Floe have no first-login app.

Usage:
  first-login-check.py image IMAGE_ID BUILDROOT
      Check an assembled image tree (shared/composition/first-login.finalize).
  first-login-check.py apps FILE
      Check the shape of a first-run application list
      (/usr/share/snow/first-run/apps.json).

A first-login entry is an autostart .desktop file whose name starts with a
known first-login application ID, or whose [Desktop Entry] Exec program is a
known first-login program. It is a trigger unless Hidden=true or
X-GNOME-Autostart-enabled=false disables it. The check fails closed: an
unreadable or malformed entry fails it.
"""

import json
import os
import re
import stat
import sys

ENTRY_DIRS = (
    "etc/xdg/autostart",
    "usr/etc/xdg/autostart",
    "etc/skel/.config/autostart",
)
CHAIRLIFT_ENTRY = "etc/xdg/autostart/org.frostyard.ChairLift.FirstRun.desktop"
CHAIRLIFT_EXEC = "/usr/bin/chairlift-first-run"
APPS_JSON = "usr/share/snow/first-run/apps.json"
FIRST_LOGIN_NAMES = ("org.frostyard.ChairLift.FirstRun", "org.frostyard.FirstSetup")
FIRST_LOGIN_PROGRAMS = ("chairlift-first-run", "snow-first-setup")
# IMAGE_ID -> number of first-login triggers the image must ship.
PRODUCTS = {"snow": 1, "snowfield": 1, "sundog": 0, "floe": 0}

# flatpak's flatpak_is_valid_name, as chairlift's firstrun.ValidFlatpakID.
_ELEMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
_LAST_ELEMENT = re.compile(r"[A-Za-z_-][A-Za-z0-9_-]*\Z")


class CheckError(Exception):
    pass


def valid_flatpak_id(app_id):
    if not isinstance(app_id, str) or not app_id or len(app_id.encode()) > 255:
        return False
    elements = app_id.split(".")
    if len(elements) < 3:
        return False
    for index, element in enumerate(elements):
        pattern = _LAST_ELEMENT if index == len(elements) - 1 else _ELEMENT
        if not element.isascii() or not pattern.match(element):
            return False
    return True


def check_apps(data):
    """Raise CheckError unless data is chairlift's first-run list shape.

    The shape is first-setup's: {"<category>": [{"name": str, "id": str,
    "active": bool (optional, default true)}]}. chairlift's ParseApps rejects
    the same faults and then hides the Apps step, so a fault here is a build
    failure, not a silent loss of the step.
    """
    def unique_keys(pairs):
        keys = [key for key, _ in pairs]
        if len(keys) != len(set(keys)):
            raise CheckError(f"duplicate key in {keys}")
        return dict(pairs)

    try:
        raw = json.loads(data, object_pairs_hook=unique_keys)
    except ValueError as err:
        raise CheckError(f"invalid JSON: {err}") from err
    if not isinstance(raw, dict) or not raw:
        raise CheckError("the top level must be a non-empty object of categories")
    seen = {}
    count = 0
    for category, entries in raw.items():
        if not category.strip():
            raise CheckError("a category key is empty")
        if not isinstance(entries, list) or not entries:
            raise CheckError(f"category {category!r} must be a non-empty list")
        for index, entry in enumerate(entries):
            where = f"category {category!r} entry {index}"
            if not isinstance(entry, dict):
                raise CheckError(f"{where} must be an object")
            unknown = set(entry) - {"name", "id", "active"}
            if unknown:
                raise CheckError(f"{where} has unknown fields {sorted(unknown)}")
            name = entry.get("name")
            if not isinstance(name, str) or not name.strip():
                raise CheckError(f"{where} has no name")
            app_id = entry.get("id")
            if not valid_flatpak_id(app_id):
                raise CheckError(f"{where} ({name}) has an invalid Flatpak application ID {app_id!r}")
            if "active" in entry and not isinstance(entry["active"], bool):
                raise CheckError(f"{where} ({name}) has a non-boolean active")
            if app_id in seen:
                raise CheckError(f"application ID {app_id!r} appears in {seen[app_id]!r} and {category!r}")
            seen[app_id] = category
            count += 1
    return count


def parse_desktop(text, where):
    """Return the [Desktop Entry] group as a dict; fail on a malformed file."""
    groups = {}
    current = None
    for number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            current = stripped[1:-1]
            if current in groups:
                raise CheckError(f"{where}:{number}: group [{current}] appears twice")
            groups[current] = {}
            continue
        if current is None or "=" not in line:
            raise CheckError(f"{where}:{number}: not a key=value line in a group")
        key, value = line.split("=", 1)
        key = key.strip()
        if key in groups[current]:
            raise CheckError(f"{where}:{number}: key {key} appears twice in [{current}]")
        groups[current][key] = value.strip()
    if "Desktop Entry" not in groups:
        raise CheckError(f"{where}: no [Desktop Entry] group")
    return groups["Desktop Entry"]


def exec_program(exec_line):
    words = exec_line.split()
    return os.path.basename(words[0]) if words else ""


def resolve(root, rel):
    """Follow symlinks of root/rel inside root; return the real path."""
    path = os.path.join(root, rel)
    for _ in range(40):
        if not os.path.islink(path):
            return path
        target = os.readlink(path)
        if os.path.isabs(target):
            path = os.path.join(root, target.lstrip("/"))
        else:
            path = os.path.join(os.path.dirname(path), target)
    raise CheckError(f"/{rel}: too many symlinks")


def first_login_entries(root):
    """Yield (rel, entry, enabled) for every first-login autostart entry."""
    for directory in ENTRY_DIRS:
        base = os.path.join(root, directory)
        if not os.path.lexists(base):
            continue
        try:
            names = sorted(os.listdir(resolve(root, directory)))
        except OSError as err:
            raise CheckError(f"cannot list /{directory}: {err}") from err
        for name in names:
            if not name.endswith(".desktop"):
                continue
            rel = f"{directory}/{name}"
            try:
                with open(resolve(root, rel), encoding="utf-8") as handle:
                    text = handle.read()
            except (OSError, UnicodeDecodeError) as err:
                raise CheckError(f"cannot read /{rel}: {err}") from err
            entry = parse_desktop(text, f"/{rel}")
            program = exec_program(entry.get("Exec", ""))
            by_name = name.startswith(FIRST_LOGIN_NAMES)
            by_program = program in FIRST_LOGIN_PROGRAMS or (
                program == "chairlift" and "--first-run" in entry.get("Exec", "").split()
            )
            if not (by_name or by_program):
                continue
            enabled = (
                entry.get("Hidden", "false").lower() != "true"
                and entry.get("X-GNOME-Autostart-enabled", "true").lower() != "false"
            )
            yield rel, entry, enabled


def check_image(image_id, root):
    if image_id not in PRODUCTS:
        raise CheckError(f"no first-login rule for IMAGE_ID={image_id!r}")
    if not os.path.isdir(root):
        raise CheckError(f"BUILDROOT {root} is not a directory")
    want = PRODUCTS[image_id]
    entries = list(first_login_entries(root))
    triggers = [rel for rel, _, enabled in entries if enabled]

    for rel, entry, _ in entries:
        if rel == CHAIRLIFT_ENTRY and entry.get("Exec") != CHAIRLIFT_EXEC:
            raise CheckError(
                f"/{rel} has Exec={entry.get('Exec')!r}; it must be exactly {CHAIRLIFT_EXEC}"
            )

    if want == 0:
        if entries:
            raise CheckError(
                f"{image_id} must ship no first-login entry, found: "
                + ", ".join("/" + rel for rel, _, _ in entries)
            )
        return f"{image_id}: no first-login entry, as required"

    if len(triggers) != want:
        found = ", ".join("/" + rel for rel in triggers) or "none"
        raise CheckError(f"{image_id} must ship exactly {want} first-login trigger, found {len(triggers)}: {found}")
    if triggers[0] != CHAIRLIFT_ENTRY:
        raise CheckError(f"{image_id}'s first-login trigger is /{triggers[0]}, not /{CHAIRLIFT_ENTRY}")
    stale = [rel for rel, _, enabled in entries if not enabled]
    if stale:
        raise CheckError(f"{image_id} ships disabled first-login entries: " + ", ".join("/" + r for r in stale))

    program = resolve(root, CHAIRLIFT_EXEC.lstrip("/"))
    try:
        mode = os.stat(program).st_mode
    except OSError as err:
        raise CheckError(f"{CHAIRLIFT_EXEC} is missing ({err.strerror}); frostyard-chairlift is too old for the first-run trigger") from err
    if not stat.S_ISREG(mode) or not mode & 0o111:
        raise CheckError(f"{CHAIRLIFT_EXEC} is not an executable regular file")

    apps = resolve(root, APPS_JSON)
    try:
        with open(apps, encoding="utf-8") as handle:
            count = check_apps(handle.read())
    except (OSError, UnicodeDecodeError) as err:
        raise CheckError(f"cannot read /{APPS_JSON}: {err}") from err
    except CheckError as err:
        raise CheckError(f"/{APPS_JSON}: {err}") from err
    return f"{image_id}: /{CHAIRLIFT_ENTRY} -> {CHAIRLIFT_EXEC}, /{APPS_JSON} lists {count} apps"


def main(argv):
    try:
        if len(argv) == 4 and argv[1] == "image":
            print("first-login-check: " + check_image(argv[2], argv[3]))
        elif len(argv) == 3 and argv[1] == "apps":
            try:
                with open(argv[2], encoding="utf-8") as handle:
                    count = check_apps(handle.read())
            except (OSError, UnicodeDecodeError) as err:
                raise CheckError(f"cannot read {argv[2]}: {err}") from err
            print(f"first-login-check: {argv[2]} lists {count} apps")
        else:
            print(__doc__.split("\n\n")[1], file=sys.stderr)
            return 64
    except CheckError as err:
        print(f"first-login-check: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
