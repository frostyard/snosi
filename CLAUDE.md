# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

snosi is a bootable container image build system using [mkosi](https://github.com/systemd/mkosi) to produce Debian Trixie-based immutable OS images and system extensions (sysexts). Images are deployed via bootc/systemd-boot with atomic updates.

**Outputs:** 4 OCI desktop images (snow, snowloaded, snowfield, snowfieldloaded), 2 OCI server images (cayo, cayoloaded), and 10 sysext overlay images (1password-cli, code-server, debdev, dev, docker, himmelblau, incus, nix, podman, tailscale).

## Build Commands

Requires: just, git, python3, root/sudo access. mkosi itself is auto-bootstrapped: the Justfile fetches systemd/mkosi into a repo-local, gitignored `.mkosi/` checkout at the exact commit pinned by the `systemd/mkosi@<sha>` action in `.github/workflows/build.yml` (read at runtime — no drift between local and CI), and runs `.mkosi/bin/mkosi` from there. Delete `.mkosi/` to discard it; override with `just mkosi=/usr/bin/mkosi <target>` to use a system install.

```bash
just                    # List targets
just sysexts            # Build base + all 10 sysexts
just snow               # Build snow desktop image
just snowloaded         # Build snowloaded variant
just snowfield          # Build snowfield (Surface kernel)
just snowfieldloaded    # Build snowfieldloaded variant
just cayo               # Build cayo server image
just cayoloaded         # Build cayoloaded variant
just clean              # Remove build artifacts
just test-install       # Run bootc install test
just run-qemu           # Run image in QEMU
```

All `just` targets run `mkosi clean` first (clean build every time).

## Architecture

### Configuration Composition

mkosi configs use `Include=` directives to compose reusable fragments. The composition chain:

- `mkosi.conf` (root) declares base + sysext dependencies
- `mkosi.images/` contains base image and sysext definitions
- `mkosi.profiles/` defines desktop and server image variants
- `shared/` contains reusable fragments: kernel configs, package sets, output format, scripts

Each profile composes: package sets + kernel variant + output format + build/postinstall/finalize/postoutput scripts.

Root `mkosi.conf` depends on `base` plus all sysexts so `mkosi build`/`just sysexts` produces the sysext publishing set. Profile configs must start with an empty `Dependencies=` assignment followed by `Dependencies=base`; mkosi appends collection settings, so the empty assignment is required to avoid rebuilding every sysext for each profile image build.

### Script Pipeline (per image)

Scripts execute in order: **BuildScripts** (in chroot) -> **PostInstallationScripts** (after packages) -> **FinalizeScripts** (pre-output) -> **PostOutputScripts** (after image creation).

### Immutable Filesystem Constraints

- `/usr/` - Read-only. All binaries and libraries must live here.
- `/etc/` - Overlay on `/usr/etc`. Base configs in image, user changes persist.
- `/var/` - Persistent, writable. State, logs, container storage.
- `/opt/` - Bind mount to `/var/opt`. Writable at runtime but **shadowed by sysext overlays**.

**Critical pattern:** Packages installing to `/opt` must be relocated to `/usr/lib/<package>` at build time with symlinks in `/usr/bin`. This applies to both desktop images and sysexts.

**First-boot semantics:** the image ships `/etc/machine-id` as an empty file, which systemd treats as "initialize a machine ID, but not first boot" — `ConditionFirstBoot=yes` never fires on installed systems (only a missing machine-id or one containing `uninitialized` triggers it). Any unit that must run once on a fresh install needs a different condition (e.g. `ConditionPathExists=!<marker>`); see the `sshd-keygen.service.d` drop-in in base `mkosi.extra`, which regenerates SSH host keys whenever they are missing. When writing such a drop-in, remember an empty `Condition*=` assignment resets ALL conditions on the unit, so restate the stock unit's other conditions.

### Base Image: In-Tree bootc + ostree Build

bootc and ostree are **not** installed from APT; they are compiled from pinned source during the base image build.

- **Why:** `frostyard/bootc-debian` (the former private packaging repo) is archived. Debian Trixie ships no bootc package and only ostree 2025.2 (too old for current bootc).
- **Where:** `shared/bootc/build/bootc.chroot` runs as a mkosi `BuildScript` (wired via `BuildScripts=` in `mkosi.images/base/mkosi.conf`). (The image rootfs has no `apt` — mkosi manages packages externally — so build deps cannot be apt-installed from inside a postinstall chroot; a BuildScript with `BuildPackages=` is required.)
- **Versions:** Pinned in `shared/download/checksums.json` (keys `ostree`, `bootc`, `bootc-vendor`); tracked weekly by `check-dependencies.yml`.
- **Build deps:** declared in `BuildPackages=` in `mkosi.images/base/mkosi.conf`. mkosi installs them into the build overlay only; the overlay (and every build dep) is discarded after the build script, so they never ship in the image. There is no `apt` call and no purge logic in the script.
- **Rust toolchain:** Debian's `rustc` (1.85) is too old to *build* bootc 1.16.2 (its xtask/build deps need rustc ≥ 1.91). The script installs a pinned toolchain (`RUST_VERSION`) via `rustup` (from `BuildPackages=`) and runs `make` under `rustup run`.
- **ostree double-install:** the BuildScript runs `make install DESTDIR="$DESTDIR"` (ships in image) AND `make install DESTDIR=` (explicit empty — mkosi exports `DESTDIR` into the build env, so the empty value is needed to install into the overlay's real `/usr` so the bootc build finds `ostree-1.pc` and can run the bootc binary for docgen).
- **dpkg registration:** `shared/bootc/postinst/bootc-register.chroot` (a `PostInstallationScript`) builds metadata-only stub `.deb`s (versions from `checksums.json`) and `dpkg -i`s them, so `dpkg -l`/`apt list --installed` and dependency checks see `bootc` + `libostree-1-1` as installed. The files come from the BuildScript; dpkg does not own them.
- **Runtime libs:** bootc/ostree runtime dependencies (e.g. `libglib2.0-0t64`, `libcurl4t64`) are listed in base `Packages=` so they ship in the image and the compiled binaries link against them at runtime.

### Sysext Constraints

Sysexts can ONLY provide files under `/usr`. They cannot modify `/etc` or `/var` at runtime. Configs needed in `/etc` must be:

1. Captured to `/usr/share/factory/etc` during build (via `mkosi.finalize`) — capture ONLY the specific paths the sysext's tmpfiles rules reference, never all of `/etc` (the buildroot `/etc` is the merged base view; a full capture ships `/etc/shadow` and SSH host keys in the published sysext)
2. Injected at boot via systemd-tmpfiles

Every sysext must have matching `<name>.transfer` and `<name>.feature` files in `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/`. The `.transfer` file defines how systemd-sysupdate downloads the sysext; the `.feature` file provides metadata and defaults to `Enabled=false`. Use existing files as templates.

**Service activation in sysexts:** Do NOT rely on `WantedBy=multi-user.target` + preset alone. At boot, the sysext is not yet merged when PID 1 scans units — the `.wants/` symlink is dangling and silently dropped. Always ship a `usr/lib/systemd/system/multi-user.target.d/10-<name>.conf` drop-in inside the sysext with `[Unit]\nUpholds=<name>.service`. This drop-in is new to systemd after the post-merge daemon-reload, so activation fires correctly. The preset is still required for enabled state; the drop-in handles timing.

The shared sysext postoutput script (`shared/sysext/postoutput/sysext-postoutput.sh`) handles versioned naming and manifest processing. It requires the `KEYPACKAGE` env var set in each sysext's `mkosi.conf`.

## Key Directories

- `shared/download/` - Verified download system: `checksums.json` pins URLs+SHA256s, `verified-download.sh` provides the `verified_download()` helper
- `shared/bootc/` - In-tree source build of bootc (v1.16.2) and ostree (v2026.1); `build/bootc.chroot` is a base image **BuildScript** (wired via `BuildScripts=`); build deps come from `BuildPackages=` (overlay-only, discarded after build); compiles both tools (autotools for ostree, offline vendored cargo for bootc) and installs into `$DESTDIR`, which mkosi copies into the image
- `shared/kernel/` - Kernel configs (backports, surface, stock) and dracut scripts
- `shared/packages/` - Package set definitions, some with postinstall scripts for relocation
- `shared/outformat/image/` - Image output format config (directory), finalize scripts, `buildah-package.sh` (OCI packaging), and `chunkah-package.sh` (CI re-chunks the OCI image for efficient delta updates)
- `shared/sysext/postoutput/` - Shared sysext postoutput logic
- `mkosi.sandbox/etc/apt/` - External APT repo configs (Docker, Incus, linux-surface, Frostyard)

## Shell Script Conventions

- Use `set -euo pipefail` at the top of all scripts
- Build scripts running in chroot use `.chroot` extension
- External downloads must go through `verified_download()` with entries in `checksums.json`
- Pin external URLs to specific versions/commits, never `latest` or branch names
- When adding a new verified download, also add a corresponding update check to `.github/workflows/check-dependencies.yml`

## User Service Enablement in Chroot

`systemctl --user enable` does not work inside a mkosi chroot (no user session/D-Bus). System services are enabled via `systemctl enable` in `snow.postinst.chroot`, but user services require manually creating symlinks:

```bash
mkdir -p /etc/systemd/user/<target>.wants
ln -sf /usr/lib/systemd/user/<service> /etc/systemd/user/<target>.wants/<service>
```

The target (e.g. `gnome-session.target`) comes from the service's `WantedBy=` in its `[Install]` section.

**Known issue:** `deb-systemd-helper` creates `.dsh-also` tracking files in `/var/lib/systemd/deb-systemd-user-helper-enabled/` during the build but may not create the actual enablement symlinks in `/etc/systemd/user/`. If a user service isn't auto-starting after reboot, check whether its symlink is missing from `/etc/systemd/user/<target>.wants/` and compare against its `.dsh-also` file. A full sweep on 2026-07-01 found only two affected units, both resolved deliberately: `gnome-remote-desktop-headless` (removed — conflicts with the non-headless variant) and `rygel` (kept off — tracking removed in `snow.postinst.chroot`). Re-run the comparison when adding packages that ship user services.

## CI/CD

- `build.yml` - Builds base + sysexts, publishes to Frostyard repo (Cloudflare R2)
- `build-images.yml` - Matrix build of 6 profiles (4 desktop + 2 server), resetting mkosi dependencies to `base` so sysexts are not rebuilt per profile. Pushes OCI to ghcr.io, generates SBOMs (Syft), attaches via ORAS, signs with Cosign (public key committed at `cosign.pub`; `test-install.yml` verifies it before tests). A non-blocking `release` job runs after the matrix on main-branch pushes and creates a GitHub Release whose body is a changelog generated by `frostyard/changelog-generator` diffing the new `snowloaded` image against the previously published one.
- `check-dependencies.yml` - Weekly check for external dependency updates, creates PRs with updated checksums
- `check-packages.yml` - Daily check for APT package version updates, creates PRs
- `validate.yml` - shellcheck + mkosi summary validation on PRs
- `test-install.yml` - Manual bootc installation test in QEMU/KVM
- `scorecard.yml` - Weekly OpenSSF supply-chain security analysis
## Documentation

**update documentation** After any change to source code, update relevant documentation in CLAUDE.md, README.md and the yeti/ folder. A task is not complete without reviewing and updating relevant documentation.

**yeti/ directory** The `yeti/` directory contains documentation written for AI consumption and context enhancement, not primarily for humans. Jobs like `doc-maintainer` and `issue-worker` instruct the AI to read `yeti/OVERVIEW.md` and related files for codebase context before performing tasks. Write content in this directory to be maximally useful to an AI agent understanding the codebase — detailed architecture, patterns, and decision rationale rather than user-facing guides.
