# 0031 — first-setup retired without a soak; snosi claims only its own gates

- **Status:** Accepted
- **Date:** 2026-11-06

## Context

[ADR-0028](0028-first-login-runs-chairlift-first-run.md) moved the first-login
trigger of Snow and Snowfield from `snow-first-setup` to chairlift's first run.
Two of its consequences did not hold:

- It said that first-setup, its APT package and its frostyard.org pages retire
  after a soak of 14 days and 3 green main builds, and that a revert restores
  first-setup while its deb stays in APT. The soak was dropped. The
  frostyard/first-setup repository was archived on 2026-11-05, and every
  `snow-first-setup` version was then withdrawn from the `trixie` suite
  ([apt-publisher#32](https://github.com/frostyard/apt-publisher/pull/32),
  merged 2026-11-06, record `withdrawals/2026-11-05-snow-first-setup.txt`).
  Pool files stay; the index no longer lists the package.
- It said that frostyard/lab's first-login probe gates the lane after 3 green
  main runs. That probe is a report-only mode of a manual, advisory lane
  ([lab ADR-0016](https://github.com/frostyard/lab/blob/main/docs/adr/0016-first-login-probe-is-a-report-only-lane-mode.md)).
  Whether it gates is a lab decision. A snosi ADR that states it goes stale
  without any snosi change.

## Decision

1. **first-setup is retired, with no soak.** No snosi build input may name
   `snow-first-setup`; `test/first-login-trigger-test.sh` already enforces
   this.
2. **A revert of ADR-0028 needs a republication first.** With the package out
   of the `trixie` index, an image build that lists `snow-first-setup` fails
   when APT resolves its packages; it does not ship an image without a first-login
   app. To bring first-setup back, apt-publisher must first republish its
   last release (the pool still holds it), and the first-login guards of
   ADR-0028 must be reverted in the same change.
3. **snosi documents only the gates it runs.** The first-login trigger is
   gated in snosi by `shared/composition/first-login.finalize` (every OCI
   build) and `test/first-login-trigger-test.sh` (`validate.yml`). Published
   images are checked by frostyard/testsuite's `desktop.feature` scenarios,
   which the lab's container lane runs when an image's `latest` tag moves. The
   lab's first-login probe is lab evidence; its gate status lives in lab's
   ADRs, not here. This replaces ADR-0028's sentence that the probe gates the
   lane after 3 green main runs.

## Consequences

- ADR-0028 stays Accepted; its status line points here, and its two retired
  consequence bullets are read through this ADR.
- A rollback of the first-login swap is a two-repository change
  (apt-publisher, then snosi), not a single revert.
- A future cross-repository promise in a snosi ADR links the repository that
  keeps it instead of restating it (AGENTS.md, Documentation).

## Alternatives considered

- **Edit ADR-0028 in place:** accepted ADRs are immutable except for status
  and successor pointers (`docs/adr/TEMPLATE.md`).
- **Supersede ADR-0028 as a whole:** its decision (image-owned trigger, one
  entry, image-owned app list, brew `profile.d`, both markers) still holds;
  only two consequences changed.

## References

- Amends: [ADR-0028](0028-first-login-runs-chairlift-first-run.md)
- Shapes: [integration-contracts.md](../integration-contracts.md),
  [design/overview.md](../design/overview.md)
- Related: [lab ADR-0016](https://github.com/frostyard/lab/blob/main/docs/adr/0016-first-login-probe-is-a-report-only-lane-mode.md),
  [apt-publisher#32](https://github.com/frostyard/apt-publisher/pull/32),
  [testsuite `desktop.feature`](https://github.com/frostyard/testsuite/blob/main/tests/smoke/features/desktop.feature)
