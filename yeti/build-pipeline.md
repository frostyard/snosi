# Build Pipeline

## Script Execution Order

Each image build runs four phases of scripts sequentially:

### 1. BuildScripts (in chroot)

Download and install items not available as Debian packages. These run inside the chroot with network access.

**Desktop profiles (snow/snowfield):**

| Script | Location | Purpose |
|--------|----------|---------|
| `brew.chroot` | `shared/snow/scripts/build/` | Downloads Homebrew installer via `verified_download()`, runs in non-interactive mode, creates `/usr/share/homebrew.tar.zst` |
| `hotedge.chroot` | `shared/snow/scripts/build/` | Downloads Hotedge GNOME extension (hot corners) from GitHub, installs to `/usr/share/gnome-shell/extensions/` |
| `logomenu.chroot` | `shared/snow/scripts/build/` | Downloads Logomenu GNOME extension from GitHub, installs extension + GLib schema |
| `bazaar.chroot` | `shared/snow/scripts/build/` | Clones Bazaar Companion GNOME extension from GitHub, patches metadata.json for shell version "48" |
| `surface-cert.chroot` | `shared/snow/scripts/build/` | Downloads Linux Surface secure boot certificate, installs to `/usr/share/linux-surface-secureboot/` |

**Server profiles (cayo):**

| Script | Location | Purpose |
|--------|----------|---------|
| `brew.chroot` | `shared/cayo/scripts/build/` | Same Homebrew installation, also sets xattr `user.component=linuxbrew` for chunkah |

### 2. PostInstallationScripts (after packages)

Run after all APT packages are installed. Handle relocation, branding, service enablement.

**Kernel postinstall (all profiles):**
- `shared/kernel/scripts/postinst/mkosi.postinst.chroot` — Builds initramfs via dracut, detects kernel version, generates `/usr/lib/modules/$VERSION/initramfs.img`, copies vmlinuz

**Desktop postinstall:**
- `shared/snow/scripts/postinstall/snow.postinst.chroot` — Sets os-release (PRETTY_NAME="Snow Linux", ID, ID_LIKE, VERSION_ID, SYSEXT_LEVEL, BUILD_ID), enables GDM + mount units (home, root, srv, mnt, media, opt, usr-local), creates user service symlinks for gnome-remote-desktop and gnome-remote-desktop-handover (explicitly removes gnome-remote-desktop-headless due to `Conflicts=` with the non-headless variant), removes bls-garbage-collect service and fish desktop entry, generates package list to `/usr/share/frostyard/`, writes build date, cleans machine-id/SSH keys, creates sysext infrastructure dirs

**Server postinstall:**
- `shared/cayo/scripts/postinstall/cayo.postinst.chroot` — Sets os-release (PRETTY_NAME="Cayo Linux", ID, ID_LIKE, VERSION_ID, SYSEXT_LEVEL, BUILD_ID), enables mount units (home, root, srv, mnt, media, opt, usr-local), removes bls-garbage-collect service, generates package list, writes build date, cleans machine-id/SSH keys, creates sysext infrastructure dirs

**Loaded variant postinstall scripts (desktop loaded — snowloaded/snowfieldloaded):**

| Script | Location | Purpose |
|--------|----------|---------|
| `edge.chroot` | `shared/packages/edge/mkosi.postinst.d/` | Relocates `/opt/microsoft/msedge` → `/usr/lib/microsoft-edge`, creates symlinks, patches icon paths |
| `azurevpn.chroot` | `shared/packages/azurevpn/mkosi.postinst.d/` | Downloads Azure VPN via `verified_download()`, relocates from `/opt`, uses patchelf to fix RPATH for Flutter .so files |
| `bitwarden.chroot` | `shared/packages/bitwarden/mkosi.postinst.d/` | Downloads Bitwarden .deb via `verified_download()`, relocates `/opt/Bitwarden` → `/usr/lib/Bitwarden`, sets SUID on chrome-sandbox |
| `vscode.chroot` | `shared/packages/vscode/mkosi.postinst.d/` | Patches desktop entry to add inode/directory MIME type |

**Server loaded variant (cayoloaded):** No additional postinstall scripts beyond the base cayo postinstall. Docker CE and Incus are baked into the image via `docker-onimage` and `virt-base` package sets with their tree overlays providing systemd presets, sysusers, and tmpfiles.

### 3. FinalizeScripts (pre-output)

Prepare the image for output. Run after postinstall, before the image format is written.

**Image finalize** (`shared/outformat/image/finalize/mkosi.finalize.chroot`):
- Removes `/boot`, `/home`, `/root`, `/srv` (recreates empty)
- Creates `/nix` mountpoint for nix sysext
- Removes `/etc/machine-id` and SSH host keys
- Compiles GLib schemas and dconf databases
- Sets file xattrs: `user.component=<package_name>` for every installed file — used by chunkah for layer optimization

**Base image finalize** (`mkosi.images/base/mkosi.finalize.chroot`):
- Masks `systemd-networkd-wait-online.service`

**Sysext finalize** (per-sysext `mkosi.finalize` scripts):
- Captures `/etc` configs to `/usr/share/factory/etc/` for tmpfiles-based injection at boot

### 4. PostOutputScripts (after image creation)

Run after the image directory/file is created. Handle manifest processing and packaging.

**Image manifest** (`shared/manifest/postoutput/mkosi.postoutput`):
- Copies manifest to versioned filename: `$IMAGE_ID.$IMAGE_VERSION.manifest.json`

**Sysext postoutput** (`shared/sysext/postoutput/sysext-postoutput.sh`):
- Reads `KEYPACKAGE` env var, extracts version from manifest JSON
- Maps Debian release to VERSION_ID (trixie → 13)
- Renames sysext to versioned name: `{IMAGE_ID}_{KEYVERSION}_{OS_VERSION}_{ARCH}.raw`
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
| Azure VPN | `/opt/microsoft/microsoft-azurevpnclient` | `/usr/lib/microsoft-azurevpnclient` | patchelf RPATH fix for 5 .so files, polkit rules fix |
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
- Runs `chunkah build --prune /sysroot/ --max-layers $MAX_LAYERS`
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

Tracks APT-based external package versions (Edge, VSCode, Docker, 1Password) separately from download checksums. Updated daily by `check-packages.yml`.

### update-checksums.sh

Helper for CI to update checksums.json:
```bash
./update-checksums.sh <key> <url> [version]
```

## Tree Overlays

Each profile has filesystem overlays (ExtraTrees) that are merged into the image:

### shared/snow/tree/

Desktop configuration overlay (~800+ files):
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
- Polkit rules and capabilities adjustments for Azure VPN client
