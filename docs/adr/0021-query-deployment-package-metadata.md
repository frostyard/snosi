# 0021 — Query deployment-owned package metadata

- **Status:** Accepted
- **Date:** 2026-10-25

## Context

Bootc preserves `/var` across image updates. Its persistent dpkg database can
therefore describe an earlier image, while the frozen packages.txt inventory
and running binaries describe the current deployment (#1138). apt,
PackageKit and python-apt read `/var/lib/dpkg/status` through libapt; scanners
also open that path directly. Redirecting only dpkg queries leaves these
consumers stale. The database also contains administrator-owned alternatives
and other mutable state that must survive updates.

## Decision

After package installation and image cleanup, snapshot the complete dpkg
database into `/usr/lib/sysimage/dpkg`. Ship base tmpfiles `L+` rules that
maintain links from these `/var/lib/dpkg` entries to the same names in that
immutable snapshot: `status`, `info`, `triggers`, `diversions`, `available`,
and `arch-native`. Normal boot tmpfiles processing replaces old files and
populated identity directories and repairs links on later boots.

Keep `/var/lib/dpkg` itself a real directory. Leave `alternatives/`,
`statoverride`, `lock*`, `updates/` and `parts/` as real writable state.
Keep Debian's query binaries and compiled-in database defaults unchanged;
no wrapper, binary diversion or dpkg configuration override is needed.
All consumers of the standard paths, including apt, PackageKit, python-apt
and direct-file scanners, see the deployment's identity after tmpfiles runs.

This applies to all four bootc products. The base build root remains a
normal writable package database while building sysexts; only completed
products receive the snapshot. The frozen packages.txt API is unchanged.

## Consequences

Fresh installs and existing installations converge on the same link layout.
Updates and rollbacks between fixed images select the corresponding snapshot
through the unchanged absolute link targets. Administrator alternatives
choices persist, and update-alternatives can still install and select entries.
The snapshot duplicates metadata in each image.

There are two explicit transition/administration caveats:

1. Rollback across the transition to a pre-fix image leaves dangling links,
   because that image has no `/usr/lib/sysimage/dpkg`. On that older deployment
   dpkg-query reports no packages and apt lists none until rolling forward
   to a fixed image. This affects only rollback across the transition.
2. An administrator's `dpkg-divert --add` can replace the `diversions` symlink
   with a real file. The next tmpfiles run restores the link and discards
   that local diversion metadata. Mutable host package changes are unsupported;
   immutable identity/triggers also prevent normal dpkg configuration.

The accepted layout decision does not establish live lifecycle acceptance.
Fixtures exercise real tmpfiles, dpkg, apt and update-alternatives in isolated
roots, including two updates, rollback, a populated old database and repeated
tmpfiles runs. Live fresh-install, two-update and rollback validation remains
required before declaring the deployment contract proven.

## Alternatives considered

- **Link the whole `/var/lib/dpkg` directory:** hides administrator alternatives
  and other writable state. Per-file links avoid that loss.
- **Wrap dpkg-query and configure dpkg's admindir:** leaves apt, PackageKit,
  python-apt and direct-file scanners stale; replacing the packaged binary
  also fails dpkg's integrity verification.
- **Bind mount the complete immutable database:** hides mutable state and
  adds early-boot mount ordering.
- **Only document packages.txt:** leaves standard package-query consumers stale.

## References

- Shapes: [build pipeline](../design/build-pipeline.md)
- Builds on: [ADR-0001](0001-var-factory-state-outcome-maps.md)
- Issue: [#1138](https://github.com/frostyard/snosi/issues/1138)
- Design review: [PR #1149](https://github.com/frostyard/snosi/pull/1149#pullrequestreview-5641414745)
