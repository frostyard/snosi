#!/usr/bin/env python3
import json
import re
import subprocess
from functools import lru_cache
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


def validate_glob(glob):
    errors = []
    if not isinstance(glob, str):
        return ["glob is not a string"]
    if not glob:
        return ["glob is empty"]
    if any(char in glob for char in "[]!\\"):
        errors.append("glob contains a forbidden character")
    depth = 0
    for char in glob:
        if char == "{":
            depth += 1
            if depth > 1:
                errors.append("nested brace groups are forbidden")
        elif char == "}":
            depth -= 1
            if depth < 0:
                errors.append("unmatched closing brace")
                depth = 0
    if depth > 0:
        errors.append("unmatched opening brace")
    if errors:
        return sorted(set(errors))

    for group in re.findall(r"\{([^{}]*)\}", glob):
        alternatives = group.split(",")
        if len(alternatives) < 2:
            errors.append("brace group has fewer than 2 alternatives")
        if any(alternative == "" for alternative in alternatives):
            errors.append("brace group has an empty alternative")

    expansions = expand_braces(glob)
    if len(expansions) > 256:
        errors.append("brace expansion exceeds 256 alternatives")

    for expansion in expansions:
        if expansion.startswith("/"):
            errors.append("glob has a leading slash")
        if expansion.startswith("./"):
            errors.append("glob has a leading ./")
        segments = expansion.split("/")
        if any(segment == "" for segment in segments):
            errors.append("glob has an empty segment")
        if ".." in segments:
            errors.append("glob contains a .. segment")
        for segment in segments:
            if "**" in segment and segment != "**":
                errors.append("a segment containing ** must be exactly **")
    return sorted(set(errors))


def segment_matches(pattern: str, text: str):
    regex = ""
    for char in pattern:
        if char == "*":
            regex += ".*"
        elif char == "?":
            regex += "."
        else:
            regex += re.escape(char)
    return re.fullmatch(regex, text) is not None


def glob_matches(glob: str, path: str):
    glob_segments = glob.split("/")
    path_segments = path.split("/")

    @lru_cache(maxsize=None)
    def match(glob_index: int, path_index: int):
        if glob_index == len(glob_segments):
            return path_index == len(path_segments)
        glob_segment = glob_segments[glob_index]
        if glob_segment == "**":
            return match(glob_index + 1, path_index) or (
                path_index < len(path_segments) and match(glob_index, path_index + 1)
            )
        if path_index == len(path_segments):
            return False
        return segment_matches(glob_segment, path_segments[path_index]) and match(glob_index + 1, path_index + 1)

    return match(0, 0)


self_test_cases = 0
validation_cases = {
    "shared/bootc-secure/***": True,
    "a**": True,
    "{a}": True,
    "{a,}": True,
    "{a,{b,c}}": True,
    "a/../b": True,
    "/a": True,
    "./a": True,
    "a[b]": True,
    "a}b{c": True,
    "a{b,c": True,
    "shared/**/**": False,
    ".github/workflows/{build,build-images}.yml": False,
}
for glob, must_fail in validation_cases.items():
    self_test_cases += 1
    if bool(validate_glob(glob)) != must_fail:
        fail(f"self-test failed for validate_glob({glob!r})")

matcher_cases = [
    ("shared/**/**", "shared/a", True),
    ("shared/**/**", "shared/a/b", True),
    ("**/x", "x", True),
    ("**/x", "a/b/x", True),
    ("**/x", "a/x/y", False),
    ("x*", "xy", True),
    ("x*", "a/xy", False),
    ("docs/*.md", "docs/.md", True),
    ("docs/*.md", "docs/a/b.md", False),
    ("**", ".github/x.yml", True),
]
for glob, path, expected in matcher_cases:
    self_test_cases += 1
    if glob_matches(glob, path) != expected:
        fail(f"self-test failed for matcher {glob!r}, {path!r}")


try:
    risk = json.loads(RISK_PATH.read_text(), object_pairs_hook=reject_duplicate_keys)
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
    glob_errors = validate_glob(glob)
    if glob_errors:
        fail(f"invalid glob {glob}: {', '.join(glob_errors)}")
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

required_globs = {".github/risk-paths.json", ".github/workflows/risk-paths.yml"}
if not required_globs.issubset(set(globs)):
    fail("risk list must include the list and caller globs")

git_result = subprocess.run(
    ["git", "-C", str(ROOT), "ls-files", "-z"],
    capture_output=True,
    check=False,
)
if git_result.returncode != 0:
    fail("cannot obtain tracked files: git ls-files failed")
tracked_files = set(filter(None, git_result.stdout.decode("utf-8", "surrogateescape").split("\0")))
if not tracked_files:
    fail("cannot obtain tracked files: git ls-files returned no files")

for glob in globs:
    expansions = expand_braces(glob)
    wildcard = any("*" in expansion or "?" in expansion for expansion in expansions)
    if not wildcard:
        for expansion in expansions:
            if expansion not in tracked_files:
                fail(f"stale risk-path glob: {glob}")
    else:
        matched = False
        for expansion in expansions:
            if any(glob_matches(expansion, tracked_file) for tracked_file in tracked_files):
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

permission_lines = []
for line in caller.splitlines():
    match = re.match(r"^([ ]+[a-z-]+):[ ]*(read|write|none)\b", line)
    if match:
        permission_lines.append(f"{match.group(1)}: {match.group(2)}")
if len(permission_lines) != 2:
    fail("job permissions must be exactly contents: read and pull-requests: write")
if set(permission_lines) != {"      contents: read", "      pull-requests: write"}:
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

print(f"risk-paths-test: PASSED ({len(entries)} entries, {len(tracked_files)} tracked files, {self_test_cases} self-test cases)")
