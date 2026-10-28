# 0024 — Verify attestations of first-party sysext debs

- **Status:** Accepted
- **Date:** 2026-10-28

## Context

Core ADR-0058 and its Plan 0010 (Phase 3) ask snosi to ship Frostyard's
first-party Lodge apps as sysexts (`notesd` from frostyard/frostnotes, `maild`
from frostyard/frostmail), and to check the GitHub build-provenance attestation
of each release `.deb` before it goes into an image.

Snosi pins a direct download by URL and SHA-256 in
`shared/download/sysext-checksums.json`. `verified_download()` checks the
SHA-256 in the mkosi postinst. That proves the bytes equal the pin. It does not
prove who built them, from which repository, workflow and tag. The pin is
written by a person or by `check-dependencies.yml` from a GitHub release.

`gh attestation verify` checks the attestation of a file: the repository, the
signing workflow, the source ref and the runner type. `gh` is not in the mkosi
buildroot, and the postinst runs there. The `build` job of `build.yml` runs
PR-controlled mkosi configuration as root, so its permissions stay exactly
`contents: read` (`test/build-workflow-permissions-test.py`). The attestations
API of a public repository answers with that token.

## Decision

An entry of `sysext-checksums.json` can carry an `attestation` object with the
`repository` and the `signer_workflow` of the release. The source ref is always
`refs/tags/v<version>` of the pinned `version`.

`shared/download/verify-attestations.sh [KEY...]` downloads each pinned file
through `verified_download()` and runs `gh attestation verify` with `--repo`,
`--signer-workflow`, `--source-ref` and `--deny-self-hosted-runners`. It fails
closed. The pin is checked twice:

1. **At pin time.** `check-dependencies.yml` writes a candidate pin into a
   temporary copy of the JSON, runs the script on the copy, and replaces the
   real file only when the check passes. On failure nothing is pinned and the
   job fails after its PR step, so the other updates still get their PR.
2. **At every build.** `build.yml` runs the script in a step before
   `Build main and sysexts`. The pinned SHA-256 binds the bytes that mkosi
   downloads later (in the postinst) to the attested digest, so one check of the
   pinned file is enough.

Only `notesd` and `maild` carry the metadata now. A later first-party sysext
adds the object to its entry and is covered at both points.

## Consequences

- A release whose attestation is missing, from another repository, workflow or
  ref, or built on a self-hosted runner, cannot be pinned, and a pin that no
  longer verifies breaks the build.
- Every `build.yml` run (all sysexts, PRs included) makes 2 downloads of about
  14 MB and 2 calls to the GitHub attestations API. A GitHub API outage fails
  the build; the build already depends on GitHub release downloads.
- The `build` job keeps `contents: read`. The check relies on the attestations
  API of a public repository answering without more scope. A private repository
  would need a token with `attestations: read` and a new permission decision.
- The check proves provenance of the pinned bytes, not their safety. Review of
  the pin PR stays the control for what the release contains.
- The `.deb` is verified in the workflow, not in the mkosi build. A local
  `just sysexts` build installs the pinned bytes without the attestation check
  unless the developer runs the script (`gh` and `GH_TOKEN` are then needed).
- Attestations are looked up by digest; deleting an attestation upstream turns
  into a build failure, which is intended.

## Alternatives considered

- **Check only at pin time.** Cheaper, but nothing re-checks the pin after
  review: a hand edit of the JSON, or a pin written by another tool, would
  reach an image unchecked. The build-time check is cheap enough to keep.
- **Verify inside the mkosi postinst.** Rejected: `gh` is not in the buildroot,
  and the postinst has no GitHub token. Adding both to the buildroot widens
  what PR-controlled root build code can reach.
- **A `gh` or `cosign` check inside `verified_download()` for every download.**
  Rejected: third-party upstreams (Bitwarden, Coder, Edge, ...) publish no
  attestations to check, and the helper also runs in the postinst.

## References

- Shapes: [design/sysexts.md](../design/sysexts.md) (Attested downloads, notesd, maild), [design/ci-cd.md](../design/ci-cd.md)
- Builds on: [ADR-0004](0004-sysext-authoring-rules.md), frostyard/core ADR-0058 (Lodge apps ship as sysexts) and Plan 0010 Phase 3
