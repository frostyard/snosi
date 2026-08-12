# 0007 — Freeze contracts in a doc with an executable form and a shrinking allowlist

- **Status:** Accepted
- **Date:** 2026-08-12

## Context

The native A/B rollout froze names, paths, version grammar, and policy
(Phase 0) before most implementing code existed. A frozen prose document
alone drifts; a test alone encodes values nobody can read as a contract; and
a prototype that predates the freeze needs a way to deviate *visibly*
without blocking every build until each phase lands.

## Decision

[native-ab-contracts.md](../native-ab-contracts.md) is the normative source
of truth for native A/B naming, paths, and policy — it defines values and
carries no rationale. `test/native-ab-contracts-test.sh` validates every
value statically, and the doc states the tie-breaker in its own header:
*"That test is the executable form of this document. If the two disagree,
the test is currently wrong (fix it) unless a value here was deliberately
changed (update both in the same commit)."*

Known deviations are tracked in `test/native-ab-contracts-allow.txt`, which
fails closed in **both** directions:

- an unallowlisted contract violation fails the test;
- a stale allowlist entry fails the test — both modes: the referenced file
  no longer exists, or it no longer violates.

Every entry names the phase that removes it, so the allowlist can only
shrink. It has since reached its terminal state: the file is now comments
only, stating "No tracked deviations remain… the stale-entry check keeps it
that way." A missing allowlist file is itself a test failure.

## Consequences

- The contract stayed enforceable across a multi-phase rollout: the
  prototype's known deviations (e.g. the pre-rename `cayo-ab` under tag
  `pending-rename`) were visible, phase-bound, and mechanically expired as
  each phase landed.
- The two-direction fail-closed allowlist prevents both failure modes of
  exception lists: silent accumulation (stale entries fail) and silent
  bypass (unlisted violations fail).
- Editing the frozen doc is constrained: value changes require the paired
  test change in the same commit; the doc cannot grow rationale (that now
  belongs in ADRs and design docs).
- This is a governance *pattern*, but it currently has exactly one
  instance. The bootc install contract pair
  ([bootc-secure-install-contract.md](../bootc-secure-install-contract.md)
  + `test/bootc-secure-install-contract-test.sh`) is a different mechanism:
  its authoritative artifact is the shipped
  `/usr/lib/snosi/bootc-secure.json`, asserted by a hardcoded exact-dict
  test, with no allowlist and no tie-breaker clause. A second frozen-doc
  contract should copy the native-ab mechanism deliberately, not assume it
  is already generic.

## Alternatives considered

- **Doc only, review-enforced:** rejected — a freeze that review must
  remember is not a freeze; the version grammar and label budgets are
  exactly the values that erode one "harmless" exception at a time.
- **Test only, no prose contract:** rejected — downstream repos (chairlift,
  installer repos) consume the *names*; they need a citable document, not a
  shell script.
- **Warn-listed deviations (non-failing):** rejected — deviations must
  block anything that is not explicitly tracked with a removal phase, or
  the prototype would have quietly redefined the contract.

## References

- Shapes: [native-ab-contracts.md](../native-ab-contracts.md),
  [design/testing.md](../design/testing.md)
- Implemented by: `test/native-ab-contracts-test.sh`,
  `test/native-ab-contracts-allow.txt`
- Guarded by: `.github/workflows/validate.yml` (contracts test step)
- Related: [ADR-0006 — name-triggered publication guards](0006-name-triggered-publication-guards.md)
  (§15 of the contract is its normative home)
- Builds on: [core ADR-0006 — OS artifact versions are UTC timestamps](https://github.com/frostyard/core/blob/main/docs/adr/0006-os-artifact-versions-are-utc-timestamps.md)
  (the frozen version grammar), [core ADR-0005 — marker and update-state files](https://github.com/frostyard/core/blob/main/docs/adr/0005-native-ab-marker-and-update-state-files.md)
