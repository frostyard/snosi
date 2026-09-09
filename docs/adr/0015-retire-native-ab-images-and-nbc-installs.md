# 0015 — Retire the native A/B images and nbc installs on 2026-09-30

- **Status:** Accepted
- **Date:** 2026-09-08

## Context

Snosi ships two transports for the same three products. The bootc/composefs
OCI images (`floe`, `snow`, `snowfield`) are the path the installer (Firn,
core ADR-0031), the update stager, the signature policy, and the secure
Secure Boot work all build on. The native A/B images (`floe-ab`, `snow-ab`,
`snowfield-ab`) are a parallel systemd-sysupdate transport with its own
publication pipeline, installer ISO lane, MOK/PCR credential handling,
capacity contracts, and QEMU harnesses. Hosts installed with `nbc`, the
interim A/B partition installer that predates bootc, are a third population:
they run the bootc OCI images but have no bootc deployment state
(`spec.image: null`), and cannot be converted to bootc in place
([nbc-to-bootc-migration.md](../nbc-to-bootc-migration.md)).

Every fix that touches update UX, notification units, `/etc` handling, or
kernel arguments has had to land in both transports, and this repository's
own history records six defects caused by a fix landing in one sibling path
and not the other (see the `test/lib/bootc-secure-assertions.sh` note in
`CLAUDE.md`). The native A/B publication lane also holds the only production
MOK/PCR signing flow, doubling the credential surface that has to be rotated
and audited.

Installed native A/B and nbc hosts have no in-band signal that their
transport is going away: the update stager reports `current`, the desktop
stays quiet, and nothing on a headless login says otherwise.

## Decision

The native A/B images (`floe-ab`, `snow-ab`, `snowfield-ab`) and nbc-based
installations reach end of life on **2026-09-30**. After that date they will
no longer receive updates, and their publication lanes may be removed.
Continued support is provided only by the bootc variants; affected hosts must
be backed up and reinstalled with a bootc image.

Every affected host tells its users so, from the next published image
onward, through one shared notice:

- `/usr/libexec/snosi-eol-notice` (base `mkosi.extra`, so it ships in every
  image and reaches both populations by their existing update path) is the
  single owner of the detection predicate and the wording. It prints the
  notice when `/usr/lib/snosi/native-ab` exists (native A/B) or when the
  kernel command line has no `composefs=` and `/run/ostree-booted` is absent
  (nbc; every supported bootc install is a composefs deployment, and the
  ostree check keeps an ostree-backend bootc deployment out). It is silent
  in containers and on every bootc install, and it flips from "reaches" to
  "reached" after the date.
- `/etc/update-motd.d/80-snosi-eol` execs the helper on every headless,
  SSH, and console login.
- `snosi-eol-notify.service` (user scope, static
  `graphical-session.target.wants/` link, no `[Install]`,
  `ConditionKernelCommandLine=!composefs` pre-filter) runs
  `/usr/libexec/snosi-eol-notify`, which raises one critical-urgency desktop
  notification per user, ack-gated on a notice ID so it never repeats.
- `snosi-update-status` prints the same notice ahead of its update summary.

The notice is the user's requested sentence verbatim: "These images will no
longer receive updates. Please backup and install the bootc variants for
continued support."

## Consequences

- Native A/B and nbc users get a persistent motd line and a one-time desktop
  toast without any change to how updates flow; the notice rides the last
  regular updates before the date.
- The wording and predicate exist in exactly one shipped file;
  `test/eol-notice-test.sh` (validate.yml) fails if a consumer grows its own
  copy, and it pins the predicate against fixture command lines, the
  ostree-booted exclusion, and the container guard.
- Re-notifying every user after a wording change requires bumping
  `NOTICE_ID` in `snosi-eol-notify`; the motd hook needs nothing.
- Removal of the native A/B publication lane, `build-native-images.yml`,
  the ab-root output format, the native harnesses, and the nbc timer units is
  deferred to a follow-up after the date; this ADR only fixes the date and
  the notice. Until that removal lands, the native contracts and tests keep
  running unchanged.
- The installer ISO still offers the native A/B path; `docs/installing.md`
  now marks it deprecated. Removing it from Firn is a Firn-side change.

## Alternatives considered

- **A stager-level `outcome=eol` state:** would reuse the existing motd and
  notify consumers, but only fires when the hourly timer runs, which the
  native timer does not on publication-disabled builds, and nbc hosts run no
  Snosi stager at all. A direct predicate on shipped state covers both.
- **A `PathExists=` path unit or `ConditionPathExists=` on the marker
  alone:** cannot express "native OR nbc" without a level-triggered path
  condition (forbidden by the 2026-08-26 trigger-limit root cause) or two
  units; one oneshot with a cheap `!composefs` pre-filter and the full
  predicate in the shared helper is simpler.
- **Editing `/etc/motd` at build time:** static text cannot distinguish nbc
  hosts from bootc hosts running the same OCI image, and per-image text
  would fork the wording across trees.

## References

- Shapes: [design/build-pipeline.md](../design/build-pipeline.md) (update
  state consumers), [installing.md](../installing.md),
  [nbc-to-bootc-migration.md](../nbc-to-bootc-migration.md)
- Builds on: [ADR-0013](0013-no-requiredby-enablement-prune-stale-requires.md)
  (static-wants activation, no `RequiredBy=`), core ADR-0031 (Firn owns
  installs)
- Enforced by: `test/eol-notice-test.sh`
