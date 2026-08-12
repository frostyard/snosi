# Documentation

Docs are split by the question they answer (the shape defined by
[frostyard/core ADR-0025](https://github.com/frostyard/core/blob/main/docs/adr/0025-consolidate-repository-docs-into-docs.md)):

| Directory | Question | Contents |
| --- | --- | --- |
| [adr/](adr/) | **Why** did we choose this? | Repo-local Architecture Decision Records — immutable once accepted; superseded, never edited. Org-wide decisions live in frostyard/core instead — see [org-adrs.md](org-adrs.md) |
| [design/](design/) | **How** does it fit together? | Living documents describing the current architecture; [design/overview.md](design/overview.md) is the entry point |
| [specs/](specs/) | **What exactly** is the contract? | Precise, testable interface definitions, changed only alongside implementing code |
| [plans/](plans/) | **When/in what order** do we build? | Phased plans and their paired designs; updated as work lands |

## Index

### Decisions (ADRs)

*(none yet — repo-local decisions get the next number from
[adr/TEMPLATE.md](adr/TEMPLATE.md))*

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
- [plans/ab-deploy-checklist.md](plans/ab-deploy-checklist.md) — native A/B production-deploy checklist

### Contracts and runbooks (indexed in place)

Pre-existing docs kept at their original paths; categorize opportunistically
when next rewritten.

- [native-ab-contracts.md](native-ab-contracts.md) — **frozen normative source of truth** for native A/B naming, paths, and policy (spec-natured; candidate for `specs/`)
- [integration-contracts.md](integration-contracts.md) — cross-tool producer→consumer contract map with fragility ratings
- [bootc-secure-install-contract.md](bootc-secure-install-contract.md) — contract between secure OCI images and the external installer repos
- [bootc-secure-assembly-compatibility.md](bootc-secure-assembly-compatibility.md) — assemble-uki.sh compatibility contract with bootc 1.16.7
- [bootc-secure-operations.md](bootc-secure-operations.md) — normative secure-bootc operations runbook (pinned by `test/bootc-secure-docs-test.sh`)
- [native-ab-publication.md](native-ab-publication.md) — native A/B production publication runbook
- [native-ab-capacities.md](native-ab-capacities.md) — measurements behind per-product channel partition sizes
- [nbc-to-bootc-migration.md](nbc-to-bootc-migration.md) — operator runbook: legacy nbc hosts → bootc
- [installing.md](installing.md) — user-facing installation guide for published images
- [snosi-kargs.md](snosi-kargs.md) — persistent custom kernel arguments on secure installs

### Process and governance (indexed in place)

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
