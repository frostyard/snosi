# Prompt: add or change a sysext

Goal: `<what the sysext must provide>`

Read first: `docs/design/sysexts.md`, plus the "Sysext Constraints" section of
`CLAUDE.md`.

Work to do:

1. Create or edit `mkosi.images/<name>/` using an existing sysext as the
   template. Set `KEYPACKAGE=` in its `mkosi.conf`; bump `SYSEXT_REVISION=`
   when republishing a tree-only fix under an unchanged package version.
2. Ship matching `<name>.transfer` and `<name>.feature` files in
   `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.<name>.d/`. Never add them
   to the shared `usr/lib/sysupdate.d/` directory, which is reserved for the
   native A/B OS transfers.
3. List every path the sysext itself ships in
   `mkosi.images/<name>/required-paths.txt`. For `Overlay=yes` images the
   finalize `$BUILDROOT` is the delta, so paths already present in the base
   image must not be listed.
4. Respect the immutable-filesystem rules: `/usr` only. Relocate anything a
   package installs into `/opt` to `/usr/lib/<package>` with symlinks in
   `/usr/bin`. Configs needed in `/etc` are captured into
   `/usr/share/factory/etc` (only the exact paths the tmpfiles rules
   reference) and injected via tmpfiles.
5. For services, ship a `usr/lib/systemd/system/multi-user.target.d/10-<name>.conf`
   drop-in with `Upholds=<name>.service` in addition to the preset — a plain
   `.wants` symlink is dropped at boot because the sysext is not merged yet.
6. For desktop applications, include `shared/sysext/finalize/sysext-strip-icon-cache.sh`
   in `FinalizeScripts=` so no hicolor icon cache leaks into the delta.
7. Any direct download must go through `verified_download()` with a pinned
   URL and an entry in `shared/download/sysext-checksums.json`, plus a check
   in `.github/workflows/check-dependencies.yml` (or `check-packages.yml` for
   APT sentinels).

Validate: `just sysexts` (or a targeted build of the one image), then the
relevant scripts under `test/` and the checks in `.github/workflows/validate.yml`.

Finish by updating `CLAUDE.md` and `docs/design/sysexts.md` if any constraint or
contract changed.
