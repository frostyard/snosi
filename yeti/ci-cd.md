# CI/CD Pipeline

## Workflows

### build.yml — Sysext Build and Publish

**Trigger:** Push/PR to main, manual dispatch. Push/PR events ignore
`shared/download/image-checksums.json` when that is the only changed path;
image-only direct-download updates should rebuild OCI profiles instead.

Builds the base image and all 13 sysexts, publishes to the Frostyard repository on Cloudflare R2.

**Steps:**
1. Aggressive cleanup of runner (removes JDK, .NET, Android SDK, etc. to free disk space)
2. Redirect `TMPDIR` to `/mnt/tmp`; mkosi workspaces can otherwise overflow the hosted runner root volume
3. Run `check-duplicate-packages.sh` to validate no duplicate packages across configs
4. Build base + all sysext images via mkosi
5. Run `sysextmv.sh` and `manifestmv.sh` to organize output into `output/sysexts/` and `output/manifests/`
6. Upload sysext artifacts to Frostyard R2 repository via `frostyard/repogen` action
7. Upload manifest files to R2
8. Uses concurrent workflow cancellation (newer pushes cancel in-progress builds)

The publish step uses `skip-duplicates: true`: a sysext raw whose versioned
filename already exists in R2 is not re-uploaded. Since the filename version
comes from the KEYPACKAGE deb version, sysext tree fixes do NOT republish on
their own — set `SYSEXT_REVISION` in the sysext's mkosi.conf to append `+rN`
and force a new filename (see yeti/sysexts.md). Each sysext build also runs
`shared/sysext/finalize/sysext-required-paths.sh`, failing the build if any
path in the image's `required-paths.txt` is missing from the buildroot.

### build-images.yml — Desktop/Server Image Build and Publish

**Trigger:** repository_dispatch type `build`, push/PR to main, manual dispatch.
Push/PR events ignore sysext-only dependency metadata
(`shared/download/sysext-checksums.json`,
`shared/download/package-versions.json`, `latest-versions.txt`) when those are
the only changed paths.

Matrix build of all 3 profiles (snow, snowfield, cayo).

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

After the matrix completes, a self-contained `release` job runs on main-branch pushes only and creates a GitHub Release summarising what changed in the build. It uses `!cancelled()` so it can still run after a matrix leg fails, but only proceeds when the `snow` leg uploaded its tag artifact. Release failures are visible; the job is not `continue-on-error`.

**Resolution:** The `snow` matrix leg writes the just-pushed timestamp tag to a short-lived artifact. The release job reads that as `current`, then prefers the previous tag recorded in the latest GitHub Release body (`<!-- snow-tag: ... -->`). If no release marker exists, it falls back to `oras repo tags ghcr.io/<owner>/snow` and selects the newest other timestamp tag. It then runs `frostyard/changelog-generator` with those two exact tags to produce the diff. Only `snow` is diffed; the other profiles build and push unchanged and are not referenced in the release.

**Release tag scheme:** `YYYY-MM-DD.N` (daily counter, e.g. `2026-04-09.1`). The release title is `Build YYYY-MM-DD HH:MM:SS UTC`. The body comes from the generated changelog plus the hidden `snow-tag` marker used by future releases.

**Skip paths:** Missing/invalid snow artifact, no previous tag, or `previous == current` all emit warnings and skip release creation.

### check-dependencies.yml — Direct Download Updates

**Trigger:** Weekly (Monday 9am UTC), manual dispatch

Checks for updates to resources managed by the verified download system. The
workflow has two independent jobs so update PRs touch only the metadata file
for the build artifact that must be rebuilt.

**Sysext dependency job (`shared/download/sysext-checksums.json`):**
- 1Password desktop .deb (stable apt channel metadata, installed as a pinned
  .deb because the deb postinst needs network the buildroot lacks)
- Bitwarden desktop .deb
- code-server .deb
- coder .deb — deliberately tracks coder's **stable** channel (GitHub
  "latest"); mainline releases carry higher version numbers but are not
  followed
- Microsoft Azure VPN Client
- Microsoft Edge Stable .deb

Version-based checks only propose an update when the candidate sorts
**strictly newer** (`sort -V`) than the pinned version — a plain `!=`
comparison once let coder's stable/mainline channel split generate a
downgrade PR (2.35.1 -> 2.34.5, 2026-07-09). A pin ahead of the tracked
channel therefore stays put until the channel passes it.

Updates open `auto-update-sysext-checksums` PRs. Those PRs should trigger
`build.yml` and skip the OCI image matrix.

**OCI image dependency job (`shared/download/image-checksums.json`):**
- Homebrew install script
- Surface secure boot certificate
- Hotedge GNOME extension
- Logomenu GNOME extension
- Bazaar Companion GNOME extension

Updates open `auto-update-image-checksums` PRs. Those PRs should trigger
`build-images.yml` and skip the sysext publishing workflow.

**Process:**
1. Checks each upstream release/commit/package index
2. Downloads changed resources
3. Computes SHA256 checksums
4. Updates the target-specific checksum file and creates a PR

### check-packages.yml — Sysext APT Package Version Updates

**Trigger:** Daily (8am UTC)

Checks for version updates to external APT packages installed by sysext images:

- code (VS Code sysext)
- docker-ce
- 1password-cli

`shared/download/package-versions.json` is only a change-detection sentinel.
It does not pin installed package versions; mkosi resolves the package from APT
during the sysext build.

**Process:**
1. Queries APT repositories for current versions
2. Compares against `shared/download/package-versions.json`
3. If changed: updates `package-versions.json`, creates a sysext package-version PR

### validate.yml — Code Validation

**Trigger:** PR/push to main, manual dispatch

Three jobs:
1. **shell-lint:** Runs shellcheck on tracked `*.sh`/`*.chroot` files and extensionless tracked shell scripts discovered by shebang, excluding `saved-unused/`; then `test/native-ab-static-test.sh` (cheap native A/B configuration invariants — no root, no build); then `test/native-ab-contracts-test.sh` (validates `docs/native-ab-contracts.md`'s frozen naming/label/URL grammar against the actual tree and the `test/native-ab-contracts-allow.txt` deviation list); then `check-native-publication-guard.sh` (docs/native-ab-contracts.md §15 — hard-fails a `cayo-ab`/`snow-ab`/`snowfield-ab` profile missing shim/Secure Boot/PCR-signing/NvPCR/pubring markers or carrying a `KernelModules=` filter, and hard-fails `cayo-ab-raw` if it ever gains a publication marker; passes today by finding no production-named profile)
2. **runtime-etc-guard:** Runs `check-runtime-etc-guard.sh` — scans every tracked file in image payload dirs (`mkosi.extra/`, `shared/*/tree/`) for patterns that delete paths from `/etc` at runtime: `systemctl disable/enable/revert/unmask/preset` (and `deb-systemd-helper`) in units/scripts, `rm`/`mv`/`find -delete` targeting `/etc/`, and tmpfiles.d removal types (`r`/`R`/`D`) on `/etc`. Any such deletion on a bootc/composefs install breaks the `/etc` merge in `bootc-finalize-staged` at shutdown ("a path led outside of the filesystem", bootc ≤ 1.16.3) and the staged update is silently discarded — the host keeps booting the old image while the updater logs success (root-caused 2026-07-05 on `enable-incus-agent.service`, which self-disabled via `ExecStartPost`). Run-once units must gate on a `/var` marker instead (`ConditionPathExists=!/var/lib/<unit>.done` + `ExecStartPost=touch`). Escape hatch for provably safe lines: `# etc-guard-allow: <reason>` comment on the same line or the line directly above (unit files have no trailing comments). Build-time scripts (`*.chroot`, `mkosi.postinst`, etc.) are outside payload dirs and intentionally unscanned — build-time `systemctl enable` is correct
3. **mkosi-config-sanity:** Runs `mkosi summary` for root config and all profiles to verify configuration, plus `check-profile-dependencies.sh` to ensure profile builds do not include sysext images

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
- **Checksum verification:** Direct external downloads are verified against pinned SHA256 hashes in target-specific sysext/image metadata files
- **Automated updates:** Dependency and package version checks create target-specific PRs for review (never auto-merge)

## Publishing Targets

| Artifact | Destination | Mechanism |
|----------|-------------|-----------|
| Sysexts (EROFS) | repository.frostyard.org/ext/ | R2 upload via frostyard/repogen |
| Desktop/server OCI images | ghcr.io/frostyard/ | buildah push + cosign sign + SBOM via ORAS |
| Manifests | R2 manifests bucket | Direct upload |
