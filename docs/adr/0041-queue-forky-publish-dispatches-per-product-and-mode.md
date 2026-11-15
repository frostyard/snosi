# 0041 — Queue forky-publish dispatches per product and per mode

- **Status:** Accepted
- **Date:** 2026-11-15

## Context

[ADR-0038](0038-publish-signed-forky-test-images.md),
[ADR-0039](0039-publish-forky-test-images-of-every-product.md) and
[ADR-0040](0040-move-the-forky-tag-to-a-verified-forky-image-by-dispatch.md)
let `.github/workflows/forky-publish.yml` publish forky test images and move
the moving `:forky` tag, 1 product per dispatch. Every dispatch shared 1
concurrency group (`cancel-in-progress: false`). Both ADRs told dispatchers to
start the next dispatch only after the previous run had started, because
GitHub keeps at most 1 waiting run per group.

That rule failed on 2026-11-14 (US Eastern time). A forky lab round needed
4 promote dispatches, 1 for each product, and they went out within 2 minutes.
The second run was still running when the third dispatch arrived, so the
third waited; the fourth dispatch, 19 seconds later, replaced it. The Snowfield
promotion (run 43669696634) was cancelled while it waited, so `:forky` never
moved for Snowfield. The loss is quiet: a replaced waiting run
leaves no failed run of the product that lost it.

The 2 jobs write different tags. `forky-publish` pushes only a new immutable
`forky-<14 digits>` tag of 1 product
(`shared/bootc-secure/ci/push-immutable-image.sh`, which fails when that tag
already exists). `forky-promote` writes only `:forky` of 1 product, and only
from a `source_tag` that already exists
(`shared/bootc-secure/ci/promote-forky-image.sh`). No tag is written by both
jobs, and 2 runs of different products never name the same package. No shared
tag needs a publish and a promote of 1 product to wait for each other.

## Decision

The workflow's concurrency group is per product and per mode:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ inputs.profile }}-${{ inputs.promote && 'promote' || 'publish' }}
  cancel-in-progress: false
```

- Dispatches of different products, or of publish and promote, queue in
  separate groups and run in parallel.
- 2 dispatches of the same product and the same mode run 1 at a time.
- GitHub still keeps at most 1 waiting run per group. A 3rd dispatch of the
  same product and mode replaces the waiting run before it starts any job, so
  a dispatcher who wants 3 runs of 1 product and mode starts the next one only
  after the previous one has started.
- The `profile` input description states the parallel rule and the
  1-at-a-time rule for the same product and mode.

`test/forky-publish-workflow-test.py` holds the top-level `concurrency:` block
to that group line and `cancel-in-progress: false`. Its self-test fails on the
single-group form (`${{ github.workflow }}` alone), on a group without the
product, on a group without the mode, and on `cancel-in-progress: true`.

## Consequences

- A lab round of 4 products can dispatch its promote runs together, 1 per
  product, and no product loses its run to another product's dispatch.
- A promote of a proven digest no longer waits behind a publish build of
  another product (the Sundog publish run 43635094915 took 48 minutes).
- The 1-at-a-time rule and the 1-waiting-run limit still hold for a product
  and mode: a 3rd quick dispatch of the same product and mode can still
  replace a waiting run. The group narrows what 1 dispatch can cancel, and
  cannot enlarge GitHub's waiting queue.
- The group names an input. `profile` is required with a default of `floe`,
  and `promote` defaults to `false`, so every dispatch has a group name.
- Forky publication is still serialized where it must be: 2 promotes of 1
  product, and 2 publishes of 1 product, never run at the same time.

## Alternatives considered

- **A group per product only:** publish and promote of 1 product still wait
  for each other, and no shared tag needs that. A promote of an already
  proven digest then waits behind a publish build that it does not depend on.
- **A group per run (`github.run_id`):** no serialization at all. 2 promotes
  of 1 product could race on `:forky`, and the later move wins with no check
  of the other one. 2 publishes that reach the same 14-digit second would
  fight over one immutable tag.
- **Keep 1 group and tell dispatchers to wait:** the rule existed in
  ADR-0039 and ADR-0040 and still lost a promotion. It is a rule of the
  dispatcher's memory, not of the workflow, and 4 dispatches in 2 minutes break
  it.

## References

- Amends: [ADR-0039](0039-publish-forky-test-images-of-every-product.md)
  (its consequence that 1 concurrency group runs 1 dispatch at a time),
  [ADR-0040](0040-move-the-forky-tag-to-a-verified-forky-image-by-dispatch.md)
  (the same consequence, and its "separate promote workflow" alternative that
  named 1 group).
- Builds on: [ADR-0038](0038-publish-signed-forky-test-images.md),
  [ADR-0037](0037-build-forky-as-a-second-suite.md).
- Shapes: [CI/CD](../design/ci-cd.md), [testing](../design/testing.md).
- Enforced by: `test/forky-publish-workflow-test.py`.
