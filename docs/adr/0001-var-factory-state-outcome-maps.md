# 0001 — Classify every build-time /var path in per-product outcome maps, audited fail-closed

- **Status:** Accepted
- **Date:** 2026-08-12

## Context

Native A/B images boot with an empty `/var` partition, while bootc images
carry `/var` state through updates. Whatever a Debian package drops under
`/var` at image-build time therefore has four possible fates, and getting one
wrong is silent: a path that should have been seeded ships broken, a path
that should have been discarded ships stale secrets or caches. Package drift
makes this worse — upstream Debian freely adds, removes, and renames its
`/var` state between releases, and nothing in mkosi flags the change.

## Decision

Every product carries an outcome map, `shared/composition/<product>/
var-outcomes.txt` (`cayo/var-outcomes.txt` for cayo; `snow/var-outcomes.txt`
shared by snow and snowfield), that
classifies every path present under the
buildroot's `/var` into exactly one of four outcomes:

- `image-metadata` — kept in the image's factory state
- `tmpfiles` — recreated at runtime by a tmpfiles.d entry
- `discard` — deliberately dropped
- `installer-seed` — written by the installer after `mkfs` (valid class,
  currently zero entries)

`shared/composition/var-audit.finalize` (a non-chroot mkosi FinalizeScript,
wired from both products' composition `mkosi.conf`) walks `$BUILDROOT/var`
— every file and symlink, plus empty directories — and matches each path
against the map's bash-glob patterns, **first match wins** (the loop breaks
and marks only that pattern used). Matching is `[[ == ]]` string globbing, so
`*` crosses `/`; `**` in the maps is a naming convention only.

The audit fails the build in **both** directions:

- any `/var` path matching no pattern → unclassified, build fails;
- any pattern matching no path → stale glob, build fails.

An unknown `IMAGE_ID` and an invalid outcome token are also hard failures.
On success the audit writes the classified inventory to
`$BUILDROOT/usr/share/snosi/var-inventory.txt` (`LC_ALL=C` sorted), which
`test/native-ab-components-test.sh` asserts in the booted guest.

## Consequences

- Upstream package drift in `/var` cannot land silently: on 2026-08-12,
  Debian's man-db stopped pre-generating `cache/man` and replaced the
  `lib/man-db/auto-update` marker with a directory. The audit failed twice
  in ~2 hours — once as an unclassified path, once as stale globs on the
  builds the first fix was not validated against — and the surviving map
  comments (`cayo/var-outcomes.txt`, `snow/var-outcomes.txt`) record the
  reclassification. Both failure directions earned their keep the same day.
- The cost is symmetric: an unrelated upstream change hard-blocks every
  image build and every open PR until the maps are updated. That is the
  accepted trade — updating a text map is cheap; shipping a misclassified
  `/var` path is not.
- The fail-closed stale check shapes glob style: dual-shape bare-`*`
  patterns (`lib/dpkg*`) are used where two separate globs would make one
  spuriously stale depending on build output.
- The audit script itself has no unit test; validation is the synthetic
  scratch-buildroot recipe in
  [design/overview.md](../design/overview.md#native-var-factory-state-phase-2)
  plus the guest-side inventory assertions.

## Alternatives considered

- **Warn-only audit:** rejected — a warning on a green build is never read;
  both halves of the man-db incident would have shipped.
- **Allowlist only unexpected paths (no full classification):** rejected —
  the value is the forced *decision* per path; an allowlist records
  exceptions without recording intent for the other four hundred paths.
- **One shared map for all products:** rejected — server and desktop
  products legitimately differ (e.g. cayo builds no man-db index; a desktop
  product that ships a non-GNOME session installs none of gdm3, tuned,
  geoclue, gnome-remote-desktop); a shared map would need per-product escapes
  that reintroduce ambiguity. Adding a third product in 2026-08 exercised
  this: it took a new map, not an escape hatch in an existing one.
- **Pathname-expansion globbing (`*` stops at `/`):** rejected — maps would
  need an entry per directory level; string globbing keeps maps short at the
  cost of the documented "`*` crosses `/`" gotcha.

## References

- Shapes: [design/overview.md](../design/overview.md) (Native `/var`
  Factory State), [design/testing.md](../design/testing.md)
- Implemented by: `shared/composition/var-audit.finalize`,
  `shared/composition/cayo/var-outcomes.txt`,
  `shared/composition/snow/var-outcomes.txt`
- Guarded by: the build itself (finalize failure — this is the only
  enforcement that actually runs today);
  `test/native-ab-components-test.sh` (guest-side inventory) is classed
  `unwired` in `test/registry.tsv` and is executed by no workflow, so it
  guards nothing until it is wired (frostyard/snosi#851, #898)
- Builds on: [core ADR-0004 — product-namespaced filesystem tiers](https://github.com/frostyard/core/blob/main/docs/adr/0004-product-namespaced-filesystem-tiers.md)
  (`/usr/share/snosi/var-inventory.txt` lives in the image-lifetime tier)
