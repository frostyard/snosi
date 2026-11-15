# 0040 — Move the :forky tag to a verified forky image by dispatch

- **Status:** Accepted; amended by [ADR-0041](0041-queue-forky-publish-dispatches-per-product-and-mode.md) (the concurrency group)
- **Date:** 2026-11-14

## Context

[ADR-0038](0038-publish-signed-forky-test-images.md) and
[ADR-0039](0039-publish-forky-test-images-of-every-product.md) let
`.github/workflows/forky-publish.yml` sign and publish forky **test images**
of Floe, Snow, Snowfield and Sundog, 1 product per dispatch, under immutable
`forky-<14 digits>` tags. An immutable tag never updates: a host that runs
`bootc switch ghcr.io/frostyard/<product>:forky-<timestamp>` stays on that
image, and `bootc-update-stage.timer` never moves it to a newer forky image.

Both ADRs say that a user-facing moving tag (for example `:forky`) is later
work and needs its own change. A host that tracks a moving tag gets each new
image through the normal update path: the timer pulls the tag under the
strict signed-image policy, stages the new digest and applies it at the next
reboot.

A moving tag is a registry write that every host on that tag follows. A bad
move reaches those hosts within about 1 hour. The tag must therefore move
only to an image that is signed, that is the image the dispatcher names, and
that the lab has proven on forky.

GHCR stores tags on package versions, and a package version is a digest.
Deleting a version in the GHCR UI deletes the digest, with every tag on it.

## Decision

`forky-publish.yml` takes 2 more `workflow_dispatch` inputs beside
`profile`:

- `promote`, a boolean, default `false`.
- `source_tag`, a string, default `""`.

With `promote=false` the run is unchanged: it builds, signs and publishes 1
new `forky-<timestamp>` tag of the selected product (ADR-0038, ADR-0039). The
`select` job fails when `source_tag` is not empty, so a publish run never
ignores it, and nothing writes to a registry.

With `promote=true` the run builds and publishes nothing. The `forky-publish`
job is skipped, and a new job, `forky-promote`, moves the moving tag
`ghcr.io/frostyard/<product>:forky` to the digest of the existing tag
`ghcr.io/frostyard/<product>:<source_tag>`. The job has the same main gate as
the other jobs (dispatch only, from main), runs in the `native-build`
environment, and has only `contents: read` and `packages: write`: no
`id-token`, no `attestations` and no signing secret. Its steps, in this
order:

1. It checks out the repository with `persist-credentials: false`.
2. It fails unless `source_tag` matches `^forky-[0-9]{14}$`. The input
   reaches the script only through `env:`.
3. It logs in to ghcr.io and installs the pinned Cosign of the publish job.
4. It resolves `<product>:<source_tag>` to its digest and reads the current
   `:forky` digest (`none` when the tag does not exist; any other read error
   fails). It writes the product, the source tag, the target digest and the
   previous `:forky` digest to the step summary **before** any move.
5. It verifies the Cosign signature with `cosign.pub` against
   `<image>@<digest>`, the digest and not the tag.
6. It checks that the `org.opencontainers.image.version` config label and
   manifest annotation of that digest both equal the 14 digits of the source
   tag (`shared/outformat/image/check-image-version.sh`).
7. Only then it moves `:forky` with
   `shared/bootc-secure/ci/promote-forky-image.sh IMAGE DIGEST AUTH_FILE`.
   The helper refuses every suite except `forky`, validates the repository
   and the digest, runs `skopeo copy --all` from `IMAGE@DIGEST` to
   `IMAGE:forky` and fails unless `:forky` then resolves to that digest.
8. It writes the previous and the new `:forky` digest to the step summary.

The move is the only registry write of the job. A failed check in steps 2 to
6 leaves `:forky` unchanged.

The workflow checks only signature and identity. It cannot see a lab result.
**Operator rule:** before a dispatch with `promote=true`, the dispatcher must
have a passing lab proof for that product on that digest: a bootc lifecycle
`PASS` with that digest as N+1 (install, update and rollback), on the current
lab lane. That lane and its PASS criteria belong to frostyard/lab
([bootc lifecycle lane spec](https://github.com/frostyard/lab/blob/main/docs/specs/bootc-lifecycle-lane.md));
this decision links that gate and does not define it. The dispatcher records
the lab run beside the promotion run.

**Removal and rollback:** to take back a bad promotion, dispatch a re-point
run: `promote=true` with a retained, known-good `forky-<timestamp>` tag as
`source_tag`. Never delete the `:forky` tag or a package version in the GHCR
UI: GHCR deletes the version by digest, which removes every tag on that
digest, also the immutable `forky-<timestamp>` tag. A re-point does not
repair a host that already staged or booted the bad image; such a host uses
the local `bootc rollback` steps in
[installing](../installing.md#after-installation).

`latest` and every trixie tag stay untouched: `promote-published-image.sh`
still refuses a forky promotion, and the forky helper writes only `:forky`.
The `forky-<timestamp>` tags stay immutable.

## Consequences

- A host can track forky with `bootc switch ghcr.io/frostyard/<product>:forky`
  and gets each promoted image through `bootc-update-stage.timer`. The images
  stay test images with no support claim; the moving tag is a test stream,
  not a supported update stream. Snowfield stays untested on representative
  Surface hardware.
- Each promotion is a separate, deliberate dispatch per product, after its
  own lab proof. Publish and promote share the workflow concurrency group
  (`cancel-in-progress: false`), so a promote waits for a running publish, and
  a newer pending dispatch replaces an older pending one (ADR-0039).
- A re-point needs a known-good `forky-<timestamp>` tag that still exists.
  Any later pruning of forky tags must keep the current `:forky` target and
  the known-good tag before it.
- The lab proof is an operator duty, not a workflow check. A dispatcher who
  skips it can move `:forky` to a signed image that the lab has not proven;
  the step summary and the run log show who moved which digest and from where.
- `test/forky-publish-workflow-test.py` holds the workflow to this decision:
  the 2 inputs and their defaults, the refusal of a `source_tag` without
  `promote`, the job conditions, the permissions of `forky-promote`, inputs
  only through `env:`, no expression inside a `run:` script of
  `forky-promote`, the source tag pattern, the order summary, signature,
  version and move, the move as the only registry write, and no `latest` in
  any step. `test/bootc-secure-forky-promotion-test.sh` covers the helper.

## Alternatives considered

- **Move `:forky` at the end of each publish run:** every publish then
  reaches tracking hosts before the lab has proven N+1. The lab proof needs
  the digest first, so the move must be a later, separate step.
- **A separate promote workflow:** duplicates the main gate, the environment
  and the product table; one workflow keeps one concurrency group, so a
  publish and a promote never run at the same time.
- **Promote by digest input instead of a tag:** a digest is easy to paste
  from another product or suite; the `forky-<timestamp>` tag binds the
  product repository, the suite and the version that step 6 checks.
- **Let the workflow query the lab result:** couples snosi publication to the
  lab's record format and to cross-repository access; the operator rule keeps
  the gate in the lab's own terms.
- **Delete the tag to roll back:** GHCR deletes by digest and removes every
  tag on it; a re-point is reversible and keeps the immutable tags.

## References

- Amends: [ADR-0038](0038-publish-signed-forky-test-images.md) (its
  consequence that a moving tag needs its own change),
  [ADR-0039](0039-publish-forky-test-images-of-every-product.md).
- Builds on: [ADR-0008](0008-digest-first-release-latest-is-promotion.md)
  (digest-first publication; a moving tag is a promotion),
  [ADR-0037](0037-build-forky-as-a-second-suite.md).
- Links: [frostyard/lab bootc lifecycle lane spec](https://github.com/frostyard/lab/blob/main/docs/specs/bootc-lifecycle-lane.md)
  (another repository's gate),
  [installing: after installation](../installing.md#after-installation).
- Shapes: [CI/CD](../design/ci-cd.md), [testing](../design/testing.md),
  [bootc secure operations](../bootc-secure-operations.md).
- Enforced by: `test/forky-publish-workflow-test.py`,
  `test/bootc-secure-forky-promotion-test.sh`.
