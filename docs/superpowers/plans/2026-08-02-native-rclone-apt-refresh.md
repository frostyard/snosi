# Native Promotion rclone APT Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every native promotion job refreshes its fresh runner's APT index immediately before installing rclone, preventing mirror 404 failures on reruns.

**Architecture:** Keep Ubuntu's packaged rclone and change only the four conditional promotion install steps. A Python standard-library structural test extracts each `Install rclone` step and enforces exact count and update-before-install ordering; CI and maintainer documentation record the invariant.

**Tech Stack:** GitHub Actions YAML, Python 3 standard library, actionlint.

## Global Constraints

- Change only `promote-cayo`, `promote-snow`, `promote-snowfield`, and `promote-iso` rclone install steps.
- Keep each step's existing verified-marker/prepared-metadata condition unchanged.
- Run `sudo apt-get update` immediately before `sudo apt-get install -y rclone`.
- Do not add retries, `--fix-missing`, third-party setup actions, or upstream binary downloads.
- Do not change R2 credentials, rclone configuration, transfer commands, signing, or promotion behavior.
- Update `CLAUDE.md` and `yeti/ci-cd.md`; README.md was reviewed and needs no change because it does not document hosted-runner package installation.

---

### Task 1: Refresh APT Before Promotion rclone Installation

**Files:**
- Create: `test/native-rclone-install-test.py`
- Modify: `.github/workflows/build-native-images.yml:843-845,965-967,1087-1089,1399-1401`
- Modify: `.github/workflows/validate.yml:88-104`
- Modify: `CLAUDE.md:1582`
- Modify: `yeti/ci-cd.md:161-170`
- Test: `test/native-rclone-install-test.py`

**Interfaces:**
- Consumes: `.github/workflows/build-native-images.yml` step names and shell scripts.
- Produces: a CI contract requiring exactly four `Install rclone` steps, each with APT refresh before install.

- [ ] **Step 1: Write the failing structural test**

Create `test/native-rclone-install-test.py`:

```python
#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/build-native-images.yml"
STEP_PREFIX = "      - name: "


def named_step_blocks(text: str, name: str) -> list[list[str]]:
    lines = text.splitlines()
    starts = [
        index
        for index, line in enumerate(lines)
        if line == f"{STEP_PREFIX}{name}"
    ]
    blocks = []
    for start in starts:
        end = next(
            (
                index
                for index in range(start + 1, len(lines))
                if lines[index].startswith(STEP_PREFIX)
            ),
            len(lines),
        )
        blocks.append(lines[start:end])
    return blocks


workflow = WORKFLOW.read_text()
blocks = named_step_blocks(workflow, "Install rclone")
if len(blocks) != 4:
    raise SystemExit(f"expected exactly 4 Install rclone steps, found {len(blocks)}")

for number, block in enumerate(blocks, start=1):
    commands = [line.strip() for line in block]
    try:
        update = commands.index("sudo apt-get update")
        install = commands.index("sudo apt-get install -y rclone")
    except ValueError as error:
        raise SystemExit(
            f"Install rclone step {number} must refresh APT and install rclone"
        ) from error
    if update >= install:
        raise SystemExit(
            f"Install rclone step {number} must refresh APT before installation"
        )

print("native-rclone-install-test: PASSED")
```

- [ ] **Step 2: Run the test and verify the red state**

Run `python3 test/native-rclone-install-test.py`.

Expected: exit nonzero with `Install rclone step 1 must refresh APT and install rclone` because the current one-line steps have no update.

- [ ] **Step 3: Fix all four promotion install steps**

Replace each promotion step's one-line `run:` value with this block, preserving its existing `if:` expression byte-for-byte:

```yaml
        run: |
          sudo apt-get update
          sudo apt-get install -y rclone
```

- [ ] **Step 4: Run the test and verify green**

Run `python3 test/native-rclone-install-test.py`.

Expected: `native-rclone-install-test: PASSED` and exit zero.

- [ ] **Step 5: Wire the regression into validate.yml**

Add this step immediately after `Validate native A/B publication and signing pipeline`:

```yaml
      - name: Validate native promotion rclone installation
        # Fresh promotion runners must refresh APT before installing rclone;
        # stale hosted-runner indexes can reference mirror revisions already removed.
        run: python3 test/native-rclone-install-test.py
```

- [ ] **Step 6: Update maintainer documentation**

Append to the `build-native-images.yml` bullet in `CLAUDE.md`:

```text
Each fresh promotion runner refreshes APT immediately before installing rclone;
never rely on the hosted image's preloaded package index, because reruns can
reference package revisions already removed from Ubuntu mirrors.
```

In `yeti/ci-cd.md` item 5, state that the four promotion jobs conditionally run an `Install rclone` step only when both artifacts are present, and that this step runs `apt-get update` immediately before installation to avoid stale hosted-runner indexes on delayed reruns.

- [ ] **Step 7: Run complete verification**

Run:

```bash
python3 -m py_compile test/native-rclone-install-test.py
python3 test/native-rclone-install-test.py
actionlint .github/workflows/build-native-images.yml .github/workflows/validate.yml
./test/native-publication-pipeline-test.sh
git diff --check
```

Expected: Python compilation and both linters exit zero; the new test prints `PASSED`; the existing pipeline reports `49 passed, 0 failed`; diff check is clean.

- [ ] **Step 8: Review, commit, push, and open the requested PR**

Review `git status`, the complete diff, and recent log. Commit only the workflow, test, design/plan, and documentation changes with:

```bash
git commit -m "fix: refresh APT before native promotion"
```

Push `fix/native-rclone-apt-refresh` and open a PR against `main` summarizing the stale-index root cause and verification commands. Do not claim a live rerun has passed until GitHub executes the fixed workflow.
