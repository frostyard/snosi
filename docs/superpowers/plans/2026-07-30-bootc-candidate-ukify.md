# Bootc Candidate-Image Ukify Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run pinned direct ukify inside the first-pass candidate image instead of depending on a host ukify installation.

**Architecture:** The packager hands its exact first-pass local image reference to the assembler. A focused assembler helper runs `/usr/bin/ukify` as the candidate entrypoint with no network, individual read-only credential mounts, and one public-only writable work mount; all target inputs use in-image paths while bootc remains storage-digest authority.

**Tech Stack:** Bash, Podman, Buildah, systemd-ukify 261.1-3, OpenSSL, ShellCheck

## Global Constraints

- Execute `/usr/bin/ukify` from the first-pass candidate image; do not install or invoke host ukify.
- Require exact Forky `systemd-ukify 261.1-3` layout: executable `/usr/bin/ukify`.
- Use `podman run --rm --network=none --security-opt label=type:unconfined_t --entrypoint=/usr/bin/ukify`.
- Mount MOK key, MOK certificate, active PCR key, and optional previous PCR key individually read-only at fixed `/run/snosi-ukify-*` paths.
- Mount exactly one assembler-owned public-only work directory writable at `/run/snosi-ukify-work`.
- Never use `:z`/`:Z`, mount a credential directory, use Podman secrets, create a retained container, or add privilege/PID-host access.
- Translate kernel, initrd, os-release, PCR-public-key, output, and credential arguments to in-container paths; no host rootfs/work path may remain in ukify argv.
- Redact both host and fixed in-container private-key paths plus PEM contents from diagnostics and the retained log.
- Reject candidate failure and absent/empty `uki.efi`; scan the work directory for caller-owned credentials before and after candidate execution.
- Preserve exact direct-ukify options, phases, `rw composefs=?<digest>`, two-pass digest sequence, candidate bootc authority, final byte comparisons, secure labels, sudo forwarding, cleanup, and fail-before-push ordering.
- Update `CLAUDE.md`, `README.md`, `yeti/build-pipeline.md`, and `docs/bootc-secure-assembly-compatibility.md`.
- Execute this plan on the existing `fix/bootc-candidate-ukify` branch based on `origin/main`.

---

### Task 1: Hand Off The Exact First-Pass Candidate

**Files:**
- Modify: `test/bootc-secure-package-cleanup-test.sh:60-139`
- Modify: `shared/outformat/image/buildah-package.sh:112-122`

**Interfaces:**
- Consumes: `first_image`, the packager-owned local image reference `localhost/snosi-bootc-secure-first-$$`.
- Produces: `SNOSI_BOOTC_SECURE_UKIFY_IMAGE=<first_image>` on the actual assembler invocation only.

- [ ] **Step 1: Add the failing handoff assertion**

In the controlled assembler's normal assembly branch in
`test/bootc-secure-package-cleanup-test.sh`, record the environment value before
touching `assembler-invoked`:

```bash
printf '%s\n' "${SNOSI_BOOTC_SECURE_UKIFY_IMAGE:-}" \
    >"$BUILD_FIXTURE_STATE/ukify-image"
```

Add to `assert_cleanup()`:

```bash
    [[ -f "$state/ukify-image" ]] || fail "assembler did not receive a ukify image"
    ukify_image=$(<"$state/ukify-image")
    [[ $ukify_image == localhost/snosi-bootc-secure-first-[0-9]* ]] ||
        fail "assembler did not receive the exact first-pass ukify image"
    [[ -f "$state/podman-first-args" ]] && grep -Fxq -- "$ukify_image" "$state/podman-first-args" ||
        fail "assembler ukify image differs from the first digest candidate"
```

Add `ukify_image` to `assert_cleanup()`'s local declaration.

Extend the controlled Podman fixture so its first invocation writes every
argument, one per line, to `$BUILD_FIXTURE_STATE/podman-first-args`. This makes
the digest invocation, not a separately reconstructed PID, authoritative.

- [ ] **Step 2: Run the package fixture and confirm RED**

Run:

```bash
test/bootc-secure-package-cleanup-test.sh
```

Expected: FAIL with `assembler did not receive the exact first-pass ukify image`.

- [ ] **Step 3: Pass the first image to the assembler**

In `shared/outformat/image/buildah-package.sh`, extend only the real assembly
invocation after first-pass digest computation:

```bash
    SNOSI_BOOTC_SECURE_COMPOSEFS_DIGEST="$digest" SNOSI_BOOTC_SECURE_BOOTC_VERSION=1.16.3 \
        SNOSI_BOOTC_SECURE_UKIFY_IMAGE="$first_image" \
        SNOSI_BOOTC_PREVIOUS_PCR_KEY="${SNOSI_BOOTC_PREVIOUS_PCR_KEY:-}" \
        "$ASSEMBLER" "$ROOTFS_DIR" \
        "$SNOSI_BOOTC_MOK_KEY" "$SNOSI_BOOTC_MOK_CERT" "$SNOSI_BOOTC_PCR_KEY" "$SNOSI_BOOTC_PCR_CERT" \
        "${SNOSI_BOOTC_PREVIOUS_PCR_CERT:-}"
```

Do not export the value globally and do not pass it to recursive insecure
packaging, scans, or cleanup calls.

- [ ] **Step 4: Run focused verification**

Run:

```bash
test/bootc-secure-package-cleanup-test.sh
shellcheck shared/outformat/image/buildah-package.sh \
  test/bootc-secure-package-cleanup-test.sh
git diff --check
```

Expected: cleanup fixtures pass; ShellCheck and diff check are silent.

- [ ] **Step 5: Commit Task 1**

Run:

```bash
git add shared/outformat/image/buildah-package.sh test/bootc-secure-package-cleanup-test.sh
git commit -m "fix: hand candidate image to bootc assembler"
```

### Task 2: Run Direct Ukify Inside The Candidate

**Files:**
- Modify: `shared/bootc-secure/assemble-uki.sh:8-283,293-319,450-465`
- Modify: `CLAUDE.md:66-89`
- Modify: `README.md:439-456`
- Modify: `yeti/build-pipeline.md:55-79`
- Modify: `docs/bootc-secure-assembly-compatibility.md:1-50`

**Interfaces:**
- Consumes: `SNOSI_BOOTC_SECURE_UKIFY_IMAGE`, directory rootfs paths, caller-owned key paths, assembler work directory, and unchanged ukify option values.
- Produces: `run_candidate_ukify IMAGE WORK LOG MOK_KEY MOK_CERT PCR_KEY PREVIOUS_KEY -- UKIFY_ARGS...`, returning 0 only when Podman exits 0 and a nonempty host-side `WORK/uki.efi` exists.

- [ ] **Step 1: Add candidate path constants and helper fixture**

Add after `EXPECTED_BOOTC_VERSION` in `shared/bootc-secure/assemble-uki.sh`:

```bash
readonly CANDIDATE_UKIFY_MOK_KEY=/run/snosi-ukify-mok.key
readonly CANDIDATE_UKIFY_MOK_CERT=/run/snosi-ukify-mok.crt
readonly CANDIDATE_UKIFY_PCR_KEY=/run/snosi-ukify-pcr.key
readonly CANDIDATE_UKIFY_PREVIOUS_KEY=/run/snosi-ukify-previous-pcr.key
readonly CANDIDATE_UKIFY_WORK=/run/snosi-ukify-work
```

Add `candidate_ukify_self_test()` before `self_test()`. It must create a
temporary `root`, separate per-case work directories, and a `bin/podman`
fixture that records one argument per line in
`$CANDIDATE_UKIFY_TEST_ARGS`, locates the host source of the
`:$CANDIDATE_UKIFY_WORK:rw` volume, and then:

Create `root` and every case work directory as siblings under the top-level
temporary directory so `$work/outside` is structurally outside `$root` in the
path-refusal assertion.

```bash
if [[ ${CANDIDATE_UKIFY_TEST_FAIL:-0} == 1 ]]; then
    echo "candidate ukify failed at $CANDIDATE_UKIFY_PCR_KEY" >&2
    exit 86
fi
if [[ ${CANDIDATE_UKIFY_TEST_NO_OUTPUT:-0} != 1 ]]; then
    if [[ ${CANDIDATE_UKIFY_TEST_EMPTY_OUTPUT:-0} == 1 ]]; then
        : >"$host_work/uki.efi"
    else
        printf 'fixture uki\n' >"$host_work/uki.efi"
    fi
fi
printf 'safe diagnostic; key path %s\n' "$CANDIDATE_UKIFY_PCR_KEY" >&2
cat "$CANDIDATE_UKIFY_TEST_PRIVATE_KEY" >&2
```

The fixture parser must reject any invocation without these exact control
arguments before the image name:

```text
run
--rm
--network=none
--security-opt
label=type:unconfined_t
--entrypoint=/usr/bin/ukify
```

- [ ] **Step 2: Add single-key assertions and confirm RED**

Have `candidate_ukify_self_test()` generate disposable MOK/PCR keys and a MOK
certificate, create `work/pcr.pub`, then invoke the not-yet-implemented helper
with image `localhost/snosi-bootc-secure-first-fixture`, a log path, no previous
key, and this ukify argv:

```bash
build
--linux /usr/lib/modules/one/vmlinuz
--initrd /usr/lib/modules/one/initramfs.img
--os-release @/usr/lib/os-release
--cmdline 'rw composefs=?fixture'
--pcr-private-key "$CANDIDATE_UKIFY_PCR_KEY"
--secureboot-private-key "$CANDIDATE_UKIFY_MOK_KEY"
--secureboot-certificate "$CANDIDATE_UKIFY_MOK_CERT"
--pcrpkey "$CANDIDATE_UKIFY_WORK/pcr.pub"
--output "$CANDIDATE_UKIFY_WORK/uki.efi"
```

Assert the recorded Podman argv contains:

```text
localhost/snosi-bootc-secure-first-fixture
<mok-host-path>:/run/snosi-ukify-mok.key:ro
<mok-cert-host-path>:/run/snosi-ukify-mok.crt:ro
<pcr-host-path>:/run/snosi-ukify-pcr.key:ro
<work-host-path>:/run/snosi-ukify-work:rw
```

Assert it contains no `snosi-ukify-previous-pcr.key`, no host rootfs path in
arguments after the image, and no second `:rw` volume. Assert `work/uki.efi` is
nonempty. Assert the retained log contains `safe diagnostic` but contains
neither the host/fixed private-key paths nor `BEGIN PRIVATE KEY`.

Call `candidate_ukify_self_test` immediately before `self_test()`'s existing
`return "$rc"` line.

Run:

```bash
test/bootc-secure-artifact-test.sh --fixtures
```

Expected: FAIL because `run_candidate_ukify` is undefined.

- [ ] **Step 3: Add dual-key and failure assertions**

Within `candidate_ukify_self_test()`, run a second success case with a generated
previous PCR key. Require exactly this additional read-only mount and argument:

```text
<previous-host-path>:/run/snosi-ukify-previous-pcr.key:ro
--pcr-private-key
/run/snosi-ukify-previous-pcr.key
```

Add three fail-closed cases around the helper with `set +e`/status capture:

```text
CANDIDATE_UKIFY_TEST_FAIL=1          -> status 86, sanitized safe diagnostic retained
CANDIDATE_UKIFY_TEST_NO_OUTPUT=1     -> nonzero, "candidate ukify produced no UKI"
CANDIDATE_UKIFY_TEST_EMPTY_OUTPUT=1  -> nonzero, "candidate ukify produced no UKI"
```

Use a fresh work directory for every helper invocation, or remove `uki.efi`
before each case. No-output and empty-output cases must never observe a prior
success artifact. For the status-86 case, require the log to contain
`candidate ukify failed at [redacted credential path]`; it must not require the
later success-only `safe diagnostic` line and must contain neither the fixed
PCR path nor PEM content.

Run:

```bash
test/bootc-secure-artifact-test.sh --fixtures
```

Expected: FAIL until the helper implements status propagation, redaction, and
nonempty output enforcement.

- [ ] **Step 4: Implement candidate execution helper**

Add before `assemble()`:

```bash
run_candidate_ukify() { # image work log mok-key mok-cert pcr-key previous-key -- ukify-args...
    local image=$1 work=$2 log=$3 mok_key=$4 mok_cert=$5 pcr_key=$6 previous_key=$7 status
    local -a podman_args
    shift 7
    [[ ${1:-} == -- ]] || die "candidate ukify argument separator is missing"
    shift

    podman_args=(run --rm --network=none
        --security-opt label=type:unconfined_t
        --entrypoint=/usr/bin/ukify
        --volume "$mok_key:$CANDIDATE_UKIFY_MOK_KEY:ro"
        --volume "$mok_cert:$CANDIDATE_UKIFY_MOK_CERT:ro"
        --volume "$pcr_key:$CANDIDATE_UKIFY_PCR_KEY:ro"
        --volume "$work:$CANDIDATE_UKIFY_WORK:rw")
    [[ -z $previous_key ]] || podman_args+=(
        --volume "$previous_key:$CANDIDATE_UKIFY_PREVIOUS_KEY:ro")

    podman "${podman_args[@]}" "$image" "$@" 2>&1 |
        redact_credentials "$mok_key" "$pcr_key" "$previous_key" \
            "$CANDIDATE_UKIFY_MOK_KEY" "$CANDIDATE_UKIFY_PCR_KEY" \
            "$CANDIDATE_UKIFY_PREVIOUS_KEY" |
        tee "$log" >&2
    status=${PIPESTATUS[0]}
    [[ $status -eq 0 ]] || return "$status"
    [[ -s $work/uki.efi ]] || {
        echo "Error: candidate ukify produced no UKI" >&2
        return 1
    }
}
```

Do not add `--privileged`, `--pid=host`, `:z`, or `:Z`.

- [ ] **Step 5: Translate rootfs paths and replace host ukify**

Add before `assemble()`:

```bash
rootfs_image_path() { # rootfs host-path
    local root=${1%/} path=$2 relative
    [[ $path == "$root/"* ]] || die "path is outside rootfs: $path"
    relative=${path#"$root/"}
    while [[ $relative == /* ]]; do relative=${relative#/}; done
    printf '/%s\n' "$relative"
}
```

Add direct self-test assertions before the Podman cases:

```bash
    [[ $(rootfs_image_path "$root/" "$root//usr/lib/modules/one/vmlinuz") == \
        /usr/lib/modules/one/vmlinuz ]] || die "rootfs path translation failed"
    if (rootfs_image_path "$root" "$work/outside") >/dev/null 2>&1; then
        die "outside-rootfs path accepted"
    fi
```

In `assemble()`, immediately after `discover_kernel` populates `$kernel` and
`$initrd`, require and resolve the candidate image and translated paths:

```bash
    local ukify_image image_kernel image_initrd
    ukify_image=${SNOSI_BOOTC_SECURE_UKIFY_IMAGE:-}
    [[ -n $ukify_image ]] || die "missing first-pass candidate image for ukify"
    image_kernel=$(rootfs_image_path "$root" "$kernel")
    image_initrd=$(rootfs_image_path "$root" "$initrd")
```

Build `ukify_args` with only candidate paths:

```bash
    ukify_args=(build --linux "$image_kernel" --initrd "$image_initrd"
        --os-release @/usr/lib/os-release --cmdline "rw composefs=?$digest"
        --uname "$version" --pcr-private-key "$CANDIDATE_UKIFY_PCR_KEY"
        --secureboot-private-key "$CANDIDATE_UKIFY_MOK_KEY"
        --secureboot-certificate "$CANDIDATE_UKIFY_MOK_CERT"
        --measure --output "$CANDIDATE_UKIFY_WORK/uki.efi")
```

Replace the existing single/dual-key argument conditional with:

```bash
    if [[ -n "$previous_key" ]]; then
        ukify_args+=(--pcr-private-key "$CANDIDATE_UKIFY_PREVIOUS_KEY"
            --pcrpkey "$CANDIDATE_UKIFY_WORK/pcr.pub"
            --phases "enter-initrd,enter-initrd:leave-initrd,enter-initrd:leave-initrd:sysinit,enter-initrd:leave-initrd:sysinit:ready"
            --phases "enter-initrd,enter-initrd:leave-initrd,enter-initrd:leave-initrd:sysinit,enter-initrd:leave-initrd:sysinit:ready")
    else
        ukify_args+=(--pcrpkey "$CANDIDATE_UKIFY_WORK/pcr.pub")
    fi
```

Immediately before candidate execution, require the work directory contains no
caller-owned private credential:

```bash
    credential_gate_scan_tree "$gate" "ukify work directory before candidate execution" "$work"
```

Replace the host `ukify ... | redact ... | tee ...` pipeline with:

```bash
    set +e
    run_candidate_ukify "$ukify_image" "$work" "$work/ukify.log" \
        "$mok_key" "$mok_cert" "$pcr_key" "$previous_key" -- \
        "${ukify_args[@]}"
    ukify_status=$?
    set -e
    [[ $ukify_status -eq 0 ]] || die "ukify failed"
    credential_gate_scan_tree "$gate" "ukify work directory after candidate execution" "$work"
```

Retain the sanitized-log scan, host installation of `work/uki.efi`, UKI
validation, and final rootfs credential scan.

- [ ] **Step 6: Run assembler fixtures and confirm GREEN**

Run:

```bash
test/bootc-secure-artifact-test.sh --fixtures
test/bootc-secure-artifact-negative-test.sh --fixtures
```

Expected: positive and negative artifact fixtures pass.

- [ ] **Step 7: Document the candidate-image boundary**

Update the Task 5 paragraph in `CLAUDE.md` to state:

```markdown
Direct ukify executes as `/usr/bin/ukify` inside the pristine first-pass
candidate with network disabled, individual read-only credential mounts, and a
public-only writable work mount. The candidate supplies pinned systemd-ukify
261.1-3 and its dependencies; no host ukify is accepted. The disposable
container and mounts never enter a layer. Host `.linux`/`.initrd` byte checks
remain valid because first-pass packaging is a byte-identical `cp -a` snapshot.
```

Add equivalent concise user-facing text to `README.md`. In
`yeti/build-pipeline.md`, record the fixed mount paths, path translation,
entrypoint/network/label options, and the public-only work scans. In
`docs/bootc-secure-assembly-compatibility.md`, record:

```markdown
- Forky systemd-ukify 261.1-3 ships executable `/usr/bin/ukify` (package
  SHA-256 `817b8ea0a8953f9fb4b42d91f04ed1511bbb1e76cee466497dfb955cb246aa34`).
- Direct ukify runs inside the first-pass candidate; candidate bootc remains
  storage-digest authority.
- Final host byte comparisons depend on first-pass `cp -a` identity.
```

- [ ] **Step 8: Run complete focused verification**

Run:

```bash
test/bootc-secure-artifact-test.sh --fixtures
test/bootc-secure-artifact-negative-test.sh --fixtures
test/bootc-secure-package-cleanup-test.sh
test/bootc-publication-guard-test.sh
./check-bootc-publication-guard.sh
shellcheck shared/bootc-secure/assemble-uki.sh \
  shared/outformat/image/buildah-package.sh \
  test/bootc-secure-package-cleanup-test.sh
git diff --check
```

Expected: all commands exit 0; publication guard reports 29 passing assertions;
ShellCheck and diff check are silent.

- [ ] **Step 9: Review and commit Task 2**

Run:

```bash
git diff -- shared/bootc-secure/assemble-uki.sh CLAUDE.md README.md yeti/build-pipeline.md docs/bootc-secure-assembly-compatibility.md
git status --short
git add shared/bootc-secure/assemble-uki.sh CLAUDE.md README.md yeti/build-pipeline.md docs/bootc-secure-assembly-compatibility.md
git commit -m "fix: run ukify inside bootc candidate image"
```

### Task 3: Merge And Re-run Protected Publication

**Files:**
- No repository file changes.

**Interfaces:**
- Consumes: Reviewed candidate-image ukify implementation and protected credentials.
- Produces: Three signed immutable OCI candidates promoted only after local and policy-copied artifact validation.

- [ ] **Step 1: Push and create the PR**

Run:

```bash
test "$(git branch --show-current)" = fix/bootc-candidate-ukify
git push -u origin fix/bootc-candidate-ukify
gh pr create --repo frostyard/snosi --base main --head fix/bootc-candidate-ukify \
  --title "fix: run ukify inside bootc candidate image" \
  --body $'## Summary\n- run pinned direct ukify inside the first-pass candidate image\n- expose credentials only as ephemeral read-only mounts\n- guard single/dual-key command shape, output, redaction, and cleanup\n\n## Failure evidence\nProtected run 30568330831 completed first-pass packaging and digest computation for all profiles, then failed because the Ubuntu host had no ukify; no registry write ran.\n\n## Validation\n- secure artifact positive and negative fixtures\n- secure package cleanup fixture\n- publication guard fixture and real-tree guard\n- ShellCheck'
```

- [ ] **Step 2: Wait for checks and inspect the PR**

Run:

```bash
PR_NUMBER=$(gh pr view --repo frostyard/snosi --json number --jq .number)
gh pr checks "$PR_NUMBER" --repo frostyard/snosi --watch
gh pr diff "$PR_NUMBER" --repo frostyard/snosi
gh pr view "$PR_NUMBER" --repo frostyard/snosi \
  --json url,state,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup
```

If branch protection requires independent approval, stop without `--admin` and
resume after the user merges or supplies approval.

- [ ] **Step 3: Merge normally and identify the exact automatic run**

Run:

```bash
gh pr merge "$PR_NUMBER" --repo frostyard/snosi --squash --delete-branch
MERGE_SHA=
for _ in $(seq 1 30); do
  MERGE_SHA=$(gh pr view "$PR_NUMBER" --repo frostyard/snosi \
    --json mergeCommit --jq '.mergeCommit.oid // empty')
  [[ -n $MERGE_SHA ]] && break
  sleep 2
done
[[ -n $MERGE_SHA ]]
RUN_JSON=
for _ in $(seq 1 30); do
  RUN_JSON=$(gh run list --repo frostyard/snosi --workflow build-images.yml --branch main \
    --limit 10 --json databaseId,headSha,url,status,conclusion | \
    jq -c --arg sha "$MERGE_SHA" 'map(select(.headSha == $sha)) | first // empty')
  [[ -n $RUN_JSON ]] && break
  sleep 2
done
[ -n "$RUN_JSON" ]
RUN_ID=$(jq -r .databaseId <<<"$RUN_JSON")
RUN_URL=$(jq -r .url <<<"$RUN_JSON")
printf 'Run %s: %s\n' "$RUN_ID" "$RUN_URL"
gh run watch "$RUN_ID" --repo frostyard/snosi --exit-status --interval 20
```

- [ ] **Step 4: Record immutable evidence and ordering**

Run:

```bash
gh run view "$RUN_ID" --repo frostyard/snosi --json url,headSha,status,conclusion,jobs
```

Expected for Cayo, Snow, and Snowfield: package, local artifact validation,
immutable push, signing, remote verification, policy-copied validation, and
latest promotion all succeed in order. Record each 14-digit version and digest.
Treat the result as one candidate set, not distinct `N`/`N+1`/`N+2`, Task 9,
rotation, or Snowfield hardware evidence.
