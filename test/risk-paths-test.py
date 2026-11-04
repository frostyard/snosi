#!/usr/bin/env python3
import json
import os
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RISK_PATH = ROOT / ".github/risk-paths.json"
POLICY_PATH = ROOT / "policies/agent-governance.json"
CALLER_PATH = ROOT / ".github/workflows/risk-paths.yml"
BUILD_PATH = ROOT / ".github/workflows/build.yml"
BUILD_IMAGES_PATH = ROOT / ".github/workflows/build-images.yml"
VALIDATE_PATH = ROOT / ".github/workflows/validate.yml"


def fail(message: str) -> None:
    raise SystemExit(f"risk-paths-test: {message}")


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


try:
    risk = json.loads(
        RISK_PATH.read_text(),
        object_pairs_hook=reject_duplicate_keys,
    )
except (OSError, json.JSONDecodeError, ValueError) as error:
    fail(f"cannot load .github/risk-paths.json: {error}")

if not isinstance(risk, dict) or set(risk) != {"schema_version", "paths"}:
    fail("top-level keys must be exactly schema_version and paths")
if isinstance(risk["schema_version"], bool) or not isinstance(risk["schema_version"], int):
    fail("schema_version must be integer 1")
if risk["schema_version"] != 1:
    fail("schema_version must be 1")

paths = risk["paths"]
if not isinstance(paths, list) or not paths:
    fail("paths must be a non-empty list")

globs = []
entries = []
for entry in paths:
    if not isinstance(entry, dict) or set(entry) != {"glob", "why"}:
        fail("each risk-path entry must contain exactly glob and why")
    glob = entry["glob"]
    why = entry["why"]
    if not isinstance(glob, str) or not glob:
        fail("each glob must be a non-empty string")
    if not isinstance(why, str) or not why:
        fail("each why must be a non-empty string")
    if len(why) > 200:
        fail(f"why exceeds 200 characters: {glob}")
    globs.append(glob)
    entries.append((glob, why))
if len(globs) != len(set(globs)):
    fail("globs must be unique")

try:
    policy = json.loads(POLICY_PATH.read_text())
except (OSError, json.JSONDecodeError) as error:
    fail(f"cannot load policies/agent-governance.json: {error}")
boundaries = policy.get("protectedBoundaries") if isinstance(policy, dict) else None
if not isinstance(boundaries, list) or not all(isinstance(item, str) for item in boundaries):
    fail("protectedBoundaries must be a list of names")
boundary_set = set(boundaries)
for glob, why in entries:
    match = re.fullmatch(r"([^:]+): (.+)", why)
    if not match:
        fail(f"why must use boundary: text form: {glob}")
    boundary, text = match.groups()
    if boundary not in boundary_set:
        fail(f"unknown protected boundary {boundary}: {glob}")
    if not text:
        fail(f"why text must not be empty: {glob}")

required_globs = {
    ".github/risk-paths.json",
    ".github/workflows/risk-paths.yml",
}
if not required_globs.issubset(set(globs)):
    fail("risk list must include the list and caller globs")


def expand_braces(glob: str):
    match = re.search(r"\{([^{}]+)\}", glob)
    if not match:
        return [glob]
    choices = match.group(1).split(",")
    prefix = glob[:match.start()]
    suffix = glob[match.end():]
    expansions = []
    for choice in choices:
        expansions.extend(expand_braces(prefix + choice + suffix))
    return expansions


def glob_to_regex(expansion: str):
    segments = expansion.split("/")
    pattern = ""
    for index, segment in enumerate(segments):
        if segment == "**":
            if index == 0:
                if index == len(segments) - 1:
                    pattern += "(?:[^/]+(?:/[^/]+)*)?"
                else:
                    pattern += "(?:[^/]+/)*"
            elif index == len(segments) - 1:
                pattern += "(?:/[^/]+)*"
            else:
                pattern += "(?:/[^/]+)*?/"
            continue

        if index > 0:
            if segments[index - 1] != "**":
                pattern += "/"
        segment_pattern = ""
        for char in segment:
            if char == "*":
                segment_pattern += "[^/]*"
            elif char == "?":
                segment_pattern += "[^/]"
            else:
                segment_pattern += re.escape(char)
        pattern += segment_pattern
    return re.compile(r"^" + pattern + r"$")


repository_files = []
for directory, folder_names, file_names in os.walk(ROOT):
    if ".git" in folder_names:
        folder_names.remove(".git")
    for file_name in file_names:
        repository_files.append(
            (Path(directory) / file_name).relative_to(ROOT).as_posix()
        )

for glob in globs:
    expansions = expand_braces(glob)
    for expansion in expansions:
        if "*" not in expansion and "?" not in expansion:
            if not (ROOT / expansion).is_file():
                fail(f"stale risk-path glob: {glob}")

    if any("*" in expansion or "?" in expansion for expansion in expansions):
        matched = False
        for expansion in expansions:
            matcher = glob_to_regex(expansion)
            if any(matcher.fullmatch(repository_file) for repository_file in repository_files):
                matched = True
                break
        if not matched:
            fail(f"stale risk-path glob: {glob}")

try:
    caller = CALLER_PATH.read_text()
except OSError as error:
    fail(f"cannot load .github/workflows/risk-paths.yml: {error}")
if "  pull_request_target:" not in caller:
    fail("caller must contain pull_request_target")
if "    types: [opened, synchronize, reopened, edited]" not in caller:
    fail("caller types must remain the documented pull_request_target types")
if re.search(r"^  merge_group:", caller, re.MULTILINE):
    fail("caller must not contain merge_group")
if re.search(r"^  pull_request:$", caller, re.MULTILINE):
    fail("caller must not use the pull_request trigger")
if "actions/checkout" in caller:
    fail("caller must not check out pull request code")
if "secrets:" in caller:
    fail("caller must not declare secrets")
if not re.search(r"^permissions: \{\}$", caller, re.MULTILINE):
    fail("caller top-level permissions must be {}")

permission_full_lines = re.findall(r"^[ ]+[a-z-]+: (?:read|write)$", caller, re.MULTILINE)
permission_full_set = set(permission_full_lines)
if len(permission_full_lines) != 2:
    fail("job permissions must be exactly contents: read and pull-requests: write")
if permission_full_set != {"      contents: read", "      pull-requests: write"}:
    fail("job permissions must be exactly contents: read and pull-requests: write")

uses_lines = re.findall(r"^[ -]*uses:.*$", caller, re.MULTILINE)
if len(uses_lines) != 1:
    fail("caller must contain exactly one uses line")
if not re.fullmatch(r"    uses: frostyard/core/\.github/workflows/risk-paths\.yml@[0-9a-f]{40}( #.*)?", uses_lines[0]):
    fail("uses line must pin the core risk-paths workflow to a 40-character commit")

for workflow_path in (BUILD_PATH, BUILD_IMAGES_PATH):
    try:
        workflow = workflow_path.read_text()
    except OSError as error:
        fail(f"cannot load {workflow_path.relative_to(ROOT)}: {error}")
    if workflow.count('- ".github/risk-paths.json"') != 2:
        fail(f"{workflow_path.relative_to(ROOT)} must ignore the risk list twice")
    if workflow.count('- ".github/workflows/risk-paths.yml"') != 2:
        fail(f"{workflow_path.relative_to(ROOT)} must ignore the caller twice")

try:
    validate = VALIDATE_PATH.read_text()
except OSError as error:
    fail(f"cannot load .github/workflows/validate.yml: {error}")
command = "python3 ./test/risk-paths-test.py"
if validate.count(command) != 1:
    fail("validate.yml must run risk-paths-test.py exactly once")

print(f"risk-paths-test: PASSED ({len(entries)} entries, {len(repository_files)} repository files scanned)")
