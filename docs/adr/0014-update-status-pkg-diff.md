# 0014 — `snosi-update-status --pkg-diff` diffs local deployments from packages.txt

- **Status:** Proposed
- **Date:** 2026-09-07

## Context

Operators coming from Fedora bootc/Silverblue run `rpm-ostree status -v` (or
`rpm-ostree db diff`) and see which RPMs a pending deployment will add,
remove, or upgrade. Snosi already answers "is this machine current?" via
`snosi-update-status`, `bootc status`, and the `/run/snosi/update-*`
semaphores, but it never shows a package delta. GitHub Releases do, and only
for Snow: `frostyard/changelog-generator` diffs Cosign-signed Syft SBOMs
between tags. That is a web page, not an on-device CLI, and it is not a
Debian package list (Syft also emits Go modules from binaries).

The inventory the CLI would need is already on every image.
[core ADR-0003](https://github.com/frostyard/core/blob/main/docs/adr/0003-image-provenance-in-usr-share-frostyard.md)
puts `/usr/share/frostyard/<IMAGE_ID>.packages.txt` (`apt list --installed`
format, name and version) in `/usr` so a changelog tool can answer "what is
in this image?" without the registry. `packagediff.sh` consumes that file
today, but it is a repo-root dev tool, it compares a build manifest against
the *running* host, and it throws versions away.

The dpkg database is the wrong second source. Native A/B relocates it to
`/usr/lib/sysimage/dpkg` so `dpkg-query` only sees the booted slot. Bootc
leaves `/var/lib/dpkg` on persistent `/var`, so after the first update
`dpkg -l` is the *install-time* set, not the running image. ADR-0003 already
rejected it as a diff surface.

A second list is also not free to obtain. After `bootc switch`/`upgrade`,
`bootc-update-stage` copies the tree into composefs and `podman image prune
-f`, so the staged image is often gone from containers-storage. Native A/B
keeps the other root as an EROFS partition labeled `<ImageId>_<version>_r`
(verity, not LUKS; `/var` is the LUKS volume), which *is* still on disk.
Neither transport ships `oras` or `cosign`, so the GHCR Syft referrer is not
an on-host fetch. Bootc's R2 `manifests/` upload is unsigned and not a
documented public contract.

Default `snosi-update-status` is a fast local-state read. A package diff can
be hundreds of lines on a kernel/GNOME bump and, on bootc, needs work at
stage time. It cannot be the unflagged output.

## Decision

`snosi-update-status` gains `--pkg-diff`. The unflagged command is unchanged.
`--pkg-diff` prints the usual status block, then a Debian-package delta
between the running image and a *local* second deployment, in the shape of
`rpm-ostree db diff`:

```text
Upgraded:
  libde265-0 1.0.15-1+deb13u1 -> 1.0.15-1+deb13u2
Added:
  …
Removed:
  …
```

Combinable with `--check`. `--check` still compares published *versions*
only. Fetching a remote package list is a later decision, not this one.

### Inventory

Both sides of the diff are `apt list --installed` text, the format frozen by
core ADR-0003. The running side is always
`/usr/share/frostyard/<IMAGE_ID>.packages.txt` from the booted `/usr`.
Parse `name/now version …`; skip the `Listing...` header. Compare by package
name. Version ordering uses `dpkg --compare-versions` (the dpkg *database*
is not read). Equal versions are omitted. A version that sorts higher in
the new image is `Upgraded:`; one that sorts lower is `Downgraded:`. Do not
fold both into a single "Changed" section.

One parser, used by both backends. Not a copy in `native_status()` and
`bootc_status()`.

Sysext contents are not image packages and are out of scope. Syft language
packages are out of scope.

### When there is no second list

If nothing is staged (bootc: no staged deployment and no semaphore; native:
`systemd-sysupdate pending` is false and no semaphore), print the status
block, then one line that nothing is staged to diff, and exit 0. Do not hit
the network. Do not invent a rollback diff.

Post-reboot rollback diffs (`rpm-ostree status -v` against the previous
deployment after it has become rollback) are deferred. `/run` is gone after
the applying reboot, which is correct for a staged delta.

### Bootc staged list

`bootc-update-stage` extracts the pulled image's
`/usr/share/frostyard/<IMAGE_ID>.packages.txt` *before* the post-stage
`podman image prune -f` and writes it to `/run/snosi/staged-packages.txt`
(mode 0644, root-owned, same lifetime as `update-staged`). The copy is the
staged image's file bytes, not a regenerated `apt list`.

This file is a new sibling under `/run/snosi/`. It is not a field of
`update-check` or `update-staged` (those stay small `key=value` files;
motd and `bootc-update-notify` must not grow a package list). It is
snosi-owned. It does not amend
[core ADR-0005](https://github.com/frostyard/core/blob/main/docs/adr/0005-native-ab-marker-and-update-state-files.md)
until a second consumer needs it.

If bootc reports a staged deployment but the sidecar is missing (manual
`bootc upgrade`, or a stager from before this ADR), print status, warn that
the staged inventory was not captured, skip the delta, and still exit 0.
Do not re-pull the image to recover the file. Do not parse composefs
internals.

### Native staged list

`snosi-sysupdate-stage` writes the same `/run/snosi/staged-packages.txt`
from the newly labeled other root after a successful stage (read-only
EROFS access, then copy `packages.txt`). `snosi-update-status --pkg-diff`
prefers that sidecar.

If the sidecar is missing but a newer other-slot version exists
(`systemd-sysupdate pending` or the semaphore), the native backend reads
`packages.txt` from that slot at query time as a fallback (one read-only
EROFS access). That is the only filesystem the status CLI may mount for
this flag. If the fallback also fails, same warn-and-skip as bootc.

### Output and tests

`--help` / usage documents `--pkg-diff`. Motd, desktop notify, and
`snosi-update-status` without the flag stay silent on packages.

Fixture tests pin the parser (added / removed / version-changed /
identical). Static tests pin that both stagers write the sidecar path and
that `snosi-update-status` does not call `dpkg-query`, `dpkg -l`, or
`apt list` to build either side of the diff. A live native or bootc update
harness assertion can wait until those lanes already boot a staged hop.

## Consequences

- Fedora-shaped "what will this reboot change?" becomes a local command on
  both transports, using the file ADR-0003 already required every image to
  ship.
- Default status stays a cheap `/run` + `bootc status` / sysupdate read.
- Bootc staging gains a new fail point: if extracting `packages.txt` from
  the pulled image fails, the stage itself fails. Staging without an
  inventory is how `--pkg-diff` goes mute on the next status. The extract
  is a `podman run`/`cp` of one small file before prune; that is cheaper
  than the pull that just happened.
- `/run/snosi/staged-packages.txt` dies on reboot. After an applying
  reboot the flag correctly has nothing staged to diff. Operators who want
  "what did the last update change?" keep using Snow GitHub Releases, or a
  later rollback-diff ADR.
- Images built before the stager change can stage an update and then
  `--pkg-diff` will warn and skip. That is an upgrade-once gap, not a
  reason to pull multi-gigabyte images from status.
- Chairlift and motd ignore the new file. A future GUI package list would
  be a core-contract change, not a silent reuse.
- Unsigned R2 mkosi manifests and GHCR Syft SBOMs stay off the host CLI.
  The Snow release notes remain the human changelog; they are not a
  fallback parser target.

## Alternatives considered

- **A sibling `snosi-pkg-diff` next to `snosi-etc-diff`:** rejected. The
  question is about a pending *update*, and `rpm-ostree status -v` already
  taught the flag-on-status shape. `snosi-etc-diff` compares live `/etc` to
  the image, a different job.
- **Unflagged verbose output:** rejected. Default status is what people
  run from muscle memory and scripts. A kernel bump's package list must
  not become the normal print.
- **`dpkg-query` / live `apt list`:** rejected by core ADR-0003 and by the
  bootc `/var/lib/dpkg` persistence bug.
- **Diff against the GHCR Syft SBOM or R2 `manifests/` from `--pkg-diff`
  alone:** rejected. Syft is noisier than dpkg; the host has no oras/cosign;
  R2 manifests are unsigned. Remote package preview waits for a signed,
  small, dpkg-shaped artifact the image can actually fetch, and it belongs
  behind `--check`, not behind `--pkg-diff`.
- **Mount the staged bootc composefs tree from status:** rejected. bootc
  treats ostree layout as an implementation detail; pinning it in a
  shipped CLI is the Task-5 class of hidden-interface contract. Capturing
  one file at stage time is the maintained interface.
- **Show rollback diffs after reboot:** deferred. Useful, but it needs a
  durable copy or a safe read of the inactive deployment, which is a
  different lifetime than `/run`.
- **Include sysext packages:** rejected. Sysexts update on their own
  channel; mixing them into the OS image delta would lie about what a
  reboot of the staged OS applies.

## References

- Shapes: [design/build-pipeline.md](../design/build-pipeline.md)
  (`snosi-update-status`, stagers), [design/overview.md](../design/overview.md)
  (native/bootc `/run/snosi` contract),
  [integration-contracts.md](../integration-contracts.md) §5 (`update-check` /
  `update-staged`; the sidecar will be listed here when implemented)
- Implemented by (when this ADR is accepted):
  `mkosi.images/base/mkosi.extra/usr/bin/snosi-update-status`,
  `mkosi.images/base/mkosi.extra/usr/libexec/bootc-update-stage`,
  `shared/outformat/ab-root/tree/usr/libexec/snosi-sysupdate-stage`
- Builds on: [core ADR-0003 — packages.txt in `/usr/share/frostyard`](https://github.com/frostyard/core/blob/main/docs/adr/0003-image-provenance-in-usr-share-frostyard.md),
  [core ADR-0005 — `/run/snosi` update-state files](https://github.com/frostyard/core/blob/main/docs/adr/0005-native-ab-marker-and-update-state-files.md)
  (sibling file, not a field change)
- Related, not reused: `packagediff.sh` (dev-only, names-only),
  Snow GitHub Releases via `frostyard/changelog-generator`
