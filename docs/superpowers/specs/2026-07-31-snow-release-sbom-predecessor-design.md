# Snow Release SBOM Predecessor Design

## Problem

Protected run `30627996880` proved the complete secure OCI path for `cayo`,
`snow`, and `snowfield`: all three jobs passed local validation, immutable push,
signature verification, policy copy, remote artifact validation, promotion, and
metadata publication. The separate release job then failed while generating the
Snow changelog.

The new Snow tag `20260731114513` resolves to an image with a Syft SBOM. The
release job selected `20260731030941` as its predecessor, but that immutable tag
came from failed run `30600727040`, which stopped before SBOM publication. The
changelog generator requires a Syft SBOM for both tags and correctly rejected
the incomplete predecessor.

Two workflow assumptions caused this:

1. `gh release view` reads the repository's latest release, which is currently
   a Native A/B release without a Snow marker. It does not find the most recent
   older release whose body contains `<!-- snow-tag: ... -->`.
2. The fallback chooses the newest older numeric registry tag without proving
   that tag was released or completed metadata publication. Failed builds leave
   immutable numeric tags behind.

The Snow tag artifact is also uploaded before SBOM, provenance, and manifest
publication. Because the release job deliberately runs after a failed matrix,
that early artifact can authorize a release attempt for a metadata-incomplete
current image.

## Selected Design

### Current-image eligibility

The Snow matrix leg emits its `snow-tag` artifact only after all release metadata
steps succeed:

- immutable image signature and policy-copied validation;
- SBOM upload and SBOM signature;
- build provenance attestation; and
- manifest upload to R2.

The release job continues to use artifact presence as its deterministic signal
that the Snow leg completed the release-producing path. A failed metadata step
therefore leaves no tag artifact and causes release creation to skip.

### Predecessor selection

The release job queries all GitHub releases in newest-first API order and
extracts Snow markers from their bodies. Native A/B and unrelated releases are
ignored because they have no Snow marker.

For each candidate marker, in order:

1. Reject it if it is not a 14-digit tag, is equal to the current tag, or is
   newer than the current tag.
2. Resolve `ghcr.io/frostyard/snow:<candidate>` to its immutable digest with the
   authenticated ORAS client.
3. Discover referrers for that immutable digest.
4. Accept the candidate only if discovery contains at least one referrer whose
   `artifactType` is exactly `application/vnd.syft+json`.

The first eligible marker is the changelog predecessor. Registry tags that are
not recorded in a GitHub release body are never eligible, even when they happen
to have an SBOM. This preserves changelog continuity from the last published
Snow release rather than from an unreleased intermediate build.

If no prior marker resolves to an SBOM-complete image, the resolver writes
`skip=true`, emits a warning, and exits successfully. Changelog generation and
release creation are skipped. It must not fall back to arbitrary numeric
registry tags and must not backfill metadata onto failed historical images.

### Failure behavior

An absent or malformed release body is ignored. A candidate whose tag cannot be
resolved, whose referrer discovery fails, or whose discovery has no Syft SBOM is
skipped with a warning before trying the next marker. These are candidate
eligibility failures, not workflow failures.

Failures that make the search itself untrustworthy remain fatal: GitHub API
pagination failure, malformed authenticated output for the selected candidate,
or inability to write step outputs. The current image is already gated by the
late `snow-tag` artifact and does not need a second registry fallback.

## Implementation Boundary

Keep predecessor logic in a small repository script rather than embedding a
large shell program in workflow YAML. The script accepts the repository, image,
and current tag; uses the already-authenticated `gh` and `oras` CLIs; and writes
GitHub step outputs to the path supplied by `GITHUB_OUTPUT`. A fixture mode uses
PATH-provided command doubles and never contacts GitHub or GHCR.

The workflow remains responsible for ordering, authentication, and invoking the
resolver. The publication guard remains responsible for ensuring:

- the Snow tag artifact occurs after all required metadata steps;
- the resolver is used instead of inline latest-tag selection; and
- no `oras repo tags` numeric-tag fallback survives in the release job.

## Tests

Fixture tests must prove:

- newer Native A/B releases before an older Snow release do not hide its marker;
- a marker whose image has a Syft SBOM is selected;
- a missing tag, discovery failure, or missing Syft SBOM skips that candidate
  and tries the next marker;
- a same/newer marker is rejected;
- no eligible marker writes `skip=true` and exits zero;
- GitHub release-pagination failure is fatal;
- arbitrary numeric registry tags are never enumerated or selected;
- the selected predecessor and current tag are written exactly once using the
  existing `previous=`, `current=`, and `skip=` output contract.

Static workflow tests must prove:

- `snow-tag` recording and artifact upload occur after SBOM signing, provenance,
  and manifest upload;
- the release job calls the repository resolver after ORAS authentication;
- deleting the resolver call or moving the tag artifact before metadata fails;
  and
- reintroducing `oras repo tags` fallback fails.

## Documentation and Evidence

Update `CLAUDE.md` and `yeti/ci-cd.md` with the release-lineage and late-artifact
contract. Record run `30627996880` accurately: secure image publication passed
for all three profiles; only release changelog generation failed because the
old fallback selected a failed-build predecessor without an SBOM. Do not claim
the release repair is live-proven until a main-branch run creates or cleanly
skips the Snow release under this new selection logic.
