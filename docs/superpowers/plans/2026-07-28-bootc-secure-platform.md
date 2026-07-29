# Bootc Secure Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add firmware Secure Boot, authenticated OCI updates, encrypted bootc state, and signed-PCR-11 TPM unlock to fresh cayo, snow, and snowfield bootc installations.

**Architecture:** Published OCI images embed centrally built MOK-signed UKIs sealed to their composefs deployment digest. Fisherman installs Debian shim, MOK-signed systemd-boot, and a per-machine encrypted DPS root; bootc manages Type #2 UKIs across authenticated updates and rollback.

**Tech Stack:** mkosi, bootc 1.16.x composefs, systemd-boot/UKI, Debian shim/MOK, LUKS2, TPM2, Btrfs, Podman containers policy, Cosign, QEMU/OVMF, swtpm, Bash.

## Global Constraints

- Fresh installations only; in-place conversion is a separate project.
- Reuse the existing native A/B MOK certificate and RSA-2048 PCR identity.
- Private signing keys must never enter OCI images or installed systems.
- Production image names remain cayo, snow, and snowfield.
- Local insecure builds remain available but cannot be published as production.
- Secure installs require UEFI Secure Boot, TPM 2.0, and an external recovery passphrase.
- Raw kernel/initrd BLS fallback is forbidden on the secure path.
- Runtime code must not create or remove enablement state under `/etc`.
- Preserve the existing composefs containers-storage update workaround.
- Update CLAUDE.md, README.md, and relevant yeti documentation with every source change.

---

### Task 1: Sealed UKI Feasibility Gate

**Files:**
- Create: `test/bootc-secure-spike-test.sh`
- Reference: `shared/kernel/scripts/postinst/mkosi.postinst.chroot`
- Reference: `shared/native-ab-secure/tools/ukify`

**Interfaces:**
- Consumes: a built `output/cayo` rootfs and disposable MOK/PCR credentials.
- Produces: a repeatable test proving UKI section content and composefs digest binding.

- [x] Write fixture-level tests for key validation, kernel discovery, pre-existing UKI refusal, and expected output paths.
- [x] Run the fixture tests and require them to fail before the spike helper exists.
- [x] Build one cayo rootfs without a UKI under `/boot/EFI/Linux`.
- [x] Run `bootc container ukify --rootfs` with a disposable MOK key and RSA-2048 PCR key.
- [x] Copy the UKI under `/boot/EFI/Linux` only after digest calculation.
- [x] Recompute the composefs ID and compare it byte-for-byte with the UKI `.cmdline` value.
- [x] Compare `.linux` and `.initrd` with the rootfs kernel/initramfs and validate `.pcrpkey`/`.pcrsig`.
- [x] Run the same validation after `shared/outformat/image/buildah-package.sh`.
- [x] Document the exact pinned bootc behavior in `yeti/testing.md` and `CLAUDE.md`.

### Task 2: Encrypted DPS Root Feasibility Gate

**Files:**
- Extend: `test/bootc-secure-spike-test.sh`
- Extend: `test/lib/vm.sh`

**Interfaces:**
- Consumes: Task 1's signed UKI OCI fixture.
- Produces: an installed raw disk with ESP plus externally created DPS LUKS2/Btrfs root and Type #2 UKI entries.

- [x] Add a failing layout test for ESP size/type, DPS root type, LUKS2, and Btrfs.
- [x] Create the GPT, recovery key, LUKS mapper, and Btrfs root in the test.
- [x] Invoke bootc `to-filesystem` with composefs, systemd-boot, empty root mount specification, and no dynamic kernel arguments.
- [x] Assert bootc emits Type #2 UKI metadata and no raw kernel/initrd BLS fallback.
- [x] Assert the installed UKI's composefs ID matches the installed deployment.
- [x] Record an upstream or bootc-debian blocker and stop if pinned bootc cannot satisfy this gate.

### Task 3: Shim And TPM Feasibility Gate

**Files:**
- Extend: `test/bootc-secure-spike-test.sh`
- Create: `test/lib/secure-vm.sh`
- Refactor where safe: `test/native-ab-secure-boot-test.sh`

**Interfaces:**
- Consumes: Task 2's encrypted disk.
- Produces: enforced-Secure-Boot and TPM unlock evidence using persistent OVMF and swtpm state.

- [x] Extract shared OVMF/MOK/swtpm lifecycle helpers with unchanged native behavior.
- [x] Install Debian shim, MokManager, and MOK-signed systemd-boot on the test ESP.
- [x] Prove a fresh Microsoft-only varstore rejects the installed second stage.
- [x] Enroll the MOK in the same varstore and prove the UKI reaches multi-user.target.
- [x] Assert mokutil, bootctl, lockdown, signer identity, composefs identity, and clean units.
- [x] Enroll LUKS using signed PCR 11, no raw PCR set, and pcrlock disabled.
- [x] Prove unattended reboot unlock and independent recovery-passphrase unlock.
- [x] Document exact shim filenames and bootctl behavior.

### Task 4: Bootc Secure Composition

**Files:**
- Create: `shared/bootc-secure/mkosi.conf`
- Create: `shared/bootc-secure/package-manager/`
- Create: `shared/bootc-secure/tree/`
- Modify: `mkosi.profiles/{cayo,snow,snowfield}/mkosi.conf`

**Interfaces:**
- Consumes: feasibility results and existing native public trust material.
- Produces: coherent secure packages, immutable kargs, public keys, and a versioned rootfs contract.

- [x] Add static failing tests for profile inclusion, coherent systemd versions, required packages, and native-profile isolation.
- [x] Add a bootc-only secure fragment with the validated systemd family, shim, mokutil, cryptsetup, TPM, and signing tools.
- [x] Add `lockdown=integrity` through bootc immutable kargs.
- [x] Ship public MOK/PCR material and `/usr/lib/snosi/bootc-secure.json` schema 1.
- [x] Run duplicate-package, mkosi-summary, native static, and native contract regressions.
- [x] Update architecture documentation.

### Task 5: UKI Assembly And Artifact Validation

**Files:**
- Create: `shared/bootc-secure/assemble-uki.sh`
- Create: `test/bootc-secure-artifact-test.sh`
- Create: `test/bootc-secure-artifact-negative-test.sh`
- Modify: `shared/outformat/image/buildah-package.sh`

**Interfaces:**
- `assemble-uki.sh ROOTFS MOK_KEY MOK_CERT PCR_KEY PCR_CERT [PREVIOUS_PCR_CERT]`.
- Produces a signed UKI, signed systemd-boot, secure contract, and OCI labels.

- [x] Write negative tests for missing/multiple kernels, pre-existing UKIs, malformed keys, and private-key leakage.
- [x] Implement UKI construction before `/boot` injection and MOK signing afterward.
- [x] Implement single- and dual-PCR signature modes.
- [x] Validate Authenticode, PE sections, composefs binding, initrd contents, signer fingerprints, and no raw fallback.
- [x] Mutate every trusted section/signature and require rejection.
- [x] Emit explicit secure or insecure capability labels; never infer capability from key presence.

### Task 6: OCI Signature Policy

**Files:**
- Create: `shared/bootc-secure/tree/etc/containers/policy.json`
- Create: `test/bootc-container-policy-test.sh`
- Modify: `test/lib/vm.sh`
- Modify: `mkosi.images/base/mkosi.extra/usr/libexec/bootc-update-stage`

**Interfaces:**
- Consumes Cosign v2.6.1 signatures and committed `cosign.pub`.
- Produces repository-scoped Podman policy enforcement for install and update.

- [x] Prove current Cosign signatures are accepted by containers/image `sigstoreSigned` policy.
- [x] Require repository identity for the three Frostyard GHCR images.
- [x] Add valid, unsigned, wrong-key, and wrong-repository tests.
- [x] Remove `--skip-fetch-check` from secure tests and enforce container policy.
- [x] Preserve the containers-storage workaround and existing staging digest checks.
- [x] Record policy failures through existing update status files without staged state.

### Task 7: Bootloader Reconciliation

**Files:**
- Create: `shared/bootc-secure/tree/usr/libexec/snosi-bootc-bootloader-reconcile`
- Create: `shared/bootc-secure/tree/usr/lib/systemd/system/snosi-bootc-bootloader-reconcile.service`
- Create: `test/bootc-bootloader-reconcile-test.sh`

**Interfaces:**
- Consumes the booted image's MOK-signed systemd-boot and installed ESP.
- Produces an atomically verified shim second-stage update without touching shim or `/etc` enablement.

- [x] Write fixture tests for no-op, valid update, wrong signer, interrupted write, rollback compatibility, and shim preservation.
- [x] Add a static `/usr` wants link with no `[Install]` section.
- [x] Verify source and temporary destination before atomic replacement and sync.
- [x] Keep the prior second stage after every failure.
- [x] Run the runtime `/etc` guard.

### Task 8: Fisherman Installation Contract

**Status:** complete. The versioned contract/schema and the named external
Fisherman, bootc-installer, and Dakota implementation work are complete; live
Snosi evidence is tracked in Task 9.

**Files:**
- Create: `docs/bootc-secure-install-contract.md`
- Modify: `shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json`
- External: `frostyard/fisherman`, `frostyard/bootc-installer`, `frostyard/dakota-iso`.

**Interfaces:**
- Produces the exact schema, disk layout, bootc invocation, enrollment, provenance, cleanup, restage, and repair contract consumed by external installer repositories.

- [x] Define schema and minimum versions/capacities.
- [x] Implement immutable Cosign-verified pulls and secure-capability refusal in fisherman.
- [x] Implement per-machine LUKS2/Btrfs and Type #2 bootc installation.
- [x] Implement shim/systemd-boot/MokManager installation and verification.
- [x] Implement MOK restaging, signed-PCR enrollment, recovery verification, secret cleanup, and provenance.
- [x] Add installer UI for prerequisites, recovery-key acknowledgement, MOK flow, restage, and ESP repair.
- [x] Validate the resulting installer ISO's own Debian-trusted boot chain.

### Task 9: Secure Install And Update Harnesses

**Status:** install/update fixture contracts and fail-closed external-runner
interfaces are complete in Snosi. Live E2E remains BLOCKED pending authorized
signed secure N/N+1/N+2/transition OCI fixtures and prepared external runners;
the inspected 2026-07-27 `latest` images lacked
`io.snosi.bootc.secureboot-capable` and are not valid inputs.

**Files:**
- Create: `test/bootc-secure-install-test.sh`
- Create: `test/bootc-secure-update-test.sh`
- Reuse: `test/update-tests/`

**Interfaces:**
- Consumes signed N/N+1/N+2 OCI fixtures and installer media.
- Produces end-to-end evidence for all production profiles.

- [x] Complete fixture/protocol coverage for pre-enrollment rejection and post-enrollment install success.
- [x] Complete fixture/protocol coverage for Secure Boot, MOK, bootloader/UKI signers, lockdown, LUKS/Btrfs, TPM, recovery, composefs, bootc status, and units.
- [x] Complete fixture/protocol coverage for first switch, steady-state upgrade, rollback, and return.
- [x] Complete fixture/protocol coverage for repeated security and persistence assertions.
- [x] Complete fixture/protocol coverage for unsigned/wrong-key OCI, wrong-MOK UKI, digest mismatch, ESP-full, interrupted finalization, and reconciliation failure.
- [ ] Live TPM replacement and recovery enrollment evidence (BLOCKED).
- [ ] Live cayo, snow, and snowfield runs, including Snowfield Surface hardware validation (BLOCKED).

### Task 10: Rotation, CI, And Release

**Files:**
- Modify: `.github/workflows/build-images.yml`
- Modify: `.github/workflows/test-install.yml`
- Create: `.github/workflows/test-bootc-secure.yml`
- Create: `.github/workflows/bootc-secure-nightly.yml`
- Create: `check-bootc-publication-guard.sh`
- Modify: `.github/workflows/validate.yml`

**Interfaces:**
- Produces protected signed builds, publication refusal for insecure artifacts, candidate secure-boot gates, and nightly rotation coverage.

- [x] Keep PR builds unsigned/insecure and non-publishable.
- [x] Materialize signing keys only for protected assembly and delete them immediately afterward.
- [x] Validate signed artifacts before packaging and pushed artifacts before tagging latest.
- [x] Add fixture coverage for old-only, dual-PCR, new-only, MOK-overlap, rollback, and old-trust-removal.
- [x] Add PR, candidate, nightly, full-window, and hardware validation tier orchestration.
- [x] Keep insecure `just test-install` as explicitly non-security mechanics coverage.

**Live-evidence status:** Task 10 implementation, fixtures, and CI scaffolding
are complete. Live rotation, a real full-window run, and Snowfield hardware
evidence remain pending/BLOCKED; none is represented by a checked box above.

### Task 11: Documentation And Operations

**Status:** operations and documentation contracts are complete. Live release
evidence remains BLOCKED pending the Task 9/10 artifacts/runners and
representative Snowfield hardware evidence.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `yeti/{OVERVIEW,build-pipeline,testing,ci-cd}.md`
- Modify: `docs/nbc-to-bootc-migration.md`
- Create: `docs/bootc-secure-operations.md`

- [x] Document trust boundaries, build modes, installer flow, recovery, rotation, CI evidence, and existing-install limitations.
- [x] Add MOK restage, TPM replacement, ESP repair, and key-ceremony runbooks.
- [x] Keep the current unsupported warning until all profile and hardware gates pass.
- [x] Run all static, artifact, install, update, workflow, and documentation checks.
