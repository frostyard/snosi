# Bootc Verifier Registry-Auth Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make protected root Skopeo verification consume the authenticated Docker source explicitly instead of inheriting an inaccessible runner `XDG_RUNTIME_DIR` path.

**Architecture:** `docker/login-action` remains the user-context login authority. The workflow passes its Docker configuration path as a fifth verifier argument, and the verifier validates that file before supplying it only to root Skopeo's immutable registry source through `--src-authfile`; existing inspect, Cosign, policy, root containers-storage, and promotion boundaries remain unchanged.

**Tech Stack:** Bash, GitHub Actions YAML, Skopeo, Cosign, jq, ShellCheck

## Global Constraints

- Keep the repair local to remote verification; do not change working Buildah push, Cosign signing, or promotion authentication.
- The verifier interface is `verify-published-image.sh IMAGE VERSION_TAG EXPECTED_DIGEST LOCAL_REF AUTH_FILE`.
- `AUTH_FILE` must name an existing regular file before any policy copy runs.
- Pass credentials only as `sudo skopeo copy --src-authfile "$AUTH_FILE"`; never put a PAT or `username:password` in process arguments.
- Do not infer root credentials from `XDG_RUNTIME_DIR`, root Buildah state, or earlier command defaults.
- Do not print or copy credential contents into repository state.
- Preserve immutable digest verification, exact secure labels, Cosign verification, restrictive policy copy, root containers-storage destination, and validation-before-`latest` ordering.
- A protected workflow pass is one candidate set, not installed-system Task 9 evidence or distinct N/N+1/N+2 evidence.

---

### Task 1: Explicit Registry-Auth Handoff

**Files:**
- Modify: `test/bootc-secure-publication-test.sh:8-130`
- Modify: `shared/bootc-secure/ci/verify-published-image.sh:10-56`
- Modify: `.github/workflows/build-images.yml:286-302`
- Modify: `test/bootc-publication-guard-test.sh:44-167`
- Modify: `check-bootc-publication-guard.sh:171-205`

**Interfaces:**
- Consumes: Docker-compatible auth JSON written at `${DOCKER_CONFIG:-$HOME/.docker}/config.json` by `docker/login-action`.
- Produces: `verify-published-image.sh IMAGE VERSION_TAG EXPECTED_DIGEST LOCAL_REF AUTH_FILE`, which imports the signed immutable source into root containers-storage using that exact source auth file.

- [ ] **Step 1: Add a failing verifier fixture for the explicit source auth file**

In `test/bootc-secure-publication-test.sh`, add an auth-file variable, create a harmless fixture after `WORK` is initialized, pass it as the fifth helper argument, and require the policy copy to carry it:

```bash
AUTH_FILE=""

run_helper() { # image version digest local-ref auth-file
    local output status
    set +e
    output=$(PATH="$WORK/bin:$PATH" COMMAND_LOG="$WORK/commands" COPIED_POLICY="$WORK/copied-policy.json" "$HELPER" "$@" 2>&1)
    status=$?
    set -e
    printf '%s\n%s\n' "$status" "$output"
}

run_case() { # description expected-status image version digest local-ref auth-file
    local result status output
    : >"$WORK/commands"
    result=$(run_helper "$3" "$4" "$5" "$6" "$7")
    status=${result%%$'\n'*}
    output=${result#*$'\n'}
    if [[ $2 == success ]]; then
        assert_success "$1" "$status" "$output"
    else
        assert_failure "$1" "$status" "$output"
    fi
}

WORK=$(mktemp -d)
mkdir -p "$WORK/bin"
AUTH_FILE="$WORK/auth.json"
printf '{"auths":{}}\n' >"$AUTH_FILE"
```

Update every existing `run_case` invocation to append `"$AUTH_FILE"`. After the accepted-image command assertions, add:

```bash
grep -Fq "skopeo copy --src-authfile $AUTH_FILE --policy " "$WORK/commands" &&
        pass "root policy copy receives the explicit source auth file" ||
        fail "root policy copy receives the explicit source auth file"
if ! sed -n '1,2p' "$WORK/commands" | grep -Fq -- '--src-authfile'; then
    pass "inspect and Cosign do not receive the root copy auth option"
else
    fail "inspect and Cosign do not receive the root copy auth option"
fi
run_case "missing source auth file is rejected" failure \
    "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$WORK/missing-auth.json"
run_case "non-regular source auth path is rejected" failure \
    "$IMAGE" "$VERSION" "$DIGEST" "$LOCAL_REF" "$WORK"
```

- [ ] **Step 2: Run the verifier fixture and verify the new assertion fails for the intended reason**

Run:

```bash
./test/bootc-secure-publication-test.sh
```

Expected: nonzero with `not ok - root policy copy receives the explicit source auth file`; the existing helper still accepts only four arguments and therefore cannot satisfy the new contract.

- [ ] **Step 3: Implement the minimal verifier and workflow handoff**

In `shared/bootc-secure/ci/verify-published-image.sh`, change argument parsing to:

```bash
if [[ $# -ne 5 ]]; then
    printf 'usage: %s IMAGE VERSION_TAG EXPECTED_DIGEST LOCAL_REF AUTH_FILE\n' "${0##*/}" >&2
    exit 2
fi

IMAGE=$1
VERSION_TAG=$2
EXPECTED_DIGEST=$3
LOCAL_REF=$4
AUTH_FILE=$5

if [[ ! -f $AUTH_FILE ]]; then
    printf 'source registry auth file is not a regular file\n' >&2
    exit 2
fi
```

Change only the policy-copy invocation:

```bash
sudo skopeo copy --src-authfile "$AUTH_FILE" \
    --policy "$work/policy.json" --registries.d "$work/registries.d" \
    "docker://$IMAGE@$EXPECTED_DIGEST" "containers-storage:$LOCAL_REF"
```

In `.github/workflows/build-images.yml`, replace the verifier's one-line `run` with:

```yaml
        run: |
          AUTH_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
          ./shared/bootc-secure/ci/verify-published-image.sh \
            "$IMAGE" "$VERSION_TAG" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
```

Correct the comment above signing so it no longer claims credentials are implicitly shared with root Skopeo:

```yaml
        # docker/login-action writes the user-context registry credentials used
        # directly by Cosign and passed explicitly to root Skopeo verification.
```

- [ ] **Step 4: Run the verifier fixture and verify it passes**

Run:

```bash
./test/bootc-secure-publication-test.sh
```

Expected: exit 0; all prior checks plus the explicit-auth and missing-auth checks pass.

- [ ] **Step 5: Add failing publication-guard mutations for both halves of the handoff**

Update the fixture verifier in `test/bootc-publication-guard-test.sh` to include the required command text:

```bash
sudo skopeo copy --src-authfile "$AUTH_FILE" \
    "docker://$IMAGE@$EXPECTED_DIGEST" "containers-storage:$LOCAL_REF"
```

Update its workflow fixture to use the exact approved call:

```yaml
      - name: Verify pushed secure image
        run: |
          AUTH_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
          ./shared/bootc-secure/ci/verify-published-image.sh \
            "$IMAGE" "$VERSION_TAG" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
```

Add mutations and assertions:

```bash
remove_workflow_auth_handoff() {
    perl -0pi -e 's/^          AUTH_FILE=.*\n//m; s/ "\$AUTH_FILE"\n/\n/' \
        "$1/.github/workflows/build-images.yml"
}
remove_verifier_src_authfile() {
    perl -0pi -e 's/ --src-authfile "\$AUTH_FILE"//' \
        "$1/shared/bootc-secure/ci/verify-published-image.sh"
}

assert_guard 'missing workflow auth handoff fails' 1 remove_workflow_auth_handoff
assert_guard 'missing verifier source auth option fails' 1 remove_verifier_src_authfile
```

- [ ] **Step 6: Run the guard mutation suite and verify RED**

Run:

```bash
./test/bootc-publication-guard-test.sh
```

Expected: nonzero because at least one new mutation unexpectedly passes the existing guard.

- [ ] **Step 7: Enforce the explicit handoff in the production guard**

In `check-bootc-publication-guard.sh`, extend the `verifier_step` checks:

```bash
        require_text "$workflow secure verifier auth path" \
            "$verifier_step" '          AUTH_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"'
        require_text "$workflow secure verifier auth argument" \
            "$verifier_step" '            "$IMAGE" "$VERSION_TAG" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"'
```

Extend the verifier file checks:

```bash
    require_text "$verifier" "$verifier_text" \
        'sudo skopeo copy --src-authfile "$AUTH_FILE" \'
```

- [ ] **Step 8: Run focused tests and static validation**

Run:

```bash
./test/bootc-secure-publication-test.sh
./test/bootc-publication-guard-test.sh
./check-bootc-publication-guard.sh
actionlint .github/workflows/build-images.yml
shellcheck -S warning -x \
  shared/bootc-secure/ci/verify-published-image.sh \
  test/bootc-secure-publication-test.sh \
  check-bootc-publication-guard.sh \
  test/bootc-publication-guard-test.sh
git diff --check
```

Expected: every command exits 0; the guard mutation suite reports 31 passing assertions and 0 failures.

- [ ] **Step 9: Commit the atomic auth handoff**

```bash
git add \
  .github/workflows/build-images.yml \
  shared/bootc-secure/ci/verify-published-image.sh \
  test/bootc-secure-publication-test.sh \
  check-bootc-publication-guard.sh \
  test/bootc-publication-guard-test.sh
git commit -m "fix: pass registry auth to bootc verifier"
```

### Task 2: Operational Contract And Final Verification

**Files:**
- Modify: `test/bootc-secure-docs-test.sh:28-48`
- Modify: `docs/bootc-secure-operations.md:42-54`
- Modify: `CLAUDE.md:166-180`
- Modify: `yeti/ci-cd.md:197-219`

**Interfaces:**
- Consumes: Task 1's explicit `AUTH_FILE` verifier contract.
- Produces: Normative and AI-context documentation that no longer requires public GHCR visibility solely because root Skopeo lacked authentication.

- [ ] **Step 1: Add a failing documentation-contract assertion**

Add this exact string to `required_strings` in `test/bootc-secure-docs-test.sh`:

```bash
    'Root Skopeo receives the Docker login auth file explicitly through --src-authfile.'
```

- [ ] **Step 2: Run the documentation contract and verify RED**

Run:

```bash
./test/bootc-secure-docs-test.sh
```

Expected: nonzero because `docs/bootc-secure-operations.md` does not yet contain the required statement.

- [ ] **Step 3: Update normative and repository-context documentation**

Replace the obsolete public-GHCR caveat in `docs/bootc-secure-operations.md` with:

```markdown
Root Skopeo receives the Docker login auth file explicitly through --src-authfile.
Do not rely on inherited `XDG_RUNTIME_DIR`, root Buildah
credentials, or registry visibility as the authentication mechanism for the
policy-copy gate.
```

Add this operational fact to the Task 10 paragraph in `CLAUDE.md`:

```markdown
The remote verifier passes Docker login's auth file explicitly to root Skopeo
as source-only authentication; it never relies on sudo preserving a usable
user runtime auth path or on root Buildah's credential-store defaults.
```

Extend `yeti/ci-cd.md` immediately after the protected publication paragraph:

```markdown
The workflow's `docker/login-action` credentials serve user-context Cosign and
are passed by path to the verifier. Root Skopeo receives that file only through
`--src-authfile` for the immutable registry source; its local
`containers-storage:` destination receives no registry credentials. Do not
infer this handoff from `XDG_RUNTIME_DIR` or root Buildah login state.
```

- [ ] **Step 4: Run documentation and full relevant validation**

Run:

```bash
./test/bootc-secure-docs-test.sh
./test/bootc-secure-publication-test.sh
./test/bootc-publication-guard-test.sh
./check-bootc-publication-guard.sh
actionlint .github/workflows/build-images.yml
shellcheck -S warning -x \
  shared/bootc-secure/ci/verify-published-image.sh \
  test/bootc-secure-publication-test.sh \
  check-bootc-publication-guard.sh \
  test/bootc-publication-guard-test.sh \
  test/bootc-secure-docs-test.sh
git diff --check
```

Expected: every command exits 0 with no actionlint or ShellCheck diagnostics; the publication guard reports 31 passing assertions and the docs test prints `Bootc secure operations documentation validation passed`.

- [ ] **Step 5: Review the final diff for secret and scope safety**

Run:

```bash
git diff --check
git diff --stat HEAD~1
git status --short
```

Inspect the diff and confirm it contains no PAT, username/password pair, copied auth JSON, unrelated refactor, production-support claim, or modification outside the files listed by Tasks 1 and 2 plus this plan/spec history.

- [ ] **Step 6: Commit documentation**

```bash
git add \
  test/bootc-secure-docs-test.sh \
  docs/bootc-secure-operations.md \
  CLAUDE.md \
  yeti/ci-cd.md
git commit -m "docs: record bootc verifier auth boundary"
```

- [ ] **Step 7: Request review before protected execution**

Request an adversarial review focused on credential scope, sudo boundary behavior, fail-closed validation, publication ordering, fixture fidelity, and unsupported support claims. Address findings with the same red-green discipline, then rerun Step 4 before opening a PR or triggering another protected build.
