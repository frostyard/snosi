# Plan: Complete Sundog's native Plasma desktop

**Status:** Proposed
**Last verified:** 2026-10-05

This is the immediate Sundog work: fix missing desktop helpers and provide
the settings, previews, hardware controls, and offline documentation
expected from Plasma. It implements Sundog's existing
[product decision](../adr/0016-name-kde-bootc-product-sundog.md) and
[composition](../design/overview.md). Standalone applications move to
Flatpak in the separate
[follow-up plan](2026-10-05-sundog-flatpak-defaults-plan.md), after its
installer and migration paths are ready.

## Evidence and scope

An operator reported that clicking KRunner's Configure icon fails with:

```text
kf.kio.gui: Could not find an executable named: "kcmshell6"
```

Debian Trixie's `libkf6kcmutils-bin` supplies `/usr/bin/kcmshell6`.
`libkf6kcmutils6` recommends that package, but mkosi does not install
Recommends and `shared/packages/sundog/mkosi.conf` does not select it.
The same split exists for other libraries and their executable helpers:
Dolphin's Baloo widgets launch `baloo_filemetadata_temp_extractor`, supplied
by the recommended `libbaloowidgets-bin` package.

The existing `test/sundog-profile-test.sh` passed during investigation.
Its static package contract does not currently establish that these
runtime helpers are available. The package audit used Debian Trixie
metadata and package contents; it is not installed-image validation.
The local composition was checked at commit `4681c32`.

The agreed additions are:

| Feature | Explicit package selections |
| --- | --- |
| Desktop helpers, editing, locking, monitoring, spell checking | `libkf6kcmutils-bin`, `libbaloowidgets-bin`, `kmenuedit`, `keditbookmarks`, `kde-config-screenlocker`, `ksystemstats`, `plasma-systemmonitor`, `sonnet6-plugins`, `hunspell-en-us` |
| Dolphin previews | `ffmpegthumbs`, `kdegraphics-thumbnailers`, `qt6-image-formats-plugins` |
| Wallet management | `kwalletmanager` |
| GTK appearance and preview | `kde-config-gtk-style`, `kde-config-gtk-style-preview`, `breeze-gtk-theme`, `xsettingsd` |
| Thunderbolt controls | `plasma-thunderbolt` |
| Info Center and its probe tools | `kinfocenter`, `aha`, `clinfo`, `dmidecode`, `libdisplay-info-bin`, `mesa-utils`, `pulseaudio-utils`, `vulkan-tools`, `wayland-utils` |
| Local Help and separately packaged handbooks | `khelpcenter`, `dolphin-doc`, `gwenview-doc`, `okular-doc`, `plasma-desktop-doc`, `plasma-workspace-doc` |

`plasma-disks` and `smartmontools` are deferred by explicit operator choice.
There is no SMART-specific state integration in this work.

Some supporting packages already arrive through hard dependencies:
`systemsettings` through `kde-config-flatpak`, `kde-cli-tools` through
`kde-config-fcitx5`, and `kimageformat6-plugins` through native Gwenview.
Info Center's `iproute2` and `pciutils` are already selected in base.
Ark, Kate/KatePart, Konsole, KCalc, KMenuEdit, KEditBookmarks, and
KWalletManager bundle English handbooks in their application/data packages.

WebKit's Enchant dependency already requires a dictionary alternative.
Selecting `hunspell-en-us` explicitly makes the English spell-checking
baseline deterministic; Sonnet's plugins alone do not supply dictionaries.

Keep recommendations selective. Sundog's Wayland-only, Fcitx, tuned,
Flatpak-backed Discover, and shared desktop-library contracts remain the
constraints enforced by `test/sundog-profile-test.sh` and the
[sysext design](../design/sysexts.md).

## Phase 1 — Compose and build the desktop payload (small)

- [ ] Add the agreed packages to `shared/packages/sundog/mkosi.conf` in
      short, commented feature groups. Keep helpers explicit even when a
      newly selected application also hard-depends on them.
- [ ] Run the existing profile and duplicate-package guards:

  ```sh
  ./test/sundog-profile-test.sh
  ./check-duplicate-packages.sh
  ```

- [ ] Build through the existing entry point:

  ```sh
  just sundog
  ```

- [ ] Review dependency resolution and the resulting manifest. Confirm the
      requested selections and the complete `gui-base` closure.
- [ ] Resolve any actual new build-time `/var` entries through
      `shared/composition/sundog/var-outcomes.txt` and shipped tmpfiles
      rules where needed. The existing `var-audit.finalize` must pass;
      adding a broad discard pattern is not evidence of runtime recovery.
- [ ] Inspect `output/sundog` for executable helpers, KCM plugins,
      thumbnail/image plugins, the GTK preview executable, and English
      handbook and Hunspell dictionary files. Check that the files needed
      by the visible actions are usable, rather than relying solely on
      package names.
- [ ] Identify the installed GTK integration's XSettings/portal provider
      and its session activation path. Installing `xsettingsd` alone does
      not establish activation; use Plasma's existing provider where it
      handles the session and avoid starting a competing provider.
- **Done when:** a Sundog build passes the existing guards and `/var`
  audit, and its artifact contains the requested executable, plugin, and
  handbook payloads with recorded inspection results.

## Phase 2 — Verify installed desktop behavior (medium)

- [ ] Run the existing bootc installation checks described in
      [testing](../design/testing.md):

  ```sh
  just test-install output/sundog
  ```

- [ ] Test the candidate in a fresh Plasma session on a fresh installation
      and on an existing Sundog installation updated to the candidate.
      Record the candidate image identity and which path each result covers.
- [ ] Check the following user-visible outcomes:

  | Feature | Acceptance check |
  | --- | --- |
  | KRunner | Configure opens its settings panel without a missing-executable error. |
  | Menu and bookmarks | Edit Applications and Konsole bookmark editing open their editors. |
  | Screen locking | The Screen Locking panel opens and saves a user setting; locking still works. |
  | Monitoring | Plasma System Monitor and a system-monitor widget show live sensor data. |
  | Spell checking | With English (US) selected, Kate accepts a correctly spelled control word and flags a deliberately misspelled word using the installed Hunspell dictionary. |
  | Dolphin metadata | On-demand metadata works for a file not already indexed by Baloo. |
  | Dolphin previews | Enabled video, document, and supported additional image previews render. |
  | Wallet | KWalletManager opens and manages a test entry in the user's wallet. |
  | GTK appearance | The settings panel, theme selection, and Preview action work for GTK3 applications; XWayland GTK clients receive changed font/icon settings through the active XSettings/portal provider. |
  | Info Center | Probe-backed pages run their tools and display results or a valid no-capability result, not missing-command errors. |
  | Local Help | Plasma and shipped-application handbooks open with networking disabled. |
  | Thunderbolt | The panel opens; on suitable hardware, device authorization works through the existing bolt service. |

- [ ] Record hardware-dependent checks as pending until suitable hardware
      evidence exists. A VM panel-opening check is not Thunderbolt
      authorization evidence. Host GTK3 theme support does not establish
      theme availability inside every Flatpak or theming of libadwaita apps.
- [ ] Capture the preceding deployment identity and document recovery using
      the existing bootc rollback workflow if the candidate regresses the
      desktop. Wallet and desktop configuration remain persistent user state.
- **Done when:** fresh-install and updated-host desktop checks pass with
  recorded image identities, and required hardware checks have suitable
  evidence. Unavailable hardware checks keep this phase open.

## Phase 3 — Review and deliver (small)

- [ ] Update relevant living documentation to describe the shipped desktop
      payload and its verification. Preserve the distinction between bootc
      mechanics tests and live Firn/Secure Boot lifecycle evidence.
- [ ] Submit the implementation as a Tier 3 image-composition PR under
      [risk tiers](../risk-tiers.md), with actual build/test results and
      rollback behavior, for maintainer review.
- [ ] Update this plan's status and checkboxes as work lands; link the
      implementation and retained validation evidence.
- **Done when:** the reviewed implementation is merged, validation is
  recorded, and the living docs identify the desktop behavior that shipped.

## Open questions

- **Validation host:** identify the fresh-install and existing-install
  environments before Phase 2, including access to Thunderbolt hardware.
- **Artifact paths:** verify the current Debian plugin and handbook paths
  during Phase 1 instead of treating upstream layout as a permanent ABI.

## References

- Implements: [architecture overview](../design/overview.md),
  [build pipeline](../design/build-pipeline.md),
  [testing](../design/testing.md).
- Decision: [ADR-0016](../adr/0016-name-kde-bootc-product-sundog.md).
- Constraints: [sysext design](../design/sysexts.md),
  [risk tiers](../risk-tiers.md), [review rubric](../review-rubric.md).
- Next: [Sundog Flatpak defaults](2026-10-05-sundog-flatpak-defaults-plan.md).
- Package evidence: [Debian Trixie amd64 package index](https://deb.debian.org/debian/dists/trixie/main/binary-amd64/Packages.xz).
