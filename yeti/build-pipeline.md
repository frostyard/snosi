# Build Pipeline

## Script Execution Order

Each image build runs four phases of scripts sequentially:

### 1. BuildScripts (in chroot)

Download and install items not available as Debian packages. These run inside the chroot with network access.

**All profiles (shared):**

| Script | Location | Purpose |
|--------|----------|---------|
| `brew.chroot` | `shared/scripts/build/` | Downloads Homebrew installer via `verified_download()`, runs in non-interactive mode, creates `$DESTDIR/usr/share/homebrew.tar.zst` (installed into the image by mkosi), sets `user.component=linuxbrew` xattr for chunkah |

**Desktop profiles (snow/snowfield) only:**

| Script | Location | Purpose |
|--------|----------|---------|
| `hotedge.chroot` | `shared/snow/scripts/build/` | Downloads Hotedge GNOME extension (hot corners) from GitHub via `verified_download()`, installs to `$DESTDIR/usr/share/gnome-shell/extensions/` |
| `logomenu.chroot` | `shared/snow/scripts/build/` | Downloads Logomenu GNOME extension from GitHub via `verified_download()`, installs extension + GLib schema into `$DESTDIR` |
| `bazaar.chroot` | `shared/snow/scripts/build/` | Downloads pinned Bazaar Companion GNOME extension tarball from GitHub via `verified_download()`, installs its `src/` into `$DESTDIR`, patches metadata.json for shell version "48". Build scripts install via `$DESTDIR` only — never into `$SRCDIR`/the tree overlays (#293) |
| `surface-cert.chroot` | `shared/snow/scripts/build/` | Downloads Linux Surface secure boot certificate via `verified_download()`, installs to `/usr/share/linux-surface-secureboot/` |

**ostree + bootc — Frostyard debs (no longer built in-tree):**

bootc and ostree install as regular APT packages from the Frostyard repository (`frostyard.sources` in `mkosi.sandbox/etc/apt/`): `bootc` and `libostree-1-1` (which ships the library AND the ostree CLI, and `Provides: ostree, libostree-dev`). They are built and published by [frostyard/bootc-debian](https://github.com/frostyard/bootc-debian), whose `build.sh` mirrors the former in-tree mkosi BuildScript exactly — same pinned upstream tarballs (sha256-verified in that repo's `download/checksums.json`), same pinned Rust toolchain (Debian Trixie's rustc 1.85 is too old to build bootc 1.16.x), same configure/make invocations. Debian Trixie ships no bootc package and only ostree 2025.2 (too old for current bootc), hence the external packaging.

- **Versions:** deb versions carry a `-frostyard<timestamp>` suffix so rebuilds of the same upstream version sort newer in apt. Upstream releases are tracked weekly by bootc-debian's own `check-dependencies.yml`; snosi's dependency check does not cover ostree/bootc.
- **Publish → rebuild:** bootc-debian's Build workflow publishes the debs and then dispatches a snosi image build, so new bootc/ostree versions roll into images automatically.
- **Runtime lib pinning:** the debs declare only a partial `Depends` list; base `Packages=` keeps the full set of runtime link deps explicit (`libfuse3-4`, `libsoup-3.0-0`, `liblzma5`, `libzstd1`, `libmount1`, `libselinux1`, `libcom-err2`, `libext2fs2t64`, plus the declared ones). Do not remove them from `Packages=` just because apt does not demand them.
- **History (until 2026-07):** both were compiled from source during the base image build via `shared/bootc/build/bootc.chroot` (BuildScript + `BuildPackages=` overlay deps + rustup toolchain + ostree double-install + stub-deb dpkg registration in `shared/bootc/postinst/bootc-register.chroot`). All of that machinery was removed when the deb path landed; see git history if the in-tree build ever needs resurrecting.

**Server profile (cayo):** Only `brew.chroot` (no desktop build scripts).

### 2. PostInstallationScripts (after packages)

Run after all APT packages are installed. Handle relocation, branding, service enablement.

**Base image postinstall** (`mkosi.images/base/mkosi.postinst.chroot`):

Runs during the base image build (not during profile builds). Handles:
- Sets home directory path to `/var/home` in `/etc/default/useradd`
- Enables systemd mount units (home, root, srv, mnt, media, opt, usr-local)
- Removes bls-garbage-collect service

**Base update services** (`mkosi.images/base/mkosi.extra/usr/lib/systemd/`):

The base overlay ships `bootc-update-stage.service` and `bootc-update-stage.timer`, enabled by `system-preset/04-bootc-update.preset`. That preset also disables upstream `bootc-fetch-apply-updates.timer`: upstream's timer is currently inert on composefs deployments because it is gated on `/run/ostree-booted`, and its intended behavior includes applying updates with an immediate reboot. The custom service runs `/usr/libexec/bootc-update-stage`, which:
- exits cleanly when the system is not bootc-managed,
- prunes stale transfer images before pulling to avoid `/var` exhaustion,
- pulls the followed image with `podman` so containers policy is enforced,
- stages it with `bootc upgrade` when the spec already follows
  `containers-storage` (the steady state after the first staged update) or
  `bootc switch --transport containers-storage` otherwise — switch to an
  identical spec is a SILENT no-op in bootc <= 1.16.3 and left installs
  unable to take a second update (root-caused 2026-07-06),
- verifies the staged digest equals the pulled digest (fails loudly on any
  future silent no-op),
- writes the reboot-pending semaphore `/run/snosi/update-staged`
  (image/digest/timestamp; also re-asserted when an update is found already
  staged, covering manual `bootc upgrade`; /run placement means the applying
  reboot clears it), and
- prunes dangling transfer images after the switch.

Two consumers surface the pending reboot:
- `/etc/update-motd.d/86-bootc-update-staged` — SSH/console logins (all
  images, including headless cayo).
- `bootc-update-notify.path` + `.service` (user scope) with
  `/usr/libexec/bootc-update-notify` — desktop notification. The path unit
  fires when the semaphore appears mid-session or is modified (newer image
  re-staged), and PathExists= also triggers at session start when the file
  already exists; the helper is ack-gated per staged digest (same pattern as
  snosi-etc-drift-notify) so users see one notification per staged update,
  not one per login or trigger.

This mirrors the previous nbc-style download-only semantics: the staged deployment applies at the next normal reboot. The podman transfer path is also the current workaround for bootc registry-transport composefs pull failures noted in `docs/plans/2026-07-03-bootc-update-validation-plan.md`.

Runtime units shipped in `mkosi.extra/` must not self-disable, call `systemctl preset`, or otherwise delete shipped `/etc` state. For run-once behavior, use a persistent `/var` marker (`ConditionPathExists=!/var/lib/<unit>.done` and a final `touch`) so bootc can merge `/etc` cleanly when the next staged deployment finalizes.

**Kernel postinstall (all profiles):**
- `shared/kernel/scripts/postinst/mkosi.postinst.chroot` — Builds initramfs via dracut, detects kernel version, generates `/usr/lib/modules/$VERSION/initramfs.img`, copies vmlinuz

**Common postinstall logic** (`shared/scripts/common-postinst.sh`):

Both snow and cayo postinstall scripts source this shared script after setting `OS_PRETTY_NAME` and `OS_NAME`. It handles:
- Updates `/usr/lib/os-release` (PRETTY_NAME, NAME, ID, ID_LIKE, VERSION_ID, SYSEXT_LEVEL, BUILD_ID)
- Generates package list to `/usr/share/frostyard/`
- Writes build date
- Cleans apt caches
- Creates sysext infrastructure dirs (`/var/lib/extensions`, `/var/lib/confexts`, `/usr/lib/extension-release.d`)

**Desktop postinstall:**
- `shared/snow/scripts/postinstall/snow.postinst.chroot` — Sources `common-postinst.sh` with OS_PRETTY_NAME="Snow Linux", enables GDM, creates user service symlinks for gnome-remote-desktop and gnome-remote-desktop-handover (explicitly removes gnome-remote-desktop-headless due to `Conflicts=` with the non-headless variant), removes fish desktop entry

**Server postinstall:**
- `shared/cayo/scripts/postinstall/cayo.postinst.chroot` — Sources `common-postinst.sh` with OS_PRETTY_NAME="Cayo Linux" (no additional steps beyond common logic)

**App package-set postinstall scripts (now consumed only by the app sysext builds — the loaded variants that used them were retired 2026-07):**

| Script | Location | Purpose |
|--------|----------|---------|
| `edge.chroot` | `shared/packages/edge/mkosi.postinst.d/` | Downloads Edge .deb via `verified_download()`, strips `install_key`/`install_deb822_sources` from its `DEBIAN/postinst` (those call `apt-config` and break inside the chroot), installs the patched deb, relocates `/opt/microsoft/msedge` → `/usr/lib/microsoft-edge`, creates symlinks, patches icon paths |
| `azurevpn.chroot` | `shared/packages/azurevpn/mkosi.postinst.d/` | Downloads Azure VPN via `verified_download()`, relocates from `/opt`, uses patchelf to fix RPATH for Flutter .so files |
| `bitwarden.chroot` | `shared/packages/bitwarden/mkosi.postinst.d/` | Downloads Bitwarden .deb via `verified_download()`, relocates `/opt/Bitwarden` → `/usr/lib/Bitwarden`, sets SUID on chrome-sandbox |
| `vscode.chroot` | `shared/packages/vscode/mkosi.postinst.d/` | Patches desktop entry to add inode/directory MIME type |


### 3. FinalizeScripts (pre-output)

Prepare the image for output. Run after postinstall, before the image format is written.

**Image finalize** (`shared/outformat/image/finalize/mkosi.finalize.chroot`):
- Removes `/boot`, `/home`, `/root`, `/srv` (recreates empty)
- Creates `/sysroot` and `/nix` mountpoints (nix sysext bind-mount)
- Writes `/etc/machine-id` as the literal `uninitialized` (machine-id(5) golden-image value) and removes SSH host keys. **First boot is real:** every install's first boot satisfies `ConditionFirstBoot=`, PID 1 applies system presets, and `preset-global.service` (base `mkosi.extra`, from ParticleOS) applies user-scope presets. `systemd-firstboot.service` is preset-disabled so nothing prompts on console. (Until 2026-07 the file shipped *empty*, which only means "generate an ID" and suppressed first-boot semantics entirely.) The `sshd-keygen.service.d` drop-in that keys on missing host keys is kept — it also covers key deletion on installed systems.
- Strips ALL unit enablement symlinks (`.wants`/`.requires` entries + `[Install]` aliases, system and user scope) from `/etc` — mkosi ran `preset-all`/`--global preset-all` just before finalize; first boot recreates the same symlinks from the same preset policy as **runtime-created** state, so a later admin `systemctl disable` deletes runtime paths instead of image-shipped ones (which would break bootc's `/etc` merge at update finalize — the crash needs a *symlink* counterpart in the new deployment; deletions of shipped regular files merge fine, as `persistence-write.sh`'s `/etc/issue.net` check proves). Masks (`/dev/null`) and linked units (dracut) are kept. Stripped links are recorded in `/usr/share/snosi/enablement-manifest.txt`; `test/tests/05-firstboot-presets.sh` verifies first-boot parity against it.
- Compiles GLib schemas and dconf databases
- Sets file xattrs: `user.component=<package_name>` for every installed file — used by chunkah for layer optimization

**Base image finalize** (`mkosi.images/base/mkosi.finalize.chroot`):
- Masks `systemd-networkd-wait-online.service`

**Sysext finalize** (per-sysext `mkosi.finalize` scripts):
- Captures `/etc` configs to `/usr/share/factory/etc/` for tmpfiles-based injection at boot
- Used by: docker, incus, nix, tailscale
- Capture ONLY the specific paths referenced by the sysext's tmpfiles.d `C` directives — never all of `/etc`. With `Overlay=yes` the buildroot `/etc` is the merged base view, so a full capture ships the base image's `/etc/shadow` and SSH host keys in the published sysext (frostyard/snosi#282)

### 4. PostOutputScripts (after image creation)

Run after the image directory/file is created. Handle manifest processing and packaging.

**Image manifest** (`shared/manifest/postoutput/mkosi.postoutput`):
- Copies manifest to versioned filename: `$IMAGE_ID.$IMAGE_VERSION.manifest.json`

**Sysext postoutput** (`shared/sysext/postoutput/sysext-postoutput.sh`):
- Reads `KEYPACKAGE` env var, extracts version from manifest JSON
- Maps Debian release to VERSION_ID (forky → 14, trixie → 13, bookworm → 12, bullseye → 11, buster → 10)
- Handles Debian epoch notation: `5:1.2.3` → `5+1.2.3`
- Renames sysext to versioned name: `{IMAGE_ID}_{KEYVERSION}_{OS_VERSION}_{ARCH}.{ext}` (ext may be raw, raw.gz, raw.xz, etc.)
- Annotates manifest with key_package and key_version
- Creates symlink for systemd-sysupdate MatchPattern matching

## Output Organization

After `mkosi build` completes, the output directory contains all images, sysexts, and manifests flat in `output/`. Two root scripts organize them for publishing:

Root `mkosi.conf` intentionally lists `base` plus all sysexts in `Dependencies=` so plain `mkosi build` and `just sysexts` produce the sysext publishing set. Profile configs clear that inherited collection with an empty `Dependencies=` assignment and then add `Dependencies=base`; without the reset, mkosi appends list settings and profile builds would rebuild every sysext. CI enforces this with `check-profile-dependencies.sh`.

Root `mkosi.conf` also configures mkosi's build tooling bootstrap with `ToolsTree=default` and `ToolsTreeSandboxTrees=mkosi.tools.sandbox`. Keep package-manager settings for that tools tree in `mkosi.tools.sandbox/`; the regular `mkosi.sandbox/` tree only affects target-image APT operations. Network hardening that should protect both surfaces, such as APT retries/timeouts, needs matching files in both trees.

### sysextmv.sh

Moves sysext files matching `{image_id}_{version}_{os_version}_{arch}.{ext}` into `output/sysexts/`, organized by sysext name (e.g., `output/sysexts/docker/`). This structure is required by the `frostyard/repogen` action for R2 publishing.

### manifestmv.sh

Moves manifest JSON files into `output/manifests/` for separate upload to R2.

### check-duplicate-packages.sh

Pre-build validation script (run in CI before `mkosi build`). Checks for duplicate package entries across mkosi configs to prevent conflicts.

### check-profile-dependencies.sh

Config sanity check used by `validate.yml`. It runs `mkosi -f --profile <profile> summary` for every profile and fails if any profile summary includes one of the sysext image dependencies from root `mkosi.conf`. This protects the required `Dependencies=` reset pattern in profile configs.

### check-runtime-etc-guard.sh

Runtime payload guard used by `validate.yml`. It scans tracked files in `mkosi.extra/` and `shared/**/tree/` for guest-side service enablement mutations (`systemctl enable/disable/revert/unmask/preset`, `deb-systemd-helper`) and deletion/rename patterns targeting `/etc`. Build-time scripts are intentionally outside the scan because build-time enablement is the correct way to define image service state.

**CI usage in build.yml:**
```bash
./check-duplicate-packages.sh    # Validate
sudo -E mkosi build              # Build
sudo ./sysextmv.sh               # Organize sysexts
sudo ./manifestmv.sh             # Organize manifests
```

## Package Relocation

Packages that install to `/opt` must be relocated to `/usr/lib/<package>` because `/opt` is a writable bind mount that gets shadowed by sysext overlays on an immutable system.

### Pattern

```bash
# 1. Move the installation directory
mv /opt/<vendor>/<package> /usr/lib/<package>

# 2. Create binary symlinks
ln -sf /usr/lib/<package>/<binary> /usr/bin/<binary>

# 3. Fix icon/desktop paths if GUI app
# 4. Fix RPATH if shared libraries reference /opt paths (use patchelf)
# 5. Set SUID bits if needed (e.g., chrome-sandbox)
```

### Current Relocations

| Package | From | To | Extra Steps |
|---------|------|----|-------------|
| Microsoft Edge | `/opt/microsoft/msedge` | `/usr/lib/microsoft-edge` | Icon symlinks, gnome-control-center default-apps patch |
| Azure VPN | `/opt/microsoft/microsoft-azurevpnclient` | `/usr/lib/microsoft-azurevpnclient` | patchelf RPATH fix for 5 .so files, polkit rules fix, `cap_net_admin+eip` capability |
| Bitwarden | `/opt/Bitwarden` | `/usr/lib/Bitwarden` | SUID on chrome-sandbox (4755), desktop entry path update |

## OCI Image Packaging

After mkosi produces a directory image, two scripts handle OCI packaging:

### buildah-package.sh

Creates OCI container images from the directory output.

```bash
buildah-package.sh <rootfs-dir> <image-ref> [label=value ...]
```

Uses `buildah mount` + `cp -a` + `buildah commit` instead of `buildah COPY` to preserve all file metadata (SUID bits, xattrs, capabilities, ACLs, hardlinks). This works around buildah#4463 which drops SUID bits during COPY.

### chunkah-package.sh

Optimizes OCI image layers using [chunkah](https://quay.io/jlebon/chunkah).

- Reads the built image via `podman inspect`
- Mounts into chunkah container
- Runs `chunkah build --prune /sysroot/ --max-layers $MAX_LAYERS` (default 128)
- Uses `user.component` xattrs (set during finalize) to group files into efficient layers
- Removes ostree-specific labels from output

## Verified Download System

External resources are managed through `shared/download/`:

### checksums.json

Pins URL + SHA256 for each external download:

```json
{
  "bitwarden": {
    "url": "https://...",
    "sha256": "abc123...",
    "version": "2026.2.1"
  }
}
```

### verified-download.sh

Provides `verified_download(key, output_path)`:
1. Reads URL + checksum from checksums.json via jq
2. Downloads with curl + retries
3. Validates SHA256 post-download
4. Fails the build on checksum mismatch

### package-versions.json

Tracks APT-based external package versions (VSCode `code`, `docker-ce`, `1password-cli`) separately from download checksums. Updated daily by `check-packages.yml`. Edge is NOT tracked here — it is pinned via `checksums.json` and updated by `check-dependencies.yml`.

### update-checksums.sh

Helper for CI to update checksums.json:
```bash
./update-checksums.sh <key> <url> [version]
```

## Tree Overlays

Each profile has filesystem overlays (ExtraTrees) that are merged into the image:

### shared/snow/tree/

Desktop configuration overlay:
- APT sources for Docker, backports
- dconf/GLib schema overrides for GNOME defaults
- GDM configuration
- Flatpak remote (Flathub)
- systemd units: mount units (home, root, srv, opt, usr-local), service overrides, presets
- dracut configs: TPM, bootc, systemd
- tmpfiles.d and sysusers.d definitions
- Flatpak sandbox overrides

### shared/cayo/tree/

Server configuration overlay:
- APT sources for Docker
- NetworkManager/IWD networking config
- systemd mounts and presets (no desktop services)
- sysusers/tmpfiles for avahi, dnsmasq, docker, incus

## /etc Drift Tooling and Preset Reconciliation (base mkosi.extra)

- `usr/bin/snosi-etc-diff` — root CLI; bind-mounts `/` (submount-free) to reach the pristine composefs image `/etc` under the writable `/etc` bind mount, then reports `M`(odified)/`D`(eleted) — and `A`(dded) with `--added` — relative to it. `--machine` emits tab-separated lines. Ignore globs: `usr/lib/snosi/etc-diff.ignore` (image defaults, tuned against a live install) plus optional `/etc/snosi/etc-diff.ignore`.
- `preset-reconcile.service` → `usr/libexec/preset-reconcile` — closes the "new image preset policy never reaches existing installs" gap: diffs the image's enablement manifest against `/var/lib/snosi/enablement-manifest.applied`; entries ADDED to policy are preset (creates-only; masked units skipped, so admin masks win; admin disables of pre-existing policy are never re-applied), entries REMOVED are written to `/var/lib/snosi/preset-removals` for the drift report (never auto-disabled), then the applied snapshot is updated. Gated on the enablement marker so first boot/migration initialize the model first. Newly enabled units take effect at the next boot (runs after the boot transaction on purpose).
- `snosi-etc-drift-report.service` → `usr/libexec/snosi-etc-drift-report` — per boot, writes `M`/`D` diff entries plus `P`(olicy removal) lines to `/var/lib/snosi/etc-drift.report` with a sha256 in `etc-drift.hash`; removes both when clean.
- `snosi-etc-drift-notify.service` (user scope, `graphical-session.target`) → one `notify-send` per report *change*, gated by comparing the report hash against `$XDG_STATE_HOME/snosi/etc-drift.ack`.
- `etc/update-motd.d/85-snosi-etc-drift` — headless equivalent: one summary line at login when the report is non-empty.

All verified functionally on a live spike-image install (2026-07-05): diff correctly isolated one real drift entry (`gdm3/daemon.conf`) after ignore tuning; reconciler initialize/add/remove/steady paths all exercised (preset recreated a removed enablement symlink; removals recorded, never disabled).
