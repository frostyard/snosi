# firn-installer — the single installer ISO

Successor to `shared/native-installer` per firn's ADR-0010: **one**
installer ISO for all four snosi bootc products, with
[firn](https://github.com/frostyard/firn)'s frontends as kiosks and a
package payload for firn's bootc installer steps. A GRUB menu picks the tty1
frontend: firn's TUI (the default) or firn-gui in the cage compositor; the
TUI always runs on ttyS0 too (see [Boot menu](#boot-menu-graphical-or-console)
and [ADR-0022](../../docs/adr/0022-installer-graphical-and-console-boot-entries.md)). `mokutil` (Secure Boot
mok-stage) and `flatpak` (flatpaks step and offline seed) stay in the payload
because Firn's bootc steps declare them.

## The firn binaries come from the frostyard apt repo

`mkosi.conf` installs `Packages=frostyard-firn` and
`Packages=frostyard-firn-gui` unpinned (published by firn's release via
repogen), so CI needs no sibling firn checkout and each ISO build takes the
newest Firn release. The image postinst still fails the build loudly if
`/usr/bin/firn`, `/usr/libexec/firn-gui/firn-gui`, cage, or a library or
font firn-gui loads at runtime is missing: `frostyard-firn-gui` declares no
dependencies, so `mkosi.conf` lists its graphics stack explicitly.

For dev testing of *unreleased* firn, the `just firn-installer` /
`just firn-installer-iso` recipes still run `_firn-binary` and
`_firn-gui-binary` first, which build from a sibling checkout into the
gitignored `tree/usr/bin/firn` and `tree/usr/libexec/firn-gui/firn-gui`
(ExtraTrees then overrides the packaged binaries; a checkout without the
`gui/` module keeps the packaged firn-gui):

```sh
# FIRN_SRC defaults to ../firn relative to this repo's root;
# worktree users must point it at a real checkout:
FIRN_SRC=/path/to/firn just firn-installer
```

## The product catalog is snosi's

`catalog.json` ships to `/etc/firn/catalog.json`, which firn reads as a
**wholesale** override of its compiled-in picker list (firn ADR-0010:
the catalog is media payload). Adding a product to the installer is
therefore a snosi change: add the entry here — every product must be
listed, and bootc entries must satisfy firn's `checkCatalog` (`ref` +
`cosign_pub_key`, no `product`). The
pinned `cosign` CLI (scripts/build/cosign.chroot) and
`/usr/lib/snosi/cosign.pub` back the bootc entries' signature
verification — firn's preflight requires both.

## Kiosk units

`tree/usr/lib/systemd/system/firn-kiosk.service` (TUI on tty1) and
`firn-kiosk-serial@.service` (TUI on a serial console) started as copies of
firn's kiosk units. Firn's tree no longer carries them, so this directory
holds the live copies. `firn-gui.service` and
`/usr/lib/firn/firn-gui-session` (the graphical kiosk) belong to the snosi
ISO, like `firn-flatpak-seed.service`.

All are enabled with static wants links, never `[Install]`:

| Link | Starts | Under |
|---|---|---|
| `multi-user.target.wants/firn-kiosk-serial@ttyS0.service` | TUI on ttyS0 (the ISO's `console=ttyS0`) | both entries |
| `multi-user.target.wants/firn-flatpak-seed.service` | the offline seed mount | both entries |
| `firn-console.target.wants/firn-kiosk.service` | TUI on tty1 | console entry, `default.target` |
| `firn-graphical.target.wants/firn-gui.service` | firn-gui in cage on tty1 | graphical entry |

## Boot menu: graphical or console

`tools/build-iso.sh` writes one `grub.cfg`, used by both the optical
(ISO9660) and USB-stick (GPT ESP) boot paths. It shows a five-second menu on
the display and, through firmware console redirection, on serial:

| Entry | Hotkey | Kernel argument |
|---|---|---|
| Install snosi (graphical) | `g` | `systemd.unit=firn-graphical.target` |
| Install snosi (console), the default | `t` | `systemd.unit=firn-console.target` |

`firn-gui-session` waits up to 10 s for a DRM device. Without one (a
serial-only server, a VM without a display, a GPU no kernel driver
supports) it exits 77 and `firn-gui.service` hands tty1 to the TUI at once.
Three crashes in 60 s and a clean exit (Quit or Close) do the same, so tty1
always ends with an installer. firn-gui runs as root under cage, so it skips
pkexec, and it draws on the CPU where there is no GPU acceleration.

The graphics stack costs RAM on every boot, because both entries share one
initramfs. Measured against the TUI-only ISO: 121 more packages, +292 MiB of
rootfs (191 MiB of it Mesa and LLVM, which cage's wlroots and Xwayland pull
through `libgbm1`), +90 MiB of initramfs and +103 MiB of ISO (783 MiB). The
rootfs is a tmpfs capped at half of RAM, and the compressed initramfs is
held until it is unpacked, so the minimum RAM to boot rose from 3584–3840 MiB
to 4352–4480 MiB (QEMU probes; the docs say 4.5 GiB). A 4 GiB machine no
longer boots the ISO.
`test/firn-installer-ui-boot-test.sh` boots each entry in QEMU with 6 GiB.

## Offline flatpak seed (firn ADR-0006 media obligation)

firn provisions system flatpaks into the target **at install time,
offline-first**: it copies the installer medium's own
`/var/lib/flatpak` system installation into the installed system, then
downloads anything missing over the network
([firn ADR-0006](https://github.com/frostyard/firn/blob/main/docs/adr/0006-install-time-offline-first-flatpaks.md),
`internal/flatpak/flatpak.go` — `hostFlatpakDir = "/var/lib/flatpak"`).
For that to be the common path rather than the degraded one, the
installer medium must present a **populated** `/var/lib/flatpak` at
install time. This is how it gets one.

### Why a data area, not the initramfs (Option A)

`tools/build-iso.sh` packs the **entire** installer rootfs as the
kernel's initramfs (cpio+zstd), unpacked wholesale into tmpfs at boot —
it all lives in RAM. The seed is the 23 core desktop apps from
Snow's list **plus their GNOME/freedesktop runtimes** — several GiB. Put
inside the rootfs it would blow the RAM budget the ISO test tracks.

So the seed rides the ISO as a **data area outside the initramfs**: a
squashfs file on the ISO9660 filesystem, on the physical medium, mounted
into RAM by nobody. Only what firn actually copies for a given install
crosses into the target.

### Build time — `just firn-flatpak-seed`

Reads the app IDs from Snow's core list (see below) and builds a standalone
flatpak **system** installation tree into `output/firn-flatpak-seed`
(gitignored) via a `flatpak --user` install pointed there with
`FLATPAK_USER_DIR` — the on-disk layout of a user and a system
installation is identical (`repo/` + `app/` + `runtime/` + `exports/`,
`bare-user-only` repo), and `flatpak list --system` reads it verbatim
once mounted at `/var/lib/flatpak`. Building `--user` needs no root and
no `flatpak-system-helper`/polkit on the build host.

Critical detail: the recipe hides the build host's own flatpak
installations during resolution (`FLATPAK_SYSTEM_DIR` and
`FLATPAK_CONFIG_DIR` point at throwaway empty dirs). Otherwise, if the
host already has e.g. `org.gnome.Platform` installed, flatpak treats each
app's runtime dependency as already satisfied and does **not** copy the
runtime into the seed — the seed then ships apps with no runtime and the
offline install is silently broken. Flathub is pinned as the seed remote
(the same remote firn adds for its network-download leg).

The recipe is **slow** (network + several GiB of disk). Run it once
before `just firn-installer-iso`.

### ISO assembly — `tools/build-iso.sh`

`firn-installer-iso` passes the seed tree to `build-iso.sh` via
`FIRN_FLATPAK_SEED_DIR` **if it exists**. `build-iso.sh` squashes it into
`firn-flatpak-seed.squashfs` in the ISO9660 tree with `mksquashfs
-all-root` — every file becomes uid/gid 0 regardless of the unprivileged
user that built the tree, so the mounted `/var/lib/flatpak` presents as
root-owned like a real system installation and firn's tar-copy carries
root ownership into the target. The Debian-signed shim/GRUB chain, the
El Torito/GPT-hybrid layout, and the `SNOSI_INSTALLER_<version>` volume
ID are untouched.

The seed is **optional**: with no seed tree, `build-iso.sh` builds a
seedless ISO (a fast/offline build) and firn falls back to network at
install time. A missing seed is never a build failure (ADR-0006
report-don't-fail).

### Runtime — `firn-flatpak-seed.service`

`tree/usr/lib/systemd/system/firn-flatpak-seed.service` (a oneshot,
enabled via the `multi-user.target.wants/` symlink like the kiosk units)
runs `tree/usr/lib/firn/firn-flatpak-seed-mount` before the kiosk
starts. That script finds the boot medium by its ISO9660 label prefix
(`SNOSI_INSTALLER_*` / `FIRN_INSTALLER_*` — the same label firn matches
for medium detection), mounts it read-only, and loop-mounts
`firn-flatpak-seed.squashfs` read-only at `/var/lib/flatpak`. If there is
no medium or no seed on it, the script exits 0 (no-op) and firn uses the
network — a seedless ISO still boots. This unit is the **snosi ISO's
own** (unlike the firn-owned kiosk units).

### The core flatpak list comes from `flatpaks/`

Each product's core Flatpak set lives in [`flatpaks/`](../../flatpaks/)
and is published as the image's `org.frostyard.core-flatpaks` label
(frostyard/firn ADR-0018). Firn reads that label for the chosen image, so
the ISO carries no core list of its own: the former
`/usr/share/firn/core-flatpaks.json` fallback, which gave every product
Snow's set, is gone, and `test/firn-installer-iso-test.sh --static`
keeps it off the medium.

Only the optional seed still uses `flatpaks/legacy/firn-core-flatpaks.json`:
Snow's set in the legacy `{"core": [...]}` shape, generated from
`flatpaks/snow.json`. Edit `flatpaks/snow.json`, then run
`flatpaks/core-flatpaks.py generate-legacy`; CI and image builds refuse
a stale file.

The seed is Snow's set only: Firn copies the whole seeded installation,
so seeding other products' sets would put them on every install.
