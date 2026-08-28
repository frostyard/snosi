# Org-wide decisions (frostyard/core ADRs)

Conventions this repository follows that are decided at the org level are
recorded as ADRs in
[frostyard/core](https://github.com/frostyard/core/tree/main/docs/adr).
The ones that bind snosi:

- [ADR-0003 — Record image provenance in /usr/share/frostyard](https://github.com/frostyard/core/blob/main/docs/adr/0003-image-provenance-in-usr-share-frostyard.md) — defines the packages.txt/build_date files written by common-postinst.sh
- [ADR-0004 — Product-namespaced filesystem paths, split by lifetime tier](https://github.com/frostyard/core/blob/main/docs/adr/0004-product-namespaced-filesystem-tiers.md) — the /usr/lib|share/snosi, /var/lib/snosi, /run/snosi split
- [ADR-0005 — Transport discrimination by marker file and /run update-state contract](https://github.com/frostyard/core/blob/main/docs/adr/0005-native-ab-marker-and-update-state-files.md) — /usr/lib/snosi/native-ab and /run/snosi/update-* are cross-repo contracts (chairlift consumes them)
- [ADR-0006 — OS artifact versions are 14-digit UTC timestamps](https://github.com/frostyard/core/blob/main/docs/adr/0006-os-artifact-versions-are-utc-timestamps.md) — mkosi.version / GHCR tags / partition-label budget
- [ADR-0007 — The Frostyard sysext filename pattern and derived versions](https://github.com/frostyard/core/blob/main/docs/adr/0007-frostyard-sysext-filename-pattern.md) — sysext-postoutput.sh's KEYPACKAGE/epoch/revision rules
- [ADR-0008 — Sysext distribution layout and update contract](https://github.com/frostyard/core/blob/main/docs/adr/0008-sysext-distribution-and-update-contract.md) — the ext/<name>/ layout the shipped .transfer files consume
- [ADR-0009 — repository.frostyard.org is the single artifact origin](https://github.com/frostyard/core/blob/main/docs/adr/0009-single-artifact-origin-repository-frostyard-org.md) — frozen os/native/v1 and isos namespaces, SHA256SUMS channel pointer
- [ADR-0010 — Publish packages through the shared repogen action](https://github.com/frostyard/core/blob/main/docs/adr/0010-publish-packages-via-repogen-to-r2.md) — build.yml / build-images.yml publish steps
- [ADR-0013 — Component releases trigger image rebuilds via repository_dispatch](https://github.com/frostyard/core/blob/main/docs/adr/0013-release-fanout-via-repository-dispatch.md) — snosi is the receiver of `build` dispatches
- [ADR-0014 — One GPG repository key, baked into images](https://github.com/frostyard/core/blob/main/docs/adr/0014-single-gpg-trust-root.md) — shared/sysext/keys, import-pubring.gpg
- [ADR-0015 — os-release is the image identity surface](https://github.com/frostyard/core/blob/main/docs/adr/0015-os-release-image-identity.md) — IMAGE_ID written into ID=; ImageId stays the product name in -ab profiles
- [ADR-0017 — io.snosi.* OCI capability labels and the mechanics QA tier](https://github.com/frostyard/core/blob/main/docs/adr/0017-io-snosi-capability-labels-and-mechanics-tier.md) — buildah-package.sh trusted labels; build-mechanics.yml
- [ADR-0018 — Org-wide agent instruction and knowledge surfaces](https://github.com/frostyard/core/blob/main/docs/adr/0018-org-wide-agent-instruction-and-knowledge-surfaces.md) — AGENTS.md symlinks, .memory/, .knowledge/ (its yeti/ AI-docs surface is superseded on that point by ADR-0025; snosi's former yeti/ now lives in docs/design/)
- [ADR-0019 — Repository governance as machine-readable policy with risk tiers](https://github.com/frostyard/core/blob/main/docs/adr/0019-governance-as-code-and-risk-tiers.md) — policies/agent-governance.json, risk tiers
- [ADR-0020 — Trust boundaries for AI automation in CI](https://github.com/frostyard/core/blob/main/docs/adr/0020-ai-automation-trust-boundaries.md) — COPILOT_ASSIGNMENT_TOKEN canonical-secret rule originates here
- [ADR-0021 — SHA-pinned actions and least-privilege CI workflows](https://github.com/frostyard/core/blob/main/docs/adr/0021-sha-pinned-actions-and-least-privilege-ci.md) — workflow pinning policy
- [ADR-0023 — External downloads are version-pinned and checksum-verified](https://github.com/frostyard/core/blob/main/docs/adr/0023-verified-pinned-downloads.md) — shared/download/verified-download.sh and its split registries
- [ADR-0025 — One docs/ tree per repository, in core's four-category shape](https://github.com/frostyard/core/blob/main/docs/adr/0025-consolidate-repository-docs-into-docs.md) — docs/{adr,design,specs,plans} + indexed docs/README.md; the former yeti/ tree was folded into docs/design/
- [ADR-0030 — Shipped systemd units never use RequiredBy= enablement](https://github.com/frostyard/core/blob/main/docs/adr/0030-no-requiredby-enablement-in-shipped-units.md) — preset-persisted .requires links brick boot when the unit is retired; enforced here by check-required-by-guard.sh and the initrd prune (repo ADR-0013)
- [ADR-0031 — Retire Dakota's secure bootc installer; Firn owns the path](https://github.com/frostyard/core/blob/main/docs/adr/0031-retire-dakota-secure-bootc-installer.md) — Firn's E2E and lab matrix own secure bootc installation; Snosi must not retain or pin Dakota/Fisherman adapter wiring
- [ADR-0041 — Retire copilot-review-apply where Snowcat gates review](https://github.com/frostyard/core/blob/main/docs/adr/0041-retire-copilot-review-apply-where-snowcat-gates-review.md) — Copilot review findings route to people; Snosi retains only the `ai-fix-requested` issue handoff

When changing behavior covered by one of these, update or supersede the ADR
in frostyard/core first, then change this repo in the same effort.
