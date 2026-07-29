# Bootc Secure Platform Design

## Scope

Add a production secure platform path for fresh `cayo`, `snow`, and
`snowfield` bootc installs. The path covers firmware Secure Boot, authenticated
OCI installation and updates, whole-state LUKS2 encryption, TPM2 unattended
unlock using signed PCR 11 policies, recovery unlock, updates, and rollback.

Existing bootc installations are outside the first release. They remain on the
current insecure-firmware path until a separately designed migration can enroll
trust and convert storage without risking an unbootable host.

## Trust Chain

The supported chain is:

```
Microsoft UEFI db
  -> Debian-signed shim
  -> MOK-signed systemd-boot
  -> MOK-signed UKI
  -> signed UKI composefs= digest
  -> composefs deployment from an authenticated OCI image
```

Bootc images reuse the native A/B MOK certificate and RSA-2048 PCR signing
identity. Private keys never enter an OCI image or installed system. MOK and
PCR rotation retain old trust for the complete supported rollback window; PCR
rotation uses dual-signed transition UKIs.

Published images contain a prebuilt UKI. `bootc container ukify` computes the
composefs image ID before the UKI is copied under `/boot`, avoiding a digest
cycle because boot resources are outside the composefs-measured root. The UKI
contains the kernel, initramfs, immutable command line, OS metadata,
`.pcrpkey`, and `.pcrsig`. Bootc's Type #2 path copies it to the ESP and manages
current and staged BLS entries.

Raw kernel/initramfs BLS entries are not an acceptable fallback for the secure
path because they do not authenticate the initramfs as one firmware-verified
unit.

## Storage And TPM

The external installer creates, per machine:

- one EFI System Partition;
- one DPS-typed root partition containing LUKS2;
- Btrfs inside the opened LUKS mapper.

The encrypted root contains the composefs repository, deployment-specific
`/etc`, shared `/var`, container storage, and host identity. A mandatory
external recovery passphrase remains enrolled alongside the TPM token.

Root discovery uses the Discoverable Partitions Specification rather than
per-machine `root=` or `luks.uuid=` arguments. This is required because bootc
1.16.3 rejects machine-local kernel arguments when consuming a prebuilt UKI.
The initramfs discovers the encrypted DPS root and unlocks it with a signed-PCR
11 policy. Enrollment uses no raw PCR set and disables pcrlock, matching the
native A/B policy.

## Build And Publication

The mkosi profiles continue to emit directory root filesystems. A secure
assembly step runs after mkosi and before Buildah packaging:

1. Validate exactly one kernel/initramfs pair.
2. Compute the composefs ID and build the UKI.
3. Sign expected PCR policies and the UKI.
4. Copy the UKI under `/boot/EFI/Linux`.
5. Install a MOK-signed systemd-boot EFI binary and the public trust material.
6. Validate signatures, sections, digest binding, and absence of private keys.
7. Package the root as OCI, push it, and Cosign-sign the immutable OCI digest.

Production keeps the existing public image names. Secure CI sets
`SNOSI_BOOTC_SECURE=1` and requires signing material. Local builds without that
setting remain available for insecure mechanics testing and carry an explicit
`secureboot-capable=false` marker. Publication rejects false or missing secure
markers.

The image ships a repository-scoped containers policy requiring the committed
Cosign key for the three Frostyard GHCR repositories. Fisherman verifies the
resolved immutable digest before executing the installer container. Bootc
installation enforces signature policy, and the runtime updater's Podman pull
uses the same policy.

## Installer Responsibilities

The existing `frostyard/bootc-installer` and `frostyard/fisherman` path remains
authoritative. It must:

1. Verify and pin the OCI image digest before writing the disk.
2. Refuse images not marked and validated as secure-capable.
3. Create the ESP and encrypted DPS root.
4. Invoke bootc's composefs `to-filesystem` path with systemd-boot and no
   machine-local kernel arguments.
5. Require a Type #2 UKI result.
6. Install Debian shim, MokManager, and MOK-signed systemd-boot.
7. Stage MOK enrollment and support restaging without reinstalling.
8. Enroll the LUKS TPM token from the installed UKI's PCR public key.
9. Test recovery unlock and remove temporary secrets.
10. Record image, composefs, UKI, MOK, PCR, LUKS, and installer provenance.

## Runtime And Recovery

Bootc stages only OCI deployments accepted by Podman policy. A failed pull,
UKI/digest mismatch, ESP write, or post-stage digest check leaves the current
deployment intact and records `outcome=failed` through the existing update
status surfaces.

A static `/usr`-activated service reconciles only the MOK-signed systemd-boot
second stage after a successful boot into a newer authenticated deployment. It
never replaces shim and never performs runtime unit enablement changes under
`/etc`.

Supported recovery operations are:

- restage MOK enrollment from installer media;
- unlock with the external recovery passphrase and enroll a replacement TPM;
- use bootc rollback to a retained signed deployment;
- reconstruct verified ESP contents without modifying encrypted state.

Loss of both the TPM authorization path and recovery passphrase is intentionally
unrecoverable.

## Validation Gates

Implementation is phased and fail-closed:

1. Prove a UKI can be sealed to the pinned bootc composefs digest without a
   digest cycle.
2. Prove bootc `to-filesystem` supports an externally created DPS LUKS/Btrfs
   root with a Type #2 UKI and no dynamic kernel arguments.
3. Prove Debian shim rejects the unenrolled chain and launches the MOK-signed
   systemd-boot and UKI after enrollment.
4. Prove signed-PCR-11 TPM unlock and recovery unlock.
5. Prove a signed N to N+1 bootc update and rollback under the same chain.

Failure of gates 1 or 2 requires an upstream bootc change or a focused patch in
`frostyard/bootc-debian`. It must not be hidden in installer shell code.

Production support requires all three profiles to pass enforced-Secure-Boot
install and update tests. Snowfield also retains its Surface module-trust and
representative-hardware gates. bcvk remains supplemental; it is not the
authority for Secure Boot validation.
