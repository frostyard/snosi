#!/usr/bin/env python3
"""Static gate for frostyard/core ADR-0021 across .github/workflows/ (#1274).

Every workflow must keep three properties:

  1. every remote `uses:` pins a 40-character lowercase commit SHA and carries
     a trailing `# vX[.Y[.Z]]` release comment; only the untagged repositories
     in BRANCH_PIN_ALLOW may name a default-branch commit, with its own
     dated comment, because they publish no release tags;
  2. each workflow declares exactly one top-level `permissions:` of `{}` or
     read-only (`read`/`none`) grants, so a job opts in to write scope itself;
  3. every `actions/checkout@` step sets `persist-credentials: false` in its
     `with:` block, so the job token never stays in `.git/config`.

The parse is line based on purpose: CI python may not ship PyYAML, and the
shapes this gate reads (`uses:` keys, top-level `permissions:`) are simple.
Anything it cannot parse it reports instead of skipping, so the gate fails
closed.
"""

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
MAKEFILE = ROOT / "Makefile"
VALIDATE = WORKFLOWS / "validate.yml"
NIGHTLY = WORKFLOWS / "nightly-compliance.yml"
COMMAND = "python3 ./test/workflow-pins-test.py"
PREFIX = "workflow-pins-test:"

# Action repositories pinned to an untagged default-branch commit. Each entry
# accepts its own dated branch comment beside the usual `# vX[.Y[.Z]]` form.
BRANCH_PIN_ALLOW = {
    "systemd/mkosi": {
        "comment": r"^# main \d{4}-\d{2}-\d{2}$",
        "reason": (
            "snosi pins mkosi to a main commit newer than the last release; "
            "the Justfile and the ISO helpers bootstrap the same commit "
            "(ADR-0011)."
        ),
    },
    "ublue-os/container-storage-action": {
        "comment": r"^# main \d{4}-\d{2}-\d{2}$",
        "reason": "the repository publishes no release tags.",
    },
    "frostyard/changelog-generator": {
        "comment": r"^# main \d{4}-\d{2}-\d{2}$",
        "reason": "the repository publishes no release tags.",
    },
    "frostyard/core": {
        "comment": r"^# frostyard/core main, \d{4}-\d{2}-\d{2}( \(.*\))?$",
        "reason": "core publishes no release tags.",
    },
}

# `permissions: read-all` is accepted only for the workflow whose job replaces
# the top-level grant with its own scopes.
READ_ALL_ALLOW = {
    "scorecard.yml": (
        "OpenSSF scorecard-action's documented workflow form; its only job "
        "sets its own job permissions, which replace the top-level grant."
    ),
}

USES_KEY = re.compile(r"^([ ]*)(-[ ]+)?(\"uses\"|'uses'|uses)\s*:\s*(.*)$")
USES_ANY = re.compile(r"(^|[\s{\[,])(?:\"uses\"|'uses'|uses)\s*:")
SEQUENCE_PREFIX = re.compile(r"^([ ]*)((?:-[ ]+)*)(.*)$")
BLOCK_INDICATOR = re.compile(r"[|>](?:[0-9][+-]?|[+-][0-9]?)?\s*(?:#.*)?")
BLOCK_KEY = re.compile(
    r"(?:[^\s#][^:]*|\"[^\"]*\"|'[^']*')\s*:[ ]*"
    r"[|>](?:[0-9][+-]?|[+-][0-9]?)?\s*(?:#.*)?"
)
PERMISSIONS = re.compile(r"^permissions\s*:")
PERMISSIONS_VALUE = re.compile(r"^permissions\s*:\s*(.*)$")
PERMISSION_ENTRY = re.compile(r"^[ ]+([A-Za-z0-9_-]+)\s*:\s*(\S+)\s*(?:#.*)?$")
PIN_COMMENT = re.compile(r"# v\d+(\.\d+){0,2}")
COMMIT = re.compile(r"[0-9a-f]{40}")
DOCKER_DIGEST = re.compile(r"docker://[^\s@]+@sha256:[0-9a-f]{64}")
PERSIST_KEY = re.compile(r"persist-credentials\s*:")
PERSIST = re.compile(r"persist-credentials\s*:\s*false\s*(?:#.*)?")
WITH_KEY = re.compile(r"[ ]*with\s*:")


def fail(message: str) -> None:
    raise SystemExit(f"{PREFIX} {message}")


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


QUOTED = re.compile(r"'(?:[^']|'')*'|\"(?:[^\"\\]|\\.)*\"")
EXPRESSION = re.compile(r"\$\{\{.*?\}\}")
DOUBLE_QUOTED_KEY = re.compile(r'"((?:[^"\\]|\\.)*)"\s*:')
FLOW_VALUE = re.compile(r"(?:[^\s#{\[!?\"'][^:]*?|\"x*\"|'x*')\s*:\s+(?=[{\[])")


def blank_text(text: str) -> str:
    """The same line, with GitHub expressions and quoted text masked.

    The result has the same length, so an index found in it (a comment start,
    a flow collection start) is valid in the original line.
    """
    text = EXPRESSION.sub(lambda match: "x" * len(match.group()), text)
    return QUOTED.sub(
        lambda match: match.group()[0]
        + "x" * (len(match.group()) - 2)
        + match.group()[-1],
        text,
    )


def strip_comment(text: str) -> str:
    """The line without its YAML comment: a `#` outside quotes, after a space."""
    blanked = blank_text(text)
    for index, char in enumerate(blanked):
        if char == "#" and (index == 0 or blanked[index - 1] in " \t"):
            return text[:index]
    return text


def key_syntax_error(rest: str) -> str | None:
    r"""Message for key syntax a line scan cannot decode, or None.

    `rest` is the line without its indentation, `- ` prefixes and comment.
    YAML decodes escapes in a double-quoted key, so `"us\u0065s"` is the key
    `uses`; a complex key (`? uses`) and a tagged key (`!!str uses:`) also
    hide the real key name. Do not decode these shapes: fail closed instead.
    Keys appear only at the start of the node or inside a flow collection
    (`{...}`, `[...]`); a plain scalar value such as `run: echo Hello, !`
    holds no key and is not checked.
    """
    blanked = blank_text(rest)
    quoted_key = DOUBLE_QUOTED_KEY.match(rest)
    if quoted_key is not None and "\\" in quoted_key.group(1):
        return (
            "escaped quoted key; write the key plain (a backslash escape "
            "hides the real key name)"
        )
    if blanked == "?" or blanked.startswith("? "):
        return "complex mapping key (`?`) is not supported"
    if blanked.startswith("!"):
        return "tagged mapping key (`!`) is not supported"
    if blanked[:1] in ("{", "["):
        flow_start = 0
    else:
        flow_value = FLOW_VALUE.match(blanked)
        if flow_value is None:
            return None
        flow_start = flow_value.end()
    flow = rest[flow_start:]
    flow_blanked = blanked[flow_start:]
    # A flow collection that spans lines would put keys on continuation
    # lines that this scan does not read as flow content.
    depth = 0
    for char in flow_blanked:
        if char in "{[":
            depth += 1
        elif char in "}]":
            depth -= 1
    if depth != 0:
        return "multi-line flow collection is not supported; close it on one line"
    for quoted in re.finditer(r'"((?:[^"\\]|\\.)*)"(\s*:)?', flow):
        if quoted.group(2) and "\\" in quoted.group(1):
            return (
                "escaped quoted key; write the key plain (a backslash escape "
                "hides the real key name)"
            )
    if re.search(r"[{\[,]\s*\?(\s|$)", flow_blanked):
        return "complex mapping key (`?`) is not supported"
    if re.search(r"[{\[,]\s*!", flow_blanked):
        return "tagged mapping key (`!`) is not supported"
    return None


def block_scalar_parent(line: str) -> int | None:
    """Column of the key (or of a bare `-` entry) that owns this block scalar.

    The block belongs to the KEY, not to the `-` that may precede it, so
    `      - name: |` blocks content past column 8, and the `uses:` key at
    column 8 stays visible to the scan.
    """
    match = SEQUENCE_PREFIX.match(line)
    if match is None:
        return None
    prefix = len(match.group(1)) + len(match.group(2))
    rest = match.group(3)
    if BLOCK_INDICATOR.fullmatch(rest):
        # A bare sequence entry, `- |`: the last dash is the parent node.
        return max(prefix - 2, 0)
    if BLOCK_KEY.fullmatch(rest):
        return prefix
    return None


def block_scalar_lines(lines: list[str]) -> set[int]:
    """Indexes of lines that belong to a `key: |` or `key: >` block scalar."""
    inside: set[int] = set()
    parent = -1
    for index, line in enumerate(lines):
        if parent >= 0:
            if line.strip() == "" or indent_of(line) > parent:
                inside.add(index)
                continue
            parent = -1
        column = block_scalar_parent(line)
        if column is not None:
            parent = column
    return inside


def check_workflow(name: str, text: str) -> list[str]:
    """Return one error string per violation of the 3 ADR-0021 rules."""
    lines = text.splitlines()
    errors: list[str] = []

    def error(line_index: int, message: str) -> None:
        errors.append(f"{name}:{line_index + 1}: {message}")

    in_block = block_scalar_lines(lines)

    # Rule 2: exactly one top-level `permissions:`, and it grants no write.
    permission_indexes = [
        index for index, line in enumerate(lines) if PERMISSIONS.match(line)
    ]
    if not permission_indexes:
        error(
            0,
            "no top-level `permissions:`; declare `permissions: {}` or "
            "read-only grants",
        )
    else:
        for extra in permission_indexes[1:]:
            error(extra, "duplicate top-level `permissions:`")
        index = permission_indexes[0]
        value = PERMISSIONS_VALUE.match(lines[index]).group(1).strip()
        if value.startswith("#"):
            value = ""
        elif "#" in value:
            value = value[: value.index("#")].strip()
        if value in ("{}", "read-all"):
            if value == "read-all" and Path(name).name not in READ_ALL_ALLOW:
                error(
                    index,
                    "top-level `permissions: read-all` is not allowed; declare "
                    "read-only scopes or use `permissions: {}`",
                )
        elif value == "write-all":
            error(index, "top-level `permissions: write-all` is forbidden")
        elif value == "":
            entries: list[tuple[int, str, str]] = []
            for other in range(index + 1, len(lines)):
                line = lines[other]
                if line.strip() == "" or line.strip().startswith("#"):
                    continue
                if indent_of(line) == 0:
                    break
                entry = PERMISSION_ENTRY.match(line)
                if not entry:
                    error(
                        other,
                        "unrecognized top-level permissions entry; use "
                        "`<scope>: read` or `<scope>: none`",
                    )
                    continue
                entries.append((other, entry.group(1), entry.group(2)))
            if not entries:
                error(
                    index,
                    "empty top-level permissions block; write `permissions: {}`",
                )
            for other, scope, access in entries:
                if access not in ("read", "none"):
                    error(
                        other,
                        f"top-level permissions grant `{scope}: {access}`; "
                        "only `read` or `none` is allowed",
                    )
        else:
            error(
                index,
                "top-level permissions must be `{}` or a block mapping of "
                f"read/none grants; found `{value}`",
            )

    # Rules 1 and 3: every `uses:` line.
    for index, line in enumerate(lines):
        if index in in_block:
            continue
        if line.strip().startswith("#"):
            continue
        # A key this scan cannot read would hide an unpinned action, so any
        # such shape is an error before the `uses:` check runs.
        rest = strip_comment(line).lstrip(" ")
        while rest.startswith("- "):
            rest = rest[2:].lstrip(" ")
        message = key_syntax_error(rest.rstrip())
        if message is not None:
            error(index, message)
        match = USES_KEY.match(line)
        if not match:
            if USES_ANY.search(strip_comment(line)):
                error(
                    index,
                    "unrecognized uses form; write `uses:` as a plain key on "
                    "its own line",
                )
            continue
        column = len(match.group(1)) + len(match.group(2) or "")
        value = match.group(4).strip()
        if not value:
            error(index, "unrecognized uses form: `uses:` has no value")
            continue
        if "#" in value:
            cut = value.index("#")
            reference = value[:cut].strip()
            comment = value[cut:].rstrip()
        else:
            reference = value.rstrip()
            comment = None
        if (
            len(reference) >= 2
            and reference[0] == reference[-1]
            and reference[0] in "'\""
        ):
            reference = reference[1:-1]
        if not reference:
            error(index, "unrecognized uses form: `uses:` has no reference")
            continue
        if reference.startswith("./"):
            # A local action lives in this commit; there is nothing to pin.
            continue
        if reference.startswith("docker://"):
            if not DOCKER_DIGEST.fullmatch(reference):
                error(
                    index,
                    f"docker reference `{reference}` must pin a digest "
                    "(`@sha256:` and 64 hex characters)",
                )
            continue
        if "@" not in reference:
            error(
                index,
                f"action reference `{reference}` must pin a 40-character "
                "lowercase commit SHA",
            )
            continue
        repo_path, pin = reference.rsplit("@", 1)
        segments = repo_path.split("/")
        if len(segments) < 2 or any(segment == "" for segment in segments):
            error(
                index,
                f"action reference `{reference}` must be "
                "`owner/repo[/path]@<40 hex>`",
            )
            continue
        repo = "/".join(segments[:2])
        if not COMMIT.fullmatch(pin):
            error(
                index,
                f"action `{repo}` must pin a 40-character lowercase commit "
                f"SHA, not `{pin}`",
            )
            continue
        allowed = BRANCH_PIN_ALLOW.get(repo)
        if comment is None:
            error(
                index,
                f"pinned action `{repo}` needs a trailing `# vX[.Y[.Z]]` "
                "comment",
            )
        elif PIN_COMMENT.fullmatch(comment):
            pass
        elif allowed is not None and re.fullmatch(allowed["comment"], comment):
            pass
        elif allowed is None and re.match(r"# main\b", comment):
            error(
                index,
                f"pinned action `{repo}` names a branch (`{comment}`) but is "
                "not in BRANCH_PIN_ALLOW; only an untagged allow-listed "
                "repository accepts a branch comment",
            )
        else:
            error(
                index,
                f"pinned action `{repo}` has an unrecognized pin comment "
                f"`{comment}`; expected `# vX[.Y[.Z]]`",
            )
        if not reference.startswith("actions/checkout@"):
            continue
        # Rule 3: the checkout step must not persist the job token. There is
        # deliberately no exception list: none exists today, and a job that
        # must push would need a reasoned exception added here.
        step_indent = column - 2
        start = None
        for other in range(index, -1, -1):
            candidate = lines[other]
            if step_indent < 0 or indent_of(candidate) != step_indent:
                continue
            rest = candidate[step_indent + 1 :]
            if candidate[step_indent : step_indent + 1] == "-" and (
                rest == "" or rest.startswith(" ")
            ):
                start = other
                break
        if start is None:
            error(
                index,
                "cannot locate the `- ` step line of this actions/checkout "
                "step",
            )
            continue
        end = len(lines)
        for other in range(start + 1, len(lines)):
            candidate = lines[other]
            if candidate.strip() == "" or candidate.strip().startswith("#"):
                continue
            if indent_of(candidate) <= step_indent:
                end = other
                break
        with_index = None
        for other in range(start, end):
            if indent_of(lines[other]) == column and WITH_KEY.match(lines[other]):
                with_index = other
                break
        # Only the DIRECT children of the `with:` block count. A deeper line,
        # or a line inside a `key: |` scalar (for example a sparse-checkout
        # pattern list), never sets the credential policy. A flow-form
        # `with: {...}` has no children and fails closed.
        entries: list[tuple[int, str]] = []
        if with_index is not None:
            child_indent = None
            for other in range(with_index + 1, end):
                candidate = lines[other]
                if candidate.strip() == "" or candidate.strip().startswith("#"):
                    continue
                if indent_of(candidate) <= column:
                    break
                if other in in_block:
                    continue
                if child_indent is None:
                    child_indent = indent_of(candidate)
                if indent_of(candidate) != child_indent:
                    continue
                text = candidate[child_indent:]
                if PERSIST_KEY.match(text):
                    entries.append((other, text))
        if len(entries) > 1:
            error(
                entries[1][0],
                "actions/checkout step sets `persist-credentials` more than "
                "once (duplicate); exactly one `persist-credentials: false` "
                "is required",
            )
        elif len(entries) != 1 or not PERSIST.fullmatch(entries[0][1]):
            error(
                index,
                "actions/checkout step must set `persist-credentials: false` "
                "in its `with:` block",
            )

    return errors


def self_test() -> int:
    """Run the built-in fixtures; every one must produce the expected result."""
    cases = 0

    def run(
        label: str, fixture: str, expected: str | None, filename: str | None = None
    ) -> None:
        nonlocal cases
        cases += 1
        found = check_workflow(filename or f"fixture-{label}", fixture)
        if expected is None:
            if found:
                fail(f"self-test {label} must pass but reported: {found[0]}")
            return
        if not found:
            fail(f"self-test {label} must fail with {expected!r} but passed")
        if not any(expected in item for item in found):
            fail(
                f"self-test {label} must fail with {expected!r} but reported: "
                f"{found}"
            )

    good = (
        "# A comment that mentions uses: is not a pin.\n"
        "permissions: {}\n"
        "jobs:\n"
        "  verify:\n"
        "    runs-on: ubuntu-latest\n"
        "    steps:\n"
        "      - name: Checkout repository\n"
        "        uses: actions/checkout@"
        "3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
        "        with:\n"
        "          persist-credentials: false\n"
        "      - name: Local action\n"
        "        uses: ./.github/actions/local\n"
        "      - name: Script output only\n"
        "        run: |\n"
        '          echo "uses: actions/checkout@v4"\n'
        "          # uses: nothing here either\n"
    )
    run("good", good, None)
    run(
        "quoted",
        "permissions: {}\n"
        "jobs:\n"
        "  a:\n"
        "    steps:\n"
        '      - uses: "actions/checkout@'
        '3d3c42e5aac5ba805825da76410c181273ba90b1" # v7.0.1\n'
        "        with:\n"
        "          persist-credentials: false  # never keep the token\n",
        None,
    )
    run(
        "branch-allow-listed",
        "permissions: {}\n"
        "jobs:\n"
        "  a:\n"
        "    steps:\n"
        "      - uses: systemd/mkosi@"
        "a6753e508681aa162cef4e5183f1a728c11c4d78 # main 2026-11-05\n",
        None,
    )
    # A `- name: |` block scalar must not hide the `uses:` key that follows
    # it: the block belongs to the key column, not to the `-` column.
    run(
        "good-block-scalar-name",
        "permissions: {}\njobs:\n  a:\n    steps:\n"
        "      - name: |\n"
        "          Checkout repository\n"
        "        uses: actions/checkout@"
        "3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
        "        with:\n"
        "          persist-credentials: false\n",
        None,
    )
    # A `run: |` script may mention `uses:` and `persist-credentials:` freely.
    run(
        "good-run-scalar",
        "permissions: {}\njobs:\n  a:\n    steps:\n"
        "      - name: Script step\n"
        "        run: |\n"
        '          echo "uses: actions/checkout@v4"\n'
        "          persist-credentials: true\n"
        "      - name: Checkout repository\n"
        "        uses: actions/checkout@"
        "3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
        "        with:\n"
        "          persist-credentials: false\n",
        None,
    )
    # A plain scalar value and an inline comment hold no key: commas, `!`,
    # `?` and escaped quotes there are not key syntax.
    run(
        "good-scalar-and-comment-punctuation",
        "on:\n  push:\n    branches: [main, 'a, !b']\n"
        "permissions: {}\njobs:\n  a:\n    steps:\n"
        "      - run: printf '%s\\n' Hello, !\n"
        "      - run: echo done # completed, !important, ? x, \"a\\u0065\": y\n"
        "      - run: make # uses: nothing\n"
        "      - name: x\n"
        "        if: ${{ !cancelled() }}\n"
        "        uses: actions/checkout@"
        "3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
        "        with:\n"
        "          persist-credentials: false\n"
        "          sparse-checkout: [a, b] # c, !d\n",
        None,
    )
    # `read-all` is allowed only in scorecard.yml, matched by file name.
    run(
        "read-all-scorecard",
        "permissions: read-all\n"
        "jobs:\n"
        "  analysis:\n"
        "    permissions:\n"
        "      security-events: write\n",
        None,
        filename="scorecard.yml",
    )
    fixtures = {
        "tag-ref": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - uses: actions/checkout@v4 # v4\n",
            "40-character lowercase commit SHA",
        ),
        "branch-ref": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - uses: actions/checkout@main # v4.2.2\n",
            "40-character lowercase commit SHA",
        ),
        "short-sha": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - uses: actions/checkout@3d3c42e # v7.0.1\n",
            "40-character lowercase commit SHA",
        ),
        "no-comment": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - uses: actions/upload-artifact@"
            "cf430e030ddbb5b0abf93d22962f4752f3646cd9\n",
            "needs a trailing",
        ),
        "branch-comment-unknown-repo": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - uses: actions/checkout@"
            "3d3c42e5aac5ba805825da76410c181273ba90b1 # main 2026-01-01\n",
            "BRANCH_PIN_ALLOW",
        ),
        "no-permissions": (
            "jobs:\n  a:\n    steps:\n"
            "      - uses: ./.github/actions/local\n",
            "no top-level `permissions:`",
        ),
        "write-all": (
            "permissions: write-all\njobs:\n  a:\n    steps:\n"
            "      - uses: ./.github/actions/local\n",
            "write-all",
        ),
        "write-grant": (
            "permissions:\n  contents: read\n  contents-write: write\n"
            "jobs:\n  a:\n    steps:\n"
            "      - uses: ./.github/actions/local\n",
            "only `read` or `none`",
        ),
        "read-all-unlisted": (
            "permissions: read-all\njobs:\n  a:\n    steps:\n"
            "      - uses: ./.github/actions/local\n",
            "read-all",
        ),
        "checkout-no-with": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - name: Checkout repository\n"
            "        uses: actions/checkout@"
            "3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
            "      - name: Next\n        run: true\n",
            "persist-credentials: false",
        ),
        "checkout-persist-true": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - name: Checkout repository\n"
            "        uses: actions/checkout@"
            "3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
            "        with:\n"
            "          persist-credentials: true\n",
            "persist-credentials: false",
        ),
        "checkout-persist-in-later-step": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - uses: actions/checkout@"
            "3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
            "      - name: Later step\n"
            "        run: true\n"
            "        with:\n"
            "          persist-credentials: false\n",
            "persist-credentials: false",
        ),
        "flow-mapping": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - {uses: actions/checkout@"
            "3d3c42e5aac5ba805825da76410c181273ba90b1}\n",
            "unrecognized uses form",
        ),
        "docker-no-digest": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - uses: docker://ghcr.io/frostyard/snow:latest\n",
            "must pin a digest",
        ),
        # A `- name: |` header records the `-` column in a line-based scan, so
        # the `uses:` key below it would be skipped as scalar content.
        "block-scalar-name-hides-uses": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - name: |\n"
            "          Checkout repository\n"
            "        uses: actions/checkout@v4\n",
            "40-character lowercase commit SHA",
        ),
        "quoted-uses-key": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            '      - "uses": actions/checkout@v4\n',
            "40-character lowercase commit SHA",
        ),
        "quoted-uses-key-job-level": (
            "permissions: {}\njobs:\n  a:\n"
            "    'uses': owner/repo/.github/workflows/x.yml@v1\n",
            "40-character lowercase commit SHA",
        ),
        # A `persist-credentials: false` line inside a block scalar of another
        # `with:` child must not satisfy the credential check.
        "persist-in-block-scalar": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - name: Checkout repository\n"
            "        uses: actions/checkout@"
            "3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
            "        with:\n"
            "          persist-credentials: true\n"
            "          sparse-checkout: |\n"
            "            persist-credentials: false\n",
            "persist-credentials: false",
        ),
        "persist-duplicate": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - name: Checkout repository\n"
            "        uses: actions/checkout@"
            "3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
            "        with:\n"
            "          persist-credentials: false\n"
            "          persist-credentials: false\n",
            "duplicate",
        ),
        # YAML decodes escapes in a double-quoted key, so `"us\u0065s"` is a
        # real `uses:` key that a plain text match cannot see.
        "escaped-quoted-uses-key": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            '      - "us\\u0065s": actions/checkout@v4\n',
            "escaped quoted key",
        ),
        "escaped-quoted-uses-key-job-level": (
            "permissions: {}\njobs:\n  a:\n"
            '    "us\\x65s": owner/repo/.github/workflows/x.yml@v1\n',
            "escaped quoted key",
        ),
        # A complex key (`? key` + `: value`) and a tagged key also hide the
        # real key name from a line scan.
        "complex-key": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - ? uses\n"
            "        : actions/checkout@v4\n",
            "complex mapping key",
        ),
        # The same key shapes inside a flow collection.
        "escaped-quoted-key-in-flow": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            '      - {name: x, "us\\u0065s": actions/checkout@v4}\n',
            "escaped quoted key",
        ),
        "flow-sequence-uses": (
            "permissions: {}\njobs:\n  a:\n"
            "    steps: [uses: actions/checkout@v4]\n",
            "unrecognized uses form",
        ),
        "tagged-key-in-flow": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - {name: x, !!str uses: actions/checkout@v4}\n",
            "tagged mapping key",
        ),
        "escaped-quoted-key-in-flow-value": (
            "permissions: {}\njobs:\n  a:\n"
            '    steps: [{"us\\u0065s": actions/checkout@v4}]\n',
            "escaped quoted key",
        ),
        "multi-line-flow": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - {name: x,\n"
            "         uses: actions/checkout@v4}\n",
            "multi-line flow collection",
        ),
        "tagged-key": (
            "permissions: {}\njobs:\n  a:\n    steps:\n"
            "      - !!str uses: actions/checkout@v4\n",
            "tagged mapping key",
        ),
    }
    for label, (fixture, expected) in fixtures.items():
        run(label, fixture, expected)
    return cases


def main() -> None:
    cases = self_test()

    # Wiring self-check: the gate must run in the make gate and in both
    # workflows that repeat the policy tests.
    makefile_lines = MAKEFILE.read_text().splitlines()
    if "\t" + COMMAND not in makefile_lines:
        fail(f"Makefile verify target must run `{COMMAND}`")
    for path, label in ((VALIDATE, "validate.yml"), (NIGHTLY, "nightly-compliance.yml")):
        count = path.read_text().count(COMMAND)
        if count != 1:
            fail(f"{label} must run `{COMMAND}` exactly once (found {count})")

    workflow_paths = sorted(
        path
        for path in WORKFLOWS.iterdir()
        if path.is_file() and path.suffix in (".yml", ".yaml")
    )
    if not workflow_paths:
        fail("no workflow files found in .github/workflows")

    errors: list[str] = []
    for path in workflow_paths:
        errors.extend(
            check_workflow(str(path.relative_to(ROOT)), path.read_text())
        )

    if errors:
        for message in errors:
            print(message, file=sys.stderr)
        raise SystemExit(
            f"{PREFIX} {len(errors)} violation(s) across "
            f"{len(workflow_paths)} workflow file(s)"
        )

    print(
        f"{PREFIX} PASSED ({len(workflow_paths)} workflow files, "
        f"{cases} self-test cases)"
    )


if __name__ == "__main__":
    main()
