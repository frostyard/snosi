# Plan: Native A/B and nbc retirement without losing bootc installation

**Status:** Proposed
**Last verified:** 2026-09-24

This is a reviewable sequence, not production authority. It implements the
proposed [local decision](../adr/0017-gate-native-ab-and-nbc-disposal.md)
alongside [core Plan 0008](https://github.com/frostyard/core/blob/main/docs/plans/0008-post-nbc-bootc-only-transition.md)
(Draft) and Plan 0006. Core ADR-0047's support cutoff is Accepted; core ADR-0050's
outside-`stable` retention conditions remain operative while core ADR-0052
is Proposed. No local plan can override these, core ADR-0048's signed `stable`
floor, or the core ADR-0046 cayo freeze. Do not change image, publication,
catalog, R2/GHCR, signed bytes or credentials under this planning phase.

## Phase 1 — Review decision and operator boundary

- Align [ROADMAP](../../ROADMAP.md), [installation](../installing.md), and
  [migration](../nbc-to-bootc-migration.md): end support and routine
  publication on **2026-09-30**, allow best-effort help through 2026-10-31
  only for four known users, use Firn for backup/fresh install/restore, not
  Dakota/Fisherman or in-place conversion. Ordinary bootc install is not
  evidence of secure DPS/MOK/TPM install, update, or Snowfield hardware proof.
- ADR-0015 stays Accepted until the successor decision is approved; then mark
  its status Superseded by 0017 (metadata/link only). Core ADR-0052 must be
  Accepted before dropping the operative outside-`stable` completion gate.
- Require recorded **review by both maintainers** of the decision,
  inventory, shared Firn ISO boundary, rollout, and rollback gates before
  implementation. Coordinate Firn-side catalog/recipe consequences; approval
  of a design is not approval for a production mutation.
- **Done when:** review and governing ADR status are recorded, and the proposed
  docs and CI-wired static contract agree without claiming production work.

## Phase 2 — Inventory and disposal worksheet (read-only)

### Source/consumer worksheet

| Candidate or dependency | Exact source / target and consumers | Proposed handling (not executed) |
| --- | --- | --- |
| NBC package | `frostyard-nbc` in `mkosi.images/base/mkosi.conf`; base feeds bootc images and sysext builds | Remove only on later approved builds; already-published debs may stay. Do not touch signed `stable` or referenced `pool/` bytes. Old nbc installs may still consume bootc OCI releases with their legacy updater. |
| NBC activation | `mkosi.images/base/mkosi.extra/usr/lib/systemd/system/nbc-update-download.{service,timer}`, base preset policy, `test/tests/02-services.sh`, native masks in `shared/outformat/ab-root/tree/` and native harnesses | Retire new-image units/preset only after host inventory; change guest test to expect absence, audit first-boot manifest and old-host recovery. Removing units from a new image does not deactivate an old host or remove persistent state. |
| Native profiles | `mkosi.profiles/{floe-ab,snow-ab,snowfield-ab}/mkosi.conf`, `shared/outformat/ab-root/`, `shared/native-ab/channels/{floe,snow,snowfield}/`, `shared/native-ab-secure/` | Separate native-only pieces from shared ISO dependencies before any removal. `mkosi.profiles/floe-ab-raw/mkosi.conf` is a never-published dev fixture, not an R2 product. |
| Native producers/tests | `.github/workflows/build-native-images.yml`, native publication guards, `test/native-ab-*`, `test/native-publication-pipeline-test.sh`, `test/workflow-path-filter-test.sh` | Stop routine three-product production publication after cutoff; adapt guards/harnesses without losing ISO gates; preserve historical evidence. |
| Picker | Three `family: ab` entries `snow-ab`, `snowfield-ab`, `floe-ab` in `shared/firn-installer/catalog.json`; `shared/firn-installer/mkosi.conf` installs it at `/etc/firn/catalog.json` | Remove exactly those entries later; this file **wholesale replaces** Firn's built-in picker. Keep exact bootc `snow`, `snowfield`, `floe`, `sundog` entries and ExtraTrees mapping. `:latest` is not proof of signed publication or successful install. |
| Shared ISO | `shared/firn-installer/`, `.github/workflows/build-installer-iso.yml`, `shared/native-ab/ci/`, ISO-facing `shared/native-ab/publish/` helpers (`prepare-iso-publication.sh`, candidate/verify/promote/withdraw, publish-lib, redirect verification), `shared/native-ab-secure/package-manager/`, `shared/native-ab/keys/mok-2026.crt`, `shared/native-ab/keys/import-pubring.gpg` | **Retain.** Forky sandbox, public MOK cert, update pubring and signed sysext trust serve bootc/Firn. Audit shared helpers before pruning OS-only code. Preserve `isos/native/v1/`, its signed index and stable redirect (`workers/native-installer-redirect/`, deploy workflow). |
| ISO identity | `shared/native-ab/publish/prepare-iso-publication.sh` produces `snosi-installer_<version>_x86-64.iso`, product/channel `snosi-installer`, `dest_path=isos/native/v1` | Namespace name alone does not make current Firn ISO a native A/B artifact. Historical `snosi-native-installer_*` media, if present, needs its own separately governed inventory. |

### Remote exact-object worksheet — **unfilled pending authenticated inventory**

Do not fill rows from guessed versions or treat this worksheet as deletion
authority. Obtain authenticated **read-only R2** key/size/hash listings and
public-origin observations for each of
`os/native/v1/{floe,snow,snowfield}/x86-64/` immediately before review.
Verify each live `SHA256SUMS` with `SHA256SUMS.gpg` against the committed
pubring; enumerate actual top-level versioned root, verity, EFI, disk and
SBOM keys, all `.candidate/<version>/` keys, all `.history/<version>/`
signed-index pairs, and **every** live/historical index reference. Reconcile
R2 keys with manifests, sizes, hashes and public bytes; record missing or
unverifiable objects as unresolved, never absent. A scheduled dry-run is not
a frozen production object list.

| Exact R2 key (one row per object) | Size | SHA-256 / signed-index & history references | Public URL / producer commit & run | Host/rollback/offline-media reliance | Proposed retain/delete + recovery/rollback reason | Fresh recheck / maintainer authorization |
| --- | --- | --- | --- | --- | --- | --- |
| **PENDING authenticated read-only listing** | unknown | unverified | unverified | unverified | **retain pending evidence** | not authorized |

Exclude `os/native/v1/cayo/` (historical, core ADR-0046), GHCR cayo, all ISO
objects, keys, signed `stable` and referenced package bytes, and every
referenced image byte unless a separate governing approval permits otherwise.
Do not use wildcard or prefix deletion. Record installed native/nbc hosts,
booted and rollback-slot versions, recovery keys and offline media, backups,
and direct outreach to the four known users (product, hardware class,
disposition and help needed). The 2026-08-26 cayo-ab host observation is
stale until rechecked. An unresolved disposition or stale last-resort nbc
reinstall instruction must be surfaced before authorization; under Accepted
ADR-0050 it remains a retention gate until core ADR-0052 is Accepted.

`native-retention.yml` currently schedules **execute** for floe, snow,
snowfield OS prefixes **and** the ISO namespace; `retention.sh` keeps live
plus two older versions (and 24-hour grace), not complete history. Propose
pausing/reconciling only its three OS legs during review by a separately
approved workflow change; keep the ISO leg operational. A live retention run
can change the object list between inventory and approval. Re-list and
re-verify before any deletion request.

- **Done when:** authenticated per-object evidence, signed-reference graph,
  installed-host recovery checks and unresolved gaps are recorded for review;
  **no object has been deleted**.

## Phase 3 — Separately authorized implementation after cutoff

- After the public and four direct EOL notices, stop routine NBC package and
  three native OS publications; preserve a separately approved exact-artifact
  emergency path (reason, digest, affected users, tests, rollback). Do not
  change signed stable, referenced bytes, ISO or sysext publication.
- In a separate implementation change remove NBC-only new-build/runtime
  wiring and native OS profiles/guards as appropriate; retain the shipped
  shared `/usr/libexec/snosi-eol-notice`, MOTD, toast and status consumers.
  Change `test/tests/02-services.sh` to expect NBC units absent; adapt native
  publication/retention and workflow-path-filter tests while keeping ISO
  checks. Exercise `test/workflow-path-filter-test.sh`,
  `test/native-ab-retention-test.sh`,
  `test/native-publication-pipeline-test.sh`, and
  `test/verify-installer-redirect-test.sh` after refactoring; keep validate.yml.
- Remove only three A/B picker entries; extend `test/firn-catalog-test.sh` to
  require exactly four named bootc choices, zero A/B, and catalog ExtraTrees.
  Review Firn's own A/B recipes/selection separately. On a bad picker pause
  publication, use an **approved signed-index withdrawal** or publish a new
  verified ISO; never mutate immutable ISO bytes. Reinstating routine native
  publication requires a separate approved support exception.
- **Done when:** independently approved changes ship without altering bootc
  picker, signed sysext trust or ISO publication, and static/real checks pass.

## Phase 4 — Evidence and independent production disposal gate

- Record actual CI run, image digest, ISO version, origin and hardware for
  Podman-backed bootc staged update + reboot + rollback (including user data),
  restrictive OCI signature policy, signed sysext index/update/merge, exact
  Firn picker, public-origin verified signed ISO index, stable redirect and
  ISO boot/install smoke. Run `test/bootc-container-policy-test.sh`, bootc
  update/install and secure artifact contracts, sysext signature tests,
  `test/firn-catalog-test.sh`, `test/native-iso-boot-smoke-test.sh` and public
  origin ISO verification when non-destructive releases are authorized.
  Fixtures are not installed-host evidence. Secure bootc fresh install belongs
  to Firn's enforced-Secure-Boot E2E; Snosi lifecycle update/recovery/rotation
  and Snowfield representative Surface hardware remain separately gated.
- Require the core ADR-0047 reported-class install, real published update,
  rollback and 48-hour use evidence to claim readiness, or disclose failures
  to affected users; failed gates block promotion/deletion, not checks.
- **Production A/B image deletion is a final distinct gate:** obtain separate
  explicit maintainer authorization of a freshly rechecked **exact per-object**
  list and consequences immediately before execution. Reconfirm signed-index/history
  references, user recovery/rollback, approved retention status, and ISO/cayo/
  stable exclusions. No approval of this plan authorizes any production delete.
- **Done when:** evidence and limitations are recorded independently of
  fixtures, and any later disposal has its own recorded exact-object approval
  and recovery path. Update [overview](../design/overview.md),
  [CI/CD](../design/ci-cd.md), [native publication](../native-ab-publication.md),
  [secure operations](../bootc-secure-operations.md), README and AGENTS
  alongside implementation; preserve historical records as historical.

## Open questions

- What objects and installed rollback slots exist at the time of the read-only
  inventory? Resolve in Phase 2; the remote worksheet remains unfilled until
  an authenticated read-only listing is captured.
- Is the promoted Firn catalog bound to tested digests instead of floating
  `:latest`? Resolve with Firn before promotion, not by assuming a listing is
  installation evidence.

## References

- Implements: [proposed ADR-0017](../adr/0017-gate-native-ab-and-nbc-disposal.md),
  [design overview](../design/overview.md), [CI/CD](../design/ci-cd.md).
- Governing: core ADR-0047, Accepted ADR-0050, Proposed ADR-0052, ADR-0048,
  ADR-0046, Plan 0006 and Plan 0008; [native contracts](../native-ab-contracts.md),
  [secure operations](../bootc-secure-operations.md).
