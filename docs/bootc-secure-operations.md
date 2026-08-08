# Bootc Secure Operations Runbook

> [!WARNING]
> Implementation and fixture contracts are complete, but production support is
> withheld pending live install, update, and rotation evidence for each profile
> and representative Snowfield hardware evidence. The 2026-07-27 published
> `latest` images lack the secure capability label and are not secure-install
> evidence. A missing runner or authorized artifact must remain visibly
> `BLOCKED:`; fixture success is not live security evidence.

This is the normative operator entry point for the secure bootc path. It applies
only to fresh `cayo`, `snow`, and `snowfield` installs. The detailed external
installer contract is [docs/bootc-secure-install-contract.md](bootc-secure-install-contract.md),
the assembly compatibility contract is [docs/bootc-secure-assembly-compatibility.md](bootc-secure-assembly-compatibility.md),
and the image schema source is
[shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json](../shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json).

## Support Status

Secure image assembly, static contracts, fixture contracts, and CI mechanics are
implemented. They do not establish a supported production path. Live evidence
remains blocked until authorized signed secure N/N+1/N+2 and transition OCI
artifacts, prepared Dakota/bootc-installer/Fisherman runners, and representative
Snowfield hardware results exist. Do not use an image unless inspection confirms
`io.snosi.bootc.secureboot-capable=true` and
`io.snosi.bootc.secureboot-assembly=bootc-1.16.3-storage-digest-v1`.

## Trust Boundaries

The trust chain is Microsoft UEFI db to Debian shim, then an enrolled MOK to
systemd-boot and Type #2 UKIs. Signed PCR 11 policies authorize TPM unlock
without raw-PCR pinning. The external recovery passphrase independently
authenticates LUKS. The committed Cosign public key and repository-scoped
containers policy authenticate OCI pulls. The UKI `composefs=` value binds the
booted code to the authenticated deployment content.

Private MOK and PCR keys never enter OCI images or installed systems.
The recovery credential is separate from signing authority and never belongs in
an OCI image, recipe, log, provenance record, firmware variable, or retained
test state.

That statement covers Frostyard release-signing identities. The optional
machine-local key created by `snosi-kargs key generate` is a separate operator
choice stored under `/var/lib/snosi/kargs/`; it never becomes release authority
and carries the wider local trust warning documented in
[`docs/snosi-kargs.md`](snosi-kargs.md).

## Build Modes And Publication

PR mechanics builds are secretless and may only create images labelled insecure.
Protected `secure-build` is the only OCI publisher: it materializes the
production identities only for local assembly and validation, verifies an
immutable version digest before moving `latest`, deletes credentials before any
registry write, and then advances the tracking tag.

GitHub's `native-build` environment must be restricted to protected/default
branches and have no required reviewer. Root Skopeo receives the Docker login auth file explicitly through --src-authfile.
Every GHCR read and write in secure verification and promotion receives the Docker login config explicitly.
Pinned Cosign v2.6.1 receives registry auth through command-scoped DOCKER_CONFIG.
The Docker auth file from `docker/login-action` must be directly consumable by
root Skopeo without user-scoped credential-helper state; otherwise verification
fails closed. The next protected run remains the live proof. Do not rely on
inherited `XDG_RUNTIME_DIR`, root Buildah credentials, or registry visibility as
the authentication mechanism for the policy-copy gate. Candidate publication,
tag movement, and an image labelled secure are not substitutes for the blocked
live installation and hardware gates.

Skopeo inspections use `--authfile`, root policy copy uses source-only
`--src-authfile`, and promotion uses source and destination auth files. Pinned
Cosign has no registry-config flag; its command receives only the config
directory through `DOCKER_CONFIG`. Version-tag resolution must equal the pushed
digest before policy copy.

## Fresh Installation

This procedure describes acceptance criteria, not an installer command. The
privileged installation action is owned by the external Dakota,
bootc-installer, and Fisherman implementation.

Before that action, require all of the following:

1. A freshly built Debian-trusted Dakota ISO.
2. An accepted immutable `ghcr.io/frostyard/<profile>@sha256:...` reference and
   a separate tracking tag in the same repository.
3. Public MOK and PCR identities that byte-match the selected image.
4. A blank target of at least 30 GiB and an externally held mode-0600 recovery
   file.
5. UEFI Secure Boot and TPM 2.0 hardware.

The external installer must refuse before writes if capability, OCI signature,
hardware, disk, or public-identity checks fail. It must prove pre-enrollment
shim rejection, enroll the MOK with MokManager in the same firmware state, and
then prove an unattended TPM boot. It creates one 1 GiB ESP and a DPS LUKS2/Btrfs
root opened exactly as `/dev/mapper/root`; it must not add machine-specific root
or LUKS kernel arguments.

After completion, use only public or non-secret installed-state data for
verification. Confirm the immutable provenance record, Type #2 BLS entry, UKI
hash and composefs identity, public MOK/PCR fingerprints, and one TPM token.
Treat absent external runners or artifacts as `BLOCKED:` rather than attempting
an unsupported manual substitute.

## Recovery Credential Custody

Create the recovery passphrase externally in a mode-0600 regular file and keep
its only durable copy outside the installed disk, OCI registry, CI artifacts,
and repository. Supply its path only to the authorized external action. Verify
it non-destructively before recovery or TPM changes with `cryptsetup open
--test-passphrase`, then remove any installer-owned temporary copy.

Loss of both TPM authorization and the external recovery passphrase is unrecoverable.

## MOK Restage

**External privileged action:** Dakota/bootc-installer/Fisherman owns MOK
restage. Snosi provides no CLI for it.

Preconditions: authenticate the existing encrypted root with the recovery
credential, retain the same immutable installed deployment and firmware state,
and identify the installed public MOK fingerprint. The external action repeats
only MokManager enrollment staging for that authenticated MOK certificate.
It must not repartition, reinstall, or replace the deployment.

After approval in the same firmware state, verify `mokutil --sb-state`, the
enrolled public certificate fingerprint, and MOK signatures on systemd-boot and
unlock test result as evidence.

## TPM Replacement And Recovery Reenrollment

**External privileged action:** Dakota/bootc-installer/Fisherman owns TPM
replacement and reenrollment. Snosi provides no CLI for it.

### Clear the stale SRK after replacing a TPM

Rotating the LUKS TPM token is not sufficient. systemd separately stores the
SRK public key of the TPM it last saw, and after a **replacement** that stored
key belongs to the old device. `systemd-tpm2-setup` and
`systemd-tpm2-setup-early` then fail on every subsequent boot:

```text
TPM key integrity check failed. Key most likely does not belong to this TPM.
```

The system still boots and still TPM-unlocks — the LUKS token is independent of
this — but it is permanently `degraded`. Remove the stale key so systemd
re-derives it from the new TPM on the next boot:

```bash
# /var on a composefs deployment is state/os/<stateroot>/var. <root>/var also
# exists, is a different directory, and nothing mounts it.
rm -f /var/lib/systemd/tpm2-srk-public-key.pem
```

Offline, with the root mounted at `$m`, that path is
`$m/state/os/<stateroot>/var/lib/systemd/tpm2-srk-public-key.pem`; assert the
stateroot glob matches exactly one existing directory before writing, or the
removal silently does nothing.

This is not required for reenrollment against the **same** TPM, where the
stored key is still correct.

NvPCR is a separate matter and needs no operator action: the secure profiles do
not consume NvPCR attestation, and `systemd-pcrproduct`/`systemd-pcrlogin@` are
masked in the shipped image precisely because their anchor cannot survive a
TPM change or a PCR signing key rotation.

`/dev/mapper/root` remains the opened Btrfs mapper for mounting and runtime; it
is not the LUKS2 device. Before recovery authentication or TPM enrollment,
derive and validate exactly one LUKS2 backing device:

```bash
ROOT_BACKING_DEVICE=$(cryptsetup status root | awk '/^[[:space:]]*device:/{print $2; exit}')
ROOT_BACKING_DEVICE_COUNT=$(cryptsetup status root | awk '/^[[:space:]]*device:/{print $2}' | grep -Ec '^/dev/')
[[ "$ROOT_BACKING_DEVICE_COUNT" -eq 1 ]]
[[ "$ROOT_BACKING_DEVICE" == /dev/* && "$ROOT_BACKING_DEVICE" != *$'\n'* ]]
cryptsetup isLuks "$ROOT_BACKING_DEVICE"
cryptsetup open --test-passphrase --key-file "$RECOVERY_KEY" "$ROOT_BACKING_DEVICE"
```

Preserve the immutable OCI reference, image version, installed UKI hash, and
installed `.pcrpkey` public identity. The authorized action must enroll the
replacement TPM against that installed UKI public key, using this exact command:

```bash
systemd-cryptenroll --unlock-key-file="$RECOVERY_KEY" --tpm2-device=auto --tpm2-pcrs= --tpm2-public-key="$INSTALLED_PCR_PUBLIC_KEY" --tpm2-public-key-pcrs=11 --tpm2-pcrlock= "$ROOT_BACKING_DEVICE"
```

Afterward, record the new token ID, prove the old token is unavailable, repeat
the non-destructive recovery verification against `"$ROOT_BACKING_DEVICE"`, and
prove a distinct unattended boot using the replacement TPM. Do not retain
recovery bytes, TPM state, or writable firmware variables in the evidence
record.

## ESP Repair

**External privileged action:** Dakota/bootc-installer/Fisherman owns ESP
repair. Snosi provides no general ESP reconstruction CLI.

The narrow exception is [`snosi-kargs`](snosi-kargs.md), which owns only
`loader/addons/50-snosi-local.addon.efi`. It may mount the one ESP beside the
encrypted root when `bootctl` cannot identify an existing writable mount, and
uses verified same-filesystem replacement with restoration on sync failure. It
does not repair or modify shim, MokManager, systemd-boot, UKIs, or BLS metadata.
Bootc persistence of this addon across a deployment update remains `BLOCKED:`
pending the external live runner and authorized secure OCI artifacts.

Preconditions: recovery-authenticate the existing encrypted root; retain the
immutable deployment reference, composefs ID, expected UKI hash, MOK public
certificate, and PCR public identity; and identify the one ESP beside the root
backing partition. The external action reconstructs only the ESP from the
authenticated deployment and must verify hashes and signatures for Debian shim,
MokManager, MOK-signed systemd-boot, Type #2 UKIs, and BLS metadata.

Post-action verification uses `sbverify --list` for signed PE files, `sha256sum
--check` for recorded hashes, and `bootctl --esp-path=<mounted-esp> --no-pager
status` for the selected Type #2 entry. ESP repair cannot alter deployment state,
`/etc`, `/var`, LUKS metadata, or recovery credentials.

## PCR Signing-Key Rotation

**External privileged action:** the authorized release and external installer
implementations own the live ceremony. Snosi provides no rotation CLI.

1. Generate new RSA-2048, default-exponent PCR material offline; retain only
   the approved public identity in the release workflow.
2. Review public fingerprints and collect old-only baseline boot, token, and
   recovery evidence.
3. Build and validate a dual-PCR transition UKI, then enroll the new TPM token
   from that transition UKI.
4. Publish and prove a new-PCR-only build, including retained rollback boot.
5. Retire the old token only after the rollback proof is complete.

Dual-PCR transition policy is not fallback across independent TPM tokens.
Current CI does not materialize historical production keys or publish transition
artifacts automatically, so the live ceremony remains blocked until authorized
inputs exist.

## MOK Rotation

**External privileged action:** the authorized release and external installer
implementations own MOK rotation. Snosi provides no rotation CLI.

1. Generate an offline RSA-4096 MOK identity and review its public fingerprint.
2. Enroll the new certificate while old trust remains in firmware.
3. Publish new-MOK-signed systemd-boot and UKIs, then prove reconciler behavior
   and boot them under the enrolled trust.
4. Retire every old-signed rollback deployment and prove the complete rollback
   window is gone.
5. Delete old firmware trust and prove old-only content is rejected.

A PE binary does not need dual Authenticode signatures; overlap lives in
enrolled firmware trust. Remove the old MOK only after every old-signed rollback deployment is retired.

## CI Evidence Tiers

| Tier | Proves | Does not prove |
| --- | --- | --- |
| PR mechanics | Secretless build composition and insecure-label mechanics | Signed assembly, registry publication, installation, or Secure Boot |
| Candidate | Protected assembly validation and immutable candidate verification | A successful external install or update |
| Nightly | Ephemeral-key secure-chain regression coverage | Production identities, published artifacts, or hardware coverage |
| Full-window | Prepared runner evidence across update, rollback, and transition windows | Representative Surface hardware behavior |
| Hardware | The required representative device's install, input, power, update, rollback, and fallback evidence | Other hardware models or a generalized production claim |
| Legacy mechanics | Existing bootc/nbc behavior and migration mechanics | Conversion to the secure DPS LUKS/MOK/TPM layout |

## Existing Installations

Existing bootc and nbc installations cannot be converted in place to this secure layout.

Back up required user data and wait for the fresh-install path to clear its
support gates. Do not use ESP repair, MOK restage, TPM reenrollment, or a
registry tag change as a conversion mechanism.

## Incident Response

| Signal | Immediate response | Required recovery evidence |
| --- | --- | --- |
| Unsigned, wrong-key, or wrong-repository OCI | Stop the install/update, preserve the rejected immutable ref and policy result, and do not weaken policy | Rejection output, immutable digest, policy and public-key fingerprints |
| False or missing capability label | Refuse before writes; do not fall back to an insecure image | Inspected label, digest, and refusal output |
| Wrong-MOK or composefs-mismatched UKI | Stop boot/installation, retain hashes and public fingerprints, and rebuild from an authorized immutable ref | `sbverify` output, UKI hash, composefs comparison, and console evidence |
| ESP full, interrupted finalization, or reconciliation failure | Keep the authenticated deployment intact; use only the external ESP repair action after recovery authentication | ESP free-space/error logs, repaired hashes/signatures, and successful Type #2 boot |
| TPM replacement | Authenticate recovery first, use the external reenrollment action, and prove new-token unattended boot | Recovery test, old-token-unavailable result, new token ID, and new boot ID |
| Lost recovery credential | Stop destructive operations and determine whether current TPM authorization remains available | Custody incident record; if TPM authorization is also lost, record unrecoverable status |
| Suspected MOK/PCR private-key compromise | Stop publication and tag movement, preserve immutable digests and sanitized logs, withdraw unsupported candidates, and rotate through an authorized overlap window | Public fingerprints, replacement build refs, CI URLs, rollback-retirement proof, and revocation results |

Never delete current trust in response to a suspected compromise before a
verified replacement has booted and affected rollback deployments are retired.

## Evidence Retention

For every installation, repair, or rotation, retain public fingerprints,
immutable references and digests, image versions, CI run URLs, console and
runtime evidence, TPM token IDs, and timestamps. Preserve only sanitized logs
and public metadata. Never retain private keys, recovery bytes, MOK passwords,
TPM state, writable firmware variables, or copied installer credentials.
