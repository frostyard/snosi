# Snow Release SBOM Predecessor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Snow release creation select the newest prior released Snow image with a Syft SBOM, and skip safely when no eligible predecessor exists.

**Architecture:** Add a small shell resolver that scans GitHub release bodies in API order, validates each Snow marker against authenticated immutable ORAS metadata, and writes the existing release-step output contract. Move the Snow tag artifact after all metadata publication and replace the unsafe registry-tag fallback with the resolver. Static guards and command fixtures enforce both selection and ordering.

**Tech Stack:** Bash, GitHub CLI, ORAS, jq, GitHub Actions, ShellCheck, actionlint.

## Global Constraints

- GitHub release body markers `<!-- snow-tag: <14 digits> -->` are the sole predecessor lineage.
- Native A/B and unrelated releases without a Snow marker are ignored.
- A predecessor is eligible only when its immutable digest has a referrer with exact artifact type `application/vnd.syft+json`.
- Same-tag, newer-tag, missing-tag, failed-discovery, malformed-discovery, and missing-SBOM candidates are not eligible.
- If no eligible predecessor exists, write `skip=true`, warn, and exit zero.
- Never enumerate or select arbitrary numeric registry tags as a fallback.
- Emit the `snow-tag` artifact only after SBOM signing, provenance attestation, and manifest upload succeed.
- Preserve `previous=`, `current=`, and `skip=` step-output names consumed by the release job.
- Do not backfill or mutate failed historical image metadata.
- Do not claim live release success until a main-branch run creates or cleanly skips the release with this logic.
- Do not create git commits unless the user explicitly requests them.

---

### Task 1: SBOM-Complete Release Predecessor Resolver

**Files:**
- Create: `shared/bootc-secure/ci/resolve-snow-release-predecessor.sh`
- Create: `test/bootc-release-predecessor-test.sh`
- Modify: `.github/workflows/validate.yml`
- Modify: `.github/workflows/test-bootc-secure.yml`
- Modify: `.github/workflows/bootc-secure-nightly.yml`

**Interfaces:**
- CLI: `resolve-snow-release-predecessor.sh REPOSITORY IMAGE CURRENT_TAG OUTPUT_FILE`
- Consumes: authenticated `gh`, authenticated `oras`, and `jq` on `PATH`.
- Produces on success with predecessor: exactly one `previous=<tag>` and one `current=<tag>` line in `OUTPUT_FILE`.
- Produces with no predecessor: exactly one `skip=true` line in `OUTPUT_FILE` and exits zero.

- [ ] **Step 1: Write the failing resolver fixture**

Create PATH doubles for `gh` and `oras`. The `gh api --paginate` double emits a fixture containing newer Native A/B bodies followed by Snow markers. The ORAS double supports:

```text
oras resolve IMAGE:TAG
oras discover --format json IMAGE@DIGEST
```

Cover these cases independently:

```bash
run_success newest-released-complete
run_success skip-incomplete-newer-marker
run_success skip-missing-tag
run_success skip-discovery-failure
run_success skip-malformed-discovery
run_success reject-same-and-newer
run_success no-eligible-marker
run_failure github-pagination-failure
```

Assert that every successful selection writes exactly:

```text
previous=20260727175908
current=20260731114513
```

Assert that no-eligible writes exactly `skip=true`, and assert the command log contains no `oras repo tags` invocation.

- [ ] **Step 2: Run the fixture and verify it fails before implementation**

Run:

```bash
./test/bootc-release-predecessor-test.sh
```

Expected: nonzero because `shared/bootc-secure/ci/resolve-snow-release-predecessor.sh` does not exist.

- [ ] **Step 3: Implement the resolver**

Use this validation and output shape:

```bash
#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

REPOSITORY=${1:?Usage: $0 REPOSITORY IMAGE CURRENT_TAG OUTPUT_FILE}
IMAGE=${2:?Usage: $0 REPOSITORY IMAGE CURRENT_TAG OUTPUT_FILE}
CURRENT=${3:?Usage: $0 REPOSITORY IMAGE CURRENT_TAG OUTPUT_FILE}
OUTPUT=${4:?Usage: $0 REPOSITORY IMAGE CURRENT_TAG OUTPUT_FILE}

[[ $REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo "Error: invalid repository: $REPOSITORY" >&2; exit 1;
}
[[ $IMAGE =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo "Error: invalid image: $IMAGE" >&2; exit 1;
}
[[ $CURRENT =~ ^[0-9]{14}$ ]] || {
    echo "Error: invalid current Snow tag: $CURRENT" >&2; exit 1;
}
for command in gh oras jq; do
    command -v "$command" >/dev/null || { echo "Error: missing $command" >&2; exit 1; }
done
```

Capture the complete paginated API response before parsing so a failed `gh api` cannot be masked by a pipeline:

```bash
if ! release_bodies=$(gh api --paginate "/repos/$REPOSITORY/releases" --jq '.[].body // ""'); then
    echo "Error: failed to enumerate GitHub releases" >&2
    exit 1
fi
```

Extract markers in response order. For each prior candidate, resolve its digest and discover referrers. Continue with a warning on candidate-specific ORAS failures or invalid JSON. Accept only:

```bash
jq -e '[.referrers[]? | select(.artifactType == "application/vnd.syft+json")] | length > 0'
```

Write selected outputs with one `printf` call. If the loop ends without a selection, write `skip=true`, warn, and return zero.

- [ ] **Step 4: Wire the fixture into existing static CI suites**

Add `./test/bootc-release-predecessor-test.sh` beside the existing secure publication fixtures in `validate.yml`, `test-bootc-secure.yml`, and `bootc-secure-nightly.yml`.

- [ ] **Step 5: Verify Task 1**

Run:

```bash
bash -n shared/bootc-secure/ci/resolve-snow-release-predecessor.sh test/bootc-release-predecessor-test.sh
shellcheck shared/bootc-secure/ci/resolve-snow-release-predecessor.sh test/bootc-release-predecessor-test.sh
./test/bootc-release-predecessor-test.sh
actionlint .github/workflows/validate.yml .github/workflows/test-bootc-secure.yml .github/workflows/bootc-secure-nightly.yml
```

Expected: all commands exit zero and the fixture reports every case passing.

---

### Task 2: Late Release Authorization and Static Guard

**Files:**
- Modify: `.github/workflows/build-images.yml:308-389,514-595`
- Modify: `check-bootc-publication-guard.sh`
- Modify: `test/bootc-publication-guard-test.sh`

**Interfaces:**
- Consumes: Task 1 resolver CLI and existing release output names.
- Produces: a release job that runs the changelog only with an SBOM-complete released predecessor, or skips successfully.

- [ ] **Step 1: Add failing workflow-guard mutations**

Expand the fixture workflow with these secure metadata steps in order:

```yaml
      - name: Upload SBOM
      - name: Sign SBOM
      - name: Attest build provenance
      - name: Upload manifests to R2
      - name: Record snow tag for release job
      - name: Upload snow tag artifact
```

Add a fixture release job that checks out the repository, authenticates ORAS, and calls the resolver. Add mutations proving guard failure when:

```text
Record snow tag for release job moves before Sign SBOM
Upload snow tag artifact moves before Upload manifests to R2
resolver invocation is removed
oras repo tags fallback is added
release checkout is removed
```

- [ ] **Step 2: Run the guard fixture and verify the new assertions fail**

Run:

```bash
./test/bootc-publication-guard-test.sh
```

Expected: nonzero with the new mutation descriptions reported as `not ok` before guard implementation.

- [ ] **Step 3: Move Snow release authorization after metadata**

Delete the current `Record snow tag for release job` and `Upload snow tag artifact` steps before ORAS setup. Reinsert them after `Upload manifests to R2`, preserving the Snow-only conditions and one-day artifact retention.

- [ ] **Step 4: Replace unsafe predecessor selection**

Add a release-job checkout after reading the current tag:

```yaml
      - name: Checkout repository
        if: steps.current.outputs.tag != ''
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5b # v4
        with:
          persist-credentials: false
```

Replace the body of `Resolve previous and current snow tags` with:

```bash
./shared/bootc-secure/ci/resolve-snow-release-predecessor.sh \
  "$GITHUB_REPOSITORY" "$IMAGE" "$CURRENT" "$GITHUB_OUTPUT"
```

Remove the `gh release view` and `oras repo tags` fallback logic entirely.

- [ ] **Step 5: Enforce release ordering and resolver use**

Extend `check-bootc-publication-guard.sh` to require the resolver file, extract the release job, require the pinned checkout action, require the exact resolver invocation, reject `oras repo tags`, and compare global step line numbers so both Snow tag steps occur after `Upload manifests to R2` (which itself follows SBOM signing and provenance).

- [ ] **Step 6: Verify Task 2**

Run:

```bash
bash -n check-bootc-publication-guard.sh test/bootc-publication-guard-test.sh
shellcheck check-bootc-publication-guard.sh test/bootc-publication-guard-test.sh
./check-bootc-publication-guard.sh
./test/bootc-publication-guard-test.sh
actionlint .github/workflows/build-images.yml
```

Expected: all commands exit zero and all new guard mutations are rejected.

---

### Task 3: Documentation, Regression Verification, and Review

**Files:**
- Modify: `CLAUDE.md`
- Modify: `yeti/ci-cd.md`
- Modify: `README.md`
- Verify: `docs/superpowers/specs/2026-07-31-snow-release-sbom-predecessor-design.md`

**Interfaces:**
- Documents: release lineage, SBOM eligibility, late Snow artifact authorization, safe skip, and run `30627996880` evidence boundary.

- [ ] **Step 1: Update documentation**

Record that all three secure image jobs in run `30627996880` passed and that only the release job failed. Explain that Snow changelogs use the newest prior GitHub-release marker whose immutable image has a Syft SBOM, never arbitrary registry tags, and skip when none exists. State that the Snow tag artifact is emitted only after all metadata publication succeeds.

- [ ] **Step 2: Run the complete verification set**

Run:

```bash
bash -n shared/bootc-secure/ci/resolve-snow-release-predecessor.sh \
  test/bootc-release-predecessor-test.sh check-bootc-publication-guard.sh \
  test/bootc-publication-guard-test.sh
shellcheck shared/bootc-secure/ci/resolve-snow-release-predecessor.sh \
  test/bootc-release-predecessor-test.sh check-bootc-publication-guard.sh \
  test/bootc-publication-guard-test.sh
./test/bootc-release-predecessor-test.sh
./check-bootc-publication-guard.sh
./test/bootc-publication-guard-test.sh
./test/bootc-secure-publication-test.sh
./test/bootc-secure-promotion-test.sh
actionlint .github/workflows/build-images.yml .github/workflows/validate.yml \
  .github/workflows/test-bootc-secure.yml .github/workflows/bootc-secure-nightly.yml
git diff --check
```

Expected: every command exits zero. Record exact fixture totals.

- [ ] **Step 3: Request adversarial review**

Ask a reviewer to check release API pagination failure propagation, marker order, same/newer filtering, ORAS failure handling, exact Syft artifact matching, output duplication, unsafe registry fallback, workflow ordering, current-image metadata gating, and fixture vacuity. Resolve all correctness findings and rerun Step 2.
