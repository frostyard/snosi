# Bootc Verifier Registry-Auth Boundary Design

## Problem

Protected `build-images.yml` run `30590168012` proved that Cayo and Snow pass
secure packaging, local artifact validation, protected credential deletion,
chunking, immutable push, and Cosign signing. Both then fail at the root policy
copy in `shared/bootc-secure/ci/verify-published-image.sh`:

```text
error reading credentials: stat /run/user/1001/containers/auth.json: permission denied
```

The preceding user-context Skopeo inspection and Cosign verification succeed.
The failing command is `sudo skopeo copy`. `docker/login-action` creates
user-context registry credentials, while sudo preserves the runner's
`XDG_RUNTIME_DIR=/run/user/1001`. Root-side Skopeo consequently selects an
inaccessible user runtime auth path instead of receiving an explicit source
credential file. This is a registry-auth handoff defect after successful image
assembly and signing; it is not a candidate ukify or artifact defect.

## Decision

Keep the repair local to the remote verifier. Add a fifth `AUTH_FILE` argument
to `verify-published-image.sh`, require it to name an existing regular file, and
pass it to the root policy copy as:

```text
sudo skopeo copy --src-authfile "$AUTH_FILE" ...
```

The workflow supplies the Docker login configuration written by
`docker/login-action`:

```text
${DOCKER_CONFIG:-$HOME/.docker}/config.json
```

The path, not credential contents, crosses the command boundary. Skopeo receives
the credentials only for the immutable `docker://` source; the local
`containers-storage:` destination receives no registry credentials. User-context
Skopeo inspection and Cosign verification remain unchanged.

The verifier must not infer credentials from `XDG_RUNTIME_DIR`, root Buildah
state, or an earlier command's implementation-specific defaults. It must not
place a PAT or username/password pair in process arguments, copy registry
credentials into repository state, or print credential contents.

## Alternatives Rejected

### Unset `XDG_RUNTIME_DIR`

Running root Skopeo with `XDG_RUNTIME_DIR` removed could cause it to discover the
credentials created by the earlier root Buildah login. This is smaller textually
but creates an undocumented dependency between distant workflow steps and their
credential-store defaults.

### Copy Credentials Into Root Runtime State

Copying the Docker configuration under a root runtime directory would work but
duplicates sensitive material and introduces additional ownership, mode, and
cleanup obligations without improving the verifier contract.

### Unify Authentication Across the Publication Job

A single explicit auth file shared by Buildah, Cosign, Skopeo, and promotion
would be coherent but broadens a localized repair across already-working push,
signing, and promotion paths. That additional regression surface is unnecessary.

## Validation

`test/bootc-secure-publication-test.sh` will provide the regression test. Before
the production change, the new assertion must fail because the root policy-copy
command lacks `--src-authfile`. After the change it must prove:

- an accepted immutable secure image is copied with the exact supplied source
  auth path;
- the auth option appears only on the root policy-copy command;
- a missing or non-regular auth file fails before remote copy;
- existing digest, label, Cosign, policy, ordering, and no-promotion assertions
  remain green.

`check-bootc-publication-guard.sh` and its mutation fixtures will require the
workflow verifier step to pass the Docker configuration path and require the
verifier to use an explicit source auth file. ShellCheck, `git diff --check`,
the publication fixture, the publication guard mutation suite, and relevant
documentation tests must pass before another protected run.

## Documentation

Update `CLAUDE.md` and the relevant `yeti/` secure-publication context to record
that root policy-copy verification receives the user login's auth file
explicitly. Existing statements that user-context credentials are simply
"shared" with root Skopeo must be corrected; sudo does not make that boundary
reliable without an explicit source auth path.
