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

## Amendment 2 (2026-07-17, after visual verification in QEMU)

`splash` alone produced NO visible splash. Root-caused with
`plymouth.debug=file:/dev/ttyS1` on a second QEMU serial port:

1. **A configured serial console suppresses the splash entirely.** The
   shared native cmdline carries `console=ttyS0`; plymouthd (24.004.60)
   sees the serial console in `/sys/class/tty/console/active` and logs
   `serial consoles detected, managing them with details forced` — details
   mode globally, and DRM devices are never probed. This applies to real
   hardware identically (the cmdline is baked into the signed UKI).
   `plymouth.force-splash` does not help (no graphical device is ever
   attached).
2. **`plymouth.ignore-serial-consoles` restores DRM probing, but the
   INITRD then loses a race**: virtio-gpu's card0 emits a premature udev
   `change` event before its devnode exists; plymouthd's open fails with
   ENOENT, it permanently falls back to the text splash, and the real
   `add` event milliseconds later is never re-tried. Reproduced with both
   virtio-vga and virtio-gpu-pci (the harness's device). Debian's kernel
   ships no simpledrm (only builtin simplefb, which plymouth ignores), so
   there is no instant boot-time DRM device to prevent the race.

**Final design:** the splash runs from the REAL ROOT only, with the VT as
the preferred console.

- `shared/composition/snow/mkosi.conf`:
  `KernelCommandLine=splash plymouth.ignore-serial-consoles`.
- The native-only dracut override
  (`shared/outformat/ab-root/tree/.../30-bootc-standard.conf`) adds
  `omit_dracutmodules+=" plymouth "` — no plymouth in native initrds
  (no-op for cayo, which never installs plymouth). The real root's
  `plymouth-start.service` (statically wanted by sysinit.target in the
  plymouth deb) starts after DRM is long up — deterministic graphical
  splash on QEMU and hardware.
- bootc images keep initrd plymouth (their base dracut conf is unchanged;
  the static test asserts the omit stays native-only).

## Amendment 3 (2026-07-17, after the real-root plymouthd segfault)

Amendment 2's design crashed plymouthd in the real root:
`ply_terminal_set_disabled_input` SIGSEGV via the DRM renderer's
`open_input_source` — a known upstream NULL-terminal bug (Ubuntu
LP#2103533; NULL guards first released in plymouth 26.134.222; Fedora
backports them; Debian — including sid's 24.004.60-5.2 — does not).
Trigger in our images: `plymouth.ignore-serial-consoles` + `/dev/console`
being the (ignored) serial console + XKB config present in the real root
leaves plymouthd's local console terminal NULL; the initrd never crashed
only because it lacks `/etc/default/keyboard`.

**Fix, proven by screendump (the flower renders, no crash):** make the VT
the preferred console on desktop natives — `KernelCommandLine=console=tty0`
in `shared/native-ab/channels/{snow,snowfield}/mkosi.conf` (the channel is
the only desktop fragment `[Include]`d after ab-root, so tty0 lands after
`console=ttyS0` and wins `/dev/console`). cayo's channel stays serial-only.

Consequence handled: `/dev/console`=tty0 moves
`systemd-ask-password-console`'s LUKS prompt off the serial port, which
the QEMU harnesses' console pump depends on. Restored by
`snosi-ask-password-serial.{service,path}` (ab-root tree, static
sysinit.target.wants link, `install_items` into the native initrd via the
same dracut conf): `systemd-tty-ask-password-agent --watch
--console=/dev/ttyS0`, Condition-gated on BOTH `console=tty0` (desktop
natives only) and `console=ttyS0` + `/dev/ttyS0` existing. Prompts appear
on the VT (visible on hardware — an improvement over the old serial-only
prompt) AND on serial (pump-compatible, raw-agent shape). Kernel printk
still reaches serial (printk goes to every registered console); systemd
status output moves to tty0 (hidden behind the splash).

Known cosmetic trade-off: without `quiet`, kernel messages are now visible
on the hardware screen for the few seconds before the real-root splash
starts (the earlier "kernel messages never hit the screen" rationale for
skipping `quiet` was invalidated by `console=tty0`). Flagged for a
follow-up decision rather than silently added — `quiet` was explicitly
declined during design.
