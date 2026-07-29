# Bootc Secure CI And Rotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make secure bootc assembly and GHCR publication fail closed, add fixture-tested bootc key-rotation orchestration, and establish explicit PR, candidate, nightly, full-window, and Snowfield hardware validation tiers.

**Architecture:** `build-images.yml` remains the only workflow allowed to mutate production OCI repositories: protected jobs first publish and verify an immutable version digest, then move `latest`. Focused shell helpers own static publication policy, remote image verification, and rotation-runner contracts so workflow YAML remains auditable and fixture-testable. Native PR builds use per-run ephemeral signing credentials after the shared `native-build` environment is re-hardened.

**Tech Stack:** GitHub Actions, Bash, mkosi, Buildah/Podman/Skopeo, Cosign 2.6.1, containers/image policy, QEMU/OVMF, swtpm, ShellCheck, actionlint.

## Global Constraints

- Fresh installations only; in-place conversion remains out of scope.
- Reuse `NATIVE_SECURE_BOOT_KEY`, `NATIVE_SECURE_BOOT_CERTIFICATE`, `NATIVE_PCR_SIGNING_KEY`, and `NATIVE_PCR_SIGNING_CERTIFICATE` from the re-hardened `native-build` environment for protected bootc assembly.
- Native PR credentials are disposable RSA-4096 MOK and RSA-2048 PCR identities and their outputs are non-publishable.
- Private signing keys must never enter OCI images, installed systems, logs, caches, uploaded artifacts, or retained temporary state.
- Only pushes to `main`, manual dispatches on `main`, and repository dispatches on the default branch may publish bootc images.
- `build-images.yml` is the sole mutator of `ghcr.io/frostyard/{cayo,snow,snowfield}` and must not move `latest` before immutable-digest label, signature, policy, and artifact validation succeeds.
- Secure images must carry `io.snosi.bootc.secureboot-capable=true` and `io.snosi.bootc.secureboot-assembly=bootc-1.16.3-storage-digest-v1`.
- PR images remain explicitly insecure, carry `io.snosi.bootc.secureboot-capable=false`, and are never pushed.
- Rotation live mode requires explicit external runners and artifacts; missing inputs print `BLOCKED:` and exit 2.
- PCR overlap relies on a dual-signed transition UKI, never sequential fallback across independent TPM tokens. The old token is retained only for rollback safety.
- Runtime code must not create or remove enablement state under `/etc`.
- Preserve the containers-storage update workaround and exact repository-scoped Cosign policy.
- Keep `test-install.yml` as explicitly non-security installation-mechanics coverage.
- Keep the unsupported warning until all profile live gates and Snowfield representative-hardware validation pass.
- Do not create commits unless the user explicitly requests them.
- Update `CLAUDE.md`, `README.md`, and relevant `yeti` documentation with source changes.

---

### Task 1: Bootc Rotation Runner Contract

**Files:**
- Create: `test/bootc-secure-rotation-test.sh`
- Modify: `docs/bootc-secure-install-contract.md`

**Interfaces:**
- Consumes: a mode-0600 Task 9 install-state manifest, immutable old/transition/new OCI references from one Frostyard repository, old/new public MOK and PCR identities, and `BOOTC_SECURE_ROTATION_COMMAND`.
- Produces: `test/bootc-secure-rotation-test.sh [--fixtures]`; live mode invokes one external runner through six ordered phases with exact causal markers.

- [ ] **Step 1: Write the fixture-first rotation harness skeleton**

Create the script with `set -euo pipefail`, TAP-style counters, exact input validation, and these phase and marker contracts:

```bash
rotation_phase() {
    case $1 in
        old-only|dual-pcr|new-pcr|mok-overlap|new-mok|old-trust-removed) return 0 ;;
        *) return 1 ;;
    esac
}

phase_marker() {
    printf 'BOOTC_SECURE_ROTATION: %s: complete\n' "$1"
}

run_phase() {
    local phase=$1 output status
    shift
    set +e
    output=$("$BOOTC_SECURE_ROTATION_COMMAND" --phase "$phase" "$@" 2>&1)
    status=$?
    set -e
    [[ $status -eq 0 ]] || { printf '%s\n' "$output" >&2; return 1; }
    grep -Fqx "$(phase_marker "$phase")" <<<"$output" || return 1
    [[ $output != *NOOP* && $output != *no-op* ]] || return 1
    if [[ $phase == old-trust-removed ]]; then
        grep -Fqx 'BOOTC_SECURE_ROTATION: old-trust-removed: old-mok-rejected' <<<"$output"
        grep -Fqx 'BOOTC_SECURE_ROTATION: old-trust-removed: recovery-ready' <<<"$output"
    fi
}
```

Require these live variables:

```bash
: "${BOOTC_SECURE_ROTATION_STATE:=}"
: "${BOOTC_SECURE_ROTATION_COMMAND:=}"
: "${ROTATION_OLD_REF:=}"
: "${ROTATION_TRANSITION_REF:=}"
: "${ROTATION_NEW_REF:=}"
: "${ROTATION_OLD_MOK_CERT:=}"
: "${ROTATION_NEW_MOK_CERT:=}"
: "${ROTATION_OLD_PCR_PUBLIC:=}"
: "${ROTATION_NEW_PCR_PUBLIC:=}"
```

Accept only `ghcr.io/frostyard/(cayo|snow|snowfield)@sha256:<64 hex>` references from the state manifest's profile repository. Require all three digests to differ, every public identity to exist, the state manifest and recovery file to be mode 0600, and the external runner to be executable.

- [ ] **Step 2: Add fixtures that fail before orchestration is complete**

Fixture mode must assert:

```bash
assert_true 'all six rotation phases are recognized' rotation_phase dual-pcr
assert_false 'unknown rotation phases are rejected' rotation_phase remove-everything
assert_true 'exact phase markers are accepted' marker_is_exact \
    'BOOTC_SECURE_ROTATION: dual-pcr: complete' "$(phase_marker dual-pcr)"
assert_false 'wrapped phase markers are rejected' marker_is_exact \
    'prefix BOOTC_SECURE_ROTATION: dual-pcr: complete' "$(phase_marker dual-pcr)"
```

Create temporary marked, no-op, and failing runner stubs. Require the marked runner to pass, and require `/bin/true`, `/bin/false`, and the no-op runner to fail. Create a safe mode-0600 state fixture and reject wrong mode, tags, cross-repository refs, equal digests, missing public identities, and secret-bearing manifest keys.

Run: `./test/bootc-secure-rotation-test.sh --fixtures`

Expected: FAIL until ordered live orchestration and all fixture helpers exist.

- [ ] **Step 3: Implement ordered fail-closed live orchestration**

Invoke phases exactly in this order:

```bash
phases=(old-only dual-pcr new-pcr mok-overlap new-mok old-trust-removed)
for phase in "${phases[@]}"; do
    run_phase "$phase" \
        --state "$BOOTC_SECURE_ROTATION_STATE" \
        --old-ref "$ROTATION_OLD_REF" \
        --transition-ref "$ROTATION_TRANSITION_REF" \
        --new-ref "$ROTATION_NEW_REF" \
        --old-mok-cert "$ROTATION_OLD_MOK_CERT" \
        --new-mok-cert "$ROTATION_NEW_MOK_CERT" \
        --old-pcr-public "$ROTATION_OLD_PCR_PUBLIC" \
        --new-pcr-public "$ROTATION_NEW_PCR_PUBLIC"
done
```

The contract text must state that `dual-pcr` proves the transition UKI unlocks using the old authorization and then enrolls the new token; `new-pcr` proves new-only policy plus retained rollback; MOK overlap retains both certificates until all old rollback deployments are retired; and `old-trust-removed` must prove old-only content is rejected while recovery remains usable.

Document the complete six-phase mapping: `old-only` establishes the old MOK/PCR baseline; `dual-pcr` transitions PCR authorization; `new-pcr` proves the new PCR identity and retained rollback; `mok-overlap` enrolls the new MOK while retaining the old; `new-mok` boots and reconciles new-MOK-signed content; and `old-trust-removed` retires old rollback content before deleting the old MOK.

When requirements are missing, print one line beginning `BLOCKED: Task 10 bootc rotation proof requires:` and return 2 before invoking a runner.

- [ ] **Step 4: Verify fixture and blocked modes**

Run:

```bash
./test/bootc-secure-rotation-test.sh --fixtures
set +e
output=$(./test/bootc-secure-rotation-test.sh 2>&1)
status=$?
set -e
test "$status" -eq 2
grep -q '^BLOCKED: Task 10 bootc rotation proof requires:' <<<"$output"
shellcheck -S warning -x test/bootc-secure-rotation-test.sh
```

Expected: fixture suite passes; live mode without inputs exits 2 and reports `BLOCKED`; ShellCheck reports no warnings.

### Task 2: Remote Secure Image Verification

**Files:**
- Create: `shared/bootc-secure/ci/verify-published-image.sh`
- Create: `test/bootc-secure-publication-test.sh`

**Interfaces:**
- `verify-published-image.sh IMAGE VERSION_TAG EXPECTED_DIGEST LOCAL_REF` verifies the pushed immutable candidate and policy-copies it into root containers-storage as `LOCAL_REF`; it never pushes or retags.
- Consumes: committed `cosign.pub`, secure containers policy, GHCR `registries.d` configuration, existing Docker/containers credentials, Skopeo, Cosign 2.6.1, and passwordless `sudo` for the root storage copy.

- [ ] **Step 1: Write failing publication-helper fixtures**

Use PATH stubs for `skopeo`, `cosign`, and `sudo`. Record every command in `$COMMAND_LOG`. The successful fixture must report the expected digest and labels:

```json
{
  "Digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "Labels": {
    "io.snosi.bootc.secureboot-capable": "true",
    "io.snosi.bootc.secureboot-assembly": "bootc-1.16.3-storage-digest-v1"
  }
}
```

Assert that the helper:

- rejects tags, wrong repositories, malformed digests, remote digest mismatch, false/missing capability, wrong assembly label, failed Cosign verification, and failed policy copy;
- invokes `cosign verify --key <repo>/cosign.pub IMAGE@DIGEST`;
- invokes `skopeo copy` with a disposable policy and registries directory from `docker://IMAGE@DIGEST` to `containers-storage:LOCAL_REF`;
- never contains or invokes `push`, `tag`, or `latest`.

Run: `./test/bootc-secure-publication-test.sh`

Expected: FAIL because the helper does not exist.

- [ ] **Step 2: Implement the minimal verifier**

Validate arguments with anchored expressions, inspect the immutable remote reference once as JSON, and enforce:

```bash
jq -e --arg digest "$EXPECTED_DIGEST" '
    .Digest == $digest and
    .Labels["io.snosi.bootc.secureboot-capable"] == "true" and
    .Labels["io.snosi.bootc.secureboot-assembly"] == "bootc-1.16.3-storage-digest-v1"
' <<<"$inspection" >/dev/null
```

Create a mode-0700 temporary directory. Rewrite every trusted Docker scope's `keyPath` in the committed policy to the absolute committed key path:

```bash
jq --arg key "$ROOT_DIR/cosign.pub" '
  .transports.docker |= with_entries(.value |= map(.keyPath = $key))
' "$ROOT_DIR/shared/bootc-secure/tree/etc/containers/policy.json" >"$work/policy.json"
mkdir -p "$work/registries.d"
cp "$ROOT_DIR/shared/bootc-secure/tree/etc/containers/registries.d/frostyard.yaml" "$work/registries.d/frostyard.yaml"
```

Then run:

```bash
cosign verify --key "$ROOT_DIR/cosign.pub" "$IMAGE@$EXPECTED_DIGEST" >/dev/null
sudo skopeo copy --policy "$work/policy.json" --registries.d "$work/registries.d" \
    "docker://$IMAGE@$EXPECTED_DIGEST" "containers-storage:$LOCAL_REF"
```

Trap removal of the temporary directory. Do not weaken the repository-scoped policy or add an insecure registry exception.

- [ ] **Step 3: Run positive and mutation fixtures**

Run:

```bash
./test/bootc-secure-publication-test.sh
shellcheck -S warning -x shared/bootc-secure/ci/verify-published-image.sh \
  test/bootc-secure-publication-test.sh
```

Expected: all helper fixtures pass and ShellCheck reports no warnings.

### Task 3: Static Bootc Publication Guard

**Files:**
- Create: `check-bootc-publication-guard.sh`
- Create: `test/bootc-publication-guard-test.sh`

**Interfaces:**
- `check-bootc-publication-guard.sh` inspects `${SNOSI_BOOTC_GUARD_ROOT:-repository root}` without network access.
- Produces a zero exit only when profile composition and workflow publication ordering remain fail closed.

- [ ] **Step 1: Write mutation fixtures for the guard**

Build a temporary minimal repository fixture containing the three bootc profile configs, one native profile, required public files, and a reduced `build-images.yml` with these literal step names in order:

```yaml
- name: Push immutable version tag
- name: Sign immutable image digest
- name: Verify pushed secure image
- name: Validate policy-copied secure artifact
- name: Promote validated digest to latest
```

Run the guard with `SNOSI_BOOTC_GUARD_ROOT="$fixture"`. Require the baseline to pass, then independently mutate and require failure for:

- a missing bootc secure include;
- a native profile including `shared/bootc-secure/mkosi.conf`;
- a missing policy, registry, schema, MOK certificate, PCR public key, or Cosign public key;
- a publishing job without `environment: native-build`;
- a publishing condition that lacks `refs/heads/main` or permits pull requests;
- missing `SNOSI_BOOTC_SECURE: "1"` or any signing variable;
- missing `if: always()` credential cleanup;
- false/missing secure-label checks;
- `latest` promotion before immutable digest verification or artifact validation.

Run: `./test/bootc-publication-guard-test.sh`

Expected: FAIL because the guard does not exist.

- [ ] **Step 2: Implement the static guard**

Use arrays and exact grep checks rather than a general YAML parser. Require each `mkosi.profiles/{cayo,snow,snowfield}/mkosi.conf` to contain:

```text
Include=%D/shared/bootc-secure/mkosi.conf
```

Reject that include under `mkosi.profiles/*-ab*/mkosi.conf`. Require these files:

```text
cosign.pub
shared/native-ab/keys/mok-2026.crt
shared/native-ab/keys/pcr-signing-2026.pub
shared/bootc-secure/tree/etc/containers/policy.json
shared/bootc-secure/tree/etc/containers/registries.d/frostyard.yaml
shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json
```

Require the protected job, four secret mappings, secure environment switch, unconditional cleanup, verifier call, local/remote artifact checks, and ordered step-name line numbers. Emit one `FAIL:` line per violation and a final success line only when no violations exist.

- [ ] **Step 3: Verify guard fixtures before workflow integration**

Run:

```bash
./test/bootc-publication-guard-test.sh
shellcheck -S warning -x check-bootc-publication-guard.sh test/bootc-publication-guard-test.sh
```

Expected: mutation fixtures and ShellCheck pass. Running `./check-bootc-publication-guard.sh` against the real repository still fails because Task 4 has not yet replaced the insecure publisher; do not wire the real-repository guard into `validate.yml` until Task 4 Step 8.

### Task 4: Protected Transactional OCI Publication

**Files:**
- Modify: `.github/workflows/build-images.yml`
- Modify: `.github/workflows/validate.yml`
- Test: `check-bootc-publication-guard.sh`
- Test: `test/bootc-publication-guard-test.sh`

**Interfaces:**
- Pull requests run `mechanics-build`, which packages locally with no secrets and never pushes.
- Main/default-branch publication events run `secure-build` in `native-build`; the version tag becomes a release candidate and `latest` moves only after immutable remote verification.

- [ ] **Step 1: Make the guard fail against the current insecure publisher**

Run: `./check-bootc-publication-guard.sh`

Expected: FAIL because the current workflow packages insecure images on publishing events and pushes `latest` before remote signature/label/artifact validation.

- [ ] **Step 2: Split unprotected mechanics from protected publication**

Rename the current matrix job to `secure-build`, add:

```yaml
if: >-
  github.event_name != 'pull_request' &&
  github.ref == 'refs/heads/main'
environment: native-build
```

Keep the existing three-profile matrix and publishing permissions there. Add a separate `mechanics-build` matrix job with `if: github.event_name == 'pull_request'`, `contents: read`, and only the disk preparation, checkout, duplicate-package check, date/version, mkosi setup/build, insecure package, SUID/bcvk smoke test, and cleanup steps. It must not reference `secrets.*`, `native-build`, `buildah push`, `cosign`, ORAS, R2, attestations, `SNOSI_BOOTC_SECURE=1`, or `latest`.

Repository setup prerequisite: keep `GHCR_PAT`, `SIGNING_SECRET`, and the three existing `R2_*` values as repository secrets accessible to protected main/default-branch jobs. Re-harden `native-build` with deployment-branch restrictions for the default/protected branch and no required-reviewer gate, so automated main pushes and repository dispatches do not stall waiting for approval.

Update `release.needs` from `build` to `secure-build`.

- [ ] **Step 3: Materialize and clean protected credentials**

Immediately before secure packaging, add:

```yaml
- name: Materialize protected bootc signing credentials
  env:
    NATIVE_SECURE_BOOT_KEY: ${{ secrets.NATIVE_SECURE_BOOT_KEY }}
    NATIVE_SECURE_BOOT_CERTIFICATE: ${{ secrets.NATIVE_SECURE_BOOT_CERTIFICATE }}
    NATIVE_PCR_SIGNING_KEY: ${{ secrets.NATIVE_PCR_SIGNING_KEY }}
    NATIVE_PCR_SIGNING_CERTIFICATE: ${{ secrets.NATIVE_PCR_SIGNING_CERTIFICATE }}
  run: |
    set -euo pipefail
    for name in NATIVE_SECURE_BOOT_KEY NATIVE_SECURE_BOOT_CERTIFICATE NATIVE_PCR_SIGNING_KEY NATIVE_PCR_SIGNING_CERTIFICATE; do
      [[ -n "${!name}" ]] || { echo "::error::secrets.$name is not set in native-build" >&2; exit 1; }
    done
    umask 077
    mkdir -p /var/tmp/bootc-secure-credentials
    printf '%s' "$NATIVE_SECURE_BOOT_KEY" > /var/tmp/bootc-secure-credentials/mok.key
    printf '%s' "$NATIVE_SECURE_BOOT_CERTIFICATE" > /var/tmp/bootc-secure-credentials/mok.crt
    printf '%s' "$NATIVE_PCR_SIGNING_KEY" > /var/tmp/bootc-secure-credentials/pcr.key
    printf '%s' "$NATIVE_PCR_SIGNING_CERTIFICATE" > /var/tmp/bootc-secure-credentials/pcr.crt
    chmod 600 /var/tmp/bootc-secure-credentials/*
    openssl x509 -in /var/tmp/bootc-secure-credentials/pcr.crt -pubkey -noout \
      > /var/tmp/bootc-secure-credentials/pcr.pub
    chmod 600 /var/tmp/bootc-secure-credentials/pcr.pub
    cmp -s /var/tmp/bootc-secure-credentials/mok.crt shared/native-ab/keys/mok-2026.crt || {
      echo "::error::protected MOK certificate differs from the committed identity" >&2
      exit 1
    }
    cmp -s /var/tmp/bootc-secure-credentials/pcr.pub shared/native-ab/keys/pcr-signing-2026.pub || {
      echo "::error::protected PCR certificate differs from the committed identity" >&2
      exit 1
    }
```

Set the package step environment exactly:

```yaml
SNOSI_BOOTC_SECURE: "1"
SNOSI_BOOTC_MOK_KEY: /var/tmp/bootc-secure-credentials/mok.key
SNOSI_BOOTC_MOK_CERT: /var/tmp/bootc-secure-credentials/mok.crt
SNOSI_BOOTC_PCR_KEY: /var/tmp/bootc-secure-credentials/pcr.key
SNOSI_BOOTC_PCR_CERT: /var/tmp/bootc-secure-credentials/pcr.pub
```

After local validation, add an unconditional cleanup step:

```yaml
- name: Remove protected bootc signing credentials
  if: always()
  run: sudo rm -rf /var/tmp/bootc-secure-credentials
```

- [ ] **Step 4: Validate the local secure artifact before registry writes**

Before credential cleanup, run:

```yaml
- name: Validate locally assembled secure artifact
  env:
    IMAGE: ghcr.io/${{ github.repository_owner }}/${{ matrix.profile }}
  run: |
    sudo ./test/bootc-secure-artifact-test.sh \
      "output/${{ matrix.profile }}" \
      "$IMAGE:${{ steps.version.outputs.tag }}" \
      /var/tmp/bootc-secure-credentials/mok.crt \
      /var/tmp/bootc-secure-credentials/pcr.pub
```

The package script's own final credential scan remains mandatory; this external validation is additive.

- [ ] **Step 5: Push and sign only the immutable version candidate**

Rename the push step to `Push immutable version tag` and remove the current local `latest` tag and push commands. Retain digest extraction and validation. Install Cosign before image signing, then run the existing `Sign image` step against `IMAGE@DIGEST`.

Retain `docker/login-action` before image signing, remote verification, and promotion so user-context Cosign and Skopeo share authenticated Docker credentials. Root Buildah keeps its separate stdin login for the immutable version push.

Do not upload SBOMs, record the snow release tag, or promote `latest` yet.

- [ ] **Step 6: Verify the remote candidate and policy-copied artifact**

After signing, add:

```yaml
- name: Verify pushed secure image
  env:
    IMAGE: ghcr.io/${{ github.repository_owner }}/${{ matrix.profile }}
    VERSION_TAG: ${{ steps.version.outputs.tag }}
    DIGEST: ${{ steps.push.outputs.digest }}
    LOCAL_REF: localhost/snosi-verified-${{ matrix.profile }}:${{ steps.version.outputs.tag }}
  run: ./shared/bootc-secure/ci/verify-published-image.sh "$IMAGE" "$VERSION_TAG" "$DIGEST" "$LOCAL_REF"

- name: Validate policy-copied secure artifact
  env:
    LOCAL_REF: localhost/snosi-verified-${{ matrix.profile }}:${{ steps.version.outputs.tag }}
  run: |
    sudo ./test/bootc-secure-artifact-test.sh \
      "output/${{ matrix.profile }}" "$LOCAL_REF" \
      "output/${{ matrix.profile }}/usr/lib/snosi/mok.crt" \
      "output/${{ matrix.profile }}/usr/lib/snosi/pcr-signing.pub"
```

This proves the bytes pulled through the restrictive repository policy still satisfy the UKI/composefs artifact contract.

- [ ] **Step 7: Promote the validated digest to `latest`**

Only after both remote checks pass, perform a registry-to-registry copy from the already validated immutable digest. Do not re-push local Buildah bytes under `latest`: that could produce a different manifest and would mutate `latest` before detecting the mismatch.

```yaml
- name: Promote validated digest to latest
  env:
    IMAGE: ghcr.io/${{ github.repository_owner }}/${{ matrix.profile }}
  run: |
    skopeo copy --all \
      "docker://$IMAGE@${{ steps.push.outputs.digest }}" \
      "docker://$IMAGE:latest"
    latest_digest=$(skopeo inspect --format '{{.Digest}}' "docker://$IMAGE:latest")
    [[ "$latest_digest" == "${{ steps.push.outputs.digest }}" ]] || {
      echo "::error::latest resolved to $latest_digest instead of ${{ steps.push.outputs.digest }}" >&2
      exit 1
    }
```

Move snow-tag recording, SBOM attachment/signing, provenance, manifest upload, and release consumption after this step so none treats an unpromoted candidate as released.

- [ ] **Step 8: Wire the guard and fast secure fixtures into validation**

After the real workflow satisfies the guard, add a dedicated `bootc-secure-contracts` job to `.github/workflows/validate.yml` with read-only contents permission and these exact commands:

```yaml
- name: Validate bootc publication guard
  run: ./check-bootc-publication-guard.sh
- name: Validate bootc publication guard fixtures
  run: ./test/bootc-publication-guard-test.sh
- name: Validate bootc secure artifact fixtures
  run: ./test/bootc-secure-artifact-test.sh --fixtures
- name: Validate bootc secure mutation fixtures
  run: ./test/bootc-secure-artifact-negative-test.sh --fixtures
- name: Validate bootc secure package cleanup
  run: ./test/bootc-secure-package-cleanup-test.sh
- name: Validate bootc container policy
  run: ./test/bootc-container-policy-test.sh
- name: Validate bootloader reconciliation
  run: ./test/bootc-bootloader-reconcile-test.sh
- name: Validate secure installer contract
  run: ./test/bootc-secure-install-contract-test.sh
- name: Validate secure install harness fixtures
  run: ./test/bootc-secure-install-test.sh --fixtures
- name: Validate secure update harness fixtures
  run: ./test/bootc-secure-update-test.sh --fixtures
- name: Validate secure rotation harness fixtures
  run: ./test/bootc-secure-rotation-test.sh --fixtures
- name: Validate remote publication fixtures
  run: ./test/bootc-secure-publication-test.sh
```

- [ ] **Step 9: Verify workflow structure and fixture gates**

Run:

```bash
./check-bootc-publication-guard.sh
./test/bootc-publication-guard-test.sh
actionlint .github/workflows/build-images.yml
actionlint .github/workflows/validate.yml
```

Expected: all checks pass; the guard confirms immutable verification and artifact validation precede `latest`.

### Task 5: Native PR Ephemeral Signing

**Files:**
- Modify: `.github/workflows/build-native-images.yml`
- Modify: `check-native-publication-guard.sh`
- Modify: `docs/native-ab-publication.md`

**Interfaces:**
- Production `build-{cayo,snow,snowfield}` jobs remain in `native-build` and run only outside pull requests.
- New `build-pr` matrix job covers all three native profiles with disposable credentials and performs no candidate upload or promotion.

- [ ] **Step 1: Extend the native guard to require protected production and ephemeral PR separation**

Add checks requiring:

```text
build-pr:
if: github.event_name == 'pull_request'
openssl req -x509 -newkey rsa:4096
openssl req -x509 -newkey rsa:2048
```

Require each production build job to retain `environment: native-build` and an `if` excluding pull requests. Reject `secrets.NATIVE_*` references inside the `build-pr` job block and reject publication-script calls there.

Read `.github/workflows/build-native-images.yml` explicitly. Extract the PR job with this boundary rule so checks cannot drift into a neighboring job:

```bash
pr_job=$(awk '
  /^  build-pr:$/ { capture=1 }
  capture && /^  [A-Za-z0-9_-]+:$/ && $0 != "  build-pr:" { exit }
  capture { print }
' .github/workflows/build-native-images.yml)
```

Require the ephemeral-key markers in `$pr_job`; reject `secrets.NATIVE_`, `publish-candidate.sh`, `promote.sh`, `rclone:`, and `actions/upload-artifact` there. Extract each production job with the same next-top-level-job boundary and require its environment and non-PR condition.

Run: `./check-native-publication-guard.sh`

Expected: FAIL until workflow separation exists.

- [ ] **Step 2: Gate existing production build jobs out of PRs**

Add this exact condition to `build-cayo`, `build-snow`, and `build-snowfield`:

```yaml
if: github.event_name != 'pull_request'
```

Keep `environment: native-build` and the existing protected secret materialization unchanged. Update the header comment to require protected/default-branch access rather than describing same-repository PR key exposure.

- [ ] **Step 3: Add one non-publishing native PR matrix job**

Add `build-pr` after `prepare`:

```yaml
build-pr:
  needs: prepare
  if: github.event_name == 'pull_request'
  runs-on: ubuntu-latest
  timeout-minutes: 180
  permissions:
    contents: read
  strategy:
    fail-fast: false
    matrix:
      include:
        - profile: cayo-ab
          product: cayo
        - profile: snow-ab
          product: snow
        - profile: snowfield-ab
          product: snowfield
```

Reuse the existing disk, checkout, pinned-mkosi, and host preparation steps. Generate credentials with:

```bash
set -euo pipefail
umask 077
mkdir -p .snosi-private/history
openssl req -x509 -newkey rsa:4096 -nodes -days 2 \
  -keyout mkosi.key -out mkosi.crt \
  -subj "/CN=snosi native PR ephemeral MOK"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout .snosi-private/pcr-signing.key \
  -out .snosi-private/pcr-signing.crt \
  -subj "/CN=snosi native PR ephemeral PCR"
openssl x509 -in .snosi-private/pcr-signing.crt -pubkey -noout \
  > .snosi-private/pcr-signing.pub
```

Build with `SNOSI_NATIVE_AUTOSTAGE=1`, remove all private/certificate files in an `if: always()` step, run `native-ab-secure-artifact-test.sh`, and conditionally run `snowfield-artifact-test.sh` when `matrix.product == 'snowfield'`. Do not call prepare-publication, R2, upload-artifact, verify-remote, promote, or release scripts.

- [ ] **Step 4: Keep downstream publication jobs deterministic on PRs**

Retain `test-public-origin`'s `if: ${{ !cancelled() }}` and missing-artifact skip behavior. Its PR run must find no `native-prepared-*` artifacts and perform no public-origin mutation. Promotion jobs already exclude pull requests and remain unchanged.

- [ ] **Step 5: Verify native workflow separation**

Run:

```bash
./check-native-publication-guard.sh
./test/native-ab-static-test.sh
./test/native-ab-contracts-test.sh
actionlint .github/workflows/build-native-images.yml
```

Expected: all static and workflow checks pass.

### Task 6: Validation Workflows And Explicit Mechanics Tier

**Files:**
- Create: `.github/workflows/test-bootc-secure.yml`
- Create: `.github/workflows/bootc-secure-nightly.yml`
- Modify: `.github/workflows/test-install.yml`

**Interfaces:**
- `test-bootc-secure.yml` runs no-secret fixture coverage on PR/push/manual and an optional manually requested self-hosted live gate.
- `bootc-secure-nightly.yml` rotates profiles, runs fixtures, and makes absent external release fixtures visibly blocked.
- `test-install.yml` remains manual and insecure by declaration.

- [ ] **Step 1: Add the fast secure-contract workflow**

Create `test-bootc-secure.yml` with PR, main push, and workflow-dispatch triggers; empty top-level permissions; concurrency per ref; and a hosted `contracts` job that checks out without persisted credentials and runs the same twelve commands added to `validate.yml` in Task 4 Step 8.

Add workflow-dispatch inputs:

```yaml
run_live:
  description: "Run live secure install/update/rotation on a prepared self-hosted runner"
  required: false
  default: false
  type: boolean
profile:
  description: "Live profile"
  required: false
  default: cayo
  type: choice
  options: [cayo, snow, snowfield]
state_root:
  description: "Absolute directory containing Task 9/10 artifacts and runner inputs"
  required: false
  default: ""
```

Add `live-full-window` with:

```yaml
if: github.event_name == 'workflow_dispatch' && inputs.run_live
runs-on: [self-hosted, linux, x64, bootc-secure]
timeout-minutes: 360
permissions:
  contents: read
```

Validate that `state_root` is an absolute mode-0700 directory. Use fixed names below it (`dakota.iso`, `target.raw`, `recovery.key`, `mok.crt`, `pcr.pub`, `install-state.json`, `installer`, `negative-runner`, `recovery-runner`, `publisher`, `update-negative-runner`, `rotation-runner`, and `refs.env`). Source only `refs.env` after requiring it is mode 0600, owned by the runner user, and contains no shell metacharacters outside simple `NAME=value` lines. Invoke install, update, and rotation harnesses sequentially with their exact environment variables. Any missing input must reach the harness and return `BLOCKED`/2 rather than being skipped.

- [ ] **Step 2: Add nightly profile rotation and visible blocking**

Create `bootc-secure-nightly.yml` following `native-nightly.yml`'s schedule, concurrency, disk preparation, KVM enablement, `set -o pipefail`, `KEEP_VM=1`, and failure-log upload patterns. Select `snowfield` on Sunday, `cayo` Tuesday/Thursday/Saturday, and `snow` otherwise.

Use two jobs:

- `fixtures`: hosted, no secrets/environments, runs all Task 10 contract fixtures.
- `live-full-window`: runs on `[self-hosted, linux, x64, bootc-secure]`, needs fixtures, and reads prepared state from `/var/lib/snosi/bootc-secure/<profile>`. If that directory is absent, run `./test/bootc-secure-rotation-test.sh` without inputs so the job visibly exits 2 with `BLOCKED`. If present, run the same fixed-name protocol as the manual live job. The self-hosted runner is the external execution boundary; do not put recovery material or private keys in repository variables or Actions artifacts.

Nothing in `build-images.yml` or release jobs may depend on this nightly workflow.

- [ ] **Step 3: Add the manual Snowfield hardware tier**

Add a `snowfield-hardware` job to `test-bootc-secure.yml` behind a second boolean input `run_snowfield_hardware`. Run it only on:

```yaml
runs-on: [self-hosted, linux, x64, snowfield-hardware]
```

Require `${state_root}/snowfield-hardware-runner` to be executable and require its exact final marker:

```text
BOOTC_SECURE_SNOWFIELD_HARDWARE: complete
```

Pass `--state-root "$state_root"`; reject a wrapped marker or a zero exit without the exact marker. Upload runner logs for 30 days on success or failure. This tier records representative hardware evidence; it does not run on hosted QEMU.

- [ ] **Step 4: Rename and constrain the legacy install workflow**

Change the display name to:

```yaml
name: Test bootc installation mechanics (insecure)
```

Change the input description to state that it accepts an explicitly insecure mechanics image and does not provide security evidence. Add a job-level comment and summary step stating it does not validate Secure Boot, MOK, LUKS, TPM, or authenticated updates. Before running the install test, require the resolved image label:

```bash
capability=$(skopeo inspect --format '{{ index .Labels "io.snosi.bootc.secureboot-capable" }}' "docker://${IMAGE}@${DIGEST}")
[[ $capability == false ]] || {
  echo "::error::legacy mechanics workflow requires secureboot-capable=false" >&2
  exit 1
}
```

Use `IMAGE` from the workflow-level environment and `DIGEST` resolved by the immediately preceding verification step. A missing label is intentionally rejected just like `true`; current pre-capability published images are not acceptable mechanics fixtures. Change the default input away from production `latest` to an empty required value so operators must deliberately name a non-production mechanics tag.

- [ ] **Step 5: Validate all workflow syntax and static gates**

Run:

```bash
actionlint .github/workflows/test-bootc-secure.yml \
  .github/workflows/bootc-secure-nightly.yml \
  .github/workflows/test-install.yml
./check-bootc-publication-guard.sh
./test/bootc-publication-guard-test.sh
```

Expected: actionlint and both publication gates pass.

### Task 7: CI Documentation And Final Task 10 Verification

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `yeti/build-pipeline.md`
- Modify: `yeti/testing.md`
- Modify: `yeti/ci-cd.md`
- Modify: `docs/superpowers/plans/2026-07-28-bootc-secure-platform.md`

**Interfaces:**
- Produces accurate operator-facing and AI-facing documentation for protected build modes, publication ordering, validation tiers, and remaining blockers.

- [ ] **Step 1: Update build and custody documentation**

Document these exact facts:

- `native-build` must be restricted to protected/default branches in GitHub settings;
- the four existing `NATIVE_*` secrets serve protected native and bootc assembly;
- native PRs use per-run ephemeral RSA-4096/RSA-2048 credentials and cannot publish;
- bootc PRs build only `secureboot-capable=false` mechanics images;
- protected bootc credentials exist only around packaging/local validation and are deleted before registry publication;
- protected MOK and PCR public identities must be byte-identical to `shared/native-ab/keys/mok-2026.crt` and `shared/native-ab/keys/pcr-signing-2026.pub`;
- `build-images.yml` pushes a version tag, validates its immutable digest, then moves `latest`;
- failed immutable candidates never move `latest`.

Remove the obsolete accepted-risk text claiming `native-build` is open to same-repository PRs.

- [ ] **Step 2: Document validation tiers and blockers**

Describe PR, candidate, nightly, full-window, legacy mechanics, and Snowfield hardware tiers. State that fixture success proves runner contracts only; live Task 9/10 remains `BLOCKED` until signed secure N/N+1/N+2/transition OCI fixtures and prepared external runners exist. Record that the inspected 2026-07-27 `latest` images lacked `io.snosi.bootc.secureboot-capable` and therefore are correctly unsuitable for live Task 9.

Do not remove the unsupported warning or claim production Secure Boot support.

- [ ] **Step 3: Update the umbrella plan status accurately**

Mark Task 8 external implementation checkboxes complete. Mark Task 9 fixture/protocol items complete but retain live profile and hardware items as blocked. Mark Task 10 fixture/CI implementation items complete while explicitly leaving live rotation/full-window/hardware evidence pending. Do not convert blocked evidence to `[x]`.

- [ ] **Step 4: Run focused Task 10 verification**

Run:

```bash
./test/bootc-secure-rotation-test.sh --fixtures
./test/bootc-secure-publication-test.sh
./test/bootc-publication-guard-test.sh
./check-bootc-publication-guard.sh
./check-native-publication-guard.sh
./test/bootc-secure-install-test.sh --fixtures
./test/bootc-secure-update-test.sh --fixtures
./test/bootc-secure-artifact-test.sh --fixtures
./test/bootc-secure-artifact-negative-test.sh --fixtures
./test/bootc-secure-package-cleanup-test.sh
./test/bootc-container-policy-test.sh
./test/bootc-bootloader-reconcile-test.sh
./test/bootc-secure-install-contract-test.sh
./check-runtime-etc-guard.sh
```

Expected: every fixture/static command passes.

- [ ] **Step 5: Run lint and configuration verification**

Run:

```bash
shellcheck -S warning -x \
  check-bootc-publication-guard.sh \
  check-native-publication-guard.sh \
  shared/bootc-secure/ci/verify-published-image.sh \
  test/bootc-secure-rotation-test.sh \
  test/bootc-secure-publication-test.sh \
  test/bootc-publication-guard-test.sh
actionlint \
  .github/workflows/build-images.yml \
  .github/workflows/build-native-images.yml \
  .github/workflows/test-install.yml \
  .github/workflows/test-bootc-secure.yml \
  .github/workflows/bootc-secure-nightly.yml \
  .github/workflows/validate.yml
sudo mkosi summary >/dev/null
for profile in cayo snow snowfield; do
  sudo mkosi --profile "$profile" summary >/dev/null
done
```

Expected: ShellCheck and actionlint report no findings; every mkosi summary resolves.

- [ ] **Step 6: Confirm live modes remain fail closed**

Run:

```bash
for test_script in \
  ./test/bootc-secure-install-test.sh \
  ./test/bootc-secure-update-test.sh \
  ./test/bootc-secure-rotation-test.sh; do
  set +e
  output=$($test_script 2>&1)
  status=$?
  set -e
  test "$status" -eq 2
  grep -q '^BLOCKED:' <<<"$output"
done
```

Expected: every unconfigured live harness exits 2 and identifies its missing evidence; none reports PASS.
