# 0003 — Ban runtime /etc mutation, enforced by scanning payload directories

- **Status:** Accepted
- **Date:** 2026-08-12

## Context

On 2026-07-05, `enable-incus-agent.service` — a shipped unit that disabled
itself via `ExecStartPost=systemctl disable` — was root-caused as the trigger
of bootc (≤ 1.16.3) failing its `/etc` merge with `error: Merging: a path led
outside of the filesystem`: the staged update was silently discarded while
the updater reported success. Any *shipped* code that mutates `/etc`
enablement state or deletes `/etc` paths at runtime can reproduce this class
of failure, and code review alone had already missed one instance.

## Decision

Files that ship inside images may not mutate `/etc` at runtime. The rule is
enforced by `check-runtime-etc-guard.sh` (repo root), which scans **payload
directories** — a classification invented for this guard: every git-tracked
file under `*/mkosi.extra/*`, `mkosi.extra/*`, or `shared/*/tree/*`. These
are exactly the trees copied verbatim into images; build-time scripts
(`*.chroot`, `mkosi.postinst`, `mkosi.finalize`) are deliberately out of
scope because build time is the correct place to set enablement state.

Forbidden in payload files:

- `systemctl`/`deb-systemd-helper` with `disable|enable|revert|unmask|
  preset|preset-all` — `enable` only *creates* symlinks and is merge-safe,
  but is banned anyway: enablement state must be image-defined;
- `rm`/`rmdir`/`unlink`, `mv`, and `find … -delete` targeting `/etc`;
- tmpfiles.d removal types (`r`, `R`, `D`) on `/etc` paths.

Run-once behavior must use a `/var` marker instead:
`ConditionPathExists=!/var/lib/<unit>.done` plus `ExecStartPost=touch …`.

The escape hatch is `# etc-guard-allow: <reason>`, trailing on the offending
line or on the comment line immediately above (unit files cannot carry
trailing comments on directive lines); an above-line allowance exempts
exactly one following line, never a block.

## Consequences

- The incus-agent failure class is structurally closed: the three current
  allowances (`preset-reconcile`, `preset-global.service`,
  `preset-migration.service`) are each a deliberate, reasoned exception
  visible to `grep etc-guard-allow`.
- Adding any shipped file that touches `/etc` at runtime now requires either
  a redesign around `/var` markers and presets, or a written reason at the
  call site — the review conversation happens in the diff.
- The guard is textual: obfuscated invocations (variables, wrappers) evade
  it. It is a tripwire against the common spellings, not a sandbox.
- The "payload directory" classification must be kept in sync if new payload
  roots are added to the repo layout.

## Alternatives considered

- **Review checklist only:** rejected — this exact bug shipped once already
  under review.
- **Runtime enforcement (read-only `/etc`, SELinux):** rejected — `/etc`
  must stay admin-writable on these systems; the ban is on *shipped* code,
  not on administrators.
- **Scanning every file in the repo:** rejected — build-time scripts
  legitimately set enablement state; scanning them would drown the signal
  in allowances.

## References

- Shapes: [design/ci-cd.md](../design/ci-cd.md),
  [design/build-pipeline.md](../design/build-pipeline.md),
  [design/overview.md](../design/overview.md)
- Implemented by: `check-runtime-etc-guard.sh`
- Guarded by: `test/runtime-etc-guard-test.sh`,
  `test/publication-guards.bats`, `.github/workflows/validate.yml`,
  `.github/workflows/nightly-compliance.yml`
- Related: [ADR-0002 — ship no enablement symlinks in /etc](0002-ship-no-enablement-symlinks-in-etc.md)
- Builds on: [core ADR-0005 — marker files and /run update-state contract](https://github.com/frostyard/core/blob/main/docs/adr/0005-native-ab-marker-and-update-state-files.md)
  (the `/var` marker idiom extends the same state-file discipline)
