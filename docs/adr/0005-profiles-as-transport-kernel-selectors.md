# 0005 — Profiles select transport and kernel posture; composition stays shared

- **Status:** Accepted
- **Date:** 2026-08-12

## Context

Each product (cayo, snow, snowfield) ships over two transports — bootc OCI
and native A/B — and the two variants must have identical package
composition or every guest test proves the wrong thing. mkosi has two
properties that make naive profile configs wrong: list settings
*accumulate* (a profile's `Dependencies=` appends to the root
`mkosi.conf`'s), and `Include=` fragments merge list settings in encounter
order.

## Decision

The root `mkosi.conf` declares `Dependencies=base` plus all 22 sysexts, so
the default build produces everything. Every profile then reduces itself to
a transport+kernel selector using the reset idiom — an empty assignment
followed by the single wanted dependency:

```ini
[Config]
Dependencies=
Dependencies=base
```

(the empty assignment is required because mkosi appends collection settings;
without it every profile would rebuild every sysext). All nine profiles
carry the idiom verbatim. Product composition lives in shared fragments
(`shared/composition/<product>/mkosi.conf`) included by both the bootc and
the native profile of a product, so the pair differs only in transport
fragments (`shared/packages/bootc` + `shared/outformat/image` vs
`shared/outformat/ab-root` + `shared/native-ab/channels/<product>`).

`Include=` order inside a profile is load-bearing: the secure posture
fragment comes before the composition fragment so its FinalizeScripts
(disable-nvpcr) resolve before the composition's image finalize — mkosi
accumulates list settings in `Include=` encounter order. The three
production native profiles state this in an identical comment; the arbiter
for any ordering question is a byte-level diff of `mkosi cat-config`/
`mkosi summary` output, not a read of the source files.

`check-profile-dependencies.sh` enforces the reset idiom's outcome for the
bootc profiles (cayo, snow, snowfield): it runs `mkosi summary` per profile
and greps for any forbidden `IMAGE: <sysext>` line.

## Consequences

- One composition fragment per product keeps bootc and native builds
  provably identical in package terms; a package added to a product lands on
  both transports by construction.
- The reset idiom is boilerplate every new profile must copy exactly;
  forgetting the empty assignment silently rebuilds all sysexts (caught by
  the guard for bootc profiles).
- Known enforcement gaps, accepted for now: the guard covers only the three
  bootc profiles, not the six native/installer profiles carrying the same
  idiom; its sysext list is a hand-maintained duplicate of the root
  `mkosi.conf`; and no test asserts the secure-before-composition `Include=`
  order — that ordering is held by the in-profile comments and by
  "verified via `mkosi summary`" review discipline.
- Profile behavior can only be judged from resolved output (`summary` /
  `cat-config`), never from reading fragment files in isolation.

## Alternatives considered

- **Per-profile Dependencies lists (no root list):** rejected — the default
  build is the sysext-publishing build and must stay complete; profiles are
  the exception, not the rule.
- **Duplicating composition per transport profile:** rejected — the two
  transports of a product would drift, and the native test matrix would
  validate a different package set than what bootc ships.
- **A real Include= resolver as the guard:** rejected — `mkosi summary` *is*
  the resolver; the guard greps its output rather than reimplementing mkosi
  config semantics ([ADR-0006](0006-name-triggered-publication-guards.md)
  makes the same choice for the same reason).

## References

- Shapes: [design/overview.md](../design/overview.md) (Configuration
  Composition), [design/build-pipeline.md](../design/build-pipeline.md)
- Implemented by: `mkosi.conf`, `mkosi.profiles/*/mkosi.conf`,
  `shared/composition/*/mkosi.conf`
- Guarded by: `check-profile-dependencies.sh`
  (`.github/workflows/validate.yml`),
  `test/check-profile-dependencies-local-mkosi-test.sh`,
  `test/native-ab-static-test.sh` (Include= presence)
- Builds on: [core ADR-0015 — os-release image identity](https://github.com/frostyard/core/blob/main/docs/adr/0015-os-release-image-identity.md)
  (`ImageId` stays the product name across transports, which is what lets
  composition fragments key off `IMAGE_ID`)
