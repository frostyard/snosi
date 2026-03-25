# CI/CD Pipeline

## Workflows

### build.yml — Sysext Build and Publish

**Trigger:** Push/PR to main

Builds the base image and all 9 sysexts, publishes to the Frostyard repository on Cloudflare R2.

**Steps:**
1. Build base + all sysext images via mkosi
2. Upload sysext artifacts to Frostyard R2 repository via `frostyard/repogen` action
3. Upload manifest files to R2
4. Uses concurrent workflow cancellation (newer pushes cancel in-progress builds)

### build-images.yml — Desktop/Server Image Build and Publish

**Trigger:** Push/PR to main, manual dispatch

Matrix build of all 6 profiles (snow, snowloaded, snowfield, snowfieldloaded, cayo, cayoloaded).

**Steps:**
1. Build profile image via mkosi (produces directory output)
2. Package OCI image via `buildah-package.sh` (preserves SUID, xattrs)
3. Optimize layers via `chunkah-package.sh`
4. **Smoke test:** Validates SUID bit on `/usr/bin/sudo` (mode 4755) — catches metadata loss
5. Push to ghcr.io with `latest` tag
6. Attest build provenance (GitHub Actions attestation)
7. Sign image with Cosign
8. Upload manifests to R2

### check-dependencies.yml — External Download Updates

**Trigger:** Weekly (Monday 9am UTC), manual dispatch

Checks for updates to resources managed by the verified download system:

- Bitwarden desktop .deb
- Homebrew install script
- Emdash .deb
- Surface secure boot certificate

**Process:**
1. Downloads each resource from its upstream URL
2. Computes SHA256 checksum
3. Compares against `shared/download/checksums.json`
4. If changed: updates checksums.json, creates PR

### check-packages.yml — APT Package Version Updates

**Trigger:** Daily (8am UTC)

Checks for version updates to external APT packages:

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
- **Image signing:** OCI images signed with Cosign after push
- **Build attestation:** GitHub Actions provenance attestation on image builds
- **Checksum verification:** All external downloads verified against pinned SHA256 hashes
- **Automated updates:** Dependency and package version checks create PRs for review (never auto-merge)

## Publishing Targets

| Artifact | Destination | Mechanism |
|----------|-------------|-----------|
| Sysexts (EROFS) | repository.frostyard.org/ext/ | R2 upload via frostyard/repogen |
| Desktop/server OCI images | ghcr.io/frostyard/ | buildah push + cosign sign |
| Manifests | R2 manifests bucket | Direct upload |
