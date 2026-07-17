# Testing Framework

## Overview

The `test/` directory contains bootc lifecycle tests and the experimental native
A/B validation harnesses. The install path validates OCI load → bootc install →
QEMU boot → SSH-based test suite. The update paths validate bootc or sysupdate
hops, deployment continuity, persistence, rollback, and failure handling.

## Architecture

```
test/
├── bootc-install-test.sh      # Orchestrator script (headless, for CI)
├── bootc-update-test.sh       # Update/rollback orchestrator (headless)
├── native-ab-update-test.sh   # Native A/B N through N+3 QEMU test
├── native-ab-components-test.sh # Phase 1 exit-criterion QEMU test (masks, components, etc drift)
├── native-ab-static-test.sh   # Cheap A/B configuration invariants
├── native-publish-test.sh     # Publisher naming/derivation self-test (fixture GPT, no root)
├── native-ab-secure-artifact-test.sh # Secure package/initrd/PCR metadata
├── native-ab-secure-artifact-negative-test.sh # Rejection mutations
├── native-ab-secure-rotation-test.sh # Destructive enrolled-VM rotation proof
├── native-ab-secure-update-test.sh # Destructive secure rollback/fallback proof
├── cayo-ab-install-spike.sh   # Guarded native A/B disk installer (GPT/var-grow/LUKS spike, unchanged since Task 8.2)
├── native-installer-iso-test.sh # Installer ISO boot-chain validation (structural + QEMU positive/negative Secure Boot proof)
├── native-installer-e2e-test.sh # Phase 8 exit: real ISO install of cayo-ab + snow-ab end to end (build/publish -> boot ISO -> non-interactive encrypted install -> MOK enroll -> enforced unattended boot)
├── native-publication-pipeline-test.sh # Phase 7 candidate/verify/promote/withdraw pipeline self-test (OS + ISO fixture legs)
├── snosi-install-test.sh      # snosi-install CLI unit tests (index verification, disk refusal, arg validation, streamed-verify, restage-mok)
├── run-qemu.sh                # Interactive QEMU runner (GTK display)
├── lib/
│   ├── helpers.sh             # Shared test helpers: check(), counters, summary
│   ├── ssh.sh                 # SSH key generation, command execution with retry
│   ├── snosi-install-test-helpers.sh # Wrapper functions around snosi-install internals for fixture testing
│   └── vm.sh                  # QEMU lifecycle, image loading, bootc installation
├── update-tests/
│   ├── persistence-write.sh   # Writes /var, /etc, identity, and container markers before update hops
│   └── persistence-verify.sh  # Verifies the marker matrix after each hop/rollback
└── tests/
    ├── 01-installation.sh     # Tier 1: Installation validation
    ├── 02-services.sh         # Tier 2: Service health
    ├── 03-sysexts.sh          # Tier 3: Sysext validation
    ├── 04-smoke.sh            # Tier 4: Smoke tests
    └── 05-firstboot-presets.sh # Tier 5: First-boot preset parity
```

## Interactive QEMU Runner (run-qemu.sh)

**Usage:**
```bash
just run-qemu [image="output/snow"]
# or directly:
./test/run-qemu.sh <rootfs-directory-or-registry-ref>
```

Boots an image in a QEMU graphical window (GTK display). Loads the image, installs to a virtual disk via bootc, and launches QEMU. The disk image is preserved between runs — subsequent invocations skip the install step.

**Defaults:** 50G disk (via Justfile), 4G RAM, 2 CPUs. Configurable via `DISK_SIZE`, `VM_MEMORY`, `VM_CPUS` env vars.

## Orchestrator (bootc-install-test.sh)

**Usage:**
```bash
sudo ./test/bootc-install-test.sh [image-ref]
```

Must run as root: `bootc install` requires the root user namespace (it aborts under rootless podman with "/proc/1 is owned by 65534"), and the script also uses losetup/mount. When passing a registry ref, the image is pulled into root's podman storage.

**Flow:**
1. Loads OCI image (from local directory or registry reference via skopeo/podman)
2. Generates ephemeral SSH keypair
3. Creates sparse raw disk image
4. Runs `bootc install to-disk --via-loopback` to install the image
5. Injects the generated SSH key into the installed composefs state directory
6. Boots installed disk in QEMU with KVM acceleration
7. Waits for SSH availability (retry loop)
8. Runs all test tiers in order via SSH
9. Reports results, cleans up

The explicit post-install SSH-key injection is intentional: `bootc install --root-ssh-authorized-keys` does not currently place the key where the composefs backend exposes `/root` at runtime. The test mounts partition 3 and writes `state/os/default/var/roothome/.ssh/authorized_keys` directly before booting the VM.

**Configuration:** Supports custom disk size, VM memory, CPU count, and timeouts.

**Justfile target:** `just test-install [image="output/snow"]`

## Update Orchestrator (bootc-update-test.sh)

**Usage:**
```bash
sudo ./test/bootc-update-test.sh <install-ref> <hop-ref> [<hop-ref>...]
```

Installs the starting registry reference to a virtual disk, boots it in QEMU, writes persistence markers, then switches to each hop reference with `bootc switch`. After every hop it reboots, verifies that the staged deployment became booted, verifies that the previous booted deployment moved to the rollback slot, and runs the persistence verifier inside the guest.

**Important defaults and knobs:**
- Must run as root for the same root namespace, loopback, and mount reasons as `bootc-install-test.sh`.
- `DISK_SIZE` defaults to `20G` because update hops pull whole images into the guest's `/var`.
- `HOP_TRANSPORT=containers-storage` pulls hop images with guest `podman` and switches from local storage. Use it as a workaround when bootc's registry transport fails while pulling composefs images.
- `ROLLBACK=1` adds a rollback phase after the final hop and verifies that slots swap correctly while `/var` and `/etc` persistence still holds.
- `INJECT_HOSTKEYS=1` pre-generates host keys on the installed disk for testing images published before the sshd-keygen fix.
- `KEEP_VM=1` leaves the VM and working directory in place for inspection.

The baseline install uses local containers-storage, so its booted digest can differ from the registry manifest digest. The update test therefore asserts continuity across the guest-reported staged, booted, and rollback digests for each hop rather than requiring the installed baseline digest to equal the registry digest.

The production base image uses the same containers-storage staging strategy in `/usr/libexec/bootc-update-stage`: it pulls the followed image with `podman`, stages with `bootc switch --transport containers-storage`, and waits for the next normal reboot instead of forcing one.

### Persistence Matrix

`update-tests/persistence-write.sh` writes markers before the first update:
- `/var` file marker, user home marker under `/var/home`, imported local podman image, and `/opt` bind mount marker under `/var/opt`
- `/etc` new file, local modification to `/etc/motd`, deletion marker for `/etc/issue.net`, hostname change, and NetworkManager connection profile
- Identity baselines for SSH host keys, machine-id, and journal boot count

`update-tests/persistence-verify.sh` runs after each hop and optional rollback. It checks that `/var` data persists, `/etc` local changes carry into new deployments, deleted shipped files remain deleted, hostname and NetworkManager profile persist, SSH host keys and machine-id are stable, and the journal contains prior boots.

## Native A/B Tests

`native-ab-update-test.sh` and `native-ab-components-test.sh` are parameterized
by product (Phase 3, docs/native-ab-contracts.md §1): `PROFILE` (default
`cayo-ab-raw`) selects the `mkosi --profile` value; `IMAGE_ID` defaults to
`PROFILE` with a trailing `-ab-raw` or `-ab` stripped (`cayo`); `CHANNEL`
defaults to `${IMAGE_ID}-ab` (`cayo-ab`). Partition labels and
`MatchPartitionType=partition` transfer targets are always `IMAGE_ID`-based
(GPT labels are never channel-based, §3); OS transfer `Source` blob names and
the UKI's `Target` names are always `CHANNEL`-based, matching the real shipped
transfers (`shared/native-ab/channels/<product>/tree/usr/lib/sysupdate.d/`) —
this mirrors production even for the default `cayo-ab-raw` dev fixture, whose
build output is never itself named `cayo-ab`. Both scripts default to
byte-equivalent behavior against `cayo`/`cayo-ab-raw`/`cayo-ab` when run with
no overrides.

Every harness that runs build outputs through
`shared/native-ab/publish/prepare-native-publication.sh` (updateux,
components, publication, secure-boot, installer-e2e) must stage the
product-curated feature catalog alongside the split artifacts: since the
sysext feature catalog landed (#430, df7bc6e) the publisher hard-fails
without `<product>.features.json` in its source dir. The build emits it as
`output/<IMAGE_ID>.features.json` (NOT `<Output>`-prefixed like the other
split artifacts), and the staged name must be IMAGE_ID-based, not
CHANNEL-based — the publisher derives product from the manifest's
`.config.name`. Each harness's `build_profile` copies it as
`$PROFILE.features.json` next to the other artifacts and its
publish-staging step links it into the stage as
`${IMAGE_ID}.features.json` (`native-installer-e2e-test.sh` is the
exception: its build dir doubles as the publisher source dir, so
`copy_build_artifacts` keeps the `<image_id>.features.json` name as-is).

`native-ab-update-test.sh` uses four real `cayo-ab-raw` builds to exercise signed
manifest rejection, N through N+3 updates, slot reuse, rollback, and boot-count
fallback in QEMU.

`native-ab-components-test.sh` is the Phase 1 exit-criterion QEMU test
(`docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md`, "Phase 1: Fix
Current Prototype Safety"). It is self-contained: it builds two real
`cayo-ab-raw` versions itself (mirroring the Justfile's `ensure-mkosi`
bootstrap plus `mkosi clean -ff` + `mkosi --profile cayo-ab-raw build` --
`SKIP_BUILD=1 BUILD_N_DIR=... BUILD_N1_DIR=...` lets it reuse two already-built
`cayo-ab-raw` output directories for fast iteration instead of paying the
~15-25 min clean-build cost, which includes a full mkosi ToolsTree rebuild,
twice per run), boots N, and asserts in order: (1) no failed systemd units and
bootc/nbc/systemd-sysupdate auto-update timers and services report `masked`,
including the user-scope `bootc-update-notify` mask symlinks;
(1.5, added phase 2, see OVERVIEW.md "Native /var Factory State") the dpkg
database relocation and per-product `/var` audit inventory survive a real
install: `/var/lib/dpkg` is a symlink to `../../usr/lib/sysimage/dpkg`,
`dpkg-query -W systemd`/`dpkg-query -W 'linux-image-*'` both resolve,
`usr/share/snosi/var-inventory.txt` exists with at least one
`image-metadata` line, and no unit failures were introduced; (2)
`/usr/lib/sysupdate.d/` contains only the three OS transfers (no `.feature`
files) and `systemd-sysupdate components` enumerates all 17 shipped sysext
components; (3) two ad hoc test components (`testa`, `testb`, independently
versioned) created under `/etc/sysupdate.<name>.d/` update independently via
`--component=`, leave the GPT partition table and ESP `/EFI/Linux` listing
byte-identical, and enumerate correctly; (4) an unqualified N -> N+1 OS update
(via a `--definitions=` override pointing at a guest-local HTTP fixture, same
pattern as `native-ab-update-test.sh`) succeeds with both test components still
enabled, leaves `/var/lib/extensions.d` untouched, and both components still
list correctly after reboot -- the N+1 update source itself is generated by
running `$PROFILE`'s build output (symlinked under the `$CHANNEL` name the
publisher requires) through
`shared/native-ab/publish/prepare-native-publication.sh --xz` (Phase 3), so
this leg exercises the real public artifact-naming contract, not hand-rolled
fixture names; (5) `snosi-etc-diff` and
`snosi-etc-drift-report.service` correctly report, diff, and restore a live
`/etc/issue` modification against the native A/B `/.etc.lower` tree, and leave
no bind mounts behind. It found and fixed a real bug: the `KernelModules=`
allowlist (at the time in the shared ab-root fragment; Phase 3 moved it to
`mkosi.profiles/cayo-ab-raw/mkosi.conf` and removed it from
`shared/outformat/ab-root/mkosi.conf` entirely, since release channels ship
the full module set unconditionally) excluded `nf_tables`/`nfnetlink`, so
`nftables.service` (shipped and preset-enabled unconditionally by the base
image) failed on every native A/B boot with "Unable to initialize Netlink
socket: Protocol not supported" -- fixed by adding both modules to the
allowlist.

`native-ab-updateux-test.sh` is the Phase 4 exit-criterion QEMU test
(`docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md`, "Phase 4: Build
Native Update UX"). Mirrors `native-ab-components-test.sh`'s build/publish/boot
scaffolding, but builds N and N+1 with DIFFERENT build environments: N
ordinary (publication-disabled), N+1 with `SNOSI_NATIVE_AUTOSTAGE=1` (the
Phase 4 activation-policy knob). Both are published through the real
`prepare-native-publication.sh --xz` pipeline to a local HTTP fixture origin,
signed with an ephemeral GPG key installed at `/etc/systemd/import-pubring.gpg`
(overrides the shipped DEV pubring by ordinary systemd config precedence,
without touching the shipped default) and served via 3 whole-file
`/etc/sysupdate.d/*.transfer` overrides (see CLAUDE.md's "Native A/B Update UX"
section for why this, not `--definitions=`, is the only mechanism
`sysupdate.d(5)` actually supports). Sequence: (1) boot N, assert no bootc/nbc/
upstream-sysupdate activity, `snosi-sysupdate-stage.timer` present but
`is-enabled=static` with no wants link, and a manual stager run against an
origin that only promotes N reports `outcome=current` (motd agrees); (2)
publish N+1, run the stager manually -- it stages, its own post-stage
partition/UKI checks pass, `update-check`/semaphore/motd/`snosi-update-status`
all agree, the native notify unit files + static wants link are present, and
running the shared `bootc-update-notify` script directly (stubbed
`notify-send` on `$PATH`) proves ack-gating: first run notifies, second run
for the same staged version is a silent no-op; (3) reboot into N+1 and assert
`snosi-sysupdate-stage.timer` is ACTIVE -- the static wants link arrived WITH
the image, the actual Phase 4 exit criterion -- semaphore is gone (fresh
`/run`), a fresh manual stager run reports `outcome=current` again, and no
bootc/nbc/upstream-sysupdate activity reappeared (exactly one update stack);
(4) tamper case: fabricates a filename set claiming a version newer than N+1 by
hardlinking N+1's own already-published bytes under new names (no 3rd mkosi
build, and guarantees `systemd-sysupdate` actually attempts to trust the index
rather than silently no-opping as "nothing newer"), signs a valid SHA256SUMS
for it, then truncates `SHA256SUMS.gpg` to break the signature -- the stager
must fail closed: `outcome=failed`, no semaphore, no new partition, running
version unchanged. The four steps between them exercise all three of the
stager's decision paths live: step 1 now asserts two additional
factory-UKI properties before ever invoking the stager -- the ESP UKI is
named `<channel>_<version>.efi` (the channel transfer's own Target
`MatchPattern=`, fixed from mkosi's former `<ImageId>-<kver>-<roothash>.efi`
default -- see CLAUDE.md "Native A/B Update UX") and `systemd-sysupdate
list` already reports N as installed -- then hits the SAME rc!=0 +
index-probe-passes "current" path as step 3 (`check-new` legitimately
finds nothing newer once the origin only promotes N); step 3 hits that
same path again after reboot into N+1; step 4 hits the rc!=0 + probe-fails
fail-closed path. (Step 2's manual stage of N+1 is the sole rc==0 "found
something newer" path.) The stager's separate not-newer-than-running
guard -- `check-new` sideways re-offering the already-running version,
needed only under the pre-fix naming gap step 1 used to exercise -- is no
longer reachable by this scenario and remains untested belt-and-suspenders.
First full run: 53/53 assertions passed (2026-07-15,
N=20260715003309 -> N+1=20260715003624).

`native-publish-test.sh` is a static, non-root regression test for
`shared/native-ab/publish/prepare-native-publication.sh` (Phase 3), the script
that turns mkosi's internal split outputs (double-`.raw` filenames with a
literal, un-substituted `@v`, e.g. `cayo-ab.cayo_@v.root.raw.raw`) into the
frozen `docs/native-ab-contracts.md` §4 public names. It derives
product/channel/version from the built artifacts themselves (never from
command-line arguments): product + version come from the mkosi JSON
manifest's `.config.name` / `.config.version` (version validated against the
frozen `^[0-9]{14}$` grammar), and channel is the profile's `Output=` value,
validated to equal `<product>-ab` -- this is what makes the script refuse to
"publish" a `*-ab-raw` dev fixture by construction, not by convention.
PARTUUIDs come from `sfdisk --json` on the built disk image, which needs
neither a loop device nor root (verified against a real 16 GiB disk as an
unprivileged user). `--xz` compresses the root/root-verity/disk artifacts and
appends `.xz`, matching §4 exactly; without `--xz` the same base names are
produced without the suffix, an intentionally-not-frozen fast path for local
iteration and the two QEMU tests' fixtures. The test builds a synthetic
fixture (`truncate` + `sfdisk` script mode for a fake GPT, plus a fake JSON
manifest) and exercises the happy path (both with and without `--xz`,
verifying names against the same frozen-grammar regexes as
`test/native-ab-contracts-test.sh`, and that `SHA256SUMS` verifies), plus
negative cases: a `*-ab-raw` profile name is rejected, a malformed version is
rejected, and a missing split artifact is rejected. `test/native-ab-contracts-
test.sh` also runs it internally so a naming drift fails that same static
gate. Not wired into `PostOutputScripts=`: see the "Why this is not wired
into PostOutputScripts=" note in the script's own header for why (real per-
build disk cost of copying multi-gigabyte artifacts on every build, not a
permissions limitation -- sfdisk itself needs no root and `$OUTPUTDIR`
contents are confirmed available to postoutput scripts).

`native-ab-secure-artifact-test.sh` checks the secure build's
coherent systemd package set, TPM-capable initrd, `.pcrpkey`, and `.pcrsig`.
Passing an old PCR certificate and new public key enables the eight-signature
transition checks. `native-ab-secure-artifact-negative-test.sh` requires the
validator to reject an unpaired old/new PCR policy and a transition that
publishes the old key.

`native-ab-secure-rotation-test.sh` is a destructive manual integration test for
an already MOK-enrolled disposable VM with a persistent vTPM. It requires
`--yes`, root SSH, the exact guest machine ID, and a tested external recovery
key. It stages local split artifacts inside the guest and uses
`systemd-sysupdate` against a guest-local HTTP source. The harness creates an
ephemeral OpenPGP key, signs `SHA256SUMS`, temporarily installs that public
keyring, and requires `Verify=yes`. It then:

1. Ensures the transition UKI is installed before changing TPM metadata.
2. Enrolls the old signed-PCR key and removes the new token, leaving old-only.
3. Requires an unattended Secure Boot of the transition UKI.
4. Enrolls the new key and removes the old token by discovered fingerprint and keyslot.
5. Requires a second unattended boot of the byte-identical UKI with new-only.

The harness verifies boot-ID changes, Secure Boot, lockdown, measured UKI state,
roothash, UKI hash, LUKS2 `/var`, empty raw-PCR policy, PCR 11 signed policy, and
system health. The UKI hash is read from the entry that `bootctl` reports as
currently running. It does not create the VM, automate MokManager, or cover N
through N+3 rollback and fallback; `native-ab-secure-update-test.sh` covers that
separate destructive sequence. `SSH_PORT`, `SSH_TIMEOUT`, `SOURCE_PORT`, and
`KEEP_REMOTE` are optional environment knobs.

`native-ab-secure-update-test.sh` requires `--yes`, exact guest machine and Incus
instance identities, N+1/N+2 dual-signed artifacts, N+3 signed only by the new
key, the external recovery key, and root SSH. It verifies all three artifacts,
serves N+2/N+3 from a verified guest-local signed manifest, and restarts that
transient source after the N+2 reboot. Starting from N+1 with only the new TPM
token, it checks N+2/N+3 slot reuse and unattended boots, explicit rollback to
N+2, and return to N+3. It then renames the blessed N+3 UKI to `+3-0`, corrupts
the N+3 root, requires a new N+3 roothash plus emergency marker for each of three
Incus-driven boot attempts, and accepts only an automatic N+2 fallback with the
N+3 UKI at `+0-3`. Successful boots must not leave TPM setup or NvPCR units
failed.

Durable test keys belong under `.snosi-private`, not `.mkosi-private`; mkosi
removes the latter during `clean -ff`. The secure profile masks systemd 261's
unused NvPCR definitions and product/login writers because its anchor credential
cannot migrate between PCR signing keys. Signed-PCR LUKS unlock and TPM SRK setup
remain enabled.

`native-ab-secure-boot-test.sh` (Phase 5) is a FULLY AUTOMATED end-to-end QEMU
harness for a production native profile (`PROFILE`, default `snow-ab`; also
accepts `cayo-ab`) — no MokManager interaction, no manual boot-time input. It
builds two real versions (N, N+1) itself (same `SKIP_BUILD=1
BUILD_N_DIR=...  BUILD_N1_DIR=...` fast-iteration knobs as the other native-ab
QEMU tests), installs N to a raw disk FILE via `cayo-ab-install-spike.sh
--allow-file --yes --encrypt-var --recovery-key-file` (deliberately no
`--mok-certificate`: that talks to the HOST's live EFI variable store, wrong
for a loopback install, and the spike script itself refuses the combination),
then boots it under a from-scratch OVMF+swtpm+MOK stack it assembles itself:

- `virt-fw-vars --add-mok <guid> mkosi.crt` pre-enrolls the Snosi cert into a
  writable copy of `/usr/share/OVMF/OVMF_VARS_4M.ms.fd` (Microsoft keys
  already enrolled ⇒ Secure Boot enforced from first boot, no
  `SecureBootAutoEnroll`), paired with `OVMF_CODE_4M.secboot.fd`.
- `swtpm socket --tpm2` provides the vTPM; QEMU's `-tpmdev emulator` chardev
  MUST point at swtpm's `--ctrl` socket, not `--server` (pointing at
  `--server` hangs QEMU at startup indefinitely — confirmed and documented in
  the script's own comments, a real bug found building this harness).
- The serial console is a bidirectional `server=on,wait=off` QEMU chardev
  socket. Since this host has neither `expect` nor `socat`, a single
  self-contained Python process (`start_console_pump`) both tees the console
  to a log file AND types the LUKS recovery passphrase automatically the
  first time (and only the first time) an `ask-password`-shaped prompt
  appears — a separate read-only "log" process and a separate "sender"
  process do NOT both work against one such socket (only one client
  connection is accepted); this was tried and confirmed broken before
  settling on the single combined design.

Assertions, first boot (no TPM token yet — recovery-passphrase prompt
automated): `mokutil --sb-state`/`bootctl status` show enforced Secure Boot
and `Measured UKI: yes` (the MOK-signed shim → systemd-boot → UKI chain
actually loaded, not merely present on disk), kernel lockdown is
integrity/confidentiality mode, `/var` is LUKS2 via `/dev/mapper/var`, `/etc`
is the overlay, no failed units, no NvPCR journal errors,
`snow-linux-live-setup.service` did NOT fire (see CLAUDE.md's decision note —
a real bug found and fixed while building this harness: its old marker-only
gate could not distinguish a real native install's true first boot from live
media), and `test/tests/05-firstboot-presets.sh` is reused VERBATIM via the
same `TEST_LIB_DIR`/`lib/helpers.sh` remote-execution pattern
`bootc-install-test.sh` already uses — reusing a bootc-authored check against
a native/secure profile surfaces 3 fully-explained, expected differences
(`bootc-update-stage.timer`/`nbc-update-download.timer` are permanently
masked by native updater isolation; `run-lock.mount` no longer exists in the
secure profile's Forky systemd 261 at all), asserted to be EXACTLY that set,
not "any failure is fine" — a real regression anywhere else still fails hard.

In-guest TPM enrollment mirrors `native-ab-secure-rotation-test.sh`'s
`enroll_token` EXACTLY (`--tpm2-pcrs=` empty raw-PCR set,
`--tpm2-public-key=.snosi-private/pcr-signing.pub --tpm2-public-key-pcrs=11`
signed PCR 11 policy). Every reboot after enrollment feeds ZERO serial input
by design — a hang at `wait_for_ssh` would itself prove the initrd needed a
passphrase it didn't get. Desktop assertions (Snow only):
`graphical.target`/`gdm.service` active, a logind seat, `notify-send`
present, fresh-`/var` tmpfiles ownership (`/var/home`, `/var/roothome`,
`/var/opt`), `dpkg-query` against the relocated `/var/lib/dpkg`, and a
minimal ad hoc sysext fixture in PLAIN-DIRECTORY form (not a raw disk image —
`systemd-sysext` merges directories under `/var/lib/extensions/` identically;
no erofs/squashfs build or guest-side loop mount needed) proving the
CLAUDE.md hicolor icon-cache contract end to end — including that the
extension-release file must declare a matching `SYSEXT_LEVEL=`, not just
`ID=`, when the host os-release sets one (another real bug found live:
`systemd-sysext merge` silently reports "1 ignored due to incompatible
image(s))" otherwise).

The secure update hop publishes N+1 through the real
`prepare-native-publication.sh --xz` pipeline to a local HTTP origin signed
with an ephemeral GPG key (same `/etc/systemd/import-pubring.gpg` override
mechanism as `native-ab-updateux-test.sh`), runs
`/usr/libexec/snosi-sysupdate-stage`, and reboots with zero serial input —
proving the signed PCR 11 policy survives a REAL UKI change (the entire point
of signed-vs-raw PCR policy), that `/var` and `/etc`-overlay persistence
markers survive, and that the N rollback entry is still present
(`InstancesMax=2`). Finishes with a non-destructive recovery-keyslot check
(`cryptsetup open --test-passphrase`), never a destructive token wipe.
**NvPCR journal errors are asserted per boot** via a shared
`assert_nvpcr_journal_clean` helper called after EVERY boot that reaches SSH
(first boot, the TPM-enrollment reboot, each update hop, and — in
`--full-window`, via `assert_post_update_common` — both explicit-rollback
boots and the boot-count-fallback recovery boot): `journalctl -b` only ever
sees the CURRENT boot, so the previous end-of-sequence checks silently
missed every earlier boot (review finding fixed 2026-07-15; this raised the
default-mode total from 56 to 58 and the full-window total from 120 to 125).
First full run: 56/56 assertions passed (2026-07-15, `snow-ab`
N=20260715021239 → N+1=20260715021816; the default-mode total is 58 after
the per-boot NvPCR change). Requires `swtpm`/`swtpm-tools` and
`virt-fw-vars` (`virt-firmware`); see CLAUDE.md for how those were installed
on a snosi dev host itself (read-only `/usr`, no `apt-get install`) and the
`$SUDO_USER`-home-resolution fix needed because plain `sudo` resets `$HOME`.

`--full-window` extends the same harness into the **Phase 5 exit-criterion
run** ("Snow completes installation, N through N+3, rollback, and fallback in
QEMU or Incus with Secure Boot and TPM unlock"). Default mode is byte-for-byte
unchanged when the flag is absent. After the N→N+1 hop it builds N+2 and N+3
(four real builds total) and publishes each through the same
ephemeral-signed-origin pipeline ONE VERSION AT A TIME (the origin's
`SHA256SUMS` advertises a single version, matching the production
channel-pointer contract), staging each hop via
`/usr/libexec/snosi-sysupdate-stage` and rebooting with zero serial input.
Beyond the per-hop secure invariants (enforced SB, `Measured UKI: yes`,
unattended TPM unlock, exactly one `systemd-tpm2` token, `/var` + `/etc`
markers), it asserts `InstancesMax=2` slot accounting EXACTLY: after N+2 the
root-slot label set must be exactly `{N+1, N+2}` (N vacuumed) with N+2
physically occupying N's freed GPT slot; after N+3, exactly `{N+2, N+3}` with
N+3 in N+1's freed slot. Explicit rollback is `bootctl set-oneshot` to the
N+2 entry, then a plain reboot back to the persistent N+3 default. Boot-count
fallback re-arms the blessed N+3 UKI to `+3-0`, then corrupts N+3's root
FROM THE HOST while the VM is fully powered off (`losetup` + `dd` over the
labeled partition — deliberately different from the SB-off prior art in
`native-ab-update-test.sh`/`native-ab-secure-update-test.sh`, which corrupt
guest-side while running) and power-cycles: each of three failed attempts
must produce a NEW "Entering emergency mode" console marker (the baseline
count is seeded from whatever already exists in the cumulative console log
at that point — one log spans the whole run — not a hardcoded 0, so an
unrelated earlier emergency line cannot be double-counted as this loop's
first match), and between
cycles the ESP is loop-mounted read-only from the host (VM off, so nothing
races a live QEMU) to assert the counting suffix decremented exactly
(`+2-1`, `+1-2`, `+0-3`); the fourth power-cycle must boot N+2 automatically
with TPM unlock intact and leave the exhausted entry at `+0-3`. **swtpm
lifecycle gotcha (root-caused live in the first full-window run, after 113
green assertions):** swtpm terminates when its QEMU client exits (QEMU shuts
the daemon down over the ctrl channel), so every HOST-side power-cycle must
re-arm swtpm before the next QEMU launch — against the SAME persistent
`--tpmstate` directory, never reinitialized (the sealed state behind the
enrolled LUKS token lives there). Guest-initiated reboots keep one QEMU
process alive and never hit this, which is why the N..N+3 hops and explicit
rollback all passed before the first power-cycle exposed it. Phase 5 exit
evidence: 120/120 assertions, 2026-07-15, `snow-ab` N=20260715042306 →
N+1=20260715042712 → N+2=20260715043757 → N+3=20260715044206, explicit
rollback to N+2 and back, boot-count fallback to N+2, ~41 min wall (warm
caches, ~4 min per build). Re-validated green after the per-boot NvPCR
coverage fix: 125/125 assertions, 2026-07-15, `snow-ab` N=20260715074012 →
N+1=20260715074417 → N+2=20260715075510 → N+3=20260715075918, same window
shape. The re-run's first attempt (124/125) also caught a REAL race in
`snosi-sysupdate-stage`'s post-stage verification: an immediate `lsblk`
after `systemd-sysupdate update` can read a mixed stale udev view (new
PARTLABEL, old pre-vacuum PARTUUID) on the reused slot even though the
on-disk GPT is correct — fixed with `udevadm settle` + a bounded re-read
retry in the stager (see yeti/OVERVIEW.md "Native A/B Update UX (phase 4)").

**Phase 6 (Secure Snowfield):** the same harness runs unmodified with
`PROFILE=snowfield-ab` (`IMAGE_ID` derives to `snowfield`, already routed
through `HAS_DESKTOP=1` before Phase 6). Two new pieces, both gated on
`IMAGE_ID == snowfield`:
`test/snowfield-artifact-test.sh` (Surface kernel/package/module/firmware/
initrd static checks, invoked right after the existing
`native-ab-secure-artifact-test.sh` call) and a new "Step 3c" module-trust
runtime check (right after the pre-existing first-boot lockdown assertion):
`keyctl show %:.builtin_trusted_keys` holds an asymmetric key; a
hardware-free signed in-tree module (`isofs`) and a genuine Surface in-tree
module (`surface_aggregator`) both report the SAME `modinfo -F signer`
("Build time autogenerated kernel key") and `sig_key` fingerprint and both
load successfully; a trivial out-of-tree module built IN-GUEST against
`linux-headers-surface` (gcc/make confirmed present in the built image) is
genuinely unsigned and is rejected
(`Key was rejected by service` / `dmesg`: `Loading of unsigned module is
rejected`). Decision: Surface in-tree modules do not need re-signing with
the Snosi MOK — see `docs/native-ab-contracts.md` §7 and CLAUDE.md's
"Secure Snowfield" section for the full writeup and the real
`CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y` lockdown bug this investigation
found and fixed (`KernelCommandLine=lockdown=integrity` added to
`shared/native-ab-secure/mkosi.conf`) along the way — the FIRST run through
this harness for `snowfield-ab` scored 64/65 (only the pre-existing
profile-neutral lockdown assertion failed); after the fix, a clean rebuild
+ re-run passed in full. `--full-window` was deliberately not run for
snowfield in Phase 6 (see `docs/native-ab-capacities.md`
"PROVISIONAL-pending-hardware" and CLAUDE.md's "PENDING HUMAN GATE"
checklist) — representative Surface hardware validation is out of scope
for a QEMU-only machine and is the actual Phase 6 plan exit criterion.

**Phase 8 (ISO install end-to-end).** `test/native-installer-e2e-test.sh` is the
Phase 8 exit criterion: the sole test that proves a user can take the shipped
network-installer ISO and reach a running, Secure-Boot-enforced, TPM-unlocked
native A/B system with no keyring injection and no hand-editing — the whole
trust chain on stock artifacts. Per run it (1) builds the ISO fresh (so the
own-boot-medium fix from commit 99f4921 is exercised in the REAL initramfs, not a
fixture) and builds+publishes `cayo-ab` and `snow-ab` through the actual
`prepare -> publish-candidate -> verify-remote -> promote` pipeline with the DEV
signing key to a local origin served by `test/lib/range-http-server.py`; trust leg
is the stock shipped `import-pubring.gpg` everywhere. Then per product it boots a
VM with a VIRGIN Secure-Boot varstore (`OVMF_VARS_4M.ms.fd`, no MOK) and
persistent swtpm against a blank disk sized to the product's documented minimum
plus a 3 GiB margin (so the grow-to-end path runs), and drives the seven-step
sequence: (2) ISO boots to the installer with SB enabled; (3, cayo-ab only)
own-boot-medium install is refused in the real initramfs, before any write to the
ISO device; (4) non-interactive encrypted-`/var` install with a recovery key, TPM
enrollment, and a MOK password file — first proving a world/group-readable
password file is refused — then asserting exactly one `systemd-tpm2` LUKS token,
a recovery keyslot, a grown `var`, and that the recovery passphrase opens the
volume (`--test-passphrase`); (5) pre-enrollment boot fails with shim's Security
Violation because the MOK is not yet enrolled; (6) `--restage-mok` succeeds
(cayo-ab gets a dedicated fresh-ISO-boot restage; snow-ab skips it); (7)
host-side `virt-fw-vars --add-mok` into the SAME varstore simulates the MokManager
one-time approval, then the installed system boots fully enforced and fully
unattended, verifying SB enforced, kernel lockdown, `/var` on the LUKS mapper via
unattended TPM unlock, the `/etc` overlay, correct `IMAGE_ID`/`IMAGE_VERSION`, all
`install-info.json` fields, a clean `snosi-update-status`, no failed units, and
that the recovery passphrase still opens `/var`. cayo-ab runs the full sequence;
snow-ab runs steps 2, 4, 5, 7 only; `snowfield-ab` is behind `--with-snowfield`
(off by default — QEMU cannot represent Surface hardware, same rationale as Phase
6). `SKIP_ISO_BUILD` / `SKIP_CAYO_BUILD` / `SKIP_SNOW_BUILD` with
`BUILD_CAYO_DIR` / `BUILD_SNOW_DIR` skip the multi-GiB rebuilds during iteration.
First full run: 75/75 assertions passed (2026-07-15, cayo-ab full + snow-ab
partial, ISO `snosi-native-installer_20260716003626_x86-64.iso` (cayo-ab image 20260715203830, snow-ab 20260715204023), wall time ~17 min). It also fixed real product
bugs along the way — the installer ISO was missing `fdisk` (sfdisk), `binutils`
(objcopy for `.pcrpkey` extraction), and `openssl`, and `snosi-install` wrote
several tool-diagnostic streams to stdout instead of stderr, dumped a UKI section
to `/dev/null` (objcopy always exits 1 doing that), and left the LUKS mapper close
un-retried — see CLAUDE.md "Native A/B Prototype".

## Test Tiers

### Tier 1 — Installation Validation (01-installation.sh)

Validates the fundamental bootc/immutable OS installation:

- System reached `running` or `degraded` state (systemd boot complete)
- Root filesystem is read-only
- composefs is active
- `/usr` is read-only
- `bootc status` reports correct image reference

### Tier 2 — Service Health (02-services.sh)

Validates critical system services:

- systemd-resolved is active (DNS)
- NetworkManager is active (networking)
- SSH is active (remote access)
- `nbc-update-download.timer` is loaded, and on composefs installs is condition-gated off (not active, service never failed — see frostyard/nbc#139)
- `frostyard-updex` is installed
- No failed systemd units are present

### Tier 3 — Sysext Validation (03-sysexts.sh)

Validates the sysext infrastructure:

- `systemd-sysext` binary is available
- `systemd-sysext list` command succeeds
- sysupdate component directories (`/usr/lib/sysupdate.<name>.d/`, one per sysext) exist and have entries
- Lists currently active extensions

### Tier 4 — Smoke Tests (04-smoke.sh)

End-to-end functional validation:

- Network connectivity (curl to example.com)
- DNS resolution works
- Package metadata integrity (`dpkg -l` reports > 100 packages)
- System time is plausible (year ≥ 2025)
- Hostname and locale are configured
- Default system locale is set (`LANG=` present in `/etc/locale.conf` — shipped as `en_US.UTF-8` by base `mkosi.extra`; on trixie `/etc/default/locale` is a symlink to it, so PAM and systemd read the same file)

### Tier 5 — First-Boot Preset Parity (05-firstboot-presets.sh)

Verifies the hermetic-`/etc` first-boot model (image ships machine-id as
`uninitialized` and no unit enablement symlinks in `/etc`):

- machine-id was committed on first boot (32-hex, not `uninitialized`)
- `first-boot-complete.target` was reached (the boot really was a systemd first boot)
- `preset-global.service` succeeded (user-scope presets applied)
- `systemd-firstboot.service` is disabled (no console prompts)
- **Manifest parity:** every enablement symlink listed in
  `/usr/share/snosi/enablement-manifest.txt` (recorded by the outformat
  finalize when it stripped the image `/etc`) was recreated by the preset
  pass; extra runtime symlinks not in the manifest are reported informationally
- Exactly one gnome-remote-desktop variant is enabled (they declare mutual `Conflicts=`)
- SSH host keys were generated

## Helper Libraries

### helpers.sh

Shared test harness sourced by all four test scripts. Provides:

- `PASS` / `FAIL` counters — initialized to 0
- `check(description, command...)` — Run a command, print TAP-like output, increment counters
- `print_summary()` — Print results line and `exit $FAIL`

### ssh.sh

- `generate_ssh_key()` — Creates ephemeral ED25519 keypair
- `ssh_exec(host, command)` — Execute command on VM via SSH with retry and timeout
- Handles connection retry for VM boot wait

### vm.sh

- `load_image(ref)` — Loads OCI image from local dir or registry (uses buildah mount + cp -a + commit pattern for local dirs)
- `install_to_disk(disk)` — Runs `bootc install to-disk` with loopback inside a privileged podman container
- `vm_start(disk)` — Launches QEMU with KVM, OVMF firmware, port forwarding for SSH
- `vm_stop()` / `vm_cleanup()` — Graceful shutdown and disk cleanup
- `find_ovmf()` searches common OVMF locations, including Incus' bundled firmware path (`/usr/incus/share/qemu/`)

`bootc-update-test.sh` sources `vm.sh` after setting `DISK_SIZE=20G`; keep that ordering if refactoring because `vm.sh` snapshots the disk size at source time.

## CI Integration

`validate.yml` runs `native-ab-static-test.sh`, `native-ab-contracts-test.sh`
(which also runs `native-publish-test.sh` internally), and standalone
`native-publish-test.sh` on pull requests and main-branch pushes -- all static,
non-root, no image build. The destructive rotation test and build-dependent
artifact tests (including the QEMU `native-ab-update-test.sh` and
`native-ab-components-test.sh`) remain manual because CI does not provision
MOK, a persistent vTPM, signing material, or the large real-build artifacts.

The `test-install.yml` workflow runs these tests on manual dispatch:
1. Sets up KVM-enabled runner
2. Installs QEMU + OVMF + podman + skopeo
3. Resolves the selected `ghcr.io/frostyard/snow:<tag>` to a digest and verifies that immutable ref with `cosign.pub`
4. Pulls the verified image ref
5. Runs the full test suite

Not run automatically on every PR due to infrastructure requirements (KVM, large disk, long runtime).
