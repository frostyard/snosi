# Plan: Rename the cayo server image to floe

<!--
Plans are updated as work lands: check off what shipped, renumber what moved.
Every phase MUST have a "Done when" — a demonstrable outcome, not an activity.
-->

This plan renames the headless server product from **cayo** to **floe** across
every surface that publishes, installs, updates, tests, or documents it:
snosi (both transports — bootc OCI and native A/B), the Firn installer ISO,
lab, pilothouse, firn, and the two websites. Only two real installs exist, so
the migration is coordinated directly with those operators rather than through
a deprecation program — but the *ordering* below is still mandatory, because
an installed system's signature-trust policy is baked into the image it is
currently running, and a mis-ordered cutover strands it.

**Name rationale (record in the ADR, Phase 0):** a floe is a flat slab of
floating sea ice — the load-bearing sheet that forms once conditions
consolidate. Snow and Floe come from the same water (same Debian core, same
snosi pipeline); snow consolidates into something denser, flatter, and
structurally sound enough to bear weight — which is what a headless container
host needs to be. One-liner: *"Snow falls, Floe holds you up."*

## The two ordering constraints everything hangs on

1. **Signature policy is enforced by the *running* image.** Installed bootc
   systems update by `podman pull` (which enforces the shipped
   `/etc/containers/policy.json`) followed by `bootc switch/upgrade`. The
   current policy accepts exactly `ghcr.io/frostyard/{cayo,snow,snowfield,flurry}`
   with `default: reject`. A cayo install therefore **cannot pull a floe image
   until it is first updated to a cayo build whose policy includes the floe
   scope**. So trust pre-staging (Phase 1) must publish *as cayo* and land on
   both installs *before* the rename release exists — after the rename merges,
   `cayo:latest` never updates again.
2. **The native A/B channel name is baked into installed disks.** On a
   `cayo-ab` install the partition labels (`cayo_<version>_r`), the sysupdate
   transfer patterns (`cayo-ab_@v_@u.root.raw.xz`), the entry-token
   (`cayo-ab_<version>`), and the R2 path (`os/native/v1/cayo/x86-64/`) all
   carry the name. There is no supported in-place channel rename: sysupdate's
   instance accounting keys on the label pattern, so a floe-named transfer
   does not recognize cayo-named slots. **Native installs migrate by
   reinstall from the new ISO** (acceptable at this install count), not by an
   update hop. Do not engineer a label-migration path.

Everything else — CI job names, guard lists, docs, downstream repos — renames
mechanically once these two are sequenced correctly.

## Phase 0 — Inventory and decision record (small)

- [x] Inventory (resolved 2026-08-26): one install is native `cayo-ab`
      (bjk's), which will be backed up and **reinstalled as bootc floe** —
      it leaves the native channel entirely. The other is bootc
      (minisnow, fresh 1.16.7). Remaining per-host check before Phase 3:
      `snosi-update-status` version and `snosi-etc-diff` drift worth keeping.
- [ ] Record the rename as an org ADR in **frostyard/core** (it binds snosi,
      firn, lab, pilothouse, and the websites — per CLAUDE.md, decisions
      binding more than this repo go to core), including the name rationale
      above and the artifact-retirement decisions from Phase 5. Add the line
      to snosi's [docs/org-adrs.md](../org-adrs.md).
- [ ] Decide and record in that ADR: old artifacts are **frozen, not
      deleted** — the archived pre-snosi `frostyard/cayo` repo stays archived
      and untouched; the GHCR `cayo` package keeps its digests (installed
      systems' rollback deployments reference them); `os/native/v1/cayo/` on
      R2 stays readable but stops receiving updates. Also record (resolved
      2026-08-26): fisherman, bootc-installer, and dakota-iso are dormant,
      inactive, and superseded — they get no rename work.
- [ ] **Done when:** the org ADR is merged in core.

## Phase 1 — Trust pre-staging (publish as cayo, one small snosi PR)

The last cayo release, whose only job is to let installed systems trust floe.
With the inventory resolved, this phase gates exactly **one** host: the bootc
install (minisnow). The native cayo-ab machine reinstalls fresh in Phase 3
and never needs the pre-staged scope.

- [ ] Add `ghcr.io/frostyard/floe` as a `sigstoreSigned`/`matchRepository`
      scope in `shared/bootc-secure/tree/etc/containers/policy.json`
      (exactly the flurry precedent). Keep the cayo scope. Do not touch
      `default: reject` or any transport stanza.
- [ ] Update `test/bootc-container-policy-test.sh` expectations for the new
      scope; run it (fixtures) locally.
- [ ] Merge; let `build-images.yml` `secure-build` publish new
      cayo/snow/snowfield/flurry `latest` (shared file — all four get the
      scope, which floe itself also needs later or floe installs could never
      take their own updates).
- [ ] The bootc operator updates and reboots (hourly `bootc-update-stage` +
      natural reboot, or manually), then confirms
      `grep floe /etc/containers/policy.json`.
- [ ] Escape hatch if an install misses this window (discovered only after
      Phase 2): `/etc` is a persistent overlay, so the operator may manually
      append the floe scope to `/etc/containers/policy.json` — record it as
      expected drift. Prefer not to need this.
- [ ] **Done when:** the bootc install is running a cayo deployment whose
      `/etc/containers/policy.json` contains the `ghcr.io/frostyard/floe`
      scope.

## Phase 2 — The snosi rename PR (large, atomic)

One PR renames the product in-repo. It must be atomic because the
name-triggered publication guards (ADR-0006), the contracts test, and the
workflows all enumerate product names — a half-rename fails `validate.yml`.
`grep -ri cayo` over the tree is the working checklist; the load-bearing
groups:

**Profiles and composition**
- [ ] `mkosi.profiles/cayo` → `floe`, `cayo-ab` → `floe-ab`,
      `cayo-ab-raw` → `floe-ab-raw`; inside each: `ImageId=floe`,
      `Output=floe`/`floe-ab`, include paths.
- [ ] `shared/composition/cayo/` → `floe/` (mkosi.conf, `var-outcomes.txt`,
      references in `var-audit.finalize`).
- [ ] `shared/cayo/` → `shared/floe/` (postinst.chroot, tree — including
      `usr/share/cayo/bundles` → `usr/share/floe/bundles` and anything in
      `shared/scripts/common-postinst.sh` that names the path).
- [ ] `shared/native-ab/channels/cayo/` → `floe/`: repart labels
      `floe_%A_r` (+ verity partition config), `SplitName=floe_@v.root.raw`,
      and the three transfers — `Source Path=…/os/native/v1/floe/x86-64/`,
      `MatchPattern=floe-ab_@v…` / `Target MatchPattern=floe_@v_r`.
      Slot sizes are unchanged (same payload); update the name in
      `docs/native-ab-capacities.md`, not the numbers.
- [ ] Root `mkosi.conf` / `mkosi.images/{base,gui-base}` references
      (comments and any Dependencies mentions).

**Trust and installer catalog**
- [ ] `shared/bootc-secure/tree/etc/containers/policy.json`: floe scope is
      already present from Phase 1; **keep the cayo scope until Phase 5**
      (installed cayo systems still running pre-switch must keep updating…
      they won't get new cayo builds, but keeping the scope one release
      longer is free and removes a failure mode during the switch window).
- [ ] `shared/firn-installer/catalog.json`: replace the bootc `cayo` entry
      with `floe` (`ghcr.io/frostyard/floe:latest`) and `cayo-ab` with
      `floe-ab`; same server `default_groups`. The ISO picker is driven by
      this snosi-owned file, not by a firn release, so the ISO republishes
      correctly from this PR alone (`build-installer-iso.yml` triggers on
      `shared/firn-installer/**`).

**CI, guards, Justfile**
- [ ] `build-images.yml`: both matrix entries `profile: cayo` → `floe`.
- [ ] `build-native-images.yml`: PR matrix entry, `build-cayo` →
      `build-floe` (env `PROFILE: floe-ab`, `PRODUCT: floe`), artifact names
      (`native-prepared-cayo` etc.), `promote-cayo` → `promote-floe`, the R2
      URL `os/native/v1/floe/x86-64`, the verify/summary loops' product
      lists. GitHub environments (`native-build`, `native-promotion`) are
      product-agnostic — no settings change.
- [ ] `native-nightly.yml`: rotation (`Tue/Thu/Sat cayo-ab` → `floe-ab`) and
      the dispatch options list.
- [ ] `bootc-secure-nightly.yml` / `test-bootc-secure.yml` /
      `build-mechanics.yml`: `PROFILE=cayo` defaults and any job matrices.
- [ ] Guards: `check-bootc-publication-guard.sh` `profiles=(… floe …)`,
      `check-native-publication-guard.sh` `production_names=(floe-ab …)` and
      its `cayo-ab-raw` special-case path, `check-profile-dependencies.sh`.
      These must move in the same commit as the directory renames.
- [ ] `Justfile`: `cayo`/`cayo-ab`/`_cayo`/`_cayo-ab` targets and any
      test-install/run-qemu defaults.

**Tests**
- [ ] `test/native-ab-contracts-test.sh` + `test/native-ab-contracts-allow.txt`
      and the normative `docs/native-ab-contracts.md` (the naming contract
      itself changes: `floe`, `floe-ab`, `floe_<version>_r`,
      `floe-ab_<version>` entry-token, `os/native/v1/floe`).
- [ ] The bootc-secure suites' `PROFILE=cayo|snow|snowfield` acceptance
      lists and defaults (`bootc-secure-spike/install/update/artifact/static`,
      `native-ab-secure-boot-test.sh`, `native-boot-smoke-test.sh`, etc.).
- [ ] `test/workflow-path-filter-test.sh` and any other test pinning
      workflow content that names cayo jobs.

**Docs — living only**
- [ ] Update: `CLAUDE.md`, `AGENTS.md`, `README.md`, `CONTRIBUTING.md`,
      `docs/installing.md`, `docs/design/*`, `docs/native-ab-contracts.md`,
      `docs/native-ab-publication.md`, `docs/native-ab-capacities.md`,
      `docs/bootc-secure-*.md` (the install contract's
      `PROFILE=cayo|snow|snowfield` grammar), `docs/snosi-kargs.md`,
      `docs/integration-contracts.md`, `.github/prompts/native-ab-change.md`,
      PR template, `skills/flurry/SKILL.md`, `docs/README.md` index (add this
      plan).
- [ ] Do **not** rewrite ADRs, `docs/plans/2026-02-19-cayo-ship-*`,
      `docs/native-ab-prototype-history.md`, superpowers specs/plans, or
      `.memory/` history — they are historical record; the org ADR is the
      pointer from old name to new.
- [ ] Append a `.memory/corrections.jsonl`-adjacent note only if something
      believed here turns out wrong; otherwise nothing (the repo records the
      rename itself).

**Verification before merge**
- [ ] `mkosi --profile floe summary` and `--profile floe-ab summary` diff
      byte-clean (modulo Seed/tmpdir/Image Version) against pre-rename cayo
      captures — same composition, only names changed. Remember the
      `History=yes` gotcha: `sudo rm -f .mkosi-private/history/latest.json`
      before capturing.
- [ ] Local `just floe` build; full `validate.yml` suite green; fixture
      suites for every touched test.

**Post-merge, first main-branch run**
- [ ] `build-images.yml` publishes and signs `ghcr.io/frostyard/floe`
      (version tag + `latest`); `build-native-images.yml` promotes
      `os/native/v1/floe/x86-64/` with a signed index;
      `build-installer-iso.yml` republishes the ISO whose picker offers
      floe/floe-ab.
- [ ] **GHCR gotcha:** the first push creates a *new* package that defaults
      to private (CI verification passes because it authenticates). Set
      `ghcr.io/frostyard/floe` public in org package settings and confirm an
      unauthenticated `podman pull ghcr.io/frostyard/floe:latest` succeeds.
- [ ] **Done when:** an anonymous pull of `ghcr.io/frostyard/floe:latest`
      passes signature policy on a Phase-1-updated host, the floe-ab index
      at `https://repository.frostyard.org/os/native/v1/floe/x86-64/` is
      served and GPG-verifiable, and the new ISO boots to a picker offering
      floe.

## Phase 3 — Migrate the two installs (small, coordinated)

- [ ] **The bootc install** (minisnow):

      ```
      sudo podman pull ghcr.io/frostyard/floe:latest
      sudo bootc switch --transport containers-storage ghcr.io/frostyard/floe:latest
      sudo systemctl reboot
      ```

      The pull enforces the Phase-1 policy; after reboot the steady-state
      spec follows floe and `bootc-update-stage` continues unmodified
      (same containers-storage flow, new repository). Verify
      `snosi-update-status` shows the floe image and a later
      `outcome=current|staged` check against the floe registry entry.
- [ ] Keep the cayo deployment as the rollback slot until the operator
      confirms stable (this is why cayo GHCR digests are not deleted).
- [ ] **The native cayo-ab install** (bjk's, decided 2026-08-26): back up
      `/etc` drift worth keeping (`snosi-etc-diff`) and `/var` data, then do
      a **fresh bootc floe install** from the new ISO (family `bootc`, floe
      picker entry) and restore data. The machine leaves the native channel
      entirely — no update-path migration exists or should be built
      (constraint 2 above). Note this leaves `floe-ab` publishing with zero
      known installs; nightlies and lab's install lanes remain its coverage.
- [ ] **Done when:** both machines are booted on floe (`IMAGE_ID=floe` in
      `/etc/os-release`), have taken at least one subsequent staged floe
      update through the normal stager, and rollback is confirmed no longer
      needed.

## Phase 4 — Downstream repos (parallelizable after Phase 2 publishes)

Ordered only by "the artifact must exist before the consumer points at it";
within that, these are independent.

- [ ] **lab** (points at published artifacts — merge only after Phase 2's
      first publication): rename `manifests/image-poll-cayo-latest.yaml` →
      floe (image ref, CronWorkflow name, state key `digest-cayo-latest` →
      `digest-floe-latest` in `manifests/image-polling-digests.yaml`; a
      fresh empty key just triggers one initial QA pass — fine); defaults in
      `argo/snosi-disk-boot-test.yaml`, `snosi-install-test.yaml`
      (`cayo-ab` → `floe-ab`), `workflow-templates/run-incus-disk-tests`,
      `run-incus-install-tests`, `run-firn-install-tests`; the
      `firn-install-test` matrix products; Justfile/README/roadmap examples
      where they are living commands (leave historical run logs alone).
- [ ] **firn**: built-in catalog `internal/tui/catalog.go` (bootc `floe`
      entry + ab `floe-ab`); `trust.go` is already generic
      (`floe-ab` → `os/native/v1/floe` derives mechanically) — update only
      its doc comments; e2e defaults (`test/e2e-bootc.sh`,
      `e2e-bootc-secure.sh`, `e2e-ab.sh`, `e2e-tui.sh` fixtures and
      choose-patterns). Cut a firn release so the *next* ISO build ships a
      firn whose fallback catalog matches (not blocking — the ISO picker is
      snosi's catalog.json).
- [ ] **pilothouse**: cosmetic — demo fleet data in
      `internal/modules/fleet/module.go` / `views.templ` (regenerate
      `views_templ.go`), and update `docs/branding.md`'s intentional-
      occurrence allowlist (it explicitly documents these cayo strings; the
      rename must keep that doc truthful).
- [ ] **frostyard.github.io** (`site/`): move
      `content/docs/images/server/cayo/` → `floe/`, rewrite content, add a
      redirect/alias from the old URL if the generator supports it.
- [ ] **frostyard-org**: `src/pages/cayo.astro` → `floe.astro` + redirect.
- [ ] **fisherman / bootc-installer / dakota-iso**: dormant, inactive,
      superseded (confirmed 2026-08-26) — no rename work. Their stale cayo
      references are historical record, like the archived `frostyard/cayo`
      repo.
- [ ] **Done when:** lab's floe poll + install lanes are green against
      published floe artifacts, and a site search for "cayo" returns only
      deliberately historical pages.

## Phase 5 — Retirement (small, after Phase 3 sign-off)

- [ ] snosi PR: remove the `ghcr.io/frostyard/cayo` scope from
      `policy.json` + policy test (floe/snow/snowfield/flurry remain).
- [ ] Edit the GHCR `cayo` package description to "renamed to floe
      (2026-08); frozen" — keep digests indefinitely (cheap, and rollback
      deployments reference them).
- [ ] Leave `os/native/v1/cayo/` on R2 as-is (frozen); optionally add a
      `RENAMED-to-floe` marker object. Do not break old signed indexes.
- [ ] Update the user-memory note (`minisnow` etc.) and close the tracking
      issue with links to the ADR.
- [ ] **Done when:** a freshly-installed floe system's policy no longer
      trusts the cayo repository, and both operators have confirmed a full
      update cycle on floe with cayo nowhere in `bootc status`.

## Open questions

None — the install-inventory and dormant-repo questions were resolved
2026-08-26 and their answers are recorded in Phases 0, 3, and 4.

## References

- Naming/path contracts the rename rewrites:
  [native-ab-contracts.md](../native-ab-contracts.md),
  [native-ab-publication.md](../native-ab-publication.md),
  [bootc-secure-install-contract.md](../bootc-secure-install-contract.md)
- Guard design: [ADR-0006 name-triggered publication guards](../adr/0006-name-triggered-publication-guards.md)
- Precedent for adding a policy scope + new product end-to-end: the flurry
  work, [2026-08-25-flurry-omarchy-plan.md](2026-08-25-flurry-omarchy-plan.md)
