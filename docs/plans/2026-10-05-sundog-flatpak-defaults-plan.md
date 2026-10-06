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

The immediate printer-package fix is scheduled separately in the
[printer-support plan](2026-10-05-sundog-printer-support-plan.md). This
Flatpak plan remains proposed while its cross-repository contract and
implementation are developed. Deferred manual desktop checks from the
preceding plan are not prerequisites for this package/ref-only acceptance.

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
refs verified on 2026-10-05. Check stable x86_64 ref availability for all
nine applications and metadata relevant to offline export. Flatpak's seed
export and installation mechanisms supply runtime dependencies.

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
the core defaults: merge and deduplicate them with an opted-in core set,
and honor them independently when core defaults are disabled.

## Current integration and ordering constraint

> **Superseded in part (2026-10-06):** `shared/firn-installer/core.json` no
> longer exists. Core Flatpak sets now live in [`flatpaks/`](../../flatpaks/)
> and ship as the `org.frostyard.core-flatpaks` image label
> ([integration contracts](../integration-contracts.md#core-flatpak-sets),
> firn ADR-0018). Do not recreate or re-vendor that file; this plan's
> contract and Phases 1–2 are pending a rewrite.

The 2026-10-05 planning review found:

- `shared/firn-installer/core.json` is a byte-identical vendored copy of
  first-setup's `snow_first_setup/core.json`, the current canonical
  GNOME-oriented core list.
- `Justfile`'s `firn-flatpak-seed` recipe reads that single list and builds
  `output/firn-flatpak-seed` with its apps and runtimes. ISO assembly puts
  the seed outside the initramfs, and
  `firn-flatpak-seed.service` mounts it at `/var/lib/flatpak`.
- `.github/workflows/build-installer-iso.yml` does not invoke the seed
  builder or pass a seed to ISO assembly; published CI media is currently
  seedless.
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
- Firn's wizard retains the chosen catalog entry but does not serialize
  its name into the recipe. Product identity must reach core-set selection
  explicitly rather than being guessed from an OCI reference.
- Native `gwenview`, `kcalc`, `okular`, and `skanpage` are explicitly
  selected in `shared/packages/sundog/mkosi.conf`. Haruna, KCharSelect,
  and Skanlite are not explicitly selected there.

Installer provisioning and the existing-host migration must be ready
before those four native applications are removed. A bootc update does
not apply an install-time app list to an existing `/var/lib/flatpak`.

## Proposed cross-repository contract

Keep first-setup's `snow_first_setup/core.json` canonical and extend it
additively. Preserve its existing top-level `core` array for the legacy
consumer; add a `sets` map without duplicating that array:

| Selector | Manifest entry | Selection |
| --- | --- | --- |
| `snow` | `sets.snow.ref = "core"` | Existing GNOME core list |
| `snowfield` | `sets.snowfield.ref = "core"` | Same canonical GNOME core list |
| `sundog` | `sets.sundog.apps` | The nine applications above |
| `floe` | `sets.floe.apps = []` | Intentionally no core applications |

Each set has exactly one of `ref` or `apps`. References may point only to
the reserved legacy `core` array; `apps` uses the existing `name`/`id`
entry format. Floe's empty set is an explicit operator decision, not a
missing-manifest fallback. Explicit recipe applications remain supported
for Floe.

Firn carries the normalized catalog `name` into a recipe selector such as
`system.core_flatpak_set`. This needs no new catalog field and preserves
the bootc catalog's ban on the native `product` field. The same selector
chooses data from a readable image manifest or the installer fallback.
New wizard recipes carry the selector; legacy recipes without it retain a
defined legacy-`core` meaning. Unknown nonempty selectors and absent or
malformed requested manifests are configuration errors, never a fallback
to another product. Core opt-out skips set lookup and still installs
explicit applications. Combined IDs are deduplicated in stable order.

Use one shared sideload repository, exported with `flatpak create-usb`,
instead of copying a deployed installation. Firn installs only requested
IDs with `--sideload-repo`; Flatpak supplies dependency deployment,
exports, and ownership. Flathub advertises collection ID
`org.flathub.Stable`, which must be configured in both the isolated seed
builder and the target remote. Ship a local Flathub descriptor with its
signing key so remote setup itself works offline. An absent seed retains
network fallback; unavailable apps are reported separately from structural
repository/setup failures. Existing unrelated target apps are preserved.

## Validation scope

Acceptance is basic APT/Flathub availability plus focused schema and
selection checks. UI behavior, hardware integration, sandboxed Help,
fresh/migrated live installs, local image/ISO builds, and bootc
upgrade/rollback exercises are not acceptance gates. Normal CI runs its
existing builds, `/var` audits, and automated tests; results must describe
the checks actually performed.

Local checks are:

- Confirm APT candidates for retained host support with
  `apt-cache policy kimageformat6-plugins libsane1`.
- Check each of the nine stable x86_64 Flathub refs, for example
  `flatpak remote-info --system --arch=x86_64 flathub org.kde.gwenview`.
  Inspect metadata for offline-export restrictions such as extra-data
  payloads; this does not require installing or launching applications.
- Parse the manifest and check set shape, aliases, IDs, and catalog/set
  consistency. Add focused Firn unit fixtures for selection, opt-out,
  deduplication, and selective provisioning; let Firn CI exercise them.
- Run the existing short Snosi checks when their inputs change:

  ```sh
  ./test/sundog-profile-test.sh
  ./check-duplicate-packages.sh
  ./test/firn-catalog-test.sh
  ./test/firn-installer-iso-test.sh --static
  git diff --check
  ```

## Phase 1 — Specify and record the core-set contract (medium)

- [ ] Finalize the additive manifest schema and recipe selector with Firn
      and first-setup, following the proposed contract above. Keep one
      canonical source per set and byte-identical media vendoring.
- [ ] Define parsing and error behavior for aliases, intentionally empty
      sets, opt-out, explicit applications, legacy recipes, and
      missing/malformed requested data.
- [ ] Define the shared sideload layout, local remote configuration, and
      reporting for refs that cannot be exported offline.
- [ ] Record the new cross-repository decision in frostyard/core, link it
      from `docs/org-adrs.md`, and update the relevant Firn contract with
      its implementing code. Existing accepted ADRs are not rewritten.
- **Done when:** the manifest/selector and sideload contracts are recorded,
  including Floe's empty set, compatibility behavior, and release order.

## Phase 2 — Implement product-aware provisioning and media (large)

- [ ] Extend first-setup's manifest and re-vendor it into
      `shared/firn-installer/core.json`. Embed the canonical data in Sundog
      and at the installer fallback path for composefs selection.
- [ ] Implement Firn's catalog-name-to-recipe selector in
      `internal/tui/wizard.go` and its recipe schema; update
      `internal/steps/bootc.go` and `internal/flatpak/flatpak.go` to resolve
      the exact core set and merge explicit requests.
- [ ] Replace whole-installation tar copying with requested-ID installs
      into Firn's mounted target using `--sideload-repo`. Configure the
      target's remote collection ID even when the remote already exists.
      Preserve unrelated apps and report unavailable apps separately from
      structural setup failures.
- [ ] Update `Justfile`'s `firn-flatpak-seed` recipe to install the union
      of desktop core sets into isolated staging and export supported refs
      and dependencies with `flatpak create-usb --destination-repo=repo`.
- [ ] Update `shared/firn-installer/mkosi.conf` and `_firn-binary` to ship
      the same manifest fallback and local Flathub descriptor/signing key.
- [ ] Update ISO seed assembly and `firn-flatpak-seed-mount` to expose a
      dedicated read-only cache, such as `/run/firn-flatpak-seed/repo`,
      rather than mounting a deployed installation at `/var/lib/flatpak`.
- [ ] Invoke the shared seed builder from
      `.github/workflows/build-installer-iso.yml`, supply its tools, and
      pass the exported seed to assembly. Preserve optional seedless media.
- [ ] Preserve the current seed-builder isolation from the host's own
      Flatpak installations so already-installed host runtimes cannot
      mask an incomplete seed. Keep multi-GiB data outside the initramfs.
- [ ] Check ref availability and export metadata. Add focused unit
      fixtures for selection and selective provisioning, including an
      unrequested seeded app, explicit-only requests, and unavailable-app
      versus structural failures. Run manifest/static checks locally and
      use normal CI for builds and automated fixture coverage.
- [ ] Deliver the compatible Firn release and installer payload before
      proceeding to native application removal. The ISO consumes the
      newest published Firn release; do not introduce a release pin.
- **Done when:** compatible Firn is released, Snosi media carries the
  updated manifest and selective seed path, and availability, focused
  fixtures, and normal CI results are recorded. Live-install evidence is
  not required for this application-selection change.

## Phase 3 — Migrate existing installations (medium)

- [ ] Provide documented, opt-in migration commands in `docs/installing.md`
      for system and per-user installations, using the canonical Sundog
      manifest rather than a separately maintained app list.
- [ ] Install replacements first and check installation success/ref
      presence before offering optional removal of former default GNOME
      apps, Extension Manager, and DistroShelf. Retain Bazaar and
      MissionCenter; deliberately retained user apps remain installed.
- [ ] Specify behavior for system and per-user installations, apps users
      deliberately retained, app data, and an interrupted migration.
      Make rerunning the migration safe and keep app-data deletion outside
      the ordinary replacement operation.
- [ ] Document how to list installed replacement refs, report failed
      downloads, and rerun the same commands after interruption. Application
      launches and hardware behavior are outside the migration checkpoint.
- [ ] Document recovery for a failed migration. Bootc rollback restores
      native image packages but does not undo persistent Flatpak changes;
      application recovery needs its own instructions.
- **Done when:** canonical-data-driven migration commands are delivered
  for both installation scopes, with replacement-first ordering, optional
  cleanup, rerun behavior, and application/data recovery documented.

## Phase 4 — Remove native apps and preserve host integration (medium)

- [ ] After Phases 2 and 3 are ready, remove explicit native `gwenview`,
      `kcalc`, `okular`, and `skanpage` selections from Sundog.
- [ ] Review hard-dependency metadata and explicitly retain
      `kimageformat6-plugins` and `libsane1`. Gwenview currently brings the
      former; Skanpage brings the latter through `libksanecore6-1`.
      `libsane1` owns the host's scanner udev rules. Retain any other
      host-side preview, sharing, scanner-account, or portal support
      identified by that dependency review.
- [ ] Preserve every package required by `mkosi.images/gui-base/mkosi.conf`
      and review sysext compatibility under the
      [existing library-closure contract](../design/sysexts.md).
- [ ] Retain independently packaged `gwenview-doc` and `okular-doc`, along
      with native Help Center support, during this change. These packages
      do not hard-depend on the native applications. Bundled handbooks leave
      with their application packages; sandboxed Help behavior remains
      unverified and is not a cleanup gate.
- [ ] Check retained-package availability and run the short profile and
      duplicate-package guards. Use ordinary image-build CI for dependency
      resolution, `/var` auditing, and built package-manifest checks.
- [ ] Update `shared/firn-installer/README.md`, relevant living designs and
      integration contracts, user migration guidance, and this plan's
      status/evidence with the scoped check results and delivery order.
- **Done when:** native selections are removed after provisioning and
  migration support are delivered, required host support is explicitly
  composed, and availability/static checks plus normal CI results are
  recorded. No UI or bootc lifecycle proof is required.

## Open questions

- **Offline exportability:** inspect the selected refs' metadata in Phase 2
  and define reporting/network fallback for any ref that `create-usb`
  cannot export, including extra-data payloads. A shared cache does not
  imply offline availability for every explicitly requested application.

## References

- Prerequisite: [native desktop completeness](2026-10-05-sundog-desktop-completeness-plan.md).
- Independent immediate fix: [printer support](2026-10-05-sundog-printer-support-plan.md).
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
- Selective seed mechanics: [Flatpak create-usb](https://manpages.debian.org/trixie/flatpak/flatpak-create-usb.1.en.html),
  [Flatpak install](https://manpages.debian.org/trixie/flatpak/flatpak-install.1.en.html).
- Constraints: [sysext design](../design/sysexts.md),
  [risk tiers](../risk-tiers.md), [review rubric](../review-rubric.md).
