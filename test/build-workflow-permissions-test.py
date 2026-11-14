#!/usr/bin/env python3
"""Guard .github/workflows/build.yml: job permissions, the publish steps and
the order of the 2 suites.

The trixie job `build` and the forky job `build-forky` (ADR-0037) each run
mkosi as root and publish sysexts to R2 with repogen's publish-to-r2. The
checks run on the real workflow, and then on in-memory mutations of it that
each must be rejected (self-test cases), so a check that cannot fail is found.
"""
from pathlib import Path
import os
import re


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = Path(os.environ.get("BUILD_WORKFLOW", ROOT / ".github/workflows/build.yml"))
JOB_PATTERN = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")
PERMISSION_PATTERN = re.compile(r"^      ([A-Za-z0-9_-]+):\s*(\S+)\s*$")
USES_PATTERN = re.compile(
    r"^\s+uses: frostyard/repogen/\.github/actions/publish-to-r2@([0-9a-f]{40})"
    r"\s+# (v\d+\.\d+\.\d+)\s*$"
)
VERSION_PATTERN = re.compile(r"^\s+repogen-version:\s*(\S+)\s*$")
COMMIT_PATTERN = re.compile(r"^\s+repogen-commit:\s*(\S+)\s*$")
MKOSI_PATTERN = re.compile(r"^\s+uses: (systemd/mkosi@\S+.*)$")
CANCEL_PATTERN = re.compile(r"^  cancel-in-progress:\s*(.+?)\s*$")
PUBLISH = "Publish sysexts to frostyard repo"
MANIFESTS = "Upload manifests to R2"
NAME_CHECK = "Check the forky sysext names"
FORKY_COLLECT = "Collect forky sysext outputs"
PUBLISHING_JOBS = ("build", "build-forky")


class Failed(Exception):
    pass


def fail(message: str) -> None:
    raise Failed(message)


def jobs_of(lines: list[str]) -> dict[str, list[str]]:
    try:
        start = lines.index("jobs:")
    except ValueError:
        fail("workflow has no jobs: section")
    jobs: dict[str, list[str]] = {}
    current = None
    for line in lines[start + 1 :]:
        match = JOB_PATTERN.match(line)
        if match:
            current = match.group(1)
            jobs[current] = [line]
        elif current is not None:
            jobs[current].append(line)
    return jobs


def steps_of(job: list[str]) -> list[tuple[str, list[str]]]:
    steps: list[tuple[str, list[str]]] = []
    for line in job:
        if line.startswith("      - name: "):
            steps.append((line.removeprefix("      - name: "), [line]))
        elif line.startswith("      - "):
            steps.append(("<unnamed>", [line]))
        elif steps:
            steps[-1][1].append(line)
    return steps


def step_index(steps, job_name: str, name: str) -> int:
    found = [i for i, (step, _) in enumerate(steps) if step == name]
    if len(found) != 1:
        fail(f"{job_name} job must have exactly 1 step named {name!r}; found {len(found)}")
    return found[0]


def job_key(job: list[str], key: str) -> list[str]:
    return [
        line.split(":", 1)[1].strip()
        for line in job
        if line.startswith(f"    {key}:")
    ]


def check_job_hardening(name: str, job: list[str]) -> None:
    try:
        permissions_start = job.index("    permissions:")
    except ValueError:
        fail(f"{name} job has no explicit permissions")
    permissions: dict[str, str] = {}
    for line in job[permissions_start + 1 :]:
        match = PERMISSION_PATTERN.match(line)
        if match:
            permissions[match.group(1)] = match.group(2)
            continue
        if line.strip() and not line.startswith("      "):
            break
    if permissions != {"contents": "read"}:
        fail(f"{name} job permissions must be exactly contents: read; found {permissions}")
    for forbidden in ("packages: write", "id-token: write", "attestations: write"):
        if any(forbidden in line for line in job):
            fail(f"{name} job restored forbidden grant {forbidden!r}")
    if not job_key(job, "timeout-minutes"):
        fail(f"{name} job must set timeout-minutes")
    text = "\n".join(job)
    if 'echo "TMPDIR=/mnt/tmp" >> "$GITHUB_ENV"' not in text:
        fail(f"{name} job must redirect TMPDIR to /mnt")
    checkouts = [i for i, line in enumerate(job) if "uses: actions/checkout@" in line]
    if len(checkouts) != 1 or "persist-credentials: false" not in "\n".join(
        job[checkouts[0] : checkouts[0] + 3]
    ):
        fail(f"{name} job must check out once with persist-credentials: false")


def check_publish(name: str, job: list[str]) -> tuple[str, str]:
    # The publish-to-r2 action pin and the repogen binary it downloads are two
    # separate pins. The action's repogen-version input defaults to "latest",
    # which floated to v0.5.0 on 2026-09-14 and broke every publish. Require
    # an explicit tag equal to the release in the action pin's comment, and
    # (since v0.7.0) the commit its release binary embeds.
    uses = [m for m in (USES_PATTERN.match(line) for line in job) if m]
    if len(uses) != 1:
        fail(
            f"{name} job must use exactly one commit-pinned publish-to-r2 action "
            "with a trailing '# vX.Y.Z' release comment"
        )
    action_commit, action_release = uses[0].group(1), uses[0].group(2)
    versions = [m.group(1) for m in (VERSION_PATTERN.match(line) for line in job) if m]
    if versions != [action_release]:
        fail(
            f"{name} publish-to-r2 step must set repogen-version to the action pin's "
            f"own release {action_release!r}; found {versions}"
        )
    commits = [m.group(1) for m in (COMMIT_PATTERN.match(line) for line in job) if m]
    if commits != [action_commit]:
        fail(
            f"{name} publish-to-r2 step must set repogen-commit to the action pin's "
            f"own commit {action_commit!r}; found {commits}"
        )
    steps = steps_of(job)
    publish = steps[step_index(steps, name, PUBLISH)][1]
    stripped = [line.strip() for line in publish]
    # Every main run rebuilds every sysext and mkosi output is not
    # byte-reproducible: the publish step must skip published identities
    # itself (repogen v0.7.2, ADR-0018), from the signature-verified SHA256SUMS.
    for required in (
        "packages-dir: ./output/sysexts",
        "skip-published-identities: true",
        "skip-duplicates: true",
        "package-type: sysext",
    ):
        if required not in stripped:
            fail(f"{name} publish step must set {required!r}")
    if not any(line.startswith("gpg-private-key: ${{ secrets.") for line in stripped):
        fail(f"{name} publish step needs gpg-private-key for skip-published-identities")
    publish_if = [line for line in stripped if line.startswith("if:")]
    if publish_if != ["if: github.event_name != 'pull_request'"]:
        fail(f"{name} publish step must run on every non-PR event only; found {publish_if}")
    if any("drop-published" in line for line in job):
        fail("drop-published.sh is retired; repogen skips published identities")
    return action_commit, action_release


def manifest_destinations(job: list[str]) -> list[str]:
    return [
        line.strip().removeprefix("destination-dir:").strip()
        for line in job
        if line.strip().startswith("destination-dir:")
    ]


def check(text: str) -> None:
    lines = text.splitlines()
    if "  pull_request:" not in text:
        fail("build workflow must retain its pull_request trigger")
    if "permissions: {}" not in text:
        fail("workflow-level permissions must remain empty")

    jobs = jobs_of(lines)
    for name in PUBLISHING_JOBS:
        if name not in jobs:
            fail(f"workflow has no {name!r} job")
    # Only the 2 ordered jobs may write to R2: a third writer could run beside
    # them and lose an update of the shared SHA256SUMS.
    for name, job in jobs.items():
        writes = any("publish-to-r2" in line or "r2-upload-action" in line for line in job)
        if writes and name not in PUBLISHING_JOBS:
            fail(f"job {name!r} writes to R2; only {PUBLISHING_JOBS} may")

    build, forky = jobs["build"], jobs["build-forky"]
    for name in PUBLISHING_JOBS:
        check_job_hardening(name, jobs[name])
    pins = {name: check_publish(name, jobs[name]) for name in PUBLISHING_JOBS}
    if pins["build"] != pins["build-forky"]:
        fail(f"both publish steps must use the same repogen pin; found {pins}")
    mkosi_pins = {
        name: [m.group(1) for m in (MKOSI_PATTERN.match(l) for l in jobs[name]) if m]
        for name in PUBLISHING_JOBS
    }
    if len(mkosi_pins["build"]) != 1 or mkosi_pins["build-forky"] != mkosi_pins["build"]:
        fail(f"build-forky must use the build job's setup-mkosi pin; found {mkosi_pins}")

    # Every step that writes to R2, in both jobs, must skip pull requests.
    for name in PUBLISHING_JOBS:
        for step, body in steps_of(jobs[name]):
            if not any("publish-to-r2" in l or "r2-upload-action" in l for l in body):
                continue
            guards = [l.strip() for l in body if l.strip().startswith("if:")]
            if guards != ["if: github.event_name != 'pull_request'"]:
                fail(
                    f"{name} upload step {step!r} must have exactly "
                    f"\"if: github.event_name != 'pull_request'\"; found {guards}"
                )

    # Trixie: the root build and its manifests at manifests/.
    if not any("sudo -E mkosi build" in line for line in build):
        fail("test no longer covers the PR-controlled root mkosi build job")
    if manifest_destinations(build) != ["manifests/"]:
        fail(f"build job must upload manifests to manifests/; found {manifest_destinations(build)}")

    # Forky: after the trixie job, its own build, its manifests at
    # manifests/forky/, and the name check before any upload.
    if job_key(forky, "needs") != ["build"]:
        fail(
            "build-forky must declare 'needs: build': its publish must start "
            "only after the trixie publish"
        )
    # The forky job runs on pull requests too, so its build, output paths and
    # name check are tested before the first publish; only its upload steps
    # skip pull requests (checked for both jobs below).
    if job_key(forky, "if"):
        fail(
            "build-forky must have no job-level 'if': it must also run on pull "
            f"requests, and only its upload steps skip them; found {job_key(forky, 'if')}"
        )
    forky_text = "\n".join(forky)
    if "sudo -E mkosi --release forky build" not in forky_text:
        fail("build-forky must run 'sudo -E mkosi --release forky build'")
    forky_code = "\n".join(line for line in forky if not line.strip().startswith("#"))
    if "himmelblau" in forky_code:
        fail("build-forky must not build himmelblau (trixie-only, a known gap)")
    destinations = manifest_destinations(forky)
    if destinations != ["manifests/forky/"]:
        fail(
            "build-forky must upload manifests to manifests/forky/ only, never "
            f"manifests/ (the names carry no suite); found {destinations}"
        )
    steps = steps_of(forky)
    # repogen writes each index.html from the local files only, so a forky
    # publish with HTML indexes would drop the trixie links from the shared
    # ext/ indexes (cross-review of PR #1308).
    forky_publish = [l.strip() for l in steps[step_index(steps, "build-forky", PUBLISH)][1]]
    if "html-index: false" not in forky_publish:
        fail("build-forky publish step must set 'html-index: false' to keep the trixie indexes")
    collect = step_index(steps, "build-forky", FORKY_COLLECT)
    name_check = step_index(steps, "build-forky", NAME_CHECK)
    check_text = "\n".join(steps[name_check][1])
    for required in (
        "mkosi --release forky --json summary",
        'select(.Format == "sysext")',
        "./shared/suite/forky/check-sysext-names.sh output/sysexts",
    ):
        if required not in check_text:
            fail(f"build-forky name check must contain {required!r}")
    uploads = [
        i
        for i, (_, body) in enumerate(steps)
        if any("publish-to-r2" in line or "r2-upload-action" in line for line in body)
    ]
    if not uploads:
        fail("build-forky has no upload steps")
    if not collect < name_check < min(uploads):
        fail("build-forky must collect, then check the sysext names, then upload")

    # A cancel during the R2 upload can leave SHA256SUMS and its signature out
    # of step: a run that publishes must never be cancelled by a newer run.
    cancel = [m.group(1) for m in (CANCEL_PATTERN.match(line) for line in lines) if m]
    if cancel != ["${{ github.event_name == 'pull_request' }}"]:
        fail(
            "workflow concurrency may cancel only pull_request runs, never a "
            f"publishing push run; found {cancel}"
        )


def mutate(text: str, old: str, new: str, count: int = 1) -> str:
    if text.count(old) < count:
        raise SystemExit(f"build-workflow-permissions-test: self-test fixture is stale: {old!r}")
    return text.replace(old, new, count)


def forky_part(text: str) -> tuple[str, str]:
    marker = "\n  build-forky:\n"
    head, _, tail = text.partition(marker)
    if not tail:
        raise SystemExit("build-workflow-permissions-test: self-test needs the build-forky job")
    return head + marker, tail


def in_forky(text: str, old: str, new: str) -> str:
    head, tail = forky_part(text)
    return head + mutate(tail, old, new)


def move_name_check_after_publish(text: str) -> str:
    head, tail = forky_part(text)
    lines = tail.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.startswith("      - name: ")]
    names = [lines[i].removeprefix("      - name: ").strip() for i in starts]
    a = starts[names.index(NAME_CHECK)]
    b = starts[names.index(NAME_CHECK) + 1]
    block, rest = lines[a:b], lines[:a] + lines[b:]
    starts = [i for i, line in enumerate(rest) if line.startswith("      - name: ")]
    names = [rest[i].removeprefix("      - name: ").strip() for i in starts]
    end = starts[names.index(MANIFESTS) + 1] if names.index(MANIFESTS) + 1 < len(starts) else len(rest)
    return head + "".join(rest[:end] + block + rest[end:])


def self_tests(text: str) -> int:
    cases = [
        ("the forky job without needs: build",
         lambda t: in_forky(t, "    needs: build\n", ""), "needs: build"),
        ("the forky job needing another job",
         lambda t: in_forky(t, "    needs: build\n", "    needs: [build, other]\n"), "needs: build"),
        ("forky manifests uploaded to manifests/",
         lambda t: in_forky(t, "destination-dir: manifests/forky/", "destination-dir: manifests/"),
         "manifests/forky/"),
        ("trixie manifests moved to manifests/forky/",
         lambda t: mutate(t, "destination-dir: manifests/\n", "destination-dir: manifests/forky/\n"),
         "build job must upload manifests to manifests/"),
        ("the forky name check removed",
         lambda t: in_forky(t, f"      - name: {NAME_CHECK}\n", "      - name: Something else\n"),
         NAME_CHECK),
        ("the forky name check after the publish steps",
         move_name_check_after_publish, "then check the sysext names, then upload"),
        ("the forky name check on the wrong directory",
         lambda t: in_forky(t, "check-sysext-names.sh output/sysexts", "check-sysext-names.sh output"),
         "check-sysext-names.sh output/sysexts"),
        ("a job-level PR guard on the forky job",
         lambda t: in_forky(t, "    needs: build\n",
                            "    needs: build\n    if: github.event_name != 'pull_request'\n"),
         "no job-level 'if'"),
        ("the forky manifests upload on pull requests",
         lambda t: in_forky(t, "if: github.event_name != 'pull_request'\n        uses: ryand56/r2-upload-action",
                            "uses: ryand56/r2-upload-action"),
         "upload step 'Upload manifests to R2'"),
        ("the trixie manifests upload on pull requests",
         lambda t: mutate(t, "if: github.event_name != 'pull_request'\n        uses: ryand56/r2-upload-action",
                          "uses: ryand56/r2-upload-action"),
         "build upload step 'Upload manifests to R2'"),
        ("the forky build without --release forky",
         lambda t: in_forky(t, "sudo -E mkosi --release forky build", "sudo -E mkosi build"),
         "--release forky build"),
        ("a himmelblau build in the forky job",
         lambda t: in_forky(t, "sudo -E mkosi --release forky build",
                            "sudo -E mkosi --release forky build\n          sudo -E mkosi --dependency=himmelblau build"),
         "himmelblau"),
        ("the forky publish without skip-published-identities",
         lambda t: in_forky(t, "skip-published-identities: true", "skip-published-identities: false"),
         "skip-published-identities"),
        ("the forky publish writing HTML indexes",
         lambda t: in_forky(t, "          html-index: false\n", ""), "html-index: false"),
        ("the forky publish with html-index true",
         lambda t: in_forky(t, "html-index: false", "html-index: true"), "html-index: false"),
        ("a floating repogen binary in the forky publish",
         lambda t: in_forky(t, "repogen-version: v0.7.2", "repogen-version: latest"), "repogen-version"),
        ("a forky publish on pull requests",
         lambda t: in_forky(t, "if: github.event_name != 'pull_request'\n        uses: frostyard/repogen",
                            "uses: frostyard/repogen"), "non-PR event"),
        ("a write grant in the forky job",
         lambda t: in_forky(t, "      contents: read\n", "      contents: read\n      id-token: write\n"),
         "build-forky job"),
        ("the forky checkout keeping credentials",
         lambda t: in_forky(t, "persist-credentials: false", "persist-credentials: true"),
         "persist-credentials"),
        ("another setup-mkosi pin in the forky job",
         lambda t: in_forky(t, "systemd/mkosi@904357aa12013e3adbb4857cc4bf8840c6c83682",
                            "systemd/mkosi@0000000000000000000000000000000000000000"),
         "setup-mkosi pin"),
        ("a third job that writes to R2",
         lambda t: t + "\n  extra:\n    runs-on: ubuntu-latest\n    steps:\n"
                       "      - uses: ryand56/r2-upload-action@33ebb7a494b3a8a3c5ed2ea6bbdc72e707090317 # v1.5\n",
         "writes to R2"),
        ("a cancellable publishing run",
         lambda t: mutate(t, "cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
                          "cancel-in-progress: true"), "cancel only pull_request"),
    ]
    for description, change, expected in cases:
        mutated = change(text)
        try:
            check(mutated)
        except Failed as error:
            if expected not in str(error):
                raise SystemExit(
                    f"build-workflow-permissions-test: self-test '{description}' failed "
                    f"for another reason: {error}"
                )
            continue
        raise SystemExit(f"build-workflow-permissions-test: self-test '{description}' was not detected")
    return len(cases)


text = WORKFLOW.read_text()
try:
    check(text)
except Failed as error:
    raise SystemExit(f"build-workflow-permissions-test: {error}")
count = self_tests(text)
print(f"build-workflow-permissions-test: PASSED ({count} self-test cases)")
