# Podman runc CI Override Design

## Problem

GitHub's `ubuntu-24.04` runner image changed from `20260720.247.2` to
`20260726.254.1` and upgraded its preinstalled Podman from 4.9.3 to 5.8.4.
Snosi's Snow mechanics build and independent Fisherman jobs that landed on the
new image fail at `podman run` with:

```text
Error: OCI runtime error: crun: unknown version specified
```

Comparable jobs on `20260720.247.2` pass. Snosi image assembly completes before
the error, and cayo and snowfield jobs on the older runner image pass, so image
profile content is not the source of the failure.

## Design

Both `secure-build` and `mechanics-build` in
`.github/workflows/build-images.yml` will configure the ephemeral runner's
Podman engine to use `runc`. Each job will write a dedicated
`/etc/containers/containers.conf.d/99-snosi-ci-runtime.conf` drop-in containing:

```toml
[engine]
runtime = "runc"
```

The step will immediately query `podman info` and fail unless Podman reports
`runc` as the selected OCI runtime. The override belongs at job scope instead
of only on the smoke-test command because secure UKI assembly and image
chunking invoke `podman run` inside repository scripts.

The change affects only the disposable GitHub Actions host. It does not alter
the OCI image, installed-system container runtime defaults, or the supported
bootc installation path.

## Alternatives Rejected

- Adding `--runtime=runc` only to the smoke tests leaves nested Podman calls in
  secure assembly and chunking exposed to the same hosted-runner regression.
- Waiting for a runner-image update leaves required Snosi CI blocked and makes
  future runs depend on nondeterministic hosted-image rollout.
- Pinning the hosted runner image is not supported by GitHub's
  `ubuntu-latest`/`ubuntu-24.04` labels.

## Verification

1. Validate workflow syntax and repository static checks.
2. Confirm an existing Snosi OCI image starts with the host's `runc` runtime.
3. Push the workflow update and require all three `mechanics-build` matrix jobs
   to pass on the current hosted runner image.
4. Confirm protected secure-build behavior remains unchanged except for the
   selected host OCI runtime.

## Documentation

Record the job-scoped runtime selection in `yeti/ci-cd.md` and the CI summary
in `CLAUDE.md`. `README.md` needs no change because this is an internal hosted
CI compatibility measure with no user-facing behavior.
