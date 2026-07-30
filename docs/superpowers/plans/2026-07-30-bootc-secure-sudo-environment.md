# Bootc Secure Packaging Sudo Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forward secure assembly state explicitly through sudo so protected packaging enters the signed-UKI path.

**Architecture:** Keep GitHub Actions step-level declarations as the source of secure values, then repeat their names as explicit sudo command assignments at the privilege boundary. Extend the publication guard and its isolated mutation fixture to require both declaration and forwarding before a protected workflow is accepted.

**Tech Stack:** GitHub Actions YAML, sudo, Bash, Buildah, Podman, ShellCheck, actionlint

## Global Constraints

- Correct only the protected package invocation's sudo environment boundary and its publication guard.
- Do not change credential contents, assembly behavior, validation behavior, registry ordering, labels, or the secretless mechanics build.
- Explicitly forward `TMPDIR`, `SNOSI_BOOTC_SECURE`, `SNOSI_BOOTC_MOK_KEY`, `SNOSI_BOOTC_MOK_CERT`, `SNOSI_BOOTC_PCR_KEY`, and `SNOSI_BOOTC_PCR_CERT` after `sudo`.
- Do not use `sudo --preserve-env`.
- Only credential paths cross sudo; secret bytes remain in mode-0600 files under `/var/tmp`.
- A failed package or local validation must continue to prevent every registry write and `latest` promotion.
- Update `CLAUDE.md`, `README.md`, and `yeti/ci-cd.md` with the sudo boundary.

---

### Task 1: Forward And Guard Secure Packaging State

**Files:**
- Modify: `test/bootc-publication-guard-test.sh:52-89,109-149`
- Modify: `check-bootc-publication-guard.sh:95-125`
- Modify: `.github/workflows/build-images.yml:160-178`
- Modify: `CLAUDE.md:141-160`
- Modify: `README.md:62-75`
- Modify: `yeti/ci-cd.md:50-60`

**Interfaces:**
- Consumes: The five `SNOSI_BOOTC_*` values declared by the protected `Package image` step and `TMPDIR` from `$GITHUB_ENV`.
- Produces: A root packager process that receives those six values explicitly and a guard that rejects any declaration-only regression.

- [ ] **Step 1: Extend the isolated workflow fixture with explicit forwarding**

In `make_fixture()` within `test/bootc-publication-guard-test.sh`, extend the fixture's `Package image` step after its existing `env:` entries:

```yaml
        run: |
          sudo TMPDIR="$TMPDIR" \
            SNOSI_BOOTC_SECURE="$SNOSI_BOOTC_SECURE" \
            SNOSI_BOOTC_MOK_KEY="$SNOSI_BOOTC_MOK_KEY" \
            SNOSI_BOOTC_MOK_CERT="$SNOSI_BOOTC_MOK_CERT" \
            SNOSI_BOOTC_PCR_KEY="$SNOSI_BOOTC_PCR_KEY" \
            SNOSI_BOOTC_PCR_CERT="$SNOSI_BOOTC_PCR_CERT" \
            ./shared/outformat/image/buildah-package.sh output/cayo localhost/cayo:version
```

Add this mutation helper beside `remove_package_variable()`:

```bash
remove_forwarded_package_variable() {
    perl -0pi -e "s/^            $1=\\\"\\\$$1\\\" \\\\\n//m" \
        "$2/.github/workflows/build-images.yml"
}
```

Add this mutation loop immediately after the existing `remove_package_variable` loop:

```bash
for variable in SNOSI_BOOTC_SECURE SNOSI_BOOTC_MOK_KEY SNOSI_BOOTC_MOK_CERT SNOSI_BOOTC_PCR_KEY SNOSI_BOOTC_PCR_CERT; do
    assert_guard "missing sudo-forwarded $variable fails" 1 \
        remove_forwarded_package_variable "$variable"
done
```

Also add the `TMPDIR` anchor mutation beside the forwarding helper and loop:

```bash
remove_sudo_tmpdir() {
    perl -0pi -e 's/^          sudo TMPDIR="\$TMPDIR" \\\n//m' \
        "$1/.github/workflows/build-images.yml"
}

assert_guard 'missing sudo TMPDIR forwarding fails' 1 remove_sudo_tmpdir
```

- [ ] **Step 2: Run the guard fixture and confirm RED**

Run:

```bash
test/bootc-publication-guard-test.sh
```

Expected: the five new `missing sudo-forwarded ... fails` cases report `not ok` because the current guard checks only the step-level declarations.

- [ ] **Step 3: Extend the real publication guard**

In `check-bootc-publication-guard.sh`, capture the protected package step after validating the declaration list:

```bash
        package_step=$(awk '
            /^      - name: Package image$/ { capture=1 }
            capture && /^      - name: / && $0 != "      - name: Package image" { exit }
            capture { print }
        ' <<<"$secure_job")
```

Then require each name to be explicitly forwarded:

```bash
        forwarded_variables=(
            SNOSI_BOOTC_SECURE
            SNOSI_BOOTC_MOK_KEY
            SNOSI_BOOTC_MOK_CERT
            SNOSI_BOOTC_PCR_KEY
            SNOSI_BOOTC_PCR_CERT
        )
        for variable in "${forwarded_variables[@]}"; do
            forwarded_line=$(printf '            %s="$%s" \\' \
                "$variable" "$variable")
            require_text "$workflow protected package sudo environment" \
                "$package_step" "$forwarded_line"
        done
```

Also require the existing explicit `TMPDIR` assignment:

```bash
        sudo_tmpdir_line='          sudo TMPDIR="$TMPDIR" \'
        require_text "$workflow protected package sudo environment" \
            "$package_step" "$sudo_tmpdir_line"
```

The indentation and trailing continuation slash are intentional: the existing
`require_text()` helper uses `grep -Fqx` and therefore compares a complete
line, not a substring.

- [ ] **Step 4: Run the fixture and confirm the intended intermediate failure**

Run:

```bash
test/bootc-publication-guard-test.sh
```

Expected: the fixture baseline passes because it declares all forwarded values; each of the five secure-variable forwarding mutations and the `TMPDIR` anchor mutation pass by making the guard reject its fixture. The real-tree guard is not run yet because the production workflow still lacks forwarding.

- [ ] **Step 5: Forward secure values through sudo in the protected workflow**

Change only the protected `Package image` command in `.github/workflows/build-images.yml` to:

```yaml
          sudo TMPDIR="$TMPDIR" \
            SNOSI_BOOTC_SECURE="$SNOSI_BOOTC_SECURE" \
            SNOSI_BOOTC_MOK_KEY="$SNOSI_BOOTC_MOK_KEY" \
            SNOSI_BOOTC_MOK_CERT="$SNOSI_BOOTC_MOK_CERT" \
            SNOSI_BOOTC_PCR_KEY="$SNOSI_BOOTC_PCR_KEY" \
            SNOSI_BOOTC_PCR_CERT="$SNOSI_BOOTC_PCR_CERT" \
            ./shared/outformat/image/buildah-package.sh \
```

Retain every existing packager argument below that line unchanged. Do not alter the mechanics-build package command.

- [ ] **Step 6: Document the sudo boundary**

Add to the Task 10 CI paragraph in `CLAUDE.md`:

```markdown
The protected package step forwards the secure flag and credential paths as
explicit sudo command assignments; GitHub step environment values do not cross
sudo implicitly, and secret bytes remain only in the mode-0600 files.
```

Add after the protected bootc publication paragraph in `README.md`:

```markdown
The protected packager passes its secure assembly flag and credential paths
explicitly through sudo. The private bytes stay in mode-0600 runner files;
only their paths cross the privilege boundary.
```

Extend protected-publication step 1 in `yeti/ci-cd.md` with:

```markdown
The package command repeats all five `SNOSI_BOOTC_*` names as explicit sudo
assignments because step-level environment values are otherwise filtered by
sudo. Do not replace this with implicit preservation or pass secret bytes in
arguments.
```

- [ ] **Step 7: Run all focused verification**

Run:

```bash
test/bootc-publication-guard-test.sh
./check-bootc-publication-guard.sh
test/bootc-secure-package-cleanup-test.sh
test/bootc-secure-artifact-negative-test.sh --fixtures
shellcheck check-bootc-publication-guard.sh \
  test/bootc-publication-guard-test.sh
actionlint .github/workflows/build-images.yml
git diff --check
```

Expected: all commands exit 0; the publication fixture reports 29 passing assertions and zero failures; both package fixture scripts pass.

- [ ] **Step 8: Review and commit Task 1**

Run:

```bash
git diff -- .github/workflows/build-images.yml check-bootc-publication-guard.sh test/bootc-publication-guard-test.sh CLAUDE.md README.md yeti/ci-cd.md
git status --short
git add .github/workflows/build-images.yml check-bootc-publication-guard.sh test/bootc-publication-guard-test.sh CLAUDE.md README.md yeti/ci-cd.md
git commit -m "fix: forward secure packaging state through sudo"
```

Expected: exactly the protected workflow, guard, guard fixture, and three documentation files are committed.

### Task 2: Merge And Re-run Protected Publication

**Files:**
- No repository file changes.

**Interfaces:**
- Consumes: Task 1's reviewed explicit forwarding and the existing protected `native-build` credentials.
- Produces: Three signed immutable OCI candidates promoted only after local and policy-copied artifact validation.

- [ ] **Step 1: Push and create the focused PR**

Run:

```bash
test "$(git branch --show-current)" = fix/bootc-secure-sudo-env
git push -u origin fix/bootc-secure-sudo-env
PR_URL=$(gh pr create --repo frostyard/snosi \
  --base main \
  --head fix/bootc-secure-sudo-env \
  --title "fix: forward secure packaging state through sudo" \
  --body $'## Summary\n- explicitly forward secure assembly state through sudo\n- reject declaration-only regressions in the publication guard\n- document the privilege-boundary contract\n\n## Failure evidence\nRun 30555492550 passed credentials but packaged without a UKI because sudo filtered the five SNOSI_BOOTC_* values; local validation failed before registry writes.\n\n## Validation\n- publication guard fixture and real-tree guard\n- package cleanup and negative fixtures\n- ShellCheck\n- actionlint')
PR_NUMBER=${PR_URL##*/}
printf 'PR %s: %s\n' "$PR_NUMBER" "$PR_URL"
```

- [ ] **Step 2: Wait for checks, inspect, and merge**

Run:

```bash
PR_NUMBER=$(gh pr view --repo frostyard/snosi --json number --jq .number)
gh pr checks "$PR_NUMBER" --repo frostyard/snosi --watch
gh pr diff "$PR_NUMBER" --repo frostyard/snosi
gh pr merge "$PR_NUMBER" --repo frostyard/snosi --squash --delete-branch
```

Expected: all required checks pass and the focused PR merges without generated files.

- [ ] **Step 3: Dispatch and watch a fresh protected build**

Run:

```bash
DISPATCHED_AT=$(date -u +%s)
gh workflow run build-images.yml --repo frostyard/snosi --ref main
RUN_JSON=
for _ in $(seq 1 30); do
  RUN_JSON=$(gh run list --repo frostyard/snosi \
    --workflow build-images.yml --branch main --event workflow_dispatch \
    --limit 10 --json databaseId,createdAt,url | \
    jq -c --argjson dispatched "$DISPATCHED_AT" \
      'map(select((.createdAt | fromdateiso8601) >= $dispatched)) |
       sort_by(.createdAt) | last // empty')
  [ -n "$RUN_JSON" ] && break
  sleep 2
done
[ -n "$RUN_JSON" ]
RUN_ID=$(jq -r .databaseId <<<"$RUN_JSON")
RUN_URL=$(jq -r .url <<<"$RUN_JSON")
printf 'Run %s: %s\n' "$RUN_ID" "$RUN_URL"
gh run watch "$RUN_ID" --repo frostyard/snosi --exit-status --interval 20
```

Expected for Cayo, Snow, and Snowfield:

```text
Package image                                  success
Validate locally assembled secure artifact     success
Push immutable version tag                     success
Sign immutable image digest                    success
Verify pushed secure image                     success
Validate policy-copied secure artifact          success
Promote validated digest to latest             success
```

- [ ] **Step 4: Record immutable evidence**

Run:

```bash
gh run view "$RUN_ID" --repo frostyard/snosi \
  --json url,headSha,status,conclusion,jobs
```

Record each profile's 14-digit version and immutable `sha256:` digest from its log, plus ordering proof that local validation preceded push and policy-copied validation preceded promotion. Treat the result as one secure candidate set, not distinct `N`, `N+1`, and `N+2`, and not installed-system Task 9 evidence.
