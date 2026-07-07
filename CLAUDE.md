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

**Runtime service enablement changes are forbidden:** units must never run `systemctl disable`/`enable` at runtime (e.g. via `ExecStartPost`) — it deletes/creates `.wants`/`.requires` symlinks in `/etc`, and any path removed from the live `/etc` relative to the booted image makes bootc's `/etc` merge fail at update finalize with "a path led outside of the filesystem" (bootc ≤ 1.16.3 follows the corresponding symlink in the new deployment's `/etc` out of its sandbox). The failure is silent from the user's perspective: `bootc-update-stage` keeps logging "staged" while every reboot discards the staged deployment and boots the old image (root-caused 2026-07-05 on `enable-incus-agent.service`). For run-once behavior, gate on a `/var` marker file instead (see `snow-linux-live-setup.service`). CI enforces this: `check-runtime-etc-guard.sh` (run by `validate.yml`) fails on runtime `systemctl disable/enable`, `/etc` deletions, and tmpfiles removal types on `/etc` in any shipped payload dir (`mkosi.extra/`, `shared/*/tree/`); escape hatch is a trailing `# etc-guard-allow: <reason>` comment.

**First-boot semantics:** the image ships `/etc/machine-id` containing the literal `uninitialized` (the machine-id(5) golden-image value), so the first boot of every install is a TRUE systemd first boot: `ConditionFirstBoot=yes` fires, PID 1 applies system unit presets, `preset-global.service` applies user-scope presets, and a unique machine ID is then generated and committed. (Before 2026-07 the image shipped an *empty* machine-id, which only means "generate an ID" and silently suppressed all first-boot semantics — the finalize comment claimed the opposite.) `systemd-firstboot.service` is preset-disabled so nothing prompts on the console; the installer and first-setup own locale/hostname/user. The `sshd-keygen.service.d` drop-in (path-gated on missing host keys) is kept because it also covers key deletion on existing installs.

**Enablement lives in presets, not shipped `/etc` symlinks:** the outformat finalize script strips ALL unit enablement symlinks (`.wants`/`.requires` entries and `[Install]` aliases, both system and user scope) from the image `/etc` after mkosi's build-time `preset-all` pass, recording them in `/usr/share/snosi/enablement-manifest.txt`. First boot recreates them from the same preset policy as *runtime-created* `/etc` state — so an admin's `systemctl disable` deletes a runtime-created path and no longer breaks bootc's `/etc` merge (see below). Masks (`/dev/null` symlinks) and linked units (e.g. the dracut service links) are kept: presets cannot recreate those. Consequences: (1) enablement changes belong in `usr/lib/systemd/system-preset/` / `user-preset/` files, never in postinst `systemctl enable` or manual symlinks — mkosi runs `preset-all` (and `--global preset-all`) AFTER postinst scripts, so manual symlink surgery there is silently overridden by the preset pass; (2) a NEW image's changed preset policy does not re-apply to existing installs (first boot has passed) — new-unit enablement on updates needs its own mechanism; (3) `test/tests/05-firstboot-presets.sh` verifies manifest parity on first boot.

### OS Update Staging (bootc)

On bootc-installed systems, updates are staged by `bootc-update-stage.timer` (hourly; base `mkosi.extra`): `/usr/libexec/bootc-update-stage` pulls the followed image via **podman**, then stages it with `bootc upgrade` when the spec already follows `containers-storage` (the steady state after the first staged update) or `bootc switch --transport containers-storage` otherwise — `bootc switch` to an IDENTICAL spec is a silent no-op in bootc ≤ 1.16.3 (composefs switch returns before staging when `new_spec == host.spec`), which made every install unable to take a second update while logging success (root-caused 2026-07-06). The script verifies post-stage that `.status.staged.image.imageDigest` equals the pulled digest and fails loudly otherwise. The update applies at the next natural reboot via `bootc-finalize-staged.service`. podman does the transfer because bootc's registry-transport composefs pull currently fails on snosi images (known upstream bug) — and podman enforces `containers-policy.json` at pull time. The script no-ops when: not a bootc-managed system (nbc installs — `spec.image` is null), already running or already staged the pulled digest, or the pulled digest equals the **rollback** deployment (never auto-flip-flop back to a version the admin rolled away from; bootc refuses that switch anyway). Upstream's `bootc-fetch-apply-updates.timer` is preset-disabled: it force-reboots on update and is gated on `/run/ostree-booted`, which does not exist on composefs deployments. During the transition, `nbc-update-download.timer` still ships for nbc-installed hosts. bootc-update-stage no-ops on nbc installs (`spec.image` null check); the nbc units are gated with `ConditionKernelCommandLine=!composefs` because `nbc update` itself ERRORS (exit 1, permanently failed unit, degraded state) rather than no-opping on bootc/composefs installs (frostyard/nbc#139).

### Base Image: bootc + ostree from Frostyard debs

bootc and ostree install as regular APT packages (`bootc`, `libostree-1-1` — the latter ships the library AND the ostree CLI) from the Frostyard repository, built and published by [frostyard/bootc-debian](https://github.com/frostyard/bootc-debian). Debian Trixie ships no bootc package and only ostree 2025.2 (too old for current bootc), hence the external packaging.

- **Versions:** pinned in bootc-debian's `download/checksums.json`, tracked weekly by that repo's own `check-dependencies.yml` — snosi's dependency check does NOT cover them. Deb versions carry a `-frostyard<timestamp>` suffix so rebuilds of the same upstream version still sort newer in apt.
- **Build parity:** bootc-debian's `build.sh` mirrors the former in-tree mkosi BuildScript (same pinned tarballs, same checksums, same pinned Rust toolchain — Debian's rustc 1.85 is too old to build bootc 1.16.x). Its Build workflow publishes the debs and then dispatches a snosi image build.
- **Runtime libs:** the debs declare only a partial `Depends` list; base `Packages=` keeps the full set of runtime link deps explicit (`libfuse3-4`, `libsoup-3.0-0`, `liblzma5`, etc.) — do not remove them just because apt doesn't demand them.
- **History:** until 2026-07 these were compiled from source during the base image build (`shared/bootc/build/bootc.chroot` + stub-deb dpkg registration); that machinery is gone.

### Sysext Constraints

Sysexts can ONLY provide files under `/usr`. They cannot modify `/etc` or `/var` at runtime. Configs needed in `/etc` must be:

1. Captured to `/usr/share/factory/etc` during build (via `mkosi.finalize`) — capture ONLY the specific paths the sysext's tmpfiles rules reference, never all of `/etc` (the buildroot `/etc` is the merged base view; a full capture ships `/etc/shadow` and SSH host keys in the published sysext)
2. Injected at boot via systemd-tmpfiles

Every sysext must have matching `<name>.transfer` and `<name>.feature` files in `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/`. The `.transfer` file defines how systemd-sysupdate downloads the sysext; the `.feature` file provides metadata and defaults to `Enabled=false`. Use existing files as templates.

**Service activation in sysexts:** Do NOT rely on `WantedBy=multi-user.target` + preset alone. At boot, the sysext is not yet merged when PID 1 scans units — the `.wants/` symlink is dangling and silently dropped. Always ship a `usr/lib/systemd/system/multi-user.target.d/10-<name>.conf` drop-in inside the sysext with `[Unit]\nUpholds=<name>.service`. This drop-in is new to systemd after the post-merge daemon-reload, so activation fires correctly. The preset is still required for enabled state; the drop-in handles timing.

The shared sysext postoutput script (`shared/sysext/postoutput/sysext-postoutput.sh`) handles versioned naming and manifest processing. It requires the `KEYPACKAGE` env var set in each sysext's `mkosi.conf`. If `SYSEXT_REVISION` is also set, the version gets a `+rN` suffix — bump this to force a republish of tree/content fixes when the KEYPACKAGE version hasn't changed (publishing skips existing filenames via `skip-duplicates`, so tree fixes otherwise never reach users; remove the setting when the package version bumps). Every sysext must also ship `mkosi.images/<name>/required-paths.txt` (one absolute path per line); the shared finalize check (`shared/sysext/finalize/sysext-required-paths.sh`) fails the build if any listed path is missing from the buildroot — guard against publishing structurally broken sysexts (the 2026-07-01 incus publish shipped with no incusd/CLI/units and nothing noticed). For `Overlay=yes` images the finalize `$BUILDROOT` is the sysext DELTA (upper layer), so list only paths the sysext itself ships — packages also present in the base image never appear in the delta and will always fail the check.

## Key Directories

- `shared/download/` - Verified download system: `checksums.json` pins URLs+SHA256s, `verified-download.sh` provides the `verified_download()` helper
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
- `validate.yml` - shellcheck + runtime-/etc-guard (`check-runtime-etc-guard.sh`) + mkosi summary validation on PRs
- `test-install.yml` - Manual bootc installation test in QEMU/KVM
- `scorecard.yml` - Weekly OpenSSF supply-chain security analysis
## Documentation

**update documentation** After any change to source code, update relevant documentation in CLAUDE.md, README.md and the yeti/ folder. A task is not complete without reviewing and updating relevant documentation.

**yeti/ directory** The `yeti/` directory contains documentation written for AI consumption and context enhancement, not primarily for humans. Jobs like `doc-maintainer` and `issue-worker` instruct the AI to read `yeti/OVERVIEW.md` and related files for codebase context before performing tasks. Write content in this directory to be maximally useful to an AI agent understanding the codebase — detailed architecture, patterns, and decision rationale rather than user-facing guides.
