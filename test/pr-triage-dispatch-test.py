#!/usr/bin/env python3
"""Guard bot PR dispatches and the rule A2 least-privilege triage caller."""

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PIN = r"^    uses: frostyard/core/\.github/workflows/pr-triage\.yml@([0-9a-f]{40})( #.*)?$"
PR_ACTION = r"^        uses: peter-evans/create-pull-request@.+$"
TEMPLATE = """name: PR triage dispatch
on:
  workflow_dispatch:
    inputs:
      pr:
        description: The number of the pull request to triage
        required: true
        type: string
permissions: {}
jobs:
  pr-triage:
    permissions:
      contents: read
      pull-requests: write
    uses: frostyard/core/.github/workflows/pr-triage.yml@<SHA>
    with:
      pr: ${{ inputs.pr }}
      dependabot-shadow: false"""


def check(workflows: dict[str, str], caller_text: str, dispatch_text: str) -> list[str]:
    errors = []
    counts = {}
    for filename, text in workflows.items():
        counts[filename] = 0
        jobs_section = re.search(r"^jobs:\n(.*?)(?=^\S|\Z)", text, re.MULTILINE | re.DOTALL)
        if not jobs_section:
            continue
        jobs = re.split(r"^  ([A-Za-z0-9_-]+):$", jobs_section[1], flags=re.MULTILINE)
        for job, body in zip(jobs[1::2], jobs[2::2]):
            parts = re.split(r"(?=^      - )", body, flags=re.MULTILINE)
            steps = parts[1:]
            has_pr = False
            for index, step in enumerate(steps):
                if not re.search(PR_ACTION, step, re.MULTILINE):
                    continue
                has_pr = True
                counts[filename] += 1
                name_match = re.search(r"^      - name: (.+)$", step, re.MULTILINE)
                name = name_match[1] if name_match else f"#{index + 1}"
                prefix = f"{filename} job {job}: PR step {name}"
                id_match = re.search(r"^        id: ([A-Za-z0-9_-]+)$", step, re.MULTILINE)
                if not id_match:
                    errors.append(f"{prefix} has no valid id")
                    continue
                step_id = id_match[1]
                required = [
                    f"        if: steps.{step_id}.outputs.pull-request-operation == 'created' || steps.{step_id}.outputs.pull-request-operation == 'updated'",
                    "          GH_TOKEN: ${{ github.token }}",
                    "          PR_NUMBER: ${{ steps." + step_id + ".outputs.pull-request-number }}",
                    '        run: gh workflow run pr-triage-dispatch.yml --repo "$GITHUB_REPOSITORY" -f pr="$PR_NUMBER"',
                ]
                found = False
                for later in steps[index + 1:]:
                    lines = later.splitlines()
                    if not all(line in lines for line in required):
                        continue
                    # Inspect each run scalar and its indented block, not env values.
                    run_texts = re.findall(r"^        run:.*(?:\n(?:          .*|[ \t]*$))*", later, re.MULTILINE)
                    if any("${{" in run for run in run_texts):
                        continue
                    found = True
                    break
                if not found:
                    errors.append(f"{prefix} has no following PR triage dispatch step")
            if has_pr:
                permissions = re.search(r"^    permissions:\n((?:      .*\n)*)", parts[0], re.MULTILINE)
                if not permissions or "      actions: write" not in permissions[1].splitlines():
                    errors.append(f"{filename} job {job}: PR job needs actions: write")
    for filename in ("check-packages.yml", "check-dependencies.yml"):
        if not counts.get(filename):
            errors.append(f"{filename} must exist and contain at least one PR step")

    pins = []
    for filename, text in (("risk-paths.yml", caller_text), ("pr-triage-dispatch.yml", dispatch_text)):
        matches = re.findall(PIN, text, re.MULTILINE)
        if len(matches) != 1:
            errors.append(f"{filename} must contain exactly one core pr-triage SHA pin")
        pins.append(matches[0][0] if len(matches) == 1 else None)
    caller_pin, dispatch_pin = pins
    if caller_pin and dispatch_pin and caller_pin != dispatch_pin:
        errors.append(f"pr-triage-dispatch.yml pins {dispatch_pin} but risk-paths.yml pins {caller_pin}")
    normalized = []
    for line in dispatch_text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("    uses:"):
            line = line.split(" #", 1)[0]
        normalized.append(line)
    if caller_pin:
        expected = TEMPLATE.replace("<SHA>", caller_pin).splitlines()
        if normalized != expected:
            for index in range(max(len(normalized), len(expected))):
                actual = normalized[index] if index < len(normalized) else "<missing>"
                wanted = expected[index] if index < len(expected) else "<end>"
                if actual != wanted:
                    errors.append(f"pr-triage-dispatch.yml differs from the rule A2 template: line {index + 1}: expected {wanted!r}, got {actual!r}")
                    break
    return errors


def fail(message: str) -> None:
    print(f"pr-triage-dispatch-test: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    try:
        directory = ROOT / ".github/workflows"
        workflows = {path.name: path.read_text() for pattern in ("*.yml", "*.yaml") for path in sorted(directory.glob(pattern))}
        caller = (directory / "risk-paths.yml").read_text()
        dispatch = (directory / "pr-triage-dispatch.yml").read_text()
    except OSError as error:
        fail(f"cannot load workflows: {error}")

    cases = 0

    def case(name, files, dispatch_text, expected=None):
        nonlocal cases
        errors = check(files, caller, dispatch_text)
        if expected is None:
            if errors:
                fail(f"self-test {name}: {'; '.join(errors)}")
        elif not any(expected in error for error in errors):
            fail(f"self-test {name}: expected {expected!r}, got {errors!r}")
        cases += 1

    def edit_case(name, filename, old, new, expected, last=False):
        files = workflows.copy()
        original = files[filename]
        if last:
            before, separator, after = original.rpartition(old)
            assert separator, name
            files[filename] = before + new + after
        else:
            assert old in original, name
            files[filename] = original.replace(old, new, 1)
        assert files[filename] != original, name
        case(name, files, dispatch, expected)

    # The real files first, so a failure names the real problem, not a self-test.
    errors = check(workflows, caller, dispatch)
    if errors:
        fail("; ".join(errors))
    packages = "check-packages.yml"
    dependencies = "check-dependencies.yml"
    # Include the two explanatory comments and the step's trailing blank line.
    dispatch_step = re.compile(r"      # A PR that GITHUB_TOKEN opens or updates starts no pull_request_target\n      # run; dispatch PR triage so it gets its level label \(core ADR-0087\)\.\n      - name: Run PR triage\n(?:        .*\n)+(?:\n|$)")
    for name, filename, last in (("no-dispatch-step", packages, False), ("no-dispatch-in-check-dependencies", dependencies, True)):
        matches = list(dispatch_step.finditer(workflows[filename]))
        assert matches, name
        match = matches[-1] if last else matches[0]
        edit_case(name, filename, match[0], "", "has no following PR triage dispatch step", last=last)
    edit_case("no-actions-write", dependencies, "      actions: write\n", "", "needs actions: write")
    edit_case("pr-number-inline", packages, '-f pr="$PR_NUMBER"', '-f pr="${{ steps.cpr.outputs.pull-request-number }}"', "has no following PR triage dispatch step")
    if_line = "        if: steps.cpr.outputs.pull-request-operation == 'created' || steps.cpr.outputs.pull-request-operation == 'updated'\n"
    edit_case("no-if", packages, if_line, "", "has no following PR triage dispatch step")
    edit_case("wrong-id", packages, "        id: cpr\n", "        id: other\n", "has no following PR triage dispatch step")
    pin = re.findall(PIN, caller, re.MULTILINE)[0][0]
    different = "".join(format((int(digit, 16) + 1) % 16, "x") for digit in pin)
    changed = dispatch.replace(pin, different)
    assert changed != dispatch
    case("pin-differs", workflows, changed, f"pr-triage-dispatch.yml pins {different} but risk-paths.yml pins {pin}")
    changed = dispatch.replace("on:\n", "on:\n  pull_request_target:\n", 1)
    assert changed != dispatch
    case("extra-trigger", workflows, changed, "differs from the rule A2 template")
    files = workflows.copy()
    files[packages] = files[packages].replace("peter-evans/create-pull-request@", "example/other-action@")
    assert files[packages] != workflows[packages]
    case("no-pr-step-in-check-packages", files, dispatch, "check-packages.yml must exist and contain at least one PR step")
    assert dispatch
    case("missing-dispatch-file", workflows, "", "pr-triage-dispatch.yml must contain exactly one core pr-triage SHA pin")

    counts = [len(re.findall(PR_ACTION, text, re.MULTILINE)) for text in workflows.values()]
    print(f"pr-triage-dispatch-test: PASSED ({sum(counts)} PR steps in {sum(count > 0 for count in counts)} files, {cases} self-test cases)")


if __name__ == "__main__":
    main()
