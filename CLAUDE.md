# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

snosi is a bootable container image build system using [mkosi](https://github.com/systemd/mkosi) to produce Debian Trixie-based immutable OS images and system extensions (sysexts). Images are deployed via bootc/systemd-boot with atomic updates.

**Outputs:** 4 OCI desktop images (snow, snowloaded, snowfield, snowfieldloaded) and 6 sysext overlay images (1password-cli, debdev, dev, docker, incus, podman).

## Build Commands

Requires: mkosi v24+, just, root/sudo access.

```bash
just                    # List targets
just sysexts            # Build base + all 6 sysexts
just snow               # Build snow desktop image
just snowloaded         # Build snowloaded variant
just snowfield          # Build snowfield (Surface kernel)
just snowfieldloaded    # Build snowfieldloaded variant
just clean              # Remove build artifacts
```

All `just` targets run `mkosi clean` first (clean build every time).

## Architecture

### Configuration Composition

mkosi configs use `Include=` directives to compose reusable fragments. The composition chain:

- `mkosi.conf` (root) declares base + sysext dependencies
- `mkosi.images/` contains base image and sysext definitions
- `mkosi.profiles/` defines desktop image variants
- `shared/` contains reusable fragments: kernel configs, package sets, output format, scripts

Each profile composes: package sets + kernel variant + output format + build/postinstall/finalize/postoutput scripts.

### Script Pipeline (per image)

Scripts execute in order: **BuildScripts** (in chroot) -> **PostInstallationScripts** (after packages) -> **FinalizeScripts** (pre-output) -> **PostOutputScripts** (after image creation).

### Immutable Filesystem Constraints

- `/usr/` - Read-only. All binaries and libraries must live here.
- `/etc/` - Overlay on `/usr/etc`. Base configs in image, user changes persist.
- `/var/` - Persistent, writable. State, logs, container storage.
- `/opt/` - Bind mount to `/var/opt`. Writable at runtime but **shadowed by sysext overlays**.

**Critical pattern:** Packages installing to `/opt` must be relocated to `/usr/lib/<package>` at build time with symlinks in `/usr/bin`. This applies to both desktop images and sysexts.

### Sysext Constraints

Sysexts can ONLY provide files under `/usr`. They cannot modify `/etc` or `/var` at runtime. Configs needed in `/etc` must be:
1. Captured to `/usr/share/factory/etc` during build (via `mkosi.finalize`)
2. Injected at boot via systemd-tmpfiles

The shared sysext postoutput script (`shared/sysext/postoutput/sysext-postoutput.sh`) handles versioned naming and manifest processing. It requires the `KEYPACKAGE` env var set in each sysext's `mkosi.conf`.

## Key Directories

- `shared/download/` - Verified download system: `checksums.json` pins URLs+SHA256s, `verified-download.sh` provides the `verified_download()` helper
- `shared/kernel/` - Kernel configs (backports, surface, stock) and dracut scripts
- `shared/packages/` - Package set definitions, some with postinstall scripts for relocation
- `shared/outformat/oci/` - OCI output format config, finalize, and postoutput scripts
- `shared/sysext/postoutput/` - Shared sysext postoutput logic
- `mkosi.sandbox/etc/apt/` - External APT repo configs (Docker, Incus, linux-surface, Frostyard)

## Shell Script Conventions

- Use `set -euo pipefail` at the top of all scripts
- Build scripts running in chroot use `.chroot` extension
- External downloads must go through `verified_download()` with entries in `checksums.json`
- Pin external URLs to specific versions/commits, never `latest` or branch names

## CI/CD

- `build.yml` - Builds base + sysexts, publishes to Frostyard repo (Cloudflare R2)
- `build-images.yml` - Matrix build of 4 desktop profiles, pushes OCI to ghcr.io
- `check-dependencies.yml` - Weekly check for external dependency updates, creates PRs with updated checksums
