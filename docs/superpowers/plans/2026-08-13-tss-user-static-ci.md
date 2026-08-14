# TSS User Initrd Static CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run PR #731's TSS user initrd static contract in the standard per-PR validation workflow.

**Architecture:** Add one independently named step to the existing `shell-lint` job in `.github/workflows/validate.yml`. Keep the contract separate from the native A/B static test so GitHub Actions reports failures with clear attribution.

**Tech Stack:** GitHub Actions YAML, POSIX shell contract test, actionlint

## Global Constraints

- Run `./test/tss-user-initrd-static-test.sh` immediately after `./test/native-ab-static-test.sh`.
- Use a separate workflow step; do not create another job or combine both commands in one step.
- Modify no production image behavior.

---

### Task 1: Wire the TSS User Initrd Contract into CI

**Files:**
- Modify: `.github/workflows/validate.yml:85-88`

**Interfaces:**
- Consumes: executable contract `test/tss-user-initrd-static-test.sh` added by PR #731
- Produces: a `shell-lint` step that executes that contract on pull requests, pushes to `main`, and manual workflow runs

- [ ] **Step 1: Confirm the contract is not yet wired**

Run:

```bash
grep -nF './test/tss-user-initrd-static-test.sh' .github/workflows/validate.yml
```

Expected: exit status 1 and no output.

- [ ] **Step 2: Add the independently named workflow step**

Insert immediately after `Validate native A/B invariants`:

```yaml
      - name: Validate TSS user initrd integration
        run: ./test/tss-user-initrd-static-test.sh
```

- [ ] **Step 3: Run the contract test**

Run:

```bash
./test/tss-user-initrd-static-test.sh
```

Expected: exit status 0 with all TAP assertions passing.

- [ ] **Step 4: Validate the workflow and patch**

Run:

```bash
actionlint .github/workflows/validate.yml
git diff --check
```

Expected: both commands exit 0 with no diagnostics.

- [ ] **Step 5: Commit the workflow change**

```bash
git add .github/workflows/validate.yml
git commit -m "ci: run tss-user initrd static test"
```

- [ ] **Step 6: Push the PR branch**

Run:

```bash
git push origin scanner/fix-initrd-tss-user
```

Expected: the remote branch advances and PR #731 includes the workflow step.
