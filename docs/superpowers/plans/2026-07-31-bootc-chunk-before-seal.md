# Bootc Chunk-Before-Seal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish chunkah-optimized secure bootc images whose final bootc storage digest exactly matches the digest sealed into the UKI.

**Architecture:** Refactor the pinned chunkah command into a sourceable `chunk_image` function. In secure mode, `buildah-package.sh` packages and chunks the pristine candidate first, computes the authoritative digest from that chunked image, assembles the UKI, and derives the final image from the chunked candidate with only `/boot` copied into a final layer. The final image's own bootc must return the same digest before the image can survive cleanup or reach publication.

**Tech Stack:** Bash, Buildah, Podman, chunkah, bootc 1.16.3, ukify 261.1-3, GitHub Actions, ShellCheck, actionlint.

## Global Constraints

- Preserve `quay.io/coreos/chunkah@sha256:fdff3175bfb41e111089392ef8a41b46a10766c7b2ec454ba1272a0c39ce3bf3`.
- Preserve `chunkah build --prune /sysroot/ --max-layers "$MAX_LAYERS"` and the default `MAX_LAYERS=128`.
- Secure mode requires `SOURCE_DATE_EPOCH`, derived from `git log -1 --format=%ct` and explicitly forwarded through sudo.
- Candidate bootc 1.16.3 remains the sole storage-digest authority.
- The only post-digest filesystem mutation is a final overlay copied from `$ROOTFS_DIR/boot/` to the derived candidate's `/boot/`.
- The final image inherits the chunked candidate layers; it is never repackaged from scratch and never passed through chunkah a second time.
- Private MOK/PCR credentials must not enter chunkah mounts, environment, image layers, labels, logs, or retained state.
- Preserve existing candidate-ukify confinement, byte comparisons, credential scans, secure labels, and failure cleanup.
- Do not modify or revert unrelated worktree changes.
- Do not create git commits unless the user explicitly requests them.

---

### Task 1: Chunked Secure Packaging

**Files:**
- Modify: `shared/outformat/image/chunkah-package.sh:1-40`
- Test: `test/bootc-secure-package-cleanup-test.sh`

**Interfaces:**
- Produces: `chunk_image IMAGE_REF SOURCE_DATE_EPOCH [MAX_LAYERS]`, which replaces the named local image with chunkah's loaded output and returns nonzero on malformed load output.
- Preserves: direct CLI `chunkah-package.sh IMAGE_REF SOURCE_DATE_EPOCH` with `MAX_LAYERS` read from the environment and defaulting to 128.

- [ ] **Step 1: Add failing fixture assertions for the reusable chunker**

Extend the package fixture's fake Podman to distinguish `inspect`, the pinned chunkah `run`, `load`, and bootc digest probes. Record chunk arguments in `$BUILD_FIXTURE_STATE/chunk-args`, and assert:

```bash
grep -Fxq -- '--prune' "$state/chunk-args" || fail "chunkah lost --prune"
grep -Fxq -- '/sysroot/' "$state/chunk-args" || fail "chunkah lost /sysroot/"
grep -Fxq -- '--max-layers' "$state/chunk-args" || fail "chunkah lost --max-layers"
grep -Fxq -- '128' "$state/chunk-args" || fail "chunkah lost the default layer limit"
[[ $(<"$state/chunk-source-epoch") == 1722384000 ]] || fail "chunkah received the wrong source epoch"
```

Invoke every secure fixture with `SOURCE_DATE_EPOCH=1722384000`. Add a missing-epoch case that expects `SOURCE_DATE_EPOCH is required for secure chunking` and proves chunkah, assembler, and final commit were not reached.

- [ ] **Step 2: Run the fixture and verify the new expectations fail**

Run:

```bash
./test/bootc-secure-package-cleanup-test.sh
```

Expected: nonzero, with at least one failure showing that secure packaging never invoked chunkah or accepted the source epoch.

- [ ] **Step 3: Refactor the chunker without changing its CLI**

Replace top-level execution in `chunkah-package.sh` with:

```bash
CHUNKAH_IMAGE='quay.io/coreos/chunkah@sha256:fdff3175bfb41e111089392ef8a41b46a10766c7b2ec454ba1272a0c39ce3bf3'

chunk_image() { # image-ref source-date-epoch [max-layers]
    local image_ref=$1 source_date_epoch=$2 max_layers=${3:-128}
    local config loaded new_ref
    [[ $source_date_epoch =~ ^[0-9]+$ ]] || {
        echo "Error: SOURCE_DATE_EPOCH must be a non-negative integer" >&2
        return 1
    }
    [[ $max_layers =~ ^[1-9][0-9]*$ ]] || {
        echo "Error: MAX_LAYERS must be a positive integer" >&2
        return 1
    }

    config=$(podman inspect "$image_ref")
    loaded=$(podman run --rm \
        --security-opt label=type:unconfined_t \
        --mount=type=image,src="$image_ref",dst=/chunkah \
        -e "CHUNKAH_CONFIG_STR=$config" \
        -e "SOURCE_DATE_EPOCH=$source_date_epoch" \
        "$CHUNKAH_IMAGE" \
        build --prune /sysroot/ --max-layers "$max_layers" \
        --label ostree.commit- --label ostree.final-diffid- | podman load)
    printf '%s\n' "$loaded"
    new_ref=$(grep -oP '(?<=Loaded image: ).*' <<<"$loaded" ||
        grep -oP '(?<=Loaded image\(s\): ).*' <<<"$loaded" || true)
    [[ -n $new_ref ]] || {
        echo "ERROR: could not parse loaded image ref from podman output above" >&2
        return 1
    }
    [[ $new_ref == "$image_ref" ]] || podman tag "$new_ref" "$image_ref"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    [[ $# -eq 2 ]] || {
        echo "Usage: $0 IMAGE_REF SOURCE_DATE_EPOCH" >&2
        exit 1
    }
    chunk_image "$1" "$2" "${MAX_LAYERS:-128}"
fi
```

- [ ] **Step 4: Verify direct and sourced behavior**

Run:

```bash
bash -n shared/outformat/image/chunkah-package.sh
shellcheck shared/outformat/image/chunkah-package.sh
./test/bootc-secure-package-cleanup-test.sh
```

Expected: syntax and ShellCheck pass before continuing to Part B; the package
fixture remains red until Part B completes the same atomic task.

---

#### Part B: Chunk Before Digest Sealing

**Files:**
- Modify: `shared/outformat/image/buildah-package.sh:68-177`
- Test: `test/bootc-secure-package-cleanup-test.sh`

**Interfaces:**
- Consumes: `chunk_image IMAGE_REF SOURCE_DATE_EPOCH [MAX_LAYERS]` from Part A.
- Produces: a secure `$IMAGE_REF` derived from the chunked first candidate, with one final `/boot` filesystem overlay and trusted secure labels.

- [ ] **Step 1: Add failing ordering and digest-equality fixtures**

Update the fake Buildah implementation to log every invocation and make `from IMAGE` distinguish scratch packaging from final derivation. Add assertions equivalent to:

```bash
first=$(<"$state/chunk-image")
grep -Fxq "from $first" "$state/buildah-commands" ||
    fail "final image was not derived from the chunked candidate"
grep -Fxq -- "-a $root/boot/. " "$state/cp-final-prefix" ||
    fail "final image did not copy only the rootfs boot tree"
[[ $(<"$state/digest-probe-count") == 2 ]] ||
    fail "secure packaging did not perform exactly two digest probes"
[[ $(<"$state/first-digest-image") == "$first" ]] ||
    fail "chunked candidate was not digest authority"
[[ $(<"$state/final-digest-image") == "$published" ]] ||
    fail "published image was not the final digest authority"
```

Change the mismatch fixture so the second digest probe returns a different 128-hex digest. Keep the success rerun to prove cleanup does not wedge another secure package.

- [ ] **Step 2: Run the focused fixture and verify it fails**

Run:

```bash
./test/bootc-secure-package-cleanup-test.sh
```

Expected: nonzero because the current packager computes its first digest before chunking and builds the final image from scratch.

- [ ] **Step 3: Implement chunk-before-seal secure packaging**

In secure mode, source the helper and require the epoch before mutating the rootfs:

```bash
CHUNKER="$(dirname "${BASH_SOURCE[0]}")/chunkah-package.sh"
[[ -r $CHUNKER ]] || { echo "Error: chunkah packager is unavailable" >&2; exit 1; }
# shellcheck source=shared/outformat/image/chunkah-package.sh
source "$CHUNKER"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH is required for secure chunking}"
```

After preparing the immutable systemd-boot source, recursively package the pristine candidate with caller labels, then chunk it before the first digest probe:

```bash
first_image="localhost/snosi-bootc-secure-first-$$"
SNOSI_BOOTC_SECURE=0 "$0" "$ROOTFS_DIR" "$first_image" "$@"
chunk_image "$first_image" "$SOURCE_DATE_EPOCH" "${MAX_LAYERS:-128}"
digest=$(podman run --rm --privileged --pid=host \
    -v /var/lib/containers:/var/lib/containers \
    --security-opt label=type:unconfined_t "$first_image" \
    bootc container compute-composefs-digest-from-storage "$first_image" | tr -d '\n')
```

After assembly, replace the scratch second/final packaging passes with a container derived from the chunked candidate:

```bash
container=$(buildah from "$first_image")
mountpoint=$(buildah mount "$container")
mkdir -p "$mountpoint/boot"
cp -a "$ROOTFS_DIR/boot/". "$mountpoint/boot/"
buildah umount "$container"
buildah config --label "io.snosi.bootc.secureboot-capable=true" "$container"
buildah config --label \
    "io.snosi.bootc.secureboot-assembly=bootc-1.16.3-storage-digest-v1" "$container"
buildah commit "$container" "$IMAGE_REF"
buildah rm "$container"
final_image_committed=1
```

Probe `$IMAGE_REF` exactly once, reject inequality with `Error: /boot overlay changed OCI composefs digest`, scan the final image, set `secure_complete=1`, print completion, and exit before the non-secure scratch packager. Remove `final_probe` and its cleanup branch.

- [ ] **Step 4: Verify digest equality and cleanup behavior**

Run:

```bash
./test/bootc-secure-package-cleanup-test.sh
./test/bootc-secure-artifact-test.sh --fixtures
./test/bootc-secure-artifact-negative-test.sh --fixtures
```

Expected: all three pass. The cleanup fixture proves equal digests succeed and a changed final digest removes the incomplete final image and injected boot artifacts.

---

### Task 2: Protected Workflow Ordering Guard

**Files:**
- Modify: `.github/workflows/build-images.yml:160-212`
- Modify: `check-bootc-publication-guard.sh:105-137`
- Modify: `test/bootc-publication-guard-test.sh:75-244`

**Interfaces:**
- Consumes: secure packager requirement `SOURCE_DATE_EPOCH=<commit epoch>`.
- Produces: a protected build with no post-package chunk step and a static guard rejecting either missing epoch forwarding or reintroduced post-assembly chunking.

- [ ] **Step 1: Add failing publication-guard mutations**

Add `SOURCE_DATE_EPOCH` and `MAX_LAYERS` to the fixture package environment and sudo forwarding. Keep a fixture `Chunk image` step initially, then add mutations/assertions:

```bash
remove_source_epoch_forwarding() {
    perl -0pi -e 's/^            SOURCE_DATE_EPOCH="\$SOURCE_DATE_EPOCH" \\\n//m' \
        "$1/.github/workflows/build-images.yml"
}
add_post_package_chunk() {
    perl -0pi -e 's/(      - name: Validate locally assembled secure artifact)/      - name: Chunk image\n        run: .\/shared\/outformat\/image\/chunkah-package.sh image epoch\n$1/' \
        "$1/.github/workflows/build-images.yml"
}

assert_guard 'missing sudo SOURCE_DATE_EPOCH forwarding fails' 1 remove_source_epoch_forwarding
assert_guard 'post-package secure chunking fails' 1 add_post_package_chunk
```

- [ ] **Step 2: Run the guard fixture and verify the new mutations fail to be detected**

Run:

```bash
./test/bootc-publication-guard-test.sh
```

Expected: nonzero because the guard does not yet require source-epoch forwarding or prohibit a secure-build `Chunk image` step.

- [ ] **Step 3: Move epoch derivation into protected packaging**

In `Package image`, set:

```yaml
          MAX_LAYERS: 128
```

Then derive and forward the epoch in the run block:

```bash
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
sudo TMPDIR="$TMPDIR" \
  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  MAX_LAYERS="$MAX_LAYERS" \
```

Delete the protected secure-build `Chunk image` step entirely. Do not alter mechanics-build chunking.

- [ ] **Step 4: Enforce the workflow invariant statically**

Extend `check-bootc-publication-guard.sh` to require the exact epoch derivation and sudo forwarding in `package_step`, require `MAX_LAYERS`, and fail if `secure_job` contains `- name: Chunk image`.

- [ ] **Step 5: Verify workflow and guard behavior**

Run:

```bash
./check-bootc-publication-guard.sh
./test/bootc-publication-guard-test.sh
actionlint .github/workflows/build-images.yml
```

Expected: all pass, with the guard fixture count increased by two assertions.

---

### Task 3: Documentation and Full Verification

**Files:**
- Modify: `docs/bootc-secure-assembly-compatibility.md:7-50`
- Modify: `yeti/build-pipeline.md:57-73,395-409`
- Modify: `CLAUDE.md:68-110,1549`
- Modify: `README.md:28-36`
- Verify: `docs/superpowers/specs/2026-07-31-bootc-chunk-before-seal-design.md`

**Interfaces:**
- Documents: chunked candidate authority, final `/boot` overlay, exact two digest probes, and absence of post-assembly chunking.

- [ ] **Step 1: Update maintained contracts**

State consistently that protected secure packaging chunks the pristine candidate before calculating the storage digest; the final image inherits those layers and adds only `/boot`; the final candidate's bootc must return the same digest; and changing chunkah, Buildah derivation, or `/boot` exclusion requires full compatibility revalidation.

- [ ] **Step 2: Run static and fixture verification**

Run:

```bash
bash -n shared/outformat/image/buildah-package.sh shared/outformat/image/chunkah-package.sh \
  test/bootc-secure-package-cleanup-test.sh check-bootc-publication-guard.sh \
  test/bootc-publication-guard-test.sh
shellcheck shared/outformat/image/buildah-package.sh shared/outformat/image/chunkah-package.sh \
  test/bootc-secure-package-cleanup-test.sh check-bootc-publication-guard.sh \
  test/bootc-publication-guard-test.sh
./test/bootc-secure-package-cleanup-test.sh
./test/bootc-secure-artifact-test.sh --fixtures
./test/bootc-secure-artifact-negative-test.sh --fixtures
./check-bootc-publication-guard.sh
./test/bootc-publication-guard-test.sh
./test/bootc-secure-publication-test.sh
./test/bootc-secure-promotion-test.sh
actionlint .github/workflows/build-images.yml
git diff --check
```

Expected: every command exits 0. Record fixture assertion totals in the final report.

- [ ] **Step 3: Request adversarial review**

Ask a reviewer to check specifically for digest authority before chunking, any filesystem mutation outside `/boot`, a second chunk pass, missing credential cleanup, labels surviving failed validation, or workflow paths that bypass source-epoch forwarding. Resolve all correctness findings and rerun Step 2.
