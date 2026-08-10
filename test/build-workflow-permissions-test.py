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

print("build-workflow-permissions-test: PASSED")
