# Bootc Secure Operations Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish an accurate, fail-closed operations runbook for secure bootc installation, recovery, trust rotation, CI evidence, and current support limitations, then enforce its critical claims with a static documentation contract.

**Architecture:** `docs/bootc-secure-operations.md` is the normative operator runbook and links to the lower-level installer and assembly compatibility contracts instead of duplicating them. Existing human and AI documentation links to that runbook and retains concise architecture/status summaries. A no-network shell test checks required sections, exact security boundaries, recovery commands, and unsupported-state language.

**Tech Stack:** Markdown, Bash, jq, mokutil, systemd-cryptenroll, cryptsetup, bootctl, sbverify, bootc, GitHub Actions documentation.

## Global Constraints

- The secure bootc path applies only to fresh `cayo`, `snow`, and `snowfield` installs; in-place conversion of existing bootc or nbc systems remains unsupported.
- Do not claim production bootc Secure Boot support until live install/update gates pass for all three profiles and representative Snowfield hardware validation passes.
- The supported chain is Microsoft UEFI db -> Debian shim -> MOK-signed systemd-boot -> MOK-signed UKI -> signed composefs digest -> authenticated OCI deployment.
- Protected bootc/native builds reuse the durable `NATIVE_*` production MOK and RSA-2048 PCR identities; only runner-local files are transient.
- Private MOK/PCR keys must never enter images, installed systems, recipes, provenance, logs, uploaded artifacts, or retained temporary state.
- Secure installs require UEFI Secure Boot, TPM 2.0, a minimum 30 GiB disk, and a mandatory external mode-0600 recovery passphrase.
- Recovery root mapper name is exactly `root`; secure installs use one 1 GiB ESP and one DPS x86-64 LUKS2/Btrfs root.
- Raw kernel/initrd BLS fallback and machine-specific root/LUKS kernel arguments are forbidden.
- PCR rotation uses a dual-signed transition UKI; never rely on fallback across independent TPM tokens.
- MOK overlap retains old and new trust until every supported old-signed rollback deployment is retired; remove old MOK only afterward.
- MOK restage, TPM replacement, and ESP repair authenticate existing state and must never repartition or reinstall.
- Loss of both TPM authorization and the external recovery passphrase is unrecoverable.
- Fixture/contract success is not live security evidence. Missing live artifacts/runners remain `BLOCKED` with exit status 2.
- The 2026-07-27 published `latest` images lack `io.snosi.bootc.secureboot-capable` and are unsuitable for secure installation evidence.
- Snowfield retains a representative Surface hardware gate.
- Do not create commits unless explicitly requested.

---

### Task 1: Normative Operations Runbook And Documentation Contract

**Files:**
- Create: `docs/bootc-secure-operations.md`
- Create: `test/bootc-secure-docs-test.sh`

**Interfaces:**
- Produces the normative operator entry point for support status, trust boundaries, fresh installation, recovery, rotations, CI evidence, and incident handling.
- `test/bootc-secure-docs-test.sh` is a no-network static contract invoked with no arguments.

- [ ] **Step 1: Write the failing documentation contract**

The test must require these exact headings:

```bash
required_headings=(
    '## Support Status'
    '## Trust Boundaries'
    '## Build Modes And Publication'
    '## Fresh Installation'
    '## Recovery Credential Custody'
    '## MOK Restage'
    '## TPM Replacement And Recovery Reenrollment'
    '## ESP Repair'
    '## PCR Signing-Key Rotation'
    '## MOK Rotation'
    '## CI Evidence Tiers'
    '## Existing Installations'
    '## Incident Response'
    '## Evidence Retention'
)
```

Require these exact security strings somewhere in the runbook:

```text
io.snosi.bootc.secureboot-capable=true
io.snosi.bootc.secureboot-assembly=bootc-1.16.3-storage-digest-v1
/dev/mapper/root
ROOT_BACKING_DEVICE=$(cryptsetup status root | awk '/^[[:space:]]*device:/{print $2; exit}')
ROOT_BACKING_DEVICE_COUNT=$(cryptsetup status root | awk '/^[[:space:]]*device:/{print $2}' | grep -Ec '^/dev/')
[[ "$ROOT_BACKING_DEVICE_COUNT" -eq 1 ]]
[[ "$ROOT_BACKING_DEVICE" == /dev/* && "$ROOT_BACKING_DEVICE" != *$'\n'* ]]
cryptsetup isLuks "$ROOT_BACKING_DEVICE"
systemd-cryptenroll --unlock-key-file="$RECOVERY_KEY" --tpm2-device=auto --tpm2-pcrs= --tpm2-public-key="$INSTALLED_PCR_PUBLIC_KEY" --tpm2-public-key-pcrs=11 --tpm2-pcrlock= "$ROOT_BACKING_DEVICE"
cryptsetup open --test-passphrase
BLOCKED:
```

Require links to:

```text
docs/bootc-secure-install-contract.md
docs/bootc-secure-assembly-compatibility.md
shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json
```

Require these five exact boundary sentences:

```text
Existing bootc and nbc installations cannot be converted in place to this secure layout.
Private MOK and PCR keys never enter OCI images or installed systems.
Dual-PCR transition policy is not fallback across independent TPM tokens.
Remove the old MOK only after every old-signed rollback deployment is retired.
Loss of both TPM authorization and the external recovery passphrase is unrecoverable.
```

Reject a runbook containing any of these unsupported claims:

```text
production bootc Secure Boot is supported
all three profiles have passed live validation
Snowfield hardware validation passed
bcvk validates Secure Boot
```

Run: `bash test/bootc-secure-docs-test.sh`

Expected: FAIL because the runbook does not exist.

- [ ] **Step 2: Write support status and trust/build sections**

Start the runbook with a warning block that says implementation and fixture contracts are complete but production support is withheld pending live profile and Snowfield hardware gates. Record the currently published-label blocker.

Document the chain and separate trust authorities:

- Microsoft/Debian authenticate shim;
- enrolled MOK authenticates systemd-boot and UKIs;
- signed PCR 11 policies authorize TPM unlock without raw-PCR pinning;
- the external recovery passphrase independently authenticates LUKS;
- committed Cosign key and repository-scoped policy authenticate OCI pulls;
- UKI `composefs=` binds booted code to deployment content.

Document PR mechanics, protected secure publication, immutable-version verification before `latest`, and the GitHub `native-build` protected/default-branch/no-required-reviewer prerequisite. State that GHCR packages must remain public for the current root Skopeo policy-copy gate unless root registry authentication is added.

- [ ] **Step 3: Write fresh-install and recovery runbooks**

Fresh install must require:

1. A freshly built Debian-trusted Dakota ISO.
2. An immutable `ghcr.io/frostyard/<profile>@sha256:...` accepted reference and separate same-repository tracking tag.
3. Public MOK/PCR identities matching the image.
4. A blank at-least-30-GiB target and external mode-0600 recovery file.
5. Installer refusal before writes when secure capability, signature, hardware, disk, or identity checks fail.
6. Pre-enrollment shim rejection, MokManager enrollment in the same firmware state, and post-enrollment unattended TPM boot.

For MOK restage, TPM replacement, and ESP repair, explicitly label the privileged operation as owned by the external Dakota/bootc-installer/Fisherman implementation. Do not invent a Snosi CLI. Give preconditions, immutable inputs, required external action, and post-action verification commands.

TPM replacement must derive exactly one LUKS2 `/dev/` backing device from
`cryptsetup status root`, verify recovery against it, and include the exact
`systemd-cryptenroll` command from the contract. `/dev/mapper/root` remains the
opened mapper for mounting/runtime, not a LUKS metadata target. ESP repair must
verify shim/MokManager/systemd-boot/UKI signatures and hashes and state that it
cannot alter deployment state, `/etc`, `/var`, LUKS metadata, or recovery
credentials.

- [ ] **Step 4: Write PCR and MOK rotation ceremonies**

PCR ceremony must require offline generation of RSA-2048/default-exponent material, public identity review, old-only baseline evidence, dual-PCR transition build, new token enrollment from the transition UKI, new-PCR-only build, rollback proof, then old token retirement. State that current CI does not materialize historical production keys or publish transition artifacts automatically, so live ceremony remains blocked until authorized inputs exist.

MOK ceremony must require offline RSA-4096 identity generation, new certificate enrollment while old trust remains, new-MOK systemd-boot/UKI publication, reconciler proof, full rollback-window retirement, old certificate deletion, and old-only rejection. A PE binary does not need dual Authenticode signatures; overlap lives in enrolled firmware trust.

For both ceremonies, require fingerprints, immutable refs/digests, image versions, CI run URLs, console/runtime evidence, token IDs, and timestamps in the retained evidence record, but prohibit private keys, recovery bytes, MOK passwords, TPM state, and writable firmware vars.

- [ ] **Step 5: Write CI, incident, and limitation sections**

Describe PR, candidate, nightly, full-window, hardware, and legacy mechanics tiers. State exactly what each proves and does not prove. Include response tables for:

- unsigned/wrong-key/wrong-repository OCI;
- false/missing capability label;
- wrong-MOK or composefs-mismatched UKI;
- ESP full/interrupted finalization/reconciliation failure;
- TPM replacement;
- lost recovery credential;
- suspected MOK/PCR private-key compromise.

For compromise, require stopping publication/tag movement, preserving immutable digests/logs without secrets, rotating through an authorized overlap window, and withdrawing unsupported candidates. Do not suggest deleting current trust before a verified replacement and rollback retirement.

- [ ] **Step 6: Run the documentation contract**

Run:

```bash
chmod +x test/bootc-secure-docs-test.sh
./test/bootc-secure-docs-test.sh
shellcheck -S warning -x test/bootc-secure-docs-test.sh
git diff --check
```

Expected: documentation contract passes, ShellCheck is clean, and no whitespace errors exist.

### Task 2: Cross-Document Integration And Final Evidence Audit

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `yeti/OVERVIEW.md`
- Modify: `yeti/build-pipeline.md`
- Modify: `yeti/testing.md`
- Modify: `yeti/ci-cd.md`
- Modify: `docs/nbc-to-bootc-migration.md`
- Modify: `docs/bootc-secure-install-contract.md`
- Modify: `docs/superpowers/plans/2026-07-28-bootc-secure-platform.md`
- Modify: `.github/workflows/validate.yml`

**Interfaces:**
- Every overview links to `docs/bootc-secure-operations.md`; detailed mechanics remain in their authoritative contracts.
- `validate.yml` runs `test/bootc-secure-docs-test.sh` in `bootc-secure-contracts`.

- [ ] **Step 1: Wire the docs contract into validation**

Add after the installer contract step:

```yaml
- name: Validate bootc secure operations documentation
  run: ./test/bootc-secure-docs-test.sh
```

Update `test-bootc-secure.yml`'s contract job with the same command so its command set remains aligned with `validate.yml`.

- [ ] **Step 2: Add concise runbook links without duplicating authority**

In `README.md`, add a user-facing secure-bootc operations link beside the unsupported status warning. In `CLAUDE.md`, add the runbook as the normative recovery/rotation/incident reference. In each `yeti` file, link from its relevant build/testing/CI section and summarize only that file's layer.

Update `docs/bootc-secure-install-contract.md` line that says Task 9 has no CI workflow wiring: Task 10 now provides fixture/candidate/nightly orchestration, while live execution remains blocked on prepared artifacts/runners.

- [ ] **Step 3: Clarify migration and existing-install limitations**

In `docs/nbc-to-bootc-migration.md`, distinguish ordinary insecure-firmware bootc migration from the new secure fresh-install path. State that neither an nbc install nor an existing bootc install can be converted in place to the secure DPS LUKS/MOK/TPM layout; backup and fresh installation are required once the path becomes supported. Do not imply support before gates pass.

- [ ] **Step 4: Mark Task 11 accurately**

Mark all four Task 11 checklist items complete only after the runbook, cross-links, and full verification pass; Step 5 closes the fourth all-checks item. Keep the unsupported warning and all Task 9/10 live blockers. Add a status note that operations/documentation contracts are complete but live release evidence is not.

- [ ] **Step 5: Run complete static, fixture, workflow, and docs verification**

Run:

```bash
./test/bootc-secure-docs-test.sh
./test/bootc-secure-install-contract-test.sh
./test/bootc-secure-artifact-test.sh --fixtures
./test/bootc-secure-artifact-negative-test.sh --fixtures
./test/bootc-secure-package-cleanup-test.sh
./test/bootc-container-policy-test.sh
./test/bootc-bootloader-reconcile-test.sh
./test/bootc-secure-install-test.sh --fixtures
./test/bootc-secure-update-test.sh --fixtures
./test/bootc-secure-rotation-test.sh --fixtures
./test/bootc-secure-publication-test.sh
./test/bootc-publication-guard-test.sh
./test/bootc-secure-ci-test.sh
./check-bootc-publication-guard.sh
./check-native-publication-guard.sh
./check-runtime-etc-guard.sh
shellcheck -S warning -x test/bootc-secure-docs-test.sh
actionlint \
  .github/workflows/build-images.yml \
  .github/workflows/build-native-images.yml \
  .github/workflows/test-install.yml \
  .github/workflows/test-bootc-secure.yml \
  .github/workflows/bootc-secure-nightly.yml \
  .github/workflows/validate.yml
sudo .mkosi/bin/mkosi -f summary >/dev/null
for profile in cayo snow snowfield; do
  sudo .mkosi/bin/mkosi -f --profile "$profile" summary >/dev/null
done
git diff --check
```

Expected: every static/fixture/docs test passes, ShellCheck/actionlint are clean, all four pinned mkosi summaries resolve, and the diff has no whitespace errors.

- [ ] **Step 6: Reconfirm blocked live evidence**

Run each unconfigured live harness and require exit 2 plus `BLOCKED:` with no PASS claim:

```bash
for test_script in \
  ./test/bootc-secure-install-test.sh \
  ./test/bootc-secure-update-test.sh \
  ./test/bootc-secure-rotation-test.sh; do
  set +e
  output=$($test_script 2>&1)
  status=$?
  set -e
  test "$status" -eq 2
  grep -q '^BLOCKED:' <<<"$output"
  ! grep -Eq '^(ok -|# Results:)' <<<"$output"
done
```

Expected: all three harnesses remain visibly blocked pending external evidence.
