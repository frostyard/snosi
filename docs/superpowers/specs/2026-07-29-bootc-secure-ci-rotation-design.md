# Bootc Secure CI And Rotation Design

## Scope

Task 10 turns the secure bootc implementation into a fail-closed build,
publication, and validation pipeline for `cayo`, `snow`, and `snowfield`. It
does not publish transition images, create historical production keys, or
claim that the externally blocked Task 9 live tests have passed.

The existing `build-images.yml` workflow remains the sole authority that
mutates the three production GHCR repositories. Pull-request builds remain
useful for insecure installation mechanics but cannot obtain production keys
or publish artifacts. The transactional publication sequence in this document
runs inside `build-images.yml`; neither validation workflow may push an image
or move a tag.

## Protected Signing Boundary

Bootc and native A/B builds reuse the same production MOK and RSA-2048 PCR
identities. The existing `native-build` GitHub environment remains the single
owner of these secrets:

- `NATIVE_SECURE_BOOT_KEY`
- `NATIVE_SECURE_BOOT_CERTIFICATE`
- `NATIVE_PCR_SIGNING_KEY`
- `NATIVE_PCR_SIGNING_CERTIFICATE`

Repository operators must re-harden `native-build` so only protected/default
branch deployments can access it. Environment protection is GitHub repository
state and cannot be enforced by workflow YAML; the operations documentation
must make this a release prerequisite.

After re-hardening, native A/B pull-request builds generate disposable
RSA-4096 MOK and RSA-2048 PCR credentials per run. These credentials provide
build coverage only. Their outputs are non-publishable and must never be
promoted or confused with production identities.

Secure bootc publication is permitted for:

- pushes to `main`;
- manual dispatches running the default `main` revision;
- existing repository dispatches, which execute against the default branch.

Every publishing path must enter `native-build`. Pull requests and other refs
must have no path to production credentials, GHCR mutation, or `latest`
promotion.

## Build Modes

Pull requests package local OCI mechanics fixtures without
`SNOSI_BOOTC_SECURE=1`. The resulting image must carry
`io.snosi.bootc.secureboot-capable=false` and is never uploaded.

Protected publication materializes the four production secrets as mode-0600
files under a runner-owned temporary directory immediately before packaging.
It maps them to:

- `SNOSI_BOOTC_MOK_KEY`
- `SNOSI_BOOTC_MOK_CERT`
- `SNOSI_BOOTC_PCR_KEY`
- `SNOSI_BOOTC_PCR_CERT`

and sets `SNOSI_BOOTC_SECURE=1`. An `if: always()` cleanup step removes the
credential directory after packaging and validation, including failure paths.
Private key contents must not be printed, uploaded, cached, or retained in
runner diagnostics.

The secure package must carry both authoritative labels:

- `io.snosi.bootc.secureboot-capable=true`
- `io.snosi.bootc.secureboot-assembly=bootc-1.16.3-storage-digest-v1`

## Transactional Publication

Publication advances a mutable tracking tag only after its immutable candidate
has passed every check:

1. Build a pristine profile rootfs.
2. Securely package it with the protected MOK and PCR credentials.
3. Run local UKI, composefs, signature, section, private-key-leakage, and OCI
   capability validation.
4. Delete the materialized credentials unconditionally.
5. Push only the version tag.
6. Resolve the version tag to its remote immutable digest.
7. Verify the remote secure-capability and assembly labels.
8. Cosign-sign the immutable digest with the existing OCI signing identity.
9. Verify that signature with the committed `cosign.pub` and exercise the
   repository-scoped containers policy against the immutable reference.
10. Move `latest` to the already validated digest.

No earlier step may mutate `latest`. A failure leaves the previous tracking
tag untouched and must fail the job. SBOM, provenance, and release processing
consume the validated immutable candidate; they do not weaken this ordering.

## Publication Guard

`check-bootc-publication-guard.sh` is a no-network static gate, analogous to
the native publication guard. It checks that:

- every production bootc profile includes `shared/bootc-secure/mkosi.conf`;
- native profiles do not include the bootc secure fragment;
- required public trust, policy, registry, karg, and schema files remain;
- pull-request paths are insecure and non-publishing;
- every production publication path is main/default-branch scoped and uses
  `native-build`;
- secure assembly variables and artifact validation are present;
- credential materialization is paired with unconditional cleanup;
- remote digest, label, Cosign, and policy checks precede `latest` promotion.

Textual inspection cannot prove live registry state. Runtime workflow checks
remain authoritative for pushed labels, signatures, and digest identity.
`validate.yml` runs this guard on every pull request alongside the existing
publication and static guards.

## Rotation Contract

A bootc-specific rotation harness defines a fixture-testable external-runner
protocol. It covers:

1. Boot and unlock with the old PCR identity only.
2. Upgrade to a dual-PCR transition UKI.
3. Enroll a TPM token authorized by the new PCR identity while retaining the
   old token solely as rollback safety through the supported rollback window.
   Unlock across the signing-key transition relies on the transition UKI's
   dual-signed PCR policy, never on trying independent tokens in sequence.
4. Boot a new-PCR-only UKI and verify retained rollback still boots and
   unlocks.
5. Enroll the new MOK while the old-MOK deployment remains bootable.
6. Upgrade to new-MOK-signed systemd-boot and UKI content and run second-stage
   reconciliation.
7. Prove old and new MOK overlap supports the retained rollback window.
8. Retire old rollback deployments before removing the old MOK.
9. Prove old-trust removal rejects old-only content while the supported new
   deployment, TPM recovery path, and external recovery passphrase remain
   usable.

MOK overlap means both certificates are enrolled temporarily; it does not
require one PE binary to carry two Authenticode signatures. PCR overlap uses
the existing dual-policy `.pcrsig` assembly contract.

Fixture mode validates command ordering, exact causal markers, state handoff,
and refusal behavior. Live mode requires explicit immutable old, transition,
and new image references; persistent OVMF and swtpm state; public trust
identities; external recovery material; and external installer/update/rotation
runners. Missing inputs print `BLOCKED:` and exit 2. Task 10 does not invent
production historical secrets or publish transition artifacts to satisfy the
test.

## Validation Tiers

### Pull Request

The no-secret tier in `test-bootc-secure.yml` runs:

- insecure local OCI mechanics packaging;
- bootc secure static and publication guards;
- artifact fixture and mutation tests;
- package cleanup and private-key leakage tests;
- containers-policy fixtures;
- bootloader reconciliation fixtures;
- installer contract fixtures;
- secure install, update, and rotation fixture harnesses.

No result in this tier is Secure Boot runtime evidence.

### Candidate

Each protected production profile runs secure assembly in `build-images.yml`,
local artifact validation, immutable version-tag publication, remote label and
Cosign policy validation, and only then tracking-tag promotion. A manually
invoked live-validation job in `test-bootc-secure.yml` may consume an explicit
secure Dakota ISO plus immutable image and runner inputs to execute the Task 9
live gates. That job never publishes or retags an image and must fail closed
when its inputs are incomplete.

### Nightly

`bootc-secure-nightly.yml` rotates across `cayo`, `snow`, and `snowfield` and
runs assembly/spike evidence plus live install, update, and rotation protocols.
Until external release fixtures exist, the live job reports `BLOCKED` and is
not represented as passing security evidence. Nightly failures do not alter
already-published images.

### Full Window

The full-window protocol covers N to N+1 to N+2, rollback and return, security
and persistence checks after every boot, PCR transition, MOK overlap, old-trust
removal, TPM replacement, and external recovery reenrollment.

### Hardware

Representative Snowfield Surface validation is a manual self-hosted tier with
an explicit runner label and retained evidence. QEMU remains useful for generic
Secure Boot, TPM, update, and rollback mechanics but cannot replace Surface
hardware validation.

### Legacy Mechanics

`test-install.yml` remains an explicitly insecure manual mechanics test. Its
workflow name and documentation must state that it does not validate firmware
Secure Boot, MOK enrollment, encrypted root, TPM unlock, or authenticated
updates.

## Documentation And Evidence

Task 10 updates `CLAUDE.md`, `README.md`, and relevant `yeti` CI/testing
documentation with the build modes, protected-environment prerequisite,
publication ordering, validation tiers, and blocked live gates. Task 11 owns
the detailed operator, recovery, key-ceremony, and incident runbooks.

The unsupported warning remains until all three profiles pass live install and
update gates and Snowfield passes representative hardware validation.
