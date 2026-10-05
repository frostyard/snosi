# snosi Roadmap

This document states direction, not a schedule. The
[decision index](docs/README.md) explains *why*; plans describe specific
sequences. Revisit the horizons as work lands.

## Current position

**bootc is the only transport** built by snosi. Snow, Snowfield, Floe and
Sundog are OCI products; sysexts add optional `/usr` payloads. Firn offers
only these four bootc choices. Snowfield ships **untested** on representative
Surface hardware: its inclusion gate was waived, not passed. Fresh-install
evidence for Snow, Floe and Sundog is pending: no minideb lab install has
produced any yet. Neither fixture results
nor catalog inclusion establishes live secure update and rollback proof.

Native A/B and nbc support and routine publication ended **2026-09-30**
([ADR-0015](docs/adr/0015-retire-native-ab-images-and-nbc-installs.md)).
The build/runtime lanes were removed by
[ADR-0018](docs/adr/0018-remove-native-ab-and-nbc-lanes.md). Existing hosts
cannot convert in place; back up and reinstall using the
[migration guidance](docs/nbc-to-bootc-migration.md). Core ADR-0047's
best-effort assistance through 2026-10-31 for four known users does not
extend product support. Already published artifacts are not deleted by source
cleanup. Signed `stable` and referenced package bytes remain protected by
core ADR-0048, and any future R2 deletion requires an exact-object inventory,
recovery review and separate authorization under ADR-0018 and the
[retirement plan](docs/plans/2026-09-24-native-ab-nbc-retirement-plan.md).
The Firn ISO still uses `isos/native/v1/` and its stable redirect. There is
no automatic ISO retention workflow.

## Near term

- **Prove bootc lifecycle on Firn-installed systems.** Complete the
  [update validation plan](docs/plans/2026-07-03-bootc-update-validation-plan.md)
  and the [manual secure lab handoff](docs/specs/bootc-secure-lab-handoff.md):
  authenticate signed N/N+1 artifacts, install, stage, reboot, roll back and
  retain sanitized evidence. Fresh-install and fixture tests do not replace
  this proof.
- **Assess any published-object disposal separately.** Preserve the Firn ISO
  namespace and public-key dependencies. Do not delete an R2 prefix by name;
  use ADR-0018's exact-object gate.
- **Enforce plan status metadata.** Plans have a `**Status:**` field, but no
  fail-closed repository guard yet verifies it.

## Mid term

- **Installer UI:** any graphical front end should be designed around Firn's
  bootc contract, not the retired native installer. The
  [older graphical-installer plan](docs/plans/2026-07-17-graphical-installer-plan.md)
  describes a removed prototype.
- **Update/sysext API:** consider whether a schema-owning daemon simplifies
  the currently point-to-point updex, pilothouse and chairlift contracts
  ([design](docs/plans/2026-07-20-update-api-daemon-design.md)).
- **Contract governance:** decide which live cross-tool interfaces belong
  under `docs/specs/` with executable checks.

## Longer-term questions

Fleet-wide staged rollout, health-gated promotion and recovery should operate
over signed bootc OCI deployments. Additional hardware families need new
validation criteria; Snowfield's present untested status must not be treated
as a hardware validation precedent.

No mutable `/usr`, non-Debian base or second OS transport is planned.
Sysext candidates must satisfy the `/usr`-only, verified-source and
maintainability rules in [ADR-0004](docs/adr/0004-sysext-authoring-rules.md)
and [sysext design](docs/design/sysexts.md).
