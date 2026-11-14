# 0038 — Publish signed forky test images under forky-<timestamp> tags

- **Status:** Accepted
- **Date:** 2026-11-13

## Context

[ADR-0037](0037-build-forky-as-a-second-suite.md) made the Debian release a
build input: `mkosi --release forky` builds the Floe composition on Debian
testing beside the unchanged trixie default. It left publication of forky
images out, and said that it needs its own decision.

Phase 6 of [core plan 0009](https://github.com/frostyard/core/blob/main/docs/plans/0009-debian-publication-through-apt-publisher.md)
needs the lab to prove install, update and rollback on forky. The lab can do
that only with signed images: a secure bootc install and update verify each
image against the repository's signature policy, so the lab needs two signed
forky digests, N and N+1, of the same product.

The forky secure contract copy
(`shared/bootc-secure/suite/forky/tree/usr/lib/snosi/bootc-secure.json`)
differs from the trixie contract only in its bootc version fields. Before this
decision the host-side secure scripts (the UKI assembler, the packager, the
push, verify and promote helpers) loaded only the trixie contract and accepted
only bare 14-digit tags, so they could not package or publish a forky image.

## Decision

`.github/workflows/forky-publish.yml` publishes signed forky Floe **test
images**:

- It runs only on `workflow_dispatch`, and its one job runs only from
  `refs/heads/main`, in the `native-build` environment. Nothing publishes forky
  on a push, a pull request or a schedule.
- Its steps are those of `build-images.yml` `secure-build`, in the same order,
  with the same pinned actions, the same MOK and PCR credentials, the same
  Cosign signing key, the same signature policy, the same SBOM and the same
  build-provenance attestation. The build is
  `mkosi --release forky --profile floe`.
- It publishes only an immutable `forky-<14 digits>` tag in the product
  repository (`ghcr.io/frostyard/floe:forky-<timestamp>`). It never moves
  `latest` or any trixie tag, uploads no R2 manifests and makes no release.
  It omits exactly the steps of `secure-build` that do those things.
- `IMAGE_VERSION` and the `org.opencontainers.image.version` label and
  annotation stay the 14-digit timestamp, as on trixie. The suite is in the tag
  and in os-release (`VERSION_CODENAME=forky`, `VERSION_ID="14"`).

The environment variable `SNOSI_BOOTC_SECURE_SUITE` selects the suite for the
host-side secure scripts. Unset or empty is `trixie`, so every trixie caller
behaves as before; `forky` is the only other value, and any other value fails.
The helpers in `shared/bootc-secure/compatibility.sh` map the suite to its
contract and to its tag form:

| Suite | Contract | Tag form |
|-------|----------|----------|
| `trixie` (default) | `shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json` | `^[0-9]{14}$` |
| `forky` | `shared/bootc-secure/suite/forky/tree/usr/lib/snosi/bootc-secure.json` | `^forky-[0-9]{14}$` |

`assemble-uki.sh`, `buildah-package.sh` and `verify-published-image.sh` load
the contract of the selected suite. `buildah-package.sh` also fails when the
rootfs `VERSION_CODENAME` differs from the selected suite.
`push-immutable-image.sh` and `verify-published-image.sh` accept only the tag
form of the selected suite. `promote-published-image.sh` refuses any suite but
trixie, so a forky image cannot move `latest` even through a wrong workflow
edit. The forky workflow sets `SNOSI_BOOTC_SECURE_SUITE: forky` for the whole
job and passes it through each `sudo` call of a suite-aware script.

## Consequences

- The system and bootc image policies accept every tag of a Frostyard
  repository, so a user can already `bootc switch` to a `forky-<timestamp>`
  tag. Such a tag is a test artifact with no support claim and no update
  stream: an immutable tag never updates, and no `bootc upgrade` moves a host
  from one forky tag to the next.
- A user-facing moving tag (for example `:forky`), per-suite sysexts and the
  lab's install, update and rollback proof are later work, and each needs its
  own change.
- Forky secure-assembly evidence comes from the first dispatch run of the
  workflow; until then nothing shows that the forky bootc pair assembles a
  valid secure image.
- Forky test tags accumulate in the Floe package under GHCR's default
  retention. They share the repository with trixie tags but not the tag
  namespace: a forky tag never matches the trixie tag form, and the release
  job reads only the Snow tag.
- `test/forky-publish-workflow-test.py` holds the workflow to this decision:
  the trigger, the main gate, the environment, the suite, the absence of every
  `latest`, R2, release and artifact step, the forky tag on every push and
  verification, and the `secure-build` step list minus the omitted steps, with
  every shared step byte-identical except the few forky-specific ones.
  A step added to `secure-build` fails that test until `forky-publish.yml`
  takes it too or the test names it as omitted.

## Alternatives considered

- **A forky leg in the `build-images.yml` `secure-build` matrix:** couples the
  status of main to a suite that Debian has not released, and publishes on
  every push.
- **A reusable workflow shared by both suites:** removes the step copy, but is
  a larger refactor of a risk path now; the drift test covers the copy.
- **Bare 14-digit tags for forky:** collide with trixie's version namespace in
  the same repository and with the tag form that the release job reads.

## References

- Builds on: [ADR-0037](0037-build-forky-as-a-second-suite.md),
  [ADR-0008](0008-digest-first-release-latest-is-promotion.md) (digest-first
  publication; `latest` is a promotion),
  [core plan 0009, phase 6](https://github.com/frostyard/core/blob/main/docs/plans/0009-debian-publication-through-apt-publisher.md).
- Shapes: [CI/CD](../design/ci-cd.md),
  [build pipeline](../design/build-pipeline.md#suite-specific-content),
  [bootc secure assembly compatibility](../bootc-secure-assembly-compatibility.md),
  [bootc secure operations](../bootc-secure-operations.md).
- Enforced by: `test/forky-publish-workflow-test.py`,
  `test/bootc-secure-static-test.sh`, `test/bootc-secure-push-test.sh`,
  `test/bootc-secure-promotion-test.sh`, `test/bootc-secure-publication-test.sh`,
  `test/bootc-secure-package-cleanup-test.sh`,
  `test/bootc-secure-artifact-test.sh --fixtures`.
