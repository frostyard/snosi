# Plymouth boot splash for snow-ab / snowfield-ab (+ Snow-branded theme)

Date: 2026-07-17
Status: approved (amended — see "Amendment" at the end; delivery is
ExtraTrees, not SkeletonTrees)

## Problem

The native A/B desktop images (`snow-ab`, `snowfield-ab`) boot with no
graphical splash. Plymouth is already installed and present in their initrds
(the `shared/packages/snow` set ships `plymouth`/`plymouth-themes`/
`plymouth-label`), but plymouth only shows a graphical splash when `splash`
or `rhgb` is on the kernel command line. bootc installs get `rhgb quiet`
injected by bootc at install time (verified on a live bootc snow host);
the native A/B UKI cmdline is baked at build time as
`console=ttyS0 rd.luks=1 rd.etc.overlay=1` (`shared/outformat/ab-root/
mkosi.conf`) plus `lockdown=integrity` (`shared/native-ab-secure/mkosi.conf`)
— no splash trigger, so plymouth sits in text/details mode.

Additionally, the images have no Snow branding: the effective theme is
Debian's default (`bgrt` on hardware — the OEM firmware logo).

## Decisions (user-confirmed)

- Kernel command line gains `splash` only — not `quiet`. `console=ttyS0` is
  the only `console=` argument, so kernel messages never hit the screen
  anyway; keeping serial verbose preserves the QEMU harnesses' logs.
- Snow-branded theme: logo + spinner style (plymouth `two-step` plugin),
  using the FirstSetup flower artwork
  (`first-setup/data/icons/hicolor/scalable/apps/org.frostyard.FirstSetup-flower.svg`)
  rendered once to a committed `watermark.png`.
- snowfield-ab shares the identical theme.
- The theme applies to ALL snow/snowfield images, bootc and native (side
  effect: bootc hosts show the flower instead of the OEM bgrt logo after
  their next update). The `splash` karg is only effective on native (inert
  on bootc, which builds no UKI).
- cayo-ab / cayo-ab-raw are untouched (servers stay text; they never include
  the snow composition fragment).
- Validation: full build + QEMU secure-boot harness run for snow-ab.

## Design

### 1. Kernel command line

`shared/composition/snow/mkosi.conf` gains:

```
KernelCommandLine=splash
```

with a comment explaining the bootc-inert / native-effective scoping.
Rationale for this location: the fragment is included by exactly the four
desktop consumers (snow, snowfield, snow-ab, snowfield-ab) and no server
profile, and the production native profiles are contractually
`[Config]/[Output]/[Include]`-only, so the setting must live in a fragment.
mkosi list-setting accumulation appends it to the ab-root/secure fragments'
values; final native cmdline:
`console=ttyS0 rd.luks=1 rd.etc.overlay=1 lockdown=integrity splash`
(exact order determined by Include order; verified via `mkosi summary`).

### 2. Snow theme

Mirrors Debian's `bgrt` theme pattern (a `.plymouth` file whose `ImageDir`
points at the spinner theme's asset directory — cross-theme `ImageDir` is
the upstream-supported mechanism bgrt itself uses, and
`plymouth-populate-initrd` follows it when embedding themes in initrds).

New files, all under a new `shared/snow/skeleton/` tree:

- `usr/share/plymouth/themes/snow/snow.plymouth` — `ModuleName=two-step`,
  `ImageDir=/usr/share/plymouth/themes/spinner`, black
  `BackgroundStartColor`/`EndColor`, centered watermark
  (`WatermarkHorizontalAlignment=.5`, vertical ~.5), throbber/dialog
  alignment below it, `UseFirmwareBackground=false` (unlike bgrt — we want
  the flower, not the OEM logo), password-dialog and message settings
  copied from bgrt's proven values.
- `usr/share/plymouth/themes/spinner/watermark.png` — the flower SVG
  rendered at ~256 px via GdkPixbuf/librsvg (available on the dev host),
  committed as the single binary asset. Placed in the spinner directory
  because the two-step plugin loads `watermark.png` from `ImageDir`; the
  path is not owned by any deb, so dpkg never touches or removes it.
  Provenance recorded in a README or comment beside the theme.
- `etc/plymouth/plymouthd.conf` — `[Daemon]\nTheme=snow\nShowDelay=0`.
  This path is a dpkg **conffile** of the `plymouth` package: a copy that
  exists before package installation is treated as a locally-modified
  conffile and kept, so the skeleton-delivered file survives.

### 3. Delivery: SkeletonTrees, not ExtraTrees

`shared/composition/snow/mkosi.conf` gains
`SkeletonTrees=%D/shared/snow/skeleton`.

Reason (same as the existing `30-bootc-standard.conf` SkeletonTrees fix):
initrd generation happens DURING package installation — the linux-surface
kernel runs dracut synchronously in its postinst, and the backports kernel
via a dpkg trigger at the end of the same apt run — and that is when
`plymouth-populate-initrd` resolves the default theme and embeds its
assets. `ExtraTrees=` land after packages, too late for the initrd. The
skeleton places theme, watermark, and `Theme=snow` config before any
package installs, covering both kernels and both transports.

### 4. Out of scope

- No `quiet`, no `rhgb` on native.
- No change to cayo profiles, the installer ISO, or the contracts' frozen
  naming/publication surfaces (the cmdline is not a frozen contract item).
- No custom animation (script plugin) — spinner assets are reused from
  Debian's package.

## Validation plan

1. Build `snow-ab`. Assert:
   - `splash` present in the UKI `.cmdline` PE section
     (`objcopy --dump-section`).
   - snow theme + watermark + spinner assets inside the UKI's initrd.
   - `Theme=snow` in the image's `/.etc.lower/plymouth/plymouthd.conf`.
2. `sudo PROFILE=snow-ab test/native-ab-secure-boot-test.sh` (default
   mode) — proves the serial LUKS-passphrase pump still works with splash
   active (plymouth keeps a text prompt on serial while rendering graphics
   on DRM — this run is the empirical proof), first boot, TPM auto-unlock,
   GDM, and a signed update hop.
3. Static: `test/native-ab-contracts-test.sh`, shellcheck-affected checks,
   `mkosi --profile <p> summary` diff confirming only the intended
   cmdline/skeleton additions.
4. bootc `snow` build: artifact-level check that the theme and
   `Theme=snow` land and its initrd embeds the snow theme (no QEMU run).
5. Docs: CLAUDE.md and yeti/ updates.

## Risks

- Plymouth graphical mode changing the serial ask-password flow: mitigated
  by the harness run (step 2); the harness's prompt matcher already handles
  both plymouth and raw-agent prompt shapes.
- Theme misconfiguration falling back to text mode: two-step + cross-dir
  ImageDir is bgrt's own mechanism, and step 1's initrd inspection catches
  missing assets before any boot test.
- bootc hosts changing appearance unexpectedly: accepted and intended
  (user-approved side effect).

## Amendment (2026-07-17, after the first snow-ab build)

Two of this spec's assumptions were empirically falsified by the first
build; the delivery mechanism changed accordingly. Goals, theme design,
karg, scoping, and validation are unchanged.

1. **dpkg conffile semantics assumption was wrong.** A file pre-existing at
   a conffile path does NOT get silently kept on first install: dpkg
   prompts (`plymouthd.conf (Y/I/N/O/D/Z)`), and mkosi's non-interactive
   apt run has no stdin, so dpkg dies with "end of file on stdin at
   conffile prompt" and the build fails (`Errors were encountered while
   processing: plymouth`). SkeletonTrees delivery of
   `/etc/plymouth/plymouthd.conf` is therefore impossible.
2. **The skeleton timing rationale was unnecessary anyway.** The initrd
   that actually ships (native UKI via `$ARTIFACTDIR/io.mkosi.initrd`, and
   the bootc image's `/usr/lib/modules/<kver>/initramfs.img`) is generated
   by `shared/kernel/scripts/postinst/mkosi.postinst.chroot` — a
   PostInstallationScript that runs AFTER ExtraTrees land. The dpkg-time
   dracut runs (surface synchronous postinst, backports trigger) produce
   only incidental artifacts; a wrong theme there breaks nothing. (The
   `30-bootc-standard.conf` skeleton precedent solves a different problem:
   that dpkg-time run *crashing* on a missing dracut module.)

**Revised delivery:** the three payload files ship in the existing
`shared/snow/tree` ExtraTrees (`usr/share/plymouth/themes/snow/snow.plymouth`,
`usr/share/plymouth/themes/spinner/watermark.png`,
`etc/plymouth/plymouthd.conf`); no `shared/snow/skeleton` exists, and the
static test now asserts its ABSENCE. The ExtraTrees overwrite of the
conffile happens after dpkg finishes — the standard way this repo ships
`/etc` config — and plymouth-populate-initrd (inside the postinst dracut
run) resolves `Theme=snow` from it.
