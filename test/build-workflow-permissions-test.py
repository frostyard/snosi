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
    r"^\s+uses: frostyard/repogen/\.github/actions/publish-to-r2@([0-9a-f]{40})"
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
action_commit = uses_matches[0].group(1)
action_release = uses_matches[0].group(2)
version_values = [
    match.group(1) for match in (VERSION_PATTERN.match(line) for line in build) if match
]
if version_values != [action_release]:
    fail(
        "publish-to-r2 step must set repogen-version to the action pin's own "
        f"release {action_release!r} (never 'latest' or absent); found {version_values}"
    )

# Since v0.7.0 the action also requires the exact commit its release binary
# embeds; it is the action pin's own commit.
COMMIT_PATTERN = re.compile(r"^\s+repogen-commit:\s*(\S+)\s*$")
commit_values = [
    match.group(1) for match in (COMMIT_PATTERN.match(line) for line in build) if match
]
if commit_values != [action_commit]:
    fail(
        "publish-to-r2 step must set repogen-commit to the action pin's own "
        f"commit {action_commit!r}; found {commit_values}"
    )


def step_block(name: str) -> list[str]:
    start = next(
        (i for i, line in enumerate(build) if line == f"      - name: {name}"),
        None,
    )
    if start is None:
        fail(f"build job has no {name!r} step")
    end = next(
        (i for i in range(start + 1, len(build)) if build[i].startswith("      - ")),
        len(build),
    )
    return build[start:end]


# repogen v0.7.0 fails the whole publish on a rebuilt, already-published
# identity, so the publish must only ever see what drop-published.sh left,
# and must not run when it left nothing (the action fails on 0 packages).
PREFILTER = "Drop sysexts that are already published"
PUBLISH = "Publish sysexts to frostyard repo"
prefilter = step_block(PREFILTER)
publish = step_block(PUBLISH)
if build.index(f"      - name: {PREFILTER}") > build.index(f"      - name: {PUBLISH}"):
    fail("the pre-filter step must run before the publish step")
if "        id: prefilter" not in prefilter:
    fail("the pre-filter step must set id: prefilter")
if not any(
    "./shared/sysext/publish/drop-published.sh ./output/sysexts" in line
    for line in prefilter
):
    fail("the pre-filter step must run drop-published.sh on ./output/sysexts")
if not any(line.strip() == "R2_BUCKET: frostyardrepo" for line in prefilter):
    fail("the pre-filter must read the bucket the publish step writes")
if not any(line.strip() == "packages-dir: ./output/sysexts" for line in publish):
    fail("the publish step must publish ./output/sysexts")
publish_if = [line.strip() for line in publish if line.strip().startswith("if:")]
if publish_if != [
    "if: github.event_name != 'pull_request' && "
    "steps.prefilter.outputs.publish == 'true'"
]:
    fail(f"the publish step must be gated on the pre-filter result; found {publish_if}")

# A cancel during the R2 upload can leave SHA256SUMS and its signature out of
# step, which v0.7.0 refuses until a person repairs it: a run that publishes
# (any non-PR event) must never be cancelled by a newer run.
CANCEL_PATTERN = re.compile(r"^  cancel-in-progress:\s*(.+?)\s*$")
cancel = [m.group(1) for m in (CANCEL_PATTERN.match(line) for line in lines) if m]
if cancel != ["${{ github.event_name == 'pull_request' }}"]:
    fail(
        "workflow concurrency may cancel only pull_request runs, never a "
        f"publishing push run; found {cancel}"
    )

print("build-workflow-permissions-test: PASSED")
