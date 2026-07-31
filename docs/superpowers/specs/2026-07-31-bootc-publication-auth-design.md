# Bootc Publication Explicit-Auth Design

## Problem

Protected `build-images.yml` run `30594624886` proved that Cayo, Snow, and
Snowfield all pass secure assembly, local artifact validation, protected-key
deletion, immutable-digest push, Docker login, and Cosign signing. All three
then fail at the first command in `verify-published-image.sh`:

```text
reading JSON file "/run/user/1001/containers/auth.json": permission denied
```

The workflow passes
`${DOCKER_CONFIG:-$HOME/.docker}/config.json` to the verifier, but only the
later root `skopeo copy` receives it through `--src-authfile`. The initial
user-context `skopeo inspect` still performs ambient containers/image auth
discovery and aborts before root policy copy runs. No policy-copied artifact
validation or `latest` promotion ran.

The same incomplete auth contract remains in adjacent remote operations:
Cosign verification uses its default keychain, while `latest` promotion uses
ambient Skopeo auth for both registry endpoints and its confirming inspect.
Leaving those boundaries implicit would risk another long protected-run
failure after fixing only the observed inspect.

## Scope

This repair closes the protected publication critical path:

- every verifier registry read receives the supplied Docker auth config
  explicitly;
- the version tag is bound to the expected immutable digest before policy
  copy;
- every `latest` promotion registry read and write receives the same auth
  config explicitly;
- login ordering, auth flags, tag binding, and promotion behavior are enforced
  by positive and mutation fixtures.

The broader publication audit also found that SBOM discovery selects the last
matching referrer instead of the exact artifact just uploaded, Snow release
gating precedes some metadata completion, and general output cleanup is not
unconditional. Those are real follow-ups but are intentionally excluded from
this critical-path repair to avoid combining a publication transaction
redesign with the immediate authentication fix.

## Auth Contract

`AUTH_FILE` remains the fifth argument to
`verify-published-image.sh IMAGE VERSION_TAG EXPECTED_DIGEST LOCAL_REF AUTH_FILE`.
It must be an existing regular file named `config.json`; this matches the
Docker-compatible file written by the pinned `docker/login-action`. Only its
path crosses command boundaries. Credential contents, usernames, passwords,
and tokens never enter command arguments, logs, repository state, outputs, or
retained temporary state.

Every verifier command that contacts GHCR uses that same authority:

```bash
inspection=$(skopeo inspect --authfile "$AUTH_FILE" \
    "docker://$IMAGE@$EXPECTED_DIGEST")

tag_digest=$(skopeo inspect --authfile "$AUTH_FILE" --format '{{.Digest}}' \
    "docker://$IMAGE:$VERSION_TAG")

DOCKER_CONFIG=$(dirname "$AUTH_FILE") \
    cosign verify --key "$ROOT_DIR/cosign.pub" \
    "$IMAGE@$EXPECTED_DIGEST" >/dev/null

sudo skopeo copy --src-authfile "$AUTH_FILE" \
    --policy "$work/policy.json" --registries.d "$work/registries.d" \
    "docker://$IMAGE@$EXPECTED_DIGEST" "containers-storage:$LOCAL_REF"
```

The verifier rejects a version tag whose resolved digest differs from
`EXPECTED_DIGEST`. This detects collision or concurrent replacement at the
validation boundary. It does not claim that GHCR enforces immutable tags after
validation; registry-side tag immutability remains a separate control.

Pinned Cosign v2.6.1 has no `--registry-config` flag. Its
`options.RegistryOptions` uses `authn.DefaultKeychain`, which honors
`DOCKER_CONFIG`. Command-scoped `DOCKER_CONFIG` is therefore the maintained
explicit path for Cosign verification. Requiring `AUTH_FILE` to be named
`config.json` makes the mapping unambiguous and fail-closed. Do not replace it
with `--registry-username`, `--registry-password`, or another secret-bearing
argument.

## Promotion Helper

Move the inline `latest` mutation into a focused helper under
`shared/bootc-secure/ci/`. It accepts exactly:

```text
promote-published-image.sh IMAGE EXPECTED_DIGEST AUTH_FILE
```

It validates the repository, digest, and regular `config.json` auth file, then
runs:

```bash
skopeo copy --all \
    --src-authfile "$AUTH_FILE" --dest-authfile "$AUTH_FILE" \
    "docker://$IMAGE@$EXPECTED_DIGEST" "docker://$IMAGE:latest"

latest_digest=$(skopeo inspect --authfile "$AUTH_FILE" \
    --format '{{.Digest}}' "docker://$IMAGE:latest")
```

The helper fails unless `latest_digest` equals `EXPECTED_DIGEST`. It performs
no signing, policy copy, local-storage access, SBOM upload, or release action.
It runs only after policy-copied artifact validation. Source and destination
auth are explicit because both endpoints are remote GHCR references.

## Workflow Ordering

The protected publication order is:

1. push the version tag and record its digest;
2. run `docker/login-action`;
3. sign the immutable digest;
4. verify digest metadata, version-tag binding, Cosign signature, and policy
   copy with explicit auth;
5. validate policy-copied bytes from root containers-storage;
6. promote the validated digest through the explicit-auth helper;
7. continue existing SBOM, provenance, manifest, and release steps.

The static guard must include `Log in to ghcr.io` in this ordered sequence and
require the pinned login action to remain before signing and every consumer of
its config. A failed auth read, tag-binding check, signature check, policy copy,
artifact validation, promotion copy, or post-copy digest check prevents all
later publication steps for that profile.

## Testing

The verifier fixture must stop treating auth as command-shape decoration.
Skopeo and Cosign stubs reject each remote operation unless it receives the
exact supplied authority:

- digest inspect requires `--authfile AUTH_FILE`;
- version-tag inspect requires `--authfile AUTH_FILE` and returns the expected
  digest only in the positive case;
- Cosign verify requires command-scoped `DOCKER_CONFIG` equal to the auth
  file's parent directory;
- root policy copy requires `--src-authfile AUTH_FILE` and no destination auth
  option.

Negative cases cover omitted or wrong auth paths, a missing auth file, a
directory, a non-`config.json` filename, version-tag digest mismatch, failed
Cosign verification, and failed policy copy.

A new promotion fixture exercises the real helper with Skopeo stubbed only at
the registry boundary. It requires explicit source and destination auth on
copy, explicit auth on confirming inspect, immutable digest source, `latest`
destination, exact post-copy digest equality, and rejection of malformed
inputs and command failures.

The publication guard and mutation suite require:

- workflow auth-file derivation and verifier handoff;
- explicit auth on both verifier inspections, Cosign's command-scoped
  `DOCKER_CONFIG`, and root policy copy;
- version-tag-to-digest comparison;
- login ordering before signing and verification;
- invocation of the promotion helper after policy-copied validation;
- explicit source/destination/inspect auth inside the promotion helper;
- no promotion or mutable-tag operation inside the verifier.

ShellCheck, actionlint, documentation contracts, publication fixtures, guard
mutations, and `git diff --check` must pass before another protected run. The
next protected run remains the only live proof that the hosted runner's Docker
config is directly consumable by Skopeo in both user and root contexts and by
Cosign v2.6.1.

## Documentation

Update `CLAUDE.md`, `docs/bootc-secure-operations.md`, and `yeti/ci-cd.md` to
replace the obsolete root-copy-only statement with the complete explicit-auth
contract. Preserve the existing unsupported status: a successful protected
publication is one candidate set, not Task 9 install/update/rollback/recovery
evidence, not distinct N/N+1/N+2 evidence, and not Snowfield hardware proof.

Record the deferred SBOM identity, metadata ordering, release gating, and
cleanup findings as publication follow-ups without representing them as part
of this repair or as completed controls.
