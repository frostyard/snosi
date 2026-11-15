#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Every documented `bootc switch` command pulls through Podman first.

bootc's registry-transport composefs pull fails on snosi images, and a direct
registry switch reads the system container policy, which root overrides can
replace (ADR-0025). bootc-update-stage therefore pulls with Podman under the
strict update policy in /usr and switches with
`--transport containers-storage`. A user command in the docs must do the same:

- every command line that runs `bootc switch` names
  `--transport containers-storage`;
- the nearest preceding command line in the same code block is a
  `podman pull --signature-policy /usr/lib/snosi/containers/bootc-policy.json`
  of the same image reference.

Accepted ADRs and the dated records under docs/ are history and are not
checked.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
POLICY = "/usr/lib/snosi/containers/bootc-policy.json"
SKIP = (
    re.compile(r"^docs/adr/"),
    re.compile(r"^docs/plans/"),
    re.compile(r"^docs/\d{4}-\d{2}-\d{2}-"),
)
SWITCH = re.compile(r"^\s*(?:sudo\s+)?bootc\s+switch\b")


def commands(lines: list[str]):
    """Yield (line number, command) for each fenced command, with `\\` joins."""
    in_block = False
    pending = ""
    start = 0
    for number, line in enumerate(lines, 1):
        if line.lstrip().startswith("```"):
            in_block = not in_block
            pending = ""
            if not in_block:
                yield number, None  # block end resets the pull
            continue
        if not in_block:
            continue
        if not pending:
            start = number
        if line.rstrip().endswith("\\"):
            pending += line.rstrip()[:-1] + " "
            continue
        yield start, pending + line
        pending = ""


def image_of(command: str) -> str:
    return command.split()[-1] if command.split() else ""


def check_text(name: str, text: str) -> list[str]:
    errors = []
    last_pull = None
    for number, command in commands(text.splitlines()):
        if command is None:
            last_pull = None
            continue
        if not command.strip():
            continue
        if re.search(r"\bpodman\s+pull\b", command):
            last_pull = command
            continue
        if not SWITCH.search(command):
            continue
        where = f"{name}:{number}"
        if "--transport containers-storage" not in command:
            errors.append(f"{where}: bootc switch must use --transport containers-storage")
            continue
        image = image_of(command)
        if (last_pull is None or f"--signature-policy {POLICY}" not in last_pull
                or image_of(last_pull) != image):
            errors.append(
                f"{where}: bootc switch of {image} must follow "
                f"`podman pull --signature-policy {POLICY} {image}` in the same block")
        last_pull = None
    return errors


def tracked_docs() -> list[str]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "*.md"],
                         check=True, capture_output=True, text=True).stdout
    return [p for p in out.splitlines() if not any(s.search(p) for s in SKIP)]


GOOD = f"""```bash
sudo podman pull --signature-policy {POLICY} \\
  ghcr.io/frostyard/snow:forky
sudo bootc switch --transport containers-storage ghcr.io/frostyard/snow:forky
```
"""

SELF_TESTS = [
    ("good", GOOD, 0),
    ("registry switch", "```bash\nsudo bootc switch ghcr.io/frostyard/snow:forky\n```\n", 1),
    ("no pull", "```bash\nsudo bootc switch --transport containers-storage ghcr.io/frostyard/snow:forky\n```\n", 1),
    ("pull without policy",
     "```bash\nsudo podman pull ghcr.io/frostyard/snow:forky\n"
     "sudo bootc switch --transport containers-storage ghcr.io/frostyard/snow:forky\n```\n", 1),
    ("pull of another image",
     f"```bash\nsudo podman pull --signature-policy {POLICY} ghcr.io/frostyard/snow:latest\n"
     "sudo bootc switch --transport containers-storage ghcr.io/frostyard/snow:forky\n```\n", 1),
    ("pull in another block",
     f"```bash\nsudo podman pull --signature-policy {POLICY} ghcr.io/frostyard/snow:forky\n```\n\n"
     "```bash\nsudo bootc switch --transport containers-storage ghcr.io/frostyard/snow:forky\n```\n", 1),
    ("prose is not checked", "Run `bootc switch ghcr.io/x` never.\n", 0),
    ("bootc rollback is not a switch", "```bash\nsudo bootc rollback\n```\n", 0),
]


def main() -> int:
    failed = False
    for label, text, expected in SELF_TESTS:
        got = len(check_text(label, text))
        if got != expected:
            print(f"self-test '{label}': expected {expected} errors, got {got}", file=sys.stderr)
            failed = True
    errors = []
    docs = tracked_docs()
    for rel in docs:
        errors += check_text(rel, (ROOT / rel).read_text(encoding="utf-8"))
    for error in errors:
        print(error, file=sys.stderr)
    if failed or errors:
        print("docs-bootc-switch-test: FAILED", file=sys.stderr)
        return 1
    print(f"docs-bootc-switch-test: PASSED ({len(docs)} docs, {len(SELF_TESTS)} self-test cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
