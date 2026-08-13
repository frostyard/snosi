# 0013 — Never ship RequiredBy= enablement; prune stale .requires in the initrd

- **Status:** Accepted
- **Date:** 2026-08-12

## Context

First boot's preset pass materializes shipped units' `[Install]` sections
into the persistent `/etc` (the overlay upper on `/var` for native A/B —
ADR-0002's manifest/preset pipeline recreates exactly what the image's
`/etc` no longer carries). That state outlives the image that created it:
nothing removes it when a later image retires the unit
(`preset-reconcile.service` deliberately never disables, and the drift
report only observes).

The two `[Install]` enablement kinds fail very differently when their
target unit disappears from a later image:

- a dangling `.wants` link is silently tolerated by systemd;
- a dangling `.requires` link becomes a `Requires=` on a unit that fails
  to load, which invalidates PID 1's very first transaction — the start
  of `default.target`. The machine dies at **"Failed to isolate default
  target"** before any service runs and before the journal can persist.
  No runtime cleanup can ever fire, because the failure precedes all
  units.

This happened live on 2026-08-12: `e08311f` retired
`snow-linux-live-setup.service`, whose `[Install]` carried
`RequiredBy=multi-user.target` and `RequiredBy=display-manager.service`.
Image `20260812205454` then failed all three counted boots on an enrolled
snow-ab machine (systemd-boot fell back to the previous slot, UKI left at
`+0-3`), while fresh installs — including every CI boot-smoke and QEMU
harness, which first-boot the *new* image's presets — booted fine. Every
existing desktop install first-booted before the retirement was bricked
out of all future updates until its stale links were removed.

Debian packages can also ship `RequiredBy=` units, and packages get
dropped from images, so a repo-authoring rule alone cannot close the
class.

## Decision

Two complementary mechanisms:

1. **Shipped units must not use `RequiredBy=` enablement, and payload
   trees must not ship `*.requires/` links.**
   `check-required-by-guard.sh` (wired into `validate.yml`, fixtures in
   `test/required-by-guard-test.sh`) fails the build on either, scanning
   the same payload boundary as `check-runtime-etc-guard.sh`
   (`mkosi.extra/`, `shared/**/tree/`). Hard startup dependencies belong
   in the *dependent* unit's `[Unit] Requires=`/`BindsTo=`, or in the
   static-wants pattern — both live in `/usr` and update atomically with
   the image. Escape hatch: `# requiredby-guard-allow: <reason>`.
   This is org policy: frostyard/core ADR-0030.

2. **The native A/B initrd prunes stale `.requires` links defensively.**
   `snosi_prune_stale_requires` (`shared/outformat/ab-root/tree/usr/lib/
   dracut/modules.d/95etc-overlay/etc-overlay-prune.sh`, called by
   `etc-overlay-mount.sh` after mounting `/var`, before assembling the
   `/etc` overlay) removes any `.requires` symlink in the persistent
   upper whose unit name resolves nowhere in the booting image's search
   path (image `/usr`, image `/etc` lower, the upper itself; template
   instances fall back to their template; masks count as existing).
   Pruned entries are logged and recorded best-effort in
   `/run/snosi/etc-requires-pruned`. This covers the package-shipped
   `RequiredBy=` case the static guard cannot see, and retroactively
   heals installs already carrying stale links.
   Fixtures: `test/etc-overlay-prune-test.sh`; wiring pinned by
   `test/native-ab-static-test.sh`.

The prune scope is **`.requires` only, never `.wants`**: dangling Wants
are harmless, and sysext-provided units are legitimately absent from the
pristine root at initrd time — pruning wants would silently disable every
enabled sysext service. Anything the prune removes named a unit absent
from every loadable location, so if PID 1's initial transaction reached
it the boot was already lost; pruning strictly converts a bricked boot
into a booting system minus an unsatisfiable dependency.

## Consequences

- Retiring any unit — repo-authored or package-shipped — can no longer
  brick installed native A/B machines through persisted enablement.
- Units genuinely needing hard membership in a target express it in the
  dependent direction, which is also where systemd upstream puts it.
- The rare intentional case (a sysext unit hard-requiring another sysext
  unit via admin `systemctl enable` of a `RequiredBy=` install) loses its
  hard edge on the boot where the providing sysext's unit is absent from
  the pristine root **only if** that unit also resolves nowhere else;
  this combination was already boot-fatal before the prune existed, so no
  working configuration regresses.
- bootc profiles get the static guard but not the prune (their `/etc`
  merge is bootc's, not the overlay module's); the same hazard there
  still needs the guard to hold.
- Existing bricked-update installs (snow-ab/snowfield-ab first-booted
  before `e08311f`, offered `20260812205454`) heal on their first update
  to an image carrying the prune; the one already-published bad image
  remains unbootable for them and needs manual link removal or the next
  release.

## Alternatives considered

- **Re-ship a no-op stub of every retired unit:** works but accretes
  permanent unit-name cruft, must be remembered per retirement, and a
  `/dev/null` mask variant does not work at all (starting a masked
  required unit also fails the transaction).
- **Runtime migration service:** cannot work; the failure precedes all
  services.
- **Prune `.wants` too:** rejected — see scope rationale above.
- **Guard only, no prune:** leaves package-shipped `RequiredBy=` units
  and already-persisted state as live landmines.

## References

- Shapes: [design/overview.md](../design/overview.md) (native A/B /etc
  overlay), `shared/outformat/ab-root/tree/usr/lib/dracut/modules.d/95etc-overlay/`
- Builds on: [ADR-0002](0002-ship-no-enablement-symlinks-in-etc.md),
  [ADR-0003](0003-runtime-etc-mutation-ban.md)
- Org policy: [frostyard/core ADR-0030](https://github.com/frostyard/core/blob/main/docs/adr/0030-no-requiredby-enablement-in-shipped-units.md)
- Incident: `.memory/corrections.jsonl` 2026-08-12 entry; commit
  `e08311f`; failed image `20260812205454`
