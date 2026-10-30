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
references and runs in `validate.yml`, so a dropped wiring step fails CI.
New tests should be registered alongside their workflow or parent; `unwired`
describes a known coverage gap, not a passing test. Three tests remain
`unwired`: `bootc-migration-test.sh` and `bootc-update-test.sh`, which need
image references, and `dps-luks-cleanup-test.sh`, which needs root. The
`validate.yml` shell-lint job discovers scripts by extension and shebang.
Runtime `/etc` deletion, `RequiredBy=`, `Upholds=`, publication, sysext and profile
dependency guards have fixture suites.

`test/no-nbc-test.sh` rejects `frostyard-nbc` in tracked mkosi configs and
base `nbc-update-download` units; installed-image tier 2 checks the package
and binary are absent. `test/check-no-nbc-package-test.sh` fixtures the
dpkg-status gate that blocks OCI publication when `frostyard-nbc` is installed.
`test/updex-timer-guard-test.sh` fixtures the `updex-timer.finalize` build
guard (updex's update timer must ship and be in the enablement manifest), its
composition wiring and the base preset line.
`test/ghostty-terminfo-test.sh` checks that base compiles the shipped
`xterm-ghostty` terminfo (Debian ships only `ghostty`) into `/usr/share/terminfo`.
`test/firn-catalog-test.sh` checks the
bootc-only four-product catalog. `test/core-flatpaks-test.sh` pins the
`flatpaks/` core Flatpak sets and their `org.frostyard.core-flatpaks` label:
file shapes, the product mapping, label encoding, the image check, the
generated legacy list, that every packaging lane passes and checks the
label, and the on-disk copy each product composition installs and checks.
`test/retirement-plan-test.py` pins ADR-0018's documentation, Snowfield's
untested/waived status, historical status markers and the no-R2-deletion
boundary; it never accesses R2.
`test/firn-installer-iso-test.sh --static` checks Firn's Forky sandbox,
that the ISO installs exactly one unpinned `frostyard-firn` and
`frostyard-firn-gui`, that it carries the package behind every filesystem
Firn offers (ext4, btrfs, xfs and the FAT ESP; the postinst also checks each
`mkfs` binary), that it removes the build's SSH host keys and generates them
at boot, and the boot-entry contract of
[ADR-0022](../adr/0022-installer-graphical-and-console-boot-entries.md):
two GRUB entries that differ only in `systemd.unit=`, console as the timed
default, each tty1 frontend wanted only by its target, and a
condition-free `firn-gui.service` whose every exit hands tty1 to the TUI.
The removed native install live mode is not a bootc proof.
`test/firn-gui-scope-test.sh` keeps `frostyard-firn-gui`, Firn's
disk-erasing graphical installer, on the ISO: outside `shared/firn-installer/`
and `mkosi.profiles/firn-installer`, no mkosi package setting (first or
continuation line, any tracked `*.conf` or `Include=` target) or build script
may name it, and no other config may include the installer fragments.
`test/gdm-autologin-scope-test.sh` keeps GDM from logging in a user that no
shipped image creates: outside `docs/`, `.memory/`, `saved-unused/` and
`test/`, no tracked file or build script may name a GDM automatic or timed
login key (`AutomaticLogin`, `TimedLogin`) on a line that is not a comment,
with or without an `=`. The retired live-ISO
`shared/snow/tree/etc/gdm3/daemon.conf` set `AutomaticLogin=snow`; the Firn
installer creates the only user an installed system has.
`test/grd-no-tpm-access-test.sh` keeps the gnome-remote-desktop daemons off the
TPM: in any tracked `gnome-remote-desktop*.service.d/` drop-in or
`gnome-remote-desktop*.service` unit, and in any tracked `sysusers.d/*.conf`,
no non-comment line may name `SupplementaryGroups` with a word that decodes
to `tss` (its value is parsed with shlex, so quotes do not hide it, and a
line that ends with a `\` is joined to the lines after it as systemd joins
them), or be `m gnome-remote-desktop tss` in any quoting. PR #1141 added that
access, and 48.1 seals the RDP credentials with `Esys_ContextSave` and
restores them with `Esys_ContextLoad`, which a reboot's TPM Reset invalidates
([#1131](https://github.com/frostyard/snosi/issues/1131));
PR #1191 removed it, and the daemons use the GKeyFile backend without a TPM.
`test/frostyard-apt-image-component-test.sh` keeps the Frostyard `image` APT
component (core ADR-0059) in the build sandbox only: `frostyard.sources` must
list exactly `main image`, and no other tracked APT source may name
`repository.frostyard.org`; its `--live IMAGE_REF` mode (root, podman, network;
run by `mechanics-build`) runs `apt-get update --error-on=any` with that source
and rejects any `W:` or `E:` line.

`build-installer-iso.yml` boots each candidate ISO before promotion.
`test/native-iso-boot-smoke-test.sh` boots the default entry with no display
and waits for firn on the serial console.
`test/firn-installer-ui-boot-test.sh` then boots the same bytes four
times. It selects GRUB entries by hotkey through the QEMU monitor and reaches
the guest over SSH with an SMBIOS `ssh.authorized_keys.root` credential, so
the ISO is not modified. The legs are the console entry, the graphical entry
on virtio-vga followed by a Quit that must hand tty1 to the TUI, the graphical
entry from the USB-stick (ESP) layout on std VGA, and the graphical entry
with no display, which must fall back to the TUI at once. It saves
screenshots and prints guest memory use. Both tests boot with 6 GiB, because
the all-in-RAM rootfs is a tmpfs capped at half of RAM and the ISO needs about
4.5 GiB to unpack.

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

## Sundog desktop package validation

The [desktop-completeness plan](../plans/2026-10-05-sundog-desktop-completeness-plan.md)
records the package payload and its VM acceptance results. Run
`test/sundog-profile-test.sh` and `check-duplicate-packages.sh`, build with
`just sundog`, and inspect the artifact's executable helpers, KCMs, preview
plugins, dictionaries, and English handbooks. Package selection alone cannot
prove a visible action works: the original static profile test passed while
KRunner's Configure action could not find `kcmshell6`.

Build in an isolated VM/checkout when retaining local baseline artifacts:
`mkosi.clean` removes `output/*`. Use disposable copies of the prepared Incus
baselines for desktop checks. The local baseline setup is retained in
`output/incus-baselines/`; package-check scripts and non-secret results are in
`output/sundog-desktop-validation/`, both ignored by git. The plan carries a
self-contained results summary. Accessibility and input tooling installed in
a guest's temporary `/usr` overlay are test instrumentation, not image payload.

Check real Plasma actions and rendered content in fresh and updated VM user
sessions, including GTK3 Preview, XWayland font/icon propagation, live sensors,
unindexed-file metadata, thumbnail rendering, wallet entries, and local Help
with guest networking disabled. Hardware-dependent Thunderbolt authorization
is deferred to manual laptop validation. This package-only change does not
require additional deployment, rollback, or signing validation.

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

Fresh-install evidence exists for **Snow, Floe and Sundog** as VM evidence only.
Argo workflow `bootc-only-iso-install-54wr4` (frostyard/lab
`argo/bootc-only-iso-install-test.yaml`, minideb 10.0.1.175, 2026-10-24)
installed `snosi-installer_20261023195508_x86-64.iso` (Firn 0.8.0, commit
f3c4b5dd; checksum authenticated by the signed `SHA256SUMS.gpg` index).
Every cell was bootc, unencrypted, Secure Boot on, on a blank Incus VM disk:

- `PASS: bootc/snow/none/sb=true image=ghcr.io/frostyard/snow:latest
  digest=sha256:6dc2232f62193dc7801e38e8730717e4e84f647592568e407cb9513422f1e379`
  (image version 20261023200056).
- `PASS: bootc/floe/none/sb=true image=ghcr.io/frostyard/floe:latest
  digest=sha256:b23cc05c2cf88729c534e09c0c68fd6417a45511b9514c1b03d533b2931138b0`
  (image version 20261023195819).

A PASS proves the Firn ISO install to a blank virtual disk, the Secure Boot
MOK chain through installed boot, first boot to a ready login prompt, a
btrfs-backed root (composefs overlay on btrfs `/sysroot`), and an installed
bootc image ref and digest matching the pin. It is not hardware
qualification and does not prove encrypted (LUKS/TPM) unlock, graphical
login, updates, rollback or the signed N/N+1 lifecycle. Firn's own
enforced-Secure-Boot E2E has still produced no evidence.

**Sundog** passed in a later run, Argo workflow
`bootc-only-iso-install-fjrk8` (same lab file, Sundog cell only, minideb
10.0.1.175, 2026-10-25):

- ISO `snosi-installer_20261024172447_x86-64.iso`, SHA-256
  `7618eb104914ad99a80164eb3b4094eaf50ea7c55522ce66db4bec5f71ac6a65`
  (checksum authenticated by the signed `SHA256SUMS.gpg` index, signer
  fingerprint F37282A35CB6BDFEBFC8FE775A2EAC5C8216FD68); Firn 0.8.0, commit
  f3c4b5dd.
- `PASS: bootc/sundog/none/sb=true image=ghcr.io/frostyard/sundog:latest
  digest=sha256:f8937384af78aa7ded64528a9993364dbcc1dd86308e96b4bc2cc5f15ba6f7be`
  (image version 20261024185607).

The earlier Sundog `boot:no_report` (runs `bootc-only-iso-install-54wr4` and
`-xh2jv`) was a lab-harness race, not a Sundog defect: the serial getty's
vhangup cut the QA check's serial output. It is fixed by
[frostyard/lab#143](https://github.com/frostyard/lab/pull/143) (merge
`c7b84004`); root cause in
[frostyard/snosi#1123](https://github.com/frostyard/snosi/issues/1123).
The bootc-only installer also lists **Snowfield untested** on representative
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
