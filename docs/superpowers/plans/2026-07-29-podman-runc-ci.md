# Podman runc CI Override Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Snosi OCI image builds runnable on GitHub's `ubuntu-24.04` runner after its Podman 5.8.4 update by selecting the bundled `runc` runtime for both image-build jobs.

**Architecture:** Each disposable `secure-build` and `mechanics-build` host receives the same Podman configuration drop-in before any repository build or packaging command runs. A static contract test requires both jobs to install and verify that override, while the existing OCI smoke test remains the runtime proof.

**Tech Stack:** GitHub Actions YAML, Bash, Podman/containers.conf, repository fixture tests

## Global Constraints

- Change only CI-host behavior; do not alter OCI image contents or installed-system runtime defaults.
- Configure both `secure-build` and `mechanics-build`, because repository scripts contain nested `podman run` calls.
- Use the runner bundle's `runc`; do not download or pin another container runtime.
- Fail before image construction unless `podman info` reports `runc`.
- Do not commit unless the user explicitly requests a commit.

---

### Task 1: Select runc in Both OCI Build Jobs

**Files:**
- Modify: `test/bootc-secure-ci-test.sh:9-19,83-90`
- Modify: `.github/workflows/build-images.yml:70-89,410-429`
- Modify: `yeti/ci-cd.md:39-50`
- Modify: `CLAUDE.md` in the `CI/CD` section

**Interfaces:**
- Consumes: GitHub runner-provided `/usr/local/bin/runc`, Podman's `/etc/containers/containers.conf.d/` merge behavior, and `.Host.OCIRuntime.Name` from `podman info`.
- Produces: A job-local `99-snosi-ci-runtime.conf` that selects `runc`, plus a static contract preventing either build path from dropping the override.

- [ ] **Step 1: Add the failing static contract test**

Add this helper after `workflow_invokes_static_coverage_test()` in
`test/bootc-secure-ci-test.sh`:

```bash
workflow_job_selects_runc() { # workflow job
    local workflow=$1 job=$2 block
    block=$(awk -v header="  $job:" '
        $0 == header { in_job=1 }
        in_job && $0 ~ /^  [[:alnum:]_-]+:$/ && $0 != header { exit }
        in_job { print }
    ' "$workflow")
    [[ $block == *'- name: Configure Podman OCI runtime'* ]] \
        && [[ $block == *'runtime = "runc"'* ]] \
        && [[ $block == *"podman info --format '{{.Host.OCIRuntime.Name}}'"* ]] \
        && [[ $block == *'[[ $runtime == runc ]]'* ]]
}
```

Add these assertions before the result summary:

```bash
assert_true 'secure-build selects and verifies the runc OCI runtime' \
    workflow_job_selects_runc "$ROOT_DIR/.github/workflows/build-images.yml" secure-build
assert_true 'mechanics-build selects and verifies the runc OCI runtime' \
    workflow_job_selects_runc "$ROOT_DIR/.github/workflows/build-images.yml" mechanics-build
```

- [ ] **Step 2: Run the contract test and verify it fails**

Run:

```bash
./test/bootc-secure-ci-test.sh
```

Expected: the existing assertions pass, and the two new assertions print
`not ok` because neither job contains `Configure Podman OCI runtime` yet.

- [ ] **Step 3: Add the minimal runtime configuration to both jobs**

In `.github/workflows/build-images.yml`, add this identical step immediately
after `Mount BTRFS for podman storage` in both `secure-build` and
`mechanics-build`:

```yaml
      - name: Configure Podman OCI runtime
        # GitHub runner 20260726 upgraded Podman 4.9.3 -> 5.8.4; its default
        # crun path rejects the generated OCI version. The matched bundled
        # runc works for direct and script-nested podman invocations.
        run: |
          sudo install -d -m 0755 /etc/containers/containers.conf.d
          printf '%s\n' '[engine]' 'runtime = "runc"' \
            | sudo tee /etc/containers/containers.conf.d/99-snosi-ci-runtime.conf >/dev/null
          runtime=$(sudo podman info --format '{{.Host.OCIRuntime.Name}}')
          [[ $runtime == runc ]] || {
            echo "::error::Podman selected OCI runtime '$runtime', expected 'runc'" >&2
            exit 1
          }
```

Do not add `--runtime=runc` to individual smoke tests or nested scripts; the
job-level drop-in is the single source of truth.

- [ ] **Step 4: Run the focused contract and shell checks**

Run:

```bash
./test/bootc-secure-ci-test.sh
shellcheck -S warning -x test/bootc-secure-ci-test.sh
```

Expected: all contract assertions pass and ShellCheck emits no diagnostics.

- [ ] **Step 5: Verify runc can execute an existing Snosi OCI image**

Run:

```bash
sudo podman run --rm --runtime=runc ghcr.io/frostyard/cayo:20260726035912 \
  sh -ec 'test "$(stat -c "%a" /usr/bin/sudo)" = 4755; for command in bwrap systemctl objcopy ssh ssh-keygen; do command -v "$command" >/dev/null; done'
```

Expected: exit status 0 with no output.

- [ ] **Step 6: Update internal documentation**

Append this paragraph after the `mechanics-build`/`secure-build` overview in
`yeti/ci-cd.md`:

```markdown
Both jobs select the GitHub runner bundle's `runc` through a job-local
`containers.conf.d` drop-in and verify the effective runtime before building.
This avoids the hosted `20260726.254.1` Podman 5.8.4/default-crun incompatibility
(`crun: unknown version specified`) for direct smoke tests and nested Podman
calls without changing the runtime policy inside shipped images.
```

Add a matching concise note to `CLAUDE.md` under `build-images.yml` in the
`CI/CD` section. Do not change `README.md`: this is internal CI compatibility,
not user-facing behavior.

- [ ] **Step 7: Run repository-level static verification**

Run:

```bash
./test/bootc-secure-ci-test.sh
./check-bootc-publication-guard.sh
./test/bootc-publication-guard-test.sh
actionlint .github/workflows/build-images.yml
git diff --check
```

Expected: every command exits 0; fixture totals may increase only for the two
new runtime assertions; `git diff --check` prints nothing.

- [ ] **Step 8: Review the final diff without committing**

Run:

```bash
git status --short
git diff -- .github/workflows/build-images.yml test/bootc-secure-ci-test.sh yeti/ci-cd.md CLAUDE.md docs/superpowers/specs/2026-07-29-podman-runc-ci-design.md docs/superpowers/plans/2026-07-29-podman-runc-ci.md
```

Expected: only the approved workflow, regression test, and documentation
changes appear. Leave them uncommitted unless the user explicitly asks for a
commit.

- [ ] **Step 9: Obtain hosted-runner proof after publication**

After the user requests a commit/push, require all three `mechanics-build`
matrix jobs on PR #476 to pass. In each job log, verify:

```text
Configure Podman OCI runtime ... success
Smoke test - verify SUID bit and bcvk requirements ... success
```

At least one passing job must report runner image `20260726.254.1` or newer;
otherwise the run does not prove the regression is mitigated on the affected
host image.
