# snosi Roadmap

This document states direction: what snosi is committed to, what is being
worked on next, and what has been designed but not scheduled. It is the layer
above the decision and planning records — [`docs/adr/`](docs/adr/) says *why* a
choice was made, [`docs/plans/`](docs/plans/) says *in what order* a piece of
work happens, and this file says *which of those matter next and why*.

It is a statement of intent, not a promise of dates. Nothing here is a
commitment to ship on a schedule.

**Maintainers:** revise this file when a horizon item lands, is abandoned, or
changes horizon. A roadmap that is not revised is worse than no roadmap.

## Where the project is today

snosi builds immutable, bootable Debian Trixie images and `/usr`-only system
extensions. The build system is mkosi, pinned to a repo-local checkout
([ADR-0011](docs/adr/0011-mkosi-bootstrapped-and-pin-shared.md)). Images
publish by digest and are promoted to `latest` only after signature
verification ([ADR-0008](docs/adr/0008-digest-first-release-latest-is-promotion.md)).
Builds run continuously rather than on a named release cadence: GitHub Releases
are a human-facing changelog and download index over signed artifacts, not
milestone gates.

The shipped surface is three image families (`snow`, `snowfield`, `cayo`) and a
large sysext catalogue, described in [`README.md`](README.md).

## Position: two transports, one product line

snosi ships each image family over two transports, and this is deliberate
rather than transitional:

| Transport | What it is | Update origin |
| --- | --- | --- |
| **bootc OCI** | `snow`, `snowfield`, `cayo` — OCI images consumed by bootc | GHCR |
| **native A/B** | `snow-ab`, `snowfield-ab`, `cayo-ab` — GPT disk images, EROFS + dm-verity, Secure Boot + TPM/LUKS `/var` | Cloudflare R2 |

The coexistence design is
[`docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md`](docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md).
GHCR is authoritative for bootc OCI images; R2 is authoritative for sysexts,
native A/B update payloads, raw installer images, and the installer ISO.

**Neither transport is deprecated, and no deprecation is planned.** Choosing
between them is a deployment decision, not a bet on which one survives:

- Choose **bootc** when the host is managed as a container image — existing
  registry tooling, `bootc switch`, rollback via the OCI layer store.
- Choose **native A/B** when the requirement is verified boot end to end —
  dm-verity-sealed root, Secure Boot chain, TPM-bound LUKS `/var`, and updates
  that land in an offline slot.

Two constraints follow from the native A/B design and are unlikely to change:
partition labels, sysupdate transfer patterns, the entry-token, and the R2 path
all carry the channel name on installed disks, so **a native install migrates
to a different channel by reinstall, never by an update hop**; and installed
bootc systems enforce the `policy.json` baked into the image they are currently
running, so **trust changes must be published to installed systems before the
change that depends on them**.

See [`docs/installing.md`](docs/installing.md) to choose an image and verify
media.

## Near term

Work that is designed, has a prerequisite already merged, and is the next thing
worth a contributor's time.

- **Graphical installer (`snosi-setup`) for the native installer ISO.**
  A GTK4/libadwaita kiosk first-run experience driving the existing
  `snosi-install` backend. Phase 1 (installer-owned system settings, deferred
  first-boot provisioning) is merged and the CLI backend is feature-complete
  for everything a frontend needs. Decisions are settled; implementation has
  not started. This is the single largest adoption lever the project has: the
  native transport is the more defensible one and is currently gated behind a
  text installer.
  → [`docs/plans/2026-07-17-graphical-installer-plan.md`](docs/plans/2026-07-17-graphical-installer-plan.md)

- **Close the bootc update-validation prerequisites.**
  The bootc update validation plan is blocked on discrete, small prerequisites
  rather than on design. Landing them converts a proposed harness into running
  coverage of the update path.
  → [`docs/plans/2026-07-03-bootc-update-validation-plan.md`](docs/plans/2026-07-03-bootc-update-validation-plan.md)

- **Guard the plan `Status:` field.**
  Every file in [`docs/plans/`](docs/plans/) now carries a `**Status:**` line
  and a `**Last verified:**` date, and
  [`docs/plans/TEMPLATE.md`](docs/plans/TEMPLATE.md) fixes the vocabulary to
  `Proposed | Planned | In progress | Shipped | Superseded | Abandoned`. That
  `MUST` is documentation only: no `check-*.sh` script and no workflow
  validates it, so the next plan added can silently omit it and the legibility
  just gained decays file by file. The remaining work is one fail-closed guard
  in the style of the existing `check-*.sh` scripts, wired into `validate.yml`.

- **Resolve the coexistence plan's status.**
  The document defining the two-transport arrangement is still **Proposed**
  even though most of what it describes has shipped. The arrangement is real;
  the record should say so, and the parts that were not built should be named
  as dropped rather than left implicitly pending.

## Mid term

Designed, deliberately not scheduled. These need a decision before they need
code.

- **Snosi update/sysext API daemon.**
  Reading [`docs/integration-contracts.md`](docs/integration-contracts.md)
  holistically raises the question of whether updex, pilothouse, chairlift and
  friends should be clients of one snosi-level daemon serving known schemas
  instead of each integrating point to point. Design only; the open question is
  whether the coupling this removes is worth the surface it adds.
  → [`docs/plans/2026-07-20-update-api-daemon-design.md`](docs/plans/2026-07-20-update-api-daemon-design.md)

- **Give contracts an enforced home.**
  [ADR-0007](docs/adr/0007-frozen-contract-executable-allowlist.md) requires a
  frozen contract to have an executable form and a fail-closed allowlist that
  shrinks to empty. Several contract documents currently sit outside
  `docs/specs/` and therefore outside that discipline by default rather than by
  decision.

## Long term / exploratory

Not designed. Listed so the questions are visible rather than rediscovered.

- **Fleet-scale update orchestration** — the native A/B transport updates a
  machine well; coordinating a fleet (staged rollout, health-gated promotion,
  automatic rollback on a failed boot streak) is unaddressed.
- **Broadening the hardware story** — `snowfield` covers Surface devices via
  the linux-surface kernel. Any further hardware family is a new profile plus a
  validation burden, and the criterion for taking one on is not yet written
  down.

## What we are not doing

Stating these saves contributors from proposing them:

- **No non-Debian base.** The build system, package relocation, and every guard
  assume Debian Trixie.
- **No mutable system images.** `/etc` mutation at runtime is banned by
  [ADR-0003](docs/adr/0003-runtime-etc-mutation-ban.md), and sysexts are
  `/usr`-only overlays by [ADR-0004](docs/adr/0004-sysext-authoring-rules.md).
  Features requiring a writable `/usr` are out of scope by construction.
- **No dropping a transport to simplify the matrix.** See the position above.

## Sysext inclusion

The sysext catalogue is the most common place contributors want to add
something, so the bar is stated here rather than decided case by case:

A sysext is a candidate when it is **software a snosi user would otherwise
install into the immutable base**, and it must be:

1. **Expressible as a `/usr`-only overlay** under
   [ADR-0004](docs/adr/0004-sysext-authoring-rules.md) — `/opt` relocated,
   factory-`/etc` capture scoped, activation via `Upholds=`, and a fail-closed
   `required-paths.txt` manifest. Software that cannot meet this is not a
   sysext, regardless of demand.
2. **Verifiably sourced** — an upstream with a stable download URL and a
   checksum or signature the build can verify.
3. **Maintainable without bespoke build logic** — it fits the existing sysext
   build path rather than requiring an exception to it.

Meeting the bar makes something a candidate, not an obligation; each addition
is maintenance the project carries indefinitely.

## Contributing against this roadmap

Near-term items are the best place to start. Issues labelled
`good first issue` and `help wanted` are the curated entry points. Read
[`CONTRIBUTING.md`](CONTRIBUTING.md) first, then `CLAUDE.md` and
[`docs/design/overview.md`](docs/design/overview.md) for the architecture and
operational constraints. The repository's guards fail closed, so a change that
trips one is usually telling you something about the design rather than about
the guard.
