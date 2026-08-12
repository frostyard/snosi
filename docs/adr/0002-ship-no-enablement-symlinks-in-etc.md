# 0002 — Ship zero unit-enablement symlinks in /etc; presets recreate them at first boot

- **Status:** Accepted
- **Date:** 2026-08-12

## Context

Debian package postinsts enable units by creating symlinks under
`/etc/systemd/system/*.wants/` (and `[Install]` aliases). On an immutable
image those shipped symlinks are a liability: when an admin later runs
`systemctl disable`, systemd deletes an *image-shipped* `/etc` path, and
bootc's three-way `/etc` merge at update finalize breaks on the deletion —
the staged update is discarded while the updater reports success (the
deletion-crash needs a *symlink* counterpart in the new deployment; deleted
shipped regular files merge fine). Independently, systemd only runs
first-boot preset logic when the machine believes it is on first boot.

## Decision

Golden images ship **zero** unit-enablement symlinks under `/etc`.
`shared/outformat/image/finalize/mkosi.finalize.chroot`:

- records every `.wants`/`.requires` entry and `[Install]` alias into
  `/usr/share/snosi/enablement-manifest.txt` (`<scope> <relpath>` lines,
  `LC_ALL=C sort`ed — C collation because the guest-side parity test
  `comm(1)`s against this file), then deletes the symlinks and now-empty
  `.wants`/`.requires` directories;
- writes `uninitialized` into `/etc/machine-id` (an *empty* file merely
  means "generate an ID" and silently suppresses all first-boot semantics),
  so systemd applies presets at first boot and recreates the enablement
  state from `/usr/lib/systemd/*-preset/`.

Four classes are excluded from the manifest (documented in the script):

1. `ctrl-alt-del.target` — not preset-managed; `/usr` ships the same alias;
2. `display-manager.service` — Debian display managers carry no `Alias=`;
   desktop trees ship a static `/usr` alias instead;
3. entries whose target unit is masked (masks in `/etc` or under
   `/usr/lib/systemd`, as the native ab-root tree masks bootc/nbc updaters);
4. dangling entries whose unit is no longer shipped (e.g. systemd 261
   removed `run-lock.mount`).

Masks (`-> /dev/null`) and links whose targets live outside the systemd unit
directories are kept, not stripped. At runtime,
`/usr/libexec/preset-reconcile` (via `preset-reconcile.service`) compares the
shipped manifest against `/var/lib/snosi/enablement-manifest.applied` with
`LC_ALL=C comm`, creates newly-expected enablement, and records removals to
`/var/lib/snosi/preset-removals` without ever auto-disabling.

## Consequences

- `systemctl disable` on a running system touches only admin-created state;
  bootc's `/etc` merge can no longer be broken by enablement churn.
- Enablement becomes declarative and diffable: the manifest is the single
  build-time truth, and `test/tests/05-firstboot-presets.sh` proves parity
  in the booted guest.
- New units enabled by a package update reach existing machines through
  preset-reconcile's create-only pass; *dis*ablement never propagates
  automatically — an operator decision by design, recorded in
  `/var/lib/snosi/preset-removals`.
- The exclusion classes are knowledge that lives in the finalize script's
  comments; a new exclusion class must be added there and mirrored in the
  parity test.
- `machine-id=uninitialized` makes every image boot as a true first boot;
  anything not preset- or tmpfiles-driven will not be set up.

## Alternatives considered

- **Ship the symlinks and forbid `systemctl disable`:** rejected —
  unenforceable against admins, and the failure mode (silently discarded
  update) is the worst in the repo.
- **Empty `/etc/machine-id`:** rejected by regression — empty means
  "generate an ID" only; first-boot semantics stayed off and presets never
  ran (fixed 2026-07).
- **`systemctl preset-all` in a runtime unit instead of first-boot
  semantics:** rejected — runtime enablement mutation is exactly what
  [ADR-0003](0003-runtime-etc-mutation-ban.md) bans; preset-reconcile's
  narrow create-only pass carries an explicit `etc-guard-allow`.

## References

- Shapes: [design/build-pipeline.md](../design/build-pipeline.md)
  (FinalizeScripts), [design/testing.md](../design/testing.md)
  (first-boot preset parity)
- Implemented by:
  `shared/outformat/image/finalize/mkosi.finalize.chroot`,
  `mkosi.images/base/mkosi.extra/usr/libexec/preset-reconcile`
- Guarded by: `test/tests/05-firstboot-presets.sh`,
  `test/bootc-migration-test.sh`
- Related: [ADR-0003 — runtime /etc mutation ban](0003-runtime-etc-mutation-ban.md)
- Builds on: [core ADR-0004 — product-namespaced filesystem tiers](https://github.com/frostyard/core/blob/main/docs/adr/0004-product-namespaced-filesystem-tiers.md)
  (`/usr/share/snosi` and `/var/lib/snosi` tier placement)
