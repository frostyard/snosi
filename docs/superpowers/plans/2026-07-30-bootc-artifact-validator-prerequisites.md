# Bootc Secure Artifact Validator Prerequisites Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the unused host-bootc blocker from protected OCI artifact validation while preserving candidate-image bootc digest verification.

**Architecture:** Correct the validator wrapper's host command contract from `bootc` to `podman`; the underlying assembler continues to run the pinned bootc 1.16.3 from the candidate image. Guard that boundary with an existing static contract test and verify it in a fresh protected production build before any registry promotion is accepted.

**Tech Stack:** Bash, Podman, bootc 1.16.3, GitHub Actions, ShellCheck, actionlint

## Global Constraints

- Correct only the live artifact validator's host prerequisite contract.
- Do not change UKI assembly, digest computation, candidate labels, signing credentials, registry publication, promotion ordering, or the pinned bootc compatibility contract.
- The candidate image remains the sole bootc runtime for storage-digest validation.
- Protected validation must require host `podman` and must not require a host `bootc` executable.
- A failed local validation must continue to prevent every immutable push and `latest` promotion.
- Update `CLAUDE.md`, `README.md`, and `yeti/ci-cd.md` with the candidate-image bootc boundary.

---

### Task 1: Correct And Guard Validator Prerequisites

**Files:**
- Modify: `test/bootc-secure-static-test.sh:7-12`
- Modify: `test/bootc-secure-artifact-test.sh:22-25`
- Modify: `CLAUDE.md:141-158`
- Modify: `README.md:62-70`
- Modify: `yeti/ci-cd.md:52-57`

**Interfaces:**
- Consumes: `shared/bootc-secure/assemble-uki.sh --validate`, which invokes `podman run ... IMAGE bootc container compute-composefs-digest-from-storage IMAGE`.
- Produces: A live artifact wrapper that checks every host executable it actually needs and delegates bootc execution to the candidate image.

- [ ] **Step 1: Add the failing static prerequisite contract**

Add the artifact-validator path beside the existing path declarations in `test/bootc-secure-static-test.sh`:

```bash
artifact_validator="$root/test/bootc-secure-artifact-test.sh"
```

Add this contract immediately after the path declarations:

```bash
# Live validation executes the candidate image's pinned bootc through Podman;
# it must not depend on an independently installed host bootc.
grep -Fq 'for command in buildah jq objcopy objdump openssl podman sbverify; do' \
    "$artifact_validator"
if grep -Eq '^for command in .*\bbootc\b' "$artifact_validator"; then
    echo "bootc secure artifact validation must use candidate-image bootc, not host bootc" >&2
    exit 1
fi
```

- [ ] **Step 2: Run the static contract and confirm the expected failure**

Run:

```bash
test/bootc-secure-static-test.sh
```

Expected: nonzero exit at the new `grep -Fq` because the current prerequisite list contains `bootc` instead of `podman`.

- [ ] **Step 3: Correct the live validator prerequisite list**

Change the command loop in `test/bootc-secure-artifact-test.sh` to exactly:

```bash
for command in buildah jq objcopy objdump openssl podman sbverify; do
    command -v "$command" >/dev/null || { echo "BLOCKED: missing $command" >&2; exit 2; }
done
```

Do not change the subsequent assembler invocation.

- [ ] **Step 4: Document the runtime boundary**

Add this sentence to the Task 10 CI paragraph in `CLAUDE.md` after its local validation description:

```markdown
Local and policy-copied artifact validation use host Podman to execute the
candidate image's pinned bootc; they do not require or accept an independently
installed host bootc as the storage-digest authority.
```

Add this paragraph after the output table in `README.md`:

```markdown
Protected bootc publication validates each candidate with host Podman while
running the candidate image's pinned bootc for its composefs storage digest.
The publisher does not depend on a separate host bootc installation, avoiding
version drift at that compatibility boundary.
```

Extend protected-publication step 1 in `yeti/ci-cd.md` with:

```markdown
Local validation requires host Podman, not host bootc: the validator runs the
candidate image's pinned bootc 1.16.3 to recompute its storage composefs digest.
The same boundary applies to the policy-copied validation after registry pull.
```

- [ ] **Step 5: Run focused contract and fixture verification**

Run:

```bash
test/bootc-secure-static-test.sh
test/bootc-secure-artifact-test.sh --fixtures
test/bootc-publication-guard-test.sh
```

Expected: every command exits 0; artifact fixtures print `bootc secure artifact fixtures passed`; the publication guard reports zero failures.

- [ ] **Step 6: Run shell and workflow lint**

Run:

```bash
shellcheck test/bootc-secure-static-test.sh test/bootc-secure-artifact-test.sh
actionlint .github/workflows/build-images.yml
git diff --check
```

Expected: all commands exit 0 with no diagnostics.

- [ ] **Step 7: Review and commit the implementation**

Run:

```bash
git diff -- test/bootc-secure-static-test.sh test/bootc-secure-artifact-test.sh CLAUDE.md README.md yeti/ci-cd.md
git status --short
git add test/bootc-secure-static-test.sh test/bootc-secure-artifact-test.sh CLAUDE.md README.md yeti/ci-cd.md
git commit -m "fix: use candidate bootc for artifact validation"
```

Expected: the implementation commit contains exactly the two test scripts and three required documentation files.

### Task 2: Publish Repair And Verify Protected Builds

**Files:**
- No repository file changes.

**Interfaces:**
- Consumes: Task 1's reviewed validator correction and the protected `native-build` environment's validated MOK/PCR credentials.
- Produces: Three immutable signed OCI digests whose local and policy-copied secure artifact validation passed before their corresponding `latest` tags moved.

- [ ] **Step 1: Push the branch and open the focused PR**

Run:

```bash
git push -u origin fix/bootc-artifact-host-prereq
PR_URL=$(gh pr create --repo frostyard/snosi \
  --base main \
  --head fix/bootc-artifact-host-prereq \
  --title "fix: use candidate bootc for artifact validation" \
  --body $'## Summary\n- require host Podman instead of unused host bootc during secure artifact validation\n- preserve the candidate image pinned-bootc storage-digest probe\n- add static regression coverage and document the dependency boundary\n\n## Failure evidence\nProtected run 30551607539 passed credential materialization and packaging for all profiles, then each local validator returned BLOCKED: missing bootc before any registry write.\n\n## Validation\n- bootc secure static contract\n- artifact fixtures\n- publication guard\n- ShellCheck\n- actionlint')
PR_NUMBER=${PR_URL##*/}
printf 'PR %s: %s\n' "$PR_NUMBER" "$PR_URL"
```

Expected: a PR against `main` containing only the approved design, plan, implementation, tests, and documentation.

- [ ] **Step 2: Review checks and merge**

Run:

```bash
PR_NUMBER=$(gh pr view --repo frostyard/snosi --json number --jq .number)
gh pr checks "$PR_NUMBER" --repo frostyard/snosi --watch
gh pr diff "$PR_NUMBER" --repo frostyard/snosi
gh pr merge "$PR_NUMBER" --repo frostyard/snosi --squash --delete-branch
```

Expected: all required checks pass and the focused PR is squash-merged without generated artifacts.

- [ ] **Step 3: Dispatch a fresh protected build from merged main**

Run:

```bash
RUN_URL=$(gh workflow run build-images.yml --repo frostyard/snosi --ref main)
RUN_ID=${RUN_URL##*/}
printf 'Run %s: %s\n' "$RUN_ID" "$RUN_URL"
```

Expected: one `workflow_dispatch` run starts three protected `secure-build` matrix jobs; `mechanics-build` is skipped.

- [ ] **Step 4: Watch the complete production publication run**

Run:

```bash
RUN_ID=$(gh run list --repo frostyard/snosi --workflow build-images.yml \
  --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --repo frostyard/snosi --exit-status --interval 20
```

Expected for each of `cayo`, `snow`, and `snowfield`:

```text
Materialize protected bootc signing credentials   success
Package image                                     success
Validate locally assembled secure artifact        success
Push immutable version tag                        success
Sign immutable image digest                       success
Verify pushed secure image                        success
Validate policy-copied secure artifact             success
Promote validated digest to latest                success
```

- [ ] **Step 5: Record immutable image evidence**

Run:

```bash
RUN_ID=$(gh run list --repo frostyard/snosi --workflow build-images.yml \
  --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')
gh run view "$RUN_ID" --repo frostyard/snosi \
  --json url,headSha,status,conclusion,jobs
```

Read each successful matrix job log and record its 14-digit version tag and pushed `sha256:` digest. Confirm the run reached promotion only after both artifact-validation steps. Record these as the first secure candidate set; do not classify one build as distinct `N`, `N+1`, and `N+2`, and do not claim Task 9 installed-system evidence.
