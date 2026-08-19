#!/usr/bin/env python3
"""Guard the canonical Copilot automation secret and its fleet runbook."""

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
CANONICAL = "COPILOT_ASSIGNMENT_TOKEN"
WORKFLOWS = (
    ROOT / ".github/workflows/ai-fix-requested.yml",
)
RUNBOOK = ROOT / "docs/copilot-automation-secret.md"
VALIDATE = ROOT / ".github/workflows/validate.yml"
LEGACY_NAMES = ("COPILOT_AGENT_TOKEN", "COPILOT_ASSIGN_PAT")


def check() -> list[str]:
    errors: list[str] = []
    for workflow in WORKFLOWS:
        contents = workflow.read_text(encoding="utf-8")
        reference = f"secrets.{CANONICAL}"
        if contents.count(reference) != 1:
            errors.append(
                f"{workflow.relative_to(ROOT)} must reference {reference} exactly once"
            )
        if f"{CANONICAL} is not configured" not in contents:
            errors.append(
                f"{workflow.relative_to(ROOT)} must retain the canonical missing-secret error"
            )
        for legacy in LEGACY_NAMES:
            if legacy in contents:
                errors.append(
                    f"{workflow.relative_to(ROOT)} uses legacy secret name {legacy}"
                )

    runbook = RUNBOOK.read_text(encoding="utf-8")
    for required in (
        f"`{CANONICAL}`",
        "organization Actions secret",
        "selected-repository",
        "Do not merge a rename",
        "must fail visibly",
    ):
        if required not in runbook:
            errors.append(f"runbook is missing {required!r}")

    command = "python3 ./test/copilot-automation-secret-test.py"
    if command not in VALIDATE.read_text(encoding="utf-8"):
        errors.append("validate.yml does not run the Copilot secret contract test")
    return errors


def main() -> int:
    errors = check()
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"Copilot automation workflows use canonical secret {CANONICAL}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
