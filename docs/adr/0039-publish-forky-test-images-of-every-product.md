# 0039 — Publish forky test images of every product, 1 product per dispatch

- **Status:** Accepted
- **Date:** 2026-11-14

## Context

[ADR-0038](0038-publish-signed-forky-test-images.md) lets
`.github/workflows/forky-publish.yml` sign and publish forky **test images**
under immutable `forky-<14 digits>` tags. It names one product: Floe.

Phase 6 of [core plan 0009](https://github.com/frostyard/core/blob/main/docs/plans/0009-debian-publication-through-apt-publisher.md)
needs a lab proof of install, update and rollback on forky. Each product has
its own composition, kernel and boot path. Snow, Snowfield and Sundog add a
desktop, Plymouth and `splash quiet` on the sealed UKI command line
(ADR-0033), and Snowfield uses the linux-surface kernel. A Floe proof does not
show that these products install, update and roll back on forky. Each product
needs its own signed N and N+1 forky digests.

`forky-mechanics.yml` already builds all 4 forky products on pull requests
and every night, with no publication (ADR-0037). The `build-images.yml`
`secure-build` matrix publishes the same 4 products on trixie, with one
description for each product.

## Decision

`forky-publish.yml` publishes forky test images of Floe, Snow, Snowfield and
Sundog. A dispatch publishes exactly 1 product, which the dispatcher selects:

- The `workflow_dispatch` input `profile` is required, of type `choice`, with
  exactly the options `floe`, `snow`, `snowfield` and `sundog` (default
  `floe`). There is no option that publishes more than 1 product. Each
  registry write is a deliberate choice of 1 product.
- A first job, `select`, maps the input to exactly 1 matrix entry from a fixed
  table of the 4 products. The table has the same profiles and descriptions
  as the `secure-build` matrix. Any other value fails the job, so nothing
  publishes. The job has `permissions: {}`, no checkout, no secret and the
  same main gate as the publish job. The input reaches its script only
  through `env:`, never by expression interpolation into a script.
- The `forky-publish` job declares `needs: select` and takes its matrix from
  the output of `select`. It keeps `matrix.profile` and `matrix.description`,
  so its shared steps stay byte-identical to `secure-build`.

All other parts of ADR-0038 stay the same. The workflow runs only on
`workflow_dispatch` and only from main, in the `native-build` environment. It
sets `SNOSI_BOOTC_SECURE_SUITE: forky`. It pushes only immutable
`forky-<14 digits>` tags in the product's own repository
(`ghcr.io/frostyard/<product>:forky-<timestamp>`). It never moves `latest`
or a trixie tag, uploads no R2 manifests and makes no release. Its steps are
the `secure-build` steps minus the omitted steps that ADR-0038 names.

The only per-product steps of `secure-build` are the 2 steps that record the
Snow tag for the release job, and ADR-0038 omits both. The core Flatpak label
comes from `flatpaks/<product>.json` through `flatpaks/core-flatpaks.py`, in
the shared steps, so the forky Snow and Sundog images carry their labels as on
trixie.

## Consequences

- Forky test tags now accumulate in 4 packages (`floe`, `snow`, `snowfield`
  and `sundog`) under GHCR's default retention. They share each package with
  the trixie tags but not the tag namespace.
- A full forky lab round needs 2 dispatches for each product (N and N+1), so
  8 dispatches for the 4 products. The workflow concurrency group
  (`cancel-in-progress: false`) runs 1 dispatch at a time and keeps at most 1
  pending dispatch: a newer dispatch replaces an older pending one. So start
  the next dispatch only after the previous one has started.
- Snowfield stays **untested** on representative Surface hardware. A forky
  Snowfield test image gives no Surface support claim. The waived catalog
  inclusion gate of Snowfield stays waived.
- A forky test image of any product is a test artifact with no support claim
  and no update stream, as ADR-0038 says. The user-facing moving tag (for
  example `:forky`) is still later work and needs its own change.
- Forky secure-assembly evidence is per product: the first dispatch of each
  product is its evidence.
- `test/forky-publish-workflow-test.py` holds the workflow to this decision:
  the choice input and its 4 options, the `select` table equal to the
  `secure-build` matrix, 1 matrix entry for each run, the fail-closed default
  branch, the main gate and the empty permissions of `select`, and no
  `inputs.` reference outside the `env:` of the select step. It keeps every
  check of ADR-0038.

## Alternatives considered

- **A static matrix of all 4 products in each dispatch:** every dispatch
  writes 4 packages, also when the lab needs only 1 product.
- **An "all" option:** makes a write to 4 packages a single click; one
  dispatch for each product keeps each write deliberate.
- **A matrix entry built inline from the input
  (`profile: ${{ inputs.profile }}`, a `fromJSON` map for the description):**
  needs no extra job, but an unknown value then fails only in the mkosi
  build, and the table is an expression that the test must parse. The
  `select` job fails closed before the protected job starts.
- **A forky leg in the `secure-build` matrix:** rejected by ADR-0038 for the
  same reasons (main status, a publish on every push).

## References

- Amends: [ADR-0038](0038-publish-signed-forky-test-images.md).
- Builds on: [ADR-0037](0037-build-forky-as-a-second-suite.md),
  [ADR-0033](0033-seal-the-plymouth-splash-into-the-secure-uki-command-line.md),
  [core plan 0009, phase 6](https://github.com/frostyard/core/blob/main/docs/plans/0009-debian-publication-through-apt-publisher.md).
- Shapes: [CI/CD](../design/ci-cd.md), [testing](../design/testing.md),
  [bootc secure operations](../bootc-secure-operations.md),
  [bootc secure assembly compatibility](../bootc-secure-assembly-compatibility.md).
- Enforced by: `test/forky-publish-workflow-test.py`.
