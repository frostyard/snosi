# 0011 — Bootstrap mkosi from a repo-local checkout pinned to the workflow's commit

- **Status:** Accepted
- **Date:** 2026-08-12

## Context

Image output depends on the exact mkosi commit: a local build on a distro
mkosi and a CI build on the pinned `systemd/mkosi` action can produce
different images from the same tree, and the mkosi commit is effectively
part of the published image contract. Maintaining the pin in two places
(workflow and local tooling) invites the copy-paste defect where one is
bumped and the other is not.

## Decision

mkosi runs from a repo-local, gitignored `.mkosi/` checkout, bootstrapped by
the single implementation `shared/native-ab/ci/bootstrap-mkosi.sh` — used by
both the Justfile and CI. The pin has one source of truth: the script greps
`systemd/mkosi@<sha>` out of `.github/workflows/build.yml` and checks out
that commit; there is no second recorded pin to drift.

`shared/native-ab/ci/check-mkosi-pin.sh` enforces the scheme: the pin must
be a full 40-character SHA (short SHAs, branches, and tags are rejected —
the commit is part of the published image contract);
`build-native-images.yml` must not carry a *conflicting* `systemd/mkosi@`
pin; and an existing `.mkosi/` checkout's HEAD must equal the pin (absent
checkout is a skip, not a failure). CI runs bootstrap+check pairs in every
build job plus a standalone pin-check job.

In the Justfile, every public target depends on `ensure-mkosi` *before* its
`sudo` line — the bootstrap runs as the invoking user so the checkout is not
root-owned. Scripts prefer `.mkosi/bin/mkosi` over any `mkosi` on `PATH`
(`check-profile-dependencies.sh`), and
`test/check-profile-dependencies-local-mkosi-test.sh` proves the local
checkout wins by planting a poisoned `PATH` mkosi.

## Consequences

- Local and CI builds are bit-for-bit on the same mkosi by construction;
  "works locally, differs in CI" ceases to be a config-resolution suspect.
- Bumping mkosi is one edit (the `build.yml` action pin); everything else
  follows, and the pin-check fails any workflow that reintroduces a second
  divergent pin.
- The full-SHA requirement trades convenience for reproducibility: no
  tracking a branch, ever.
- Pre-sudo bootstrap keeps `.mkosi/` user-owned, so `git` operations and
  re-bootstraps never need elevation and never litter root-owned files in
  the tree.
- Developers pay a one-time clone of the mkosi repo per checkout; the
  bootstrap is idempotent and short-circuits when HEAD already matches.

## Alternatives considered

- **Distro/pip-installed mkosi:** rejected — version skew against CI is
  invisible until an image differs.
- **Recording the pin in its own file (e.g. `.mkosi-version`):** rejected —
  a second source of truth that the workflow could disagree with; the
  workflow's action pin is the one CI actually executes, so it is the
  truth.
- **Git submodule:** rejected — submodules require every clone and CI job
  to manage init/update state, and root-invoked builds would still need the
  ownership care the pre-sudo bootstrap gives for free.

## References

- Shapes: [design/ci-cd.md](../design/ci-cd.md),
  [design/overview.md](../design/overview.md),
  [plans/2026-07-14-bootc-native-ab-coexistence-plan.md](../plans/2026-07-14-bootc-native-ab-coexistence-plan.md)
  (Mkosi Pin Governance)
- Implemented by: `shared/native-ab/ci/bootstrap-mkosi.sh`, `Justfile`
  (`ensure-mkosi`), `.github/workflows/build.yml` (the authoritative pin)
- Guarded by: `shared/native-ab/ci/check-mkosi-pin.sh`
  (`.github/workflows/build-native-images.yml`,
  `.github/workflows/native-nightly.yml`),
  `test/check-profile-dependencies-local-mkosi-test.sh`
- Builds on: [core ADR-0021 — SHA-pinned actions and least-privilege CI](https://github.com/frostyard/core/blob/main/docs/adr/0021-sha-pinned-actions-and-least-privilege-ci.md),
  [core ADR-0023 — verified pinned downloads](https://github.com/frostyard/core/blob/main/docs/adr/0023-verified-pinned-downloads.md)
