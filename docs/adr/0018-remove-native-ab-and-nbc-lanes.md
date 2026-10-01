# 0018 — Remove native A/B and nbc build and runtime lanes

- **Status:** Accepted
- **Date:** 2026-09-30

## Context

[ADR-0015](0015-retire-native-ab-images-and-nbc-installs.md) ended native A/B
and nbc support on 2026-09-30. The parallel build, publication, installer and
update paths still imposed maintenance and test costs on the supported bootc
path. Firn's installer ISO and the bootc signing/lab inputs share directories
and R2 naming with the retired lane; directory names alone cannot identify
disposable artifacts. [ADR-0017](0017-gate-native-ab-and-nbc-disposal.md)
separated repository cleanup from production-object deletion.

## Decision

Remove the native A/B profiles, native installer payload, native OS publication
workflow/scripts, NBC package and timer, native update/status backend and EOL
helpers from new images. The Firn catalog offers only bootc `snow`,
`snowfield`, `floe` and `sundog`. Preserve `shared/native-ab/keys/` at its
existing path: external lab bootc consumers read it, while bootc-secure,
Firn's ISO and `build-images.yml` use its public identities. Preserve the
mkosi-pin CI helpers, ISO publication scripts, `isos/native/v1/` and its
stable-download redirect; `native` in that URL is not a native A/B offering.

End automatic ISO-namespace retention with removal of `native-retention.yml`.
That workflow had never run successfully because its repository-level R2
credentials were unavailable. ISO publication and signed-index verification
continue; retention is not implied by the publication pipeline. This change
deletes **no R2 object**. Any future deletion of published bytes requires the
fresh, read-only exact-object inventory, installed-host recovery check and
separate per-object authorization in [ADR-0017](0017-gate-native-ab-and-nbc-disposal.md)
and the [retirement plan](../plans/2026-09-24-native-ab-nbc-retirement-plan.md),
subject to governing core retention decisions and signed-index protections.

The bootc-only installer includes Snowfield **untested** on representative
Surface hardware: waive its former hardware gate for inclusion, not its lack
of evidence. Fresh-install evidence for Snow, Floe and Sundog is pending:
minideb lab installs will run after the Firn release is pinned; none exists
yet. Those installs will not prove Snowfield hardware or secure update/rollback.
Until that pin lands, the ISO ships the `frostyard-firn` currently in the apt
repo; its catalog loader accepts a bootc-only catalog (no `ab` entries required).
ISO promotion is not gated on the Firn pin.

## Consequences

- New images cannot update legacy nbc/native A/B hosts. Users need a verified
  backup and a fresh Firn bootc installation; old installed images and
  published artifacts are not deleted by this repository change.
- The ISO redirect and signed publication remain operational without automated
  retention. Monitor storage and treat any proposed cleanup as a separate
  exact-object decision, not a prefix deletion.
- Historical native A/B contracts and build evidence remain readable, but no
  longer describe a buildable product. Snowfield's inclusion must not be cited
  as hardware validation.

## Alternatives considered

- **Keep dormant native profiles and NBC updater:** preserves duplicated
  contracts and invites unsupported publication or updates.
- **Remove everything named native, including keys and ISO namespace:** breaks
  active bootc lab consumers and the installer download and trust path.
- **Keep the broken retention workflow:** implies an ISO cleanup guarantee it
  never supplied; repairing retention requires its own credentials and policy.

## References

- Builds on: [ADR-0015](0015-retire-native-ab-images-and-nbc-installs.md),
  [ADR-0017](0017-gate-native-ab-and-nbc-disposal.md).
- Shapes: [design overview](../design/overview.md),
  [CI/CD](../design/ci-cd.md), [installation](../installing.md),
  [migration](../nbc-to-bootc-migration.md),
  [retirement plan](../plans/2026-09-24-native-ab-nbc-retirement-plan.md).
- Enforced by: `test/no-nbc-test.sh`, `test/firn-catalog-test.sh`,
  `test/iso-publication-pipeline-test.sh`, `test/retirement-plan-test.py`.
