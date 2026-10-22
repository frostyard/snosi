# 0020 — Scope third-party APT sources to the builds that need them

- **Status:** Accepted
- **Date:** 2026-10-21

## Context

mkosi's `SandboxTrees=` is a universal setting. Every image of one mkosi
invocation shares the sandbox and runs one repository metadata sync, and a
subimage under `mkosi.images/` cannot narrow `SandboxTrees=`. The
auto-detected `mkosi.sandbox/` tree therefore applies to every build: all four
bootc OCI profiles and every sysext.

Until this decision, `mkosi.sandbox/etc/apt/sources.list.d/himmelblau.sources`
and its keyring `mkosi.sandbox/etc/apt/keyrings/himmelblau.gpg` sat in that
shared tree, although only the himmelblau sysext installs from
`https://packages.himmelblau-idm.org/stable/latest/deb/debian13`. On
2026-10-21 that repository lost its `Release`/`InRelease` index for about four
hours. `apt-get update` failed with exit 100 in every build: every OCI image
build and every sysext build stopped, although no other image needs himmelblau
packages.

## Decision

- The himmelblau APT source and key move unchanged to
  `shared/himmelblau/sandbox/`, the same `/`-overlay layout, so
  `Signed-By: /etc/apt/keyrings/himmelblau.gpg` stays correct.
- The root `mkosi.conf` no longer lists `himmelblau` in `Dependencies=`.
  himmelblau builds in a second mkosi invocation:
  `mkosi --dependency= --dependency=base --dependency=himmelblau --sandbox-tree=shared/himmelblau/sandbox build`.
  That invocation reuses the existing `output/base` and only its sandbox holds
  the himmelblau source. `just sysexts` and `build.yml` use the same command.
- `build.yml` marks the himmelblau step `continue-on-error: true` and collects
  the outputs of both invocations before publishing. A last step named "Fail
  when the himmelblau sysext did not build" tests
  `steps.himmelblau.outcome == 'failure'`, prints a `::error::` annotation and
  exits 1. The other sysexts publish first; the `build` check still goes red.
- The other third-party sources in `mkosi.sandbox/etc/apt/sources.list.d/`
  (1password, chatgpt, claude-desktop, debian-backports, docker, edge,
  frostyard, linux-surface, tailscale, vscode) stay shared for now. They are
  grandfathered by this decision. A new third-party source must be scoped like
  himmelblau, or added to the allowlist only with an ADR-backed reason.
- `test/third-party-apt-source-scope-test.sh` enforces all of this: the
  shared-sandbox allowlist, the absence of himmelblau from `mkosi.sandbox/`,
  the scoped files, the root `Dependencies=` list, the two workflow steps and
  their order, the `Justfile` `_sysexts` target, and that no other workflow
  passes `--sandbox-tree=shared/himmelblau/sandbox`.

## Consequences

- One mkosi invocation still downloads the himmelblau repository metadata.
  A himmelblau build runs an extra metadata sync compared with the other
  sysexts, and it starts after the first invocation ends.
- A himmelblau repository outage fails the CI `build` check, but the other
  sysexts are built and published first. The failure is visible, not silent.
- OCI image builds no longer depend on the himmelblau repository at all, and
  neither do the other sysexts.
- A local `just sysexts` build no longer fails when the himmelblau repository
  is down before the second invocation starts; the second invocation fails.
- A future third-party source that a reviewer adds to `mkosi.sandbox/` fails
  the guard until it is scoped or allowlisted.

## Alternatives considered

- **Keep the source shared and accept the coupling:** rejected because one
  third-party outage stopped every product and sysext build.
- **Add a per-image `SandboxTrees=`:** not possible; mkosi scopes that setting
  as universal, so a subimage cannot set it.
- **Move every third-party source into its own invocation now:** rejected as a
  much larger change with more metadata syncs; this decision scopes himmelblau,
  the source with recent observed outages, and guards the rest.
- **Let the himmelblau step fail the job immediately:** rejected because the
  other sysexts would then lose their build and publication for that run.

## References

- Shapes: [design/build-pipeline.md](../design/build-pipeline.md),
  [design/sysexts.md](../design/sysexts.md), [design/ci-cd.md](../design/ci-cd.md),
  [himmelblau.md](../himmelblau.md)
- Builds on: [ADR-0004](0004-sysext-authoring-rules.md)
