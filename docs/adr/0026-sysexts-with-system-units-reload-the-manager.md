# 0026 — Sysexts with system units reload the manager

- **Status:** Proposed
- **Date:** 2026-10-30

## Context

`updex features enable incus|coder|nix --now` merges the sysext, but PID 1 does
not start its units in that boot. They start after a reboot (snosi#1189, found
by lab run `dev-snow-bootc-lifecycle-c88m4`).

updex 2.1.3 ([updex ADR-0019](https://github.com/frostyard/updex/blob/main/docs/adr/0019-apply-merged-sysusers-and-tmpfiles-on-a-live-refresh.md))
runs `systemd-sysext refresh --no-reload`, then `systemd-sysusers` and
`systemd-tmpfiles`, then `systemd-sysext refresh --always-refresh=yes`. updex
never runs `daemon-reload` itself. `systemd-sysext` reloads PID 1 only when a
merged extension has `EXTENSION_RELOAD_MANAGER=1` in its extension-release
file. Only the suite sysexts (notesd, maild, lodge, porterd, readd) shipped that
key. Thirteen published sysexts ship system units or system-unit drop-ins in
`/usr/lib/systemd/system` without it: coder, code-server, docker, himmelblau,
incus, k3s, lemonade, nix, pilothouse, podman, sunshine, tailscale and voxtype.
For them PID 1 never loads the new units and drop-ins (including the
`Upholds=` drop-in) in a live refresh.

## Decision

Every sysext whose delta ships an entry under `usr/lib/systemd/system` (a unit,
a drop-in directory or a drop-in) must ship
`usr/lib/extension-release.d/extension-release.<ImageId>` with the exact line
`EXTENSION_RELOAD_MANAGER=1`. User units (`usr/lib/systemd/user`) do not count.

The finalizer `shared/sysext/finalize/sysext-reload-manager-guard.sh` enforces
the rule on the delta (`$BUILDROOT`) of every `Overlay=yes` sysext. It fails the
build when the delta has a system unit entry and the file or the exact line is
missing. A value of `0` or a commented line fails. The authoring contract test
requires the finalizer in every sysext `mkosi.conf`, and
`test/sysext-reload-manager-guard-test.sh` holds the fixtures and a repository
check. The 13 sysexts above ship the file, list it in `required-paths.txt`, and
bump `SYSEXT_REVISION` so that the fix republishes at the same package version.

Lab evidence (frostyard/lab branch `murbella/1189-probe-loadstate`, Snow
`20261029193641`, published sysexts `incus` r5, `coder` r3, `nix` r5,
2026-10-30):

- `dev-snow-bootc-lifecycle-mm4s5` enabled only `incus`, `coder` and `nix`
  with `--now` (each rc 0, all merged). In that boot `multi-user.target` had
  `NeedDaemonReload=yes` and an empty `Upholds=`, and the 9 probed units were
  `inactive (dead)` with no journal entry. After a reboot, `NeedDaemonReload=no`,
  `Upholds=` named the 7 upheld units, and all 9 were active. PID 1 was not
  reloaded: that is the cause.
- `dev-snow-bootc-lifecycle-4hr54` enabled `lodge` first (it ships
  `EXTENSION_RELOAD_MANAGER=1`), then the same 3. In the enable boot the target
  had `NeedDaemonReload=no` and `Upholds=` with the 7 units, and all 9 units
  and `lodge.service` were active and settled (`PASS: verified_sysext_probe`).
  A merged key makes `systemd-sysext` reload PID 1 at the next refresh, and the
  units start in the same boot.

The run used the published sysexts, which do not yet have the key. A rerun of
the first run with the republished revisions is the check after merge.

## Consequences

- A first enable with `--now` starts the units in the same boot for every
  sysext with system units, as for the suite sysexts.
- A refresh now reloads PID 1 for these sysexts. A reload restarts no running
  unit, so a running daemon keeps its old binary until it restarts.
- A new sysext with a system unit fails its build until the author adds the
  file. The cost is one 11-line file per sysext.
- The 13 sysexts republish once (a `SYSEXT_REVISION` bump each). Remove each
  revision when its package version bumps.
- The guard checks the delta. A sysext that gets its first system unit from a
  package update is caught at build time, not at review time.

## Alternatives considered

- **Document a reboot after the first enable:** it leaves `--now` with a
  misleading name, and the suite sysexts already work without a reboot.
- **Let updex run `daemon-reload`:** updex ADR-0019 rejected it. The reload is
  `systemd-sysext`'s job, and it already has the key for it.
- **A base-shipped flag extension:** a separate always-merged extension with
  the key would reload on every merge, but it adds a moving part to base and
  hides the dependency from each sysext. The per-sysext key is explicit and
  testable.

## References

- Shapes: [design/sysexts.md](../design/sysexts.md) ("When a sysext update takes
  effect", "Service Activation Pattern (Upholds=)"),
  [design/build-pipeline.md](../design/build-pipeline.md)
- Builds on: [ADR-0024](0024-verify-attestations-of-first-party-sysext-debs.md)
  (the suite sysexts), core ADR-0058 (the suite sysexts and `reload-sysext.service`),
  updex ADR-0019 (the refresh order).
