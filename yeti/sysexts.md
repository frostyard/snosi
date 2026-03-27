# System Extensions (Sysexts)

## Overview

Sysexts are overlay images that extend the immutable base OS by adding files under `/usr`. They are distributed as EROFS images and managed by systemd-sysext at runtime and systemd-sysupdate for downloads.

## Constraints

1. **Only `/usr`** — Sysexts can only provide files under `/usr`. They cannot directly modify `/etc` or `/var`.
2. **Config injection** — Configs needed in `/etc` must be:
   - Captured to `/usr/share/factory/etc/` during the sysext build (via mkosi.finalize)
   - Injected at boot via systemd-tmpfiles rules in `/usr/lib/tmpfiles.d/`
3. **Overlay composition** — All sysexts overlay the same base `/usr`, so file conflicts between sysexts must be avoided.

## Current Sysexts

| Sysext | KEYPACKAGE | Description |
|--------|------------|-------------|
| **1password-cli** | 1password-cli | 1Password CLI tool |
| **debdev** | debootstrap | Debian development tools (debootstrap, distro-info, arch-test) |
| **dev** | build-essential | Build essentials, cmake, Python3, valgrind, gdb, strace |
| **docker** | docker-ce | Docker CE, containerd, buildx, compose |
| **emdash** | emdash | Emdash terminal (GTK/NSS/libnotify deps) |
| **himmelblau** | himmelblau | Entra ID authentication (himmelblau, pam-himmelblau, nss-himmelblau) |
| **incus** | incus | Incus container/VM manager, QEMU/KVM, dnsmasq, OVMF |
| **nix** | nix-setup-systemd | Nix package manager with systemd integration |
| **podman** | podman | Podman, distrobox, buildah, crun, slirp4netns |
| **tailscale** | tailscale | Tailscale VPN client |

## Sysext Configuration Pattern

Every sysext mkosi.conf follows the same structure:

```ini
[Distribution]
Distribution=debian
Release=trixie

[Output]
Dependencies=base
Overlay=yes
ManifestFormat=json
ImageId=<sysext-name>
Format=sysext

[Content]
BaseTrees=%O/base
Packages=<package-list>

[Output]
Environment=KEYPACKAGE=<package-name>
PostOutputScripts=%D/shared/sysext/postoutput/sysext-postoutput.sh
```

Key settings:
- `Dependencies=base` — Requires the base image to be built first
- `Overlay=yes` — This is an overlay on the base image
- `BaseTrees=%O/base` — Uses the base image output as the filesystem base
- `Format=sysext` — Outputs an EROFS sysext image
- `KEYPACKAGE` — The package whose version determines the sysext version

## Sysext-Specific Extra Files

Some sysexts include extra files via `mkosi.extra/`:

### docker
- `usr/lib/systemd/system-preset/40-docker.preset` — Enable docker services
- `usr/lib/sysusers.d/docker-sysext.conf` — Docker user/group definitions
- `usr/lib/tmpfiles.d/docker-sysext.conf` — Runtime directory setup

### himmelblau
- `usr/lib/himmelblau/himmelblau-sysext-setup` — Runtime PAM/NSS injection script (idempotent, runs at boot)
- `usr/lib/systemd/system/himmelblau-sysext-setup.service` — Oneshot service to run setup script
- `usr/lib/systemd/system-preset/40-himmelblau.preset` — Enable himmelblau services
- `usr/lib/tmpfiles.d/himmelblau.conf` — Config injection from `/usr/share/factory/etc/`

### incus
- `usr/lib/systemd/system/incus.service.d/override.conf` — Service override
- `usr/lib/systemd/system-preset/40-incus.preset` — Enable incus services
- `usr/lib/sysusers.d/incus-sysext.conf` — User/group definitions
- `usr/lib/tmpfiles.d/incus-sysext.conf` — Runtime directory setup
- `usr/bin/incus-sysext-setup` — Custom setup script

### nix
- `usr/lib/systemd/` — Mount unit and preset for `/nix` bind mount
- `usr/lib/sysusers.d/nix.conf` — Nix user/group
- `usr/lib/tmpfiles.d/nix-sysext.conf` — Runtime setup

### tailscale
- `usr/lib/systemd/system-preset/40-tailscale.preset` — Enable tailscaled
- `usr/lib/tmpfiles.d/tailscale-sysext.conf` — Runtime directory setup

## Version Extraction and Naming

The shared postoutput script (`shared/sysext/postoutput/sysext-postoutput.sh`) handles versioning:

1. Reads `KEYPACKAGE` from environment
2. Queries the manifest JSON for the key package's version
3. Handles Debian epoch notation: `5:1.2.3` → `5+1.2.3`
4. Maps Debian release to VERSION_ID: forky → 14, trixie → 13, bookworm → 12, bullseye → 11, buster → 10
5. Renames the raw image: `{IMAGE_ID}_{KEYVERSION}_{OS_VERSION}_{ARCH}.raw`
   - Example: `docker_5+29.3.0_13_x86-64.raw`
6. Annotates manifest with `.config.key_package` and `.config.key_version`
7. Creates unversioned symlink for systemd-sysupdate MatchPattern

## Sysupdate Registration

Each sysext needs two files in the base image at `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/`:

### Transfer file (`<name>.transfer`)

Defines how systemd-sysupdate downloads the sysext:

```ini
[Transfer]
ProtectVersion=%A

[Source]
Type=url-file
Path=https://repository.frostyard.org/ext/<name>/
MatchPattern=<name>_@v_@o_@a.raw

[Target]
Type=regular-file
Path=/var/lib/extensions.d/
MatchPattern=<name>_@v_@o_@a.raw
```

### Feature file (`<name>.feature`)

Provides metadata and defaults:

```ini
[SysUpdate]
Description=<description>
Documentation=<url>
Enabled=false
```

All sysexts default to `Enabled=false` — users opt in via systemd-sysupdate configuration.

## Runtime Setup Service Pattern

Some sysexts need to modify files that already exist in the base image (e.g., `/etc/nsswitch.conf`, PAM configs). The tmpfiles `C` (copy-if-absent) directive cannot overwrite existing files, so a runtime setup service is needed instead.

**Pattern** (used by himmelblau and incus):
1. Create an idempotent setup script at `usr/lib/<name>/<name>-sysext-setup` that patches the target files (e.g., adds NSS modules to nsswitch.conf, configures PAM stacks)
2. Create a oneshot systemd service (`<name>-sysext-setup.service`) that runs the script at boot
3. Enable via preset (`40-<name>.preset`)

The setup script must be idempotent — safe to run on every boot without accumulating duplicate entries.

## Adding a New Sysext

1. Create `mkosi.images/<name>/mkosi.conf` following the pattern above
2. Set `KEYPACKAGE` to the primary package name
3. Add any extra files in `mkosi.images/<name>/mkosi.extra/`
4. If configs needed in `/etc`: create `mkosi.finalize` to capture to `/usr/share/factory/etc/`, add tmpfiles.d rules
5. Create `<name>.transfer` and `<name>.feature` in `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/`
6. Add the sysext name to root `mkosi.conf` Dependencies list
7. Add a corresponding update check to `.github/workflows/check-dependencies.yml` if it has external downloads
