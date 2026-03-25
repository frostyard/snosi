# snosi Overview

## Purpose

snosi is a bootable container image build system that uses [mkosi](https://github.com/systemd/mkosi) to produce Debian Trixie-based immutable OS images and system extensions (sysexts). It outputs OCI desktop/server images deployed via bootc/systemd-boot with atomic updates, and EROFS sysext overlays distributed via systemd-sysupdate.

## Outputs

### Desktop Images (OCI, pushed to ghcr.io)

| Image | Kernel | Extras |
|-------|--------|--------|
| **snow** | backports | GNOME desktop, podman, flatpak |
| **snowloaded** | backports | snow + Edge, VSCode, Bitwarden, Incus, Azure VPN |
| **snowfield** | linux-surface | GNOME desktop (Surface devices) |
| **snowfieldloaded** | linux-surface | snowfield + loaded extras |

### Server Images (OCI, pushed to ghcr.io)

| Image | Kernel | Extras |
|-------|--------|--------|
| **cayo** | backports | Headless server, podman |
| **cayoloaded** | backports | cayo + Docker CE + Incus (baked in) |

### System Extensions (EROFS sysexts, published to Frostyard R2 repo)

1password-cli, debdev, dev, docker, emdash, incus, nix, podman, tailscale

## Architecture

### Directory Layout

```
mkosi.conf                  # Root config: distribution, dependencies, build settings
mkosi.images/               # Image definitions (base + 9 sysexts)
  base/                     # Foundation image: systemd, bootc, firmware, core utils
    mkosi.extra/            # Extra filesystem overlay (dracut, systemd units, tmpfiles, sysusers)
      usr/lib/sysupdate.d/  # .transfer + .feature files for all sysexts
  docker/                   # Each sysext: mkosi.conf + optional extra/scripts
  tailscale/
  ...
mkosi.profiles/             # Desktop/server profile definitions
  snow/                     # Each profile: mkosi.conf + build/postinst/finalize scripts
  cayo/
  ...
shared/                     # Reusable fragments composed via Include=
  download/                 # Verified download system (checksums.json + helpers)
  kernel/                   # Kernel variant configs (backports, surface, stock)
  packages/                 # Package set configs with postinstall relocation scripts
  outformat/image/          # OCI output format, buildah/chunkah packaging
  sysext/postoutput/        # Shared sysext versioning and manifest logic
  manifest/postoutput/      # Image manifest processing
  snow/                     # Snow desktop: build scripts + tree overlay
  snowloaded/               # Snowloaded: additional tree overlay
  cayo/                     # Cayo server: build scripts + tree overlay
mkosi.sandbox/etc/apt/      # External APT repo configs + GPG keyrings
.github/workflows/          # CI/CD (build, publish, dependency checks, testing)
test/                       # Bootc installation test framework
docs/                       # Design specs and implementation plans
```

### Configuration Composition

mkosi configs compose via `Include=` directives. Each profile pulls in reusable fragments:

```
Profile (e.g., snow/mkosi.conf)
├── Include: shared/packages/snow/mkosi.conf      # Package set
├── Include: shared/kernel/backports/mkosi.conf    # Kernel variant
├── Include: shared/packages/fw-ipw/mkosi.conf     # Intel WiFi firmware
├── Include: shared/outformat/image/mkosi.conf     # Output format (directory)
├── Dependencies: base                              # Requires base image
├── ExtraTrees: shared/snow/tree                    # Filesystem overlay
├── BuildScripts: brew.chroot, hotedge.chroot, ... # Build-time scripts
├── PostInstallationScripts: snow.postinst.chroot   # Post-package scripts
├── FinalizeScripts: mkosi.finalize.chroot          # Pre-output scripts
└── PostOutputScripts: mkosi.postoutput             # Post-output scripts
```

The "loaded" variants (snowloaded, snowfieldloaded, cayoloaded) extend their base profile by adding more Include directives, ExtraTrees, and PostInstallationScripts for additional packages like Edge, VSCode, Docker, and Incus.

### Script Pipeline

Scripts execute in order per image build:

1. **BuildScripts** (in chroot) — Download/install items not available as packages: Homebrew, GNOME extensions, Surface secure boot cert
2. **PostInstallationScripts** (after packages) — Package relocation (/opt → /usr/lib), OS release branding, systemd service enablement, cleanup
3. **FinalizeScripts** (pre-output) — Remove ephemeral dirs (/boot, /home), clear machine-id/SSH keys, compile GLib schemas, set file xattrs for chunkah
4. **PostOutputScripts** (after image creation) — Manifest processing, sysext versioned renaming

See [build-pipeline.md](build-pipeline.md) for details.

### Immutable Filesystem

```
/usr/       Read-only. All binaries, libraries, configs.
/etc/       Overlay on /usr/etc. Base from image, user changes persist.
/var/       Persistent, writable. Logs, state, container storage.
/home/      Persistent (/var/home bind). User data.
/opt/       Bind mount to /var/opt. Writable but shadowed by sysext overlays.
```

**Critical pattern:** Packages installing to `/opt` must be relocated to `/usr/lib/<package>` at build time with symlinks from `/usr/bin`. See [build-pipeline.md](build-pipeline.md#package-relocation).

### Sysext Architecture

Sysexts overlay `/usr` at runtime. They cannot modify `/etc` or `/var` directly. Each sysext:

- Has `Overlay=yes`, `Format=sysext`, `Dependencies=base`, `BaseTrees=%O/base`
- Sets `KEYPACKAGE` env var for version extraction from manifest
- Uses shared postoutput script for versioned naming
- Needs matching `.transfer` + `.feature` files in base image's `usr/lib/sysupdate.d/`
- Configs needed in `/etc` go through `/usr/share/factory/etc` + systemd-tmpfiles

See [sysexts.md](sysexts.md) for details.

## Key Patterns

### Verified Downloads

External resources are pinned in `shared/download/checksums.json` with URL + SHA256. Scripts use `verified_download(key, output_path)` from `shared/download/verified-download.sh`. CI workflow `check-dependencies.yml` detects updates weekly and creates PRs.

Package versions for APT-based externals (Edge, VSCode, Docker, 1Password) are tracked separately in `shared/download/package-versions.json`, checked daily by `check-packages.yml`.

### User Service Enablement in Chroot

`systemctl --user enable` does not work in mkosi chroot (no D-Bus session). Workaround:

```bash
mkdir -p /etc/systemd/user/<target>.wants
ln -sf /usr/lib/systemd/user/<service> /etc/systemd/user/<target>.wants/<service>
```

### OCI Image Packaging

Images are built as directories, then packaged into OCI via `buildah-package.sh` using `buildah mount` + `cp -a` + `buildah commit`. This avoids `buildah COPY` which drops SUID bits (buildah#4463). Layer optimization is done via `chunkah-package.sh`.

### Shell Script Conventions

- `set -euo pipefail` at the top of all scripts
- `.chroot` extension for scripts running inside chroot
- External downloads via `verified_download()` only
- Pin external URLs to specific versions, never `latest`

## Configuration

### Build Requirements

- mkosi v24+, just, root/sudo access
- For CI: buildah, skopeo, podman, cosign

### Build Commands

```bash
just                    # List targets
just sysexts            # Build base + all 9 sysexts
just snow               # Build snow desktop
just snowloaded         # Build snowloaded variant
just snowfield          # Build snowfield (Surface)
just snowfieldloaded    # Build snowfieldloaded variant
just cayo               # Build cayo server
just cayoloaded         # Build cayoloaded variant
just clean              # Remove build artifacts
just test-install       # Run bootc install test
```

All `just` targets run `mkosi clean` first (clean build every time).

### Key Environment Variables

| Variable | Where Set | Purpose |
|----------|-----------|---------|
| `KEYPACKAGE` | Sysext mkosi.conf `[Output]` | Package name for sysext version extraction |
| `IMAGE_ID` | Profile mkosi.conf | Image identifier (snow, cayo, etc.) |
| `IMAGE_VERSION` | mkosi.version (timestamp) | Build version (YYYYMMDDHHMMSS) |
| `BUILD_ID` | CI environment | Injected into os-release |

### External APT Repositories

Configured in `mkosi.sandbox/etc/apt/` with GPG keyrings:

- Docker (docker.com) — Docker CE packages
- Frostyard (repository.frostyard.org) — Custom packages: nbc, chairlift, updex, igloo, intuneme, snow-first-setup
- Linux Surface (pkg.surfacelinux.com) — Surface kernel + tools
- Microsoft — Edge, VSCode
- 1Password — CLI tool
- Tailscale — VPN client
- Debian Backports — Newer kernel + firmware + mesa

## CI/CD

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `build.yml` | Push/PR to main | Build base + sysexts, publish to R2 |
| `build-images.yml` | Push/PR/dispatch | Matrix build of 6 profiles, push OCI to ghcr.io, sign with cosign |
| `check-dependencies.yml` | Weekly (Mon 9am UTC) | Check external download updates, create PRs |
| `check-packages.yml` | Daily (8am UTC) | Check APT package version updates, create PRs |
| `validate.yml` | PR/push | shellcheck + mkosi summary validation |
| `test-install.yml` | Manual dispatch | Bootc install test in QEMU/KVM |
| `scorecard.yml` | Weekly | OpenSSF supply-chain security analysis |

See [ci-cd.md](ci-cd.md) for details.

## Testing

The `test/` directory contains a bootc installation test framework:

- `bootc-install-test.sh` — Orchestrator: loads OCI image, runs bootc install to-disk, boots in QEMU, runs tests via SSH
- 4-tier test suite: installation validation → service health → sysext validation → smoke tests

See [testing.md](testing.md) for details.

## Detailed Documentation

- [Build Pipeline](build-pipeline.md) — Script execution, package relocation, OCI packaging
- [Sysexts](sysexts.md) — Sysext creation, constraints, update mechanism
- [CI/CD](ci-cd.md) — Workflow details, publishing, dependency automation
- [Testing](testing.md) — Test framework architecture and tiers
