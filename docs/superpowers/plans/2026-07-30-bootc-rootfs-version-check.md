# Bootc Rootfs Version Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate the pinned bootc executable with its target rootfs libraries instead of the CI host ABI.

**Architecture:** A dedicated packager helper temporarily bind-mounts only `/proc` into the complete mkosi rootfs, runs `/usr/bin/bootc --version` through chroot, and unmounts before any image mutation or packaging. PATH-controlled fixture commands verify boundary calls, ownership refusal, diagnostics, and cleanup; a measured published-Cayo rootfs proof covers the real dynamic loader behavior that stubs cannot model.

**Tech Stack:** Bash, chroot/coreutils, mount/util-linux, Buildah, Podman, GitHub Actions

## Global Constraints

- The accepted output remains exactly `bootc 1.16.3`.
- Bind only host `/proc`; do not bind `/sys`, `/dev`, or any credential path.
- Reject a missing or already-mounted `$ROOTFS_DIR/proc`; do not create, reuse, or unmount a mount the helper does not own.
- Invoke `mount`, `mountpoint`, `chroot`, and `umount` by bare name so fixtures can intercept them through `PATH`.
- Unmount the helper-owned procfs before systemd-boot preparation or first-pass packaging starts.
- Surface rootfs execution diagnostics and distinguish execution failure from a successful wrong version without printing credentials.
- A failed unmount is fatal.
- Do not add `bwrap`, host bootc, host libostree, APT packages, or workflow prerequisites.
- Preserve the direct two-pass ukify contract, candidate-image storage-digest authority, secure labels, credential handling, sudo forwarding, cleanup behavior, fail-before-push ordering, and secretless mechanics build.
- Update `CLAUDE.md`, `README.md`, and `yeti/build-pipeline.md`.

---

### Task 1: Execute The Version Gate Inside The Rootfs

**Files:**
- Modify: `test/bootc-secure-package-cleanup-test.sh:19-139`
- Modify: `shared/outformat/image/buildah-package.sh:18-65`
- Modify: `CLAUDE.md:63-83`
- Modify: `README.md:435-456`
- Modify: `yeti/build-pipeline.md:55-72`

**Interfaces:**
- Consumes: A complete root-owned mkosi directory rootfs with an empty `/proc` directory and `/usr/bin/bootc` plus its target libraries.
- Produces: `probe_rootfs_bootc_version ROOTFS`, returning 0 only after exact pinned output and successful unmount; no mount survives the function.

- [ ] **Step 1: Add controlled rootfs-boundary commands to the fixture**

In `write_fixtures()` in `test/bootc-secure-package-cleanup-test.sh`, add
`"$root/proc"` to the initial `mkdir -p` list. Remove the rootfs shell bootc
fixture at lines 23-24; the controlled chroot command owns version output.

Add these commands under `$state/bin` before the existing Buildah fixture:

```bash
    cat >"$state/bin/mountpoint" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $1 == -q && $2 == "$BUILD_FIXTURE_ROOT/proc" ]]
[[ -e "$BUILD_FIXTURE_STATE/proc-mounted" ]]
EOF
    cat >"$state/bin/mount" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $1 == --bind && $2 == /proc && $3 == "$BUILD_FIXTURE_ROOT/proc" ]]
printf '%s\n' "$*" >"$BUILD_FIXTURE_STATE/mount-invoked"
touch "$BUILD_FIXTURE_STATE/proc-mounted"
EOF
    cat >"$state/bin/chroot" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $1 == "$BUILD_FIXTURE_ROOT" && $2 == /usr/bin/bootc && $3 == --version ]]
printf '%s\n' "$*" >"$BUILD_FIXTURE_STATE/chroot-invoked"
if [[ ${BUILD_FIXTURE_CHROOT_FAIL:-0} == 1 ]]; then
    echo 'fixture rootfs loader failure' >&2
    exit 86
fi
printf '%s\n' "${BUILD_FIXTURE_BOOTC_VERSION:-bootc 1.16.3}"
EOF
    cat >"$state/bin/umount" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $1 == "$BUILD_FIXTURE_ROOT/proc" ]]
printf '%s\n' "$*" >"$BUILD_FIXTURE_STATE/umount-invoked"
[[ ${BUILD_FIXTURE_UMOUNT_FAIL:-0} != 1 ]] || exit 87
rm -f "$BUILD_FIXTURE_STATE/proc-mounted"
EOF
```

Make all four commands executable alongside the existing fixtures:

```bash
    chmod +x "$state/bin/mountpoint" "$state/bin/mount" "$state/bin/chroot" \
        "$state/bin/umount" "$state/bin/buildah" "$state/bin/podman" "$state/assembler"
```

At the start of the controlled Buildah command, add:

```bash
touch "$BUILD_FIXTURE_STATE/buildah-invoked"
```

- [ ] **Step 2: Add positive call-shape assertions and prove RED**

Add to `assert_cleanup()` before image cleanup assertions:

```bash
    [[ -f "$state/mount-invoked" && $(<"$state/mount-invoked") == "--bind /proc $root/proc" ]] || fail "rootfs proc bind was not exact"
    [[ -f "$state/chroot-invoked" && $(<"$state/chroot-invoked") == "$root /usr/bin/bootc --version" ]] || fail "bootc version did not use rootfs chroot"
    [[ -f "$state/umount-invoked" && $(<"$state/umount-invoked") == "$root/proc" ]] || fail "rootfs proc unmount was not exact"
    [[ ! -e "$state/proc-mounted" ]] || fail "rootfs proc mount survived"
```

Pass `BUILD_FIXTURE_ROOT="$root"` in both secure packager invocations in
`run_case()`.

Run:

```bash
test/bootc-secure-package-cleanup-test.sh
```

Expected: FAIL because the current packager executes `$root/usr/bin/bootc`
directly, so no mount/chroot/unmount records exist.

- [ ] **Step 3: Add fail-closed probe fixtures**

Add this helper before the existing `run_case()` calls:

```bash
run_probe_failure_case() { # name expected-text setup-command env-name env-value
    local name=$1 expected=$2 setup=$3 env_name=$4 env_value=$5 work state root published status output
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' RETURN
    state="$work/state"; root="$work/root"
    published="localhost/task5-probe-$name:latest"
    write_fixtures "$state" "$root"
    [[ $setup == none ]] || "$setup" "$state" "$root"
    set +e
    output=$(env BUILD_FIXTURE_STATE="$state" BUILD_FIXTURE_ROOT="$root" PATH="$state/bin:$PATH" \
        SNOSI_BOOTC_SECURE=1 SNOSI_BOOTC_MOK_KEY=fixture SNOSI_BOOTC_MOK_CERT=fixture \
        SNOSI_BOOTC_PCR_KEY=fixture SNOSI_BOOTC_PCR_CERT=fixture \
        SNOSI_BOOTC_SECURE_TEST_HOOKS=1 SNOSI_BOOTC_SECURE_TEST_ASSEMBLER="$state/assembler" \
        "$env_name=$env_value" "$PACKAGER" "$root" "$published" 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 ]] || fail "$name unexpectedly succeeded"
    [[ $output == *"$expected"* ]] || fail "$name lacked diagnostic: $expected"
    [[ ! -e "$state/assembler-invoked" ]] || fail "$name reached the assembler"
    [[ ! -e "$state/buildah-invoked" ]] || fail "$name reached Buildah"
}

mark_proc_mounted() { touch "$1/proc-mounted"; }
remove_proc_dir() { rmdir "$2/proc"; }
```

Add the cases before the existing cleanup cases:

```bash
run_probe_failure_case proc-missing 'rootfs proc directory is missing' remove_proc_dir UNUSED 0
run_probe_failure_case proc-pre-mounted 'rootfs proc is already mounted' mark_proc_mounted UNUSED 0
run_probe_failure_case chroot-fails 'fixture rootfs loader failure' none BUILD_FIXTURE_CHROOT_FAIL 1
run_probe_failure_case wrong-version 'expected bootc 1.16.3, observed bootc 1.16.2' none BUILD_FIXTURE_BOOTC_VERSION 'bootc 1.16.2'
run_probe_failure_case umount-fails 'failed to unmount rootfs proc' none BUILD_FIXTURE_UMOUNT_FAIL 1
```

After `run_probe_failure_case()` captures output, add case-specific ownership
assertions:

```bash
    case $name in
        proc-missing)
            [[ ! -e "$state/mount-invoked" && ! -e "$root/proc" ]] || fail "$name changed malformed rootfs"
            ;;
        proc-pre-mounted)
            [[ ! -e "$state/mount-invoked" && ! -e "$state/umount-invoked" && -e "$state/proc-mounted" ]] || fail "$name touched an unowned mount"
            ;;
        chroot-fails|wrong-version)
            [[ -e "$state/umount-invoked" && ! -e "$state/proc-mounted" ]] || fail "$name did not clean its proc mount"
            ;;
        umount-fails)
            [[ -e "$state/umount-invoked" && -e "$state/proc-mounted" ]] || fail "$name did not expose failed unmount state"
            ;;
    esac
```

Run:

```bash
test/bootc-secure-package-cleanup-test.sh
```

Expected: FAIL because the current packager lacks the required diagnostics,
mount ownership check, and rootfs cleanup behavior.

- [ ] **Step 4: Implement the rootfs probe helper**

Add after `ROOTFS_DIR` argument validation in
`shared/outformat/image/buildah-package.sh`:

```bash
probe_rootfs_bootc_version() ( # rootfs
    local root=$1 proc="$1/proc" mounted=0 output status

    cleanup_proc() {
        local exit_status=$?
        trap - EXIT
        if [[ $mounted -eq 1 ]] && ! umount "$proc"; then
            echo "Error: failed to unmount rootfs proc: $proc" >&2
            exit_status=1
        fi
        exit "$exit_status"
    }

    [[ -d $proc ]] || {
        echo "Error: rootfs proc directory is missing: $proc" >&2
        exit 1
    }
    if mountpoint -q "$proc"; then
        echo "Error: rootfs proc is already mounted: $proc" >&2
        exit 1
    fi

    trap cleanup_proc EXIT
    mount --bind /proc "$proc" || {
        echo "Error: failed to bind host proc into rootfs: $proc" >&2
        exit 1
    }
    mounted=1

    set +e
    output=$(chroot "$root" /usr/bin/bootc --version 2>&1)
    status=$?
    set -e
    if [[ $status -ne 0 ]]; then
        printf 'Error: rootfs bootc execution failed:\n%s\n' "$output" >&2
        exit 1
    fi
    [[ $output == 'bootc 1.16.3' ]] || {
        printf 'Error: expected bootc 1.16.3, observed %s\n' "$output" >&2
        exit 1
    }
)
```

Replace the current direct version block:

```bash
    [[ $($ROOTFS_DIR/usr/bin/bootc --version ...) == ... ]]
```

with:

```bash
    probe_rootfs_bootc_version "$ROOTFS_DIR"
```

The helper subshell's EXIT trap completes its unmount before control returns to
the next assembler line.

- [ ] **Step 5: Run the fixture and confirm GREEN**

Run:

```bash
test/bootc-secure-package-cleanup-test.sh
```

Expected: `bootc secure package cleanup fixtures passed` and exit 0.

- [ ] **Step 6: Document the target-library probe boundary**

Add to the Task 5 paragraph in `CLAUDE.md`:

```markdown
Before first-pass packaging, the root packager temporarily bind-mounts only
host `/proc` into the complete mkosi rootfs and runs the exact bootc version
probe through chroot, so target libraries rather than the CI host ABI resolve.
It refuses pre-mounted/missing rootfs proc paths and unmounts before any image
mutation. Storage-digest authority remains bootc inside the candidate OCI image.
```

Add to the secure assembly paragraph in `README.md`:

```markdown
The protected packager checks its pinned bootc through the built rootfs with a
temporary procfs bind, then removes that bind before assembly. It does not
require a matching host bootc or host libostree ABI; candidate-image bootc
remains the storage-digest authority.
```

Add beside the two-pass packaging description in `yeti/build-pipeline.md`:

```markdown
The preflight version gate uses bare-name `mount`/`mountpoint`/`chroot`/`umount`:
it refuses a missing or pre-mounted `$ROOTFS_DIR/proc`, bind-mounts only host
`/proc`, runs `/usr/bin/bootc --version` against target libraries, and always
unmounts before `--prepare-systemd-boot-source`. Bare names are load-bearing
for the non-root PATH fixtures. This gate is not digest authority; both storage
digest probes still run bootc inside their candidate OCI images.
```

- [ ] **Step 7: Run complete focused verification**

Run:

```bash
test/bootc-secure-package-cleanup-test.sh
test/bootc-secure-artifact-negative-test.sh --fixtures
test/bootc-publication-guard-test.sh
./check-bootc-publication-guard.sh
shellcheck shared/outformat/image/buildah-package.sh \
  test/bootc-secure-package-cleanup-test.sh
git diff --check
```

Expected: all commands exit 0; cleanup and negative artifact fixtures pass;
publication guard reports 29 passing assertions and the real-tree guard passes;
ShellCheck and `git diff --check` produce no diagnostics.

- [ ] **Step 8: Review and commit Task 1**

Run:

```bash
git diff -- shared/outformat/image/buildah-package.sh test/bootc-secure-package-cleanup-test.sh CLAUDE.md README.md yeti/build-pipeline.md
git status --short
git add shared/outformat/image/buildah-package.sh test/bootc-secure-package-cleanup-test.sh CLAUDE.md README.md yeti/build-pipeline.md
git commit -m "fix: run bootc version probe inside rootfs"
```

Expected: exactly the packager, cleanup fixture, and three required
documentation files are committed.

### Task 2: Merge And Re-run Protected Publication

**Files:**
- No repository file changes.

**Interfaces:**
- Consumes: Task 1's reviewed rootfs probe and existing protected credentials.
- Produces: Three signed immutable OCI candidates promoted only after local and policy-copied artifact validation.

- [ ] **Step 1: Push and create the focused PR**

Run:

```bash
test "$(git branch --show-current)" = fix/bootc-rootfs-version-check
git push -u origin fix/bootc-rootfs-version-check
gh pr create --repo frostyard/snosi \
  --base main \
  --head fix/bootc-rootfs-version-check \
  --title "fix: run bootc version probe inside rootfs" \
  --body $'## Summary\n- execute the pinned bootc version gate with target rootfs libraries\n- bind only procfs and fail closed on mount ownership or cleanup errors\n- cover call shape, diagnostics, and cleanup with PATH fixtures\n\n## Failure evidence\nProtected run 30563925331 installed bootc 1.16.3 in all three rootfs directories but direct host-context execution failed before packaging; no registry write ran.\n\n## Validation\n- secure package cleanup fixture\n- secure artifact negative fixtures\n- publication guard fixture and real-tree guard\n- ShellCheck'
```

- [ ] **Step 2: Wait for checks and inspect the complete PR**

Run:

```bash
PR_NUMBER=$(gh pr view --repo frostyard/snosi --json number --jq .number)
gh pr checks "$PR_NUMBER" --repo frostyard/snosi --watch
gh pr diff "$PR_NUMBER" --repo frostyard/snosi
gh pr view "$PR_NUMBER" --repo frostyard/snosi \
  --json url,state,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup
```

Expected: all required checks pass. If branch protection requires independent
approval, stop without `--admin`; merge after the user supplies that approval.

- [ ] **Step 3: Squash-merge without bypassing branch protection**

Run:

```bash
gh pr merge "$PR_NUMBER" --repo frostyard/snosi --squash --delete-branch
```

Expected: the PR merges normally. Do not use `--admin`.

- [ ] **Step 4: Identify the automatic protected run for the merge SHA**

Run:

```bash
MERGE_SHA=$(gh pr view "$PR_NUMBER" --repo frostyard/snosi --json mergeCommit --jq .mergeCommit.oid)
RUN_JSON=$(gh run list --repo frostyard/snosi --workflow build-images.yml --branch main \
  --limit 10 --json databaseId,headSha,url,status,conclusion | \
  jq -c --arg sha "$MERGE_SHA" 'map(select(.headSha == $sha)) | first // empty')
[ -n "$RUN_JSON" ]
RUN_ID=$(jq -r .databaseId <<<"$RUN_JSON")
RUN_URL=$(jq -r .url <<<"$RUN_JSON")
printf 'Run %s: %s\n' "$RUN_ID" "$RUN_URL"
gh run watch "$RUN_ID" --repo frostyard/snosi --exit-status --interval 20
```

- [ ] **Step 5: Record immutable evidence and ordering**

Run:

```bash
gh run view "$RUN_ID" --repo frostyard/snosi \
  --json url,headSha,status,conclusion,jobs
gh run view "$RUN_ID" --repo frostyard/snosi --log | \
  rg 'org.opencontainers.image.version|sha256:|secureboot-capable|Package image|Validate locally assembled|Push immutable|Validate policy-copied|Promote validated'
```

Expected for Cayo, Snow, and Snowfield: package, local artifact validation,
immutable push, signing, remote verification, policy-copied artifact validation,
and latest promotion all succeed in that order. Record each 14-digit version
and immutable digest. Treat this as one secure candidate set, not distinct
`N`/`N+1`/`N+2` or installed-system Task 9 evidence.
