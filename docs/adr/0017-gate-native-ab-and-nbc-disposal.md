# 0017 — Gate native A/B and nbc disposal separately from support retirement

- **Status:** Proposed
- **Date:** 2026-09-24

## Context

[ADR-0015](0015-retire-native-ab-images-and-nbc-installs.md) fixes the
2026-09-30 end of support and the single-source notice, but defers removal of
native A/B and nbc build/runtime lanes. The same Firn ISO and signing inputs
serve supported bootc installations; the `native` segment of its R2 URL does
not make it a retiring A/B image. Installed legacy hosts can still rely on
their own rollback slots, old media, or old publications for recovery.

Core [ADR-0047](https://github.com/frostyard/core/blob/main/docs/adr/0047-retire-nbc-on-a-proportional-fast-path.md)
is Accepted: support and routine publication end at the cutoff, with limited
best-effort help for four known users through 2026-10-31. Core
[ADR-0050](https://github.com/frostyard/core/blob/main/docs/adr/0050-replace-nbc-retention-date-with-a-completion-condition.md)
is Accepted and still governs outside-`stable` artifact retention. Core
[ADR-0052](https://github.com/frostyard/core/blob/main/docs/adr/0052-remove-nbc-artifact-retention-gates.md)
is **Proposed**, not operative: it would remove NBC/native-A/B-specific
retention floors and completion conditions, but does not authorize deletion.
Core ADR-0048 independently protects signed `stable` and all referenced deb
bytes, including packages under `pool/`, through at least 2027-09-30.

## Decision

Plan a bootc-only supported surface after 2026-09-30: stop routine native A/B
and nbc publication, retire their build/runtime wiring on new images, and
remove only the three A/B choices from the wholesale Firn catalog override.
Keep all four bootc choices and the shared EOL notice. Existing debs may
remain published without a support promise. **Only if core ADR-0052 becomes
Accepted**, no NBC/native-A/B-specific post-cutoff artifact-retention
obligation applies; until then ADR-0050's outside-`stable` conditions apply.
Neither policy permits rewriting signed `stable`, deleting its referenced
bytes, changing immutable signed indexes, or removing objects referenced by
them without a separate governing decision and authorization.

The [transition plan](../plans/2026-09-24-native-ab-nbc-retirement-plan.md)
requires a read-only exact-object inventory and installed-host recovery check,
architectural review by both maintainers before implementation, and separate
explicit maintainer authorization of a freshly rechecked per-object list
before any production image deletion. It is not authorization to change
production objects. Firn ISO publication, signed sysext trust, and bootc publication
continue independently. A post-cutoff emergency native publication requires
a separately approved written exact-artifact exception with reason, digest,
affected users, test evidence, and rollback; it does not restart routine
publication.

## Consequences

- An EOL date alone neither uninstalls old updater units on existing hosts nor
  makes old recovery media available. Reinstall from a verified backup with
  Firn, not an in-place nbc/native-A/B conversion; secure bootc lifecycle
  proof has separate gates.
- The live `isos/native/v1/` Firn ISO and its shared build and trust inputs
  stay outside A/B image disposal even if older native installer media is
  inventoried separately. Historical cayo remains governed by core ADR-0046.
- No deletion follows automatically from ending a retention obligation; an
  open user disposition or stale runbook must be surfaced in the authorization
  review, not silently ignored.

## Alternatives considered

- **Delete the native R2 prefix at the cutoff:** rejects signed-index,
  installed-host and shared-ISO boundaries; a prefix is not an object list.
- **Keep native A/B publication indefinitely for recovery:** would turn a
  limited help window into an unbounded unsupported update lane.

## References

- Builds on: [ADR-0015](0015-retire-native-ab-images-and-nbc-installs.md),
  core ADR-0047, ADR-0050, proposed ADR-0052, and ADR-0048.
- Shapes: [retirement plan](../plans/2026-09-24-native-ab-nbc-retirement-plan.md),
  [installing](../installing.md), [migration](../nbc-to-bootc-migration.md),
  [design overview](../design/overview.md).
- Enforced by: `test/retirement-plan-test.py`
