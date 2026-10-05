# Plan: Provision Sundog-specific Flatpak application defaults

**Status:** Proposed
**Last verified:** 2026-10-05

This follows the
[native desktop-completeness plan](2026-10-05-sundog-desktop-completeness-plan.md).
It provisions Sundog's selected applications through Flatpak, gives Firn
product-specific online and offline app selection, and provides an
existing-install migration before native applications leave the image.
It implements the Flatpak-first intent of
[ADR-0016](../adr/0016-name-kde-bootc-product-sundog.md) through the
[installer integration](../integration-contracts.md).

## Agreed application set

Sundog's core set contains exactly these nine application IDs:

| Application | Flatpak ID |
| --- | --- |
| Gwenview | `org.kde.gwenview` |
| Haruna | `org.kde.haruna` |
| KCalc | `org.kde.kcalc` |
| KCharSelect | `org.kde.kcharselect` |
| Okular | `org.kde.okular` |
| Skanpage | `org.kde.skanpage` |
| Kontainer | `io.github.DenysMb.Kontainer` |
| Bazaar | `io.github.kolunmi.Bazaar` |
| MissionCenter | `io.missioncenter.MissionCenter` |

The seven newly selected KDE-oriented applications have stable Flathub
refs verified on 2026-10-05. Revalidate their availability and runtime
closures when building installer media.

Exclude every GNOME application in the current core list, including
applications with no named replacement such as Calendar, Contacts,
Clocks, Maps, and Weather. Also exclude
`com.mattjakeman.ExtensionManager`, `com.ranfdev.DistroShelf`, and
`org.kde.skanlite`. Skanpage is the sole default scanner application.
Bazaar and MissionCenter are retained by explicit operator choice, even
though native Discover and Plasma System Monitor are also available.

These are application-selection rules. Selected applications may require
GNOME, KDE, or freedesktop runtimes and extensions; those dependencies
must remain available. Explicit user-requested apps are separate from
the core defaults and need a defined interaction with the new selection.

## Current integration and ordering constraint

The baseline local tree is commit `4681c32`:

- `shared/firn-installer/core.json` is a byte-identical vendored copy of
  first-setup's `snow_first_setup/core.json`, the current canonical
  GNOME-oriented core list.
- `Justfile`'s `firn-flatpak-seed` recipe reads that single list and builds
  `output/firn-flatpak-seed` with its apps and runtimes. ISO assembly puts
  the seed outside the initramfs, and
  `firn-flatpak-seed.service` mounts it at `/var/lib/flatpak`.
- `shared/firn-installer/mkosi.conf` embeds the same list at
  `/usr/share/firn/core-flatpaks.json`; the local `_firn-binary` recipe
  supplies the same fallback for development builds.
- Firn's `internal/flatpak/flatpak.go` reads the image core list or the
  installer fallback. The composefs deployment does not expose image
  `/usr` as ordinary files at installation time, so changing only an
  image-side list cannot reliably select Sundog's apps.
- Firn's `Provision` currently tar-copies the entire medium's system
  Flatpak installation. Filtering the requested app IDs alone therefore
  does not prevent unwanted seeded GNOME apps from reaching Sundog.
- Native `gwenview`, `kcalc`, `okular`, and `skanpage` are explicitly
  selected in `shared/packages/sundog/mkosi.conf`. Haruna, KCharSelect,
  and Skanlite are not explicitly selected there.

Installer provisioning and the existing-host migration must be ready
before those four native applications are removed. A bootc update does
not apply an install-time app list to an existing `/var/lib/flatpak`.

## Phase 1 — Agree on the cross-repository contract (medium)

- [ ] Agree with Firn and first-setup maintainers on the canonical owner
      and schema of product-specific core sets. Preserve a single source
      for each set and a defined vendoring relationship for media.
- [ ] Define how the selected catalog entry chooses the core set in both
      readable-root and composefs/fallback paths. Bootc catalog entries
      currently carry `name`, `ref`, and `cosign_pub_key` and forbid the
      native `product` field; respect that boundary when choosing a selector.
- [ ] Define core opt-out, explicit recipe apps, unknown products, absent
      manifests, malformed manifests, and deduplication behavior. Resolve
      these before changes can cause an unintended fallback to another
      product's defaults.
- [ ] Define selective offline provisioning: either selection from a
      shared seed or product-specific seed installations. Choose based on
      verified Flatpak mechanics, runtime completeness, media size, and
      preservation of existing target state.
- [ ] Retain Firn's install-time, offline-first model: unreachable apps
      are reported in the install summary; structural copy/import errors
      are distinguished from unavailable downloads.
- [ ] Record the new cross-repository decision in frostyard/core, link it
      from `docs/org-adrs.md`, and update the relevant Firn contract with
      its implementing code. Existing accepted ADRs are not rewritten.
- **Done when:** the maintainers agree on canonical data ownership,
  product selection, fallback behavior, selective seed provisioning, and
  rollout order, and the governing decision is recorded.

## Phase 2 — Implement product-aware provisioning and media (large)

- [ ] Add Sundog's agreed app set through the Phase 1 mechanism. Preserve
      Snow/Snowfield's intended defaults and Floe's core-app policy.
- [ ] Implement Firn's product selection and selective provisioning.
      Include required runtimes/extensions, exports, remotes, and
      ownership; avoid removing pre-existing or explicitly requested apps
      merely because they are outside the selected core set.
- [ ] Update both the CI ISO composition and the local `_firn-binary`
      fallback payload, the `firn-flatpak-seed` recipe, and ISO seed
      assembly/mounting as required by the agreed contract.
- [ ] Preserve the current seed-builder isolation from the host's own
      Flatpak installations so already-installed host runtimes cannot
      mask an incomplete seed. Keep multi-GiB data outside the initramfs.
- [ ] Add Firn fixtures covering product selection, core opt-out,
      explicit apps, missing/malformed lists, dependency completeness,
      unwanted seeded apps, download failures, and structural failures.
- [ ] Exercise seeded offline and unseeded network installs. On a clean
      Sundog core-only install, inspect the target's application refs and
      verify the nine-app set. Snow/Snowfield installs must resolve their
      own core lists from the same installer distribution.
- [ ] Deliver the compatible Firn release and installer payload before
      proceeding to native application removal. The ISO consumes the
      newest published Firn release; do not introduce a release pin.
- **Done when:** a released Firn and assembled ISO provision the correct
  product's core set online and offline, carry complete dependencies,
  exclude unwanted seed apps, and report failures according to the
  agreed contract, with retained fixture and installed-target evidence.

## Phase 3 — Migrate existing installations (medium)

- [ ] Provide documented commands or a scoped migration workflow for
      existing Sundog installations, using the same canonical app IDs.
- [ ] Install the replacement apps first and verify they launch before
      offering removal of the former default GNOME apps, Extension
      Manager, and DistroShelf. Retain Bazaar and MissionCenter.
- [ ] Specify behavior for system and per-user installations, apps users
      deliberately retained, app data, and an interrupted migration.
      Make rerunning the migration safe and keep app-data deletion outside
      the ordinary replacement operation.
- [ ] Test Kontainer against the host's existing Distrobox/Podman and
      Skanpage against available scanner hardware. Verify file access,
      launchers, associations, Haruna playback/acceleration, and offline
      Help for the Flatpak applications.
- [ ] Document recovery for a failed migration. Bootc rollback restores
      native image packages but does not undo persistent Flatpak changes;
      application recovery needs its own instructions.
- **Done when:** an existing Sundog installation can complete and rerun
  the migration, the replacement apps work, exclusions and retained apps
  match operator choices, and recovery/data behavior is documented.

## Phase 4 — Remove native apps and preserve host integration (medium)

- [ ] After Phases 2 and 3 are ready, remove explicit native `gwenview`,
      `kcalc`, `okular`, and `skanpage` selections from Sundog.
- [ ] Audit the newly resolved hard-dependency closure. Explicitly retain
      host `kimageformat6-plugins`, which currently comes through Gwenview,
      and any host-side preview, sharing, scanner-device/udev/account,
      or portal support still needed by native Plasma and sandboxed apps.
- [ ] Preserve every package required by `mkosi.images/gui-base/mkosi.conf`
      and review sysext compatibility under the
      [existing library-closure contract](../design/sysexts.md).
- [ ] Reconcile `gwenview-doc`, `okular-doc`, and bundled native handbooks
      with the Flatpak apps' actual Help behavior. Preserve the offline
      Help outcome from the preceding plan; decide retention/removal based
      on a working sandboxed Help path, not package naming alone.
- [ ] Run the existing profile guards, build Sundog, pass its `/var`
      audit, and verify the removed native applications are absent from
      the built package manifest. Test fresh and migrated installations
      for duplicate launcher entries, correct handlers, native Dolphin
      previews, and all selected Flatpak applications.
- [ ] Update `shared/firn-installer/README.md`, relevant living designs and
      integration contracts, user migration guidance, and this plan's
      status/evidence. Submit Tier 3 image/installer implementation PRs
      with test results and rollout/recovery behavior for maintainer review.
- **Done when:** the reviewed Sundog image supplies the standalone apps
  through the selected Flatpaks, fresh and migrated installs pass the
  integration checks, and native host functionality and local Help remain
  verified after the native application packages are removed.

## Open questions

- **Contract owner and schema:** settle in Phase 1 with Firn and
  first-setup; the current vendored `core.json` is not a Sundog manifest.
- **Seed strategy:** prove selective provisioning and runtime handling
  before selecting a shared-seed or per-product-seed implementation.
- **Local Help:** determine how each Flatpak exposes its handbook and
  reaches a viewer before removing native handbook providers in Phase 4.
- **Existing-host migration:** agree on the scope and distribution of the
  migration workflow and system/user installation handling in Phase 3.

## References

- Prerequisite: [native desktop completeness](2026-10-05-sundog-desktop-completeness-plan.md).
- Implements: [architecture overview](../design/overview.md),
  [build pipeline](../design/build-pipeline.md),
  [testing](../design/testing.md),
  [integration contracts](../integration-contracts.md).
- Media: [Firn installer composition and seed](../../shared/firn-installer/README.md).
- Decision: [ADR-0016](../adr/0016-name-kde-bootc-product-sundog.md);
  [cross-repository decision index](../org-adrs.md).
- Firn: [offline-first provisioning decision](https://github.com/frostyard/firn/blob/main/docs/adr/0006-install-time-offline-first-flatpaks.md),
  [current provisioning implementation](https://github.com/frostyard/firn/blob/main/internal/flatpak/flatpak.go).
- Canonical current list: [first-setup core.json](https://github.com/frostyard/first-setup/blob/main/snow_first_setup/core.json).
- Constraints: [sysext design](../design/sysexts.md),
  [risk tiers](../risk-tiers.md), [review rubric](../review-rubric.md).
