# snosi

A bootable container image build system using [mkosi](https://github.com/systemd/mkosi) for creating Debian-based bootable containers and system extensions (sysexts).

## What This Project Does

snosi builds immutable, bootable OCI container images based on Debian Trixie. These images are designed for use with [bootc](https://containers.github.io/bootc/) / systemd-boot and can be deployed as atomic, updateable operating system images.

The project produces:

| Image               | Description                                         | Output Format |
| ------------------- | --------------------------------------------------- | ------------- |
| **snow**            | GNOME desktop with backports kernel                 | OCI archive   |
| **snowloaded**      | snow + Edge + VSCode + Bitwarden + Incus            | OCI archive   |
| **snowfield**       | snow with linux-surface kernel for Surface devices  | OCI archive   |
| **snowfieldloaded** | snowfield + Edge + VSCode + Bitwarden + Incus       | OCI archive   |
| **1password-cli**   | 1Password CLI tool                                  | sysext        |
| **debdev**          | Debian development tools (debootstrap, distro-info) | sysext        |
| **dev**             | Build essentials, Python, cmake, valgrind, gdb      | sysext        |
| **docker**          | Docker CE container runtime                         | sysext        |
| **incus**           | Incus container/VM manager                          | sysext        |
| **podman**          | Podman + Distrobox                                  | sysext        |

## Architecture

```
                              base                ← Debian Trixie + bootc foundation
                                │
                ┌───────────────┴───────────────┐
                │                               │
             sysexts                         profiles
    ┌────┬────┬────┬────┬────┬────┐            │
    │    │    │    │    │    │    │          snow ────────────────────┐
  1pass debdev dev docker incus podman        │                      │
                                    ┌─────────┼─────────┐            │
                                    │         │         │            │
                               snowloaded  snowfield  snowfieldloaded
```

### Base Image

The `base` image ([mkosi.images/base/mkosi.conf](mkosi.images/base/mkosi.conf)) provides the foundation for all derivatives:

- Debian Trixie (testing) with main, contrib, non-free, and non-free-firmware repositories
- systemd, systemd-boot, and boot infrastructure
- Network management (NetworkManager, wpasupplicant)
- Container tooling prerequisites (erofs-utils, skopeo)
- Firmware packages for common hardware
- Core utilities (fish, zsh, vim, git)

### System Extensions (sysexts)

Sysexts are overlay images that extend the base system without modifying it. They're built with `Format=sysext` and `Overlay=yes`:

| Sysext            | Contents                                      | Config                                                                         |
| ----------------- | --------------------------------------------- | ------------------------------------------------------------------------------ |
| **1password-cli** | 1Password CLI tool                            | [mkosi.images/1password-cli/mkosi.conf](mkosi.images/1password-cli/mkosi.conf) |
| **debdev**        | debootstrap, distro-info, archive keyrings    | [mkosi.images/debdev/mkosi.conf](mkosi.images/debdev/mkosi.conf)               |
| **dev**           | build-essential, cmake, Python, valgrind, gdb | [mkosi.images/dev/mkosi.conf](mkosi.images/dev/mkosi.conf)                     |
| **docker**        | Docker CE, containerd, buildx, compose        | [mkosi.images/docker/mkosi.conf](mkosi.images/docker/mkosi.conf)               |
| **incus**         | Incus, QEMU/KVM, OVMF, virt-viewer            | [mkosi.images/incus/mkosi.conf](mkosi.images/incus/mkosi.conf)                 |
| **podman**        | Podman, Distrobox, buildah, crun              | [mkosi.images/podman/mkosi.conf](mkosi.images/podman/mkosi.conf)               |

## How Profiles Work

Profiles in `mkosi.profiles/` define complete image variants by composing shared components. Each profile's `mkosi.conf` uses `Include=` directives to pull in reusable configuration fragments from the `shared/` directory.

### Profile Structure

```
mkosi.profiles/
├── snow/           ← GNOME desktop + backports kernel
├── snowfield/      ← GNOME desktop + Surface kernel
├── snowloaded/     ← snow + extra packages (Edge, Incus)
└── snowfieldloaded/← snowfield + extra packages
```

### Shared Components

The `shared/` directory contains reusable configuration fragments that profiles include:

```
shared/
├── kernel/
│   ├── backports/mkosi.conf   ← Trixie backports kernel + firmware
│   ├── surface/mkosi.conf     ← linux-surface kernel + iptsd
│   └── scripts/               ← dracut postinst scripts
├── outformat/
│   └── oci/
│       ├── mkosi.conf         ← Sets Format=oci
│       ├── finalize/          ← OCI finalization scripts
│       └── postoutput/        ← OCI tagging scripts
├── packages/
│   ├── snow/mkosi.conf        ← GNOME desktop packages (~490 lines)
│   ├── edge/mkosi.conf        ← Microsoft Edge browser
│   ├── vscode/mkosi.conf      ← Visual Studio Code
│   ├── bitwarden/mkosi.conf   ← Bitwarden password manager
│   └── virt/mkosi.conf        ← Incus virtualization
└── snow/
    ├── tree/                  ← Extra files overlaid into image
    └── scripts/
        ├── build/             ← Build-time scripts (brew, surface-cert, etc.)
        └── postinstall/       ← Post-installation customizations
```

### Example: snow Profile

The [snow profile](mkosi.profiles/snow/mkosi.conf) composes a GNOME desktop image:

```ini
[Output]
ImageId=snow
Output=snow
ManifestFormat=json

[Content]
# Overlay additional files into the image
ExtraTrees=%D/shared/snow/tree

# Build-time scripts
BuildScripts=%D/shared/snow/scripts/build/brew.chroot
BuildScripts=%D/shared/snow/scripts/build/hotedge.chroot
BuildScripts=%D/shared/snow/scripts/build/logomenu.chroot
BuildScripts=%D/shared/snow/scripts/build/bazaar.chroot
BuildScripts=%D/shared/snow/scripts/build/surface-cert.chroot

# Post-installation scripts (run after packages installed)
PostInstallationScripts=%D/shared/kernel/scripts/postinst/mkosi.postinst.chroot
PostInstallationScripts=%D/shared/snow/scripts/postinstall/snow.postinst.chroot

# Finalization (prepare for boot)
FinalizeScripts=%D/shared/outformat/oci/finalize/mkosi.finalize.chroot

# Post-output (tag OCI image, process manifest)
PostOutputScripts=%D/shared/outformat/oci/postoutput/mkosi.postoutput
PostOutputScripts=%D/shared/manifest/postoutput/mkosi.postoutput

[Include]
# Package sets
Include=%D/shared/packages/snow/mkosi.conf    # GNOME desktop
Include=%D/shared/kernel/backports/mkosi.conf # Backports kernel
Include=%D/shared/outformat/oci/mkosi.conf    # OCI output format
```

### Profile Comparison

| Profile             | Kernel    | Extra Packages                 | Include Path                                                                |
| ------------------- | --------- | ------------------------------ | --------------------------------------------------------------------------- |
| **snow**            | backports | —                              | `kernel/backports`, `packages/snow`, `outformat/oci`                        |
| **snowfield**       | surface   | —                              | `kernel/surface`, `packages/snow`, `outformat/oci`                          |
| **snowloaded**      | backports | Edge, VSCode, Bitwarden, Incus | + `packages/edge`, `packages/vscode`, `packages/bitwarden`, `packages/virt` |
| **snowfieldloaded** | surface   | Edge, VSCode, Bitwarden, Incus | + `packages/edge`, `packages/vscode`, `packages/bitwarden`, `packages/virt` |

## Building Images

### Prerequisites

- [mkosi](https://github.com/systemd/mkosi) (v24+)
- [just](https://github.com/casey/just) task runner
- Root/sudo access (mkosi requires privileges for chroot operations)

### Build Commands

```bash
# List available build targets
just

# Build system extensions only (docker, incus, podman)
just sysexts

# Build snow desktop image
just snow

# Build snowfield (Surface devices)
just snowfield

# Build loaded variants
just snowloaded
just snowfieldloaded

# Clean build artifacts
just clean
```

### Build Process

1. **Base Build**: The `base` image is built first and cached in `output/base/`
2. **Profile Application**: Selected profile's `mkosi.conf` is loaded, which includes shared components
3. **Package Installation**: Packages from all included configs are installed
4. **Script Execution**: Build → PostInstall → Finalize → PostOutput scripts run in order
5. **Output Generation**: Final image written to `output/` in the configured format

### Output Artifacts

```
output/
├── base/                    # Base image directory (build cache)
├── snow/                    # OCI image directory
├── snow.manifest            # Package manifest (JSON)
├── snow.vmlinuz             # Extracted kernel for boot
├── docker.raw               # Docker sysext (erofs)
├── docker.manifest          # Package manifest
├── incus.raw                # Incus sysext
├── podman.raw               # Podman sysext
└── ...
```

## Repository Configuration

External repositories are configured in `mkosi.sandbox/etc/apt/` for packages not in Debian:

- **Docker**: docker.com official repository
- **Incus**: Zabbly repository
- **linux-surface**: Surface kernel packages
- **Frostyard**: Custom packages (nbc, chairlift, updex)

## CI/CD Pipeline

The project uses GitHub Actions for automated builds and publishing:
Where feasible, third-party workflow actions are pinned to specific commit SHAs to improve reproducibility and supply-chain safety.

### build.yml - System Extensions

Triggered on push/PR to main, this workflow:

1. Builds the base image and all sysexts (1password-cli, debdev, dev, docker, incus, podman)
2. Publishes sysexts to the Frostyard repository (Cloudflare R2) via the `frostyard/repogen` action
3. Uploads package manifests for version tracking

### build-images.yml - OCI Images

Triggered on push/PR to main or via repository dispatch, this workflow:

1. Runs a matrix build of all 4 profiles (snow, snowloaded, snowfield, snowfieldloaded)
2. Pushes OCI images to GitHub Container Registry (ghcr.io) with version and `latest` tags
3. Uploads manifests to R2 for tracking

## Frostyard Custom Packages

The Frostyard repository provides custom packages for Snow Linux:

- **nbc** (Not BootC): CLI tool for installing, updating bootc-compatible container based Operating Systems
- **chairlift**: System extension manager with GUI integration
- **updex**: Update executor service for applying staged updates

## Immutable OS Filesystem Layout

The images produced by snosi are **immutable atomic systems**. Understanding the filesystem layout is essential for packaging decisions:

```
/                   ← Read-only root filesystem (erofs/squashfs)
├── usr/            ← Read-only, contains all OS binaries and libraries
├── etc/            ← Overlay: base layer from /usr/etc, writes go to persistent storage
├── var/            ← Persistent, writable (logs, caches, container storage, databases)
├── home/           ← Persistent, writable (user data)
├── opt/            ← Bind mount to /var/opt (writable, persistent)
└── run/            ← tmpfs, ephemeral
```

### Key Constraints

| Path     | Behavior                 | Implication                                           |
| -------- | ------------------------ | ----------------------------------------------------- |
| `/usr/*` | Read-only after boot     | All binaries, libraries, icons must live here         |
| `/etc/*` | Overlay on `/usr/etc`    | Base configs in image, user changes persist           |
| `/opt/*` | Bind mount to `/var/opt` | Writable, but **problematic for sysexts** (see below) |
| `/var/*` | Persistent, writable     | Container storage, logs, state - but not binaries     |

### Why `/opt` Is Problematic

Many third-party packages (Chrome, Edge, VS Code, Slack, etc.) install to `/opt` because they expect a traditional mutable filesystem.

On the **base bootc image**, `/opt` is a bind mount to `/var/opt`, making it writable and persistent. This works fine for packages baked into the main image—you relocate them to `/usr/lib` at build time, and `/opt` remains available for user-installed software.

However, **sysexts change the equation**. System extensions use overlay filesystems to merge their contents with the base system. If a sysext contains files in `/opt`:

1. **The sysext merge makes `/opt` read-only** - the overlay takes precedence over the bind mount
2. **Applications expecting writable `/opt` break** - they can no longer write configs, caches, or updates
3. **The bind mount to `/var/opt` is shadowed** - user data in `/var/opt` becomes inaccessible

This is why we **always relocate `/opt` contents to `/usr/lib`** during build, for both main images and sysexts. It keeps `/opt` available as a writable bind mount for runtime use while ensuring package binaries are in the read-only, atomically-updated `/usr` tree.

## Extending the Build

### Adding a New Package Set

Most packages "just work" - you add them to a `mkosi.conf` and they install correctly to `/usr`. However, some packages require post-installation scripts to relocate files or fix paths.

#### Simple Package (No Scripts Needed)

For packages that install to standard locations (`/usr/bin`, `/usr/lib`, `/usr/share`):

1. Create `shared/packages/mypackages/mkosi.conf`:

   ```ini
   [Content]
   Packages=package1
            package2
   ```

2. Include it in a profile:
   ```ini
   [Include]
   Include=%D/shared/packages/mypackages/mkosi.conf
   ```

#### Complex Package Example: Microsoft Edge

Microsoft Edge installs to `/opt/microsoft/msedge/`, which won't work on an immutable OS. The [edge package](shared/packages/edge/) includes a post-installation script to fix this:

**Directory structure:**

```
shared/packages/edge/
├── mkosi.conf                 # Package definition
└── mkosi.postinst.d/
    └── edge.chroot            # Post-installation script
```

**[mkosi.conf](shared/packages/edge/mkosi.conf):**

```ini
[Content]
Packages=microsoft-edge-stable
```

**[edge.chroot](shared/packages/edge/mkosi.postinst.d/edge.chroot):** (runs inside the build chroot)

```bash
#!/bin/bash
set -euo pipefail

# Move Edge from /opt to /usr/lib (read-only safe location)
mv /opt/microsoft/msedge /usr/lib/microsoft-edge
rm -rf /opt/microsoft

# Create symlink for the binary
ln -sf /usr/lib/microsoft-edge/microsoft-edge /usr/bin/microsoft-edge-stable

# Fix icon paths (Edge expects /opt paths)
mkdir -p /usr/share/icons/hicolor/{16x16,24x24,32x32,48x48,64x64,128x128,256x256}/apps
for size in 16 24 32 48 64 128 256; do
    ln -sf /usr/lib/microsoft-edge/product_logo_${size}.png \
           /usr/share/icons/hicolor/${size}x${size}/apps/microsoft-edge.png
done

# Fix GNOME Control Center default apps XML
sed -i 's|/opt/microsoft/msedge/microsoft-edge|/usr/lib/microsoft-edge/microsoft-edge|g' \
    /usr/share/gnome-control-center/default-apps/microsoft-edge.xml
```

**Profile usage** ([snowloaded/mkosi.conf](mkosi.profiles/snowloaded/mkosi.conf)):

```ini
[Content]
PostInstallationScripts=%D/shared/packages/edge/mkosi.postinst.d/edge.chroot

[Include]
Include=%D/shared/packages/edge/mkosi.conf
```

#### When You Need Post-Installation Scripts

You need a `mkosi.postinst.chroot` script when a package:

| Issue                                        | Solution                                                   |
| -------------------------------------------- | ---------------------------------------------------------- |
| Installs binaries to `/opt`                  | Move to `/usr/lib/<package>`, symlink binary to `/usr/bin` |
| Has hardcoded `/opt` paths in configs        | Use `sed` to rewrite paths                                 |
| Expects to write to `/etc` at install time   | Move default configs to `/usr/share/factory/etc`           |
| Creates state directories in wrong locations | Ensure state goes to `/var`                                |
| Relies on `update-alternatives`              | Create symlinks manually                                   |

### Adding a New Profile

1. Create `mkosi.profiles/myprofile/mkosi.conf`
2. Set output name and include required components
3. Add post-installation scripts for any packages that need relocation
4. Add a just target:
   ```just
   myprofile: clean
       mkosi --profile myprofile build
   ```

### Adding a New Sysext

System extensions have **additional constraints** beyond regular packages because they overlay onto an already-running immutable system.

#### Sysext Filesystem Constraints

```
mysysext.raw (erofs image)
└── usr/                    ← ONLY /usr is merged into the base system
    ├── bin/
    ├── lib/
    └── share/
```

Sysexts can **only** provide files under `/usr`. They cannot:

- Add files to `/etc` (the overlay is already mounted)
- Add files to `/var` (it's persistent state, not part of the image)
- Run post-installation scripts on the target system (no dpkg triggers)

#### Sysext Script Types

| Script                  | When It Runs               | Purpose                            |
| ----------------------- | -------------------------- | ---------------------------------- |
| `mkosi.postinst.chroot` | Build time, in chroot      | Relocate files, fix paths          |
| `mkosi.finalize`        | Build time, outside chroot | Capture `/etc` to factory defaults |
| `mkosi.postoutput`      | After image creation       | Rename output, update manifests    |

#### Example: Incus Sysext

The [incus sysext](mkosi.images/incus/) needs special handling because:

1. **Incus packages install configs to `/etc`** - but sysexts can't modify `/etc` at runtime
2. **The sysext needs versioned filenames** - for update management

**[mkosi.finalize](mkosi.images/incus/mkosi.finalize):** (captures `/etc` for tmpfiles.d)

```bash
#!/bin/bash
set -e

# Copy /etc to /usr/share/factory/etc so systemd-tmpfiles
# can symlink configs into /etc at boot time
mkdir -p "$BUILDROOT/usr/share/factory/"
cp --archive --no-target-directory --update=none \
   "$BUILDROOT/etc" "$BUILDROOT/usr/share/factory/etc"
```

This pattern allows configs to be "injected" into `/etc` via systemd-tmpfiles rules when the sysext is activated.

**[mkosi.postoutput](mkosi.images/incus/mkosi.postoutput):** (versioned naming)

```bash
#!/bin/bash
# Extract version from manifest and rename output file
KEYVERSION=$(jq -r '.packages[] | select(.name == "incus") | .version' "$MANIFEST_FILE")
ARCH=$(jq -r '.packages[] | select(.name == "incus") | .architecture' "$MANIFEST_FILE")

# Rename: incus.raw → incus_6.20-debian13_amd64.raw
cp "$OUTPUTDIR/incus.raw" "$OUTPUTDIR/incus_${KEYVERSION}_${ARCH}.raw"
ln -s "incus_${KEYVERSION}_${ARCH}.raw" "$OUTPUTDIR/incus"
```

#### Sysext Checklist

When creating a new sysext, verify:

- [ ] All binaries are under `/usr/bin` or `/usr/lib`
- [ ] No files in `/opt` (relocate during build)
- [ ] Configs captured to `/usr/share/factory/etc` if needed
- [ ] No runtime dependencies on post-install scripts
- [ ] Symlinks/alternatives created manually (no `update-alternatives`)
- [ ] State directories expected in `/var` (not baked into image)
- [ ] Use tmpfiles.d, sysusers.d and systemd presets first, as a last resort add a one-shot systemd unit for any preconfiguration that usually would happen in the debian package's postinst scripts

#### Basic Sysext Template

```ini
# mkosi.images/mysysext/mkosi.conf
[Output]
ImageId=mysysext
Overlay=yes
Format=sysext

[Content]
Bootable=no
BaseTrees=%O/base
Packages=mypackage
```

If the package needs relocation, add:

```bash
# mkosi.images/mysysext/mkosi.postinst.chroot
#!/bin/bash
set -euo pipefail

# Move from /opt to /usr/lib
mv /opt/mypackage /usr/lib/mypackage
ln -sf /usr/lib/mypackage/bin/mybin /usr/bin/mybin
```

```bash
# mkosi.images/mysysext/mkosi.finalize
#!/bin/bash
set -e

# Capture /etc for systemd-tmpfiles
mkdir -p "$BUILDROOT/usr/share/factory/"
cp --archive --no-target-directory --update=none \
   "$BUILDROOT/etc" "$BUILDROOT/usr/share/factory/etc"
```

### Adding External Downloads with Checksum Verification

Some build scripts download files directly from external URLs (not via apt). These downloads use SHA256 checksum verification for security and reproducibility.

#### Files Involved

```
shared/download/
├── verified-download.sh   # Helper function for verified downloads
├── checksums.json         # Pinned URLs and SHA256 checksums
└── update-checksums.sh    # Manual helper to update a checksum
```

**checksums.json** contains entries like:

```json
{
  "bitwarden": {
    "url": "https://github.com/bitwarden/clients/releases/download/desktop-v2025.12.1/Bitwarden-2025.12.1-amd64.deb",
    "sha256": "33a5056f43b6205fe168f64f3fc7d52cef4c5ccbe06951584d037664aa3c6c50",
    "version": "2025.12.1"
  }
}
```

#### Using Verified Downloads in Build Scripts

In any `.chroot` build script:

```bash
#!/bin/bash
set -euo pipefail

source "$SRCDIR/shared/download/verified-download.sh"
verified_download "mykey" "/path/to/output"
```

The `verified_download` function:
1. Reads the URL and checksum from `checksums.json` using the provided key
2. Downloads the file with retries
3. Verifies the SHA256 checksum matches
4. Fails the build with a clear error if verification fails

#### Adding a New External Download

1. **Add the entry to checksums.json:**

   ```bash
   # Download the file and compute checksum
   curl -fsSL -o /tmp/myfile "https://example.com/myfile.tar.gz"
   sha256sum /tmp/myfile
   ```

   Then add to `shared/download/checksums.json`:

   ```json
   {
     "mykey": {
       "url": "https://example.com/myfile.tar.gz",
       "sha256": "<computed_sha256>",
       "version": "1.2.3"
     }
   }
   ```

   Or use the helper script:

   ```bash
   ./shared/download/update-checksums.sh mykey "https://example.com/myfile.tar.gz" "1.2.3"
   ```

2. **Use in your build script:**

   ```bash
   source "$SRCDIR/shared/download/verified-download.sh"
   verified_download "mykey" "/tmp/myfile.tar.gz"
   ```

#### Pinning Strategy

- **GitHub releases**: Use the direct release asset URL with version in path (not `latest` redirects)
- **Raw files from repos**: Pin to a specific commit SHA, not `HEAD` or branch names
- **Version field**: Store the version/commit for tracking; the GitHub Action uses this to detect updates

#### Automated Update Checking

The `.github/workflows/check-dependencies.yml` workflow runs weekly to check for updates:

1. Compares pinned versions against latest releases/commits
2. If updates are found, downloads new files and computes checksums
3. Creates a PR with updated `checksums.json`
4. **Requires manual review** before merging - verify builds work with new versions

To check manually or trigger an update PR, use the "Run workflow" button in GitHub Actions.

## License

See individual package licenses. This build system configuration is provided as-is.
