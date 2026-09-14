#!/usr/bin/env python3
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/build.yml"
JOB_PATTERN = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")
PERMISSION_PATTERN = re.compile(r"^      ([A-Za-z0-9_-]+):\s*(\S+)\s*$")


def fail(message: str) -> None:
    raise SystemExit(f"build-workflow-permissions-test: {message}")


def job_block(lines: list[str], name: str) -> list[str]:
    start = next(
        (index for index, line in enumerate(lines) if line == f"  {name}:"),
        None,
    )
    if start is None:
        fail(f"workflow has no {name!r} job")
    end = next(
        (
            index
            for index in range(start + 1, len(lines))
            if JOB_PATTERN.match(lines[index])
        ),
        len(lines),
    )
    return lines[start:end]


lines = WORKFLOW.read_text().splitlines()
workflow = "\n".join(lines)
build = job_block(lines, "build")

if "  pull_request:" not in workflow:
    fail("build workflow must retain its pull_request trigger")
if "permissions: {}" not in workflow:
    fail("workflow-level permissions must remain empty")
if not any("sudo -E mkosi build" in line for line in build):
    fail("test no longer covers the PR-controlled root mkosi build job")

try:
    permissions_start = build.index("    permissions:")
except ValueError as error:
    raise SystemExit(
        "build-workflow-permissions-test: build job has no explicit permissions"
    ) from error

permissions: dict[str, str] = {}
for line in build[permissions_start + 1 :]:
    match = PERMISSION_PATTERN.match(line)
    if match:
        permissions[match.group(1)] = match.group(2)
        continue
    if line.strip() and not line.startswith("      "):
        break

if permissions != {"contents": "read"}:
    fail(
        "PR-facing build job permissions must be exactly contents: read; "
        f"found {permissions}"
    )

for forbidden in ("packages: write", "id-token: write", "attestations: write"):
    if any(forbidden in line for line in build):
        fail(f"PR-facing build job restored forbidden grant {forbidden!r}")

# The publish-to-r2 action pin and the repogen binary it downloads are two
# separate pins. The action's repogen-version input defaults to "latest",
# which floated to v0.5.0 on 2026-09-14 and broke every publish (its sysext
# digest reconciliation hard-fails rebuilt, non-reproducible bytes before
# --skip-duplicates runs). Require an explicit tag equal to the release named
# in the action pin's trailing comment, so the binary can only move together
# with a reviewed action bump.
USES_PATTERN = re.compile(
    r"^\s+uses: frostyard/repogen/\.github/actions/publish-to-r2@[0-9a-f]{40}"
    r"\s+# (v\d+\.\d+\.\d+)\s*$"
)
VERSION_PATTERN = re.compile(r"^\s+repogen-version:\s*(\S+)\s*$")
uses_matches = [USES_PATTERN.match(line) for line in build]
uses_matches = [match for match in uses_matches if match]
if len(uses_matches) != 1:
    fail(
        "build job must use exactly one commit-pinned publish-to-r2 action "
        "with a trailing '# vX.Y.Z' release comment"
    )
action_release = uses_matches[0].group(1)
version_values = [
    match.group(1) for match in (VERSION_PATTERN.match(line) for line in build) if match
]
if version_values != [action_release]:
    fail(
        "publish-to-r2 step must set repogen-version to the action pin's own "
        f"release {action_release!r} (never 'latest' or absent); found {version_values}"
    )

print("build-workflow-permissions-test: PASSED")
