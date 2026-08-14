# Bootc Secure Installation Contract

This is the contract between Snosi secure OCI images and the external
`frostyard/fisherman`, `frostyard/bootc-installer`, and
`frostyard/dakota-iso` repositories. It applies only to fresh installs of
`cayo`, `snow`, and `snowfield`. It does not authorize an in-place conversion
of existing bootc or nbc installations.

The machine-readable source is
`/usr/lib/snosi/bootc-secure.json` in the verified OCI image. Consumers must
require `schema == 1`, reject unknown values for enumerated fields, and reject
an image missing any required field. Schema 1 is additive: its existing top
level MOK, PCR, encrypted-root-mapper, systemd, and assembly fields remain
authoritative. The `installer` object defines the requirements below.

## Prerequisites

- The installer medium must provide bootc `1.16.8` exactly, and at minimum
  Cosign `2.6.1` and the coherent Forky systemd `261.1-3` family. The two
  policies are deliberately different:

  - **bootc is an exact pin.** The secure assembly depends on observed,
    non-upstream-stable behaviour of that release — the hidden storage-digest
    command and the two-pass ukify sequence — so a newer bootc is the change
    most likely to break it without failing loudly.
  - **systemd and Cosign are floors.** What the systemd requirement guards at
    install time is tooling behaviour (`systemd-cryptenroll` TPM sealing,
    `bootctl`, `systemd-repart`); the installed system's systemd family is
    pinned and validated separately at image build time. A version above the
    floor that has not been validated end to end installs and emits a warning,
    recorded in the install provenance — it is never silently treated as
    validated. Revalidate the secure assembly compatibility contract before
    relying on such a combination.

  An exact pin on a medium that is rebuilt routinely creates standing pressure
  to edit the pinned number instead of revalidating the change, and a check
  maintainers are trained to defeat protects nothing. The floor plus warning
  keeps the signal without the treadmill.

- Install provenance records the versions **detected on the medium**, not the
  values declared here, so "what actually ran" is answerable after the fact.
- The target disk must be at least `32212254720` bytes (30 GiB). This covers
  the online pull, OCI cache, and deployed composefs state; it is not a claim
  about the eventual steady-state free space.
- A regular-file target must be a `qemu-img` raw image. Block devices are
  accepted directly; qcow2 and other regular-file formats are refused.
- Firmware must boot in UEFI Secure Boot mode and expose a TPM 2.0 device.
  The operator must supply and retain an external recovery passphrase.

## Task 9 External Test Runner Protocol

This section is a test-only protocol between the external repositories and
Snosi's Task 9 harness. It is not image runtime contract data and must not be
copied into `bootc-secure.json`.

The harness creates a writable work directory, copies the shared firmware from
`/usr/share/OVMF/OVMF_CODE_4M.secboot.fd` and
`/usr/share/OVMF/OVMF_VARS_4M.ms.fd`, then starts one persistent swtpm state
directory before invoking the installer. It exports these exact paths to every
external runner:

```text
SNOSI_SECURE_OVMF_CODE=<work>/OVMF_CODE.fd
SNOSI_SECURE_OVMF_VARS=<work>/OVMF_VARS.fd
SNOSI_SECURE_TPM_STATE=<work>/tpm
SNOSI_SECURE_TPM_SOCKET=<work>/tpm/swtpm-ctrl.sock
```

The installer runner must use that state, not create a replacement varstore or
TPM, and is invoked exactly as:

```text
BOOTC_SECURE_INSTALLER --non-interactive --iso "$DAKOTA_ISO" --recipe "$RECIPE"
```

`$RECIPE` is UTF-8 JSON with exactly the harness-owned keys `schema` (integer
`1`), `profile`, `oci_ref`, `tracking_ref`, `target_disk`, `recovery_key`,
`mok_certificate`, `pcr_public_key`, and `root_ssh_authorized_key`.
`tracking_ref` must be a tag in the same `ghcr.io/frostyard/<profile>`
repository as `oci_ref`. The runner exits zero only after its supported
non-interactive Dakota path has completed and emits the literal line
`BOOTC_SECURE_INSTALLER: installed`. Exit zero without that marker is a failure;
`/bin/true` is not an acceptable test runner.

This harness does not require a negative-fixture runner. It proves that a good
image installs and boots; it does not prove that a bad one is refused.

Refusal is enforced elsewhere and is not re-proven here: the shipped
`/etc/containers/policy.json` rejects by default and accepts only the exact
`sigstoreSigned` scopes (see `docs/bootc-secure-operations.md`), and
`test/bootc-container-policy-test.sh RUN_LIVE=1` exercises unsigned, wrong-key,
and wrong-repository rejection through Podman against real published images.
What is NOT covered by that, and is currently unproven, is refusal at
install time by this path: a deliberately-broken image reaching the installer.

The removed contract required nine causal fixtures (`unsigned`, `wrong-key`,
`wrong-repository`, `false-capability`, `wrong-mok-uki`, `composefs-mismatch`,
`esp-full`, `interrupted-finalize`, `reconcile-failure`). Six of them needed
published, deliberately-broken, signed OCI artifacts -- valid in every respect
except the single property under test, or the refusal proves nothing about the
control it claims to exercise. That cost was judged not worth paying. If it is
revisited, reinstate the causal requirement rather than a weaker check: a
negative test that cannot distinguish "refused for this reason" from "refused
for any reason" reports green while the control is absent.

`tpm-replacement` and `recovery-reenrollment` are positive recovery operations.
For each, the harness invokes:

```text
BOOTC_SECURE_RECOVERY_COMMAND --case <case> --profile "$PROFILE" --oci-ref "$OCI_REF" --state "$STATE" --iso "$DAKOTA_ISO" --recipe "$RECIPE" --recovery-key "$RECOVERY_KEY"
```

Before stopping QEMU and swtpm, the harness writes `$STATE` under its owned work
directory with mode 0600. It has the same path-only schema as the exported
install handoff, including the SSH private-key path, and no secret bytes. The
command receives the same four `SNOSI_SECURE_*` variables, exits zero, and emits
both `BOOTC_SECURE_RECOVERY: <case>: complete` and
`BOOTC_SECURE_RECOVERY: <case>: old-token-unavailable`. The harness then proves
a distinct single TPM-token identity, retained recovery unlock, and an
unattended reboot with a distinct boot ID. Before starting this command the
harness stops its QEMU and swtpm processes and removes only their owned socket
and pid files. The recovery runner exclusively owns the shared target disk,
OVMF varstore, TPM state directory, and TPM socket for its invocation; it must
leave them stopped. The harness then restarts swtpm against the same state and
boots the target before checking the new token. It never manipulates those
shared resources concurrently with the runner.
For example, TPM replacement emits
`BOOTC_SECURE_RECOVERY: tpm-replacement: complete`.

## Task 9 Update Runner Protocol

`test/bootc-secure-install-test.sh` can retain an installed target for the
separate update harness when `BOOTC_SECURE_INSTALL_STATE` names a new state
file and `TRACKING_REF=ghcr.io/frostyard/<profile>:<tag>` is supplied. The
file is mode 0600 JSON with only paths and public identifiers: the installed
disk, OVMF code/vars paths, persistent swtpm directory/socket path, recovery
credential path, profile, tracking tag, accepted immutable N reference,
public MOK/PCR identity paths, and SSH private-key path. It never serializes
credential or key bytes. The install harness stops only its QEMU and swtpm
processes before retaining that state directory.

The update harness requires two distinct immutable matching profile references
(`UPDATE_N1_REF`, `UPDATE_N2_REF`) that differ from accepted N, plus matching
`UPDATE_N1_VERSION` and `UPDATE_N2_VERSION` values. Versions use Snosi's exact
14-digit UTC image-version grammar (`^[0-9]{14}$`) and must differ. The harness
requires the running `IMAGE_VERSION` after N+1, N+2, rollback, and return to
match the expected published version; deployment-digest checks remain
cross-transport continuity checks and never compare registry and storage
digests directly. It invokes the external publisher as:

```text
BOOTC_SECURE_UPDATE_PUBLISH_COMMAND --profile "$PROFILE" --tracking-ref "$TRACKING_REF" --slot N+1|N+2 --digest-ref "$REF"
```

The publisher must atomically advance that same tag to the accepted immutable
reference and emit exactly the marker for its supplied slot,
`BOOTC_SECURE_UPDATE_PUBLISH: N+1: published` or
`BOOTC_SECURE_UPDATE_PUBLISH: N+2: published`. A no-op marker is rejected.
The installed host follows `TRACKING_REF`, while installer provenance records
both `tracking_ref` and the accepted immutable N `oci_ref`.

While the VM is live, an external runner may
use only the registry and SSH to exercise the installed updater. It must never
open or mutate the target disk, TPM state directory/socket, or OVMF vars
directly. This rule was written for the removed negative runner but is not
specific to it: it applies to every runner the harness invokes against a
running guest, the publisher included.

The update harness requires no negative runner either, for the same reason and
by the same decision as the install path above. It proves that a good N+1/N+2
is taken, that rollback returns, and that secure invariants survive each hop;
it does not prove that a bad update is refused. `bootc-update-stage`'s own
policy rejection remains enforced at runtime and is covered by
`test/bootc-container-policy-test.sh`, not by this harness.

## Task 10 Rotation Runner Protocol

`test/bootc-secure-rotation-test.sh` is the fixture-tested contract for an
external full-window key-rotation runner. It consumes a Task 9 install-state
manifest and the runner inputs below. The manifest and the recovery credential
it names must both be regular files with mode `0600`; it has the Task 9
path-only schema and must not contain secret-bearing fields. The old,
transition, and new references must be distinct immutable
`ghcr.io/frostyard/<profile>@sha256:<digest>` references for the manifest's
`cayo`, `snow`, or `snowfield` profile repository. Old and new public MOK and
PCR identity files must exist.

The harness invokes `BOOTC_SECURE_ROTATION_COMMAND` exactly once for each phase,
in this order, with `--phase` followed by the same `--state`, three reference,
and four public-identity arguments on every invocation:

1. `old-only` establishes the old MOK/PCR baseline.
2. `dual-pcr` proves that the transition UKI unlocks using old authorization,
   then enrolls the new TPM token.
3. `new-pcr` proves new-PCR-only policy while retained rollback still boots.
4. `mok-overlap` enrolls the new MOK while retaining the old certificate until
   all old rollback deployments are retired.
5. `new-mok` boots and reconciles new-MOK-signed content.
6. `old-trust-removed` retires old rollback content before deleting the old
   MOK, rejects old-only content, and proves recovery remains usable.

Each successful phase emits the exact line
`BOOTC_SECURE_ROTATION: <phase>: complete`. Zero exit without that whole line,
or output containing `NOOP` or `no-op`, is rejected. The final phase additionally
emits both `BOOTC_SECURE_ROTATION: old-trust-removed: old-mok-rejected` and
`BOOTC_SECURE_ROTATION: old-trust-removed: recovery-ready`. A nonzero runner
exit is a runner failure, not proof of a security refusal.

Live execution requires explicit transition artifacts and an executable
external runner. Until they exist, missing or invalid requirements print
`BLOCKED: Task 10 bootc rotation proof requires:` and return status `2` before
the harness invokes the runner. Fixture success proves only this runner
protocol, not a completed secure rotation.

## OCI Acceptance

Fisherman resolves the selected supported GHCR tag to an immutable digest,
verifies that digest with the committed Cosign public key, and installs only
the resulting `repository@sha256:...` reference. It must inspect the verified
image and require
`io.snosi.bootc.secureboot-capable=true`; missing or false is a refusal, not a
fallback to an insecure install.

The installer must use the image's
`/etc/containers/policy.json`, whose policy is globally rejecting and accepts
only the exact Snosi repository with `matchRepository` identity. It must not
use `--skip-fetch-check`, broaden the policy, or replace the digest with a tag
after verification. The policy permits the subsequent local
`containers-storage` bootc handoff only after Podman accepted the registry
image.

## Disk And Bootc Installation

The installer creates exactly these per-machine partitions on the target disk:

- An EFI System Partition with type
  `c12a7328-f81f-11d2-ba4b-00a0c93ec93b` and at least `1073741824` bytes.
- One x86-64 DPS root partition with type
  `4f68bce3-e8cd-4db1-96e7-fbcaf984b709`, formatted as LUKS2 and opened as
  `/dev/mapper/root`.
- Btrfs inside that mapper. The encrypted root holds bootc deployment state,
  deployment `/etc`, shared `/var`, container storage, and host identity.

The bootc invocation has this required option prefix:

```text
bootc install to-filesystem --composefs-backend --bootloader systemd --root-mount-spec ""
```

Fisherman appends the prepared Btrfs mount path according to bootc's CLI. It
must not introduce machine-specific root or LUKS kernel arguments.
Fisherman must not pass `--karg`.
The empty root mount specification preserves DPS discovery for the prebuilt UKI.

Installation succeeds only if BLS metadata has an `efi=` entry for a Type #2
UKI and no raw `linux` or `initrd` fallback entries. The installed UKI's
composefs identity must match the installed deployment.

## Secure Boot, TPM, And Recovery

The ESP must contain Debian-signed shim as `EFI/BOOT/BOOTX64.EFI`, MokManager
as `EFI/BOOT/mmx64.efi`, and the MOK-signed systemd-boot second stage as
`EFI/BOOT/grubx64.efi`. The installer verifies the second stage against
`mok_certificate` before placing it. It stages that certificate with MokManager
for one-time operator approval and must provide a restage action that repeats
only this enrollment staging without repartitioning or reinstalling.

After the installed Type #2 UKI is present, resolve the installed BLS `efi=`
entry and extract its `.pcrpkey` to a private temporary file. Byte-compare the
extracted key with `pcr_public_key`; refusal is required if the section is
missing, unreadable, or differs. TPM enrollment uses the extracted
`.pcrpkey`, not the rootfs copy, so it is bound to the installed UKI.

`/dev/mapper/root` is the opened Btrfs mapper used for mounting and runtime; it
is not the LUKS2 device. Before any LUKS metadata operation, derive exactly one
backing device, require one `/dev/` result on one line, and verify that it is
LUKS2:

```bash
ROOT_BACKING_DEVICE=$(cryptsetup status root | awk '/^[[:space:]]*device:/{print $2; exit}')
ROOT_BACKING_DEVICE_COUNT=$(cryptsetup status root | awk '/^[[:space:]]*device:/{print $2}' | grep -Ec '^/dev/')
[[ "$ROOT_BACKING_DEVICE_COUNT" -eq 1 ]]
[[ "$ROOT_BACKING_DEVICE" == /dev/* && "$ROOT_BACKING_DEVICE" != *$'\n'* ]]
cryptsetup isLuks "$ROOT_BACKING_DEVICE"
cryptsetup open --test-passphrase --key-file "$RECOVERY_KEY" "$ROOT_BACKING_DEVICE"
```

Enroll that backing LUKS2 device non-interactively with the just-created
recovery credential, explicit TPM device selection, an empty raw PCR set,
signed PCR 11, and explicitly disabled pcrlock:

```text
systemd-cryptenroll --unlock-key-file="$RECOVERY_KEY" --tpm2-device=auto --tpm2-pcrs= --tpm2-public-key="$INSTALLED_PCR_PUBLIC_KEY" --tpm2-public-key-pcrs=11 --tpm2-pcrlock= "$ROOT_BACKING_DEVICE"
```

The external recovery passphrase is mandatory alongside the TPM token. Before
success, verify it non-destructively against `"$ROOT_BACKING_DEVICE"` with the
`cryptsetup open --test-passphrase` operation above. Remove temporary recovery
files, MOK passwords, extracted public keys, and any copied private credential
before handoff; no private key may be written to the target, installer logs, or
provenance record.

## Recovery State Manifest

The harness writes a state manifest and passes its path to the external
recovery runner (`BOOTC_SECURE_RECOVERY_COMMAND`). It is **paths only** — the file names
credentials, it never contains them — and it is mode `0600`.

This schema was previously undocumented, and the two sides disagreed: the
harness wrote `ssh_key` while Dakota's runner required `ssh_private_key`, so
every manifest was rejected as "not path-only Task 9 state". Writing it down is
what stops that recurring.

| key | meaning |
|---|---|
| `schema` | integer `1` |
| `profile` | `cayo`, `snow`, or `snowfield` |
| `tracking_ref` | the same-repository tag being followed |
| `accepted_oci_ref` | the immutable `…@sha256:…` reference installed |
| `target_disk` | path to the installed disk image or block device |
| `ovmf_code` / `ovmf_vars` | paths to the firmware the install used |
| `tpm_state` / `tpm_socket` | paths to the swtpm state directory and control socket |
| `recovery_key` | **path** to the recovery credential, never its bytes |
| `mok_cert` / `pcr_public` | paths to the public MOK certificate and PCR public key |
| `ssh_key` | **path** to the harness SSH private key, never its bytes |

A runner must treat every value as a path it may read, and must not copy
credential bytes into logs, evidence, or retained state. `ovmf_vars`,
`tpm_state` and `tpm_socket` name the *same* firmware and TPM state the install
used; a runner that substitutes fresh state invalidates the enrollment it is
supposed to be exercising.

## Provenance And Repair

Fisherman records `/var/lib/snosi/bootc-secure-install.json` in the encrypted
root after successful installation. It records the resolved OCI digest and
repository, secure-capability label, contract schema and assembly compatibility,
composefs ID, UKI hash, MOK and PCR public-key fingerprints, ESP PARTUUID,
LUKS UUID and TPM-token identity, installer component versions **as detected on
the medium**, and completion time. Secrets and passphrases are never recorded.

Recording detected rather than declared versions is what makes the floor policy
above auditable: an install that proceeded on an above-floor, unvalidated
systemd says so in its own record.

The record is JSON with these required keys: `oci_ref`, `tracking_ref`, `repository`,
`secure_capability`, `contract_schema`, `assembly_compatibility`, `composefs_id`,
`uki_sha256`, `mok_fingerprint`, `pcr_fingerprint`, `esp_partuuid`, `luks_uuid`,
`tpm_token_id`, `installer_versions`, `validated_versions`, and `completed_at`.
`oci_ref` is the immutable accepted reference; `tracking_ref` is the
same-repository tag from the harness recipe; `secure_capability` is JSON boolean
`true`; `contract_schema` is JSON integer `1`; and `completed_at` is an RFC 3339
UTC timestamp. No key may contain a passphrase, private key, or temporary path.

Two version keys, answering two different questions:

- `installer_versions` — **what produced this system.** An object containing
  `fisherman`.
- `validated_versions` — **what the installer checked on the medium.** An object
  containing `bootc`, `cosign`, and `systemd`. This is the floor-policy audit
  trail described above: it is what makes "this install proceeded on an
  above-floor, unvalidated systemd" answerable after the fact.

This revision (2026-08-07) narrowed `installer_versions` from `fisherman`,
`bootc_installer`, `dakota_iso` to `fisherman` alone, and moved the dependency
versions into their own key. The original three could not be satisfied: the
medium carries no identifier for the bootc-installer Flatpak or the Dakota ISO
build, and the live environment deliberately sets `VERSION_ID=latest`. Fisherman
was writing the dependency versions under `installer_versions`, which conflated
the two questions and failed this check however the fields were spelled.

Identifying the medium is a real capability — it is what would answer "which
machines were installed by media carrying a fisherman older than v0.2.14" — but
it needs Dakota to stamp a build identifier and something to consume it. Nothing
reads this record back today. Design it when a consumer exists rather than
requiring a value no installer can supply.

`PROFILE=snowfield` exercises the generic secure-install chain only. It does
not replace the representative Surface hardware install, input, power, update,
rollback, and fallback gate.

Task 10 provides fixture, candidate, and nightly CI orchestration for this
contract. Live Task 9 execution remains BLOCKED pending authorized secure
artifacts and prepared external runners; workflow wiring is not live evidence.

ESP repair is a recovery operation, not a new install: after authenticating the
existing encrypted root with the recovery passphrase, reconstruct and verify
shim, MokManager, MOK-signed systemd-boot, Type #2 UKIs, and BLS metadata from
the authenticated deployment. It must not modify deployment state, `/etc`,
`/var`, LUKS metadata, or the recovery key. Dakota and bootc-installer expose
the prerequisite checks, recovery-passphrase acknowledgement, MOK enrollment
and restage flow, and ESP repair action; Fisherman performs the privileged work.
