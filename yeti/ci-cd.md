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

### build-native-images.yml — Native A/B Build and Publish (Phase 7)

**Trigger:** Push to `main`, manual dispatch. **ONLY** these two -- never
`pull_request`, never a fork-originated trigger, never
`repository_dispatch`. This is the interim protected-builder rule
(`docs/native-ab-publication.md` "Interim protected-builder constraints"):
the `build-*` jobs handle Secure Boot/MOK and PCR signing private keys, so
they must never run against untrusted code. A single `concurrency` group
(`build-native-images`, `cancel-in-progress: false`) prevents two runs from
interleaving `promote.sh` invocations against the same product's live
signed index.

A **thin caller**: every real step is a call into an in-repo script
(`shared/native-ab/publish/*.sh`, `shared/native-ab/ci/*.sh`,
`test/native-ab-secure-artifact-test.sh`, `test/snowfield-artifact-test.sh`)
that can be run and tested locally. See `docs/native-ab-publication.md`'s
"CI publication flow" section for the full narrative, secret inventory
table, and the "First production publication checklist" -- this section is
the mechanical job-by-job summary.

**Jobs:**
1. `pin-check` -- `shared/native-ab/ci/check-mkosi-pin.sh` (Mkosi Pin
   Governance, no build, no network)
2. `prepare` -- assigns one 14-digit version + records the source revision,
   shared by every product built this run (mirrors `build-images.yml`'s own
   version tag step)
3. `build-cayo` / `build-snow` / `build-snowfield` -- independent jobs
   (not a matrix), each gated on the `native-build` protected GitHub
   environment:
   - Free disk space, redirect `TMPDIR` to `/mnt/tmp` (mirrors
     `build-images.yml`'s CI-disk-exhaustion mitigation), bind-mount extra
     space over `/var/tmp` too (`shared/native-ab/publish/*.sh` hard-code
     `/var/tmp`, not `$TMPDIR`)
   - `shared/native-ab/ci/bootstrap-mkosi.sh .mkosi` then `check-mkosi-
     pin.sh .mkosi` (bootstraps at the exact commit `build.yml` pins;
     asserts it landed there)
   - Writes `NATIVE_SECURE_BOOT_KEY`/`_CERTIFICATE` and
     `NATIVE_PCR_SIGNING_KEY`/`_CERTIFICATE` environment secrets to
     `mkosi.key`/`mkosi.crt`/`.snosi-private/pcr-signing.{key,crt}`
     immediately before the one `mkosi build` step, `chmod 600`, never
     echoed
   - `mkosi --profile <profile> --dependency= --dependency=base
     --image-version <version> build`
   - Removes the key files (`if: always()`)
   - `test/native-ab-secure-artifact-test.sh` (all three products; single
     PCR signature mode); snowfield additionally runs
     `test/snowfield-artifact-test.sh` (needs `sudo`: loop-mounts the root
     erofs partition read-only)
   - `prepare-native-publication.sh --xz` then `publish-candidate.sh`
     against `rclone:r2:<NATIVE_R2_BUCKET>` (rclone configured via
     `RCLONE_CONFIG_R2_*` env vars from the `NATIVE_R2_*` secrets)
   - Uploads only `publication-info.json` + `SHA256SUMS` as a GitHub
     Actions artifact (`native-prepared-<product>`) -- never the
     multi-gigabyte payload objects, which are already durably in R2
4. `test-public-origin` -- one matrix job (`fail-fast: false`, legs
   `[cayo, snow, snowfield]`), no secrets needed (pure HTTP). Downloads its
   product's `native-prepared-<product>` artifact with
   `continue-on-error: true` and no-ops if absent (that product's build
   didn't finish), otherwise runs `verify-remote.sh` against the REAL
   public `https://repository.frostyard.org/os/native/v1/<product>/x86-64`
   URL and uploads a `native-verified-<product>` marker on success
5. `promote-cayo` / `promote-snow` / `promote-snowfield` -- independent
   jobs, each gated on the `native-promotion` protected GitHub environment
   (holds `NATIVE_UPDATE_SIGNING_KEY`, the OpenPGP update-signing private
   key). Downloads its own `native-verified-<product>` marker and
   `native-prepared-<product>` artifact (both `continue-on-error: true`);
   no-ops if either is missing. Otherwise writes the signing key to
   `/var/tmp/native-promote-secrets/os-update-signing.key`, runs
   `promote.sh --signing-key ...`, removes the key file (`if: always()`),
   and uploads a `native-promoted-<product>` marker on success
6. `release-notes` -- non-blocking, main-branch pushes only
   (`github.ref == 'refs/heads/main' && !cancelled()`). Downloads every
   `native-promoted-*` marker (`continue-on-error: true`); if none exist,
   skips. Otherwise composes a short release body (per-product R2 index/
   signature URLs) and runs `gh release create native-<version>`.

**Independence pattern:** every `test-public-origin` leg and every
`promote-*` job downloads its own upstream artifact with
`continue-on-error: true` and treats a missing artifact as "nothing to do
here" rather than a failure -- the same pattern `build-images.yml`'s own
`release` job already uses for its `snow-tag` artifact (`Download snow tag
artifact ... continue-on-error: true`). This is what makes one product's
build/verify/promote failure never block another product's promotion in
the same run.

**Secret inventory, protected environments, and the full "first production
publication" checklist:** see `docs/native-ab-publication.md`. Short
version: `native-build` holds the Secure Boot/MOK and PCR signing keys
(interim risk, accepted until mkosi supports split final assembly from
signing); `native-promotion` holds the OpenPGP update-signing key; R2
credentials (`NATIVE_R2_*`) are repository-level secrets, scoped to a
dedicated upload-only token, never the sysext/manifest token `build.yml`/
`build-images.yml` already use. **Production R2 upload has not been
exercised through this workflow** -- only local rehearsal and the
workflow's structure (actionlint-clean, every script reference
hand-verified) have been.

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
1. **shell-lint:** Runs shellcheck on tracked `*.sh`/`*.chroot` files and extensionless tracked shell scripts discovered by shebang, excluding `saved-unused/`; then `test/native-ab-static-test.sh` (cheap native A/B configuration invariants — no root, no build); then `test/native-ab-contracts-test.sh` (validates `docs/native-ab-contracts.md`'s frozen naming/label/URL grammar against the actual tree and the `test/native-ab-contracts-allow.txt` deviation list); then `check-native-publication-guard.sh` (docs/native-ab-contracts.md §15 — hard-fails a `cayo-ab`/`snow-ab`/`snowfield-ab` profile missing shim/Secure Boot/PCR-signing/NvPCR/pubring markers or carrying a `KernelModules=` filter, and hard-fails `cayo-ab-raw` if it ever gains a publication marker; since Phase 3 all three production profiles exist and are validated for real, `cayo-ab-raw` continues to pass the "must stay unpublishable" side)
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

### deploy-native-installer-redirect.yml — Stable ISO Discovery

**Trigger:** Push to `main` when `workers/native-installer-redirect/**` or the
workflow changes, plus manual dispatch. Installs the locked Node dependencies,
runs TypeScript/generated-binding/Vitest checks and `wrangler deploy --dry-run`,
then deploys with `CF_WORKERS_API_TOKEN` from `native-promotion`. The Worker has
a direct read binding to the publication R2 bucket and an exact-path-guarded
route for the stable installer URL; it has no signing or S3 credentials. Before
deploying, the job requires the `wrangler.jsonc` bucket to equal
`NATIVE_R2_BUCKET` and `wrangler r2 bucket info` to find it, preventing
Wrangler's automatic provisioning from turning a typo into a new empty bucket.

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
| Native A/B images (cayo-ab/snow-ab/snowfield-ab) | repository.frostyard.org/os/native/v1/\<product\>/x86-64/ | `rclone` candidate upload + independent HTTP re-verify + `promote.sh` (OpenPGP-signed `SHA256SUMS`/`SHA256SUMS.gpg`) via `build-native-images.yml`; production upload not yet exercised, see `docs/native-ab-publication.md` |
| Native installer stable URL | repository.frostyard.org/isos/native/v1/snosi-native-installer-latest-x86-64.iso | Cloudflare Worker derives an uncacheable redirect from the live R2 `SHA256SUMS`; immutable ISO publication remains in `build-native-images.yml` |
