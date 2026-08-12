# 0008 — Publish by digest; `latest` is a promotion, never a push

- **Status:** Accepted
- **Date:** 2026-08-12

## Context

A mutable `latest` tag pushed alongside the version tag means consumers can
pull an image that was never verified: signing or verification failing
*after* the push leaves `latest` pointing at unvetted bytes. Separately, the
release job must resolve a predecessor image to describe updates against —
and guessing one produced a real incident: GitHub Actions run 30627996880's
fallback selected failed-build tag `20260731030941`, which had no SBOM.

## Decision

The secure publish path in `.github/workflows/build-images.yml` is
digest-first, in a statically enforced order:

1. push the immutable 14-digit version tag only, capturing the digest
   (`--digestfile`, shape-validated `^sha256:`);
2. `cosign sign` **the digest**, never a tag;
3. verify remotely (`shared/bootc-secure/ci/verify-published-image.sh`:
   capability labels, tag→digest agreement, `cosign verify` against the
   committed `cosign.pub`, policy-gated `skopeo copy`) and re-validate the
   policy-copied bytes with `test/bootc-secure-artifact-test.sh`;
4. only then promote: `shared/bootc-secure/ci/promote-published-image.sh`
   does a registry-to-registry `skopeo copy --all "$IMAGE@$DIGEST"
   "$IMAGE:latest"` and re-inspects `latest`, failing unless it resolves to
   the expected digest. No local bytes are ever pushed under `latest`.

After promotion, the SBOM is attached as an ORAS referrer
(`--artifact-type application/vnd.syft+json`), rediscovered to prove it is
findable, and itself cosign-signed. `check-bootc-publication-guard.sh` pins
the step order (Push → Sign → Verify → Validate → Promote, monotonically
increasing line numbers).

Release notes embed a machine-readable `<!-- snow-tag: <version> -->`
marker. Predecessor resolution
(`shared/bootc-secure/ci/resolve-snow-release-predecessor.sh`) walks release
markers, requires the candidate's digest to resolve, its referrer discovery
to parse, **and a `application/vnd.syft+json` referrer to exist** — any
candidate failing any check is skipped, and if none qualifies the release
steps are skipped (`skip=true`) rather than guessing. Listing registry tags
as a fallback is forbidden by the guard (`oras repo tags` must not appear in
the release job).

## Consequences

- `latest` can only ever point at a digest that was signed, remotely
  verified, and policy-copy revalidated; a failure anywhere leaves the
  version tag published but `latest` untouched — an intentionally visible
  half-state.
- A release with no SBOM-complete predecessor produces no changelog rather
  than a wrong one (the run-30627996880 class); the trade-off is that a
  gap in SBOM attachment mutes release notes until repaired.
- The SBOM referrer is attached *after* promotion, so there is a window in
  which `latest` exists without its SBOM; the predecessor resolver treats
  such images as ineligible, which is the designed behavior for incomplete
  publishes.
- The step ordering is contract, not convention: reordering the workflow
  fails `check-bootc-publication-guard.sh` before it can ship.

## Alternatives considered

- **Push version + latest together, then sign:** rejected — the window
  where `latest` is unsigned/unverified is exactly the failure this flow
  removes.
- **Tag-based signing:** rejected — tags are mutable; the signature must
  bind bytes, so it binds the digest.
- **Predecessor by registry tag listing:** rejected by incident — tag
  listings include failed and incomplete builds; the SBOM referrer is the
  proof of a completed publish, so it is the eligibility criterion.

## References

- Shapes: [design/ci-cd.md](../design/ci-cd.md) (secure-build and release
  jobs), [bootc-secure-operations.md](../bootc-secure-operations.md)
- Implemented by: `.github/workflows/build-images.yml`,
  `shared/bootc-secure/ci/verify-published-image.sh`,
  `shared/bootc-secure/ci/promote-published-image.sh`,
  `shared/bootc-secure/ci/resolve-snow-release-predecessor.sh`
- Guarded by: `check-bootc-publication-guard.sh` (step-order pinning),
  `test/bootc-release-predecessor-test.sh`
- Builds on: [core ADR-0006 — OS artifact versions are UTC timestamps](https://github.com/frostyard/core/blob/main/docs/adr/0006-os-artifact-versions-are-utc-timestamps.md)
  (the version-tag grammar), [core ADR-0017 — io.snosi.* capability labels](https://github.com/frostyard/core/blob/main/docs/adr/0017-io-snosi-capability-labels-and-mechanics-tier.md)
  (the labels the remote verify asserts)
