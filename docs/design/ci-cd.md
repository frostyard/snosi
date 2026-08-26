# CI/CD Pipeline

Decision records shaping this document:
[ADR-0003](../adr/0003-runtime-etc-mutation-ban.md) (runtime `/etc` guard),
[ADR-0006](../adr/0006-name-triggered-publication-guards.md) (publication
guards), [ADR-0008](../adr/0008-digest-first-release-latest-is-promotion.md)
(digest-first publish, SBOM-gated predecessors),
[ADR-0010](../adr/0010-credential-handoff-paths-not-bytes.md) (credential
handoff), [ADR-0011](../adr/0011-mkosi-bootstrapped-and-pin-shared.md)
(mkosi pin governance),
[ADR-0012](../adr/0012-chunked-layers-cadence-xattrs-chunk-before-seal.md)
(chunk-before-seal).

## Workflows

### build.yml — Sysext Build and Publish

**Trigger:** Push/PR to main, manual dispatch. Push/PR events ignore
`shared/download/image-checksums.json` when that is the only changed path;
image-only direct-download updates should rebuild OCI profiles instead.

Builds the base image and all 23 sysexts, and publishes to the Frostyard
repository on Cloudflare R2 only for non-pull-request events. The build job
runs PR-controlled mkosi configuration under `sudo`, but its `GITHUB_TOKEN`
has exactly `contents: read`; it has no package, OIDC, or attestation write
scope. `test/build-workflow-permissions-test.py` enforces that boundary in the
validation workflow.

**Steps:**
1. Aggressive cleanup of runner (removes JDK, .NET, Android SDK, etc. to free disk space)
2. Redirect `TMPDIR` to `/mnt/tmp`; mkosi workspaces can otherwise overflow the hosted runner root volume
3. Run `check-duplicate-packages.sh` to validate no duplicate packages across configs
4. Build base + all sysext images via mkosi
5. Run `sysextmv.sh` and `manifestmv.sh` to organize output into `output/sysexts/` and `output/manifests/`
6. On non-PR events, upload sysext artifacts and GPG-signed `SHA256SUMS` metadata to Frostyard R2 via the `frostyard/repogen` action
7. On non-PR events, upload manifest files to R2
8. Uses concurrent workflow cancellation (newer pushes cancel in-progress builds)

Repogen uses `REPOGEN_GPG_KEY` to emit a detached `SHA256SUMS.gpg` per
component; clients authenticate it because shipped transfers use `Verify=true`.
A signing-capable repogen release and a signature backfill for every existing
component are a release-ordering prerequisite for the verifying client image.

The publish step uses `skip-duplicates: true`: a sysext raw whose versioned
filename already exists in R2 is not re-uploaded. Since the filename version
comes from the KEYPACKAGE deb version, sysext tree fixes do NOT republish on
their own — set `SYSEXT_REVISION` in the sysext's mkosi.conf to append `+rN`
and force a new filename (see sysexts.md). Each sysext build also runs
`shared/sysext/finalize/sysext-required-paths.sh`, failing the build if any
path in the image's `required-paths.txt` is missing from the buildroot.

### build-images.yml — Desktop/Server Image Build and Publish

**Trigger:** repository_dispatch type `build`, push/PR to main, manual dispatch.
Push/PR events ignore sysext-only dependency metadata
(`shared/download/sysext-checksums.json`,
`shared/download/package-versions.json`, `latest-versions.txt`) when those are
the only changed paths. They also ignore Markdown/docs, agent-context stores,
the standalone installer ISO and redirect workflows, repository metadata
(issue templates, dependabot/renovate config), workflow files that never run on push/PR
(scheduled, dispatch-only, or issue/review-event workflows), and sibling
push/PR workflow files this workflow never reads (`build-installer-iso.yml`,
`build-native-images.yml`, `test-bootc-secure.yml`, `validate.yml`) —
`build.yml` is deliberately never ignored anywhere because it is the
canonical mkosi pin source.
`test/workflow-path-filter-test.sh` (wired into `validate.yml`) pins every
expensive workflow's ignore list, including negative assertions for the
load-bearing triggers (`build.yml` for `build-native-images.yml` via
`bootstrap-mkosi.sh`; `build-images.yml` and `docs/**` for
`test-bootc-secure.yml` via the publication guard and docs contracts).

Both the PR `mechanics-build` path and protected `secure-build` path iterate the
three profiles (snow, snowfield, cayo); only the latter can publish.

Both jobs select the GitHub runner bundle's `runc` through a job-local
`containers.conf.d` drop-in and verify the effective runtime before building.
This avoids the hosted `20260726.254.1` Podman 5.8.4/default-crun incompatibility
(`crun: unknown version specified`) for direct smoke tests and nested Podman
calls without changing the runtime policy inside shipped images.

Each matrix build resets mkosi dependencies to `base` (`--dependency= --dependency=base`). This prevents the root sysext dependency list from being appended into every profile build. The sysext publishing set is built once by `build.yml`; profile image jobs build only `base` plus the selected main image.

**Jobs:** `mechanics-build` runs on pull requests with read-only permissions. It performs the three-profile disk preparation, build, insecure local package, smoke test, and cleanup path without secrets or registry writes. `secure-build` runs only on `main` non-PR events inside the protected `native-build` environment.

GHCR authentication is repository- and run-scoped: `secure-build` grants
`packages: write`, while `release` grants only `packages: read`; both use
`secrets.GITHUB_TOKEN`. Buildah and ORAS consume the token through stdin, and
Docker login writes the user-context auth file used by Cosign and Skopeo.
Registry-login `run:` steps map `github.actor` to `GHCR_USER` in `env:` and
quote that shell variable; direct GitHub context interpolation in shell source
is forbidden. No long-lived GHCR PAT is required. Scheduled mechanics run `31150007630`
successfully pushed all three profiles with the same repository token, proving
the cayo, snow, and snowfield package access needed by secure publication.

**Protected publication steps:**
1. Transiently materialize the durable production MOK/PCR signing credentials supplied by the four `NATIVE_*` secrets, then build and package each profile. The supplied MOK certificate and derived PCR public key must byte-match the committed public identities; runner-local credential files are removed unconditionally after local artifact validation and before registry writes. The distinct disposable PR keys remain ephemeral.
   The package command repeats all five `SNOSI_BOOTC_*` names as explicit sudo
   assignments because step-level environment values are otherwise filtered by
   sudo. Do not replace this with implicit preservation or pass secret bytes in
   arguments.
   Local validation requires host Podman, not host bootc: the validator runs the
   candidate image's pinned bootc 1.16.8 to recompute its storage composefs digest.
   The same boundary applies to the policy-copied validation after registry pull.
2. Chunk, smoke test, and generate the SBOM, then use root Buildah's stdin login with the job-scoped `GITHUB_TOKEN` to push only the immutable timestamp tag and capture its digest.
3. Use the Docker credential context to sign `IMAGE@DIGEST`, verify its remote digest/secure labels and Cosign signature, and copy it through the restrictive repository policy before validating the copied UKI/composefs artifact.
4. Copy the verified immutable digest registry-to-registry to `latest`, and assert that `latest` resolves to that same digest. No local Buildah bytes are pushed under the mutable tag.
5. Only after promotion, attach/sign the SBOM, attest provenance, and upload manifests to R2. The Snow tag artifact is recorded only after all of those metadata steps succeed, so its presence authorizes the release job to use the current image.

#### release job — Automated GitHub Releases

After `secure-build` completes, a self-contained `release` job runs on main-branch pushes only and creates a GitHub Release summarising what changed in the build. It uses `!cancelled()` so it can still run after a matrix leg fails, but only proceeds when the `snow` leg uploaded its post-metadata tag artifact. Release failures are visible; the job is not `continue-on-error`.

**Predecessor contract:** The `snow` matrix leg writes the just-published timestamp tag to a short-lived artifact only after SBOM upload/signing, provenance attestation, and R2 manifest publication. The release job reads that as `current`, pages GitHub Releases newest-first, and considers only `<!-- snow-tag: ... -->` markers. A marker is eligible only when it is an older 14-digit tag whose immutable `ghcr.io/<owner>/snow:<tag>` digest has a discovered referrer with exact `artifactType` `application/vnd.syft+json`. The first eligible marker is `previous`; arbitrary numeric registry tags are never enumerated or selected. A missing tag, unavailable image, discovery failure, malformed discovery output, or absent Syft referrer skips that marker and continues. API pagination failure is fatal. If no eligible marker remains, the resolver writes `skip=true`, warns, and safely skips changelog and release creation.

**Release tag scheme:** `YYYY-MM-DD.N` (daily counter, e.g. `2026-04-09.1`). The release title is `Build YYYY-MM-DD HH:MM:SS UTC`. The body comes from the generated changelog plus the hidden `snow-tag` marker used by future releases.

**Evidence boundary:** Protected run `30627996880` passed all three secure image jobs (`cayo`, `snow`, and `snowfield`); only its release changelog failed. The old fallback selected failed-build tag `20260731030941`, which had no SBOM. The replacement is fixture and static-test verified, not live-proven, until a main-branch run creates or cleanly skips a Snow release under this contract.

### build-native-images.yml — Native A/B Build and Publish (Phase 7)

**Trigger and custody:** Push/PR to main, `repository_dispatch`, and manual
dispatch. Pull requests run only the non-publishing `build-pr` matrix with
per-run RSA-4096 MOK and RSA-2048 PCR credentials; it has no environment,
`NATIVE_*` secret, artifact upload, R2, or promotion access. Production
`build-*` and promotion jobs exclude pull requests. The `native-build`
environment must be restricted in GitHub settings to protected/default
branches; its four existing `NATIVE_*` signing secrets serve protected native
and bootc assembly. This replaces the obsolete accepted-risk claim that
same-repository pull requests may enter `native-build`. A single concurrency
group prevents two publication runs from interleaving `promote.sh` against the
same product's live signed index.

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
   URL, then (2026-07-17, "boot validation") installs QEMU/OVMF and runs
   `test/native-boot-smoke-test.sh` against the same re-verified candidate
   bytes -- boots the disk in QEMU/KVM and asserts `multi-user.target`
   active, `systemctl is-system-running --wait` = `running`, os-release
   `IMAGE_ID`/`IMAGE_VERSION` match the candidate, the `/usr/lib/snosi/
   native-ab` marker present, and a clean poweroff -- and only THEN uploads
   a `native-verified-<product>` marker on success. The smoke step's serial
   console log is uploaded as a `native-smoke-console-<product>` artifact
   (`if: always() && steps.smoke.outcome == 'failure'`) so a boot failure is
   debuggable without re-running the job locally. **The smoke test is the
   actual promotion gate**: both the "Record
   verified marker" and "Upload verified marker" steps require
   `steps.smoke.outcome == 'success'` in addition to `steps.verify.outcome
   == 'success'`, so a candidate that re-verifies over HTTP but fails to
   boot is never promoted. Secure Boot/TPM fidelity is deliberately NOT
   covered here (no MOK enrollment, no vTPM) -- that belongs to the deep,
   non-blocking `native-nightly.yml` workflow below. See
   `docs/plans/2026-07-17-native-boot-validation-design.md` for the
   two-tier rationale.
5. `promote-cayo` / `promote-snow` / `promote-snowfield` -- independent
   jobs, each gated on the `native-promotion` protected GitHub environment
   (holds `NATIVE_UPDATE_SIGNING_KEY`, the OpenPGP update-signing private
   key). Downloads its own `native-verified-<product>` marker and
   `native-prepared-<product>` artifact (both `continue-on-error: true`);
    no-ops if either is missing. The three promotion jobs conditionally run an
    `Install rclone` step only when both artifacts are present; it runs
    `apt-get update` immediately before installation to avoid stale
    hosted-runner indexes on delayed reruns. Otherwise writes the signing key to
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

### build-installer-iso.yml — Installer ISO Build and Publish

**Trigger and custody:** Main-branch pushes are restricted with a positive
`paths` list to the Firn installer profile/payload and its actual build,
trust, publication, and smoke-test inputs. Manual dispatch and the org-wide
`repository_dispatch` type `build` remain available. The generic dispatch has
no source-component payload, so it cannot yet distinguish Firn from other
component releases. There is no pull-request trigger. `native-build` gates R2
candidate upload (the Debian-signed boot chain uses no Snosi private key), and
`native-promotion` gates OpenPGP index signing.

**Jobs:** `pin-check` -> `prepare` -> `build-iso` ->
`test-public-origin-iso` -> `promote-iso`. The verification job re-downloads
the candidate from `isos/native/v1`, boots it with
`test/native-iso-boot-smoke-test.sh`, and emits `native-verified-iso` only
after both byte verification and the serial-login smoke test pass. Promotion
retains signature-first/manifest-last ordering, then verifies the served
signed index and stable installer redirect. Its own non-cancelling concurrency
group serializes installer-index mutations independently from native product
publication.

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

### Bootc Secure CI Tiers (Task 10)

`build-images.yml` has two mutually exclusive paths. PR `mechanics-build`
uses no secrets, does not publish, and produces only
`io.snosi.bootc.secureboot-capable=false` local mechanics images. Protected
`secure-build` runs only for non-PR main/default-branch events in
`native-build`. It uses the same four `NATIVE_*` secrets as protected native
assembly; public MOK/PCR values must byte-match
`shared/native-ab/keys/mok-2026.crt` and
`shared/native-ab/keys/pcr-signing-2026.pub`. Private credentials are removed
after local validation and before registry publication.

Protected bootc publication pushes a version tag, validates its immutable
digest and secure labels/signature/policy-copied artifact, then moves `latest`;
failed immutable candidates never move `latest`. Every GHCR read and write in
secure verification and promotion receives the Docker login config explicitly:
Skopeo inspections use `--authfile`, root policy copy uses source-only
`--src-authfile`, and promotion uses source and destination auth files. Pinned
Cosign v2.6.1 receives registry auth through command-scoped `DOCKER_CONFIG`; it
has no registry-config flag. Version-tag resolution must equal the pushed digest
before policy copy. The Docker auth file must be directly consumable by root
Skopeo without user-scoped credential-helper state; otherwise the policy-copy
verification fails closed and the next protected run remains the live proof. Do
not infer this handoff from `XDG_RUNTIME_DIR` or root Buildah login state.

Deferred publication follow-ups: bind SBOM signing to the exact uploaded
referrer digest, gate Snow release creation on complete metadata publication,
decide whether `latest` moves only after metadata completion, and make general
output cleanup unconditional where retained runners require it.
`test-bootc-secure.yml` supplies PR/push fixture contracts,
`bootc-secure-nightly.yml` supplies fixture coverage plus a self-hosted live
full-window attempt, and `test-install.yml` remains explicitly insecure legacy
mechanics coverage. Live Task 9/10 needs authorized signed secure
N/N+1/N+2/transition OCI fixtures and external runners. Until then its
unconfigured harnesses must exit 2 with `BLOCKED:`. The 2026-07-27 published
`latest` images lacked `io.snosi.bootc.secureboot-capable`, so they are not
valid live secure inputs. A manual Snowfield hardware run remains separate.
The PR/push fixture contracts include Task 1-3's spike `--fixtures` mode, the
privileged disposable-LUKS recovery-byte regression (installing `cryptsetup`
only for that check), and the Task 3 console-pump socket fixture; no live
Task 1-3 QEMU gate is duplicated there.
This section defines CI tiers and their limits; the normative operator recovery
and evidence-retention rules are in
[`docs/bootc-secure-operations.md`](../bootc-secure-operations.md).

### native-nightly.yml — Nightly Deep Secure-Boot Validation (Tier 2, 2026-07-17)

**Trigger:** Scheduled (`0 6 * * *` UTC), manual dispatch with a `profile`
input (`rotate` default, or force one of `cayo-ab`/`snow-ab`/`snowfield-ab`).
`concurrency: {group: native-nightly, cancel-in-progress: false}`.

This is Tier 2 of the two-tier boot-validation design
(`docs/plans/2026-07-17-native-boot-validation-design.md`): where
`build-native-images.yml`'s Tier 1 smoke test proves the exact promoted
bytes boot at all (no Secure Boot, no TPM), this workflow runs the full
deep secure chain -- install, enforced Secure Boot, TPM enrollment/
auto-unlock, boot, and a signed N→N+1 update hop -- by driving `test/
native-ab-secure-boot-test.sh` in its default (non-`--full-window`) mode
on a hosted `ubuntu-latest` runner with KVM, swtpm, and virt-firmware
installed at job time. It builds its own images from the checked-out
commit, so it is a genuine deep regression signal, not a re-check of
already-published bytes.

**Profile rotation** (day-of-week, UTC): Sunday `snowfield-ab`; Tuesday/
Thursday/Saturday `cayo-ab`; every other day `snow-ab` -- spreads the
~3-4 hour deep run (builds dominate) across all three products over a week
instead of running all three nightly.

**Zero-secret design (the load-bearing security property):** the workflow
declares no GitHub environment and touches no repository secrets. Because
the harness builds its own throwaway images, all key material is generated
fresh, in-job, immediately before the run: an ephemeral RSA-4096 Secure
Boot/MOK keypair and an ephemeral RSA-2048 (default exponent 65537) PCR
signing keypair -- RSA-2048 specifically, per `docs/native-ab-contracts.md`
§7, the only algorithm the full TPM unlock chain accepts (RSA-4096 fails
`Esys_LoadExternal`, ECC fails `Esys_VerifySignature`). The harness itself
generates its own ephemeral OpenPGP update-signing key internally, so
nothing durable or production-facing is ever read by this workflow.

**`KEEP_VM=1` is required, not optional:** the harness's `cleanup()` trap
`rm -rf`s its `$WORK_DIR` unconditionally on EXIT -- including on a failed
run -- unless `KEEP_VM=1` is set, in which case it returns early and leaves
the workdir (with `console.log`/`http.log`/`swtpm.log`) in place without
blocking the script's own exit code. Without this, the `Upload harness
logs` step's artifact glob would never match anything on a failure, since
the very directory it wants to upload would already be gone by the time
the step runs. `TMPDIR` is passed through explicitly for the same
CI-disk-exhaustion reasons as every other native build job.

**Non-blocking, by design:** nothing in the release/promotion pipeline
depends on this workflow succeeding or even running -- the actual
promotion gate remains the Tier 1 smoke test inside
`build-native-images.yml`. A nightly failure is a signal to investigate,
not a blocker; `if: failure()` uploads `nightly-harness-logs-<profile>`
for exactly that purpose.

### nightly-compliance.yml — Nightly Policy Drift Detection

**Trigger:** Scheduled daily at `04:30 UTC`, plus manual dispatch.

This secretless workflow re-runs the repository's existing static security and
publication contracts independently of pull request activity. It checks the
runtime `/etc` mutation guard, frozen native A/B contracts and publication
guard, bootc secure CI wiring and publication guard, and signed sysext metadata
policy. These are selected because they are fast, deterministic, require no
root or network after checkout, and cover policy that must remain true even
when no code is changing. Deep image-build and boot evidence remains in
`native-nightly.yml` and `bootc-secure-nightly.yml`; this workflow does not
duplicate those expensive jobs or publish artifacts.

Default permissions are empty and the sole job receives only `contents: read`.
Checkout credentials are not persisted, no environment or repository secret is
referenced, and `cancel-in-progress: false` prevents a delayed run from being
silently replaced by the next schedule.

### check-dependencies.yml — External Dependency Updates

**Trigger:** Weekly (Monday 9am UTC), manual dispatch

Checks for updates to resources managed by the verified download system. The
workflow has two independent jobs so update PRs touch only the dependency state
and inline pins for the build artifact that must be rebuilt.

Every curl invocation has `--max-time 120`, including metadata probes and
artifact downloads. The 1Password `Packages.gz` stream is capped with
`head -c 52428800` both before and after decompression, bounding the fetched
archive as well as expansion from a small gzip bomb.

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
- GitHub Copilot desktop .deb
- Sunshine Trixie .deb

Version-based checks only propose an update when the candidate sorts
**strictly newer** (`sort -V`) than the pinned version — a plain `!=`
comparison once let coder's stable/mainline channel split generate a
downgrade PR (2.35.1 -> 2.34.5, 2026-07-09). A pin ahead of the tracked
channel therefore stays put until the channel passes it.

Updates open `auto-update-sysext-checksums` PRs. Those PRs should trigger
`build.yml` and skip the OCI image matrix.

**OCI image dependency job (`shared/download/image-checksums.json` and inline pins):**
- Homebrew install script
- Surface secure boot certificate
- Hotedge GNOME extension
- Logomenu GNOME extension
- Bazaar Companion GNOME extension
- Syft CLI version used for SBOM generation
- Cosign CLI version used for signing; tracks stable v2 only because v3 cannot
  verify the repository's key-signed images when GitHub provenance attestations
  are present
- Immutable chunkah image digest corresponding to `chunkah:latest`

Updates open `auto-update-image-checksums` PRs. Those PRs should trigger
`build-images.yml` and skip the sysext publishing workflow.

**Process:**
1. Checks each upstream release/commit/package index
2. Downloads changed checksum-managed resources and computes SHA256 checksums
3. Updates the target-specific checksum file
4. Validates inline pin formats and requires exactly one matching source line
   before editing Syft, Cosign, or chunkah in place
5. Creates a target-specific PR

Syft and Cosign are the only detected image dependencies whose pins live under
`.github/workflows/`. GitHub refuses a `GITHUB_TOKEN` push that modifies those
files, so the repository must provide `WORKFLOW_PAT` with contents,
pull-requests, and workflows write access to publish those pin updates. The
workflow checks that capability before editing: if the secret is absent it
emits a warning and skips Syft/Cosign, then still applies checksum or chunkah
updates and creates a PR with `GITHUB_TOKEN`. If no non-workflow update remains,
the PR step is skipped instead of attempting an unauthorized push. The fixture
`test/check-dependencies-workflow-token-test.sh` enforces all three paths.

### check-packages.yml — Sysext APT Package Version Updates

**Trigger:** Daily (8am UTC)

Checks for version updates to external APT packages installed by sysext images:

- code (VS Code sysext)
- docker-ce
- 1password-cli
- claude-desktop

The job-level 15-minute timeout bounds the lifetime of its `contents: write`
and `pull-requests: write` token if an external APT request stalls.

`shared/download/package-versions.json` is only a change-detection sentinel.
It does not pin installed package versions; mkosi resolves the package from APT
during the sysext build.

**Process:**
1. Queries APT repositories for current versions through
   `shared/download/latest-apt-version.sh`. Each transfer is capped at 60
   seconds and 50 MiB compressed; decompressed `Packages` output has an
   independent 50 MiB cap, so a small gzip bomb cannot exhaust the runner.
   Truncated, malformed, and oversized indexes fail closed.
2. Compares against `shared/download/package-versions.json`
3. If changed: updates `package-versions.json`, creates a sysext package-version PR

### ai-fix-requested.yml — Copilot Issue Handoff

**Trigger:** An issue receives the `ai-fix-requested` label, or a maintainer
manually dispatches the workflow with an issue number.

The workflow re-fetches the issue and fails unless it is open and still has
the label, then calls GitHub's issue-assignment API with
`copilot-swe-agent[bot]`, the current repository, and its default branch.
The API requires a user-to-server token, so the repository must provide the
fine-grained `COPILOT_ASSIGNMENT_TOKEN` secret with read/write access to
Actions, Contents, Issues, and Pull requests. Do not replace it with
`GITHUB_TOKEN`, which is an installation token and cannot start this agent
assignment. Default workflow permissions remain empty, no checkout occurs,
and issue title/body text never enters the shell.

`COPILOT_ASSIGNMENT_TOKEN` is the fleet-wide canonical secret name for this
workflow. The organization-level credential must be granted to each
participating repository before that repository renames a consumer; aliases
such as `COPILOT_AGENT_TOKEN` and `COPILOT_ASSIGN_PAT` are not fallbacks.
`docs/copilot-automation-secret.md` is the operator runbook for the ordered
rollout, validation, failure, and rotation procedure, while
`test/copilot-automation-secret-test.py` is the local executable contract and
runs in `validate.yml`. Repository changes cannot create or reveal the
organization secret, so administrator confirmation is a merge precondition for
consumer renames elsewhere in the fleet.

### claude.yml — ACMM AI Integration Marker

**Trigger:** Manual dispatch only.

This workflow exists to satisfy the ACMM `acmm:github-actions-ai` file-presence
criterion while keeping the repository's real AI issue handoff in the existing
Copilot workflow. It has empty default permissions, performs no checkout, uses
no secrets, and introduces no third-party action dependency.

### triage.yml — Automated Issue Classification

**Trigger:** Issue opened, edited, or reopened.

The workflow fetches the issue with `gh api`, classifies only from explicit
title signals, and adds at most one of the existing `acmm`, `bug`,
`documentation`, `enhancement`, or `question` labels. If any classification
label is already present, it does nothing; it never removes or replaces human
labels. The label output is allowlisted before `gh issue edit`, issue text is
not interpolated into workflow expressions or evaluated by the shell, and the
job receives only `issues: write`. Bug reports created from the repository
template receive `bug` directly from template front matter, so they do not
depend on title heuristics.

### validate.yml — Code Validation

**Trigger:** PR/push to main, manual dispatch

Three jobs:
1. **shell-lint:** Runs shellcheck on tracked `*.sh`/`*.chroot` files and extensionless tracked shell scripts discovered by shebang, excluding `saved-unused/`; then `test/native-ab-static-test.sh` (cheap native A/B configuration invariants — no root, no build); then `test/native-ab-contracts-test.sh` (validates `docs/native-ab-contracts.md`'s frozen naming/label/URL grammar against the actual tree and the `test/native-ab-contracts-allow.txt` deviation list); then `check-native-publication-guard.sh` (docs/native-ab-contracts.md §15 — hard-fails a `cayo-ab`/`snow-ab`/`snowfield-ab` profile missing shim/Secure Boot/PCR-signing/NvPCR/pubring markers or carrying a `KernelModules=` filter, and hard-fails `cayo-ab-raw` if it ever gains a publication marker; since Phase 3 all three production profiles exist and are validated for real, `cayo-ab-raw` continues to pass the "must stay unpublishable" side)
2. **runtime-etc-guard:** Runs `check-runtime-etc-guard.sh` — scans every tracked file in image payload dirs (`mkosi.extra/`, `shared/*/tree/`) for patterns that delete paths from `/etc` at runtime: `systemctl disable/enable/revert/unmask/preset` (and `deb-systemd-helper`) in units/scripts, `rm`/`mv`/`find -delete` targeting `/etc/`, and tmpfiles.d removal types (`r`/`R`/`D`) on `/etc`. Any such deletion on a bootc/composefs install breaks the `/etc` merge in `bootc-finalize-staged` at shutdown ("a path led outside of the filesystem", bootc ≤ 1.16.3) and the staged update is silently discarded — the host keeps booting the old image while the updater logs success (root-caused 2026-07-05 on `enable-incus-agent.service`, which self-disabled via `ExecStartPost`). Run-once units must gate on a `/var` marker instead (`ConditionPathExists=!/var/lib/<unit>.done` + `ExecStartPost=touch`). Escape hatch for provably safe lines: `# etc-guard-allow: <reason>` comment on the same line or the line directly above (unit files have no trailing comments). Build-time scripts (`*.chroot`, `mkosi.postinst`, etc.) are outside payload dirs and intentionally unscanned — build-time `systemctl enable` is correct. `test/runtime-etc-guard-test.sh` and `test/duplicate-packages-test.sh` provide standalone TAP fixture coverage for these two guards.
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
The deploy token has Workers Scripts Write, Workers Routes Write, Account
Settings Read, and R2 Storage Read only; R2 Write is intentionally forbidden.

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
| Native installer stable URL | repository.frostyard.org/isos/native/v1/snosi-installer-latest-x86-64.iso | Cloudflare Worker derives an uncacheable redirect from the live R2 `SHA256SUMS`; immutable ISO publication runs through `build-installer-iso.yml` |
