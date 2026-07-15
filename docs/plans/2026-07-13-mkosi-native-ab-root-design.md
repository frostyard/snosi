# Design: Replace bootc with mkosi-native A/B root updates

## Status

Prototype boot path validated in QEMU on 2026-07-14. The isolated `cayo-ab`
profile boots an EROFS/dm-verity root with A/B slots, an ESP, persistent `/var`,
and a persistent `/etc` overlay. This is not production validation: do not
remove bootc until the external deployment gates and production acceptance
steps in this document pass.

**Validation complete:** four real cayo builds passed signed-manifest acceptance
and tamper rejection, missing UKI/verity and bad-checksum rejection, dm-verity
boot, `/var` and `/etc` persistence, explicit rollback, N to N+1 to N+2 to N+3
physical-slot reuse, and automatic fallback after all three attempts of a
corrupted unblessed update. **External deployment gates:** production OpenPGP
key custody and signed publication, per-profile disk sizing and conversion,
CI/release integration, installer/recovery media, real-hardware soak, and a
documented backup/reinstall/restore rollout for existing bootc systems.

The native profile must explicitly hand dracut's generated archive to mkosi via
`$ARTIFACTDIR/io.mkosi.initrd`. An in-image
`/usr/lib/modules/<version>/initramfs.img` is not automatically used for UKI
assembly; leaving `Initrds=` implicit makes mkosi embed its separate default
initrd without the snosi pre-pivot units. The profile therefore sets an empty
`Initrds=` and `KernelModulesInitrd=no` so the exported dracut archive is the
single authoritative UKI initrd.

## Goal

Replace bootc's OCI/composefs deployment model with a native GPT A/B root
layout built by mkosi/systemd-repart and updated by systemd-sysupdate. Keep
atomic, download-first updates, rollback, a read-only OS, persistent `/var`,
and the existing sysext mechanism.

## Why this is viable

mkosi 27 supports the required artifact model directly:

- `Format=disk` invokes systemd-repart to build a GPT disk image.
- `SplitArtifacts=partitions` emits independently publishable root, verity,
  and UKI artifacts.
- A verity root makes mkosi put the matching roothash on the UKI command line.
- `mkosi sysupdate` is a local integration test interface for
  systemd-sysupdate transfers.

systemd-sysupdate supports coordinated A/B partition and file transfers. A
single target version must contain matching root, root-verity, optional
root-verity-signature, and UKI artifacts. It writes all backing resources
before the UKI, so an interrupted transfer cannot create a boot entry with an
incomplete root. `ProtectVersion=%A` prevents replacement of the booted slot.
systemd-boot's UKI attempt counters select the prior working UKI after a new
one exhausts its attempts.

The upstream mkosi checkout's `docs/root-verity.md` contains the same
architecture, including the required inactive root/verity partition slots.

## Proposed disk layout

Use Discoverable Partitions Specification types and labels. All root slots
must have the same fixed size. Initial installation creates the active slot
with the built root and marks the other slot `_empty`.

| Resource | Count | Format | Purpose |
| --- | --- | --- | --- |
| ESP/XBOOTLDR | 1 | vfat | systemd-boot and versioned UKIs |
| root | 2 | erofs + dm-verity | immutable OS root slots |
| root-verity | 2 | dm-verity hash | integrity data for each root slot |
| root-verity-signature | 2 | optional | signed verity metadata if Secure Boot/TPM policy requires it |
| var | 1 | ext4 or btrfs | persistent state, including containers and sysext downloads |

`/etc` remains a writable overlay backed by persistent storage, using the
already-present dracut `etc-overlay` module. Unlike bootc, no deployment-time
three-way `/etc` merge occurs. The current bootc-specific guard exists solely
to avoid that merger failure. Multi-hop persistence, rollback, and fallback now
pass, but retain the conservative runtime `/etc` policy until the bootc path is
retired so dual-published images remain safe.

The prototype chose a `/var` partition independent of the machine ID and keeps
`machine-id=uninitialized` for true first-boot preset semantics. First boot
commits the generated identity into the persistent `/etc` overlay.

## Build and publishing model

Do not replace `shared/outformat/image` in the first phase. Existing profile
builds produce directories solely to package/sign OCI images for bootc.

Add a separate A/B disk build configuration for each profile:

- `Format=disk`, `Bootable=yes`, and `Bootloader=systemd-boot`.
- Repart definitions for the initial ESP, one populated root/verity set, and
  an empty root/verity set.
- `SplitArtifacts=partitions,uki,repart-definitions,roothash`.
- EROFS root with `Verity=data`; a matching root-verity partition with
  `Verity=hash`; optional `Verity=signature` if the signing design demands it.
- Explicitly mount `/dev/mapper/root` read-only and mask
  `systemd-growfs-root.service`: fixed-size EROFS slots must never be remounted
  writable or grown during boot.
- Versioned artifact names derived from `ImageId`, `ImageVersion`, and
  architecture. Use one canonical sortable version format everywhere.

CI builds the directory/OCI artifact and the disk/split artifacts in parallel
while bootc remains supported. The disk artifacts are published to a dedicated
R2 prefix, for example `https://repository.frostyard.org/os/snow/x86-64/`.
Publishing must create `SHA256SUMS` and a detached `SHA256SUMS.gpg`; the
systemd-sysupdate keyring must be shipped at
`/usr/lib/systemd/import-pubring.gpg`. Current sysext transfers use
`Verify=false`, which is not acceptable for the OS root.

The OCI image labels, chunkah chunking, Cosign signatures, and OCI SBOM
attachment do not authenticate sysupdate partition downloads. Retain them for
the bootc path only; establish equivalent artifact checksums, GPG signatures,
SBOM publication, and provenance before the A/B path becomes supported.

## In-image update definitions

Install four ordered transfers in `/usr/lib/sysupdate.d/`; all share the same
`@v` and `ProtectVersion=%A`:

1. `10-root-verity-sig.transfer` if signatures are used.
2. `11-root-verity.transfer`, target type `partition` and partition type
   `root-verity`.
3. `12-root.transfer`, target type `partition` and partition type `root`.
4. `20-uki.transfer`, target type `regular-file` at `$BOOT/EFI/Linux`.

All partition targets use `Path=auto`, `ReadOnly=yes`, `InstancesMax=2`, and
labels containing the version. The UKI target uses a BLS Type #2 filename with
`@v`, `@l`, and `@d`, `TriesLeft=3`, `TriesDone=0`, and `InstancesMax=2`.
The UKI transfer must be last because it is the activation point.

Source transfers use `Type=url-file`, the R2 prefix, a filename
`MatchPattern=` per artifact, and `Verify=yes`. Do not mix OS transfers with
optional sysext feature transfers: root, verity, and UKI must always update as
one target; sysexts remain independently optional.

Enable `systemd-sysupdate.timer` for hourly download/stage behavior.
Do not enable `systemd-sysupdate-reboot.timer`; a normal user or admin reboot
activates the new UKI, matching current snosi behavior.

Replace `snosi-update-status`, the MOTD hook, and desktop notification inputs
with `systemd-sysupdate list`, `check-new`, and `pending`. Preserve the
existing `/run/snosi/update-check` and `/run/snosi/update-staged` user
interface if it remains useful, but have the checker write it from sysupdate
state rather than `bootc status`.

## Installer model

The initial installer must write the native mkosi disk image, not unpack an
OCI container. `systemd-sysupdate --image=` can update an offline disk image,
but it does not create partitions; initial media must contain the full GPT
layout. The installer must:

1. Verify the disk artifact and its signed checksum manifest before writing.
2. Write the raw GPT image to the selected disk.
3. Grow/recreate only the intended persistent partitions using
   systemd-repart, never either root slot.
4. Set up first-boot identity and user provisioning without making the root
   writable.

The first installer spike is `test/cayo-ab-install-spike.sh`. It verifies a
caller-supplied SHA-256, validates the source GPT's required labels and two
empty slots, rejects mounted/non-disk/undersized targets, requires destructive
confirmation, and writes the complete sparse raw image. `--allow-file --yes`
exists only for disposable QEMU disk acceptance tests. Per-install identity,
signed manifests, and safe `/var` expansion remain production requirements;
the spike deliberately does not pretend a raw clone solves them.

The installer now relocates the backup GPT and grows only the physically last
`var` partition and its ext4 filesystem. It requires a 512-byte logical sector,
preserves and rechecks the partition start, and runs an offline filesystem
check. The same loop-device path is exercised for QEMU files and physical disks.

The image ships production-shaped root, root-verity, and UKI transfers with
`Verify=yes`, UUID-bearing source names, and boot counting. They intentionally
fail closed until a dedicated OS OpenPGP public key is committed as
`/usr/lib/systemd/import-pubring.gpg` and its externally held private key signs
published manifests. The unattended timers remain preset-disabled and masked
in the image `/etc` until then; the mask avoids first-boot enablement before
real-root preset policy is visible, while manual sysupdate remains available.
Partition payloads use XZ. Debian's systemd 257 `systemd-pull` binary supports
XZ, gzip, and bzip2 but not Zstandard; a `.zst`/`.zstd` payload is written
compressed into the partition and then fails dm-verity activation.

Existing bootc installs cannot migrate in place because their composefs/btrfs
layout has no compatible root slots. They require backup, reinstall, and
restore, as did the previous nbc-to-bootc migration.

## Secure Boot, TPM, and encrypted var spike

The spike resolves the intended security architecture as follows:

- Standard Secure Boot uses Debian's Microsoft-signed shim followed by
  MOK-signed systemd-boot. Snosi's generated UKIs are not Debian-signed, so their signing
  certificate requires one normal, one-time shim MokManager enrollment. This
  does not use UEFI setup mode, custom firmware db keys, or mkosi auto-enroll.
  There is no secure zero-enrollment route for custom snosi UKIs through Debian
  shim: without a MOK, shim correctly rejects them.
- `/var` is a generic ext4 placeholder in the published raw image and becomes a
  fresh per-machine LUKS2 volume in the installer. Encrypting it at image build
  time would clone LUKS metadata and key material across installations. The
  installer must retain a strong recovery passphrase outside the target disk.
- TPM automatic unlock authorizes PCR 11 through a separately signed
  expected-PCR policy embedded in each UKI and leaves the raw-PCR set empty.
  Installer-time PCR 7 binding is invalid: the Debian-signed installer and the
  installed MOK-signed UKI extend different boot authorities, so their PCR 7
  values differ. Binding to one raw PCR 11 value would make every update fail.
  Signed PCR 11 policy permits authorized future, rollback, and fallback UKIs
  without re-enrolling `/var` for every release, while shim/MOK independently
  enforces Secure Boot. Enrollment explicitly disables automatic pcrlock policy
  discovery so a file inherited from the installer environment cannot silently
  add a mutable machine-local policy.
- The encrypted DPS `var` partition is discovered and unlocked in the initrd as
  `/dev/mapper/var` before the persistent `/etc` overlay mounts. The baseline
  profile retains the raw ext4 fallback.
- A separate root-verity-signature partition is not required for this chain.
  The Secure Boot-authenticated UKI already authenticates its embedded
  `roothash`; adding another partition and transfer would duplicate that trust
  without protecting a distinct consumer.

`cayo-ab-secure` and the installer encode these choices. Static validation and
a real 14 GiB installer conversion proved unique LUKS2 creation. Incus validated
MOK enrollment, enforced Secure Boot and kernel lockdown, automatic TPM unlock
through signed PCR 11 policy, failure after TPM replacement, and recovery-key
unlock. A clean secure-profile build also installed Debian-signed shim,
MokManager, and MOK-signed systemd-boot on the ESP and generated a signed 114 MiB UKI containing
`.pcrpkey` and `.pcrsig`. Pinned mkosi's `UnifiedKernelImages=unsigned` value
selects local UKI construction; `SecureBoot=yes` signs the result, while the
`signed` value incorrectly requests a distro-prebuilt UKI. A GRUB-based N+1
installation proved partition and UKI transfer but rebooted N because GRUB's
generated configuration ignored the new Type #2 UKI and boot counter. Replacing
GRUB with MOK-signed systemd-boot then selected and loaded N+1 and mounted its
dm-verity root. A two-token PCR signing-key rotation attempt failed because
systemd 257 did not fall through from the stale lower-numbered TPM token to the
new token. A controlled systemd 261.1 test then bound token 0 to PCR 15, changed
that PCR to make token 0 stale, and left token 1 valid; debug logs proved that
261 rejected token 0, continued to token 1, and unlocked. A real signed-policy
key mismatch behaved differently: token 0 returned `ENXIO`, token 1 was never
tried, and recovery was required. Two independently signed TPM tokens therefore
cannot provide signing-key overlap, even on the tested systemd 261.1 build.

The working overlap design signs every transition UKI PCR policy with both old
and new keys while publishing the new key in `.pcrpkey`. The opt-in `ukify`
wrapper reads `PCR_SIGNING_KEY_PREVIOUS` as a filename under
`.snosi-private/history/`, adds the archived key as a second signer, and derives
the active public key inside mkosi's sandbox. The artifact test proved that the
transition UKI contains four policy digests, each signed by both keys, and that
`.pcrpkey` is the new key. A fresh MOK-enrolled Incus VM then booted that UKI and
automatically unlocked `/var` through old token 0/keyslot 1. After wiping the old
slot, the same UKI rebooted under enforced Secure Boot and automatically unlocked
through new token 1/keyslot 2. Keep the old token until every UKI inside the
supported rollback window carries the new signature; only then retire it.

`test/native-ab-secure-rotation-test.sh` now makes that runtime proof repeatable
for an already MOK-enrolled disposable VM. It requires an exact machine ID,
external recovery key, and explicit destructive confirmation. The harness first
proves recovery, installs the transition root, verity image, and UKI through
guest-local `systemd-sysupdate` with an ephemeral signed HTTP manifest and
`Verify=yes`, and establishes an old-only TPM state. It then requires an
unattended boot, enrolls the new token, removes the old token by public-key
fingerprint and discovered keyslot, and requires a second unattended boot of the
identical UKI in a new-only state. The checked run exercised signature
verification, the actual sysupdate transfer, the firmware-reported running UKI
hash, and both token transitions under enforced Secure Boot.
`test/native-ab-secure-artifact-negative-test.sh` separately requires structural
rejection of an unpaired PCR policy signature and an old published `.pcrpkey`.

The secure profile upgrades the complete exact-version systemd family to Forky
261+ through a profile-only APT sandbox pinned below Trixie; normal profiles
remain unchanged. The artifact test verifies package coherence, the matching
systemd private library and TPM token plugin in the initrd, expected-PCR UKI
sections, and optional dual-signature structure. Before production, extend this
to recovery after a fresh TPM, power-loss injection, and representative real
hardware. The complete secure N+1 through N+3 rollback/fallback window now passes
in Incus: N+2/N+3 updated with the sole new-key token, explicit rollback returned
to N+2, N+3 was selected again, and a re-armed/corrupted N+3 exhausted three
tries before automatic N+2 fallback.

Systemd 261's NvPCR anchor credential is a separate stale-key hazard: it embeds
the PCR public key used when it was created, has no supported migration command,
and failed with `ENXIO` when the first new-only UKI dropped the old signature.
This profile does not consume NvPCR attestation. Its finalize script therefore
masks all packaged NvPCR definitions and the product/login writer units while
retaining TPM SRK setup and signed-PCR LUKS unlock. A fresh new-only build with a
fresh sole TPM token booted without the NvPCR failures. Durable PCR keys were
also moved from mkosi-owned `.mkosi-private` to gitignored `.snosi-private`
because `mkosi clean -ff` removes the former.

## Production conversion and deployment

Complete these steps in order. Keep the current OCI/bootc path supported and
dual-published until the fleet migration and rollback window are complete.

1. **Freeze the production security contract.** Require standard Debian-shim
   Secure Boot, MOK-signed UKIs, signed PCR 11 policy, TPM-bound encrypted
   `/var`, a separate recovery passphrase, signed sysupdate manifests, and
   dm-verity; do not add a redundant root-verity-signature partition. Document
   key rotation, revocation, emergency rollback, artifact
   retention, and the minimum number of recoverable versions before changing
   the partition layout again.
2. **Create production signing custody.** Generate the dedicated offline OS
   OpenPGP key; commit only `/usr/lib/systemd/import-pubring.gpg`; store the
   private key in the release environment; support an overlap window for key
   rotation; and require detached `SHA256SUMS.gpg` verification. Test valid,
   expired/unknown-key, tampered-manifest, and rotated-key cases. The ephemeral
   key used by `test/native-ab-update-test.sh` proves systemd behavior but is not
   a production credential.
3. **Define one shared A/B outformat.** Promote `shared/outformat/ab-root` from
   cayo-only prototype code into the common native disk composition. Keep the
   validated invariants: exported dracut initrd, EROFS plus dm-verity, two fixed
   root/hash slots, machine-ID-independent final `/var`, persistent pre-pivot
   `/etc`, XZ partition payloads, `PartitionFlags=0`, absolute `/EFI/Linux`,
   `Verify=yes`, and UKI activation last with three boot attempts.
4. **Convert every profile separately.** Add native disk profiles for `cayo`,
   `snow`, and `snowfield`, initially alongside their existing OCI profiles.
   Compose each from its current packages, profile tree, presets, kernel, and
   postinstall behavior; do not fork shared units. Snow and snowfield must also
   validate graphical first setup, user presets, desktop notifications, and
   sysext application visibility. Snowfield must use the Surface kernel and its
   matching modules/initrd rather than inheriting snow's standard kernel. The
   17 sysexts remain independently published `/usr` overlays rather than A/B
   roots; validate every sysext against all compatible native profiles and keep
   its `.transfer`/`.feature`, required-path, service-activation, and icon-cache
   contracts unchanged unless the native base exposes a concrete incompatibility.
5. **Set profile-specific capacities.** Measure populated root and verity sizes
   for all three profiles with release-like package sets. Choose fixed slot
   sizes with documented growth headroom, establish minimum target-disk sizes,
   and make CI fail before publication if a split root/hash/UKI exceeds its
   partition or ESP budget. Exercise the installer on exactly-minimum and larger
   disks, 512-byte-sector hardware, and representative NVMe/SATA/USB devices.
6. **Build the publication pipeline.** Extend `build-images.yml` with native
   disk/split-artifact jobs for all profiles while retaining the OCI matrix.
   Rename split artifacts to the transfer contract with version, architecture,
   and UUID; compress partition payloads with XZ; generate one atomic manifest
   set per profile/architecture; attach SBOM and provenance; sign the final
   manifest; upload to a versioned staging prefix; verify it there; then publish
   the index last. Never expose a manifest that references incomplete uploads.
7. **Put the full harness in CI.** Automate four consecutive lightweight build
   versions and run `test/native-ab-update-test.sh` with KVM. Preserve coverage
   for missing UKI/verity, checksum and signature rejection, signed acceptance,
   dm-verity boot, persistence, explicit rollback, alternating slot reuse, and
   boot-count fallback. Add static checks for transfer ordering, keyring
   presence, size budgets, and the systemd 257 compatibility constraints.
8. **Complete installer and recovery media.** Replace the spike interface with
   supported profile-selecting installation media that verifies a signed disk
   manifest, confirms the whole target device, writes the matching raw image,
   grows only final `/var`, provisions per-machine identity/users, and records
   the installed channel. Provide rescue media and documented commands to list
   entries, select either slot, inspect dm-verity failures, restore `/etc`, and
   reinstall without silently destroying recoverable `/var` data.
9. **Replace bootc-facing update UX.** Implement native status, MOTD, and desktop
   notification state from `systemd-sysupdate list/check-new/pending` and boot
   assessment. Distinguish current, staged, failed, and fallback states. Enable
   the download/stage timer only after signed production publication and soak;
   continue applying updates on a natural reboot rather than force-rebooting.
10. **Run profile and hardware acceptance.** For cayo, snow, and snowfield,
    install from release media and perform signed N to N+1 to N+2 to N+3,
    rollback, corrupt-update fallback, power-loss-during-each-transfer, disk-full,
    network interruption, and key-rotation tests. Verify `/var`, `/etc`, machine
    identity, users, containers, sysext state, bootloader variables, and recovery
    after every transition. Soak representative server, generic desktop/laptop,
    and supported Surface hardware through multiple real publication cycles.
11. **Stage production rollout.** Dual-publish bootc and native artifacts; start
    with internal canaries, then opt-in cohorts per profile, with release holds
    and rollback criteria. Publish a migration runbook requiring backup,
    verified reinstall, restore, and post-restore checks because existing bootc
    disks cannot gain A/B partitions in place. Track installed format and do not
    offer native updates to bootc hosts or bootc updates to native hosts.
12. **Retire bootc only after fleet closure.** After the supported rollback
    window and confirmation that no supported install remains on bootc, remove
    the items in the removal inventory in a separate change. Stop OCI
    publication only when no external consumer depends on it, archive the final
    bootc recovery artifacts, update all operator/user documentation, and retain
    a tested reinstall path for machines discovered after cutoff.

## Removal inventory

Only remove these after native A/B installation and update tests pass:

- `bootc` and `libostree-1-1` plus their explicit runtime libraries from
  `mkosi.images/base/mkosi.conf`.
- composefs/ostree configuration and `bootc` dracut modules, including all
  duplicate profile `30-bootc-standard.conf` files.
- `bootc-update-stage`, its system and user notification units, its preset,
  and bootc-specific MOTD/status behavior.
- OCI buildah packaging, chunkah publishing, and the bootc installation/update
  test harness once no supported consumer needs OCI images.
- bootc-specific documentation, CI names, and validation assertions.

`frostyard-nbc` and `frostyard-updex` should not be treated as automatic
dependencies of the native design. The prototype must demonstrate that only
systemd-repart, systemd-sysupdate, systemd-boot, and mkosi artifacts are
needed; then remove both unless they still provide an explicitly retained
installer feature.

## Phased validation

Phases 1 and 3 passed locally on 2026-07-14 with builds `2026071410` and
`2026071411`. `test/native-ab-update-test.sh` serves an unsigned local fixture,
runs systemd 257 sysupdate inside QEMU, asserts both inactive partition UUIDs
and labels, boots N+1 under dm-verity, retains N, and verifies persistent `/var`
and `/etc` markers. The run identified three systemd 257 requirements now
encoded in the production transfers: absolute `/EFI/Linux`, explicit partition
flag reset, and XZ rather than unsupported Zstandard URL payloads.

The same harness passed two fail-closed cases with builds `2026071411` and
`2026071412`: a manifest missing the UKI was not considered a complete update,
and an intentionally wrong root checksum failed after downloading verity but
before committing either inactive partition label or the activation UKI. The
guest remained on N and subsequently accepted and booted the valid N+1 set.
The remaining spike cases passed with builds `2026071412` through `2026071415`:
missing verity was rejected as an incomplete set; an ephemeral OpenPGP keyring
accepted a valid manifest and rejected a tampered one; a one-shot boot returned
from N+1 to N; N+2 and N+3 reused the alternating physical root slots; and a
corrupted, unblessed N+3 exhausted `+3-0` through `+0-3` before systemd-boot
automatically selected N+2. Persistence markers survived every successful boot.
Production key custody/publication and hardware soak remain external gates.

1. Build a minimal `cayo` A/B disk locally. Inspect GPT types/labels, verify
   both root slot sizes, verify dm-verity, and boot the initial disk in QEMU.
2. Host two signed versions over local HTTPS. Run `mkosi sysupdate` against a
   copy of the disk and assert that only the inactive slots and a new UKI are
   written.
3. In QEMU, boot version N, create persistence markers in `/var` and `/etc`,
   run `systemd-sysupdate update`, and reboot. Assert version N+1 boots,
   `/var` and intended `/etc` state persist, and the old root slot remains
   available.
4. Failure inject a corrupt root payload, a missing verity payload, and a
   missing UKI. Each must reject before activation and leave N bootable.
5. Failure inject a new UKI that cannot reach `boot-complete.target`. Assert
   attempt counting automatically falls back to N, and verify the user-visible
   update state is cleared or marked failed accurately.
6. Repeat a three-hop chain plus manual rollback. Add the resulting test
   harness to CI before enabling a production update timer.
7. Run dual-published bootc and A/B artifacts through a hardware soak. Only
   then switch installer media and begin the documented reinstall migration.
8. Remove bootc in a final, separately reviewable change after all supported
   installs use the native layout.

## Risks and open decisions

- The disk requires space for two complete immutable roots, two verity hashes,
  ESP/XBOOTLDR artifacts, and persistent state. Establish profile-specific
  minimum disk sizes before publishing an installer.
- A fixed root slot cannot accept an image larger than its slot. CI must fail
  before publication when a split root artifact exceeds the allocated size.
- The baseline target ships systemd 257, while the secure profile carries an
  isolated Forky 261+ systemd family and the checked-in mkosi is 27~devel.
  Confirm every selected sysupdate/repart option against the version in each
  artifact; do not rely on newer host-side mkosi documentation alone.
- Root integrity requires signed manifests and a managed public-key rotation
  policy. TLS and the current unsigned sysext scheme are insufficient.
- The `/etc` overlay and persistent `/var` survived signed N through N+3,
  rollback, and fallback tests. Keep the runtime `/etc` guard while bootc and
  native formats are dual-supported; reassess it only after bootc retirement.
- Secure Boot, TPM-bound encrypted `/var`, recovery unlock, and PCR signing-key
  rotation are validated in MOK-enrolled Incus with swtpm; a separate signed
  dm-verity metadata partition is not selected. Signed secure updates, explicit
  rollback, new-key-only unlock, and boot-count fallback are also validated.
  Production remains blocked on representative hardware validation, fresh-TPM
  recovery automation, and power-loss coverage of that contract.
