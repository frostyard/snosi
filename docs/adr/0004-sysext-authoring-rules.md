# 0004 — Sysexts are /usr-only overlays with fail-closed structural manifests

- **Status:** Accepted
- **Date:** 2026-08-12

## Context

The 22 sysexts are EROFS overlays merged onto an immutable base at runtime
(`Format=sysext`, `Overlay=yes`, `BaseTrees=%O/base`). Three facts constrain
how they must be authored: sysexts can only provide files under `/usr`;
PID 1 scans unit files *before* any sysext is merged; and the buildroot's
`/etc` during a sysext build is the merged base view, containing secrets.
Each constraint was violated once before being turned into a rule — most
expensively on 2026-07-01, when the published incus sysext
(`1+7.2-debian13-202607011055`) shipped without its entire
incus-base/incus-client payload: no incusd, no CLI, no units, and no check
noticed.

## Decision

Sysexts follow five authoring rules:

1. **Payloads are `/usr`-only.** Packages that install to `/opt` are
   relocated to `/usr/lib/<pkg>` in the image's postinst chroot script, with
   `/usr/bin` symlinks, `patchelf --set-rpath` where libraries reference
   `/opt` paths (patchelf purged afterward so it does not ship), and
   SUID/capability restoration (`chmod 4755` on chrome-sandbox binaries,
   `setcap` where needed). `/opt` itself must stay: it is the mountpoint for
   `opt.mount`, whose bind to `/var/opt` shadows anything left there.
2. **`/etc` defaults are captured into `/usr/share/factory/etc` only for the
   exact paths the sysext's tmpfiles.d entries reference** — enumerated
   per-path in each `mkosi.finalize` (e.g. incus's `FACTORY_PATHS` array).
   Never all of `/etc`: the buildroot `/etc` is the merged base view, so a
   full capture ships `/etc/shadow` and the SSH host keys generated during
   the base build (frostyard/snosi#282, found in the 2026-07-01 audit).
3. **Services activate via a shipped drop-in
   `/usr/lib/systemd/system/multi-user.target.d/10-<name>.conf` carrying
   `Upholds=`**, not `.wants` symlinks: PID 1 scans unit files before the
   sysext is merged, so a `.wants` symlink into the sysext dangles at scan
   time and is silently dropped, and merging later does not re-trigger the
   dropped `Wants=`. `Upholds=` is re-evaluated continuously, so it fires
   once the merge lands. (Deliberate non-adopters — pure desktop apps,
   sunshine — are documented in design/sysexts.md.)
4. **Every sysext declares `required-paths.txt`**, checked fail-closed by
   `shared/sysext/finalize/sysext-required-paths.sh` (wired via
   `FinalizeScripts=` in all 22 sysext configs): a missing manifest fails
   the build, and any listed path missing from the output fails the build
   ("refusing to produce a broken extension"). Because `Overlay=yes` makes
   `$BUILDROOT` the *delta*, base-image paths must not be listed.
5. **Every sysext delta is checked for `/var` and `/opt` payloads** by
   `shared/sysext/finalize/sysext-usr-only.sh`. Empty root mountpoint
   directories are permitted, but any entry below them fails the build with
   the offending path. The check never follows symlinks outside the delta.

## Consequences

- The 2026-07-01 failure class is closed structurally: an empty or
  mis-assembled payload cannot be published, because its manifest paths are
  absent. The sibling `SYSEXT_REVISION` (+rN) mechanism exists because
  publish-time `skip-duplicates` keyed on version meant tree-only fixes
  never republished.
- Relocation scripts are per-package boilerplate that must be re-derived for
  each new `/opt`-installing vendor package; the pattern is documented in
  design/build-pipeline.md.
- Factory capture is deliberately verbose (one path per line) so that review
  sees exactly which `/etc` bytes ship; scoped subtrees owned by the package
  (e.g. `/etc/1password`, `/etc/nix`) are acceptable, whole-`/etc` capture
  never is.
- `/usr`-only is enforced before artifact production: stray `/var` or `/opt`
  entries fail the shared finalize guard, while required-paths manifests prove
  that each sysext's expected `/usr` payload is present.

## Alternatives considered

- **Enable services with `.wants` symlinks in the sysext:** rejected —
  dangles at PID-1 scan time and is silently dropped (observed; recorded in
  design/sysexts.md with the docker `-H fd://` socket-activation variant).
- **Capture all of `/etc` to factory:** rejected — shipped `/etc/shadow`
  and SSH host keys in a published artifact (frostyard/snosi#282).
- **Leave packages in `/opt`:** rejected — sysexts cannot ship `/opt`, and
  the `opt.mount` bind shadows it at runtime anyway.
- **Content tests in QEMU instead of build-time manifests:** rejected as the
  only line of defense — the guest tiers exist, but the manifest fails the
  build before an artifact exists to publish, with no boot required.

## References

- Shapes: [design/sysexts.md](../design/sysexts.md),
  [design/build-pipeline.md](../design/build-pipeline.md) (Package
  Relocation)
- Implemented by: `shared/sysext/finalize/sysext-usr-only.sh`,
  `shared/sysext/finalize/sysext-required-paths.sh`,
  `mkosi.images/*/required-paths.txt`, `mkosi.images/*/mkosi.finalize`,
  `shared/packages/*/mkosi.postinst.d/*.chroot`
- Guarded by: `test/sysext-required-paths-test.sh`,
  `test/sysext-usr-only-test.sh`, and
  `test/sysext-authoring-contract-test.sh`
  (`.github/workflows/validate.yml`), `test/pilothouse-sysext-test.sh`
- Builds on:
  [core ADR-0007 — sysext filename pattern](https://github.com/frostyard/core/blob/main/docs/adr/0007-frostyard-sysext-filename-pattern.md),
  [core ADR-0008 — sysext distribution and update contract](https://github.com/frostyard/core/blob/main/docs/adr/0008-sysext-distribution-and-update-contract.md)
