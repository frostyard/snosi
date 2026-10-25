# 0021 — Query deployment-owned package metadata

- **Status:** Proposed
- **Date:** 2026-10-24

## Context

Bootc preserves /var across image updates. Its persistent dpkg database can
therefore describe an earlier image, while the frozen packages.txt inventory
and running binaries describe the current deployment (#1138). The database
also contains administrator-owned update-alternatives state.

## Decision

After package installation and image cleanup, snapshot the complete dpkg
database into /usr/lib/sysimage/dpkg. Preserve /var/lib/dpkg as persistent
legacy/administrator state; do not replace, rename or migrate its contents
at boot.

Make ordinary dpkg-query use the snapshot through a small wrapper around
the unmodified Debian executable at /usr/libexec/snosi/dpkg-query. Configure
dpkg's default admindir through /etc/dpkg/dpkg.cfg.d/00-snosi-image. Explicit
--admindir/--root options and DPKG_ADMINDIR/DPKG_ROOT query overrides retain
their upstream behavior. Keep update-alternatives on its existing persistent
database and /etc links.

This applies to all four bootc products. Base remains an unwrapped package
build root for sysext builds. The frozen packages.txt API is unchanged.

## Consequences

Fresh installs and existing installations switch query defaults with the
image; two updates and rollback select their corresponding immutable
metadata without runtime state mutation. Scanners that directly open a
database must use /usr/lib/sysimage/dpkg, not the retained /var database.

The snapshot duplicates metadata in each image and finalized images carry
a dpkg-query wrapper. Package installation on the immutable host remains
unsupported. Explicit overrides intentionally bypass the deployment view.
Administrator dpkg config overrides may also change dpkg's selected database.
A rollback to a pre-fix image restores its stale query behavior; the old
persistent database and alternatives remain available throughout.

Fixture tests exercise real dpkg-query, dpkg -l/status and
update-alternatives in isolated roots across three image versions and
rollback. Live fresh-install, two-update and rollback validation remains
required before declaring the deployment contract proven.

## Alternatives considered

- **Move /var/lib/dpkg into /usr and replace it with a symlink:** unsafe as a
  blind existing-install migration; it can hide or discard administrator
  alternatives and other persistent state.
- **Bind mount the immutable database over /var/lib/dpkg:** also hides that
  state and requires additional early-boot mount/migration ordering.
- **Only document packages.txt:** leaves existing dpkg-query consumers stale.

## References

- Shapes: [build pipeline](../design/build-pipeline.md)
- Builds on: [ADR-0001](0001-var-factory-state-outcome-maps.md)
- Issue: [#1138](https://github.com/frostyard/snosi/issues/1138)
