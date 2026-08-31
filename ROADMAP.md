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

The shipped surface is three image families (`snow`, `snowfield`, and
`cayo`) and a large sysext catalogue, described in [`README.md`](README.md).

## Position: bootc is the transport; native A/B is being phased out

**bootc is the supported transport for snosi, and the native A/B transport is
transitional.** bootc was always the preferred model; the native A/B work was
undertaken while bootc did not yet do what snosi needed. bootc now does, so the
reason for carrying a second transport has expired.

The phase-out window is **60 days, ending 2026-10-28**. During the window both
transports keep working: native A/B images continue to build, publish, and
update, and nothing installed stops receiving updates mid-window. After it,
native A/B is not a supported way to run snosi.

| Transport | What it is | Update origin | Status |
| --- | --- | --- | --- |
| **bootc OCI** | `snow`, `snowfield`, `cayo` — OCI images consumed by bootc | GHCR | **Supported.** The transport snosi is built around. |
| **native A/B** | `snow-ab`, `snowfield-ab`, `cayo-ab` — GPT disk images, EROFS + dm-verity, Secure Boot + TPM/LUKS `/var` | Cloudflare R2 | **Phasing out by 2026-10-28.** Builds and updates during the window; not a supported target after it. |

GHCR is authoritative for bootc OCI images. R2 remains authoritative for
sysexts, raw installer images, and the installer ISO; it is authoritative for
native A/B update payloads only for the duration of the window.

**Do not start new work whose value depends on native A/B outliving the
window.** New capability belongs on the bootc path. Choosing a transport is no
longer a deployment decision with two defensible answers: choose **bootc**.

Two constraints still govern what the phase-out has to do, and the first is the
reason this needs a window rather than a switch. Partition labels, sysupdate
transfer patterns, the entry-token, and the R2 path all carry the channel name
on installed disks, so **a native install migrates by reinstall, never by an
update hop** — every existing native A/B install is a machine someone must
reinstall to reach bootc, and it cannot be moved for them. Separately,
installed bootc systems enforce the `policy.json` baked into the image they are
currently running, so **trust changes must be published to installed systems
before the change that depends on them**.

Those two facts mean the window is not self-executing. Before 2026-10-28 the
project owes native A/B users, at minimum: a stated end-of-updates date for the
R2 native payloads, a documented reinstall path from a native install to the
equivalent bootc image, and a decision on what happens to already-published
native artifacts (freeze in place, or withdraw). Until those exist and are
announced, the window is an intent rather than a plan — see **Near term**.

The historical coexistence design is
[`docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md`](docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md),
and [`docs/plans/2026-07-13-mkosi-native-ab-root-design.md`](docs/plans/2026-07-13-mkosi-native-ab-root-design.md)
still describes replacing bootc with native A/B. Both predate this decision and
now record superseded direction; reconciling their `Status:` lines is tracked
in Near term.

See [`docs/installing.md`](docs/installing.md) to choose an image and verify
media.

## Near term

Work that is designed, has a prerequisite already merged, and is the next thing
worth a contributor's time.

- **Turn the native A/B phase-out into a plan.**
  The decision is made (see the position above); the obligations it creates are
  not yet written down or announced. This is the near-term item that gates the
  others, because every native A/B install is a machine that migrates by
  reinstall and cannot be moved automatically. It needs: a stated
  end-of-updates date for the R2 native payloads, a documented reinstall path
  from each `-ab` variant to its bootc equivalent, a decision on whether
  already-published native artifacts freeze in place or are withdrawn, and a
  user-facing announcement in [`README.md`](README.md) and
  [`docs/installing.md`](docs/installing.md) before anyone installs a native
  image they will have to replace. Until this lands, 2026-10-28 is a stated
  intent rather than a commitment anyone can act on.

- ~~**Reconcile the plan record with the transport decision.**~~ **Done.**
  [`docs/plans/2026-07-13-mkosi-native-ab-root-design.md`](docs/plans/2026-07-13-mkosi-native-ab-root-design.md)
  and
  [`docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md`](docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md)
  are both now marked **Superseded** as of 2026-08-29 and carry banners saying
  so, pointing here and at frostyard/snosi#889 for the obligations that
  replace them.

- **Close the bootc update-validation prerequisites.**
  The bootc update validation plan is blocked on discrete, small prerequisites
  rather than on design. Landing them converts a proposed harness into running
  coverage of the update path. This is now materially more valuable than it was
  when snosi had two transports: it is coverage of the *only* supported update
  path.
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

## Mid term

Designed, deliberately not scheduled. These need a decision before they need
code.

- **Graphical installer (`snosi-setup`) — nice to have, not needed soon.**
  A GTK4/libadwaita kiosk first-run experience over the `snosi-install`
  backend. Phase 1 is merged and the CLI backend is feature-complete, so this
  is buildable whenever someone wants it. It is deliberately *not* near-term
  work. This file previously called it the project's single largest adoption
  lever, on the grounds that "the native transport is the more defensible one
  and is currently gated behind a text installer" — that premise is gone with
  the transport it named. Anyone picking it up should first settle what it
  installs, since it was scoped against the native installer ISO and the
  supported path is bootc. A good contribution, not a blocker for anything.
  → [`docs/plans/2026-07-17-graphical-installer-plan.md`](docs/plans/2026-07-17-graphical-installer-plan.md)

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

- **Fleet-scale update orchestration** — coordinating a fleet (staged rollout,
  health-gated promotion, automatic rollback on a failed boot streak) is
  unaddressed. Previously framed against the native A/B transport; with bootc
  as the single supported transport, the question is what this looks like over
  OCI.
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
- **No dropping bootc.** bootc is the transport. The native A/B experiment is
  ending, not competing (see the position above); proposals premised on native
  A/B as a long-term target are out of scope.

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
