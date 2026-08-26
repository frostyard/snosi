# firn-installer — the single installer ISO

Successor to `shared/native-installer` per firn's ADR-0010: **one**
installer ISO for all snosi image families, with
[firn](https://github.com/frostyard/firn)'s TUI as the kiosk frontend
(no cage/GTK/python — a single static Go binary on tty1 and ttyS0) and
a package payload satisfying firn's step-declared tool preflight for
both the bootc and native A/B install families.

## The firn binary comes from the frostyard apt repo

`mkosi.conf` installs `Packages=frostyard-firn` (published by firn's
release via repogen), so CI needs no sibling firn checkout. The image
postinst still fails the build loudly if `/usr/bin/firn` is missing.

For dev testing of *unreleased* firn, the `just firn-installer` /
`just firn-installer-iso` recipes still run `_firn-binary` first, which
builds from a sibling checkout into the gitignored `tree/usr/bin/firn`
(ExtraTrees then overrides the packaged binary):

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
listed, and entries must satisfy firn's `checkCatalog` (bootc: `ref` +
`cosign_pub_key`, no `product`; ab: `product`, no `ref`/key). The
pinned `cosign` CLI (scripts/build/cosign.chroot) and
`/usr/lib/snosi/cosign.pub` back the bootc entries' signature
verification — firn's preflight requires both.

## Kiosk units

`tree/usr/lib/systemd/system/firn-kiosk.service` and
`firn-kiosk-serial@.service` are verbatim copies of firn's
`dist/` units (firn owns them; ADR-0010 repo boundary — re-copy on firn
changes, do not fork). They are enabled the same way native-installer
enables `snosi-setup.service`: static wants links in
`tree/usr/lib/systemd/system/multi-user.target.wants/` for
`firn-kiosk.service` (tty1) and `firn-kiosk-serial@ttyS0.service`
(serial, matching the ISO's `console=ttyS0` kernel argument).

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
`core.json` **plus their GNOME/freedesktop runtimes** — several GiB. Put
inside the rootfs it would blow the RAM budget the ISO test tracks.

So the seed rides the ISO as a **data area outside the initramfs**: a
squashfs file on the ISO9660 filesystem, on the physical medium, mounted
into RAM by nobody. Only what firn actually copies for a given install
crosses into the target.

### Build time — `just firn-flatpak-seed`

Reads the app IDs from `core.json` (see below) and builds a standalone
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

### `core.json` must track first-setup

`core.json` here is a **vendored copy** of
`frostyard/first-setup`'s `snow_first_setup/core.json` — the single
source of truth for the core flatpak set, and the exact same file firn
reads at install time for `core_flatpaks`
(`internal/flatpak/flatpak.go`, `coreJSONPath`). Vendoring it keeps the
ISO build from depending on a first-setup checkout. **Re-vendor it when
first-setup's list changes**, so the seeded set stays in step with what
firn installs. It is kept byte-identical to upstream for easy diffing;
the tracking obligation lives in the `firn-flatpak-seed` recipe comment
and here.
