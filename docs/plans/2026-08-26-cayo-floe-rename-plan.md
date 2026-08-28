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
Both a content inventory and a tracked-path inventory are mandatory:
`git grep -in cayo` finds contents, while
`git ls-files | grep -i cayo` finds names whose contents do not repeat the
product name. Classify every result as living (rename below) or historical
(retain per the docs rule below). Neither command substitutes for the other;
the load-bearing groups:

**Profiles and composition**
- [ ] `mkosi.profiles/cayo` → `floe`, `cayo-ab` → `floe-ab`,
      `cayo-ab-raw` → `floe-ab-raw`; inside each: `ImageId=floe`,
      `Output=floe`/`floe-ab`, include paths.
- [ ] `shared/composition/cayo/` → `floe/` (mkosi.conf, `var-outcomes.txt`,
      references in `var-audit.finalize`).
- [ ] `shared/packages/cayo/` → `shared/packages/floe/`, and the include
      that consumes it: `shared/composition/cayo/mkosi.conf` line
      `Include=%D/shared/packages/cayo/mkosi.conf` becomes
      `%D/shared/packages/floe/mkosi.conf` in the renamed composition
      fragment. This is the server package set for BOTH transports (the
      composition fragment is the only consumer), so leaving it behind
      leaves a live cayo-named build path after the "atomic" rename. Also
      update the two comments that cite it as the firmware precedent
      (`shared/firn-installer/mkosi.conf`, `shared/native-installer/mkosi.conf`)
      and the README composition table row.
- [ ] `shared/cayo/` → `shared/floe/` (postinst.chroot, tree — including
      `usr/share/cayo/bundles` → `usr/share/floe/bundles` and anything in
      `shared/scripts/common-postinst.sh` that names the path). The filename-
      only inventory must also rename
      `tree/usr/lib/systemd/system/journald.conf.d/10-cayo-bootc-persistent.conf`
      → `10-floe-bootc-persistent.conf`; the file itself contains no `cayo`
      string, so content search cannot find it.
- [ ] Inside that tree, rename the live-media kernel-argument conditions
      `ConditionKernelCommandLine=!cayo-linux.live=1` →
      `!floe-linux.live=1` in all three units that carry it:
      `usr/lib/systemd/system/brew-setup.service`,
      `usr/lib/systemd/system/incus.socket.d/override.conf`,
      `usr/lib/systemd/system/docker.socket.d/override.conf`. The karg
      follows the `<ImageId>-linux.live=1` convention snow/flurry use
      (`snow-linux.live=1`); nothing in-tree sets it, so the condition
      strings are the only thing to rename — and grep confirms it, since
      a `cayo-linux.live` left behind would silently never match a
      floe-identified live image.
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
      `shared/firn-installer/**`). Update and run
      `test/firn-catalog-test.sh`, including its `^cayo` server-product
      classifier; otherwise the renamed entry takes the desktop assertion
      branch and the test no longer validates the server groups.
- [ ] Resolve the superseded-but-still-executable native installer in this
      repository. It is distinct from the dormant external
      fisherman/bootc-installer/dakota-iso projects: `just
      native-installer-iso` still builds it and `validate.yml` still tests
      its CLI and GUI. Keep the generic `native-installer`/`snosi-install`
      names, but rename its live product vocabulary and fixtures:
      `shared/native-installer/tree/usr/libexec/snosi-install` accepts
      `floe-ab`, derives bare `floe` and
      `os/native/v1/floe/x86-64`, and reports floe's server/flatpak and disk-
      size rules; the GUI self-check/default fixture offers `floe-ab`.
      Rename the path-only `test/cayo-ab-install-spike.sh` →
      `test/floe-ab-install-spike.sh` and update all comments/callers. Update
      `test/snosi-install-test.sh`, `test/snosi-setup-model-test.py`,
      `test/native-installer-e2e-test.sh`, and the installer ISO/config
      comments and fixtures. Do not freeze a reachable executable with stale
      cayo identities.

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
- [ ] The filename inventory explicitly classifies
      `test/cayo-ab-install-spike.sh` as living and renames it as specified
      above. The old cayo ship-plan filenames under `docs/plans/` are
      historical and remain unchanged.

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
- [ ] Re-run both inventories. Every remaining content or path hit is listed
      in the historical exclusions above (including this rename plan and the
      old ship plans); no active build, test, installer, or payload path
      retains cayo.

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
- [ ] **Publish floe N+1.** The Phase 2 merge publishes exactly one signed
      floe version (call it N); a subsequent staged update cannot be
      demonstrated until a second one exists. After BOTH machines are
      booted on floe, publish N+1: either the next unrelated main-branch
      merge that triggers `build-images.yml`, or a manual
      `workflow_dispatch` of `build-images.yml` on `main` (protected
      `secure-build` — pushes/signs the immutable version digest, verifies
      it, then moves `latest`). Record N+1's 14-digit
      `org.opencontainers.image.version` and its immutable digest from the
      run. Do this *after* the reinstall, not before: the ISO pulls
      `floe:latest`, so a host installed after N+1 lands on N+1 and would
      then need an N+2 to prove the same thing.
- [ ] **Verify N+1 lands on each host through the normal path.** On each
      machine: wait for the hourly `bootc-update-stage.timer` or run
      `sudo /usr/libexec/bootc-update-stage`; confirm
      `/run/snosi/update-check` reads `outcome=staged` and
      `remote_version=<N+1>`, and `/run/snosi/update-staged` records N+1's
      digest (capture it now — the applying reboot clears the file);
      `snosi-update-status` shows the floe image staged. Reboot (natural or
      manual, never forced by the stager). After reboot: `snosi-update-status`
      running version is N+1, `bootc status` booted image is
      `ghcr.io/frostyard/floe` at the digest captured pre-reboot, and the
      rollback deployment is floe N (cayo is no longer in `bootc status` on
      the migrated bootc host). Compare *versions* across sources and
      digests only within the same host's containers-storage — the same
      build has a different digest per transport.
- [ ] `floe-ab` gets its own N+1 from its own `build-native-images.yml` run
      (the same main merge, or a separate `workflow_dispatch` of that
      workflow — dispatching `build-images.yml` does not run it), verified
      by that workflow's public-origin index check
      and boot smoke test plus lab's floe-ab install lane (Phase 4) — there
      is no floe-ab install to stage it onto (Phase 3 leaves the native
      channel with zero known installs).
- [ ] **Done when:** both machines are booted on floe (`IMAGE_ID=floe` in
      `/etc/os-release`), each has taken floe N+1 — one version newer than
      the floe version it first booted — through the normal stager and a
      reboot, with running version and booted digest verified as above, and
      rollback to cayo is confirmed no longer needed.

## Phase 4 — Downstream repos (parallelizable after Phase 2 publishes)

Ordered only by "the artifact must exist before the consumer points at it";
within that, these are independent. In **each** checkout, begin and end with
both complete tracked inventories:

```
git grep -in cayo
git ls-files | grep -i cayo
```

The following lists are the 2026-08-28 baselines. New hits discovered at
implementation time must be classified in the same PR rather than ignored
because they are absent from this snapshot.

- [ ] **lab** (points at published artifacts — merge only after Phase 2's
      first publication): the content inventory has 15 files and the only
      filename hit is `manifests/image-poll-cayo-latest.yaml`. Rename that
      manifest to floe (image ref, CronWorkflow name, and state key
      `digest-cayo-latest` → `digest-floe-latest` in
      `manifests/image-polling-digests.yaml`). Update the living surfaces:
      `Justfile`, `README.md`, `argo/firn-install-test.yaml`,
      `argo/snosi-install-test.yaml`, `argo/snosi-disk-boot-test.yaml`, and
      `argo/workflow-templates/{run-incus-install-tests,run-incus-disk-tests,run-container-tests,run-firn-install-tests}.yaml`.
      In `docs/roadmap.md`, change current tables/commands but retain dated
      evidence as historical. Leave `docs/adr/{0002,0006}-*.md` and
      `site/src/data/runs.json` unchanged as decision/run history. Run
      `just validate` and `just site-build`, then run the floe image poll,
      disk-install, and Firn-install lanes against the published artifacts.
- [ ] **firn**: the content inventory has 19 files and no filename hits.
      Rename all living source and test identities:
      `internal/tui/{catalog.go,catalog_test.go}`,
      `internal/bootcimg/storage.go`, `internal/trust/{trust.go,trust_test.go}`,
      `internal/sysconfig/{user.go,overlay_test.go}`,
      `internal/steps/{bootc.go,ab_test.go}`,
      `internal/recipe/recipe_test.go`, `cmd/firn/tui_test.go`, and
      `test/{e2e-bootc.sh,e2e-bootc-secure.sh,e2e-ab.sh,e2e-tui.sh}`.
      The catalog expects bootc `floe` and native `floe-ab`; generic trust
      derivation must resolve `floe-ab` to `os/native/v1/floe`. Update only
      living commitments in `docs/plans/roadmap.md`; retain ADRs 0003, 0004,
      and 0012 as history. Run `make ci` and the affected E2E fixture/default
      checks. Cut a firn release so the next ISO build ships a matching
      fallback catalog (not blocking — the ISO picker is snosi's
      `catalog.json`).
- [ ] **pilothouse**: the content inventory has six files and no filename
      hits. Rename demo identities in `internal/modules/fleet/module.go` and
      `views.templ`; update `module_test.go`, `views_test.go`, and the
      placeholder hostname in `cmd/pilothouse/listen_test.go`; regenerate
      `views_templ.go`; and rewrite `docs/branding.md`'s intentional-
      occurrence allowlist so it no longer blesses cayo. Run `make ci`.
- [ ] **frostyard.github.io**: the content inventory has eight files; the two
      tracked path hits are the `_index.md` files under
      `content/docs/images/server/cayo/` and its `cayo-loaded/` child. Move
      the living server page to floe and retire the obsolete loaded-variant
      page per the current sysext model (preserve an old-URL redirect).
      Update `content/docs/{status.md,images/_index.md,images/server/_index.md}`
      and `templates/pages/home.templ`; retain the two dated site plan files
      as history. Run `just test` and `just build`. Verify the deployed
      `/docs/images/server/cayo/` URL redirects to
      `/docs/images/server/floe/` and the destination returns 200.
- [ ] **frostyard-org**: the content inventory has three files and the only
      filename hit is `src/pages/cayo.astro`. Rename it to `floe.astro`,
      update `src/pages/index.astro` and `README.md`, and add an explicit
      `/cayo` → `/floe` redirect. Run `npm ci && npm run ci`. Verify the
      deployed `/cayo` URL redirects to `/floe` and the destination returns
      200.
- [ ] **fisherman / bootc-installer / dakota-iso**: dormant, inactive,
      superseded (confirmed 2026-08-26) — no rename work. Their stale cayo
      references are historical record, like the archived `frostyard/cayo`
      repo.
- [ ] **Done when:** lab's floe poll + install lanes are green against
      published floe artifacts; every downstream repository's test/build
      gate above passes; both old website URLs redirect to their floe URLs
      with a 200 destination; and both content and filename inventories in
      all five repositories return only the explicitly historical records
      classified above.

## Phase 5 — Retirement (small, after Phase 3 sign-off)

- [ ] snosi PR: remove the `ghcr.io/frostyard/cayo` scope from
      `policy.json` + policy test (floe/snow/snowfield/flurry remain).
- [ ] Reconcile the Phase 1 escape hatch on **both** migrated hosts. First run
      `snosi-etc-diff /etc/containers/policy.json`; if the operator installed
      the manual whole-file override, restore the current image copy with
      `sudo snosi-etc-diff --restore /etc/containers/policy.json` rather than
      editing the persistent overlay a second time. Verify the effective
      file with `jq`: `ghcr.io/frostyard/floe` is still
      `sigstoreSigned`/`matchRepository`, `ghcr.io/frostyard/cayo` is absent,
      and `default` remains `reject`. Confirm the file no longer appears in
      `snosi-etc-diff`. This step is required even if neither operator
      remembers using the escape hatch; persistent `/etc` drift does not
      disappear when the image policy changes.
- [ ] Edit the GHCR `cayo` package description to "renamed to floe
      (2026-08); frozen" — keep digests indefinitely (cheap, and rollback
      deployments reference them).
- [ ] Leave `os/native/v1/cayo/` on R2 as-is (frozen); optionally add a
      `RENAMED-to-floe` marker object. Do not break old signed indexes.
- [ ] Update the user-memory note (`minisnow` etc.) and close the tracking
      issue with links to the ADR.
- [ ] **Done when:** a fresh floe install and both migrated hosts' effective
      policies no longer trust the cayo repository, the two migrated hosts
      have no policy-file drift, and both operators have confirmed a full
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
