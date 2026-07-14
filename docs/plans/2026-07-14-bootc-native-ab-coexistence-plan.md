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
- Independently versioned, authenticated sysext components.
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
- Reusing the current virtio-only kernel-module filter on release hardware.

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
fixtures while this composition is built. Rename the raw profile to
`cayo-ab-raw` before publication work starts, then reserve `cayo-ab` for the
secure production posture. A static publication guard must reject any native
profile that lacks shim, Secure Boot, expected-PCR signing, the update pubring,
NvPCR policy, and native updater isolation. Do not allow one profile name to
mean both raw and secure images at different points in the rollout.

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

As part of this factoring, inventory every path written under image `/var` for
each product and map it to one of four outcomes: immutable image metadata,
tmpfiles/sysusers reconstruction, explicit installer seed, or deliberately
discarded build state. The current secure prototype loses `/var/lib/dpkg` when
the installer reformats `/var`, and `dpkg-query` then reports no installed
packages. Native and bootc variants of the same payload need an explicit,
tested package-metadata policy rather than accidental behavior.

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

These masks are an immediate prototype correctness requirement, not a later
hardening task. The base preset currently enables `bootc-update-stage.timer`,
while both nbc units explicitly select kernels without `composefs`; that is
exactly the native boot condition. No further native runtime qualification
should proceed with those units enabled.

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

When automatic native staging is introduced, activate the Snosi staging timer
through a static `/usr/lib/systemd/system/timers.target.wants/` link. Do not rely
on first-boot presets or preset reconciliation to bootstrap a new updater on
systems whose first boot predates publication. Existing installs receive the
new static link with the image and may override it by masking the timer.

## Sysupdate Target And Component Topology

The host OS and independently versioned sysexts must not share one sysupdate
target. All enabled transfers in one definitions directory participate in one
version-set intersection, and an optional feature remains lock-stepped with the
rest of that target. Combining image timestamps with package-derived sysext
versions makes complete updates impossible as soon as a sysext is enabled.

Keep the native OS as the default target:

```text
/usr/lib/sysupdate.d/
  10-root-verity.transfer
  20-root.transfer
  90-uki.transfer
```

Move every independently versioned sysext into its own named component:

```text
/usr/lib/sysupdate.docker.d/
  docker.transfer
  docker.feature

/usr/lib/sysupdate.incus.d/
  incus.transfer
  incus.feature

/usr/lib/sysupdate.vscode.d/
  vscode.transfer
  vscode.feature
```

Component-scoped feature overrides belong under the corresponding `/etc`
directory, for example:

```text
/etc/sysupdate.incus.d/incus.feature.d/00-updex.conf
```

This preserves unqualified `systemd-sysupdate update` for the host OS while
sysext operations use `--component=<name>`. Multiple sysexts may share a
component only when they intentionally use one version and publish atomically.

`frostyard-updex` must gain component discovery before this move ships. It must
enumerate `/usr/lib/sysupdate.<component>.d`, read and write component-scoped
feature drop-ins, and execute check, update, and vacuum with the matching
`--component`. Until that support exists, moving files alone would make updex
stop discovering sysexts.

Add an integration test that enables at least two differently versioned sysext
components, updates them independently, then stages and boots a native OS
update. A sysext update must not touch OS partitions or UKIs, and an unqualified
OS update must not modify sysext targets.

## Native `/etc` Drift Tooling

Adapt `snosi-etc-diff` before native desktop release. On bootc it exposes the
pristine image `/etc` by bind-mounting `/` beneath the live `/etc` mount. On
native A/B, the canonical pristine tree is `/.etc.lower` and live `/etc` is an
overlay. Detect `/usr/lib/snosi/native-ab` and use `/.etc.lower` directly;
retain the existing composefs path for bootc.

Validate listing, path inspection, deleted paths, local additions, permissions,
`--restore`, the boot drift report, MOTD, and desktop notification on both
formats. Native release is blocked if drift tooling compares the live overlay
to itself or reports the complete lower tree as drift.

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
- Final-root kernel-module and firmware retention policy.
- Initrd hardware policy.
- Product-specific transfer match patterns.

The current `KernelModules=` list in `shared/outformat/ab-root/mkosi.conf` is a
QEMU-only prototype setting. In pinned mkosi it removes unlisted modules and
their unneeded firmware from the final image; `KernelModulesInitrd=no` does not
limit that pruning to the initrd. Release profiles must remove the restrictive
list and retain the complete packaged module/firmware set unless a product has
an explicit supported-hardware allowlist with equivalent physical validation.
Keep the custom dracut archive authoritative through `Initrds=` and
`KernelModulesInitrd=no`, and control initrd content through dracut configuration
rather than final-root pruning.

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
snow_<version>_r
snow_<version>_v
snowfield_<version>_r
snowfield_<version>_v
```

Do not use `snowfield_<version>_root_verity`: with the current timestamp it
already consumes all 36 GPT code units and leaves no room for a version-format
change. Phase 0 must define a maximum version length and statically require at
least six code units of label headroom for every product and suffix.

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

Use one canonical `/var` mount contract per security posture. Production secure
profiles unlock `/dev/disk/by-partlabel/var` as `/dev/mapper/var` in the initrd
and use `/dev/mapper/var` in their fstab. The raw development profile may use a
separate fstab that mounts the unencrypted PARTLABEL directly. Do not rely on a
raw fstab entry being harmless merely because the initrd happened to mount an
encrypted mapper first. The raw mount path is a non-published test fixture and
is explicitly outside production publication gates; keep a dedicated raw-profile
boot test if the fixture remains useful.

Mask `systemd-growfs-root.service`. A fixed EROFS root must never be grown.

Exclude staged ESP payloads from the root partition while preserving empty
mountpoints. Assert that the finalized lower `/etc` contains
`machine-id=uninitialized` before it is moved to `/.etc.lower`.

## Native `/var` Factory State

The installer intentionally creates a fresh per-machine `/var`, so no build-time
file under image `/var` may be assumed to survive. Audit the complete tree after
all package installation and profile scripts. The audit is per product and is a
build artifact reviewed alongside the package manifest.

Use these default outcomes:

- Machine state, logs, caches, host keys, identities, and random seeds are
  discarded and generated on first boot.
- Required directories, ownership, and safe defaults are recreated through
  tmpfiles and sysusers.
- Installer-provisioned user and channel state is written only after the fresh
  filesystem exists.
- Image/package identity belongs to the immutable root, not persistent `/var`.

For Debian package identity, prefer moving the finalized build database to an
immutable path such as `/usr/lib/sysimage/dpkg` and creating
`/var/lib/dpkg -> /usr/lib/sysimage/dpkg` on a fresh native `/var`. Runtime
package mutation is unsupported, but normal read-only `dpkg-query`/`dpkg -l`
must describe the currently booted image and naturally change with A/B roots.
Validate this approach against maintainer scripts, first boot, updates, and
rollback before freezing it; do not seed a writable persistent copy that becomes
stale after the first update.

The installer and first boot test must compare the built `/var` inventory to
the declared outcome map and fail on an unclassified path.

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
- Installed root module and firmware size under the production hardware policy.

Set a publication threshold, initially at least 20% root-slot headroom. Fail
before publication if any artifact exceeds its fixed partition or ESP budget.

Capacity measurements are invalid until the QEMU-only module filter is gone.
Snowfield may require a substantially larger UKI because of Surface modules and
firmware. Use a conservative 1 GiB ESP for Snow and Snowfield from the first
installable layout unless release-equivalent measurements prove a larger value
is needed; an undersized ESP cannot be repaired in place after installation.
Capacity values remain product-specific.

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

Do not assume Surface modules need re-signing. First inspect the packaged
kernel configuration, module signatures, and signer trust under lockdown, then
boot representative hardware with Secure Boot enforced. In-tree modules may
already be signed by a key the Surface kernel trusts. Re-sign only modules that
actually fail trust validation or are out-of-tree. If an independent
linux-surface signer must be trusted, the installer must enroll that certificate
in addition to the Snosi MOK certificate.

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
| Secure Boot/MOK key | systemd-boot, UKI, and only modules proven to need re-signing |
| PCR signing key | Signed PCR 11 authorization for LUKS |
| OpenPGP update key | `SHA256SUMS.gpg` |
| R2 credentials | Upload authorization only |

### Build And Signing Key Custody

The MOK and PCR private keys are higher-impact than the R2 credential and must
not be exposed to arbitrary image build scripts on general GitHub-hosted
runners. Compromise of the MOK key authorizes code on every machine that enrolled
it; compromise of the PCR key authorizes new PCR 11 LUKS policies.

The target architecture separates unsigned construction from protected signing:

1. An unprivileged build job creates the root, verity tree, kernel, initrd,
   unsigned UKI inputs, manifests, and provenance without long-lived keys.
2. A protected signer accepts artifacts only from a trusted main-branch build
   with verified provenance and expected hashes.
3. The signer creates expected-PCR signatures, constructs or updates the UKI,
   applies the Secure Boot signature, signs systemd-boot, and assembles the final
   ESP/full disk from those signed artifacts.
4. Private-key operations use a restricted HSM, PKCS#11 provider, or locked
   self-hosted signer where possible; plaintext key files are not Actions
   artifacts and are never mounted while repository build scripts execute.
5. Publication verifies that signed output still binds the exact root, verity,
   kernel, initrd, command line, and source revision from the candidate build.

If mkosi cannot yet split final assembly from signing, the temporary fallback is
a dedicated protected builder that runs only trusted main commits, has no pull
request or fork trigger, receives secrets ephemerally, and is destroyed or
scrubbed after each build. That is an interim risk, not the final custody model.

### MOK Rotation

MOK rotation is separate from PCR key rotation and requires user-visible trust
enrollment. Define it before the first production enrollment:

- Publish the new certificate while all binaries remain signed by the old key.
- Stage `mokutil --import` through a guarded migration service or installer and
  require the user to complete MokManager enrollment.
- During the overlap, new installation media requests both certificates and old
  installations retain the old certificate for rollback binaries.
- Switch new UKIs, systemd-boot, and any Snosi-signed modules to the new key only
  after the supported fleet has enrolled it.
- Keep old-signed rollback UKIs supported until their rollback window expires.
- Treat emergency revocation as a separate recovery procedure; an image update
  cannot silently change firmware/MOK trust on an unattended machine.

Track enrollment state and provide a command that reports whether each required
certificate is present before promotion to new-key-only binaries.

Ship the update public key in:

```text
/usr/lib/systemd/import-pubring.gpg
```

Keep `Verify=yes` in every native transfer. R2 credentials, TLS, GitHub
provenance, Secure Boot, and the PCR key do not replace the update manifest
signature.

Apply the same authenticated-manifest requirement to sysext components before
claiming the native system is secure by default. The current sysext transfers
use `Verify=false`, so an R2 compromise can replace an extension merged into
`/usr` even though the base root is dm-verity protected. Component migration
must add signed per-component `SHA256SUMS` metadata, ship the corresponding
pubring, set `Verify=yes`, and test tampering rejection. Until that ships, call
unsigned sysexts an explicit accepted risk and do not enable them by default on
production native installs.

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

The prototype currently bakes `https://repository.frostyard.org/os/cayo/%a/`
into its three transfers. Phase 0 freezes the new URL and Phase 3 replaces every
shipped transfer; the baked client path and the publisher path must be validated
as one contract before any install is distributed.

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
14. Add an explicit Cloudflare cache rule that bypasses caching for both exact
    metadata names, and verify response headers from the public custom domain.
15. Purge both metadata URLs during promotion and test that a second region sees
    the new matching pair.
16. Run systemd-sysupdate against the public R2 URL.
17. Publish human-facing release notes only after public-origin validation.

The short interval where an old manifest and new detached signature disagree
fails closed; the staging timer retries. If public-origin tests show Cloudflare
does not honor the exact metadata cache-bypass rule, a Worker-backed atomic
generation switch becomes mandatory before initial publication. Do not ship
with stale edge-cached metadata merely because R2 object headers are correct.

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
- Keep sysext publication on its existing package-versioned R2 paths; named
  components are a client-side target separation and do not require duplicating
  the existing R2 objects.

Immediate rollback does not require old server objects because the previous root
and UKI remain on disk.

To withdraw a bad release, restore the previous `SHA256SUMS` and its exact
matching `SHA256SUMS.gpg` using the same signature-first, manifest-last sequence,
then purge both metadata URLs. Systems that have not updated no longer see the
bad version. Systems already running it need a higher-version repair release,
potentially containing the prior known-good content with new version and
partition identities. Do not rely on server-side downgrade.

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

## Mkosi Pin Governance

Native layout and signing depend on pinned mkosi 27~devel semantics, including
`UnifiedKernelImages=unsigned` meaning "construct locally",
`SplitArtifacts=partitions,uki,repart-definitions,roothash`, repart split names,
and final-root `KernelModules=` filtering. Treat the mkosi commit as part of the
published image format, not merely a build tool version.

For every mkosi pin change:

1. Diff the relevant man pages and implementation for UKI mode, Secure Boot,
   PCR signing, repart, split artifacts, module filtering, sandbox key access,
   and output naming.
2. Run static configuration summaries for every bootc and native profile.
3. Build clean Cayo, Snow, and Snowfield artifacts.
4. Compare partition tables, split filenames, UKI sections, signatures, module
   inventories, manifests, and minimum sizes to the previous pin.
5. Run installer, public-origin update, rollback, and fallback tests.
6. Merge the pin change separately from product payload changes.

CI must derive local and workflow mkosi from the same commit and fail if they
diverge.

## Installer ISO

Add a dedicated network-installer profile, for example:

```text
mkosi.profiles/native-installer/
```

The first ISO does not embed Snow, Snowfield, or Cayo. It contains networking,
storage tools, OpenPGP verification, cryptsetup, TPM enrollment, MokManager
support, and the product-aware CLI installer. Keeping the ISO independent of OS
payloads reduces its size and rebuild frequency.

The ISO itself boots before any Snosi MOK exists and therefore cannot use the
installed system's MOK-signed systemd-boot/UKI chain. Build the installer with a
fully Debian-trusted pre-enrollment chain:

```text
Microsoft firmware db
  -> Debian-signed shim
  -> Debian-signed GRUB
  -> Debian-signed stock kernel
  -> installer initrd/userspace
```

Do not sign the installer boot chain only with the Snosi MOK key. Validate the
ISO on firmware that has never enrolled a Snosi certificate and with Secure Boot
enforced.

The installer userspace must carry a coherent Forky systemd 261 cryptsetup/TPM
family matching the installed security semantics, even though its boot kernel is
Debian-signed. Enrollment behavior differs materially between systemd 257 and
261; using the older installer tool to create production tokens is unsupported.

Publish it to R2:

```text
https://repository.frostyard.org/isos/native/v1/
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
16. Prompt for a one-time MokManager enrollment password, validate it twice, and
    explain the exact next-boot interaction before staging the request.
17. Import the Snosi MOK certificate with that password.
18. Record product, architecture, channel, and version in persistent `/var`.
19. Optionally install a root SSH key for initial diagnostics.
20. Reboot into MokManager for one-time enrollment.
21. Continue into graphical first setup for Snow and Snowfield.

If Surface modules are not re-signed with the Snosi key, Snowfield installation
must also import the independent linux-surface MOK certificate.

The installer must never clone LUKS metadata, TPM tokens, recovery material,
machine IDs, or SSH host keys. Required generic `/var` content must be recreated
through tmpfiles, sysusers, or first boot after the installer formats `/var`.

If the user skips, mistypes, or times out MokManager, the firmware discards the
request and the installed MOK-signed OS will not boot. The ISO must provide a
documented recovery command that remounts the installed ESP/state, re-stages the
same certificate request with a new one-time password, and reboots to MokManager
again. Test cancellation, wrong password, timeout, and successful retry.

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
- Pinned mkosi semantic check and upgrade rehearsal.
- Package and artifact manifest validation.
- Runtime package identity works after installer-created `/var`; at minimum,
  `dpkg-query` can report the image's systemd and kernel packages.
- Root, verity, UUID, and UKI roothash agreement.
- Worst-case GPT labels remain at most 30 code units under the frozen version
  grammar.
- Signed-manifest acceptance and tampering rejection.
- Authenticated sysext-component manifest acceptance and tampering rejection.
- Byte-identical download from the public R2 endpoint.
- Root, verity, ESP, and disk capacity checks.
- Full release kernel-module and firmware retention checks for physical storage,
  networking, input, and product hardware.
- No active bootc or nbc updater.
- Default OS target and independently versioned sysext components update without
  a common-version collision.
- `systemd-sysupdate components` enumerates every shipped sysext component, and
  updex writes overrides only to the matching component path.
- Native stage/status/notification behavior.
- Transition from publication-disabled masks to static native timer activation
  works on an already-installed image.
- N through N+3 update and physical slot reuse.
- Explicit rollback.
- Corrupt unblessed update and three-attempt fallback.
- `/var` and `/etc` persistence.
- Native `/etc` drift listing, report, notification, and restore behavior.
- Secure Boot and measured UKI.
- Sole expected signed-PCR TPM token.
- Recovery-key unlock.
- No NvPCR setup failures.
- ISO boots through Debian's pre-enrollment Secure Boot chain and installs using
  public R2 assets.
- Installer-created TPM tokens are produced by the coherent systemd 261 toolset.
- MokManager cancellation and request-restaging recovery work.
- MOK and PCR private keys never appear in unprotected build logs, workspaces,
  caches, Actions artifacts, or R2 candidates.
- Public R2 responses bypass cache for both metadata files, and withdrawal
  restores a cryptographically matching manifest/signature pair.

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
- Rename of the raw prototype to `cayo-ab-raw` and secure publication guards.
- R2 path version.
- Public artifact naming.
- Image version format.
- Short partition labels, maximum version length, and six-code-unit margin.
- Default OS target plus one named component per independently versioned sysext.
- MOK, PCR, update, and R2 key ownership, custody, access, and rotation.
- Protected signing architecture and temporary protected-builder constraints.
- Debian-trusted installer ISO boot chain.
- Production kernel-module and firmware policy.
- Canonical secure and raw `/var` mount contracts.
- Pinned mkosi commit and mandatory upgrade-test policy.
- Capacity and retention policy.
- Minimum support overlap for bootc.

Exit criterion: static tests can validate all names and paths without building
an image.

### Phase 1: Fix Current Prototype Safety

Before further runtime qualification, mask bootc and nbc updater units in native
images, keep automatic sysupdate disabled, and add tests proving none can fail at
boot. Separate the default OS target from independently versioned sysext targets,
add component support to updex, and migrate each sysext transfer/feature pair to
its own component. Add signed sysext metadata or keep sysexts disabled on native
production candidates.

Adapt `snosi-etc-diff` to `/.etc.lower` and add native drift-report tests. Rename
the raw profile to `cayo-ab-raw`, reserve `cayo-ab` for secure production, shorten
the dynamic partition labels, and add static publication guards.

Exit criterion: the current prototype boots without failed legacy updaters,
updates its OS with two differently versioned sysext components enabled, reports
native `/etc` drift correctly, and cannot be mistaken for a publishable secure
profile.

### Phase 2: Factor Payload And `/var` Composition

Create shared Cayo and Snow composition fragments. Convert existing bootc
profiles to consume them without changing output. Convert the Cayo prototypes
and prove package/tree parity. Inventory all image `/var` content and define how
package metadata, state directories, tmpfiles, users, and first-boot seeds are
provided after the installer creates an empty encrypted `/var`.

Exit criterion: bootc image manifests remain intentionally unchanged, Cayo A/B
no longer omits payload build steps, and runtime package queries work after a
fresh native installation.

### Phase 3: Generalize Native A/B Output

Remove Cayo identity, URL, and capacities from the generic outformat. Add
per-product channel and repart fragments. Add the native public-name post-output
step and parameterize A/B tests. Remove the virtio-only final-root
`KernelModules=` filter, retain production modules and firmware, use canonical
secure `/dev/mapper/var` fstab entries, and preserve the deliberately
same-named native dracut override that shadows the base bootc configuration.
Add an in-file comment explaining that the matching filename is required for
ExtraTrees replacement and a static test that fails if both configurations can
survive assembly.

Exit criterion: Cayo, Snow, and Snowfield native artifacts can be built locally
with distinct labels, names, kernels, and capacities.

### Phase 4: Build Native Update UX

Add native staging, status, MOTD, and notification components. Keep automatic
staging disabled until publication, then introduce it through a static `/usr`
timer activation link rather than first-boot presets.

Exit criterion: boot tests prove each format starts exactly one update stack and
an already-installed publication-disabled image acquires the static native timer
when upgraded to the first publication-enabled image.

### Phase 5: Add Secure Snow

Build `snow-ab`, establish partition sizes, and validate desktop first boot,
GNOME, persistence, and secure update behavior.

Exit criterion: Snow completes installation, N through N+3, rollback, and
fallback in QEMU or Incus with Secure Boot and TPM unlock.

### Phase 6: Add Secure Snowfield

Build `snowfield-ab`, empirically determine Surface module trust under lockdown,
add only the signing/enrollment work proven necessary, establish capacities, and
run Secure Boot hardware validation.

Exit criterion: representative Surface hardware passes installation, desktop
boot, update, rollback, and fallback with required modules loaded.

### Phase 7: Productionize Signing And R2 Publication

Split unsigned construction from protected UKI/systemd-boot/PCR signing and final
ESP assembly. Ship the update pubring, protected signer, candidate upload, remote
verification, cache-bypass rules, per-product promotion, retention, and
public-origin integration tests.

Exit criterion: Cayo native update succeeds from the production R2 URL and a
tampered or partially published set fails closed.

### Phase 8: Build The Network Installer ISO

Create the ISO with Debian-signed shim, Debian-signed GRUB, and a Debian-signed
stock kernel plus coherent systemd 261 enrollment userspace. Generalize the
installer and add target-disk safety, signed download, per-machine LUKS,
recovery confirmation, TPM enrollment, MOK password/request/retry handling, and
product/channel recording.

Exit criterion: a clean VM can boot the R2-hosted ISO, install each product from
R2, complete MOK enrollment, and reach the installed system.

### Phase 9: Testing And Stable Promotion

Run candidate installations and multi-hop tests. Promote products independently
after their own gates pass. Publish GitHub release notes linking to R2.

Exit criterion: stable signed indexes exist for qualified products without any
change to bootc publication.

### Phase 10: Optional User Migration

Publish backup/reinstall instructions and migration export tooling. Continue
bootc updates through GHCR during the overlap period.

Exit criterion: migration is optional, documented, recoverable, and does not
require users to adopt an unqualified native product.

### Phase 11: Review Bootc Retirement

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
