# Plan: Complete Sundog's native Plasma desktop

**Status:** In progress — composition and VM package validation complete;
manual laptop/hardware validation deferred
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
Recommends and the original `shared/packages/sundog/mkosi.conf` did not select it.
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

- [x] Add the agreed packages to `shared/packages/sundog/mkosi.conf` in
      short, commented feature groups. Keep helpers explicit even when a
      newly selected application also hard-depends on them.
- [x] Run the existing profile and duplicate-package guards:

  ```sh
  ./test/sundog-profile-test.sh
  ./check-duplicate-packages.sh
  ```

- [x] Build through the existing entry point:

  ```sh
  just sundog
  ```

- [x] Review dependency resolution and the resulting manifest. Confirm the
      requested selections and the complete `gui-base` closure.
- [x] Resolve any actual new build-time `/var` entries through
      `shared/composition/sundog/var-outcomes.txt` and shipped tmpfiles
      rules where needed. The existing `var-audit.finalize` must pass;
      adding a broad discard pattern is not evidence of runtime recovery.
- [x] Inspect `output/sundog` for executable helpers, KCM plugins,
      thumbnail/image plugins, the GTK preview executable, and English
      handbook and Hunspell dictionary files. Check that the files needed
      by the visible actions are usable, rather than relying solely on
      package names.
- [x] Identify the installed GTK integration's XSettings/portal provider
      and its session activation path. Installing `xsettingsd` alone does
      not establish activation; use Plasma's existing provider where it
      handles the session and avoid starting a competing provider.
- **Done when:** a Sundog build passes the existing guards and `/var`
  audit, and its artifact contains the requested executable, plugin, and
  handbook payloads with recorded inspection results.

## Phase 2 — Verify installed desktop behavior (medium)

All build and runtime validation uses VMs. The operator narrowed this change's
acceptance to desktop package behavior: additional deployment, rollback, and
signing checks are out of scope. The laptop must not be installed, updated, or
rebooted by automation. Its eventual desktop and Thunderbolt checks will be
manual, under a test plan agreed after VM package validation.

- [x] Run the initial existing bootc installation checks described in
      [testing](../design/testing.md):

  ```sh
  just test-install output/sundog
  ```

- [x] Test the candidate in a fresh Plasma session on a fresh installation
      and on an existing Sundog installation updated to the candidate.
      Record the candidate image identity and which path each result covers.
- [x] Check the VM-applicable user-visible outcomes below; Thunderbolt device
      authorization remains a deferred manual hardware check.

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

- [x] Record hardware-dependent checks as pending until suitable hardware
      evidence exists. A VM panel-opening check is not Thunderbolt
      authorization evidence. Host GTK3 theme support does not establish
      theme availability inside every Flatpak or theming of libadwaita apps.
- The preceding deployment identity is retained with the VM results. Existing
  bootc recovery guidance remains applicable; exercising deployment or rollback
  machinery is excluded from this package-only validation scope. Rollback
  behavior has not been verified for this candidate. Wallet and desktop
  configuration remain persistent user state.
- **Done when:** fresh-install and updated-host desktop checks pass with
  recorded image identities, and required hardware checks have suitable
  evidence. Unavailable hardware checks keep this phase open.

## Phase 3 — Review and deliver (small)

- [x] Update relevant living documentation to describe the composed desktop
      payload and its verification. Preserve the distinction between bootc
      mechanics tests and live Firn/Secure Boot lifecycle evidence.
- [ ] Submit the implementation as a Tier 3 image-composition PR under
      [risk tiers](../risk-tiers.md), with actual build/test results and
      explicit unverified aspects, for maintainer review. Apply the package-only
      validation scope above; document the existing recovery workflow without
      requiring additional rollback tests.
- [ ] Update this plan's status and checkboxes as work lands; link the
      implementation and retained validation evidence.
- **Done when:** the reviewed implementation is merged, validation is
  recorded, and the living docs identify the desktop behavior that shipped.

## Open questions

- **Manual laptop test plan:** agree on the final operator-run desktop and
  Thunderbolt authorization checks after the VM results are reviewed.

## Retained validation — 2026-10-05

Validation was performed on `benjamin/feat/sundog-desktop-completeness`, based
on `8e36fed`. The isolated `sundog-desktop-build` VM built image version
`20261005155704` through `just sundog`. Both profile/package guards passed.
Artifact inspection confirmed all 33 requested selections and all 54
`gui-base` packages. The unchanged `/var` map classified 7,436 paths; no new
tmpfiles or discard entries were needed. The artifact was 6.2 GiB.

Desktop checks used `sundog-desktop-fresh-uefi` and
`sundog-desktop-update-uefi`, disposable copies of the operator's prepared
Incus templates. Both used the same desktop payload. Their local unsigned UKI
fixture reports image digest
`sha256:246cfb0f13b6d041c28ef485a61af7e3cbb7b6db9c3e1586241be148ecdcd9b7`.
The original baselines and installer medium were retained. Initial installation
mechanics checks also passed all five tiers (33 assertions); these are retained
results, not new lifecycle requirements for the package addition.

| Outcome | Recorded VM result |
| --- | --- |
| KRunner | Baseline Configure reproduced the missing-`kcmshell6` error; both candidates opened KRunner Settings through the same action. |
| Editors | Both editors launched; the updated VM's launcher opened KMenuEdit through Edit Applications, and the fresh VM's Konsole opened KEditBookmarks through Edit Bookmarks. |
| Locking | Both panels opened; the updated VM saved `LockOnResume=false` through the panel and its Apply action. Explicit locking reported active. |
| Monitoring | Both System Monitor overview pages showed live CPU/memory values; memory-monitor widgets displayed sensor data. |
| Spelling | Both Sonnet/Hunspell checks accepted `hello` and rejected `helllooo`; Kate's fresh-VM spelling dialog flagged `helllooo` with American English (United States) selected. |
| Metadata | Both Dolphin Information panels displayed `64 × 32` for a TIFF under `/var/tmp`, outside the Baloo index. The updated VM also displayed its generated-by metadata. |
| Previews | Both KIO preview jobs rendered video, PDF, TIFF, and WebP previews; additional image-format decoding passed. |
| Wallet | Both managers opened; the updated VM created a test wallet and round-tripped a non-secret test entry through the installed KWallet API. |
| GTK | Both sessions loaded `gtkconfig` and ran `xsettingsd`; GTK3 Preview opened, including the updated VM's actual Preview action. Fresh XWayland GTK3 clients received changed font/icon/theme values with ini/dconf/portal fallback disabled. |
| Info Center | OpenCL, Vulkan, GLX, EGL, audio, Wayland, CPU, and EDID pages displayed their tool output. OpenCL reported a valid zero-platform result. |
| Local Help | Both VMs rendered 14 English handbook paths through KIO with the guest NIC down; Help Center displayed the Dolphin handbook. |
| Thunderbolt | Both panels opened. Actual device authorization is pending manual hardware validation. |

Observed Debian paths include `/usr/bin/kcmshell6`,
`/usr/bin/baloo_filemetadata_temp_extractor`,
`/usr/lib/x86_64-linux-gnu/libexec/gtk3_preview`, the `kf6/sonnet` and
`kf6/thumbcreator` Qt plugin directories, `/usr/share/hunspell/en_US.{aff,dic}`,
and `/usr/share/doc/HTML/en/`. The packaged `gtkconfig` metadata has KDED
autoload enabled at phase 1. Its existing session provider handled XSettings;
no additional activation service was composed.

Raw non-secret results and repeatable package-check scripts are retained locally
in `output/sundog-desktop-validation/`. The baseline automation and credentials
remain in the separate private `output/incus-baselines/` directory. Generated
artifacts and credentials are not committed. Hardware results, maintainer
review, PR submission, and merge remain pending.

## References

- Implements: [architecture overview](../design/overview.md),
  [build pipeline](../design/build-pipeline.md),
  [testing](../design/testing.md).
- Decision: [ADR-0016](../adr/0016-name-kde-bootc-product-sundog.md).
- Constraints: [sysext design](../design/sysexts.md),
  [risk tiers](../risk-tiers.md), [review rubric](../review-rubric.md).
- Next: [Sundog Flatpak defaults](2026-10-05-sundog-flatpak-defaults-plan.md).
- Package evidence: [Debian Trixie amd64 package index](https://deb.debian.org/debian/dists/trixie/main/binary-amd64/Packages.xz).
