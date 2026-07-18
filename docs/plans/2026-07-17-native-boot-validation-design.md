# Native A/B Boot Validation in CI — Design

Date: 2026-07-17
Status: Implemented (see docs/plans/2026-07-17-native-boot-validation-plan.md)

## Problem

`build-native-images.yml` builds, byte-verifies, signs, and promotes the three
native A/B products (`cayo-ab`, `snow-ab`, `snowfield-ab`) and the installer
ISO without ever booting anything. Validation stops at static artifact
inspection (`test/native-ab-secure-artifact-test.sh`,
`test/snowfield-artifact-test.sh`) plus byte-level re-verification of the
published objects (`verify-remote.sh`). An image that builds cleanly but fails
to boot — initrd regression, unit failure, broken first-boot semantics — would
be signed and promoted to the live R2 index with no CI signal at all.

The deep QEMU harnesses that DO prove boot behavior
(`test/native-ab-secure-boot-test.sh`, `test/native-installer-e2e-test.sh`,
`test/native-ab-components-test.sh`, …) are local-only exit-criterion tools:
they need root, KVM, swtpm, `virt-firmware`, and multi-hour multi-build runs.
Nothing runs them automatically.

Meanwhile `test-install.yml` already proves GitHub-hosted runners can do
KVM-accelerated QEMU boots (the `/dev/kvm` udev rule + `qemu-system-x86` +
`ovmf` recipe), so "GHA cannot boot VMs" is not a real constraint. The real
constraints are wall time, runner disk, and secure-boot tooling fidelity.

## Decision summary

Tiered validation:

| Tier | What | When | Where | Gates? |
|------|------|------|-------|--------|
| 1 | Boot smoke test: published disk image reaches `multi-user.target` | Every run (push, PR, dispatch) | `test-public-origin` matrix legs (GHA hosted) | Yes — blocks the verified marker, therefore promotion |
| 1b | ISO serial smoke: published ISO boots to a login prompt | Every run | `test-public-origin-iso` (GHA hosted) | Yes — same marker mechanism |
| 2 | Deep secure chain: install → enforced SB → TPM enroll → boot → signed update hop | Nightly + manual dispatch | New `native-nightly.yml` (GHA hosted) | No — signal only |
| 3 | `--full-window` / installer e2e in automation | Deferred | Self-hosted Incus runner on selfie | Deferred |

## Tier 1 — Boot smoke gate

### New script: `test/native-boot-smoke-test.sh`

Root + KVM required. Follows existing harness conventions (`set -euo pipefail`,
sources `test/lib/vm.sh` and `test/lib/ssh.sh`, cleanup trap, numbered
assertions with a final tally).

Usage: `sudo test/native-boot-smoke-test.sh <prepared-dir> [base-url]`

where `<prepared-dir>` is the directory `verify-remote.sh` just verified
(contains `publication-info.json`, `SHA256SUMS`, and the downloaded candidate
objects); product and version are derived from `publication-info.json`, not
passed on the command line. `base-url` is only required when the disk blob
itself is not present locally (e.g. CI ships only the verified metadata
between jobs), in which case it is downloaded from the candidate subpath.

Steps:

1. **Locate the disk artifact** from `publication-info.json` /`SHA256SUMS`
   (never a hardcoded filename — the frozen §4 names are derived, not
   restated). Decompress the `.xz` to a scratch raw disk (honoring the
   `/var/tmp` convention of the publish scripts).
2. **Inject SSH access into the var partition only**: loop-mount the var
   partition (located by `PARTLABEL=var`), write a throwaway ed25519 public
   key to `lib/snosi/etc-overlay/upper/ssh/authorized_keys.d/root` — the
   exact path `snosi-install`'s `seed_var()` seeds, read through the sshd
   `AuthorizedKeysFile` drop-in (`10-snosi-authorized-keys.conf`). On native
   images `/root` lives on the sealed read-only root, so the
   `roothome/.ssh` pattern from `native-ab-components-test.sh` does NOT
   apply here. Root and verity partitions stay byte-pristine — the OS
   content booted is exactly what was published; only user-data state is
   seeded.
3. **Boot** via `vm_start` (plain OVMF CODE/VARS, KVM, serial console to a log
   file, user-net SSH port-forward). Secure Boot is deliberately NOT enforced:
   the MOK certificate is not enrolled in a virgin varstore, so SB enforcement
   is structurally impossible without the Tier-2 `virt-fw-vars` machinery.
   dm-verity root activation, the etc-overlay initrd, true first boot
   (`machine-id=uninitialized` → presets), and full unit startup are all still
   exercised.
4. **Assert over SSH** (via `wait_for_ssh` / `vm_ssh`):
   - `systemctl is-active multi-user.target` is `active`;
   - `systemctl --failed --no-legend` output is empty;
   - `/etc/os-release` `IMAGE_ID` equals the product and `IMAGE_VERSION`
     equals the expected version;
   - the native marker `/usr/lib/snosi/native-ab` exists (booted the right
     artifact class);
   - clean `systemctl poweroff` and QEMU exit within a timeout.
5. **On any failure**: leave the serial console log in a caller-known location
   for artifact upload; exit non-zero.

Notes:

- No auto-retry. A boot smoke on released bytes should be deterministic; if
  flakiness appears in practice, address the cause before adding retries.
- Desktop products boot to `graphical.target` as their default; the assertion
  is on `multi-user.target` being active (it is a dependency of
  `graphical.target`), so one assertion works for all three products. GDM
  health on cayo is not asserted (no GDM); a failed `gdm.service` on desktop
  products would surface via the no-failed-units assertion anyway.

### Wiring: `test-public-origin` (per matrix leg)

New steps, all conditional on the existing `steps.download.outcome ==
'success'` pattern:

1. **Enable KVM + install QEMU/OVMF** (the `test-install.yml:38` recipe:
   `99-kvm4all.rules` udev rule, `qemu-system-x86 qemu-utils ovmf`).
2. **Boot smoke test** — after "Verify candidate objects against the public
   origin", before "Record verified marker":
   `sudo ./test/native-boot-smoke-test.sh /var/tmp/native-publish/<product>/x86-64 <base-url>`
   (product and version are derived from the directory's own
   `publication-info.json`, not passed as separate arguments; `<base-url>` is
   the product's public `os/native/v1/<product>/x86-64` origin, used to
   re-fetch the disk blob when it isn't already present locally).
3. **Upload console log on failure** (`if: failure()`, `actions/upload-artifact`,
   e.g. `native-smoke-console-<product>`).

The "Record verified marker" step's condition changes from
`steps.verify.outcome == 'success'` to also require the smoke step's success
(or equivalently the smoke step sits between them and the job fails through).
Since `promote-*` jobs already key on the `native-verified-<product>` marker
artifact, an unbootable image can no longer be signed or published — no change
to the promote jobs at all.

Because `test-public-origin` runs on PRs (which build and publish candidates
but never promote), every PR to main gets boot coverage for free.

One caveat to verify at implementation time: whether `verify-remote.sh`
deletes its downloaded objects after verification. If it does, the smoke
script re-downloads just the disk object (hash-checked against the already
verified `SHA256SUMS`) rather than changing `verify-remote.sh`'s cleanup
behavior.

### Wiring: `test-public-origin-iso` (serial-only variant)

The ISO cannot get the SSH treatment without repacking its initramfs (the
whole userspace is the packed cpio), which would defeat "boot the published
bytes". Instead:

- Boot the downloaded ISO in QEMU (plain OVMF, `-cdrom`, serial console to a
  log, no disk).
- Watch the serial log for the installer environment's login prompt (the
  `hostname login:` line on ttyS0) within a timeout. This proves
  kernel + packed-initramfs + systemd userspace come up — the "ISO doesn't
  boot" failure class.
- Same marker-gating and console-log-upload pattern as the product legs.

This can live in the same script behind an `--iso` mode or as a small
separate `test/native-iso-boot-smoke-test.sh`; decide at implementation time
(bias: separate script, the flows share almost nothing).

### Cost

Per product leg: ~1 min KVM/QEMU setup + xz decompress of a 5–8 GiB image +
a 2–4 min boot/assert/poweroff cycle. Well under the job's current slack;
`/var/tmp` is already bind-mounted to `/mnt` in these jobs so runner-disk
pressure is handled.

## Tier 2 — Nightly deep harness

### New workflow: `.github/workflows/native-nightly.yml`

- **Triggers**: `schedule` (one nightly cron) + `workflow_dispatch` (with a
  profile input). `permissions: {}` at top; jobs get `contents: read`.
- **Concurrency**: single group, no cancel-in-progress (a run mid-flight
  finishes).
- **Runner**: ubuntu-latest, `timeout-minutes: 350`.
- **Host prep**: the build jobs' recipe (free-disk-space action, TMPDIR +
  /var/tmp redirect to /mnt, apparmor teardown, debian-archive-keyring,
  dracut-core, binutils, file, python3-cryptography, mkosi bootstrap + pin
  check) PLUS the KVM udev rule, `qemu-system-x86 qemu-utils ovmf swtpm
  swtpm-tools`, and `pip install virt-firmware`.
- **Keys — ephemeral only, no production secrets**: the harness builds its own
  images, so the workflow generates throwaway key material in the job:
  `mkosi genkey` (or openssl) for Secure Boot/MOK, an RSA-2048 (e=65537) PCR
  signing key — the only algorithm the unlock chain accepts, per
  docs/native-ab-contracts.md §7 — and lets the harness create its own
  ephemeral update-signing keyring as it already does locally. The workflow
  references NO GitHub environment and NO repository secrets. This is a
  deliberate security property: a scheduled workflow with zero secret access.
- **What it runs**: `sudo PROFILE=<profile> test/native-ab-secure-boot-test.sh`
  (default mode — install via the spike path, first boot under enforced SB,
  TPM enrollment + unattended auto-unlock, desktop assertions where
  applicable, one signed N→N+1 update hop, rollback-entry retention).
- **Profile rotation**: derive the profile from the day of week in a small
  step (e.g. Mon/Wed/Fri `snow-ab`, Tue/Thu/Sat `cayo-ab`, Sun
  `snowfield-ab`), overridable by the dispatch input. One profile per night
  keeps the run inside the timeout.
- **Failure handling**: the job failing is the signal (GitHub notifies on
  scheduled-workflow failures). Upload the harness's console/log directory as
  an artifact on failure. Optionally (nice-to-have, not required) a final
  step files/updates a pinned issue on failure.
- **Non-blocking**: nothing in the release pipeline depends on this workflow.
  Promotion gating stays with Tier 1 only.

## Tier 3 — Self-hosted Incus runner on selfie (deferred)

Not built now. Recorded requirements so it is a clean upgrade later:

- Runner registered from inside an **ephemeral Incus VM** on selfie
  (10.0.1.200) — fresh VM per job (ephemeral/one-shot runner registration),
  so no state survives a job.
- Runner labels (e.g. `self-hosted, incus, kvm`) referenced ONLY by
  schedule/dispatch workflows pinned to main. **Never** by `pull_request`-
  triggered workflows: a self-hosted runner reachable from PR-controlled code
  is arbitrary code execution on the LAN. Repo settings must also disable
  self-hosted runners for public fork PRs.
- First tenants once it exists: `test/native-ab-secure-boot-test.sh
  --full-window` (the Phase 5 exit-criterion mode, too long for hosted
  runners) and `test/native-installer-e2e-test.sh` (Phase 8 exit, ~17 min
  after builds). The nightly can migrate there or stay on GHA as fallback.
- Needs KVM passthrough into the Incus VM (nested virt), swtpm, and the same
  tool set as Tier 2.

## What does not change

- Build jobs, promote jobs, and every `shared/native-ab/publish/*.sh` script
  are untouched.
- The only behavioral change to the existing pipeline: the
  `native-verified-<product>` / `native-verified-iso` markers become harder to
  earn (byte-verify AND boot).
- The workflow remains a thin caller: all new logic lives in
  `test/native-boot-smoke-test.sh` (and the ISO variant), independently
  runnable on a dev machine against a local candidate directory.

## Testing the tests

- Both smoke scripts must run locally against a locally-prepared candidate
  directory (`prepare-native-publication.sh --xz` output + a local
  `range-http-server.py` origin or just the directory itself) before the
  workflow change lands — same "prove the harness locally first" discipline as
  every existing test.
- A deliberate negative check during development: corrupt a scratch copy's
  root partition (or point at an image known not to boot) and confirm the
  smoke script fails with a preserved console log — the gate must be proven
  capable of failing.
- `validate.yml`'s shellcheck sweep covers the new scripts automatically.

## Risks / accepted limitations

- **Tier 1 boots without Secure Boot enforcement.** Accepted: SB/TPM/MOK
  fidelity is Tier 2's job; enforcing SB in Tier 1 would require varstore
  pre-enrollment machinery (virt-fw-vars) for marginal gain on every run.
- **Tier 1 modifies the var partition before boot.** Accepted: var is
  user-data territory, the installer creates it fresh anyway
  ("Native /var Factory State"), and root/verity bytes stay pristine.
- **ISO smoke is serial-prompt-only.** Accepted: it targets the
  "doesn't boot at all" class; deeper installer validation belongs to the e2e
  harness (Tier 3 tenant).
- **Nightly wall time** (~3–4h with builds) is close to hosted-runner comfort
  limits; if it becomes flaky-slow, that is the trigger to build Tier 3
  rather than to trim the harness.
