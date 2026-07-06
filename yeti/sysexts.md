# System Extensions (Sysexts)

## Overview

Sysexts are overlay images that extend the immutable base OS by adding files under `/usr`. They are distributed as EROFS images and managed by systemd-sysext at runtime and systemd-sysupdate for downloads.

## Constraints

1. **Only `/usr`** — Sysexts can only provide files under `/usr`. They cannot directly modify `/etc` or `/var`.
2. **Config injection** — Configs needed in `/etc` must be:
   - Captured to `/usr/share/factory/etc/` during the sysext build (via mkosi.finalize)
   - Injected at boot via systemd-tmpfiles rules in `/usr/lib/tmpfiles.d/`
   - Capture ONLY the specific paths the tmpfiles rules reference — never all of `/etc`. The buildroot `/etc` is the merged base view, so a full capture leaks `/etc/shadow` and SSH host keys into the published sysext (frostyard/snosi#282)
3. **Overlay composition** — All sysexts overlay the same base `/usr`, so file conflicts between sysexts must be avoided.

## Current Sysexts

| Sysext | KEYPACKAGE | Description |
|--------|------------|-------------|
| **1password-cli** | 1password-cli | 1Password CLI tool |
| **code-server** | code-server | code-server (VS Code in the browser) — downloaded via `verified_download()` from coder/code-server GitHub releases |
| **debdev** | debootstrap | Debian development tools (debootstrap, distro-info, arch-test, archive keyrings) |
| **dev** | build-essential | Build essentials, cmake, Python3, valgrind, gdb, strace |
| **docker** | docker-ce | Docker CE, containerd, buildx, compose |
| **himmelblau** | himmelblau | Entra ID authentication (himmelblau, pam-himmelblau, nss-himmelblau) |
| **incus** | incus | Incus container/VM manager, QEMU/KVM, dnsmasq, OVMF, virt-viewer |
| **nix** | nix-setup-systemd | Nix package manager with systemd integration |
| **podman** | podman | Podman, distrobox, buildah, crun, slirp4netns |
| **tailscale** | tailscale | Tailscale VPN client |

## Sysext Configuration Pattern

Every sysext mkosi.conf follows the same structure:

```ini
[Config]
Dependencies=base

[Output]
ImageId=<sysext-name>
Output=<sysext-name>
Overlay=yes
ManifestFormat=json
Format=sysext

[Content]
Bootable=no
BaseTrees=%O/base
PostOutputScripts=%D/shared/sysext/postoutput/sysext-postoutput.sh

Packages=<package-list>

[Build]
Environment=KEYPACKAGE=<package-name>
```

Key settings:
- `Dependencies=base` — Requires the base image to be built first
- `Overlay=yes` — This is an overlay on the base image
- `BaseTrees=%O/base` — Uses the base image output as the filesystem base
- `Format=sysext` — Outputs an EROFS sysext image
- `KEYPACKAGE` — The package whose version determines the sysext version

`code-server` is the current exception to the `Packages=` line: it downloads a pinned upstream `.deb` in `mkosi.images/code-server/mkosi.postinst.chroot` with `verified_download()` and installs it with `dpkg -i`. It still sets `KEYPACKAGE=code-server`, and the shared postoutput script resolves that version from the merged dpkg database.

## Sysext-Specific Extra Files

Some sysexts include extra files via `mkosi.extra/`:

### code-server
- `mkosi.postinst.chroot` — Downloads code-server .deb via `verified_download()`, installs with `dpkg -i`. Upstream package targets `/usr/lib/code-server` with `/usr/bin/code-server` symlink and systemd units under `/usr/lib/systemd/`, so no relocation is required.

### debdev / dev
- `mkosi.postinst.chroot` — Repoints `/usr/bin`+`/usr/sbin` symlinks that route through `/etc/alternatives` to their resolved targets. Sysexts cannot ship `/etc`, so alternatives symlinks created while installing these sysexts' packages would dangle at runtime (observed live: `/usr/bin/automake -> /etc/alternatives/automake`, missing).

### docker
- `usr/lib/systemd/system-preset/20-docker.preset` — Enable docker.socket + containerd (numbered below 30 so it beats the base image's `30-docker.preset` disable; presets are first-match-wins in lexical order)
- `usr/lib/systemd/system/multi-user.target.d/10-docker.conf` — `Upholds=docker.socket containerd.service` drop-in for reliable boot activation (the socket, not docker.service — dockerd runs `-H fd://` and fails without socket-passed FDs)
- `mkosi.finalize` — Captures `/etc/default/docker`, `/etc/docker`, `/etc/containerd` to factory defaults
- `usr/lib/sysusers.d/docker.conf` — Docker user/group definitions
- `usr/lib/tmpfiles.d/docker.conf` — Factory config injection

### himmelblau
- `mkosi.postinst.chroot` — Post-install customization hook (currently minimal)
- `mkosi.finalize` — Captures `/etc/himmelblau` to `/usr/share/factory/etc/` for tmpfiles injection at boot
- `usr/lib/himmelblau/himmelblau-sysext-setup` — Runtime PAM/NSS injection script (idempotent, runs at boot): adds `himmelblau` to nsswitch.conf passwd/group/shadow, runs `pam-auth-update --enable himmelblau`
- `usr/lib/systemd/system/himmelblau-sysext-setup.service` — Oneshot service to run setup script (conditioned on `/run/himmelblau-sysext-setup.done`)
- `usr/lib/systemd/system-preset/40-himmelblau.preset` — Enable himmelblaud and himmelblau-sysext-setup services
- `usr/lib/systemd/system/multi-user.target.d/10-himmelblau.conf` — `Upholds=` drop-in for reliable boot activation (himmelblaud upholds himmelblaud-tasks itself)
- `usr/lib/tmpfiles.d/himmelblau.conf` — Config injection from `/usr/share/factory/etc/`

### incus
- `mkosi.finalize` — Captures the tmpfiles-referenced `/etc` paths to factory defaults
- `usr/lib/systemd/system-preset/40-incus.preset` — Enable incus services
- `usr/lib/systemd/system/multi-user.target.d/10-incus.conf` — `Upholds=` drop-in for reliable boot activation (sockets + lxcfs + startup + sysext-setup; incus.service itself is socket-activated)
- `usr/lib/systemd/system/incus-sysext-setup.service` — Oneshot post-merge setup (subuid/subgid)
- `usr/lib/incus/incus-sysext-setup` — The setup script the service runs
- `usr/lib/sysusers.d/{dnsmasq,rdma}.conf` — User/group definitions
- `usr/lib/tmpfiles.d/incus.conf` — Factory config injection + runtime dirs + xz alternatives links

### nix
- `mkosi.finalize` — Captures `/etc/nix` to factory defaults
- `usr/lib/systemd/system/nix.mount` + `nix-daemon.service.d/mount-binding.conf` — `/nix` bind mount wiring
- `usr/lib/systemd/system-preset/40-nix.preset` — Enable nix.mount + nix-daemon
- `usr/lib/systemd/system/multi-user.target.d/10-nix.conf` — `Upholds=nix.mount nix-daemon.socket nix-daemon.service` drop-in for reliable boot activation
- `usr/lib/sysusers.d/nix.conf` — Nix user/group
- `usr/lib/tmpfiles.d/nix.conf` — `/nix` hierarchy + factory config injection

### tailscale
- `mkosi.finalize` — Captures `/etc/default/tailscaled` to factory defaults (tailscaled requires the EnvironmentFile)
- `usr/lib/systemd/system-preset/40-tailscale.preset` — Enable tailscaled
- `usr/lib/systemd/system/multi-user.target.d/10-tailscale.conf` — `Upholds=tailscaled.service` drop-in for reliable boot activation
- `usr/lib/tmpfiles.d/tailscale.conf` — Factory config injection

## Version Extraction and Naming

The shared postoutput script (`shared/sysext/postoutput/sysext-postoutput.sh`) handles versioning:

1. Reads `KEYPACKAGE` from environment
2. Queries the manifest JSON for the key package's version
3. Handles Debian epoch notation: `5:1.2.3` → `5+1.2.3`
4. Maps Debian release to VERSION_ID: forky → 14, trixie → 13, bookworm → 12, bullseye → 11, buster → 10
5. Renames the output image: `{IMAGE_ID}_{KEYVERSION}_{OS_VERSION}_{ARCH}.{ext}` (ext may be `raw`, `raw.gz`, `raw.xz`, etc.)
   - Example: `docker_5+29.3.0_13_x86-64.raw`
6. Annotates manifest with `.config.key_package` and `.config.key_version`
7. Creates unversioned symlink for systemd-sysupdate MatchPattern

## Sysupdate Registration

Each sysext distributed to users needs two files in the base image at `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/`:

> Note: `emdash.transfer`/`emdash.feature` are also registered here even though
> the emdash sysext is built and published from a separate repository — every
> sysext distributed via repository.frostyard.org needs its sysupdate wiring in
> the base image regardless of where it is built.

### Transfer file (`<name>.transfer`)

Defines how systemd-sysupdate downloads the sysext:

```ini
[Transfer]
Features=<name>
Verify=false

[Source]
Type=url-file
Path=https://repository.frostyard.org/ext/<name>/
MatchPattern=<name>_@v_%w_%a.raw.zst \
             <name>_@v_%w_%a.raw.xz \
             <name>_@v_%w_%a.raw.gz \
             <name>_@v_%w_%a.raw

[Target]
Type=regular-file
Path=/var/lib/extensions.d/
MatchPattern=<name>_@v_%w_%a.raw.zst \
             <name>_@v_%w_%a.raw.xz \
             <name>_@v_%w_%a.raw.gz \
             <name>_@v_%w_%a.raw
CurrentSymlink=<name>.raw
```

### Feature file (`<name>.feature`)

Provides metadata and defaults:

```ini
[Feature]
Description=<description>
Documentation=<url>
Enabled=false
```

All sysexts default to `Enabled=false` — users opt in via systemd-sysupdate configuration. The base also registers `emdash.transfer` and `emdash.feature` for a sysext built in another repository, so do not infer the root `mkosi.conf` dependency list from the sysupdate directory alone.

## Service Activation Pattern (Upholds=)

**Do not rely on `WantedBy=multi-user.target` + preset alone for sysext-provided services.** This combination breaks at boot because:

1. PID 1 scans unit files before the sysext is merged — `tailscaled.service` doesn't exist yet
2. The `/etc/systemd/system/multi-user.target.wants/` symlink points to a missing file and is silently dropped
3. After `reload-sysext.service` merges the overlay and runs `daemon-reload`, the previously-dropped `Wants=` is not re-triggered

**Required pattern:** Ship a `multi-user.target.d/10-<name>.conf` drop-in **inside the sysext** with:

```ini
[Unit]
Upholds=<name>.service
```

This drop-in is brand-new to systemd after the post-merge `daemon-reload`, so it is processed cleanly when `multi-user.target` activates. `Upholds=` also provides crash-restart behavior — if the service dies, systemd will restart it.

Example path inside the sysext: `usr/lib/systemd/system/multi-user.target.d/10-tailscale.conf`

The preset (`40-<name>.preset`) is still required to set the enabled state; the drop-in handles the activation timing.

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
4. If configs needed in `/etc`: create `mkosi.finalize` to capture ONLY the needed paths to `/usr/share/factory/etc/` (never all of `/etc` — see Constraints), add tmpfiles.d rules
5. Create `<name>.transfer` and `<name>.feature` in `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/`
6. **If the sysext ships a systemd service:** add `usr/lib/systemd/system/multi-user.target.d/10-<name>.conf` with `Upholds=<name>.service` (see [Service Activation Pattern](#service-activation-pattern-upholds) above)
7. Add the sysext name to root `mkosi.conf` Dependencies list
8. Add a corresponding update check to `.github/workflows/check-dependencies.yml` if it has external downloads

For runtime setup scripts and units shipped inside `mkosi.extra/`, do not call `systemctl enable`, `systemctl disable`, `systemctl preset`, or remove shipped paths under `/etc` from the running guest. These mutate the live `/etc` overlay and can break bootc's `/etc` merge when a staged deployment finalizes. Express service state through presets/drop-ins at build time, and use `/var` marker files for run-once behavior.
