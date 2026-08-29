# Documentation

Docs are split by the question they answer (the shape defined by
[frostyard/core ADR-0025](https://github.com/frostyard/core/blob/main/docs/adr/0025-consolidate-repository-docs-into-docs.md)):

| Directory | Question | Contents |
| --- | --- | --- |
| [adr/](adr/) | **Why** did we choose this? | Repo-local Architecture Decision Records — immutable once accepted; superseded, never edited. Org-wide decisions live in frostyard/core instead — see [org-adrs.md](org-adrs.md) |
| [design/](design/) | **How** does it fit together? | Living documents describing the current architecture; [design/overview.md](design/overview.md) is the entry point |
| [specs/](specs/) | **What exactly** is the contract? | Precise, testable interface definitions, changed only alongside implementing code |
| [plans/](plans/) | **When/in what order** do we build? | Phased plans and their paired designs; updated as work lands |

One layer sits above this table: [`../ROADMAP.md`](../ROADMAP.md) answers
**which of these matter next, and why** — the near/mid/long-term horizons, the
two-transport position, and what the project is deliberately not doing. It
states intent; the categories below hold the record.

## Index

### Decisions (ADRs)

- [adr/0001-var-factory-state-outcome-maps.md](adr/0001-var-factory-state-outcome-maps.md) — every build-time `/var` path is classified in per-product outcome maps, audited fail-closed in both directions (unclassified paths and stale globs)
- [adr/0002-ship-no-enablement-symlinks-in-etc.md](adr/0002-ship-no-enablement-symlinks-in-etc.md) — images ship zero unit-enablement symlinks in `/etc`; first-boot presets recreate them, with parity proven against a shipped manifest
- [adr/0003-runtime-etc-mutation-ban.md](adr/0003-runtime-etc-mutation-ban.md) — shipped payload files may not mutate `/etc` at runtime; enforced by payload-directory scanning with a per-line `etc-guard-allow` escape hatch
- [adr/0004-sysext-authoring-rules.md](adr/0004-sysext-authoring-rules.md) — sysexts are `/usr`-only overlays: `/opt` relocation, scoped factory-`/etc` capture, `Upholds=` activation, fail-closed `required-paths.txt` manifests
- [adr/0005-profiles-as-transport-kernel-selectors.md](adr/0005-profiles-as-transport-kernel-selectors.md) — profiles reduce to transport+kernel selectors via the `Dependencies=` reset idiom and ordered `Include=` fragment layering
- [adr/0006-name-triggered-publication-guards.md](adr/0006-name-triggered-publication-guards.md) — a profile is production purely by name; static textual guards pin secure posture on production profiles and forbid it on dev fixtures
- [adr/0007-frozen-contract-executable-allowlist.md](adr/0007-frozen-contract-executable-allowlist.md) — frozen contract docs get an executable form and an allowlist that fails closed in both directions, so it shrinks to empty
- [adr/0008-digest-first-release-latest-is-promotion.md](adr/0008-digest-first-release-latest-is-promotion.md) — publish by digest, sign and verify before `latest` is promoted; predecessors require the SBOM referrer or are skipped
- [adr/0009-snosi-env-var-classes.md](adr/0009-snosi-env-var-classes.md) — `SNOSI_*` variables come in three classes; security-relevant test hooks are paired/mutually gated so one stray variable is inert
- [adr/0010-credential-handoff-paths-not-bytes.md](adr/0010-credential-handoff-paths-not-bytes.md) — credentials cross the sudo boundary as mode-0600 file paths, never bytes; durable keys live in `.snosi-private/`, year-stamped
- [adr/0011-mkosi-bootstrapped-and-pin-shared.md](adr/0011-mkosi-bootstrapped-and-pin-shared.md) — mkosi runs from a repo-local checkout pinned to the workflow's action commit, bootstrapped pre-sudo
- [adr/0012-chunked-layers-cadence-xattrs-chunk-before-seal.md](adr/0012-chunked-layers-cadence-xattrs-chunk-before-seal.md) — OCI layers are chunked by changelog-derived update cadence; secure images chunk before digest sealing, never after
- [adr/0013-no-requiredby-enablement-prune-stale-requires.md](adr/0013-no-requiredby-enablement-prune-stale-requires.md) — shipped units never use RequiredBy= enablement (CI guard), and the native A/B initrd prunes stale .requires links that would brick boot at "Failed to isolate default target"
- [org-adrs.md](org-adrs.md) — the frostyard/core ADRs that bind this repo

### Design

*(formerly the `yeti/` directory — moved here per frostyard/core ADR-0025)*

- [design/overview.md](design/overview.md) — entry point: purpose, architecture, image/profile matrix, key patterns
- [design/build-pipeline.md](design/build-pipeline.md) — mkosi script phases, package relocation, verified downloads, OCI packaging
- [design/ci-cd.md](design/ci-cd.md) — workflow-by-workflow CI/CD pipeline, publishing, dependency automation
- [design/sysexts.md](design/sysexts.md) — sysext constraints, the shipped sysext set, authoring narrative (the filename grammar's normative home is [core ADR-0007](https://github.com/frostyard/core/blob/main/docs/adr/0007-frostyard-sysext-filename-pattern.md) and [native-ab-contracts.md](native-ab-contracts.md))
- [design/testing.md](design/testing.md) — test framework architecture, tiers, QEMU harnesses

### Specs

*(none yet — new contracts start from [specs/TEMPLATE.md](specs/TEMPLATE.md);
[native-ab-contracts.md](native-ab-contracts.md) below is spec-natured and a
categorization candidate for this directory)*

### Plans

- [plans/2026-02-11-package-version-monitoring-design.md](plans/2026-02-11-package-version-monitoring-design.md)
- [plans/2026-02-19-bootc-install-testing-design.md](plans/2026-02-19-bootc-install-testing-design.md) / [plan](plans/2026-02-19-bootc-install-testing-plan.md)
- [plans/2026-02-19-cayo-ship-design.md](plans/2026-02-19-cayo-ship-design.md) / [plan](plans/2026-02-19-cayo-ship-plan.md)
- [plans/2026-02-23-buildah-oci-packaging.md](plans/2026-02-23-buildah-oci-packaging.md)
- [plans/2026-02-24-sysupdate-normalize-design.md](plans/2026-02-24-sysupdate-normalize-design.md) / [plan](plans/2026-02-24-sysupdate-normalize-plan.md)
- [plans/2026-02-24-tailscale-sysext-design.md](plans/2026-02-24-tailscale-sysext-design.md) / [plan](plans/2026-02-24-tailscale-sysext-plan.md)
- [plans/2026-07-03-bootc-update-validation-plan.md](plans/2026-07-03-bootc-update-validation-plan.md)
- [plans/2026-07-13-mkosi-native-ab-root-design.md](plans/2026-07-13-mkosi-native-ab-root-design.md)
- [plans/2026-07-14-bootc-native-ab-coexistence-plan.md](plans/2026-07-14-bootc-native-ab-coexistence-plan.md)
- [plans/2026-07-17-graphical-installer-plan.md](plans/2026-07-17-graphical-installer-plan.md)
- [plans/2026-07-17-native-boot-validation-design.md](plans/2026-07-17-native-boot-validation-design.md) / [plan](plans/2026-07-17-native-boot-validation-plan.md)
- [plans/2026-07-20-update-api-daemon-design.md](plans/2026-07-20-update-api-daemon-design.md)
- [plans/2026-08-25-flurry-omarchy-plan.md](plans/2026-08-25-flurry-omarchy-plan.md)
- [plans/2026-08-26-cayo-floe-rename-plan.md](plans/2026-08-26-cayo-floe-rename-plan.md) — ordered cayo → floe product rename across snosi and downstream repos
- [plans/ab-deploy-checklist.md](plans/ab-deploy-checklist.md) — native A/B production-deploy checklist

### Contracts and runbooks (indexed in place)

Pre-existing docs kept at their original paths; categorize opportunistically
when next rewritten.

- [native-ab-contracts.md](native-ab-contracts.md) — **frozen normative source of truth** for native A/B naming, paths, and policy (spec-natured; candidate for `specs/`)
- [integration-contracts.md](integration-contracts.md) — cross-tool producer→consumer contract map with fragility ratings
- [bootc-secure-install-contract.md](bootc-secure-install-contract.md) — frozen legacy Task 9 adapter contract; Firn consumes the image's schema-1 contract directly
- [bootc-secure-assembly-compatibility.md](bootc-secure-assembly-compatibility.md) — assemble-uki.sh compatibility contract with bootc 1.16.8
- [bootc-secure-operations.md](bootc-secure-operations.md) — normative secure-bootc operations runbook (pinned by `test/bootc-secure-docs-test.sh`)
- [native-ab-publication.md](native-ab-publication.md) — native A/B production publication runbook
- [native-ab-capacities.md](native-ab-capacities.md) — measurements behind per-product channel partition sizes
- [nbc-to-bootc-migration.md](nbc-to-bootc-migration.md) — operator runbook: legacy nbc hosts → bootc
- [installing.md](installing.md) — user-facing installation guide for published images
- [snosi-kargs.md](snosi-kargs.md) — persistent custom kernel arguments on secure installs
- [../runbooks/image-publication-failure.md](../runbooks/image-publication-failure.md) — on-call triage for a failed/stalled secure-build publish (push/sign/verify/validate/promote)
- [postmortem-template.md](postmortem-template.md) — blameless postmortem template; pair with [.github/ISSUE_TEMPLATE/incident_report.md](../.github/ISSUE_TEMPLATE/incident_report.md)

### Process and governance (indexed in place)

- [../ROADMAP.md](../ROADMAP.md) — direction and horizons; the layer above `adr/` and `plans/`
- [org-adrs.md](org-adrs.md) — org-wide frostyard/core ADRs binding snosi
- [risk-tiers.md](risk-tiers.md) — PR risk-tier classification
- [review-rubric.md](review-rubric.md) — PR review rubric
- [SECURITY-AI.md](SECURITY-AI.md) — security boundaries for AI contributors
- [AI-QUALITY-ASSURANCE.md](AI-QUALITY-ASSURANCE.md) — how existing CI doubles as the agent-quality dashboard
- [copilot-automation-secret.md](copilot-automation-secret.md) — the canonical `COPILOT_ASSIGNMENT_TOKEN` secret
- [metrics/README.md](metrics/README.md) — delivery-metrics definitions and their `gh`/`jq` queries

### Historical records (point-in-time; not updated)

- [fable-audit.md](fable-audit.md) — 2026-07-01 repository + running-system audit; historical narrative, path references reflect the tree at audit time (including the former `yeti/`)
- [2026-07-03-bootc-migration-record.md](2026-07-03-bootc-migration-record.md) — record of the day the bootc path was first fully validated
- [native-ab-prototype-history.md](native-ab-prototype-history.md) — phase-by-phase build journal for the native A/B products, installer ISO (Phase 8), and native `/var` factory state, extracted from `AGENTS.md` (snosi#727); the live contracts are in [native-ab-contracts.md](native-ab-contracts.md)
- [OCIFIX.md](OCIFIX.md) — record of the PAX-header/OCI-layer problem and its fix
- [superpowers/](superpowers/) — archived mill-run specs (`superpowers/specs/`) and plans (`superpowers/plans/`); historical, reference paths as they were at the time (including the former `yeti/`)

## Conventions

- **New docs start from their category's `TEMPLATE.md`** (in each directory).
- New repo-local decision → new ADR in `adr/` with the next number; if it
  reverses an old one, mark the old one `Superseded by NNNN` rather than
  editing it. Decisions binding more than this repo go to frostyard/core,
  plus a line in [org-adrs.md](org-adrs.md).
- Design docs are updated in place to always reflect reality.
- Specs change only alongside the code that implements them.
- Cross-links between categories are mandatory in both directions.
- Adding a doc means adding it to the index above.
