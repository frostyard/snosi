#!/usr/bin/env python3
"""Static planning contract; does not access production objects."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PLAN = "plans/2026-09-24-native-ab-nbc-retirement-plan.md"
ADR = "adr/0017-gate-native-ab-and-nbc-disposal.md"
PATHS = ("ROADMAP.md", "README.md", "docs/native-ab-contracts.md",
         "docs/nbc-to-bootc-migration.md", "docs/installing.md",
         f"docs/{ADR}", f"docs/{PLAN}", "docs/README.md",
         "docs/org-adrs.md", ".github/workflows/validate.yml")


def check(files: dict[str, str]) -> list[str]:
    errors = []

    def require(path: str, *markers: str) -> None:
        for marker in markers:
            if marker not in files[path]:
                errors.append(f"{path}: missing {marker!r}")

    require("ROADMAP.md", "2026-09-30", "ADR-0052", "ADR-0050",
            "artifact-retention", PLAN)
    if "preserve history plus verifiable recovery artifacts" in files["ROADMAP.md"]:
        errors.append("ROADMAP.md: obsolete unconditional retention requirement")
    require("docs/nbc-to-bootc-migration.md", "Firn", "backup", "reinstall",
            "old nbc media", PLAN)
    if re.search(r"Installer media:.*(?:bootc-installer|fisherman|dakota-iso)",
                 files["docs/nbc-to-bootc-migration.md"].split("### Disk sizing")[0],
                 re.IGNORECASE | re.DOTALL):
        errors.append("migration: obsolete installer media attribution")
    require("docs/installing.md", "Firn", "2026-09-30", ADR, PLAN)
    require("README.md", "no longer receive updates or routine publication",
            "End of support does not itself remove published artifacts", ADR)
    if "will be unavailable after" in files["README.md"]:
        errors.append("README.md: obsolete artifact availability claim")
    require("docs/native-ab-contracts.md",
            "Phase 11 and 12-month overlap prerequisites were superseded",
            "ADR-0015", "ADR-0017", "ADR-0052", PLAN)
    if "No retirement decision before" in files["docs/native-ab-contracts.md"]:
        errors.append("native contracts: obsolete overlap prerequisite")
    require(f"docs/{ADR}", "**Status:** Proposed", "2026-09-30", "ADR-0052",
            "ADR-0050", "signed `stable`", "both maintainers", PLAN,
            "Enforced by: `test/retirement-plan-test.py`")
    require(f"docs/{PLAN}", "**Status:** Proposed", "2026-09-30",
            "2026-10-31", "both maintainers", "explicit maintainer authorization",
            "authenticated",
            "read-only R2", "SHA256SUMS.gpg", ".candidate/<version>/",
            ".history/<version>/", "os/native/v1/cayo/", "isos/native/v1/",
            "frostyard-nbc", "floe-ab-raw", "snow-ab", "snowfield-ab",
            "sundog", "snosi-installer_<version>_x86-64.iso",
            "native-retention.yml", "test/firn-catalog-test.sh", "signed `stable`")
    require("docs/README.md", ADR, PLAN)
    require("docs/org-adrs.md", "ADR-0050", "ADR-0052", "not yet operative")
    require(".github/workflows/validate.yml", "./test/retirement-plan-test.py",
            "./test/eol-notice-test.sh")
    return errors


def main() -> int:
    files = {p: (ROOT / p).read_text() for p in PATHS}
    obsolete = files.copy()
    obsolete["ROADMAP.md"] += "\npreserve history plus verifiable recovery artifacts\n"
    if not any("obsolete unconditional retention" in e for e in check(obsolete)):
        raise SystemExit("ROADMAP retention regression fixture was not rejected")
    obsolete = files.copy()
    obsolete["docs/nbc-to-bootc-migration.md"] = obsolete["docs/nbc-to-bootc-migration.md"].replace(
        "### Disk sizing", "Installer media: bootc-installer / fisherman from dakota-iso\n\n### Disk sizing")
    if not any("obsolete installer media" in e for e in check(obsolete)):
        raise SystemExit("migration media regression fixture was not rejected")
    errors = check(files)
    if errors:
        raise SystemExit("\n".join(errors))
    print("retirement plan and regression fixtures: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
