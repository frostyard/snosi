# Bootc and Native A/B Coexistence Plan

**Date:** 2026-07-14
**Status:** Proposed
**Scope:** Keep the existing bootc products supported while introducing secure
native A/B variants of Cayo, Snow, and Snowfield, an R2 publication pipeline,
and a network installer ISO.

## Summary

Snosi will support two deployment formats in parallel:

| Product | Existing format | New format | Update origin |
|---|---|---|---|
| Cayo | `cayo` OCI/bootc | `cayo-ab` native A/B | GHCR / R2 |
| Snow | `snow` OCI/bootc | `snow-ab` native A/B | GHCR / R2 |
| Snowfield | `snowfield` OCI/bootc | `snowfield-ab` native A/B | GHCR / R2 |

GHCR remains the authoritative origin for bootc OCI images. Cloudflare R2 is
the authoritative blob origin for sysexts, native A/B update payloads, native
raw installer images, and the installer ISO. GitHub Releases remain a
human-facing changelog and download index that links to signed R2 artifacts;
installed systems never query GitHub for updates.

The production native variants are secure by default:

- Debian-signed shim.
- MOK-signed systemd-boot and unified kernel images.
- Signed PCR 11 authorization for a per-machine LUKS2 `/var`.
- EROFS A/B roots protected by dm-verity.
- Signed `SHA256SUMS` metadata verified by systemd-sysupdate.
- Persistent `/etc` overlay backed by encrypted `/var`.
- Three-attempt systemd-boot fallback.

Existing bootc installations are not converted in place. Their disk layout
cannot safely become the native A/B layout without repartitioning. Migration is
an explicit backup and reinstall operation, and bootc remains supported for a
defined overlap period.

## Goals

1. Keep current Cayo, Snow, and Snowfield bootc builds and updates unchanged.
2. Add native A/B builds without duplicating or drifting product payloads.
3. Make Snow and Snowfield first-class native A/B products.
4. Publish native update and installation blobs from one R2 origin.
5. Authenticate native updates independently of R2 and TLS.
6. Provide a small network installer ISO with a safe CLI installer.
7. Preserve rollback, recovery, Secure Boot, TPM unlock, `/var`, and `/etc`
   behavior across updates.
8. Permit independent product promotion so a Snowfield hardware regression
   does not block Cayo or Snow security updates.

## Non-Goals For The First Release

- In-place bootc to native A/B conversion.
- Dual-boot partition management.
- Reusing or resizing an existing operating system partition layout.
- A graphical installer.
- Automatic migration of arbitrary `/var` or container state.
- Automatic MokManager interaction.
- Immediate retirement of GHCR bootc images.
- Multi-architecture native publication before x86-64 is stable.

## Product And Profile Model

Payload, kernel, deployment transport, and security must be independent
composition dimensions:

| Dimension | Choices |
|---|---|
| Payload | Cayo, Snow |
| Kernel | Backports, linux-surface |
| Transport | OCI/bootc, native A/B |
| Product identity | `cayo`, `snow`, `snowfield` |
| Native publication identity | `cayo-ab`, `snow-ab`, `snowfield-ab` |

The existing profile names remain unchanged:

```text
mkosi.profiles/cayo
mkosi.profiles/snow
mkosi.profiles/snowfield
```

The production native profiles become:

```text
mkosi.profiles/cayo-ab
mkosi.profiles/snow-ab
mkosi.profiles/snowfield-ab
```

The current raw `cayo-ab` and secure `cayo-ab-secure` profiles are development
fixtures while this composition is built. Do not publish the non-secure
prototype. Once the production security fragment is proven for all products,
fold it into the production `*-ab` profiles and retire redundant prototype
names in a separately reviewable cleanup.

Keep `ImageId=cayo`, `snow`, or `snowfield` in the native profiles. This
preserves branding, `/usr/lib/os-release`, package manifest identity, and
sysext compatibility. A separate native channel name distinguishes publication
and update namespaces.

## Shared Payload Composition

Create profile-neutral payload fragments:

```text
shared/composition/cayo/
shared/composition/snow/
shared/outformat/image/
shared/outformat/ab-root/
shared/native-ab-secure/
shared/native-ab/channels/cayo/
shared/native-ab/channels/snow/
shared/native-ab/channels/snowfield/
```

`shared/composition/cayo/` owns the Cayo package set, tree, build scripts,
post-install scripts, and common finalization.

`shared/composition/snow/` owns:

- The Snow package set and tree.
- Kernel post-install handling.
- Snow post-install customization.
- Homebrew construction.
- Hotedge, Logomenu, Bazaar, and Surface certificate build scripts.
- Common image finalization.

Profiles then select a payload, one kernel, and one output transport. This
avoids copying the Snow profile into bootc, A/B, and secure-A/B variants and
prevents the drift already visible between the Cayo bootc and A/B prototypes.

## Existing Bootc Products

The current bootc path remains stable:

- Continue building `cayo`, `snow`, and `snowfield` in
  `.github/workflows/build-images.yml`.
- Continue publishing timestamp and `latest` tags to GHCR.
- Keep Chunkah layer construction.
- Keep Cosign image and SBOM signatures.
- Keep GitHub provenance.
- Keep the current `bootc-update-stage` timer and containers-storage staging.
- Keep the current bootc install and multi-hop update tests.
- Keep GitHub Release changelog generation based on the Snow OCI image.

No native artifact is packaged as OCI merely to reuse this pipeline. Native
disk and partition outputs require a separate build and publication workflow.

## Native Runtime Isolation

Native images must never run bootc or legacy nbc update machinery.

Keep shared unit files in one authoritative tree. Prefer native profile masks
and positive format conditions over copying or relocating units, because this
repository has already experienced profile trees shadowing fixes made to base
units.

Native profiles must:

- Mask `bootc-update-stage.timer` and its service path.
- Mask upstream bootc auto-update timers.
- Mask `nbc-update-download.timer` and its service path.
- Keep `/usr/lib/snosi/native-ab` as a positive native marker.
- Prove through static and boot tests that neither bootc nor nbc updater can
  activate.
- Keep systemd-sysupdate timers disabled until signed R2 publication is live.

Provide a common user-facing command:

```text
snosi-update-status
```

It detects deployment format and dispatches to either the existing bootc
backend or a native sysupdate backend.

For native systems, add a controlled staging wrapper instead of enabling an
upstream force-reboot flow directly:

```text
snosi-sysupdate-stage.service
snosi-sysupdate-stage.timer
```

The native stager must:

- Check the signed R2 index for a newer version.
- Download and install only into inactive root and verity slots.
- Verify installed partition UUIDs against the publication metadata.
- Confirm the matching UKI was installed last.
- Record current, available, staged, held, and failed outcomes.
- Never force an immediate reboot.
- Expose reboot-pending state through MOTD and desktop notification.
- Preserve natural reboot behavior consistent with bootc.

## Generic Native A/B Output

Remove Cayo-specific identity from `shared/outformat/ab-root`. The generic
fragment should own only disk and boot mechanics:

- Disk output and split artifact generation.
- A/B partition types.
- EROFS root formatting.
- dm-verity generation.
- Persistent final `/var`.
- systemd-boot UKIs and boot counting.
- Pre-pivot `/etc` overlay setup.
- Initrd integration.

Move these details to per-product channel fragments:

- Partition labels and split names.
- Public artifact names.
- R2 URL.
- Root, verity, ESP, and initial `/var` capacity.
- Expected kernel flavor.
- Product-specific transfer match patterns.

The current mismatch between mkosi split output and the UUID-bearing XZ names
consumed by sysupdate must be resolved by a native post-output publisher. The
internal double `.raw.raw` names are not a public contract.

Use source filenames such as:

```text
snow-ab_<version>_<root-uuid>.root.raw.xz
snow-ab_<version>_<verity-uuid>.root-verity.raw.xz
snow-ab_<version>.efi
snow-ab_<version>.disk.raw.xz
```

Use compact GPT labels based on `ImageId`, not channel name:

```text
snow_<version>_root
snow_<version>_root_verity
snowfield_<version>_root
snowfield_<version>_root_verity
```

This keeps Snowfield's longest label within the GPT partition-name limit.

## Disk Layout And Update Invariants

Retain the proven layout:

```text
ESP
root A verity
root A
root B verity
root B
persistent /var
```

Retain these update and boot invariants:

- Root partitions are EROFS and read-only.
- Each root has a dedicated dm-verity hash partition.
- The signed UKI authenticates its embedded roothash.
- `/var` is the final partition and the only partition the installer grows.
- `/etc` is overlaid before switch-root using upper/work directories in `/var`.
- Root and verity transfers are mandatory and UUID-bearing.
- UKI transfer occurs last and is the activation point.
- `ProtectVersion=%A` protects the running version.
- `InstancesMax=2` keeps one active and one rollback generation.
- `PartitionFlags=0` is applied before `ReadOnly=yes`.
- `TriesLeft=3` provides three automatic attempts.
- XZ is used for partition URL payloads.

Mask `systemd-growfs-root.service`. A fixed EROFS root must never be grown.

Exclude staged ESP payloads from the root partition while preserving empty
mountpoints. Assert that the finalized lower `/etc` contains
`machine-id=uninitialized` before it is moved to `/.etc.lower`.

## Capacity Planning

Do not copy Cayo's current 4 GiB root slots into Snow or Snowfield without
measurement.

For each product, CI must measure:

- Actual EROFS content size.
- Root slot free headroom.
- Compressed root update size.
- Verity image size and partition headroom.
- UKI size.
- ESP use with two UKIs, shim, systemd-boot, and MokManager.
- Full installer raw image size.
- Required minimum target disk size.

Set a publication threshold, initially at least 20% root-slot headroom. Fail
before publication if any artifact exceeds its fixed partition or ESP budget.

Snowfield may require a larger UKI because of Surface modules and firmware.
Capacity values therefore remain product-specific.

## Snow Native A/B

`snow-ab` must preserve every payload input used by `snow` and replace only the
transport and security model.

It uses:

- Snow composition fragment.
- Backports kernel fragment only.
- Native A/B outformat.
- Secure native fragment.
- Snow channel and capacity fragment.

Required desktop validation includes:

- GDM reaches the expected state.
- First setup creates a usable persistent administrator.
- `/var/home`, `/root`, `/opt`, Flatpak state, and GNOME state persist.
- `/etc` upper state persists through update and rollback.
- Lower `/etc` changes behave correctly with and without local overrides.
- System and user presets are correct on first boot.
- Desktop notification helpers have `notify-send`.
- A desktop sysext merges and its icon and desktop entry are visible.
- Forky systemd 261 remains compatible with GDM, PAM, logind, and GNOME.

The existing `snow-linux-live-setup.service` behavior must be resolved. It is
described as live-only but currently runs based on completion markers rather
than a live-media kernel argument. Decide whether native Snow deliberately uses
that first-setup flow or ships an installed-system-specific replacement.

## Snowfield Native A/B

`snowfield-ab` shares Snow payload composition but selects only the Surface
kernel fragment.

Artifact checks must prove:

- The manifest contains the expected Surface kernel packages.
- A generic/backports kernel is not selected accidentally.
- The UKI contains the Surface kernel.
- The matching module directory and required firmware are present.
- The initrd contains dm-verity, dm-crypt, TPM, overlay, storage, and Surface
  requirements.

Prefer re-signing required Surface modules with the Snosi MOK key during image
construction. This gives one MOK enrollment for the UKI, systemd-boot, and
runtime modules. If upstream Surface signatures are retained instead, the
installer must enroll a second independent linux-surface certificate.

Secure Boot hardware tests must verify that required Surface modules load under
kernel lockdown and that touch, pen, keyboard/cover, storage, networking, and
power management remain functional across update and rollback.

## Native Security Contract

Production A/B profiles use the secure design already validated by
`cayo-ab-secure`:

- Debian-signed shim.
- MOK-signed systemd-boot.
- MOK-signed locally generated UKI.
- No Secure Boot auto-enrollment or custom firmware database.
- Per-machine LUKS2 `/var`.
- Externally retained recovery passphrase.
- Empty raw-PCR set.
- Signed PCR 11 policy.
- Explicitly disabled automatic pcrlock selection.
- Dual-signed transition UKIs for PCR signing-key rotation.
- NvPCR definitions and writers disabled under systemd 261.

Keep these keys independent:

| Key | Purpose |
|---|---|
| Secure Boot/MOK key | systemd-boot, UKI, and preferably Surface modules |
| PCR signing key | Signed PCR 11 authorization for LUKS |
| OpenPGP update key | `SHA256SUMS.gpg` |
| R2 credentials | Upload authorization only |

Ship the update public key in:

```text
/usr/lib/systemd/import-pubring.gpg
```

Keep `Verify=yes` in every native transfer. R2 credentials, TLS, GitHub
provenance, Secure Boot, and the PCR key do not replace the update manifest
signature.

The update-signing private key belongs only in a protected promotion
environment. Build jobs produce artifacts and expected checksums; the protected
promotion job verifies uploaded bytes and signs the final index.

## R2 Publication Contract

Use a versioned API namespace under the existing production custom domain:

```text
https://repository.frostyard.org/os/native/v1/cayo/x86-64/
https://repository.frostyard.org/os/native/v1/snow/x86-64/
https://repository.frostyard.org/os/native/v1/snowfield/x86-64/
```

Each product directory contains immutable versioned objects and the current
signed index:

```text
SHA256SUMS
SHA256SUMS.gpg

snow-ab_20260714150036_<uuid>.root.raw.xz
snow-ab_20260714150036_<uuid>.root-verity.raw.xz
snow-ab_20260714150036.efi
snow-ab_20260714150036.disk.raw.xz
snow-ab_20260714150036.manifest.json
snow-ab_20260714150036.sbom.spdx.json
```

`SHA256SUMS` is the machine-consumed channel pointer. It normally advertises
only the currently promoted version. Older immutable objects remain available
for retention and incident response but are not offered by update checks.

Do not make installed systems query GitHub APIs or GitHub `latest` releases.

## Atomic Publication Procedure

Publication is independent per product even when products share a source
timestamp.

1. Build root, verity, UKI, full disk, package manifest, SBOM, and provenance.
2. Convert split outputs into the final versioned public filenames.
3. Compress root, verity, and full disk with XZ.
4. Verify every compressed artifact locally.
5. Multipart-upload all immutable versioned objects to an R2 candidate prefix.
6. Set `Cache-Control: public, max-age=31536000, immutable` on payloads.
7. Verify remote size, SHA-256, full GET, and representative range GETs.
8. Copy or promote verified objects to their final immutable names.
9. Generate `SHA256SUMS` over the exact bytes served by R2.
10. Sign it as `SHA256SUMS.gpg` in the protected promotion environment.
11. Upload the new signature first.
12. Upload `SHA256SUMS` last.
13. Set both metadata files to `Cache-Control: no-store`.
14. Run systemd-sysupdate against the public R2 URL.
15. Publish human-facing release notes only after public-origin validation.

The short interval where an old manifest and new detached signature disagree
fails closed; the staging timer retries. A future Worker-backed generation
switch may remove that interval, but it is not required for the initial
implementation.

Never transform, compress, or add content encoding to a payload after its
checksum is signed.

## R2 Retention And Cost Control

R2 remains appropriate because Internet egress is not charged. Native update
cost is primarily storage and object operations, not bandwidth egress.

Control cost through policy:

- Keep applications in sysexts so root images remain small.
- Build candidates as needed but promote stable roots weekly or less often.
- Keep at least the current and previous two stable native versions.
- Retain withdrawn versions for a defined grace period, initially 90 days.
- Retain full installer disk images for less time than root update objects.
- Apply lifecycle deletion only after rollback and offline-install windows.
- Record compressed bytes and estimated R2 storage/read cost per release.
- Keep sysext publication on its existing package-versioned R2 paths.

Immediate rollback does not require old server objects because the previous root
and UKI remain on disk.

To withdraw a bad release, restore the previous signed `SHA256SUMS` so systems
that have not updated no longer see it. Systems already running the bad version
need a higher-version repair release, potentially containing the prior known-good
content with new version and partition identities. Do not rely on server-side
downgrade.

## GitHub Releases

GitHub Releases remain lightweight and human-facing. They contain no OS blobs
if R2 is the single blob origin.

Release notes should include:

- Source commit and image version.
- Successfully promoted product matrix.
- Immutable GHCR digests for bootc products.
- R2 URLs for native raw images and the installer ISO.
- SHA-256 values and update-key fingerprint.
- Package manifests, SBOM, and provenance links.
- Minimum disk sizes.
- Known issues and migration notes.

Native products promote independently. A Snowfield-only hardware failure must
not block a Cayo or Snow security update.

## Native Build Workflow

Keep `.github/workflows/build-images.yml` dedicated to OCI/bootc products. Add:

```text
.github/workflows/build-native-images.yml
```

Suggested jobs:

| Job | Responsibility |
|---|---|
| `prepare` | Assign version and source revision |
| `build-cayo` | Build and validate `cayo-ab` |
| `build-snow` | Build and validate `snow-ab` |
| `build-snowfield` | Build and validate `snowfield-ab` |
| `publish-candidate` | Upload immutable candidate objects to R2 |
| `test-public-origin` | Pull and install from the real R2 URL |
| `promote-cayo` | Sign and update Cayo index |
| `promote-snow` | Sign and update Snow index |
| `promote-snowfield` | Sign and update Snowfield index |
| `release-notes` | Publish human-facing GitHub release information |

Do not send multi-gigabyte native artifacts through ordinary GitHub Actions
artifact storage. Upload directly from a build runner to a temporary R2 prefix.

Use runners with sufficient workspace for a full disk, split partitions, XZ
staging, and public-origin verification. Check job duration and free disk before
starting each build.

## Installer ISO

Add a dedicated network-installer profile, for example:

```text
mkosi.profiles/native-installer/
```

The first ISO does not embed Snow, Snowfield, or Cayo. It contains networking,
storage tools, OpenPGP verification, cryptsetup, TPM enrollment, MokManager
support, and the product-aware CLI installer. Keeping the ISO independent of OS
payloads reduces its size and rebuild frequency.

Publish it to R2:

```text
https://repository.frostyard.org/iso/native/v1/
```

Assets:

```text
snosi-native-installer_<version>_x86-64.iso
SHA256SUMS
SHA256SUMS.gpg
```

GitHub release notes link to this R2 location.

## First-Round CLI Installer

Generalize `test/cayo-ab-install-spike.sh` into a product-aware installer. The
initial interface may remain CLI-only.

Installation flow:

1. Start networking and synchronize time.
2. Offer `cayo-ab`, `snow-ab`, or `snowfield-ab`.
3. Fetch and verify the product's signed R2 index.
4. Display version, source revision, minimum disk size, and destructive warning.
5. Enumerate disks by path, model, serial, size, and transport.
6. Refuse mounted, ambiguous, installer-media, RAID-member, or undersized disks.
7. Require typed confirmation containing the target disk path or serial.
8. Download the `.disk.raw.xz` while verifying its signed checksum.
9. Stream or write the decompressed image to the selected disk.
10. Reread the partition table and relocate the backup GPT.
11. Grow only the final `/var` partition.
12. Recreate `/var` as per-machine LUKS2 for production installs.
13. Generate an external recovery passphrase.
14. Require confirmation that the recovery passphrase was saved off-disk.
15. Enroll TPM unlock with empty raw PCRs, signed PCR 11, and pcrlock disabled.
16. Import the Snosi MOK certificate.
17. Record product, architecture, channel, and version in persistent `/var`.
18. Optionally install a root SSH key for initial diagnostics.
19. Reboot into MokManager for one-time enrollment.
20. Continue into graphical first setup for Snow and Snowfield.

If Surface modules are not re-signed with the Snosi key, Snowfield installation
must also import the independent linux-surface MOK certificate.

The installer must never clone LUKS metadata, TPM tokens, recovery material,
machine IDs, or SSH host keys. Required generic `/var` content must be recreated
through tmpfiles, sysusers, or first boot after the installer formats `/var`.

## Installer Safety Boundary

The first installer supports whole-disk replacement only. It does not support:

- Dual boot.
- Existing ESP reuse.
- Partition shrinking.
- In-place bootc conversion.
- Arbitrary `/var` restoration.

Provide a separate bootc migration export helper for selected user data and
configuration. It must exclude machine identity, host keys, TPM state, bootc
deployment metadata, and secrets unless explicitly requested and encrypted.

## Validation Gates

Every native product must pass these gates before index promotion:

- Clean profile build.
- Package and artifact manifest validation.
- Root, verity, UUID, and UKI roothash agreement.
- Signed-manifest acceptance and tampering rejection.
- Byte-identical download from the public R2 endpoint.
- Root, verity, ESP, and disk capacity checks.
- No active bootc or nbc updater.
- Native stage/status/notification behavior.
- N through N+3 update and physical slot reuse.
- Explicit rollback.
- Corrupt unblessed update and three-attempt fallback.
- `/var` and `/etc` persistence.
- Secure Boot and measured UKI.
- Sole expected signed-PCR TPM token.
- Recovery-key unlock.
- No NvPCR setup failures.
- ISO installation using public R2 assets.

Snow adds:

- GDM and GNOME session validation.
- First-setup and persistent administrator validation.
- Desktop sysext and notification validation.

Snowfield adds:

- Surface kernel and module artifact validation.
- Secure Boot module-loading validation.
- Representative Surface hardware installation, update, rollback, and fallback.

## Phased Implementation

### Phase 0: Freeze Contracts

Define and document:

- Product and profile names.
- R2 path version.
- Public artifact naming.
- Image version format.
- Partition labels.
- Key ownership and rotation.
- Capacity and retention policy.
- Minimum support overlap for bootc.

Exit criterion: static tests can validate all names and paths without building
an image.

### Phase 1: Factor Payload Composition

Create shared Cayo and Snow composition fragments. Convert existing bootc
profiles to consume them without changing output. Convert the Cayo prototypes
and prove package/tree parity.

Exit criterion: bootc image manifests remain intentionally unchanged and Cayo
A/B no longer omits payload build steps.

### Phase 2: Generalize Native A/B Output

Remove Cayo identity, URL, and capacities from the generic outformat. Add
per-product channel and repart fragments. Add the native public-name post-output
step and parameterize A/B tests.

Exit criterion: Cayo, Snow, and Snowfield native artifacts can be built locally
with distinct labels, names, kernels, and capacities.

### Phase 3: Isolate Runtime Update Paths

Mask bootc and nbc update machinery in native profiles. Add native staging,
status, MOTD, and notification components. Keep automatic staging disabled.

Exit criterion: boot tests prove each format starts exactly one update stack.

### Phase 4: Add Secure Snow

Build `snow-ab`, establish partition sizes, and validate desktop first boot,
GNOME, persistence, and secure update behavior.

Exit criterion: Snow completes installation, N through N+3, rollback, and
fallback in QEMU or Incus with Secure Boot and TPM unlock.

### Phase 5: Add Secure Snowfield

Build `snowfield-ab`, finalize Surface module signing, establish capacities, and
run Secure Boot hardware validation.

Exit criterion: representative Surface hardware passes installation, desktop
boot, update, rollback, and fallback with required modules loaded.

### Phase 6: Productionize R2 Publication

Ship the update pubring, protected signer, candidate upload, remote verification,
per-product promotion, retention, and public-origin integration tests.

Exit criterion: Cayo native update succeeds from the production R2 URL and a
tampered or partially published set fails closed.

### Phase 7: Build The Network Installer ISO

Create the ISO profile and generalize the installer. Add target-disk safety,
signed download, per-machine LUKS, recovery confirmation, TPM enrollment, MOK
request, and product/channel recording.

Exit criterion: a clean VM can boot the R2-hosted ISO, install each product from
R2, complete MOK enrollment, and reach the installed system.

### Phase 8: Testing And Stable Promotion

Run candidate installations and multi-hop tests. Promote products independently
after their own gates pass. Publish GitHub release notes linking to R2.

Exit criterion: stable signed indexes exist for qualified products without any
change to bootc publication.

### Phase 9: Optional User Migration

Publish backup/reinstall instructions and migration export tooling. Continue
bootc updates through GHCR during the overlap period.

Exit criterion: migration is optional, documented, recoverable, and does not
require users to adopt an unqualified native product.

### Phase 10: Review Bootc Retirement

Set no retirement date until native installation, updates, recovery, and
hardware support have operated successfully for a defined support window.
Retirement is a separate decision and change set.

## Expected Code Areas

```text
mkosi.profiles/cayo/
mkosi.profiles/snow/
mkosi.profiles/snowfield/
mkosi.profiles/cayo-ab/
mkosi.profiles/snow-ab/
mkosi.profiles/snowfield-ab/
mkosi.profiles/native-installer/
shared/composition/
shared/outformat/ab-root/
shared/native-ab-secure/
shared/kernel/scripts/postinst/
test/native-ab-*.sh
test/cayo-ab-install-spike.sh
test/tests/
.github/workflows/build-native-images.yml
.github/workflows/validate.yml
Justfile
check-profile-dependencies.sh
README.md
CLAUDE.md
yeti/
```

## Completion Criteria

This plan is complete when:

- Existing bootc products still build, publish, install, and update from GHCR.
- Cayo, Snow, and Snowfield native products build from shared payload definitions.
- R2 is the only blob origin consumed by native installers and updaters.
- Every native update is authenticated with the shipped OpenPGP key.
- Native installation is available through a signed R2-hosted ISO.
- Snow and Snowfield pass desktop-specific update and persistence tests.
- Snowfield passes Secure Boot tests on representative Surface hardware.
- Automatic fallback and recovery behavior are demonstrated from public assets.
- Migration remains opt-in while bootc is supported.
