# CI/CD Pipeline

## Workflows

### build.yml — Sysext Build and Publish

**Trigger:** Push/PR to main, manual dispatch

Builds the base image and all 10 sysexts, publishes to the Frostyard repository on Cloudflare R2.

**Steps:**
1. Aggressive cleanup of runner (removes JDK, .NET, Android SDK, etc. to free disk space)
2. Run `check-duplicate-packages.sh` to validate no duplicate packages across configs
3. Build base + all sysext images via mkosi
4. Run `sysextmv.sh` and `manifestmv.sh` to organize output into `output/sysexts/` and `output/manifests/`
5. Upload sysext artifacts to Frostyard R2 repository via `frostyard/repogen` action
6. Upload manifest files to R2
7. Uses concurrent workflow cancellation (newer pushes cancel in-progress builds)

### build-images.yml — Desktop/Server Image Build and Publish

**Trigger:** Push/PR to main, manual dispatch

Matrix build of all 6 profiles (snow, snowloaded, snowfield, snowfieldloaded, cayo, cayoloaded).

**Steps:**
1. Build profile image via mkosi (produces directory output)
2. Package OCI image via `buildah-package.sh` (preserves SUID, xattrs)
3. Optimize layers via `chunkah-package.sh`
4. **Smoke test:** Validates SUID bit on `/usr/bin/sudo` (mode 4755) — catches metadata loss
5. Generate SBOM via Syft (scans mkosi output directory, syft-json format)
6. Push to ghcr.io with `latest` tag
7. Attach SBOM to image via ORAS (`application/vnd.syft+json` artifact type)
8. Sign SBOM artifact with Cosign
9. Attest build provenance (GitHub Actions attestation)
10. Sign image with Cosign
11. Upload manifests to R2

#### release job — Automated GitHub Releases

After the matrix completes, a self-contained `release` job runs on main-branch pushes only and creates a GitHub Release summarising what changed in the build. The job has `continue-on-error: true` at the job level, so any failure produces a warning annotation without turning the workflow red. The `build` job is untouched by this feature.

**Resolution:** The release job installs ORAS, logs into GHCR, then queries `oras repo tags ghcr.io/<owner>/snowloaded` to list all tags. It filters for the `YYYYMMDDhhmmss` timestamp format, sorts descending, and picks the newest tag as `current` (the image this run just pushed) and the second-newest as `previous` (the prior build). It then runs `frostyard/changelog-generator` with those two exact tags to produce the diff. Only `snowloaded` is diffed; the other five profiles build and push unchanged and are not referenced in the release.

**Release tag scheme:** `YYYY-MM-DD.N` (daily counter, e.g. `2026-04-09.1`). The release title is `Build YYYY-MM-DD HH:MM:SS UTC`. The body is a short header line ("Based on the `snowloaded` image."), a `podman pull ghcr.io/<owner>/snowloaded:latest` command in a fenced code block, and then the generated changelog.

**Skip paths:** If the `snowloaded` repository has zero or one timestamped tags (bootstrap edge case, not applicable in practice — the repository already has many historical tags), the resolve step writes `skip=true` and all downstream steps gracefully short-circuit with a `::warning::` annotation.

### check-dependencies.yml — External Download Updates

**Trigger:** Weekly (Monday 9am UTC), manual dispatch

Checks for updates to resources managed by the verified download system:

- Bitwarden desktop .deb
- Homebrew install script
- Emdash .deb
- Surface secure boot certificate
- Hotedge GNOME extension
- Logomenu GNOME extension
- Microsoft Azure VPN Client

**Process:**
1. Downloads each resource from its upstream URL
2. Computes SHA256 checksum
3. Compares against `shared/download/checksums.json`
4. If changed: updates checksums.json, creates PR

### check-packages.yml — APT Package Version Updates

**Trigger:** Daily (8am UTC)

Checks for version updates to external APT packages:

- himmelblau
- microsoft-edge-stable
- code (VS Code)
- docker-ce
- 1password-cli

**Process:**
1. Queries APT repositories for current versions
2. Compares against `shared/download/package-versions.json`
3. If changed: updates package-versions.json, creates PR

### validate.yml — Code Validation

**Trigger:** PR/push to main

Two validation checks:
1. **Shell linting:** Runs shellcheck on all `*.sh` and `*.chroot` files
2. **mkosi validation:** Runs `mkosi summary` for base image and all profiles to verify configuration

### test-install.yml — Bootc Installation Test

**Trigger:** Manual workflow dispatch only

Tests full bootc installation and boot cycle:
1. Frees disk space on runner (removes large toolchains)
2. Enables KVM on GitHub Actions runner
3. Installs QEMU, OVMF, podman, skopeo
4. Pulls specified OCI image from ghcr.io
5. Runs `test/bootc-install-test.sh` — installs to virtual disk, boots in QEMU, runs test suite via SSH

### scorecard.yml — Supply-Chain Security

**Trigger:** Weekly (Monday 12:17 UTC)

Runs OpenSSF Scorecard analysis for supply-chain security assessment. Publishes results to GitHub code scanning dashboard.

## Security Practices

- **Action pinning:** Most GitHub Actions pinned to specific commit SHAs (not tags) for supply-chain safety
- **SBOM generation:** Syft generates SBOMs for all OCI images, attached as OCI referrers via ORAS
- **Image signing:** OCI images and SBOM artifacts signed with Cosign after push
- **Build attestation:** GitHub Actions provenance attestation on image builds
- **Checksum verification:** All external downloads verified against pinned SHA256 hashes
- **Automated updates:** Dependency and package version checks create PRs for review (never auto-merge)

## Publishing Targets

| Artifact | Destination | Mechanism |
|----------|-------------|-----------|
| Sysexts (EROFS) | repository.frostyard.org/ext/ | R2 upload via frostyard/repogen |
| Desktop/server OCI images | ghcr.io/frostyard/ | buildah push + cosign sign + SBOM via ORAS |
| Manifests | R2 manifests bucket | Direct upload |
