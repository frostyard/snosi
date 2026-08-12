# 0012 — Chunk OCI layers by update cadence; chunk before sealing, never after

- **Status:** Accepted
- **Date:** 2026-08-12

## Context

A monolithic OCI rootfs layer forces clients to re-download the whole image
for any change. Chunking tools group files into layers, but grouping is only
useful if files that change together share layers — and for secure images
there is a harder constraint: the UKI binds a `composefs=` digest of the
image's storage identity into the signed kernel command line, and chunking
rewrites the OCI layer layout, changing that digest. Chunking a sealed image
invalidates its own seal.

## Decision

- **Chunking:** `shared/outformat/image/chunkah-package.sh` runs a
  digest-pinned chunkah (`quay.io/coreos/chunkah@sha256:…`, auto-bumped by
  `check-dependencies.yml`) with `--max-layers` defaulting to 128
  (`MAX_LAYERS: 128` in the workflow, pinned by the publication guard).
- **Cadence metadata:** before packaging,
  `shared/outformat/image/finalize/mkosi.finalize.chroot` tags every
  packaged file with two xattrs chunkah groups by: `user.component` (the
  owning dpkg package) and `user.update-interval`, computed per package from
  its Debian changelog — the last 10 `changelog.Debian.gz` entries, pairwise
  day-deltas, true median, bucketed into six classes: ≤3 daily, ≤10 weekly,
  ≤21 biweekly, ≤52 monthly, ≤180 quarterly, else yearly. Missing changelogs
  fail soft (xattr skipped, build continues); the Homebrew tarball is
  hardcoded `biweekly`. This tagging runs only for directory-image (OCI)
  outputs, not native A/B.
- **Chunk before seal:** on the secure path
  (`shared/outformat/image/buildah-package.sh`), the pristine candidate is
  packaged, **then chunked, and the authoritative composefs digest is
  computed from the chunked candidate**; only then does ukify bind
  `composefs=?<digest>` into the UKI, and the final image derives from the
  chunked candidate with only `/boot` overlaid — followed by a hard equality
  check that the overlay did not change the digest. `SOURCE_DATE_EPOCH` is
  required (fail-closed) for secure chunking. Protected images are never
  re-chunked after assembly: `check-bootc-publication-guard.sh` fails any
  secure-build workflow that invokes `chunkah-package.sh` directly.

## Consequences

- Update downloads scale with what changed: fast-moving packages share
  layers with each other, not with the yearly-cadence base, so a browser
  update does not invalidate the glibc layer.
- The chunked candidate — not the unchunked rootfs — is the storage-digest
  authority; the digest the UKI enforces is the digest clients actually
  pull. Re-chunking after sealing is structurally impossible in CI, not
  just discouraged.
- The cadence heuristic is deliberately cheap and wrong-tolerant: a
  mis-bucketed package costs bandwidth, never correctness, and fail-soft
  means chunking never blocks a build over a missing changelog.
- Currently chunkah's only call site is the secure branch; the non-secure
  buildah path packages without chunking (older doc text saying non-secure
  images are chunked is stale).
- Known fragility (recorded in the fable audit): `chunkah-package.sh`
  parses `podman load`'s English output, so an upstream wording change
  aborts packaging.

## Alternatives considered

- **One layer per package (no cap):** rejected — registries and clients
  degrade with thousands of layers; `MAX_LAYERS=128` forces grouping, and
  cadence is the grouping key that minimizes expected re-download.
- **Static hand-maintained layer groups:** rejected — a curated map of
  ~2000 packages drifts immediately; changelog history is already shipped
  ground truth for how often a package changes.
- **Chunk after sealing (chunk the final image):** rejected by mechanism —
  chunking rewrites the layer layout and thus the composefs digest the UKI
  already signed; the seal must bind the post-chunk identity.
- **ostree-container chunking:** not adopted — these images are
  bootc/composefs from mkosi output, not ostree commits; chunkah operates
  on the rootfs directly.

## References

- Shapes: [design/build-pipeline.md](../design/build-pipeline.md),
  [design/ci-cd.md](../design/ci-cd.md),
  [bootc-secure-assembly-compatibility.md](../bootc-secure-assembly-compatibility.md)
- Implemented by: `shared/outformat/image/chunkah-package.sh`,
  `shared/outformat/image/buildah-package.sh`,
  `shared/outformat/image/finalize/mkosi.finalize.chroot` (xattr tagging)
- Guarded by: `check-bootc-publication-guard.sh` (MAX_LAYERS pin, no
  direct chunkah invocation in secure builds),
  `test/bootc-publication-guard-test.sh`
- Related: [ADR-0008 — digest-first release](0008-digest-first-release-latest-is-promotion.md)
- Builds on: [core ADR-0017 — io.snosi.* capability labels](https://github.com/frostyard/core/blob/main/docs/adr/0017-io-snosi-capability-labels-and-mechanics-tier.md),
  [core ADR-0023 — verified pinned downloads](https://github.com/frostyard/core/blob/main/docs/adr/0023-verified-pinned-downloads.md)
  (the digest-pinned chunkah image)
