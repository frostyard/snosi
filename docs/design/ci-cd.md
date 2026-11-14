# CI/CD pipeline

Decisions: [ADR-0008](../adr/0008-digest-first-release-latest-is-promotion.md)
(digest-first OCI publication),
[ADR-0011](../adr/0011-mkosi-bootstrapped-and-pin-shared.md) (mkosi pin),
[ADR-0018](../adr/0018-remove-native-ab-and-nbc-lanes.md) (bootc-only
output; retained ISO publication). The deleted native build/retention
workflows are documented only in
[native publication history](../native-ab-publication.md).

## Build and publish workflows

| Workflow | Inputs and output | Publication boundary |
| --- | --- | --- |
| `.github/workflows/build.yml` | Builds base and sysexts in two mkosi invocations (himmelblau has its own scoped sandbox tree and `continue-on-error`), then moves artifacts and manifests into publish layout | R2 upload by repogen v0.7.2 (payloads before metadata, retried) outside pull requests; `skip-published-identities` skips every identity the signature-verified `SHA256SUMS` already lists and uploads nothing when nothing is new; main push runs are never cancelled by a newer push. PR build has only `contents: read`. This is the canonical mkosi action pin for the Justfile and retained ISO helpers. |
| `.github/workflows/build-images.yml` | Four bootc OCI profiles (`snow`, `snowfield`, `floe`, `sundog`) | PR mechanics builds use no secrets and do not publish. Protected main-branch builds sign and verify each immutable digest before copying it to `latest`. |
| `.github/workflows/build-mechanics.yml` | Nightly at 03:30 UTC (`30 3 * * *`) and manual builds of the four mechanics images (`floe`, `snow`, `snowfield`, `sundog`) | Never from a pull request. The job holds `contents: read` and `packages: write` and publishes with the scoped `GITHUB_TOKEN`; it pushes only `ghcr.io/frostyard/<profile>:mechanics-<version>` and the moving `:mechanics` alias, labelled `io.snosi.qa.mechanics-only=true`, and never touches `latest`. It fails rather than publish a secure-capable image under a mechanics tag. QA fixtures for frostyard/lab; no security evidence. |
| `.github/workflows/forky-mechanics.yml` | Forky build of Floe, Snow, Snowfield, Sundog and the sysexts (`mkosi --release forky`, [ADR-0037](../adr/0037-build-forky-as-a-second-suite.md)) on pull requests that change an image input (the `paths-ignore` list of `build-images.yml`), nightly at 05:45 UTC and on dispatch | Publishes nothing: `contents: read`, no secret, no registry login. The build step is `continue-on-error`; `shared/suite/forky/classify-build.sh` passes a failed build only when every apt error matches a row of `shared/suite/forky/known-gaps.tsv`, and fails a passing build while a row remains. After a passing sysext build, `shared/suite/forky/check-sysext-names.sh` requires exactly 1 versioned `<id>_<version>_14_<arch>.raw*` file for each `Format=sysext` image of `mkosi --release forky --json summary`, and no other versioned file (`test/forky-sysext-names-test.sh`). |
| `.github/workflows/forky-publish.yml` | Manual dispatch only: the forky secure image of 1 product, Floe, Snow, Snowfield or Sundog, that the required `profile` choice input selects (`mkosi --release forky`, `SNOSI_BOOTC_SECURE_SUITE=forky`, [ADR-0038](../adr/0038-publish-signed-forky-test-images.md), [ADR-0039](../adr/0039-publish-forky-test-images-of-every-product.md)) | A `select` job (`permissions: {}`, no checkout, no secret, main gate) maps the input through `env:` to exactly 1 matrix entry of a fixed table equal to the `secure-build` matrix, and fails on any other value. The publish job runs only from main in `native-build`, with the steps, credentials, Cosign key, SBOM and provenance of `build-images.yml` `secure-build`. Pushes only the immutable `ghcr.io/frostyard/<product>:forky-<version>` tag; never `latest` or a trixie tag, no R2 manifests, no release. Test images with no support claim and no update stream; `test/forky-publish-workflow-test.py` holds the step list to `secure-build`. |
| `.github/workflows/build-installer-iso.yml` | Firn ISO from the bootc-only catalog | Positive main-push paths, manual or `build` repository dispatch; no PR trigger. Candidate upload, independent public-origin byte and ISO boot checks (the default entry's serial smoke test, then both GRUB entries and the no-display fallback, [ADR-0022](../adr/0022-installer-graphical-and-console-boot-entries.md)), protected index promotion and stable-redirect verification. |
| `.github/workflows/deploy-native-installer-redirect.yml` | Cloudflare Worker for the stable ISO URL | Validates worker/bucket identity and deploys separately from ISO publication. The Worker resolves the signed-index target through its read-only R2 binding; it does not sign the index. |

Every workflow pins its remote actions the way core ADR-0021 asks, and
`test/workflow-pins-test.py` enforces it for every file in
`.github/workflows/`: a 40-character commit SHA with a trailing release
comment, one top-level `permissions:` of `{}` or read-only grants, and
`persist-credentials: false` on each `actions/checkout` step. The test holds
the 2 allow lists: `BRANCH_PIN_ALLOW` for the untagged repositories whose
pins name a dated default-branch commit, and `READ_ALL_ALLOW` for
`scorecard.yml`, whose job replaces the top-level `read-all` grant.

`build-images.yml` resets mkosi dependencies to `base` in each matrix job.
Neither OCI workflow passes `--sandbox-tree=shared/himmelblau/sandbox`, so
himmelblau's third-party APT source never reaches an image build
([ADR-0020](../adr/0020-scope-third-party-apt-sources.md)).
The `mechanics-build` job also runs `test/frostyard-apt-image-component-test.sh
--live` on each built image: it checks that the image ships no Frostyard APT
source and that `apt-get update` against the live repository, with only the
sandbox `frostyard.sources` (`main image`, core ADR-0059), prints no warning.
Both OCI build jobs write
`/etc/containers/containers.conf.d/99-snosi-ci-runtime.conf` to select the
runner's bundled `runc`: hosted Podman 5.8.4 (runner image 20260726) with its
default crun rejects the generated OCI version for the nested `podman run`
calls of secure UKI assembly and chunking. The step fails when Podman reports
another runtime, and it changes only the disposable runner, not an image
(`test/bootc-secure-ci-test.sh` guards it).
Protected assembly obtains signing credentials through transient mode-0600
runner files. The supplied MOK certificate and derived PCR public key must
match `shared/native-ab/keys/mok-2026.crt` and
`shared/native-ab/keys/pcr-signing-2026.pub`. Private bytes never enter OCI
layers and runner-local keys are removed before registry writes. The
candidate's pinned bootc calculates the storage composefs digest; the
assembled image is checked again to ensure digest continuity. Local and
policy-copied artifact validation run the candidate image's own bootc through
host Podman; a host `bootc` must never become a prerequisite, because it would
be an unpinned version at the digest-authority boundary
(`test/bootc-secure-static-test.sh` rejects it). A step `env:` entry does not
cross `sudo`, so the packaging step assigns each `SNOSI_BOOTC_*` variable and
credential path again after `sudo`; `sudo --preserve-env` is not used, so the
privilege boundary stays visible at the call site. A new `SNOSI_BOOTC_*`
variable needs the `env:` line, the `sudo` assignment and an entry in the
fixed variable lists of `check-bootc-publication-guard.sh`; the guard checks
only the variables it lists, and fails a listed variable that is not
forwarded. Registry
authentication uses the run-scoped `GITHUB_TOKEN`; PR jobs have no registry
write permission. `shared/bootc-secure/ci/push-immutable-image.sh` pushes the
immutable version tag: at most 3 attempts for a transient GHCR blob-upload
fault (#1216, #1217); it checks for the tag before every push and stops if
the tag exists, so the tag never moves, and requires the registry digest of
the tag to equal buildah's digest file. Cosign signs/validates the immutable digest, and
`latest` is promoted only after remote signature, label, policy-copy and
artifact checks succeed. Every published image carries
`org.opencontainers.image.version` as both a config label and a manifest
annotation, equal to os-release `IMAGE_VERSION`; bootc reads the annotation.
`shared/outformat/image/check-image-version.sh` checks the local image and
the pushed digest before promotion. Syft SBOMs attach via ORAS. Snow release
discovery requires a previous signed immutable Snow image with the exact Syft
SBOM referrer, not an arbitrary tag. The Snow leg records and uploads the
`snow-tag` artifact only after the SBOM upload, SBOM signature, provenance
attestation and manifest upload succeed, so a failed metadata step skips the
release instead of releasing an incomplete image
(`check-bootc-publication-guard.sh` pins the step order). The release job
creates the release tag
with `GITHUB_TOKEN`. When GitHub refuses that tag with
`HTTP 403: Resource not accessible by integration` because the
`.github/workflows` tree of the built commit differs from the tree on the
default branch, `shared/bootc-secure/ci/create-github-release.sh` compares the
two tree identities and retries once with the `WORKFLOW_PAT` secret; it then
checks that the tag points at the built commit. Any other failure fails the
job. Every packaging lane stamps the
product's `org.frostyard.core-flatpaks` label and checks it on the packaged
image before any push ([core Flatpak sets](../integration-contracts.md#core-flatpak-sets)).

`build-installer-iso.yml` retains the scripts at `shared/native-ab/publish/`
and the mkosi pin helpers at `shared/native-ab/ci/`. `native` in their names
and in `isos/native/v1/` does not mean an A/B product. The ISO's published
index is signed with the protected OpenPGP private key and verified against
the public `shared/native-ab/keys/import-pubring.gpg` trust root. The
signature is promoted before the manifest, then both are checked over the
served origin. `test/iso-publication-pipeline-test.sh` covers candidate,
HTTP Range, tampering and index promotion with a throwaway signing key and
local origin. The stable URL Worker derives its version from the R2 index
and never guesses a fallback. After the new index and the redirect verify,
the promote job runs `shared/native-ab/publish/retention.sh --execute`
([ADR-0036](../adr/0036-prune-installer-isos-after-promotion.md)). It keeps
the live `snosi-installer_<version>_x86-64.iso`, the two versions before it
and every object younger than 24 hours, and deletes older installer ISOs,
stale `.candidate/` scratch and the `.history/` index pair of each ISO it
deletes. The step is the last in the job, and a failed delete fails the job. It verifies the live
signed index first and deletes nothing when that fails. One run deletes at
most 30 objects: a larger plan deletes nothing, prints its list and warns,
and a maintainer clears it by dispatching the workflow with
`retention_max_delete`. Every other R2 object stays under ADR-0018's
exact-object gate.

The public-origin HTTP checks retry transient transport failures. Three of
the last 60 runs of this workflow failed with `curl: (56) Recv failure:
Connection reset by peer` in the middle of a full GET of the ISO candidate,
a transient edge fault rather than a verdict about the object. Plain curl
`--retry` does not retry errors 56 (recv failure) or 18 (partial body), so
`http_size`, `http_get_sha256` and `http_get_to_file` in
`shared/native-ab/publish/publish-lib.sh` pass `--retry-all-errors` with
`PUBLISH_HTTP_GET_RETRIES` (default 5) and
`PUBLISH_HTTP_GET_RETRY_MAX_TIME` (default 300 s). Every call keeps a
`--connect-timeout` and a `--max-time`. No `--retry-delay` is set, so curl
backs off exponentially (1, 2, 4, 8, 16 s: 31 s of delay for a full budget).
Full GETs also use stall detection: a sustained transfer below
`PUBLISH_HTTP_GET_SPEED_LIMIT` (default 1048576 bytes/s) for
`PUBLISH_HTTP_GET_SPEED_TIME` (default 60 s) aborts early, so curl can retry
while the retry window is still open. Before this fix, a slow attempt could run
to `--max-time 600` and never start a retry.
`--retry-max-time` caps the whole window. The boot smoke test's ISO download
uses the same retry options (without the stall floor), and `verify-installer-redirect.sh` uses them on its
three curls. The checks still fail closed: after the last attempt the
helper returns non-zero and the caller exits with its existing diagnostic
(`http_get_sha256` also no longer hashes a partial file as if it were the
object). `--retry-all-errors` also retries a deterministic 4xx, so a missing
object costs up to 31 s before it fails; `test-public-origin-iso` and
`promote-iso` carry `timeout-minutes: 60` and `30` so no retry chain can
hold a job open indefinitely. Range GETs keep their own attempt loop.

## Validation and evidence

`.github/workflows/validate.yml` runs on PRs, main pushes and manual
dispatch. Its shell-lint job discovers tracked shell scripts by extension
and shebang and runs ShellCheck plus static and non-root fixtures. It checks
the Firn catalog, the ISO publisher, Forky sentinel, the forky known-gap
classifier, policy as code, build
permissions, sysext behavior, retirement documentation, and other contracts.
The publication-guard job exercises BATS guard fixtures, no-NBC checks,
RequiredBy and runtime `/etc` guards, service and sysext tests, and
`test/retirement-plan-test.py`; some account provisioning fixtures use root
in disposable test roots. The bootc-secure-contracts job checks protected
CI wiring, static/negative artifacts, installation/update fixtures,
`test/bootc-secure-docs-test.sh`, and publisher contracts. The
mkosi-config-sanity job runs summaries and
`check-profile-dependencies.sh` for all profiles. The installer-redirect
Worker job runs Node checks and a dry-run bundle deployment.

`nightly-compliance.yml` repeats secretless runtime `/etc`, ISO publication,
bootc publication and signed-sysext policy tests. `test-bootc-secure.yml`
and `bootc-secure-nightly.yml` provide fixture coverage; fixtures do not
prove secure install or update on hardware. `test-install.yml` is a manual,
signature-verified bootc QEMU/KVM install test. Minideb lab runs
(2026-10-24/25) gave VM fresh-install PASS evidence for Snow, Floe and
Sundog; Firn's enforced-Secure-Boot E2E has produced none (see
[testing](testing.md)). **Snowfield is untested on representative
Surface hardware; its catalog gate was waived.** Live signed update,
rollback, rotation and bootloader reconciliation require distinct installed
lifecycle evidence; see [secure operations](../bootc-secure-operations.md)
and [testing](testing.md).

## Dependency and maintenance workflows

`check-dependencies.yml` checks pinned direct downloads and image-tool pins (a pinned first-party `.deb` with `attestation` metadata, lodge, notesd, maild, porterd and readd, is pinned only after `shared/download/verify-attestations.sh` passes on the candidate, and `build.yml` runs the same script before `Build main and sysexts`; ADR-0024);
`check-packages.yml` opens PRs for external APT package changes and a
separate Forky systemd source-version sentinel in
`shared/download/forky-versions.json`. A Forky change requires repeating
the bootc/libostree bwrap build-root check, Issue 517 GPT-auto udev-rule
check and NvPCR-mask check before acknowledging it. The sentinel triggers
the four-profile bootc image matrix, not the sysext publisher.
`ai-fix-requested.yml`, `claude.yml`, `triage.yml` and `scorecard.yml` cover
issue automation, fleet marker, labels and supply-chain reporting; they do
not publish OS artifacts.

`risk-paths.yml` calls frostyard/core's reusable `pr-triage` workflow (core ADR-0068, ADR-0077, ADR-0078) on `pull_request_target`, pinned to a core commit. It reads `.github/risk-paths.json` at the base SHA, adds 1 level label, `level:L1` to `level:L4`, adds `risk:high` when the PR is L1 or L2, and removes `ready-for-human` when the head commit moves; it is not a required check. The list is schema version 2 (default L3) with a `level` on each glob: the list, the caller and `policies/**` are L2, every other entry L1. Each `why` names a `protectedBoundaries` entry of `policies/agent-governance.json`; `test/risk-paths-test.py` enforces that, the level of the list and caller globs, and rejects stale entries. `build.yml` and `build-images.yml` ignore both files.

## Publishing targets

| Artifact | Destination | Mechanism |
| --- | --- | --- |
| EROFS sysexts | `repository.frostyard.org/ext/` | repogen R2 upload with signed checksums |
| Bootc desktop/server images | `ghcr.io/frostyard/` | Buildah package, Cosign-signed immutable digest, verified `latest` promotion |
| Forky test images (Floe, Snow, Snowfield, Sundog; 1 per dispatch) | `ghcr.io/frostyard/<product>:forky-<version>` | the same signed path, immutable tag only, never `latest` (ADR-0038, ADR-0039) |
| Package manifests | R2 manifests bucket | post-promotion upload |
| Firn installer ISO | `repository.frostyard.org/isos/native/v1/` | signed index, verified public origin and index-derived stable URL redirect |
