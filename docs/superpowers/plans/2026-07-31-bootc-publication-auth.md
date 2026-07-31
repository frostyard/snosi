# Bootc Publication Explicit-Auth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every critical-path GHCR operation use the Docker login config explicitly, bind the version tag to the expected digest, and fixture-test `latest` promotion before another protected build.

**Architecture:** The existing verifier keeps one `AUTH_FILE` input and applies it to both Skopeo inspections, Cosign's command-scoped `DOCKER_CONFIG`, and root policy copy. A new promotion helper owns the only mutable-tag operation and explicitly authenticates both registry endpoints and the confirming inspect; static guards and faithful stubs enforce the complete path.

**Tech Stack:** Bash, GitHub Actions YAML, Skopeo, Cosign 2.6.1, jq, ShellCheck, actionlint

## Global Constraints

- The verifier interface remains `verify-published-image.sh IMAGE VERSION_TAG EXPECTED_DIGEST LOCAL_REF AUTH_FILE`.
- `AUTH_FILE` must be an existing regular file named exactly `config.json`.
- Skopeo inspect uses `--authfile`, root policy copy uses source-only `--src-authfile`, and promotion copy uses both `--src-authfile` and `--dest-authfile`.
- Pinned Cosign v2.6.1 has no `--registry-config`; verification uses command-scoped `DOCKER_CONFIG` equal to `AUTH_FILE`'s parent directory.
- Never put credential contents, usernames, passwords, PATs, or tokens in command arguments, logs, outputs, repository state, or retained temporary state.
- Require the version tag to resolve to `EXPECTED_DIGEST` before policy copy; do not claim registry-enforced tag immutability.
- Preserve exact secure labels, immutable-digest Cosign verification, restrictive policy copy, root containers-storage validation, and validation-before-promotion ordering.
- The promotion helper accepts exactly `IMAGE EXPECTED_DIGEST AUTH_FILE` and performs no signing, local-storage access, SBOM, provenance, manifest, or release operation.
- Keep SBOM identity selection, metadata ordering, release gating, and general cleanup redesign out of this repair; document them as deferred findings.
- A successful protected build is one candidate set, not Task 9 runtime evidence, distinct N/N+1/N+2 evidence, or Snowfield hardware proof.

---

### Task 1: Explicitly Authenticate Every Verifier Read

**Files:**
- Modify: `test/bootc-secure-publication-test.sh`
- Modify: `shared/bootc-secure/ci/verify-published-image.sh`
- Modify: `check-bootc-publication-guard.sh`
- Modify: `test/bootc-publication-guard-test.sh`

**Interfaces:**
- Consumes: `AUTH_FILE` pointing to Docker-compatible `config.json`, `IMAGE`, `VERSION_TAG`, and `EXPECTED_DIGEST` from the protected workflow.
- Produces: a policy-copied root containers-storage image only after explicit-auth metadata reads, version-tag binding, and explicit-auth Cosign verification pass.

- [ ] **Step 1: Make the verifier fixture fail when remote reads omit explicit auth**

In `test/bootc-secure-publication-test.sh`, pass both
`EXPECTED_AUTH_FILE="$AUTH_FILE"` and `EXPECTED_DIGEST="$5"` into the helper
invocation. Replace the Skopeo stub's inspect branch with logic that requires
the exact auth path and distinguishes digest metadata from tag resolution:

```bash
inspect)
    [[ " $* " == *" --authfile $EXPECTED_AUTH_FILE "* ]]
    if [[ " $* " == *" --format {{.Digest}} "* ]]; then
        printf '%s\n' "${TAG_DIGEST:-$EXPECTED_DIGEST}"
    else
        printf '%s\n' "$INSPECTION"
    fi
    ;;
```

Make the Cosign stub require and record the command-scoped config directory:

```bash
expected_dir=$(dirname -- "$EXPECTED_AUTH_FILE")
printf 'DOCKER_CONFIG=%s cosign %s\n' "${DOCKER_CONFIG:-}" "$*" >>"$COMMAND_LOG"
[[ ${DOCKER_CONFIG:-} == "$expected_dir" ]]
[[ ${COSIGN_VERIFY_FAIL:-0} != 1 ]]
```

Change the positive assertions to require this exact order and authority:

```bash
grep -Fqx "skopeo inspect --authfile $AUTH_FILE docker://$IMAGE@$DIGEST" "$WORK/commands"
grep -Fqx "skopeo inspect --authfile $AUTH_FILE --format {{.Digest}} docker://$IMAGE:$VERSION" "$WORK/commands"
grep -Fqx "DOCKER_CONFIG=$(dirname -- "$AUTH_FILE") cosign verify --key $ROOT_DIR/cosign.pub $IMAGE@$DIGEST" "$WORK/commands"
grep -Fq "skopeo copy --src-authfile $AUTH_FILE --policy " "$WORK/commands"
```

Add negative cases:

```bash
cp "$AUTH_FILE" "$WORK/auth.json"
run_case "non-config.json auth file is rejected" failure \
    "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$WORK/auth.json"
TAG_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    run_case "version tag digest mismatch is rejected" failure \
    "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
```

- [ ] **Step 2: Run the verifier fixture and verify RED**

Run: `./test/bootc-secure-publication-test.sh`

Expected: nonzero because the first Skopeo inspect lacks `--authfile`, and the new explicit-auth assertions fail before production edits.

- [ ] **Step 3: Implement exact auth and version-tag binding in the verifier**

After the regular-file check in `verify-published-image.sh`, add:

```bash
if [[ ${AUTH_FILE##*/} != config.json ]]; then
    printf 'source registry auth file must be named config.json\n' >&2
    exit 2
fi
```

Replace the ambient metadata read and add tag binding:

```bash
inspection=$(skopeo inspect --authfile "$AUTH_FILE" \
    "docker://$IMAGE@$EXPECTED_DIGEST")

tag_digest=$(skopeo inspect --authfile "$AUTH_FILE" --format '{{.Digest}}' \
    "docker://$IMAGE:$VERSION_TAG")
if [[ $tag_digest != "$EXPECTED_DIGEST" ]]; then
    printf 'version tag resolved to %s instead of %s\n' \
        "$tag_digest" "$EXPECTED_DIGEST" >&2
    exit 1
fi
```

Replace ambient Cosign verification with the pinned-v2.6.1 keychain binding:

```bash
auth_dir=$(dirname -- "$AUTH_FILE")
DOCKER_CONFIG=$auth_dir cosign verify --key "$ROOT_DIR/cosign.pub" \
    "$IMAGE@$EXPECTED_DIGEST" >/dev/null
```

Retain root policy copy unchanged with source-only `--src-authfile`.

- [ ] **Step 4: Run the verifier fixture and verify GREEN**

Run: `./test/bootc-secure-publication-test.sh`

Expected: exit 0; explicit digest inspect, tag inspect, Cosign config, tag mismatch, and existing fail-closed cases pass.

- [ ] **Step 5: Add failing guard mutations for each newly required verifier control**

Update the guard fixture's verifier text to include the production lines, then add these mutation functions to `test/bootc-publication-guard-test.sh`:

```bash
remove_digest_inspect_auth() {
    perl -0pi -e 's/skopeo inspect --authfile "\$AUTH_FILE"/skopeo inspect/' \
        "$1/shared/bootc-secure/ci/verify-published-image.sh"
}
remove_cosign_docker_config() {
    perl -0pi -e 's/DOCKER_CONFIG=\$auth_dir cosign/cosign/' \
        "$1/shared/bootc-secure/ci/verify-published-image.sh"
}
remove_tag_binding() {
    perl -0pi -e 's/^tag_digest=.*?^fi\n//ms' \
        "$1/shared/bootc-secure/ci/verify-published-image.sh"
}
```

Add one `assert_guard ... expected 1` call per mutation.

- [ ] **Step 6: Run the guard suite and verify RED**

Run: `./test/bootc-publication-guard-test.sh`

Expected: nonzero because the existing guard does not reject at least one new mutation.

- [ ] **Step 7: Enforce verifier auth and tag binding in the static guard**

Add exact `require_text` markers in `check-bootc-publication-guard.sh`. Use a
literal here-document for the line containing nested single quotes:

```bash
'inspection=$(skopeo inspect --authfile "$AUTH_FILE" \'
'if [[ $tag_digest != "$EXPECTED_DIGEST" ]]; then'
'DOCKER_CONFIG=$auth_dir cosign verify --key "$ROOT_DIR/cosign.pub" \'
'sudo skopeo copy --src-authfile "$AUTH_FILE" \'

tag_inspect_line=$(cat <<'EOF'
tag_digest=$(skopeo inspect --authfile "$AUTH_FILE" --format '{{.Digest}}' \
EOF
)
require_text "$verifier tag inspect auth" "$verifier_text" "$tag_inspect_line"
```

Use shell quoting that preserves each marker byte-for-byte; verify each marker against the real file before accepting the guard.

- [ ] **Step 8: Run Task 1 validation**

```bash
./test/bootc-secure-publication-test.sh
./test/bootc-publication-guard-test.sh
./check-bootc-publication-guard.sh
shellcheck -S warning -x \
  shared/bootc-secure/ci/verify-published-image.sh \
  test/bootc-secure-publication-test.sh \
  check-bootc-publication-guard.sh \
  test/bootc-publication-guard-test.sh
git diff --check
```

Expected: all commands exit 0 with no ShellCheck or whitespace diagnostics.

- [ ] **Step 9: Commit Task 1**

```bash
git add \
  shared/bootc-secure/ci/verify-published-image.sh \
  test/bootc-secure-publication-test.sh \
  check-bootc-publication-guard.sh \
  test/bootc-publication-guard-test.sh
git commit -m "fix: authenticate all bootc verifier reads"
```

### Task 2: Fixture-Test Explicit-Auth Promotion

**Files:**
- Create: `shared/bootc-secure/ci/promote-published-image.sh`
- Create: `test/bootc-secure-promotion-test.sh`
- Modify: `.github/workflows/build-images.yml:274-327`
- Modify: `check-bootc-publication-guard.sh`
- Modify: `test/bootc-publication-guard-test.sh`
- Modify: `.github/workflows/validate.yml`
- Modify: `.github/workflows/test-bootc-secure.yml`
- Modify: `.github/workflows/bootc-secure-nightly.yml`

**Interfaces:**
- Consumes: a verified `ghcr.io/frostyard/{cayo,snow,snowfield}@sha256:...` digest and Docker `config.json` after policy-copied artifact validation.
- Produces: `latest` resolving to the exact supplied digest, or a nonzero fail-closed result.

- [ ] **Step 1: Write the failing promotion fixture**

Create `test/bootc-secure-promotion-test.sh` with `set -euo pipefail`, pass/fail counters, a temporary `bin/skopeo` stub, and these cases:

```bash
IMAGE=ghcr.io/frostyard/cayo
DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
AUTH_FILE="$WORK/config.json"
printf '{"auths":{}}\n' >"$AUTH_FILE"
```

The stub must reject copy unless all exact fragments are present:

```bash
--all
--src-authfile $AUTH_FILE
--dest-authfile $AUTH_FILE
docker://$IMAGE@$DIGEST
docker://$IMAGE:latest
```

It must reject inspect unless it contains:

```bash
--authfile $AUTH_FILE
--format {{.Digest}}
docker://$IMAGE:latest
```

Positive and negative assertions cover success, malformed repository, malformed digest, missing auth file, directory auth path, non-`config.json` auth file, copy failure, inspect failure, and latest digest mismatch.

- [ ] **Step 2: Run the promotion fixture and verify RED**

Run: `./test/bootc-secure-promotion-test.sh`

Expected: nonzero because `shared/bootc-secure/ci/promote-published-image.sh` does not exist.

- [ ] **Step 3: Implement the minimal promotion helper**

Create executable `shared/bootc-secure/ci/promote-published-image.sh`:

```bash
#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

if [[ $# -ne 3 ]]; then
    printf 'usage: %s IMAGE EXPECTED_DIGEST AUTH_FILE\n' "${0##*/}" >&2
    exit 2
fi

IMAGE=$1
EXPECTED_DIGEST=$2
AUTH_FILE=$3

if [[ ! $IMAGE =~ ^ghcr\.io/frostyard/(cayo|snow|snowfield)$ ]] ||
        [[ ! $EXPECTED_DIGEST =~ ^sha256:[a-f0-9]{64}$ ]]; then
    printf 'invalid secure image reference\n' >&2
    exit 2
fi
if [[ ! -f $AUTH_FILE || ${AUTH_FILE##*/} != config.json ]]; then
    printf 'registry auth must be a regular config.json file\n' >&2
    exit 2
fi

skopeo copy --all \
    --src-authfile "$AUTH_FILE" --dest-authfile "$AUTH_FILE" \
    "docker://$IMAGE@$EXPECTED_DIGEST" "docker://$IMAGE:latest"

latest_digest=$(skopeo inspect --authfile "$AUTH_FILE" \
    --format '{{.Digest}}' "docker://$IMAGE:latest")
if [[ $latest_digest != "$EXPECTED_DIGEST" ]]; then
    printf 'latest resolved to %s instead of %s\n' \
        "$latest_digest" "$EXPECTED_DIGEST" >&2
    exit 1
fi
```

Run:

```bash
chmod +x \
  shared/bootc-secure/ci/promote-published-image.sh \
  test/bootc-secure-promotion-test.sh
```

- [ ] **Step 4: Run the promotion fixture and verify GREEN**

Run: `./test/bootc-secure-promotion-test.sh`

Expected: exit 0 with every positive and negative assertion passing.

- [ ] **Step 5: Replace inline promotion and strengthen workflow ordering**

In `.github/workflows/build-images.yml`, replace the inline Skopeo block with:

```yaml
        run: |
          AUTH_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
          ./shared/bootc-secure/ci/promote-published-image.sh \
            "$IMAGE" "${{ steps.push.outputs.digest }}" "$AUTH_FILE"
```

Correct the signing comment to state that Docker login credentials are passed
explicitly to verification and promotion; pinned Cosign signing itself remains
the already-working user-context operation.

In the guard's ordered steps, require:

```bash
'Push immutable version tag'
'Log in to ghcr.io'
'Sign immutable image digest'
'Verify pushed secure image'
'Validate policy-copied secure artifact'
'Promote validated digest to latest'
```

Require the exact pinned `docker/login-action` in the login step and exact promotion-helper invocation with `AUTH_FILE`.

- [ ] **Step 6: Add promotion and login-order guard mutations, then verify RED**

Extend the guard fixture with the login step, helper call, and helper source. Add mutations that remove login, move login after verification, remove helper source auth, remove helper destination auth, remove helper inspect auth, and replace helper invocation with inline `skopeo copy`.

Run: `./test/bootc-publication-guard-test.sh`

Expected: nonzero before the production guard learns every new mutation.

- [ ] **Step 7: Wire the promotion fixture into all contract workflows**

Add `./test/bootc-secure-promotion-test.sh` beside the existing publication fixture in:

```text
.github/workflows/validate.yml
.github/workflows/test-bootc-secure.yml
.github/workflows/bootc-secure-nightly.yml
```

Do not add it to live/full-window jobs; it is network-free fixture coverage.

- [ ] **Step 8: Run Task 2 validation**

```bash
./test/bootc-secure-promotion-test.sh
./test/bootc-secure-publication-test.sh
./test/bootc-publication-guard-test.sh
./check-bootc-publication-guard.sh
actionlint \
  .github/workflows/build-images.yml \
  .github/workflows/validate.yml \
  .github/workflows/test-bootc-secure.yml \
  .github/workflows/bootc-secure-nightly.yml
shellcheck -S warning -x \
  shared/bootc-secure/ci/promote-published-image.sh \
  test/bootc-secure-promotion-test.sh \
  check-bootc-publication-guard.sh \
  test/bootc-publication-guard-test.sh
git diff --check
```

Expected: all commands exit 0 with no actionlint, ShellCheck, or whitespace diagnostics.

- [ ] **Step 9: Commit Task 2**

```bash
git add \
  shared/bootc-secure/ci/promote-published-image.sh \
  test/bootc-secure-promotion-test.sh \
  .github/workflows/build-images.yml \
  .github/workflows/validate.yml \
  .github/workflows/test-bootc-secure.yml \
  .github/workflows/bootc-secure-nightly.yml \
  check-bootc-publication-guard.sh \
  test/bootc-publication-guard-test.sh
git commit -m "fix: authenticate bootc latest promotion"
```

### Task 3: Correct Contracts And Record Deferred Findings

**Files:**
- Modify: `test/bootc-secure-docs-test.sh`
- Modify: `docs/bootc-secure-operations.md`
- Modify: `CLAUDE.md`
- Modify: `yeti/ci-cd.md`

**Interfaces:**
- Consumes: Tasks 1-2 complete explicit-auth verifier and promotion contracts.
- Produces: normative and AI-facing documentation that accurately separates completed auth controls from deferred publication redesign and blocked runtime evidence.

- [ ] **Step 1: Add failing documentation contract strings**

Add these exact single-line strings to `required_strings` in `test/bootc-secure-docs-test.sh`:

```bash
'Every GHCR read and write in secure verification and promotion receives the Docker login config explicitly.'
'Pinned Cosign v2.6.1 receives registry auth through command-scoped DOCKER_CONFIG.'
```

- [ ] **Step 2: Run the docs contract and verify RED**

Run: `./test/bootc-secure-docs-test.sh`

Expected: nonzero because the operations runbook still describes only root Skopeo source auth.

- [ ] **Step 3: Update normative and repository documentation**

In `docs/bootc-secure-operations.md`, add both required sentences on separate physical lines and state:

```markdown
Skopeo inspections use `--authfile`, root policy copy uses source-only
`--src-authfile`, and promotion uses source and destination auth files. Pinned
Cosign has no registry-config flag; its command receives only the config
directory through `DOCKER_CONFIG`. Version-tag resolution must equal the pushed
digest before policy copy.
```

In `CLAUDE.md` and `yeti/ci-cd.md`, replace root-copy-only wording with the same
architecture and record these deferred findings without claiming completion:

```markdown
Deferred publication follow-ups: bind SBOM signing to the exact uploaded
referrer digest, gate Snow release creation on complete metadata publication,
decide whether `latest` moves only after metadata completion, and make general
output cleanup unconditional where retained runners require it.
```

Preserve all existing blocked-live-evidence and unsupported-production wording.

- [ ] **Step 4: Run complete relevant validation**

```bash
./test/bootc-secure-docs-test.sh
./test/bootc-secure-publication-test.sh
./test/bootc-secure-promotion-test.sh
./test/bootc-publication-guard-test.sh
./check-bootc-publication-guard.sh
actionlint \
  .github/workflows/build-images.yml \
  .github/workflows/validate.yml \
  .github/workflows/test-bootc-secure.yml \
  .github/workflows/bootc-secure-nightly.yml
shellcheck -S warning -x \
  shared/bootc-secure/ci/verify-published-image.sh \
  shared/bootc-secure/ci/promote-published-image.sh \
  test/bootc-secure-publication-test.sh \
  test/bootc-secure-promotion-test.sh \
  check-bootc-publication-guard.sh \
  test/bootc-publication-guard-test.sh \
  test/bootc-secure-docs-test.sh
git diff --check
```

Expected: all commands exit 0; both publication fixtures and every guard mutation pass with no lint diagnostics.

- [ ] **Step 5: Review the final diff against protected-run evidence**

Confirm from the diff that:

```text
- no remote verifier or promotion command uses ambient Skopeo auth;
- Cosign verification receives command-scoped DOCKER_CONFIG;
- no credential contents appear in arguments or logs;
- version-tag mismatch fails before policy copy;
- login precedes signing and verification;
- policy-copied validation precedes promotion;
- no SBOM/release redesign or unsupported support claim entered this repair.
```

- [ ] **Step 6: Commit Task 3**

```bash
git add \
  test/bootc-secure-docs-test.sh \
  docs/bootc-secure-operations.md \
  CLAUDE.md \
  yeti/ci-cd.md
git commit -m "docs: record explicit bootc publication auth"
```

- [ ] **Step 7: Request adversarial review before publication**

Request review focused on real command semantics for Skopeo and pinned Cosign,
auth-file scope, version-tag race behavior, promotion mutation safety, guard
fidelity, workflow ordering, and unsupported claims. Address every Critical or
Important finding and rerun Step 4 before opening the PR. After merge, watch all
three protected profiles through policy-copy validation and `latest` promotion;
record exact version tags and digests without treating the run as Task 9 runtime
evidence.
