# 0035 — Lodge app sysexts declare user lodge

- **Status:** Proposed
- **Date:** 2026-11-11

## Context

`lodgeapp.LoadEnv` in frostyard/lodge resolves the system user `lodge` at
start, so every Lodge app daemon (`maild --lodge`, `notesd -lodge`,
`porterd`, `readd`) needs that user to exist. The system user is declared by
lodge's own `usr/lib/sysusers.d/lodge.conf`:

```
u lodge - "lodge, the tailnet web shell for frostyard's apps" /var/lib/lodge
```

- maild 0.2.0 and notesd 0.2.0 declared only the GROUP `lodge` in their own
  sysusers.d file. On Snow, with `updex features enable maild notesd --now`
  and without the `lodge` feature, `frostmail.service` crash-looped 72 times
  with `unknown user lodge`, and `frostnotes.service` and
  `frostnotes-lodge.socket` hit their start limits. After a reboot all of
  them passed; the lab record does not prove why.
- `systemd-sysusers` creates no user for a `g` line. A unit whose `User=` or
  `SocketUser=` names a user that no file declares fails at start, and one
  whose `Group=` or `SocketGroup=` names a group that no file declares fails
  the same way.
- The pinned debs now declare the user themselves. notesd 0.4.0, maild 0.5.0,
  porterd and readd each ship the exact line above in
  `usr/lib/sysusers.d/<name>.conf`, byte-identical to lodge's own line
  (`shared/download/sysext-checksums.json`). Lab run
  `dev-snow-bootc-lifecycle-scz5p` (2026-11-08, notesd 0.3.2, maild 0.4.1,
  no `lodge` feature) had all 4 units active in the enable boot with 0
  restarts.
- Nothing in snosi checked this. A pin bump to a deb without the line brings
  the failure back, and review does not read the payload of a downloaded deb
  ([frostyard/snosi#1245](https://github.com/frostyard/snosi/issues/1245)).
- updex 2.1.3 runs `systemd-sysusers` and `systemd-tmpfiles` after
  `systemd-sysext refresh --no-reload` and before the finalizing refresh
  ([updex ADR-0019](https://github.com/frostyard/updex/blob/main/docs/adr/0019-apply-merged-sysusers-and-tmpfiles-on-a-live-refresh.md)),
  the mechanism [ADR-0026](0026-sysexts-with-system-units-reload-the-manager.md)
  relies on. Accounts therefore exist before PID 1 starts the merged units in
  that same enable path.
- The socket failure of the 2026-10-28 run is not reproduced on notesd 0.3.2
  and maild 0.4.1 (lab run `dev-snow-bootc-lifecycle-scz5p`). Its likely cause
  is the same crash loop: the service and its counterpart socket share the
  missing account. That is a likelihood, not a measured fact.

## Decision

A sysext delta must keep the Lodge suite's account contract. The finalizer
`shared/sysext/finalize/sysext-lodge-accounts-guard.sh` enforces it on the
delta (`$BUILDROOT`) of a sysext and fails the build:

1. **The lodge sysext itself:** a delta that ships
   `usr/lib/sysusers.d/lodge.conf` holds that exact line in it.
2. **A Lodge app sysext:** a delta that ships
   `usr/share/lodge/apps/*/app.json` holds that exact line in at least one of
   its own `usr/lib/sysusers.d/*.conf` files. The line is copied byte for
   byte, so the first merge of any suite sysext creates the one account and
   every later merge is a no-op.
3. **Every account a unit names, and no account key in a drop-in:** the
   guard checks each regular `*.service` and `*.socket` file directly under
   `usr/lib/systemd/system`, template units `a@.service` included. It parses
   one file as systemd.syntax(7) reads it: a line whose first non-blank
   character is `#` or `;` is a comment and is dropped, also when it sits
   inside a continued value, and a line that ends with `\` joins the next
   non-comment line with the `\` replaced by a space. Keys count only in their
   own section: `User=`, `Group=`, `SupplementaryGroups=` and `DynamicUser=`
   in `[Service]`, `SocketUser=` and `SocketGroup=` in `[Socket]`. Of the
   scalar keys the last assignment wins and an empty value unsets it;
   `SupplementaryGroups=` accumulates and an empty assignment clears the list.
   The effective `User=`, `SocketUser=`, `Group=`, `SocketGroup=` and each
   `SupplementaryGroups=` entry must be declared by the delta's sysusers.d
   files. A user is declared by a `u` or `u!` line or by the first field of an
   `m` line; a group by a `u`, `u!` or `g` line or by the second field of an
   `m` line. An empty value, `root`, a numeric id and a value with a `%`
   specifier are skipped. An effective `DynamicUser=` of yes, true, 1 or on
   skips only the `User=` and `Group=` checks: systemd creates no
   supplementary groups for a dynamic user either, but a socket's
   `SocketUser=` and `SocketGroup=` do not depend on it.

   The guard does not emulate systemd's drop-in merging, which draws on
   `<unit>.d`, a template's `<template>.d`, a type-wide `service.d` or
   `socket.d`, a prefix directory such as `frost-.service.d`, and the same
   file name in several of them in a precedence order. It fails closed
   instead: every `*.conf` file in every `*.d` directory directly under
   `usr/lib/systemd/system` is read, and any of `User=`, `Group=`,
   `SupplementaryGroups=`, `DynamicUser=`, `SocketUser=` or `SocketGroup=` in
   any section fails the build. An account key belongs in the unit file. A
   drop-in without those keys, such as the `Upholds=` drop-ins under
   `multi-user.target.d`, passes.

The five suite sysexts (lodge, notesd, maild, porterd, readd) wire the script
in `FinalizeScripts=`. `test/sysext-lodge-accounts-guard-test.sh` holds the
fixtures and a repository check: the five suite sysexts wire the guard and
no other sysext does. `test/suite-sysexts-test.sh` checks the wiring too.

The live enable path needs no change: no `systemctl reset-failed` and no updex
change. updex 2.1.3 applies the merged sysusers files before the refresh that
reloads the manager (updex ADR-0019), so the units start once with their
accounts in place. A host where the units already failed before this fix
needs `systemctl reset-failed` for the failed units or one reboot.

## Consequences

- A pin bump to a deb that drops the line, or to one whose units name an
  account it does not declare, fails the sysext build instead of a live
  crash loop.
- The five suite sysexts repeat one line from lodge's deb. A change to that
  line in lodge fails the app builds until they follow, which is the intended
  signal: the account is one account.
- The guard reads the delta only, so it sees the payload the sysext ships. It
  cannot see an account that only the base image declares; such a unit fails
  the build until its own sysusers.d file ships.
- A new Lodge app sysext must add the line, wire the guard and join the
  suite list of `test/sysext-lodge-accounts-guard-test.sh`. The authoring
  contract does not force it, because a sysext without a Lodge app manifest
  does not need it.
- An account key in a drop-in fails the build. The suite debs ship none, so
  nothing fails today. A future need moves the key into the unit file, or
  extends the guard with the merge it needs.
- Host drop-ins in `/etc/systemd/system` or `/run/systemd/system` are out of
  scope: a sysext ships `/usr` only, so the build never sees them.

## Alternatives considered

- **Add `RequisiteFeatures=lodge` to the suite transfers:** core ADR-0058
  keeps every suite transfer free of it, and it would gate the apps on the
  shell instead of making the accounts independent.
- **Rely on the base image's accounts:** the base ships none of the Lodge
  accounts; they belong to the sysexts that use them.
- **Check the deb in `build.yml` with `dpkg -c`:** it inspects the payload
  before the build, but the rule belongs to the composed delta and the same
  check then covers app manifests and unit accounts.
- **Do nothing and document the reboot:** a reboot hides the failure the
  guard exists to catch, and the app stays down until the reboot.

## References

- Shapes: [design/sysexts.md](../design/sysexts.md) ("Attested downloads",
  the lodge, notesd, maild, porterd and readd sections),
  [design/build-pipeline.md](../design/build-pipeline.md)
- Builds on: [ADR-0026](0026-sysexts-with-system-units-reload-the-manager.md)
  (the live refresh order), core ADR-0058 (the suite sysexts), updex ADR-0019
  (sysusers before the manager reload)
- Issue: [frostyard/snosi#1245](https://github.com/frostyard/snosi/issues/1245)
