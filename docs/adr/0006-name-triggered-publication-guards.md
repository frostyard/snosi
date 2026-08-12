# 0006 — Profile names trigger publication guards; reachability is textual, not resolved

- **Status:** Accepted
- **Date:** 2026-08-12

## Context

Production and development profiles live in the same tree and share
fragments. The dangerous failure is categorical: a dev fixture drifting into
publishability (acquiring signing markers), or a production profile silently
losing its secure posture. Any guard keyed on profile *content* can be
argued around; any guard keyed on a registry file can fall out of date.
What cannot drift is the name a publish workflow builds.

## Decision

A profile is production purely by being named `cayo-ab`, `snow-ab`, or
`snowfield-ab` — the rule is normative in
[native-ab-contracts.md §1](../native-ab-contracts.md): a profile literally
so named is production-facing, must satisfy the publication guard, and must
never mean "raw prototype". Two guards enforce the postures:

- `check-native-publication-guard.sh` requires, in each production-named
  profile's reachable config text: `ShimBootloader=signed`,
  `SecureBoot=yes`, `SignExpectedPcr=yes`, the `disable-nvpcr.chroot`
  reference, the `shared/outformat/ab-root` include, and the committed
  pubring `shared/native-ab/keys/import-pubring.gpg` — and forbids a
  profile-local `KernelModules=` filter. It also hard-fails the inverse:
  the dev fixture `cayo-ab-raw` must never carry any of the three signing
  markers. Beyond profiles, it pins the workflow shape itself (PR builds
  must not reference `secrets.NATIVE_*`, publish/promote scripts, `rclone:`
  or artifact uploads; publish jobs must use `environment: native-build`).
- `check-bootc-publication-guard.sh` requires each bootc production profile
  (`cayo`, `snow`, `snowfield`) to include
  `shared/bootc-secure/mkosi.conf` plus its file set (cosign.pub, MOK/PCR
  certs, policy.json, bootc-secure.json), and forbids any `*-ab*` profile
  from including the bootc secure fragment.

Reachability is a **plain textual check, deliberately not an `Include=`
resolver**: a profile's config plus the one documented fragment directory
(`shared/native-ab-secure/**`) if and only if the profile's `mkosi.conf`
textually references it. The guard does not walk arbitrary `Include=`
chains — the comment in the script states this, and
`test/native-ab-contracts-test.sh` restates the same rule at its mirror
check.

## Consequences

- Publishing posture cannot be weakened by renaming or refactoring
  fragments without the guard noticing — the check follows the same
  contract-frozen names the publish workflows use.
- Symmetric protection: production profiles cannot lose markers, and dev
  fixtures cannot gain them; `test/publication-guards.bats` mutation cases
  cover both directions, using the `SNOSI_*_GUARD_ROOT` fixture overrides
  ([ADR-0009](0009-snosi-env-var-classes.md)).
- The textual reachability rule means a marker moved into a *new* fragment
  directory is invisible to the guard until the guard learns the directory;
  that is the accepted cost of not reimplementing mkosi's config resolution
  (the tie-breaker for resolution questions stays `mkosi summary`, per
  [ADR-0005](0005-profiles-as-transport-kernel-selectors.md)).
- Creating a profile named like production *is* a publication decision —
  there is no separate "register it for publishing" step to forget.

## Alternatives considered

- **A real Include= resolver:** rejected in the script's own comments — it
  would reimplement mkosi config semantics and drift from them; the
  contract instead freezes the one fragment directory the check must know.
- **A publishable-profiles registry file:** rejected — a second source of
  truth that can disagree with what workflows actually build; names are the
  single shared key.
- **Content-based detection (any profile with SecureBoot=yes is
  production):** rejected — inverts the failure mode: a dev profile gaining
  a marker would become production instead of failing the build.

## References

- Shapes: [native-ab-contracts.md](../native-ab-contracts.md) (§1, §15),
  [design/ci-cd.md](../design/ci-cd.md),
  [design/testing.md](../design/testing.md)
- Implemented by: `check-native-publication-guard.sh`,
  `check-bootc-publication-guard.sh`
- Guarded by: `test/publication-guards.bats`,
  `test/bootc-publication-guard-test.sh`, `.github/workflows/validate.yml`,
  `.github/workflows/nightly-compliance.yml`
- Related: [ADR-0007 — frozen contract with executable form](0007-frozen-contract-executable-allowlist.md)
- Builds on: [core ADR-0014 — single GPG trust root](https://github.com/frostyard/core/blob/main/docs/adr/0014-single-gpg-trust-root.md)
  (the committed pubring the guard requires),
  [core ADR-0015 — os-release image identity](https://github.com/frostyard/core/blob/main/docs/adr/0015-os-release-image-identity.md)
