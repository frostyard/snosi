# Build Pipeline

## Script Execution Order

Each image build runs four phases of scripts sequentially:

### 1. BuildScripts (in chroot)

Download and install items not available as Debian packages. These run inside the chroot with network access.

**All profiles (shared):**

| Script | Location | Purpose |
|--------|----------|---------|
| `brew.chroot` | `shared/scripts/build/` | Downloads Homebrew installer via `verified_download()`, runs in non-interactive mode, creates `$BREW_TREE/usr/share/homebrew.tar.zst` (requires `BREW_TREE` env var), sets `user.component=linuxbrew` xattr for chunkah |

**Desktop profiles (snow/snowfield) only:**

| Script | Location | Purpose |
|--------|----------|---------|
| `hotedge.chroot` | `shared/snow/scripts/build/` | Downloads Hotedge GNOME extension (hot corners) from GitHub via `verified_download()`, installs to `/usr/share/gnome-shell/extensions/` |
| `logomenu.chroot` | `shared/snow/scripts/build/` | Downloads Logomenu GNOME extension from GitHub via `verified_download()`, installs extension + GLib schema |
| `bazaar.chroot` | `shared/snow/scripts/build/` | Clones Bazaar Companion GNOME extension from GitHub, patches metadata.json for shell version "48" |
| `surface-cert.chroot` | `shared/snow/scripts/build/` | Downloads Linux Surface secure boot certificate via `verified_download()`, installs to `/usr/share/linux-surface-secureboot/` |

**Server profiles (cayo/cayoloaded):** Only `brew.chroot` (no desktop build scripts).

### 2. PostInstallationScripts (after packages)

Run after all APT packages are installed. Handle relocation, branding, service enablement.

**Base image postinstall** (`mkosi.images/base/mkosi.postinst.chroot`):

Runs during the base image build (not during profile builds). Handles:
- Sets home directory path to `/var/home` in `/etc/default/useradd`
- Enables systemd mount units (home, root, srv, mnt, media, opt, usr-local)
- Removes bls-garbage-collect service

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

**Loaded variant postinstall scripts (desktop loaded — snowloaded/snowfieldloaded):**

| Script | Location | Purpose |
|--------|----------|---------|
| `edge.chroot` | `shared/packages/edge/mkosi.postinst.d/` | Relocates `/opt/microsoft/msedge` → `/usr/lib/microsoft-edge`, creates symlinks, patches icon paths |
| `azurevpn.chroot` | `shared/packages/azurevpn/mkosi.postinst.d/` | Downloads Azure VPN via `verified_download()`, relocates from `/opt`, uses patchelf to fix RPATH for Flutter .so files |
| `bitwarden.chroot` | `shared/packages/bitwarden/mkosi.postinst.d/` | Downloads Bitwarden .deb via `verified_download()`, relocates `/opt/Bitwarden` → `/usr/lib/Bitwarden`, sets SUID on chrome-sandbox |
| `vscode.chroot` | `shared/packages/vscode/mkosi.postinst.d/` | Patches desktop entry to add inode/directory MIME type |

**Server loaded variant (cayoloaded):** No additional postinstall scripts beyond the base cayo postinstall. Docker CE and Incus are baked into the image via `docker-onimage` and `virt-base` package sets with their tree overlays providing systemd presets, sysusers, and tmpfiles.

**Intel WiFi firmware (fw-ipw — snow/snowloaded/snowfield/snowfieldloaded):**

| Script | Location | Purpose |
|--------|----------|---------|
| `fw-ipw.chroot` | `shared/packages/fw-ipw/mkosi.postinst.d/` | Downloads firmware-ipw2x00 from APT, extracts with `ar x`/`tar`, copies firmware files to `/lib/firmware/`, sets `user.component` xattr |

### 3. FinalizeScripts (pre-output)

Prepare the image for output. Run after postinstall, before the image format is written.

**Image finalize** (`shared/outformat/image/finalize/mkosi.finalize.chroot`):
- Removes `/boot`, `/home`, `/root`, `/srv` (recreates empty)
- Creates `/sysroot` and `/nix` mountpoints (nix sysext bind-mount)
- Removes `/etc/machine-id` (recreates empty for first-boot) and SSH host keys
- Compiles GLib schemas and dconf databases
- Sets file xattrs: `user.component=<package_name>` for every installed file — used by chunkah for layer optimization

**Base image finalize** (`mkosi.images/base/mkosi.finalize.chroot`):
- Masks `systemd-networkd-wait-online.service`

**Sysext finalize** (per-sysext `mkosi.finalize` scripts):
- Captures `/etc` configs to `/usr/share/factory/etc/` for tmpfiles-based injection at boot
- Used by: docker, himmelblau (full /etc capture), incus, nix, tailscale

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
| Emdash | `/opt/Emdash` | `/usr/lib/emdash` | SUID on chrome-sandbox (4755), desktop entry path update (sysext, not profile) |

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

Tracks APT-based external package versions (Edge, VSCode, Docker, 1Password, Himmelblau) separately from download checksums. Updated daily by `check-packages.yml`.

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
- APT sources for Docker, Incus/Zabbly
- NetworkManager/IWD networking config
- systemd mounts and presets (no desktop services)
- sysusers/tmpfiles for avahi, dnsmasq, docker, incus

### shared/snowloaded/tree/

Single GLib schema override for "loaded" variant defaults.

### shared/packages/virt-base/tree/

Incus on-image enablement overlay (used by cayoloaded and snowloaded/snowfieldloaded):
- systemd preset: `40-incus.preset` (enables incus services)
- sysusers.d: `dnsmasq.conf`, `rdma.conf`

### shared/packages/docker-onimage/tree/

Docker CE on-image enablement overlay (used by cayoloaded):
- systemd preset: enables docker services
- sysusers.d: Docker user/group definitions
- tmpfiles.d: Runtime directory setup

### shared/packages/azurevpn/tree/

Azure VPN capability fixes overlay (used by snowloaded/snowfieldloaded):
- systemd preset and workaround service for Azure VPN client capabilities
