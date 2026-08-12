# 0009 — SNOSI_* variables come in three classes; security-relevant test hooks are mutually gated

- **Status:** Accepted
- **Date:** 2026-08-12

## Context

Roughly 75 `SNOSI_*` environment variables have accumulated across build
scripts, guards, and shipped binaries. Many exist only so tests can inject
fixtures — and an env var is the easiest thing in a CI system to set by
accident or leave exported. A single stray variable must never be able to
weaken a production build or a shipped binary's security posture. This ADR
is the first written statement of the classification, which previously
existed only as scattered per-script comments.

## Decision

`SNOSI_*` variables fall into three classes, with different rules:

1. **Build inputs** — production-meaningful settings (`SNOSI_BOOTC_SECURE`,
   `SNOSI_BOOTC_MOK_KEY/_CERT`, `SNOSI_BOOTC_PCR_KEY/_CERT`,
   `SNOSI_NATIVE_AUTOSTAGE`, `SNOSI_REQUIRE_GPT_AUTO_VALIDATION`, …). These
   are documented where consumed, validated at the consumer (unset or
   malformed is fatal on secure paths), and explicitly forwarded across the
   sudo boundary by name
   ([ADR-0010](0010-credential-handoff-paths-not-bytes.md)).
2. **Guard-root overrides** — exactly the `SNOSI_*_GUARD_ROOT` family
   (bootc/native publication, runtime-etc, duplicate-packages). They
   redirect *what a guard inspects* so mutation-fixture tests are possible;
   they cannot weaken production because pointing a guard at a fixture repo
   changes the check's subject, not the shipped artifact.
3. **Test hooks** — undocumented by design (absent from `--help`), never
   present on a real target machine, and where a hook can weaken a security
   property it must be **paired or mutually gated** so one stray variable
   is inert:
   - `snosi-etc-diff` relaxes its `EUID==0` requirement only when **both**
     `SNOSI_ETC_DIFF_LIVE_ETC` and `SNOSI_ETC_DIFF_PRISTINE_ETC` are set;
     either alone changes nothing.
   - `buildah-package.sh` rejects `SNOSI_BOOTC_SECURE_TEST_ASSEMBLER`
     unless `SNOSI_BOOTC_SECURE_TEST_HOOKS=1`, rejects hooks=1 without an
     assembler, and rejects any hooks value other than 0/1 (no
     truthy-string bypass).

   Hooks that only substitute inert inputs (fixture paths such as
   `SNOSI_INSTALL_LSBLK_JSON`, `SNOSI_TEST_*` tool paths) may stand alone;
   the pairing requirement applies where a hook alone would relax a check.

## Consequences

- The threat model "one exported variable left over from a test run" is
  addressed at the two places where it could bypass a security property;
  new hooks with that power must copy the pairing pattern.
- Class-2 overrides are what make the guards testable at all
  ([ADR-0006](0006-name-triggered-publication-guards.md)'s mutation
  fixtures); keeping them read-target-only preserves that safety argument.
- Known gap, accepted: no test currently exercises the assembler/hooks
  rejection branches themselves — the suites always set the pair together.
  A regression that dropped the mutual gate would not be caught by CI
  today.
- Undocumented-by-design means test hooks impose no compatibility
  obligation; anything documented in `--help` graduates to class 1 and
  acquires one.

## Alternatives considered

- **A single `SNOSI_TEST_MODE=1` master switch:** rejected — one variable
  that relaxes everything is exactly the stray-variable hazard, and its
  blast radius grows with every hook added under it.
- **Documenting all hooks:** rejected — documentation implies support;
  hooks exist to be reshaped freely by the tests that own them.
- **Config files instead of env vars for hooks:** rejected — the hooks must
  work inside QEMU guests and fixture chroots where placing files is the
  expensive operation and env is the cheap one.

## References

- Shapes: [design/build-pipeline.md](../design/build-pipeline.md)
  (snosi-etc-diff hooks), [design/overview.md](../design/overview.md)
  (installer test hooks), [design/testing.md](../design/testing.md)
- Implemented by:
  `mkosi.images/base/mkosi.extra/usr/bin/snosi-etc-diff`,
  `shared/outformat/image/buildah-package.sh`,
  `check-*-guard.sh` / `check-duplicate-packages.sh` (guard roots)
- Guarded by: `test/snosi-etc-diff-test.sh`,
  `test/publication-guards.bats` (guard-root usage)
- Related: [ADR-0006](0006-name-triggered-publication-guards.md),
  [ADR-0010](0010-credential-handoff-paths-not-bytes.md)
- Builds on: [core ADR-0019 — governance as code and risk tiers](https://github.com/frostyard/core/blob/main/docs/adr/0019-governance-as-code-and-risk-tiers.md)
