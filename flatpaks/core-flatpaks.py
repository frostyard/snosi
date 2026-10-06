#!/usr/bin/env python3
"""Validate, label and check each product's core Flatpak set.

The files in this directory are the source of truth for the core Flatpak set
Firn installs when a recipe sets core_flatpaks = true. Each image build
publishes its product's set in the OCI label org.frostyard.core-flatpaks,
which Firn reads before installing (frostyard/firn ADR-0018). A product
mapped to no file publishes no label.

Commands:
  validate                 check every source file, the product mapping and
                           the generated first-setup list
  label PROFILE            print the buildah-package.sh label argument for
                           PROFILE, or nothing when it has no core set
  generate-first-setup     rewrite first-setup/core.json from snow.json
  check-image PROFILE      read `podman image inspect` JSON on stdin and check
                           the image's label matches PROFILE's file
"""

import json
import re
import sys
from pathlib import Path

LABEL = "org.frostyard.core-flatpaks"
FORMAT_VERSION = 1

DIR = Path(__file__).resolve().parent
ROOT = DIR.parent
FIRST_SETUP = DIR / "first-setup" / "core.json"

# Every bootc product profile must appear here, with None when the product
# intentionally has no core set. Snowfield shares Snow's list until it needs
# one of its own.
PRODUCTS = {
    "snow": "snow.json",
    "snowfield": "snow.json",
    "sundog": "sundog.json",
    "floe": None,
}
# mkosi.profiles entries that are not bootc products.
NON_PRODUCT_PROFILES = {"firn-installer"}

# Flatpak application IDs: at least three dot-separated elements of
# [A-Za-z0-9_-], none starting with a digit, '-' only in the last element,
# at most 255 characters.
_ELEMENT = r"[A-Za-z_][A-Za-z0-9_]*"
_LAST = r"[A-Za-z_-][A-Za-z0-9_-]*"
APP_ID = re.compile(rf"(?:{_ELEMENT}\.){{2,}}{_LAST}")


class Invalid(Exception):
    pass


def check_set(data, where):
    """Validate a parsed core set; producer rules are stricter than Firn's."""
    if not isinstance(data, dict):
        raise Invalid(f"{where}: top level must be a JSON object")
    extra = set(data) - {"version", "flatpaks"}
    if extra:
        raise Invalid(f"{where}: unknown field(s): {', '.join(sorted(extra))}")
    if data.get("version") != FORMAT_VERSION or isinstance(data.get("version"), bool):
        raise Invalid(f"{where}: version must be {FORMAT_VERSION}")
    apps = data.get("flatpaks")
    if not isinstance(apps, list) or not apps:
        raise Invalid(f"{where}: flatpaks must be a non-empty array "
                      "(a product with no core set has no file)")
    seen = set()
    for i, entry in enumerate(apps):
        at = f"{where}: flatpaks[{i}]"
        if not isinstance(entry, dict):
            raise Invalid(f"{at}: must be an object")
        extra = set(entry) - {"id", "name"}
        if extra:
            raise Invalid(f"{at}: unknown field(s): {', '.join(sorted(extra))}")
        app_id = entry.get("id")
        if not isinstance(app_id, str) or len(app_id) > 255 or not APP_ID.fullmatch(app_id):
            raise Invalid(f"{at}: invalid Flatpak application ID {app_id!r}")
        name = entry.get("name")
        if not isinstance(name, str) or not name.strip():
            raise Invalid(f"{at}: name must be a non-empty string")
        if app_id in seen:
            raise Invalid(f"{at}: duplicate id {app_id}")
        seen.add(app_id)
    return data


def load_set(path):
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as err:
        raise Invalid(f"{path.name}: {err}") from err
    return check_set(data, path.name)


def product_set(profile):
    if profile not in PRODUCTS:
        raise Invalid(f"unknown product profile {profile!r}; add it to PRODUCTS")
    name = PRODUCTS[profile]
    return None if name is None else load_set(DIR / name)


def compact(data):
    # Same bytes as `jq -c .` for these files.
    return json.dumps(data, separators=(",", ":"), ensure_ascii=False)


def first_setup_text():
    """first-setup's core.json shape, generated from Snow's set."""
    apps = load_set(DIR / "snow.json")["flatpaks"]
    core = [{"name": e["name"], "id": e["id"]} for e in apps]
    return json.dumps({"core": core}, indent=4, ensure_ascii=False) + "\n"


def cmd_validate():
    problems = []
    for name in sorted({n for n in PRODUCTS.values() if n}):
        try:
            load_set(DIR / name)
        except Invalid as err:
            problems.append(str(err))
    mapped = {n for n in PRODUCTS.values() if n}
    for path in sorted(DIR.glob("*.json")):
        if path.name not in mapped:
            problems.append(f"{path.name}: not mapped to any product in PRODUCTS")
    profiles = {p.name for p in (ROOT / "mkosi.profiles").iterdir() if p.is_dir()}
    for profile in sorted(profiles - NON_PRODUCT_PROFILES - set(PRODUCTS)):
        problems.append(f"profile {profile}: missing from PRODUCTS (map it to a file or None)")
    for profile in sorted(set(PRODUCTS) - profiles):
        problems.append(f"PRODUCTS entry {profile}: no such mkosi profile")
    try:
        if not FIRST_SETUP.exists() or FIRST_SETUP.read_text() != first_setup_text():
            problems.append(f"{FIRST_SETUP.relative_to(ROOT)} is out of date; "
                            "run: flatpaks/core-flatpaks.py generate-first-setup")
    except Invalid as err:
        problems.append(str(err))
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    return 1 if problems else 0


def cmd_label(profile):
    data = product_set(profile)
    if data is not None:
        print(f"{LABEL}={compact(data)}")
    return 0


def cmd_generate_first_setup():
    FIRST_SETUP.parent.mkdir(parents=True, exist_ok=True)
    FIRST_SETUP.write_text(first_setup_text())
    return 0


def cmd_check_image(profile, inspect_json):
    expected = product_set(profile)
    try:
        inspected = json.loads(inspect_json)
    except json.JSONDecodeError as err:
        raise Invalid(f"inspect output is not JSON: {err}") from err
    if isinstance(inspected, list):
        if len(inspected) != 1:
            raise Invalid(f"expected one inspected image, got {len(inspected)}")
        inspected = inspected[0]
    labels = (inspected.get("Labels") or inspected.get("Config", {}).get("Labels") or {})
    if expected is None:
        if LABEL in labels:
            raise Invalid(f"{profile} must not carry {LABEL}, found {labels[LABEL]!r}")
        print(f"ok: {profile} carries no {LABEL} label")
        return 0
    if LABEL not in labels:
        raise Invalid(f"{profile} image is missing {LABEL}")
    try:
        actual = json.loads(labels[LABEL])
    except json.JSONDecodeError as err:
        raise Invalid(f"{profile} {LABEL} is not JSON: {err}") from err
    check_set(actual, f"{profile} {LABEL}")
    if actual != expected:
        raise Invalid(f"{profile} {LABEL} does not match {PRODUCTS[profile]}")
    print(f"ok: {profile} {LABEL} matches {PRODUCTS[profile]} "
          f"({len(actual['flatpaks'])} apps)")
    return 0


def main(argv):
    try:
        match argv:
            case ["validate"]:
                return cmd_validate()
            case ["label", profile]:
                return cmd_label(profile)
            case ["generate-first-setup"]:
                return cmd_generate_first_setup()
            case ["check-image", profile]:
                return cmd_check_image(profile, sys.stdin.read())
            case _:
                print(__doc__, file=sys.stderr)
                return 2
    except Invalid as err:
        print(f"error: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
