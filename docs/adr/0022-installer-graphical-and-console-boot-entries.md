# 0022 — Offer graphical and console entries on the installer ISO

- **Status:** Proposed
- **Date:** 2026-10-26

## Context

The Firn installer ISO (`firn-installer` profile) packs its whole rootfs
into the kernel's initramfs and runs from RAM. It had no visible boot menu
and started the firn TUI kiosk on tty1 and ttyS0. Firn ADR-0007 removed
cage, GTK and Mesa from the medium to save RAM. Firn now ships firn-gui
(firn ADR-0021, frostyard/firn#122). firn-gui is a native-UI wizard that
dlopens GTK 3, Pango and Cairo, runs firn's install pipeline in-process,
and draws with OpenGL or on the CPU. Its `frostyard-firn-gui` package
declares no dependencies.

Debian's only kiosk-sized Wayland compositors (cage, labwc, weston) all
depend on `libgbm1`, which pulls `mesa-libgallium` and `libllvm19`. The
ISO's stock Debian 6.12 kernel has no simpledrm: a DRM device exists only
once a native driver binds.

The initramfs rootfs is a tmpfs capped at half of the RAM the kernel
manages. The compressed initramfs image stays reserved until it is
unpacked, so a machine needs about twice the unpacked rootfs plus the
initramfs size just to boot.

Measured on local builds of the same tree, with and without this change
(rootfs apparent size, `build-iso.sh` output, and QEMU unpack probes):

| | Before | After | Delta |
|---|---|---|---|
| Packages | 318 | 439 | +121 |
| Unpacked rootfs (RAM) | 1482 MiB | 1774 MiB | +292 MiB |
| Initramfs (zstd) | 574 MiB | 664 MiB | +90 MiB |
| ISO | 680 MiB | 783 MiB | +103 MiB |
| RAM needed to unpack | 3584–3840 MiB | 4352–4480 MiB | about +0.7 GiB |

`libllvm19`, `mesa-libgallium` and `libz3-4` account for 191 MiB of the
added rootfs. GTK 3 with its data accounts for 54 MiB, and firn-gui itself
for 12 MiB.

## Decision

The ISO's GRUB menu offers "Install snosi (graphical)" and "Install snosi
(console)". It shows for 5 seconds on the display and, through firmware
console redirection, on serial. Console is the default. The ISO is
UEFI-only, and the same `grub.cfg` serves the optical (ISO9660) and
USB-stick (GPT ESP) paths.

Each entry selects a boot target with systemd's `systemd.unit=` flag. The
command lines are otherwise identical:

- `firn-console.target` wants `firn-kiosk.service`, the TUI on tty1. It is
  also `default.target`.
- `firn-graphical.target` wants `firn-gui.service`, which runs
  `/usr/lib/firn/firn-gui-session`. That wrapper settles udev, waits up to
  10 seconds for `/dev/dri/card*`, then executes `cage -d -s --
  /usr/bin/firn-gui` as root, so firn-gui skips its pkexec re-exec.
- The serial TUI kiosk (`firn-kiosk-serial@ttyS0`) and the flatpak seed stay
  in `multi-user.target` and run under both entries. A serial-only machine
  gets the console installer whichever entry boots.

`firn-gui.service` always ends with a frontend on tty1:

- With no DRM device, the wrapper exits 77. `RestartPreventExitStatus=77`
  skips the retries, and `OnFailure=` starts the TUI at once.
- Three crashes within 60 seconds take the same `OnFailure=` path.
- A clean exit (Quit or Close; firn-gui exits 0 even after a failed install)
  triggers `OnSuccess=`, which also starts the TUI.

The unit has no `Condition*` lines, so its `Conflicts=getty@tty1.service`
is safe. firn-gui chooses OpenGL or CPU drawing itself, so a VM without GPU
acceleration works.

The ISO lists `frostyard-firn-gui` unpinned, like `frostyard-firn`. It also
lists the graphics stack explicitly: cage, GTK 3, Pango, Cairo, HarfBuzz,
fontconfig, libepoxy, Mesa EGL, the DejaVu fonts and xkb-data. The postinst
fails the build if firn-gui, cage, any library firn-gui loads, or the fonts
are missing. Only this profile may install `frostyard-firn-gui`
(`test/firn-gui-scope-test.sh`).

The higher minimum RAM is accepted. Test VMs run with 6 GiB.

## Consequences

- **Every boot carries the graphics stack.** The console entry and
  serial-only machines carry it too, because both entries share one
  initramfs.
- **4 GiB machines no longer boot the ISO** with either entry. The
  documented minimum is 4.5 GiB.
- **Cutting the rootfs is now the main lever for RAM.** Each MiB removed
  saves about 2.3 MiB of required RAM. The ISO's 737 MiB of uncompressed
  firmware is the largest candidate: the kernel supports zstd-compressed
  firmware, and compressing it could save about 450 MiB of rootfs.
- **Two installers can run at once.** firn-gui on the display and the TUI on
  ttyS0 can both run, as tty1 and ttyS0 TUIs already could. Firn has no
  cross-frontend install lock, and both frontends use the same
  `/run/firn/target` mount point and `firn-root` mapper name.
- **No firn-gui change is required.** cage maximizes firn-gui's window to
  the output, and every exit hands tty1 to the TUI. A firn-gui kiosk mode
  (fullscreen request, no Close, Quit) would polish this.
- **Not tested on real hardware yet.** Real-hardware behavior (native DRM
  driver timing, HiDPI, input) is unproven, which is why console stays the
  default.
- **CI exercises both entries.** `test/firn-installer-ui-boot-test.sh` boots
  the candidate ISO bytes four times in CI before promotion: console;
  graphical on virtio-vga, then Quit; graphical from the ESP on std VGA;
  graphical with no display. It reaches the guest over SSH with an SMBIOS
  `ssh.authorized_keys.root` credential, so the published bytes stay
  unmodified.
- **Publication gate.** The ISO cannot build until a firn release publishes
  `frostyard-firn-gui` to repository.frostyard.org.

## Alternatives considered

- **A `firn.ui=` flag read by a systemd generator:** it does what
  `systemd.unit=` already does, with custom code to test.
- **Condition-gated kiosk units on `multi-user.target`:** a conditional unit
  with `Conflicts=` kills getty even when its condition fails (the 2026-07-17
  native-installer root cause). Targets need no conditions.
- **The graphical entry as the default:** firn-gui has no real-hardware
  evidence yet. Console keeps an untouched boot identical to before.
- **The serial TUI only after a graphical failure:** it would avoid
  concurrent installers, but a server whose BMC console shows the GUI
  would offer nothing on serial.
- **weston or labwc instead of cage:** they still pull Mesa through libgbm,
  and weston adds 471 MiB.
- **Compressing the firmware in the same change:** deferred. It would offset
  the RAM cost, but it is a separate change to every boot's firmware loading.
- **A separate graphical ISO:** a second artifact to publish and verify,
  where the request was a boot-time choice on one medium.

## References

- Shapes: [shared/firn-installer/README.md](../../shared/firn-installer/README.md),
  [design/testing.md](../design/testing.md), [installing.md](../installing.md)
- Builds on: firn [ADR-0007](https://github.com/frostyard/firn/blob/main/docs/adr/0007-tui-kiosk-installer.md),
  [ADR-0010](https://github.com/frostyard/firn/blob/main/docs/adr/0010-single-installer-iso.md) and
  [ADR-0021](https://github.com/frostyard/firn/blob/main/docs/adr/0021-graphical-installer-separate-executable.md);
  [ADR-0002](0002-ship-no-enablement-symlinks-in-etc.md) (scoped to golden
  images, so the ISO's `default.target` link in `/etc` is outside it)
