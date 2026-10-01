#!/usr/bin/env python3
"""Bootc-only retirement decision and exact-object boundary; no R2 access."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PLAN = "plans/2026-09-24-native-ab-nbc-retirement-plan.md"
ADR = "adr/0018-remove-native-ab-and-nbc-lanes.md"
PREVIOUS = "adr/0017-gate-native-ab-and-nbc-disposal.md"
PATHS = ("ROADMAP.md", "README.md", "docs/nbc-to-bootc-migration.md",
         "docs/installing.md", "docs/native-ab-contracts.md",
         "docs/native-ab-publication.md", "docs/native-ab-capacities.md",
         "docs/native-ab-prototype-history.md", f"docs/{ADR}",
         f"docs/{PREVIOUS}", f"docs/{PLAN}", "docs/README.md",
         "shared/firn-installer/catalog.json", ".github/workflows/validate.yml")


def check(files: dict[str, str]) -> list[str]:
    errors = []

    def require(path: str, *markers: str) -> None:
        for marker in markers:
            if marker not in files[path]:
                errors.append(f"{path}: missing {marker!r}")

    require("ROADMAP.md", "2026-09-30", "bootc is the only", "ADR-0018")
    require("docs/nbc-to-bootc-migration.md", "Firn", "backup", "reinstall",
            "old nbc media", "no further images")
    if re.search(r"Installer media:.*(?:bootc-installer|fisherman|dakota-iso)",
                 files["docs/nbc-to-bootc-migration.md"].split("### Disk sizing")[0],
                 re.IGNORECASE | re.DOTALL):
        errors.append("migration: obsolete installer media attribution")
    require("docs/installing.md", "Firn", "2026-09-30", ADR,
            "untested", "waived")
    require("README.md", "four bootc choices", "Repository cleanup deletes no published artifacts", ADR)
    if "will be unavailable after" in files["README.md"]:
        errors.append("README.md: obsolete artifact availability claim")
    for path in ("docs/native-ab-contracts.md", "docs/native-ab-publication.md",
                 "docs/native-ab-capacities.md", "docs/native-ab-prototype-history.md"):
        require(path, "Historical", "ADR-0018")
    require(f"docs/{ADR}", "**Status:** Accepted", "bootc", "minideb",
            "Snowfield", "untested", "waive", "shared/native-ab/keys/",
            "isos/native/v1/", "redirect", "native-retention.yml",
            "never run successfully", "no R2 object", "exact-object", PLAN)
    require(f"docs/{PREVIOUS}", "**Status:** Superseded by [0018]")
    require(f"docs/{PLAN}", "**Status:** Superseded by [ADR-0018]",
            "read-only R2", "explicit maintainer authorization")
    require("docs/README.md", ADR, PREVIOUS, PLAN)
    catalog = files["shared/firn-installer/catalog.json"]
    for retired in ("snow-ab", "snowfield-ab", "floe-ab"):
        if retired in catalog:
            errors.append(f"catalog: retired choice {retired}")
    require(".github/workflows/validate.yml", "./test/retirement-plan-test.py")
    return errors


def main() -> int:
    files = {p: (ROOT / p).read_text() for p in PATHS}
    obsolete = files.copy()
    obsolete["shared/firn-installer/catalog.json"] += '\n"snow-ab"\n'
    if not any("retired choice" in e for e in check(obsolete)):
        raise SystemExit("native catalog regression fixture was not rejected")
    obsolete = files.copy()
    obsolete["docs/nbc-to-bootc-migration.md"] = obsolete["docs/nbc-to-bootc-migration.md"].replace(
        "### Disk sizing", "Installer media: bootc-installer / fisherman from dakota-iso\n\n### Disk sizing")
    if not any("obsolete installer media" in e for e in check(obsolete)):
        raise SystemExit("migration media regression fixture was not rejected")
    obsolete = files.copy()
    obsolete[f"docs/{PREVIOUS}"] = obsolete[f"docs/{PREVIOUS}"].replace(
        "**Status:** Superseded by [0018]", "**Status:** Proposed")
    if not any("Superseded" in e for e in check(obsolete)):
        raise SystemExit("ADR status regression fixture was not rejected")
    errors = check(files)
    if errors:
        raise SystemExit("\n".join(errors))
    print("bootc-only decision and disposal boundary: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
