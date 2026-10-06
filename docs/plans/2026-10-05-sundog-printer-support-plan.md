# Plan: Add Sundog printer-management support

**Status:** Planned — independent package fix ready for immediate implementation
**Last verified:** 2026-10-05

Add KDE's missing printer-management backend and automatic printer-setup
helpers to Sundog. This is a small follow-up to the
[native desktop-completeness plan](2026-10-05-sundog-desktop-completeness-plan.md)
and implements Sundog's desktop composition under
[ADR-0016](../adr/0016-name-kde-bootc-product-sundog.md). It can land
independently of the
[Flatpak-defaults plan](2026-10-05-sundog-flatpak-defaults-plan.md).

## Evidence and scope

The operator's KDE Printers panel reports that a printer support package
providing convenience features is missing. The 2026-10-05 investigation
confirmed that CUPS, `print-manager`, `cups-pk-helper`, and `ipp-usb` are
installed, while both packages below are absent:

| Package | Purpose | Available Trixie candidate |
| --- | --- | --- |
| `system-config-printer-common` | Backend and D-Bus helper used by KDE for discovery and recommended-driver selection | `1.5.18-4` |
| `system-config-printer-udev` | Automatic detection and setup of plugged-in printers | `1.5.18-4` |

Debian's `print-manager` recommends both packages. mkosi skips Recommends,
and `shared/packages/sundog/mkosi.conf` does not explicitly select them.
Snow already selects both in `shared/packages/snow/mkosi.conf`.

Acceptance is package availability and static composition checks. Printer
UI/hardware exercises, local image builds, live installs, and bootc
upgrade/rollback testing are outside this package fix. Normal CI retains
its existing image-build and `/var` audit checks.

## Phase 1 — Select the missing packages (small)

- [ ] Add `system-config-printer-common` and `system-config-printer-udev`
      to the printing block in
      [Sundog's package list](../../shared/packages/sundog/mkosi.conf).
- [ ] Add a short comment explaining that these recommended KDE helpers
      need explicit selection because mkosi skips Recommends.
- **Done when:** both helpers are explicit Sundog selections with available
  Trixie candidates.

## Phase 2 — Check and deliver the package fix (small)

- [ ] Run the short availability and static checks:

  ```sh
  apt-cache policy system-config-printer-common system-config-printer-udev
  ./test/sundog-profile-test.sh
  ./check-duplicate-packages.sh
  git diff --check
  ```

- [ ] Confirm each package has a candidate other than `(none)` and record
      the actual check results with the implementation.
- [ ] Report the normal image-build CI result and resolve any actual
      composition or `/var` audit failure through the existing rules.
- [ ] Update this plan's status and the `docs/README.md` index as work lands.
- **Done when:** the package selections pass the short checks and ordinary
  CI, with recorded results; the Flatpak migration is not a delivery gate.

## References

- Implements: [architecture overview](../design/overview.md),
  [build pipeline](../design/build-pipeline.md),
  [testing](../design/testing.md).
- Decision: [ADR-0016](../adr/0016-name-kde-bootc-product-sundog.md).
- Preceding work: [native desktop completeness](2026-10-05-sundog-desktop-completeness-plan.md).
- Separate work: [Sundog Flatpak defaults](2026-10-05-sundog-flatpak-defaults-plan.md).
