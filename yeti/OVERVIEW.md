# snosi Overview

## Purpose

snosi is a bootable container image build system that uses [mkosi](https://github.com/systemd/mkosi) to produce Debian Trixie-based immutable OS images and system extensions (sysexts). It outputs OCI desktop/server images deployed via bootc/systemd-boot with atomic updates, plus EROFS sysext overlays distributed through systemd-sysupdate.

## Outputs

### Desktop Images (OCI, pushed to ghcr.io)

| Image | Kernel | Extras |
|-------|--------|--------|
| **snow** | backports | GNOME desktop, podman, flatpak |
| **snowloaded** | backports | snow + Edge, VSCode, Bitwarden, Incus, Azure VPN, Entra SSO (linux-entra-sso) |
| **snowfield** | linux-surface | GNOME desktop (Surface devices) |
| **snowfieldloaded** | linux-surface | snowfield + loaded extras (Edge, VSCode, Bitwarden, Incus, Azure VPN, Entra SSO (linux-entra-sso)) |

### Server Images (OCI, pushed to ghcr.io)

| Image | Kernel | Extras |
|-------|--------|--------|
| **cayo** | backports | Headless server, podman |
| **cayoloaded** | backports | cayo + Docker CE + Incus (baked in) |

### System Extensions (EROFS sysexts, published to Frostyard R2 repo)

1password-cli, code-server, debdev, dev, docker, himmelblau, incus, nix, podman, tailscale

## Architecture

### Directory Layout

```
mkosi.conf                  # Root config: distribution, dependencies, build settings
mkosi.version               # Version tag script (date-based, overridden by CI IMAGE_VERSION)
mkosi.clean                 # Clean script (rm -rf output/*)
mkosi.images/               # Image definitions (base + 10 sysexts)
  base/                     # Foundation image: systemd, in-tree bootc/ostree, firmware, core utils
    mkosi.extra/            # Base filesystem overlay (dracut, systemd units/timers, sysupdate, tmpfiles, sysusers)
      usr/lib/sysupdate.d/  # .transfer + .feature files for all sysexts
    mkosi.postinst.chroot   # Mount enablement, useradd home dir, bls-garbage-collect removal
    mkosi.finalize.chroot   # Masks systemd-networkd-wait-online
  docker/                   # Each sysext: mkosi.conf + optional extra/scripts
  tailscale/
  ...
mkosi.profiles/             # Desktop/server profile definitions (6 profiles)
  snow/                     # Each profile: mkosi.conf + build/postinst/finalize scripts
  cayo/
  ...
shared/                     # Reusable fragments composed via Include=
  download/                 # Verified download system (checksums.json, package-versions.json + helpers)
  bootc/                    # In-tree source build: build/bootc.chroot compiles ostree+bootc from pinned tarballs
  kernel/                   # Kernel variant configs (backports, surface, stock)
  packages/                 # Package set configs (11 sets) with postinstall relocation scripts
  scripts/                  # Shared scripts (common-postinst.sh sourced by all profiles, brew.chroot build script)
  outformat/image/          # OCI output format, buildah/chunkah packaging
  sysext/postoutput/        # Shared sysext versioning and manifest logic
  manifest/postoutput/      # Image manifest processing
  snow/                     # Snow desktop: build scripts + tree overlay
  snowloaded/               # Snowloaded: additional tree overlay
  cayo/                     # Cayo server: postinstall scripts + tree overlay
mkosi.sandbox/etc/apt/      # External APT repo configs + GPG keyrings
.github/workflows/          # CI/CD (build, publish, dependency checks, testing)
test/                       # Bootc install, update, rollback, and VM smoke test framework
docs/                       # Design specs, implementation plans, superpowers
sysextmv.sh                 # Moves sysext output files into output/sysexts/ subdirectory
manifestmv.sh               # Moves manifest files into output/manifests/ subdirectory
check-duplicate-packages.sh # Validates no duplicate packages across mkosi configs (CI pre-build check)
Justfile                    # Build targets (just sysexts, just snow, etc.)
```

### Configuration Composition

mkosi configs compose via `Include=` directives. Each profile pulls in reusable fragments:

Root `mkosi.conf` lists `base` plus all in-repo sysexts for the sysext publishing build. Each `mkosi.profiles/*/mkosi.conf` starts with `Dependencies=` and then `Dependencies=base` to reset mkosi's append-only collection semantics; profile image builds must not inherit the sysext list. The base image also carries sysupdate registration for the external `emdash` sysext even though that sysext is published from a separate repository.

```
Profile (e.g., snow/mkosi.conf)
├── Include: shared/packages/snow/mkosi.conf       # Package set
├── Include: shared/kernel/backports/mkosi.conf    # Kernel variant
├── Include: shared/outformat/image/mkosi.conf     # Output format (directory)
├── Dependencies: base                              # Requires base image
├── ExtraTrees: shared/snow/tree                    # Filesystem overlay
├── BuildScripts: shared brew.chroot, hotedge.chroot, ... # Build-time scripts
├── PostInstallationScripts: snow.postinst.chroot   # Post-package scripts
├── FinalizeScripts: mkosi.finalize.chroot          # Pre-output scripts
└── PostOutputScripts: mkosi.postoutput             # Post-output scripts
```

The "loaded" variants extend their base profile by adding more Include directives, ExtraTrees, and PostInstallationScripts:

- **snowloaded/snowfieldloaded** add Edge, VS Code, Bitwarden, Azure VPN, Incus, and Entra SSO (`linux-entra-sso`). Incus is on-image here through `shared/packages/virt`, not the separate Incus sysext.
- **cayoloaded** adds Docker CE on-image via `docker-onimage` and Incus on-image via `virt-base`.

### Script Pipeline

Scripts execute in order per image build:

1. **BuildScripts** (in chroot) — Download/install items not available as packages: Homebrew, GNOME extensions, Surface secure boot cert. The base image additionally runs `shared/bootc/build/bootc.chroot` (wired via `BuildScripts=`) to compile ostree and bootc from pinned source — build deps come from `BuildPackages=` (overlay-only, not from APT; see [build-pipeline.md](build-pipeline.md) for details).
2. **PostInstallationScripts** (after packages) — Common logic via `shared/scripts/common-postinst.sh` (OS release branding, package list generation, cleanup, sysext infra), then profile-specific steps (GDM enablement, package relocation /opt → /usr/lib). Mount enablement and useradd home dir are handled by the base image's own postinst script.
3. **FinalizeScripts** (pre-output) — Remove ephemeral dirs (/boot, /home), create /sysroot and /nix mountpoints, set machine-id to `uninitialized` (real first-boot semantics: presets re-apply at first boot), strip unit enablement symlinks from /etc (recreated at first boot as runtime state; manifest in /usr/share/snosi/), clear SSH keys, compile GLib schemas, set file xattrs for chunkah
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

### bootc Update Staging

The base image disables upstream `bootc-fetch-apply-updates.timer` and enables `bootc-update-stage.timer` instead. The custom `/usr/libexec/bootc-update-stage` script pulls the followed image with `podman`, stages it with `bootc switch --transport containers-storage`, and leaves the deployment to apply on the next normal reboot. This preserves download-only update semantics and avoids the current registry-transport composefs pull failure documented in the update validation plan.

### Sysext Architecture

Sysexts overlay `/usr` at runtime. They cannot modify `/etc` or `/var` directly. Each in-repo sysext:

- Has `Overlay=yes`, `Format=sysext`, `Dependencies=base`, `BaseTrees=%O/base`
- Sets `KEYPACKAGE` env var for version extraction from manifest
- Uses shared postoutput script for versioned naming
- Needs matching `.transfer` + `.feature` files in base image's `usr/lib/sysupdate.d/`
- Configs needed in `/etc` go through `/usr/share/factory/etc` + systemd-tmpfiles

The base image also registers `emdash.transfer` and `emdash.feature`; keep those files even though `mkosi.conf` does not build an `emdash` image in this repository.

See [sysexts.md](sysexts.md) for details.

## Key Patterns

### Verified Downloads

External resources are pinned in `shared/download/checksums.json` with URL + SHA256. Scripts use `verified_download(key, output_path)` from `shared/download/verified-download.sh`. CI workflow `check-dependencies.yml` detects updates weekly and creates PRs.

Package versions for selected APT-based externals (VSCode, Docker, 1Password, Himmelblau) are tracked separately in `shared/download/package-versions.json`, checked daily by `check-packages.yml`.

Current checksum-managed downloads are Bitwarden, Homebrew install script, code-server, ostree, bootc, bootc-vendor, Surface secure boot certificate, Hotedge, Logomenu, Bazaar Companion, Azure VPN, and Microsoft Edge. Current APT version tracking covers `code`, `docker-ce`, `1password-cli`, and `himmelblau`; Edge is checksum-managed because the build installs a patched downloaded `.deb`. `code-server` is a sysext exception: it is installed by `mkosi.images/code-server/mkosi.postinst.chroot` with `verified_download()` + `dpkg -i`, while `KEYPACKAGE=code-server` still drives version extraction from the merged dpkg database.

### User Service Enablement in Chroot

`systemctl --user enable` does not work in mkosi chroot (no D-Bus session). Workaround:

```bash
mkdir -p /etc/systemd/user/<target>.wants
ln -sf /usr/lib/systemd/user/<service> /etc/systemd/user/<target>.wants/<service>
```

**Caution:** Check `Conflicts=` directives between related services. For example, `gnome-remote-desktop-headless.service` conflicts with `gnome-remote-desktop.service` — enabling both causes failures. When creating symlinks, explicitly remove any conflicting service symlinks.

### OCI Image Packaging

Images are built as directories, then packaged into OCI via `buildah-package.sh` using `buildah mount` + `cp -a` + `buildah commit`. This avoids `buildah COPY` which drops SUID bits (buildah#4463). Layer optimization is done via `chunkah-package.sh`.

CI sets `TMPDIR=/mnt/tmp` before mkosi/buildah/chunkah work because hosted runners have more free space on `/mnt` than on `/`; large loaded variants can exhaust `/var/tmp` if this is omitted.

### Shell Script Conventions

- `set -euo pipefail` at the top of all scripts
- `.chroot` extension for scripts running inside chroot
- External downloads via `verified_download()` only
- Pin external URLs to specific versions, never `latest`

## Configuration

### Build Requirements

- just, git, python3, root/sudo access
- mkosi is auto-bootstrapped by the Justfile into a gitignored `.mkosi/` checkout at the commit pinned by the `systemd/mkosi@<sha>` action in `.github/workflows/build.yml` (parsed at runtime, so local always matches CI); override with `just mkosi=/usr/bin/mkosi <target>`
- For CI: buildah, skopeo, podman, cosign, syft, oras

### Build Commands

```bash
just                    # List targets
just sysexts            # Build base + all 10 sysexts
just snow               # Build snow desktop
just snowloaded         # Build snowloaded variant
just snowfield          # Build snowfield (Surface)
just snowfieldloaded    # Build snowfieldloaded variant
just cayo               # Build cayo server
just cayoloaded         # Build cayoloaded variant
just clean              # Remove build artifacts
just test-install       # Run bootc install test
just run-qemu           # Run image in QEMU
```

All `just` targets run `mkosi clean` first (clean build every time).

### Key Environment Variables

| Variable | Where Set | Purpose |
|----------|-----------|---------|
| `KEYPACKAGE` | Sysext mkosi.conf `[Output]` | Package name for sysext version extraction |
| `IMAGE_ID` | Profile mkosi.conf | Image identifier (snow, cayo, etc.) |
| `IMAGE_VERSION` | mkosi.version (timestamp) | Build version (YYYYMMDDHHMMSS) |
| `BUILD_ID` | CI environment | Injected into os-release |
| `BREW_TREE` | Profile mkosi.conf | Tree path for Homebrew tarball output (e.g., `shared/snow/tree`) |
| `TMPDIR` | CI workflows / local env | mkosi, buildah, and chunkah workspace location; CI points it at `/mnt/tmp` for disk headroom |

### External APT Repositories

Configured in `mkosi.sandbox/etc/apt/` with GPG keyrings:

- 1Password — CLI tool
- Debian Backports — Newer kernel + firmware + mesa
- Debian Griffo.io (debian.griffo.io) — Additional Debian packages
- Docker (docker.com) — Docker CE packages
- Himmelblau (packages.himmelblau-idm.org) — Entra ID authentication (nightly)
- Frostyard (repository.frostyard.org) — Custom packages: nbc, chairlift, updex, igloo, intuneme, snow-first-setup. **Note:** bootc and ostree are no longer sourced from this repo (the former `frostyard/bootc-debian` packaging recipe is archived); they are compiled from pinned source in-tree instead.
- Linux Surface (pkg.surfacelinux.com) — Surface kernel + tools
- Microsoft Edge (packages.microsoft.com) — Edge browser
- Microsoft VSCode (packages.microsoft.com) — VS Code editor
- Tailscale (pkgs.tailscale.com) — VPN client

## Developer Utilities (repo root)

- `compare-images.sh` — diffoscope-style comparison of two OCI images (extracts layers, handles whiteouts, reports file-level differences); dev tool, not used by CI
- `packagediff.sh` — diffs the build manifest against the running system's package list (`/usr/share/frostyard/<id>.packages.txt`)
- `check-duplicate-packages.sh` / `check-profile-dependencies.sh` — config sanity checks, run by CI

## CI/CD

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `build.yml` | Push/PR/dispatch | Build base + sysexts, publish to R2 |
| `build-images.yml` | Push/PR/repository_dispatch/dispatch | Matrix build of 6 profiles, push OCI to ghcr.io, generate SBOMs, sign with Cosign |
| `check-dependencies.yml` | Weekly (Mon 9am UTC) | Check external download updates, create PRs |
| `check-packages.yml` | Daily (8am UTC) | Check APT package version updates, create PRs |
| `validate.yml` | PR/push/dispatch | shellcheck + mkosi summary validation + profile dependency guard |
| `test-install.yml` | Manual dispatch | Bootc install test in QEMU/KVM |
| `scorecard.yml` | Weekly | OpenSSF supply-chain security analysis |

See [ci-cd.md](ci-cd.md) for details.

## Testing

The `test/` directory contains bootc installation and update test frameworks:

- `bootc-install-test.sh` — Orchestrator: loads OCI image, runs bootc install to-disk, boots in QEMU, runs tests via SSH
- 4-tier test suite: installation validation → service health → sysext validation → smoke tests
- `bootc-update-test.sh` — Orchestrator for update hops and optional rollback: installs a starting image, runs `bootc switch` to one or more target refs, reboots between hops, and verifies deployment slot continuity plus `/var` and `/etc` persistence markers

See [testing.md](testing.md) for details.

## Detailed Documentation

- [Build Pipeline](build-pipeline.md) — Script execution, package relocation, OCI packaging
- [Sysexts](sysexts.md) — Sysext creation, constraints, update mechanism
- [CI/CD](ci-cd.md) — Workflow details, publishing, dependency automation
- [Testing](testing.md) — Test framework architecture and tiers
