# Testing framework

Decisions: [ADR-0001](../adr/0001-var-factory-state-outcome-maps.md),
[ADR-0002](../adr/0002-ship-no-enablement-symlinks-in-etc.md),
[ADR-0009](../adr/0009-snosi-env-var-classes.md), and
[ADR-0018](../adr/0018-remove-native-ab-and-nbc-lanes.md). The deleted
native QEMU harnesses and profiles belong in
[prototype history](../native-ab-prototype-history.md), not current test
instructions.

## Test registry and static gates

`test/registry.tsv` records whether each test runs in CI (`ci`), is invoked
by another test (`nested`), is a helper, or remains `unwired`.
`test/test-registry-test.sh` verifies tracked entries against the workflow
references. The registry guard itself is `unwired`, so run it locally when
changing test wiring. New tests should be registered alongside their
workflow or parent; `unwired` describes a known coverage gap, not a passing
test. The `validate.yml` shell-lint job discovers scripts by extension and
shebang. Runtime `/etc` deletion, `RequiredBy=`, publication, sysext and
profile dependency guards have fixture suites.

`test/no-nbc-test.sh` rejects `frostyard-nbc` in tracked mkosi configs and
base `nbc-update-download` units; installed-image tier 2 checks the package
and binary are absent. `test/check-no-nbc-package-test.sh` fixtures the
dpkg-status gate that blocks OCI publication when `frostyard-nbc` is installed.
`test/ghostty-terminfo-test.sh` checks that base compiles the shipped
`xterm-ghostty` terminfo (Debian ships only `ghostty`) into `/usr/share/terminfo`.
`test/firn-catalog-test.sh` checks the
bootc-only four-product catalog. `test/retirement-plan-test.py` pins
ADR-0018's documentation, Snowfield's untested/waived status, historical
status markers and the no-R2-deletion boundary; it never accesses R2.
`test/firn-installer-iso-test.sh --static` checks Firn's Forky sandbox
and that the ISO installs exactly one unpinned `frostyard-firn`;
the removed native install live mode is not a bootc proof.

`test/iso-publication-pipeline-test.sh` rehearses the retained Firn ISO
publisher in a local `isos/native/v1/` namespace with an ephemeral OpenPGP
key and `test/lib/range-http-server.py`. It verifies two independent HTTP
ranges, rejects ignored Range and tampered candidates, checks the served
signed index and tests second-promotion history. It does not write R2.
`test/bootc-secure-docs-test.sh` guards the normative secure operations
runbook; `test/bootc-secure-artifact-test.sh --fixtures` covers the
Issue 517 GPT-auto udev-rule check. `test/check-forky-systemd-test.sh`
exercises the Forky sentinel and its three recheck obligations.

## Bootc installation and update tests

`just test-install` runs `test/bootc-install-test.sh` against a selected
image in QEMU/KVM: load OCI, install to a virtual disk, boot it, connect via
SSH, and execute `test/tests/01-installation.sh` through
`05-firstboot-presets.sh`. The tiers check installation, service health,
sysexts, smoke behavior and first-boot preset parity against
`/usr/share/snosi/enablement-manifest.txt`. It requires privileged Podman,
loop/mount access, QEMU/KVM and OVMF; `test-install.yml` runs it manually
after verifying the selected image's Cosign signature. `just run-qemu`
uses `test/run-qemu.sh` for interactive bootc mechanics.

`test/bootc-update-test.sh` stages successive OCI references in a QEMU
guest and checks booted/staged/rollback deployment continuity. Its
`test/update-tests/persistence-write.sh` and `persistence-verify.sh`
fixtures cover `/var`, `/etc`, identity and workload markers across update
and optional rollback. A local containers-storage transfer mode mirrors
the shipped Podman-first updater. This is not a secure Firn install or
signed production lifecycle run. `test/lib/vm.sh` provides shared bootc
disk/VM helpers; `test/lib/secure-vm.sh` supports the secure feasibility
fixtures. Optional bcvk is only a local insecure-firmware mechanics aid,
not Secure Boot proof.

## Secure-bootc evidence boundary

`validate.yml`, `test-bootc-secure.yml` and
`bootc-secure-nightly.yml` run secretless static and fixture contracts.
`build-images.yml` PR jobs build locally without credentials; protected
publication validates the immutable OCI digest, secure artifact and
signature before promoting `latest`. The bootc-secure spike QEMU/OVMF/swtpm
path is feasibility evidence, not Firn installation evidence. The
`test/bootc-secure-install-test.sh --fixtures`,
`test/bootc-secure-update-test.sh --fixtures` and rotation fixtures validate
protocol shapes and failure handling, not installed update or rollback.

Fresh-install evidence for **Snow, Floe and Sundog** is pending: Firn's
enforced-Secure-Boot E2E and minideb lab installs will run after the Firn
release is pinned; no fresh-install evidence exists yet. The
bootc-only installer also lists **Snowfield untested** on representative
Surface hardware: its catalog gate was waived, not passed. The
[manual Snow lab handoff](../specs/bootc-secure-lab-handoff.md) describes
how a Firn-installed host and distinct signed N/N+1 images can prove a
stage, reboot and rollback; no fixture or fresh-install test substitutes
for that live lifecycle record. Use
[secure operations](../bootc-secure-operations.md) for support, recovery,
incident and evidence-retention rules.

## CI and redirect worker

The `validate.yml` Worker job executes Node checks and a dry-run deployment
for `workers/native-installer-redirect/`. Actual deployment is owned by
`deploy-native-installer-redirect.yml`; the Worker retains the ISO's
stable URL despite its name. `nightly-compliance.yml` reruns the ISO
publisher fixture, bootc publication guards, sysext signatures and runtime
`/etc` policy without credentials or live artifacts. See [CI/CD](ci-cd.md)
for the workflow boundaries and [build pipeline](build-pipeline.md) for
runtime update state.
