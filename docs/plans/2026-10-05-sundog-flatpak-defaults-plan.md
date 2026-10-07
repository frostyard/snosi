# Plan: Provision Sundog-specific Flatpak application defaults

**Status:** In progress — Sundog's set ships as the image label
(`flatpaks/sundog.json`, #1054); Firn release, fallback retirement,
migration and native-app removal remain
**Last verified:** 2026-10-06

This follows the
[native desktop-completeness plan](2026-10-05-sundog-desktop-completeness-plan.md).
It gives Sundog its own core Flatpak set, makes Firn install that set
instead of Snow's GNOME list, provides an existing-install migration, and
then removes the native applications the set replaces. It implements the
Flatpak-first intent of
[ADR-0016](../adr/0016-name-kde-bootc-product-sundog.md) through the
[core Flatpak set contract](../integration-contracts.md#core-flatpak-sets).

The original 2026-10-05 version of this plan proposed a `sets` map in
first-setup's `core.json` and a `system.core_flatpak_set` recipe selector.
[Firn ADR-0018](https://github.com/frostyard/firn/blob/main/docs/adr/0018-image-published-core-flatpaks-label.md)
replaced that design: each image publishes its own set as the
`org.frostyard.core-flatpaks` OCI label, so the chosen image is the
selector. Do not recreate first-setup sets, a recipe selector, or
`shared/firn-installer/core.json`.

## Agreed application set

[`flatpaks/sundog.json`](../../flatpaks/sundog.json) is the canonical set.
It contains these ten application IDs:

| Application | Flatpak ID |
| --- | --- |
| Gwenview | `org.kde.gwenview` |
| Haruna | `org.kde.haruna` |
| KCalc | `org.kde.kcalc` |
| KCharSelect | `org.kde.kcharselect` |
| Okular | `org.kde.okular` |
| Skanpage | `org.kde.skanpage` |
| KWeather | `org.kde.kweather` |
| Kontainer | `io.github.DenysMb.Kontainer` |
| Bazaar | `io.github.kolunmi.Bazaar` |
| MissionCenter | `io.missioncenter.MissionCenter` |

Every application in Snow's set is excluded, unless expressly included
in the application list above. Bazaar and MissionCenter are retained
by explicit operator choice, even though native Discover and
Plasma System Monitor are also available.

These rules select applications, not runtimes: selected applications may
require GNOME, KDE or freedesktop runtimes, and Flatpak installs those as
dependencies. Explicit recipe `flatpaks` stay separate; Firn merges them
with an opted-in core set and honors them when core defaults are off.
Floe has no set and carries no label.

## Phase 1 — Record the core-set contract (medium) — ✅ landed 2026-10-06

- [x] Firn ADR-0018 defines the label, its fail-closed parser, preflight
      timing and retirement of the first-setup and ISO-fallback sources
      (firn#108, firn#110).
- [x] [Integration contracts](../integration-contracts.md#core-flatpak-sets)
      record the snosi side: one source file per distinct set, Snowfield
      sharing `flatpaks/snow.json`, and Floe without a label.
- **Done when:** the label contract, Floe's empty set and the rollout order
  (labels before a Firn release that reads them) are recorded. Done.

## Phase 2 — Publish per-product sets (medium) — ✅ landed 2026-10-06

- [x] `flatpaks/snow.json` and `flatpaks/sundog.json` hold the sets;
      `flatpaks/core-flatpaks.py` validates them, prints each build's label
      and checks packaged images (#1054, #1055).
- [x] Every packaging lane stamps and checks the label; the secure lane
      rechecks the pushed, signed digest before promoting `latest`.
      `test/core-flatpaks-test.sh` pins the contract.
- [x] Published `ghcr.io/frostyard/sundog:latest` carries Sundog's set and
      `floe:latest` carries no label key (checked with `skopeo inspect`,
      2026-10-06).
- [x] Firn reads the label in `preflight-image`, installs explicit apps then
      the core set, and previews the set in the wizard (firn#111).
- **Done when:** published images carry their sets and Firn's main branch
  consumes them. Done.

## Phase 3 — Release Firn and retire the ISO fallback (small)

Until this phase lands, the ISO's Firn (v0.6.2) still installs Snow's GNOME
list on every product, including Sundog.

- [ ] Tag a Firn release containing firn#111. Its release dispatch rebuilds
      the installer ISO, which takes the newest Firn release unpinned.
- [ ] Confirm the published ISO carries that Firn version.
- [ ] Remove the `/usr/share/firn/core-flatpaks.json` embedding from
      `shared/firn-installer/mkosi.conf` and the Justfile's `_firn-binary`.
- [ ] Point `just firn-flatpak-seed` at `flatpaks/snow.json`, then delete
      `flatpaks/legacy/` and `core-flatpaks.py generate-legacy`.
- [ ] Update `shared/firn-installer/README.md` and the integration
      contract's fallback paragraph.
- **Done when:** the published ISO's Firn installs Sundog's set for a Sundog
  install with core Flatpaks enabled, and neither snosi nor the ISO ships
  `core-flatpaks.json`.

**Interim duplicates:** once Phase 3 lands and before Phase 5, a fresh
Sundog install with core Flatpaks enabled gets both native and Flatpak
Gwenview, Okular, KCalc and Skanpage. Keep that window short.

## Phase 4 — Migrate existing installations (medium)

Existing Sundog installs that opted into core Flatpaks hold Snow's GNOME
set. A bootc update does not change `/var/lib/flatpak`.

- [ ] Provide documented, opt-in migration commands in `docs/installing.md`
      for system and per-user installations. Read the app list from
      `flatpaks/sundog.json` (or the booted image's label), not a second
      copy.
- [ ] Install replacements first and check that each ref is present before
      offering optional removal of the former GNOME defaults, Extension
      Manager and DistroShelf. Keep Bazaar, MissionCenter and any app the
      user deliberately kept.
- [ ] Make rerunning the migration safe after interruption, and keep
      app-data deletion out of the ordinary replacement step.
- [ ] Document how to list installed replacement refs and report failed
      downloads. App launches and hardware behavior are outside this
      checkpoint.
- [ ] Document recovery: bootc rollback restores native image packages but
      does not undo Flatpak changes.
- **Done when:** migration commands driven by the canonical set are
  documented for both installation scopes, with replacement-first
  ordering, optional cleanup, rerun behavior and recovery.

## Phase 5 — Remove native apps and preserve host integration (medium)

- [ ] After Phases 3 and 4, remove the explicit native `gwenview`, `kcalc`,
      `okular` and `skanpage` selections from
      `shared/packages/sundog/mkosi.conf`.
- [ ] Explicitly retain `kimageformat6-plugins` and `libsane1`. Gwenview
      currently brings the former; Skanpage brings the latter through
      `libksanecore6-1`, and `libsane1` owns the host's scanner udev rules.
      Retain any other host-side preview, sharing, scanner or portal support
      the dependency review finds.
- [ ] Preserve every package `mkosi.images/gui-base/mkosi.conf` requires and
      review sysext compatibility under the
      [library-closure contract](../design/sysexts.md).
- [ ] Keep `gwenview-doc` and `okular-doc` and native Help Center support
      for now; they do not hard-depend on the applications. Sandboxed Help
      behavior is unverified and is not a gate.
- [ ] Update `docs/design/overview.md`, which still says native Gwenview and
      Okular remain in the image.
- **Done when:** the native selections are gone, required host support is
  explicitly composed, and availability checks, static guards and normal
  image-build CI pass.

## Validation scope

Acceptance is package/ref availability plus static and automated checks.
UI behavior, hardware integration, sandboxed Help, live fresh or migrated
installs, and bootc upgrade/rollback exercises are not gates. Report the
checks actually run.

```sh
apt-cache policy kimageformat6-plugins libsane1
flatpak remote-info --system --arch=x86_64 flathub org.kde.gwenview
./flatpaks/core-flatpaks.py validate
./test/core-flatpaks-test.sh
./test/sundog-profile-test.sh
./check-duplicate-packages.sh
./test/firn-catalog-test.sh
./test/firn-installer-iso-test.sh --static
git diff --check
```

## References

- Prerequisite: [native desktop completeness](2026-10-05-sundog-desktop-completeness-plan.md).
- Independent fix: [printer support](2026-10-05-sundog-printer-support-plan.md).
- Contract: [core Flatpak sets](../integration-contracts.md#core-flatpak-sets),
  [firn ADR-0018](https://github.com/frostyard/firn/blob/main/docs/adr/0018-image-published-core-flatpaks-label.md),
  [firn label spec](https://github.com/frostyard/firn/blob/main/docs/specs/core-flatpaks-label.md).
- Decision: [ADR-0016](../adr/0016-name-kde-bootc-product-sundog.md).
- Implements: [architecture overview](../design/overview.md),
  [build pipeline](../design/build-pipeline.md),
  [testing](../design/testing.md).
- Media: [Firn installer composition](../../shared/firn-installer/README.md).
- Firn provisioning: [ADR-0006](https://github.com/frostyard/firn/blob/main/docs/adr/0006-install-time-offline-first-flatpaks.md),
  [`internal/flatpak/flatpak.go`](https://github.com/frostyard/firn/blob/main/internal/flatpak/flatpak.go).
- Constraints: [sysext design](../design/sysexts.md),
  [risk tiers](../risk-tiers.md), [review rubric](../review-rubric.md).
