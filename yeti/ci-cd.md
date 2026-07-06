# CI/CD Pipeline

## Workflows

### build.yml — Sysext Build and Publish

**Trigger:** Push/PR to main, manual dispatch

Builds the base image and all 10 sysexts, publishes to the Frostyard repository on Cloudflare R2.

**Steps:**
1. Aggressive cleanup of runner (removes JDK, .NET, Android SDK, etc. to free disk space)
2. Redirect `TMPDIR` to `/mnt/tmp`; mkosi workspaces can otherwise overflow the hosted runner root volume
3. Run `check-duplicate-packages.sh` to validate no duplicate packages across configs
4. Build base + all sysext images via mkosi
5. Run `sysextmv.sh` and `manifestmv.sh` to organize output into `output/sysexts/` and `output/manifests/`
6. Upload sysext artifacts to Frostyard R2 repository via `frostyard/repogen` action
7. Upload manifest files to R2
8. Uses concurrent workflow cancellation (newer pushes cancel in-progress builds)

### build-images.yml — Desktop/Server Image Build and Publish

**Trigger:** repository_dispatch type `build`, push/PR to main, manual dispatch

Matrix build of all 6 profiles (snow, snowloaded, snowfield, snowfieldloaded, cayo, cayoloaded).

Each matrix build resets mkosi dependencies to `base` (`--dependency= --dependency=base`). This prevents the root sysext dependency list from being appended into every profile build. The sysext publishing set is built once by `build.yml`; profile image jobs build only `base` plus the selected main image.

**Steps:**
1. Free runner disk, mount BTRFS for container storage, and redirect `TMPDIR` to `/mnt/tmp`
2. Run `check-duplicate-packages.sh`
3. Build profile image via mkosi with dependencies reset to `base` only (produces directory output)
4. Package OCI image via `buildah-package.sh` (preserves SUID, xattrs)
5. Optimize layers via `chunkah-package.sh` (skipped on pull_request)
6. **Smoke test:** Validates SUID bit on `/usr/bin/sudo` (mode 4755) — catches metadata loss
7. Generate SBOM via Syft (scans mkosi output directory, syft-json format; skipped on pull_request)
8. Push timestamp and `latest` tags to ghcr.io (skipped on pull_request)
9. Attach SBOM to image via ORAS (`application/vnd.syft+json` artifact type)
10. Sign SBOM artifact with Cosign
11. Attest build provenance (GitHub Actions attestation)
12. Sign image with Cosign
13. Upload manifests to R2

#### release job — Automated GitHub Releases

After the matrix completes, a self-contained `release` job runs on main-branch pushes only and creates a GitHub Release summarising what changed in the build. It uses `!cancelled()` so it can still run after a matrix leg fails, but only proceeds when the `snowloaded` leg uploaded its tag artifact. Release failures are visible; the job is not `continue-on-error`.

**Resolution:** The `snowloaded` matrix leg writes the just-pushed timestamp tag to a short-lived artifact. The release job reads that as `current`, then prefers the previous tag recorded in the latest GitHub Release body (`<!-- snowloaded-tag: ... -->`). If no release marker exists, it falls back to `oras repo tags ghcr.io/<owner>/snowloaded` and selects the newest other timestamp tag. It then runs `frostyard/changelog-generator` with those two exact tags to produce the diff. Only `snowloaded` is diffed; the other five profiles build and push unchanged and are not referenced in the release.

**Release tag scheme:** `YYYY-MM-DD.N` (daily counter, e.g. `2026-04-09.1`). The release title is `Build YYYY-MM-DD HH:MM:SS UTC`. The body comes from the generated changelog plus the hidden `snowloaded-tag` marker used by future releases.

**Skip paths:** Missing/invalid snowloaded artifact, no previous tag, or `previous == current` all emit warnings and skip release creation.

### check-dependencies.yml — External Download Updates

**Trigger:** Weekly (Monday 9am UTC), manual dispatch

Checks for updates to resources managed by the verified download system:

- Bitwarden desktop .deb
- Homebrew install script
- code-server .deb
- ostree source tarball
- bootc + bootc-vendor source tarballs (bumped together; re-check RUST_VERSION on bootc bumps)
- Surface secure boot certificate
- Hotedge GNOME extension
- Logomenu GNOME extension
- Bazaar Companion GNOME extension
- Microsoft Azure VPN Client
- Microsoft Edge Stable .deb

**Process:**
1. Downloads each resource from its upstream URL
2. Computes SHA256 checksum
3. Compares against `shared/download/checksums.json`
4. If changed: updates checksums.json, creates PR

### check-packages.yml — APT Package Version Updates

**Trigger:** Daily (8am UTC)

Checks for version updates to external APT packages:

- himmelblau
- code (VS Code)
- docker-ce
- 1password-cli

**Process:**
1. Queries APT repositories for current versions
2. Compares against `shared/download/package-versions.json`
3. If changed: updates package-versions.json, creates PR

### validate.yml — Code Validation

**Trigger:** PR/push to main, manual dispatch

Three validation checks:
1. **Shell linting:** Runs shellcheck on tracked `*.sh`/`*.chroot` files and extensionless tracked shell scripts discovered by shebang, excluding `saved-unused/`
2. **Runtime /etc guard:** Runs `check-runtime-etc-guard.sh` — scans every tracked file in image payload dirs (`mkosi.extra/`, `shared/*/tree/`) for patterns that delete paths from `/etc` at runtime: `systemctl disable/enable/revert/unmask/preset` (and `deb-systemd-helper`) in units/scripts, `rm`/`mv`/`find -delete` targeting `/etc/`, and tmpfiles.d removal types (`r`/`R`/`D`) on `/etc`. Any such deletion on a bootc/composefs install breaks the `/etc` merge in `bootc-finalize-staged` at shutdown ("a path led outside of the filesystem", bootc ≤ 1.16.3) and the staged update is silently discarded — the host keeps booting the old image while the updater logs success (root-caused 2026-07-05 on `enable-incus-agent.service`, which self-disabled via `ExecStartPost`). Run-once units must gate on a `/var` marker instead (`ConditionPathExists=!/var/lib/<unit>.done` + `ExecStartPost=touch`). Escape hatch for provably safe lines: `# etc-guard-allow: <reason>` comment on the same line or the line directly above (unit files have no trailing comments). Build-time scripts (`*.chroot`, `mkosi.postinst`, etc.) are outside payload dirs and intentionally unscanned — build-time `systemctl enable` is correct
3. **mkosi validation:** Runs `mkosi summary` for root config and all profiles to verify configuration, plus `check-profile-dependencies.sh` to ensure profile builds do not include sysext images

### test-install.yml — Bootc Installation Test

**Trigger:** Manual workflow dispatch only

Tests full bootc installation and boot cycle:
1. Frees disk space on runner (removes large toolchains)
2. Enables KVM on GitHub Actions runner
3. Installs QEMU, OVMF, podman, skopeo
4. Resolves the requested mutable tag to a digest, verifies that immutable ref with `cosign verify --key cosign.pub`, then pulls the verified ref (into root's podman storage)
5. Runs `sudo test/bootc-install-test.sh` — installs to virtual disk, boots in QEMU, runs test suite via SSH. Root is required: `bootc install` refuses to run under rootless podman (`/proc/1 is owned by 65534`); this was why every run of this workflow failed before 2026-07

### scorecard.yml — Supply-Chain Security

**Trigger:** Weekly (Monday 12:17 UTC)

Runs OpenSSF Scorecard analysis for supply-chain security assessment. Publishes results to GitHub code scanning dashboard.

## Security Practices

- **Action pinning:** Most GitHub Actions pinned to specific commit SHAs (not tags) for supply-chain safety
- **SBOM generation:** Syft generates SBOMs for all OCI images, attached as OCI referrers via ORAS
- **Image signing:** OCI images and SBOM artifacts signed with Cosign after push. The public key is committed at repo root as `cosign.pub` (same keypair across frostyard repos); `test-install.yml` runs `cosign verify --key cosign.pub` before installation tests. cosign v2.6.x is the tested verifier — v3 currently fails key verification when GitHub provenance attestations are attached
- **Build attestation:** GitHub Actions provenance attestation on image builds
- **Checksum verification:** All external downloads verified against pinned SHA256 hashes
- **Automated updates:** Dependency and package version checks create PRs for review (never auto-merge)

## Publishing Targets

| Artifact | Destination | Mechanism |
|----------|-------------|-----------|
| Sysexts (EROFS) | repository.frostyard.org/ext/ | R2 upload via frostyard/repogen |
| Desktop/server OCI images | ghcr.io/frostyard/ | buildah push + cosign sign + SBOM via ORAS |
| Manifests | R2 manifests bucket | Direct upload |
