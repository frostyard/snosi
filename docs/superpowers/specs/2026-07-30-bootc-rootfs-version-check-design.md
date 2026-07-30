# Bootc Rootfs Version Check Design

## Problem

Protected `build-images.yml` run `30563925331` proved that the secure flag and
all credential paths now cross sudo: Cayo, Snow, and Snowfield each entered the
secure branch of `shared/outformat/image/buildah-package.sh`. All three then
failed before any registry write with:

```text
Error: secure assembly requires rootfs bootc 1.16.3
```

The build log proves each rootfs installed
`bootc 1.16.3-frostyard202607061837`. The failure is instead caused by the
packager invoking `"$ROOTFS_DIR/usr/bin/bootc" --version` directly in the
Ubuntu runner's filesystem and library context. Bootc is dynamically linked,
including against `libostree-1.so.1`; a path into a rootfs does not make that
rootfs's loader and libraries active. The current check therefore accidentally
requires the host ABI and packages to match the target image.

This bug was latent while secure environment state was filtered by sudo. The
successful fixture uses a host-runnable shell stub, so it did not model the
real dynamic-link boundary.

## Decision

Run the version probe through the already-root packager's standard `chroot`
boundary, with only the host procfs temporarily bind-mounted into the target:

```bash
mount --bind /proc "$ROOTFS_DIR/proc"
chroot "$ROOTFS_DIR" /usr/bin/bootc --version
umount "$ROOTFS_DIR/proc"
```

The accepted output remains exactly `bootc 1.16.3`. Failure to enter the
rootfs, execute bootc, load its target libraries, or produce the pinned output
remains fail-closed before first-pass packaging.

This adds no host package or privilege requirement. The workflow already runs
the packager through sudo; `chroot` is part of coreutils and `mount`, `umount`,
and `mountpoint` are part of util-linux on the runner. The rootfs is a complete
mkosi output, not an untrusted partial directory.

The procfs mount is measured, not speculative. Cayo image
`ghcr.io/frostyard/cayo@sha256:a067ed12ee6e62515b4b15ff7cbeef35d5d76df41f69f957ec1977ea9275ce98`
(image version `20260727175904`, bootc Debian package
`1.16.3-frostyard202607061837`) fails under bare chroot with:

```text
error: reading /proc/1/ns/ipc: No such file or directory (os error 2)
```

The same mounted OCI rootfs returns `bootc 1.16.3` when only `/proc` is
bind-mounted. It needs neither `/sys` nor `/dev` for this probe. The proof used
the exact `chroot ROOT /usr/bin/bootc --version` command shape planned here;
the pulled image is a real published mkosi rootfs with the same pinned bootc
package, though it predates the secure-capability label.

## Rejected Alternatives

### Host Bubblewrap

Bubblewrap would provide a namespace sandbox around the same rootfs, but the
host workflow does not currently establish `bwrap` as a packaging prerequisite.
Adding and guarding that dependency is unnecessary for a version-only probe.
The rootfs later contains bubblewrap for bcvk smoke coverage, but a binary
inside the target cannot bootstrap its own target-library execution from the
host context.

### Package Metadata Only

Reading dpkg status could prove that version `1.16.3` was registered, but not
that `/usr/bin/bootc` and its target libraries execute coherently. The secure
compatibility contract depends on the executable behavior, so metadata alone
is weaker than the existing intent.

### Host Library Installation

Installing host bootc/libostree dependencies would preserve the defective
execution boundary and couple target validation to Ubuntu package names and
ABI versions. It contradicts the candidate-owned validation architecture.

## Implementation Scope

Change only the rootfs version probe and the cleanup state needed for its
temporary procfs bind mount in `shared/outformat/image/buildah-package.sh`.
Invoke `mount`, `chroot`, `umount`, and `mountpoint` by bare name so the
non-root fixture can intercept them through `PATH`. Preserve:

- the exact `bootc 1.16.3` compatibility pin;
- the direct two-pass ukify and hidden storage-digest contract;
- storage-digest execution inside the packaged candidate OCI image;
- cleanup of first-pass, final-probe, and injected secure artifacts;
- secure labels and caller labels;
- credential handling and the sudo environment boundary;
- fail-before-push workflow ordering;
- the secretless mechanics-build path.

No `bwrap`, host bootc, host libostree, or additional APT installation may be
introduced.

The version result is a compatibility gate only. It does not replace or feed
the literal `SNOSI_BOOTC_SECURE_BOOTC_VERSION=1.16.3` passed to the assembler,
and it does not become storage-digest authority.

## Error Handling

The packager must reject a pre-mounted `$ROOTFS_DIR/proc` rather than unmounting
or reusing a mount it does not own; use `mountpoint -q` for that ownership
check. The complete mkosi rootfs must already contain its empty `/proc`
directory. Do not create a missing target: absence is malformed-rootfs evidence
and fails closed. Run the probe in a dedicated helper subshell. After its own
successful bind mount, that helper's EXIT trap must
unmount the exact path on success, version mismatch, execution failure, and
interruption. The mount must be gone before systemd-boot preparation or
first-pass packaging starts; it is never part of an OCI layer or the composefs
identity. A failed unmount is itself fatal and must not be hidden by an
otherwise successful probe.

The probe must distinguish a failed `chroot`/bootc execution from an unexpected
successful version. Capture and surface the execution diagnostic instead of
suppressing stderr; this output is needed to expose loader, library, or procfs
failures and contains no credential input. Both conditions exit nonzero before
the assembler or Buildah creates the first-pass image. A version mismatch may
print the expected and observed public version strings. No diagnostic may print
credential values or file contents.

## Test Design

Extend `test/bootc-secure-package-cleanup-test.sh` so its controlled commands
prove orchestration and cleanup without pretending to reproduce a real dynamic
loader boundary:

- provide controlled bare-name `mount`, `mountpoint`, `chroot`, and `umount`
  commands under the fixture's existing `$state/bin` PATH;
- make the controlled `chroot` command, rather than the now-inert rootfs shell
  stub, produce the pinned or deliberately wrong version output;
- assert a successful secure packaging fixture bind-mounted only `/proc`, used
  chroot with the expected root and `/usr/bin/bootc --version` arguments, and
  unmounted the owned rootfs proc path;
- add negative fixtures proving a pre-mounted rootfs proc path is refused, a
  failed chroot/bootc probe is diagnosed and rejected before assembler/Buildah,
  a wrong successful version is rejected, and procfs is unmounted after each
  failure that follows a successful bind;
- retain all existing cleanup and rerun assertions.

These command stubs prove call shape, ownership refusal, and cleanup behavior;
they do not model target ABI loading. The immutable published-Cayo experiment
above grounds the real loader/procfs behavior. The protected rerun then confirms
the same mechanism against newly built rootfs directories for all profiles.

Run the package cleanup fixture, bootc secure artifact negative fixtures,
ShellCheck, the publication guard, and `git diff --check`. The next protected
main-branch run is the production proof: all three package steps must pass this
probe and local artifact validation before any registry write is accepted.

## Documentation

Update `CLAUDE.md`, `README.md`, and the relevant `yeti/` build-pipeline
documentation to state that the initial version probe executes through chroot
with target libraries, while storage-digest authority remains bootc inside the
candidate OCI image.

## Evidence Boundary

A green protected rerun produces one signed secure candidate set for Cayo,
Snow, and Snowfield. It does not by itself provide distinct `N`, `N+1`, and
`N+2` artifacts, installed-system Task 9 evidence, rotation evidence, or the
representative Snowfield hardware gate.
