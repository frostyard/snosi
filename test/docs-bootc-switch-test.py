#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Every documented `bootc switch` command pulls through Podman first, fail closed.

bootc's registry-transport composefs pull fails on snosi images, and a direct
registry switch reads the system container policy, which root overrides can
replace (ADR-0025). bootc-update-stage therefore pulls with Podman under the
strict update policy in /usr, stops when the pull fails, and switches with
`--transport containers-storage`. A user command in the docs must do the same.

A logical command (lines joined after a trailing `\\`, `&&`, `||` or `|`) that
names `bootc switch` anywhere must be exactly an `&&` chain of:

1. `[sudo] podman pull --signature-policy /usr/lib/snosi/containers/bootc-policy.json IMAGE`
2. `[sudo] bootc switch --transport containers-storage IMAGE` (the same IMAGE)
3. optionally `[sudo] systemctl reboot`

So the switch runs only after that pull succeeded, and the reboot only after
the switch succeeded. Any other form (`;`, `||`, `|`, a background `&`, a
switch that is not the 2nd step, a switch in a separate command) fails.

Accepted ADRs, plans and the dated records under docs/ are history and are not
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
MENTION = re.compile(r"\bbootc\s+switch\b")
JOIN_SUFFIXES = ("\\", "&&", "||", "|")
PULL = re.compile(
    r"^(?:sudo\s+)?podman\s+pull\s+--signature-policy\s+" + re.escape(POLICY) + r"\s+(\S+)$")
SWITCH = re.compile(r"^(?:sudo\s+)?bootc\s+switch\s+--transport\s+containers-storage\s+(\S+)$")
REBOOT = re.compile(r"^(?:sudo\s+)?systemctl\s+reboot$")


def logical_commands(text: str):
    """Yield (first line number, logical command) for every fenced command."""
    in_block = False
    pending = ""
    start = 0
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            if in_block and pending:
                yield start, pending
            in_block = not in_block
            pending = ""
            continue
        if not in_block:
            continue
        if not pending:
            start = number
        stripped = line.strip()
        if stripped.endswith(JOIN_SUFFIXES):
            body = stripped[:-1] if stripped.endswith("\\") else stripped
            pending += body + " "
            continue
        yield start, pending + stripped
        pending = ""
    if in_block and pending:
        yield start, pending


def check_command(where: str, command: str) -> list[str]:
    if not MENTION.search(command):
        return []
    # Split on && only; any other control operator is not allowed in a chain
    # that switches the deployment.
    if re.search(r";|\|\||(?<!&)&(?!&)|(?<!\|)\|(?!\|)", command):
        return [f"{where}: a bootc switch chain may use only && between steps"]
    steps = [step.strip() for step in command.split("&&")]
    if len(steps) not in (2, 3):
        return [f"{where}: bootc switch must be the 2nd step of `podman pull ... && bootc switch ...`"]
    pull = PULL.match(steps[0])
    switch = SWITCH.match(steps[1])
    errors = []
    if not pull:
        errors.append(f"{where}: the step before bootc switch must be "
                      f"`podman pull --signature-policy {POLICY} IMAGE`")
    if not switch:
        errors.append(f"{where}: bootc switch must be "
                      "`bootc switch --transport containers-storage IMAGE`")
    if pull and switch and pull.group(1) != switch.group(1):
        errors.append(f"{where}: the pull ({pull.group(1)}) and the switch "
                      f"({switch.group(1)}) must name the same image")
    if len(steps) == 3 and not REBOOT.match(steps[2]):
        errors.append(f"{where}: only `systemctl reboot` may follow the switch")
    return errors


def check_text(name: str, text: str) -> list[str]:
    errors = []
    for number, command in logical_commands(text):
        errors += check_command(f"{name}:{number}", command)
    return errors


def tracked_docs() -> list[str]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "*.md"],
                         check=True, capture_output=True, text=True).stdout
    return [p for p in out.splitlines() if not any(s.search(p) for s in SKIP)]


def block(*lines: str) -> str:
    return "```bash\n" + "\n".join(lines) + "\n```\n"


P = f"sudo podman pull --signature-policy {POLICY}"
IMG = "ghcr.io/frostyard/snow:forky"
SW = "sudo bootc switch --transport containers-storage"

SELF_TESTS = [
    ("good, && continuation", block(f"{P} \\", f"  {IMG} &&", f"{SW} {IMG} &&", "sudo systemctl reboot"), 0),
    ("good, one line without sudo or reboot",
     block(f"podman pull --signature-policy {POLICY} {IMG} && bootc switch --transport containers-storage {IMG}"), 0),
    ("registry switch", block(f"sudo bootc switch {IMG}"), 1),
    ("bare switch without sudo", block(f"bootc switch {IMG}"), 1),
    ("switch without pull", block(f"{SW} {IMG}"), 1),
    ("pull and switch as separate commands", block(f"{P} {IMG}", f"{SW} {IMG}"), 1),
    ("pull without policy", block(f"sudo podman pull {IMG} && {SW} {IMG}"), 1),
    ("pull of another image", block(f"{P} ghcr.io/frostyard/snow:latest && {SW} {IMG}"), 1),
    ("registry switch after a good pull", block(f"{P} {IMG} && sudo bootc switch {IMG}"), 1),
    ("semicolon chain", block(f"{P} {IMG}; {SW} {IMG}"), 1),
    ("or chain", block(f"{P} {IMG} || {SW} {IMG}"), 1),
    ("pipe", block(f"{P} {IMG} | {SW} {IMG}"), 1),
    ("background", block(f"{P} {IMG} & {SW} {IMG}"), 1),
    ("retag between pull and switch",
     block(f"{P} {IMG} && sudo podman tag x {IMG} && {SW} {IMG}"), 1),
    ("switch after another command", block(f"echo go && {SW} {IMG}"), 1),
    ("unconditional reboot after the chain", block(f"{P} {IMG} && {SW} {IMG}; sudo systemctl reboot"), 1),
    ("something else after the switch", block(f"{P} {IMG} && {SW} {IMG} && rm -rf /var"), 1),
    ("backslash continuation of a registry switch", block("sudo bootc switch \\", f"  {IMG}"), 1),
    ("prose is not checked", "Run `bootc switch ghcr.io/x` never.\n", 0),
    ("rollback is not a switch", block("sudo bootc rollback &&", "sudo systemctl reboot"), 0),
]


def main() -> int:
    failed = False
    for label, text, expected in SELF_TESTS:
        got = check_text(label, text)
        if (len(got) > 0) != (expected > 0):
            print(f"self-test '{label}': expected {'errors' if expected else 'no error'}, got {got}",
                  file=sys.stderr)
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
