#!/usr/bin/env python3
"""Static gate for .github/workflows/forky-publish.yml (ADR-0038, ADR-0039).

The forky publish workflow signs and publishes forky test images of Floe,
Snow, Snowfield or Sundog, 1 product per dispatch. It must:

  0. take a required choice input `profile` with exactly the 4 products, and
     map it in a `select` job (main gate, no permissions, no checkout, no
     secret) to exactly 1 matrix entry from a fixed table equal to the
     build-images.yml secure-build matrix; the input reaches a script only
     through env, never by interpolation into a run: script;
  1. run only on workflow_dispatch, only from main, in the native-build
     environment, with SNOSI_BOOTC_SECURE_SUITE=forky for the whole job;
  2. never move latest, upload R2 manifests or record a release tag: no step
     runs promote-published-image.sh or manifestmv.sh, or uses the R2 upload
     or upload-artifact actions, and no command names a :latest reference;
  3. build with `mkosi --release forky`, push and verify only the
     forky-<timestamp> tag, keep IMAGE_VERSION at the 14-digit version, and
     pass the suite through every sudo call of a suite-aware script;
  4. keep the steps of build-images.yml secure-build in the same order, with
     the same pinned actions, minus the steps of item 2, plus one summary step
     at the end (drift guard).

The parse is line based on purpose, as in workflow-pins-test.py: CI python may
not ship PyYAML. The self-test mutates the real workflow and requires each
mutation to fail, so every check can fail.
"""

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
FORKY = WORKFLOWS / "forky-publish.yml"
BUILD_IMAGES = WORKFLOWS / "build-images.yml"
MAKEFILE = ROOT / "Makefile"
VALIDATE = WORKFLOWS / "validate.yml"
COMMAND = "python3 ./test/forky-publish-workflow-test.py"
PREFIX = "forky-publish-workflow-test:"

JOB = "forky-publish"
SELECT_JOB = "select"
PRODUCTS = ["floe", "snow", "snowfield", "sundog"]
SELECT_ENV = "          PROFILE: ${{ inputs.profile }}"
SELECT_JSON = "'[{profile: $profile, description: $description}]')"
SELECT_FALLBACK = re.compile(r"^\s+\*\) echo \"::error::[^\"]*\" >&2; exit 1 ;;$")
TABLE_ROW = re.compile(r'^\s+([a-z0-9-]+)\) description="([^"]*)" ;;$')
MATRIX_INCLUDE = "        include: ${{ fromJSON(needs.select.outputs.matrix) }}"
OMITTED_STEPS = [
    "Promote validated digest to latest",
    "Move manifests",
    "Upload manifests to R2",
    "Record snow tag for release job",
    "Upload snow tag artifact",
]
SUMMARY_STEP = "Record the forky test image"
# Steps whose text differs from secure-build on purpose: the forky build, the
# forky tag and 14-digit version, the suite under sudo, and comments that
# named latest. Every other shared step must be byte-identical to secure-build,
# so the credential checks, Flatpak label checks, smoke test, nbc refusal,
# SBOM, signing and verification steps cannot drift.
VARIED_STEPS = {
    "Generate version tag",
    "Build Image",
    "Package image",
    "Check image version annotation",
    "Validate locally assembled secure artifact",
    "Push immutable version tag",
    "Check image version annotation on pushed digest",
    "Validate policy-copied secure artifact",
    "Re-verify key signature after attestation",
}
FORBIDDEN_TEXT = [
    "promote-published-image.sh",
    "manifestmv.sh",
    "r2-upload-action",
    "actions/upload-artifact",
    "create-github-release.sh",
]
# Scripts that read SNOSI_BOOTC_SECURE_SUITE. Under sudo the variable must be
# passed explicitly: sudo resets the environment.
SUITE_AWARE = [
    "buildah-package.sh",
    "push-immutable-image.sh",
    "bootc-secure-artifact-test.sh",
    "assemble-uki.sh",
    "verify-published-image.sh",
]
SUITE_PASS = 'SNOSI_BOOTC_SECURE_SUITE="$SNOSI_BOOTC_SECURE_SUITE"'
TAG = "${{ steps.version.outputs.tag }}"
VERSION = "${{ steps.version.outputs.version }}"

STEP_NAME = re.compile(r"^      - name: (.+?)\s*$")
TOP_KEY = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):")
JOB_KEY = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")


def block(lines: list[str], start: int, indent: int) -> list[str]:
    """Lines after lines[start] that are indented deeper than indent."""
    out = []
    for line in lines[start + 1 :]:
        if line.strip() and len(line) - len(line.lstrip(" ")) <= indent:
            break
        out.append(line)
    return out


def top_block(lines: list[str], key: str) -> list[str] | None:
    for index, line in enumerate(lines):
        if line.rstrip() == f"{key}:":
            return block(lines, index, 0)
    return None


def job_block(lines: list[str], name: str) -> list[str] | None:
    jobs = top_block(lines, "jobs")
    if jobs is None:
        return None
    for index, line in enumerate(jobs):
        if line == f"  {name}:":
            return block(jobs, index, 2)
    return None


def steps(job: list[str]) -> list[tuple[str, list[str]]]:
    try:
        start = job.index("    steps:")
    except ValueError:
        return []
    result: list[tuple[str, list[str]]] = []
    for line in job[start + 1 :]:
        match = STEP_NAME.match(line)
        if match:
            result.append((match.group(1), [line]))
        elif result:
            result[-1][1].append(line)
    return result


def code(lines: list[str]) -> list[str]:
    """Drop YAML and shell comment lines; keep everything else."""
    return [line for line in lines if not line.lstrip().startswith("#")]


def commands(lines: list[str]) -> list[str]:
    """Join backslash-continued lines into logical shell commands."""
    out: list[str] = []
    current = ""
    for line in code(lines):
        stripped = line.strip()
        if stripped.endswith("\\"):
            current += stripped[:-1] + " "
            continue
        out.append(current + stripped)
        current = ""
    if current:
        out.append(current)
    return out


def gate_errors(job: list[str], name: str) -> list[str]:
    errors: list[str] = []
    condition: list[str] = []
    for index, line in enumerate(job):
        if line.startswith("    if:"):
            condition = [line] + block(job, index, 4)
            break
    condition_text = " ".join(part.strip() for part in condition)
    if "github.ref == 'refs/heads/main'" not in condition_text:
        errors.append(f"{name} job if must require github.ref == 'refs/heads/main'")
    if "github.event_name == 'workflow_dispatch'" not in condition_text:
        errors.append(f"{name} job if must require github.event_name == 'workflow_dispatch'")
    if "||" in condition_text:
        errors.append(f"{name} job if must not hold an alternative (||)")
    return errors


def secure_build_matrix(images_job: list[str]) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    for index, line in enumerate(images_job):
        match = re.match(r"^          - profile: (\S+)\s*$", line)
        if match:
            following = images_job[index + 1] if index + 1 < len(images_job) else ""
            described = re.match(r'^            description: "([^"]*)"\s*$', following)
            entries.append((match.group(1), described.group(1) if described else ""))
    return entries


def check_select(lines: list[str], on: list[str], images_job: list[str] | None) -> list[str]:
    errors: list[str] = []
    # The choice input: required, default floe, exactly the 4 products.
    try:
        start = on.index("    inputs:")
    except ValueError:
        return ["workflow_dispatch must declare inputs"]
    inputs = block(on, start, 4)
    names = [m.group(1) for line in inputs if (m := re.match(r"^      ([A-Za-z_-]+):\s*$", line))]
    if names != ["profile"]:
        errors.append(f"workflow_dispatch must have exactly the input profile; found {names}")
    profile = block(inputs, inputs.index("      profile:"), 6) if "      profile:" in inputs else []
    for required in ("        required: true", "        type: choice", "        default: floe"):
        if required not in profile:
            errors.append(f"the profile input must set {required.strip()!r}")
    options = []
    if "        options:" in profile:
        options = [line.strip().removeprefix("- ").strip() for line in block(profile, profile.index("        options:"), 8) if line.strip()]
    if options != PRODUCTS:
        errors.append(f"the profile input options must be exactly {PRODUCTS}; found {options}")

    select = job_block(lines, SELECT_JOB)
    if select is None:
        return errors + [f"workflow has no {SELECT_JOB} job"]
    errors += gate_errors(select, SELECT_JOB)
    if "    permissions: {}" not in select:
        errors.append(f"{SELECT_JOB} job must set permissions: {{}}")
    if "environment:" in "\n".join(select):
        errors.append(f"{SELECT_JOB} job must not use an environment")
    select_code = code(select)
    if any(line.strip().startswith("uses:") for line in select_code):
        errors.append(f"{SELECT_JOB} job must run no action (no checkout)")
    if any("secrets." in line for line in select_code):
        errors.append(f"{SELECT_JOB} job must use no secret")
    if "      matrix: ${{ steps.select.outputs.matrix }}" not in select:
        errors.append(f"{SELECT_JOB} job must output matrix from its select step")
    table = [(m.group(1), m.group(2)) for line in select_code if (m := TABLE_ROW.match(line))]
    if images_job is not None:
        expected = secure_build_matrix(images_job)
        if table != expected:
            errors.append(f"the {SELECT_JOB} table must equal the secure-build matrix {expected}; found {table}")
    if not any(SELECT_FALLBACK.match(line) for line in select_code):
        errors.append(f"the {SELECT_JOB} table must fail (exit 1) on any other value")
    if not any(line.strip() == SELECT_JSON for line in select_code):
        errors.append(f"the {SELECT_JOB} step must output exactly 1 matrix entry: {SELECT_JSON}")
    if sum("matrix=" in line and "GITHUB_OUTPUT" in line for line in select_code) != 1:
        errors.append(f"the {SELECT_JOB} step must write the matrix output exactly once")

    # The input reaches a script only through the select step's env.
    for line in code(lines):
        if "inputs." in line and line != SELECT_ENV:
            errors.append(f"inputs may only reach the select step through env ({SELECT_ENV.strip()}); found {line.strip()}")
    if sum(line == SELECT_ENV for line in select_code) != 1:
        errors.append(f"the {SELECT_JOB} step must take the input once through env: {SELECT_ENV.strip()}")
    return errors


def check(forky_text: str, images_text: str) -> list[str]:
    errors: list[str] = []
    lines = forky_text.splitlines()

    # 1. Triggers, permissions, job gate, environment, suite.
    on = top_block(lines, "on")
    if on is None:
        errors.append("workflow has no top-level on: block")
    else:
        events = {m.group(1) for line in on if (m := re.match(r"^  ([A-Za-z_]+):", line))}
        if events != {"workflow_dispatch"}:
            errors.append(f"triggers must be exactly workflow_dispatch; found {sorted(events)}")
        errors += check_select(lines, on, job_block(images_text.splitlines(), "secure-build"))
    if "permissions: {}" not in lines:
        errors.append("top-level permissions must be {}")

    jobs = top_block(lines, "jobs") or []
    names = [m.group(1) for line in jobs if (m := JOB_KEY.match(line))]
    if names != [SELECT_JOB, JOB]:
        errors.append(f"the workflow must hold exactly the jobs {[SELECT_JOB, JOB]}; found {names}")
    job = job_block(lines, JOB)
    if job is None:
        errors.append(f"workflow has no {JOB} job")
        return errors

    errors += gate_errors(job, JOB)
    if "    needs: select" not in job:
        errors.append(f"{JOB} job must declare needs: select")
    if MATRIX_INCLUDE not in job or any(re.match(r"^\s+- profile:", line) for line in job):
        errors.append(f"{JOB} matrix must be only {MATRIX_INCLUDE.strip()}")
    if "    environment: native-build" not in job:
        errors.append("job must run in environment native-build")

    job_env: list[str] = []
    for index, line in enumerate(job):
        if line == "    env:":
            job_env = block(job, index, 4)
            break
    if "      SNOSI_BOOTC_SECURE_SUITE: forky" not in job_env:
        errors.append("job env must set SNOSI_BOOTC_SECURE_SUITE: forky")

    forky_steps = steps(job)
    by_name = dict(forky_steps)

    # 2. Never latest, R2, release or artifact upload.
    job_code = code(job)
    for text in FORBIDDEN_TEXT:
        if any(text in line for line in job_code):
            errors.append(f"no step may use {text}")
    for name, step in forky_steps:
        for line in code(step):
            if ":latest" in line:
                errors.append(f"step {name!r} names a :latest reference: {line.strip()}")

    # 3. Forky build, forky tag, 14-digit IMAGE_VERSION, suite under sudo.
    version_step = by_name.get("Generate version tag", [])
    version_code = "\n".join(code(version_step))
    if 'echo "tag=forky-$version"' not in version_code or 'echo "version=$version"' not in version_code:
        errors.append("version step must output version=<timestamp> and tag=forky-<timestamp>")
    if "version=$(date +%Y%m%d%H%M%S)" not in version_code:
        errors.append("version step must derive a 14-digit timestamp")

    build = commands(by_name.get("Build Image", []))
    if not any("mkosi --release forky " in c and f'--image-version "{VERSION}"' in c for c in build):
        errors.append(f'Build Image must run mkosi --release forky with --image-version "{VERSION}"')

    package = commands(by_name.get("Package image", []))
    package_call = [c for c in package if "buildah-package.sh" in c]
    if len(package_call) != 1:
        errors.append("Package image must call buildah-package.sh exactly once")
    else:
        call = package_call[0]
        if f'"$IMAGE:{TAG}"' not in call:
            errors.append("Package image must package $IMAGE:<forky tag>")
        if f'"org.opencontainers.image.version={VERSION}"' not in call:
            errors.append("the image version label must be the 14-digit version")
    if any(f"org.opencontainers.image.version={TAG}" in line for line in job):
        errors.append("the image version label must not carry the forky- tag")

    for name in ("Check image version annotation", "Check image version annotation on pushed digest"):
        step_commands = [c for c in commands(by_name.get(name, [])) if "check-image-version.sh" in c]
        if len(step_commands) != 1 or f'"{VERSION}"' not in step_commands[0]:
            errors.append(f"{name} must check the 14-digit version")

    push = [c for c in commands(by_name.get("Push immutable version tag", [])) if "push-immutable-image.sh" in c]
    if len(push) != 1 or not push[0].rstrip(")").endswith(f'"$IMAGE" "{TAG}"'):
        errors.append("Push immutable version tag must push exactly $IMAGE <forky tag>")

    verify = by_name.get("Verify pushed secure image", [])
    if f"          VERSION_TAG: {TAG}" not in verify:
        errors.append("Verify pushed secure image must verify the forky tag")
    for name in ("Verify pushed secure image", "Validate policy-copied secure artifact"):
        if "          LOCAL_REF: localhost/snosi-verified-${{ matrix.profile }}:" + TAG not in by_name.get(name, []):
            errors.append(f"{name} must use the local reference of the forky tag")

    for name, step in forky_steps:
        for command in commands(step):
            if not re.search(r"(^|[\s(])sudo\s", command):
                continue
            for script in SUITE_AWARE:
                if script in command:
                    before = command.split(script, 1)[0]
                    if SUITE_PASS not in before:
                        errors.append(f"step {name!r} runs {script} under sudo without {SUITE_PASS}")

    # 4. Drift guard against build-images.yml secure-build.
    images_job = job_block(images_text.splitlines(), "secure-build")
    if images_job is None:
        errors.append("build-images.yml has no secure-build job")
        return errors
    images_steps = steps(images_job)
    for omitted in OMITTED_STEPS:
        if omitted not in dict(images_steps):
            errors.append(f"build-images.yml secure-build no longer has the omitted step {omitted!r}; update this test")
    expected = [name for name, _ in images_steps if name not in OMITTED_STEPS] + [SUMMARY_STEP]
    actual = [name for name, _ in forky_steps]
    if actual != expected:
        errors.append(
            "step names differ from build-images.yml secure-build minus the omitted steps, plus the summary step:\n"
            f"  expected {expected}\n  actual   {actual}"
        )
    images_by_name = dict(images_steps)
    for name, step in forky_steps:
        if name in images_by_name:
            forky_uses = [line.strip() for line in step if line.strip().startswith("uses:")]
            images_uses = [line.strip() for line in images_by_name[name] if line.strip().startswith("uses:")]
            if forky_uses != images_uses:
                errors.append(f"step {name!r} uses {forky_uses}, but secure-build uses {images_uses}")
            if name not in VARIED_STEPS:
                forky_body = "\n".join(step).rstrip()
                images_body = "\n".join(images_by_name[name]).rstrip()
                if forky_body != images_body:
                    errors.append(f"step {name!r} differs from secure-build; only {sorted(VARIED_STEPS)} may differ")
    return errors


def _replace_nth(text: str, old: str, new: str, nth: int) -> str:
    """Replace only the nth (1-based) occurrence of old."""
    index = -1
    for _ in range(nth):
        index = text.find(old, index + 1)
        if index < 0:
            raise SystemExit(f"{PREFIX} FAIL self-test anchor is missing: {old!r} #{nth}")
    return text[:index] + new + text[index + len(old):]


def self_test(forky_text: str, images_text: str) -> int:
    def sub(old: str, new: str, count: int = 1):
        def mutate(text: str) -> str:
            if old not in text:
                raise SystemExit(f"{PREFIX} FAIL self-test anchor is missing: {old!r}")
            return text.replace(old, new, count)
        return mutate

    cases = {
        "push trigger": sub("on:\n  workflow_dispatch:\n", "on:\n  workflow_dispatch:\n  push:\n    branches: [main]\n"),
        "main gate removed": sub("github.ref == 'refs/heads/main'", "true", 2),
        "publish job main gate removed": lambda t: _replace_nth(t, "github.ref == 'refs/heads/main'", "true", 2),
        "select job main gate removed": lambda t: _replace_nth(t, "github.ref == 'refs/heads/main'", "true", 1),
        "an all option": sub("          - sundog\n", "          - sundog\n          - all\n"),
        "a fifth profile": sub("          - sundog\n", "          - sundog\n          - cayo\n"),
        "a fifth table row": sub(
            '            sundog) description="Sundog Linux OS Image" ;;\n',
            '            sundog) description="Sundog Linux OS Image" ;;\n            cayo) description="Cayo" ;;\n',
        ),
        "a description that differs from secure-build": sub('snow) description="Snow Linux OS Image"', 'snow) description="Snow Image"'),
        "inputs.profile in a run script": sub('case "$PROFILE" in', 'case "${{ inputs.profile }}" in'),
        "inputs.profile in the build": sub("--profile ${{ matrix.profile }}", "--profile ${{ inputs.profile }}"),
        "fallback accepts any value": sub("exit 1 ;;\n          esac", "description=x ;;\n          esac"),
        "all products in one run": sub(SELECT_JSON, "'[{profile: \"floe\"}, {profile: $profile, description: $description}]')"),
        "static matrix entry": sub(MATRIX_INCLUDE + "\n", "        include:\n          - profile: floe\n            description: \"Floe Linux Server Image\"\n"),
        "select job with a token": sub("    permissions: {}\n    outputs:", "    permissions:\n      contents: read\n    outputs:"),
        "select job with a checkout": sub(
            "      - name: Select the product\n",
            "      - name: Checkout\n        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n      - name: Select the product\n",
        ),
        "publish job without needs": sub("    needs: select\n", ""),
        "input not required": sub("        required: true\n", "        required: false\n"),
        "environment removed": sub("    environment: native-build\n", ""),
        "suite env removed": sub("      SNOSI_BOOTC_SECURE_SUITE: forky\n", ""),
        "suite env trixie": sub("      SNOSI_BOOTC_SECURE_SUITE: forky\n", "      SNOSI_BOOTC_SECURE_SUITE: trixie\n"),
        "promote step added": sub(
            "      - name: Install ORAS\n",
            "      - name: Install ORAS\n        run: ./shared/bootc-secure/ci/promote-published-image.sh x y z\n",
        ),
        "latest reference": sub('"docker://$IMAGE@$DIGEST" "', '"docker://$IMAGE:latest" "'),
        "trixie build": sub("mkosi --release forky ", "mkosi "),
        "bare timestamp tag": sub('echo "tag=forky-$version"', 'echo "tag=$version"'),
        "package without suite": sub('            SNOSI_BOOTC_SECURE_SUITE="$SNOSI_BOOTC_SECURE_SUITE" \\\n            ./shared/outformat', "            ./shared/outformat"),
        "push without suite": sub('sudo TMPDIR="$TMPDIR" SNOSI_BOOTC_SECURE_SUITE="$SNOSI_BOOTC_SECURE_SUITE" \\\n', 'sudo TMPDIR="$TMPDIR" \\\n'),
        "artifact without suite": sub(
            '            SNOSI_BOOTC_SECURE_SUITE="$SNOSI_BOOTC_SECURE_SUITE" \\\n            ./test/bootc-secure-artifact-test.sh',
            "            ./test/bootc-secure-artifact-test.sh",
        ),
        "version label carries tag": sub(f'"org.opencontainers.image.version={VERSION}"', f'"org.opencontainers.image.version={TAG}"'),
        "push of version": sub(f'push-immutable-image.sh "$IMAGE" "{TAG}"', f'push-immutable-image.sh "$IMAGE" "{VERSION}"'),
        "verify of version": sub(f"          VERSION_TAG: {TAG}", f"          VERSION_TAG: {VERSION}"),
        "summary step removed": sub(f"      - name: {SUMMARY_STEP}\n", "      - name: Something else\n"),
        "step renamed": sub("      - name: Sign SBOM\n", "      - name: Sign the SBOM\n"),
        "credential compare dropped": sub(
            "          cmp -s /var/tmp/bootc-secure-credentials/mok.crt shared/native-ab/keys/mok-2026.crt || {",
            "          true || {",
        ),
        "cosign key changed": sub(
            'cosign sign --key env://COSIGN_PRIVATE_KEY --yes \\\n            "$IMAGE@${{ steps.push.outputs.digest }}"',
            'cosign sign --key env://OTHER_KEY --yes \\\n            "$IMAGE@${{ steps.push.outputs.digest }}"',
        ),
        "action pin drift": sub(
            "uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8",
            "uses: actions/attest-build-provenance@0000000000000000000000000000000000000000",
        ),
    }
    failures = 0
    if check(forky_text, images_text):
        print(f"{PREFIX} FAIL self-test baseline is not clean", file=sys.stderr)
        failures += 1
    for name, mutate in cases.items():
        if not check(mutate(forky_text), images_text):
            print(f"{PREFIX} FAIL self-test mutation passed: {name}", file=sys.stderr)
            failures += 1
    # A step added to secure-build that forky-publish lacks must fail too.
    images_mutated = images_text.replace(
        "      - name: Install ORAS\n",
        "      - name: New secure step\n        run: true\n\n      - name: Install ORAS\n",
        1,
    )
    if not check(forky_text, images_mutated):
        print(f"{PREFIX} FAIL self-test mutation passed: secure-build step added", file=sys.stderr)
        failures += 1
    # A product description changed in secure-build must fail the select table.
    images_mutated = images_text.replace('description: "Sundog Linux OS Image"', 'description: "Sundog OS"', 1)
    if images_mutated == images_text or not check(forky_text, images_mutated):
        print(f"{PREFIX} FAIL self-test mutation passed: secure-build description changed", file=sys.stderr)
        failures += 1
    return len(cases) + 3 if failures == 0 else -failures


def main() -> int:
    forky_text = FORKY.read_text()
    images_text = BUILD_IMAGES.read_text()
    errors = check(forky_text, images_text)
    if f"\t{COMMAND}" not in MAKEFILE.read_text():
        errors.append(f"Makefile verify must run {COMMAND}")
    if f"run: {COMMAND}" not in VALIDATE.read_text():
        errors.append(f"validate.yml must run {COMMAND}")
    cases = self_test(forky_text, images_text)
    if cases < 0:
        errors.append(f"{-cases} self-test case(s) failed")
    if errors:
        for error in errors:
            print(f"{PREFIX} FAIL {error}", file=sys.stderr)
        return 1
    print(f"{PREFIX} PASSED ({len(steps(job_block(forky_text.splitlines(), JOB) or []))} steps, {cases} self-test cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
