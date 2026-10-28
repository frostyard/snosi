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
| `.github/workflows/build.yml` | Builds base and sysexts in two mkosi invocations (himmelblau has its own scoped sandbox tree and `continue-on-error`), then moves artifacts and manifests into publish layout | R2 upload by repogen outside pull requests; PR build has only `contents: read`. This is the canonical mkosi action pin for the Justfile and retained ISO helpers. |
| `.github/workflows/build-images.yml` | Four bootc OCI profiles (`snow`, `snowfield`, `floe`, `sundog`) | PR mechanics builds use no secrets and do not publish. Protected main-branch builds sign and verify each immutable digest before copying it to `latest`. |
| `.github/workflows/build-installer-iso.yml` | Firn ISO from the bootc-only catalog | Positive main-push paths, manual or `build` repository dispatch; no PR trigger. Candidate upload, independent public-origin byte and ISO boot checks (the default entry's serial smoke test, then both GRUB entries and the no-display fallback, [ADR-0022](../adr/0022-installer-graphical-and-console-boot-entries.md)), protected index promotion and stable-redirect verification. |
| `.github/workflows/deploy-native-installer-redirect.yml` | Cloudflare Worker for the stable ISO URL | Validates worker/bucket identity and deploys separately from ISO publication. The Worker resolves the signed-index target through its read-only R2 binding; it does not sign the index. |

`build-images.yml` resets mkosi dependencies to `base` in each matrix job.
Neither OCI workflow passes `--sandbox-tree=shared/himmelblau/sandbox`, so
himmelblau's third-party APT source never reaches an image build
([ADR-0020](../adr/0020-scope-third-party-apt-sources.md)).
The `mechanics-build` job also runs `test/frostyard-apt-image-component-test.sh
--live` on each built image: it checks that the image ships no Frostyard APT
source and that `apt-get update` against the live repository, with only the
sandbox `frostyard.sources` (`main image`, core ADR-0059), prints no warning.
Protected assembly obtains signing credentials through transient mode-0600
runner files. The supplied MOK certificate and derived PCR public key must
match `shared/native-ab/keys/mok-2026.crt` and
`shared/native-ab/keys/pcr-signing-2026.pub`. Private bytes never enter OCI
layers and runner-local keys are removed before registry writes. The
candidate's pinned bootc calculates the storage composefs digest; the
assembled image is checked again to ensure digest continuity. Registry
authentication uses the run-scoped `GITHUB_TOKEN`; PR jobs have no registry
write permission. Cosign signs/validates the immutable digest, and
`latest` is promoted only after remote signature, label, policy-copy and
artifact checks succeed. Every published image carries
`org.opencontainers.image.version` as both a config label and a manifest
annotation, equal to os-release `IMAGE_VERSION`; bootc reads the annotation.
`shared/outformat/image/check-image-version.sh` checks the local image and
the pushed digest before promotion. Syft SBOMs attach via ORAS. Snow release
discovery requires a previous signed immutable Snow image with the exact Syft
SBOM referrer, not an arbitrary tag. Every packaging lane stamps the product's
`org.frostyard.core-flatpaks` label and checks it on the packaged image
before any push ([core Flatpak sets](../integration-contracts.md#core-flatpak-sets)).

`build-installer-iso.yml` retains the scripts at `shared/native-ab/publish/`
and the mkosi pin helpers at `shared/native-ab/ci/`. `native` in their names
and in `isos/native/v1/` does not mean an A/B product. The ISO's published
index is signed with the protected OpenPGP private key and verified against
the public `shared/native-ab/keys/import-pubring.gpg` trust root. The
signature is promoted before the manifest, then both are checked over the
served origin. `test/iso-publication-pipeline-test.sh` covers candidate,
HTTP Range, tampering and index promotion with a throwaway signing key and
local origin. The stable URL Worker derives its version from the R2 index
and never guesses a fallback. There is **no automatic ISO retention**:
the removed workflow never ran successfully because its R2 credentials
were unavailable. No R2 object is deleted by the source-lane removal; any
future deletion is gated by ADR-0018's exact-object check.

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
backs off exponentially (1, 2, 4, 8, 16 s: 31 s of delay for a full budget);
`--retry-max-time` caps the whole window. The boot smoke test's ISO download
uses the same options, and `verify-installer-redirect.sh` uses them on its
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
the Firn catalog, the ISO publisher, Forky sentinel, policy as code, build
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

`check-dependencies.yml` checks pinned direct downloads and image-tool pins (a pinned first-party `.deb` with `attestation` metadata, notesd and maild, is pinned only after `shared/download/verify-attestations.sh` passes on the candidate, and `build.yml` runs the same script before `Build main and sysexts`; ADR-0024);
`check-packages.yml` opens PRs for external APT package changes and a
separate Forky systemd source-version sentinel in
`shared/download/forky-versions.json`. A Forky change requires repeating
the bootc/libostree bwrap build-root check, Issue 517 GPT-auto udev-rule
check and NvPCR-mask check before acknowledging it. The sentinel triggers
the four-profile bootc image matrix, not the sysext publisher.
`ai-fix-requested.yml`, `claude.yml`, `triage.yml` and `scorecard.yml` cover
issue automation, fleet marker, labels and supply-chain reporting; they do
not publish OS artifacts.

## Publishing targets

| Artifact | Destination | Mechanism |
| --- | --- | --- |
| EROFS sysexts | `repository.frostyard.org/ext/` | repogen R2 upload with signed checksums |
| Bootc desktop/server images | `ghcr.io/frostyard/` | Buildah package, Cosign-signed immutable digest, verified `latest` promotion |
| Package manifests | R2 manifests bucket | post-promotion upload |
| Firn installer ISO | `repository.frostyard.org/isos/native/v1/` | signed index, verified public origin and index-derived stable URL redirect |
