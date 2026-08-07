# Issue 517 — evidence dump

> **CLOSED 2026-08-07.** Root cause was systemd 261 moving the
> `gpt-auto-root[-luks]` udev rules from `99-systemd.rules` into
> `90-image-dissect.rules`, which dracut does not install. Fixed by
> [snosi#520](https://github.com/frostyard/snosi/pull/520); **proven on a real
> published image** — the target installs and boots with Secure Boot enforced
> and a TPM-unlocked LUKS root. The next assertion after it,
> `cat /boot/loader/entries/*.conf`, was a harness bug (bootc leaves `/boot`
> unmounted unless it is using it) and is fixed in
> [snosi#524](https://github.com/frostyard/snosi/pull/524).
>
> Kept as a record of what was measured and where the reasoning went wrong.
> Safe to delete.


Everything gathered while chasing the secure bootc install to its current
failure. Written for whoever picks up #517 next, so nothing has to be
re-derived. Uncommitted scratch — delete it when the issue closes.

**Author's note on trust:** I got the root cause of this wrong once already (see
[Wrong turn](#wrong-turn-the-missing-unit-template)). Everything below is either
a captured artefact or a command you can re-run. Where I am inferring rather
than observing, it says so.

---

## The failure

A secure bootc install completes, boots the signed UKI under enforced Secure
Boot, and drops to emergency mode because nothing unlocks the encrypted root.

Guest serial console, post-MOK-enrollment boot:

```
[    0.000000] Command line: rw composefs=?a0c1f9a9690a4e7ce2c702eacdeed3b0c0bd59f1819a470feb0d2af82c66f4a60eecc1fe6830521b8157a847f5de3dd8f4d21dce240ac70a0cd7325087eca94f console=uart,io,0x3f8
[    1.808479] systemd[1]: systemd 261.2-1 running in system mode (… +LIBCRYPTSETUP +LIBCRYPTSETUP_PLUGINS … +TPM2 …)
[    1.872348] systemd[1]: Expecting device dev-gpt\x2dauto\x2droot.device - /dev/gpt-auto-root...
[  OK  ] Reached target cryptsetup.target - Local Encrypted Volumes.
         Expecting device dev-tpm0.device - /dev/tpm0...
[  OK  ] Reached target remote-cryptsetup.target - Remote Encrypted Volumes.
[  OK  ] Found device dev-tpm0.device - /dev/tpm0.
[  OK  ] Reached target tpm2.target - Trusted Platform Module.
[ TIME ] Timed out waiting for device dev-gpt-auto-root.device.
[DEPEND] Dependency failed for systemd-fsck-root.service - File System Check on /dev/gpt-auto-root.
[DEPEND] Dependency failed for sysroot.mount - Root Partition.
[DEPEND] Dependency failed for initrd-root-fs.target - Initrd Root File System.
[DEPEND] Dependency failed for bootc-root-setup.service - bootc setup root.
Entering emergency mode. Exit the shell to continue.
Cannot open access to console, the root account is locked.
```

Two details that matter:

- **`cryptsetup.target` is reached with no units beneath it.** Nothing attempted
  an unlock. Had a `systemd-cryptsetup@root.service` been queued we would see
  `Starting Cryptography Setup for root...`.
- **`gpt-auto-root-luks` appears exactly zero times** in the whole console log.
  The LUKS branch never executed.

Environment for that run:

| | |
|---|---|
| image | `ghcr.io/frostyard/cayo@sha256:8f19bad4e0b8df6ac71330125636672368c68236d1079a0b829156f0c641ffc0` |
| fisherman | v0.2.14 |
| kernel | `7.1.3+deb13-amd64` |
| systemd (guest PID 1) | `261.2-1` |
| UKI cmdline | `rw composefs=?a0c1f9a9…4f` — no `root=`, no `luks.*`, by design |

---

## What is ruled out

### The disk is correct — not an installer bug

Captured from the installed target before the lane's cleanup trap removed it:

```
--- partition identities ---
### /dev/loop4p1
ID_FS_TYPE=vfat
ID_PART_ENTRY_NAME=EFI-SYSTEM
ID_PART_ENTRY_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
### /dev/loop4p2
ID_FS_TYPE=crypto_LUKS
ID_PART_ENTRY_NAME=root
ID_PART_ENTRY_TYPE=4f68bce3-e8cd-4db1-96e7-fbcaf984b709
    LUKS: yes
Version:       	2
  0: crypt
  0: luks2
  1: luks2
Tokens:
  0: systemd-tpm2
  0: pbkdf2
```

So: correct x86-64 root DPS type GUID, genuinely `crypto_LUKS`, LUKS2 with both
a `systemd-tpm2` token and a pbkdf2 recovery slot. fisherman's partitioning,
LUKS setup and TPM enrollment are all doing their job.

### The ESP chain is correct and fully signed

```
### /EFI/BOOT/BOOTX64.EFI  (1036152 bytes)
 - /C=US/…/CN=Microsoft Corporation UEFI CA 2011
 - /C=US/…/CN=Microsoft UEFI CA 2023
### /EFI/BOOT/mmx64.efi  (873904 bytes)
 - /CN=Debian Secure Boot Signer 2022 - shim
### /EFI/BOOT/grubx64.efi  (160616 bytes)      ← MOK-signed systemd-boot
 - /CN=snosi Secure Boot 2026/O=frostyard
### /EFI/Linux/bootc/bootc_composefs-a0c1f9a9….efi  (101157224 bytes)
 - /CN=snosi Secure Boot 2026/O=frostyard
    sections: .text .rodata .data .sbat .sdmagic .reloc .osrel .cmdline .uname .pcrpkey .linux .initrd .pcrsig
    cmdline:  rw composefs=?a0c1f9a9…4f
```

The harness's pre-enrollment check also passes, which is only possible with a
correctly signed UKI:

```
ok - Microsoft-only varstore rejects the unenrolled MOK stage
```

### The initramfs has everything it needs

Unpacked from the image's own signed UKI (`boot/EFI/Linux/7.1.3+deb13-amd64.efi`,
`.initrd` section):

| component | state |
|---|---|
| dracut module `systemd-cryptsetup` | **enabled** (in `modules.txt`) |
| `usr/bin/systemd-cryptsetup` | present (with `usr/lib/systemd/systemd-cryptsetup` symlink to it) |
| `libcryptsetup.so.12` | **present** |
| `libcryptsetup-token-systemd-tpm2.so` | **present** |
| `systemd-gpt-auto-generator` | present |
| `systemd-cryptsetup-generator` | present |
| `libsystemd-shared-261.so` | present — matches PID 1's 261.2-1, **no trixie/forky skew** |
| `add_root_cryptsetup`, `/dev/gpt-auto-root-luks` strings in the generator binary | **present** — LUKS support compiled in |

Full dracut module list in the initramfs:

```
dash systemd systemd-ask-password systemd-battery-check systemd-cryptsetup
systemd-initrd systemd-journald systemd-modules-load systemd-pcrphase
systemd-sysctl systemd-tmpfiles systemd-udevd modsign console-setup i18n ostree
bootc systemd-sysusers btrfs crypt dm kernel-modules kernel-modules-extra lvm
mdraid nvdimm overlay-root qemu fido2 pkcs11 tpm2-tss etc-overlay hwdb lunmask
resume rootfs-blocks …
```

### The generator ran

The **only** thing in the entire initramfs that references `gpt-auto-root` is the
generator binary itself — there is no static `sysroot.mount`, and no bootc or
ostree dracut hook writing one:

```
$ grep -rl "gpt.auto" .          # inside the unpacked initramfs
./usr/bin/dracut-cmdline
./usr/bin/udevadm
./usr/lib/bootc/initramfs-setup
./usr/lib/systemd/system-generators/systemd-gpt-auto-generator
./usr/lib/systemd/system-generators/systemd-fstab-generator
./usr/lib/x86_64-linux-gnu/systemd/libsystemd-shared-261.so
./usr/lib/udev/rules.d/60-persistent-storage-dm.rules
```

So the console's `Expecting device dev-gpt-auto-root.device` can only have come
from the generator. **It ran, and it created the root mount — it just did not
create the cryptsetup unit.**

### The symlink is device-mapper gated

`usr/lib/udev/rules.d/60-persistent-storage-dm.rules:46`:

```
ENV{ID_PART_ENTRY_SCHEME}=="gpt", ENV{ID_PART_GPT_AUTO_ROOT}=="1", SYMLINK+="gpt-auto-root"
```

A **dm** rule — it fires on the decrypted mapper. No unlock → no mapper → no
symlink → `sysroot.mount` waits forever. Consistent with the console exactly.

---

## The generator is capable — demonstrated

Running the **real initramfs's own generator**, extracted from the **real signed
UKI**, in forced-discovery mode, it emits everything required:

```
/run/gen/normal/systemd-fsck-root.service
/run/gen/late/sysroot.mount
/run/gen/late/systemd-cryptsetup@root.service
/run/gen/late/dev-gpt\x2dauto\x2droot\x2dluks.device.wants/systemd-cryptsetup@root.service
/run/gen/late/systemd-veritysetup@root.service
/run/gen/late/dev-disk-by\x2ddesignator-root\x2dverity\x2ddata.device.wants/systemd-veritysetup@root.service
/run/gen/late/sysroot.mount.wants/systemd-pcrfs@sysroot.service
/run/gen/late/sysroot.mount.wants/systemd-validatefs@sysroot.service
/run/gen/late/dev-mapper-root.device.d/50-job-timeout.conf
/run/gen/late/initrd-root-device.target.d/50-root-device.conf
```

`systemd-cryptsetup@root.service` as generated:

```ini
# Automatically generated by systemd-gpt-auto-generator

[Unit]
Description=Cryptography Setup for %I
Documentation=man:crypttab(5) man:systemd-cryptsetup-generator(8) man:systemd-cryptsetup@.service(8)

DefaultDependencies=no
After=cryptsetup-pre.target systemd-udevd-kernel.socket systemd-udevd.service systemd-tpm2-setup-early.service
Before=blockdev@dev-mapper-%i.target
Wants=blockdev@dev-mapper-%i.target
IgnoreOnIsolate=true
Before=umount.target cryptsetup.target
Conflicts=umount.target
BindsTo=dev-gpt\x2dauto\x2droot\x2dluks.device
After=dev-gpt\x2dauto\x2droot\x2dluks.device

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutSec=infinity
KeyringMode=shared
…
ExecStart=/usr/bin/systemd-cryptsetup attach 'root' '/dev/gpt-auto-root-luks' '' ''
```

`sysroot.mount` as generated:

```ini
[Unit]
Description=Root Partition
Before=initrd-root-fs.target
Requires=systemd-fsck-root.service
After=systemd-fsck-root.service
After=blockdev@dev-gpt\x2dauto\x2droot.target

[Mount]
What=/dev/gpt-auto-root
Where=/sysroot
```

**So the embedded generator can set up the encrypted root.** It has cryptsetup
*and* verity support and wires the dependencies correctly. The failure is
therefore in the **production discovery path**, not in the generator's ability
to emit the unit.

### Reproduce this in about a minute

Needs root (for `chroot`), plus `dracut-core`, `zstd`, `binutils`. On the lab
host it is a privileged pod; anywhere else a container is fine.

```bash
# 1. Get the signed UKI out of the image (any secure cayo/snow/snowfield build)
skopeo copy docker://ghcr.io/frostyard/cayo@sha256:8f19bad4… oci:img:
#    then extract boot/EFI/Linux/*.efi from the layer that carries it

# 2. Pull the initramfs out.  NOTE THE OUTPUT FILE -- objcopy rewrites its
#    input in place when you omit it, and strips the Authenticode signature.
cp uki.efi uki.work.efi
objcopy --dump-section .initrd=initrd.img uki.work.efi uki.copy

# 3. Unpack and run the initramfs's OWN generator
mkdir -p initrd && (cd initrd && lsinitrd --unpack ../initrd.img)
mkdir -p initrd/run/gen/{normal,early,late}
SYSTEMD_IN_INITRD=1 SYSTEMD_IN_CHROOT=0 \
SYSTEMD_PROC_CMDLINE='root=gpt-auto-force' SYSTEMD_VIRTUALIZATION=none \
  chroot initrd /usr/lib/systemd/system-generators/systemd-gpt-auto-generator \
    /run/gen/normal /run/gen/early /run/gen/late

find initrd/run/gen \( -type f -o -type l \)
```

**Caveat that matters:** `root=gpt-auto-force` forces `GPT_AUTO_ROOT_FORCE`,
which bypasses the production path (`is_efi_boot()` +
`efi_loader_get_device_part_uuid()`) and emits the unit without probing
hardware. It proves capability, **not** that production discovery works. That is
precisely the gap #517 lives in.

---

## Wrong turn: the missing unit template

Recording this so nobody repeats it.

I first observed that the image ships `system-systemd\x2dcryptsetup.slice` and
`usr/share/man/man8/systemd-cryptsetup@.service.8.gz` but **not**
`usr/lib/systemd/system/systemd-cryptsetup@.service`, and concluded the missing
template was the root cause. It is not.

**systemd v261's gpt-auto-generator writes complete unit files; it does not
instantiate a packaged template.** Confirmed in
`src/gpt-auto-generator/gpt-auto-generator.c` at tag `v261` — the cryptsetup
path calls `generator_open_unit_file(arg_dest_late, /* source= */ NULL, n, &f)`
and writes the whole unit. Forky's `systemd-cryptsetup` package therefore has no
reason to ship the template, and its absence is correct packaging, not an
anomaly. The generated unit above is the proof: it exists, complete, with no
template present anywhere.

Cost of that mistake: one wrong issue title, one nearly-landed workaround.

---

## Evidence that is NOT obtainable, and why

The single most useful artefact would be `/run/systemd/generator.late` from the
failed guest, plus `journalctl -b | grep gpt-auto`. Neither is reachable:

- the target drops to **emergency mode with the root account locked**, so there
  is no shell;
- `/run` is tmpfs, so it is gone on reset;
- the cmdline is baked into the **signed** UKI, so `rd.debug` or
  `systemd.log_level=debug` cannot be added without breaking the signature —
  which is the property under test.

**Practical route if that evidence is needed:** build a deliberately *unsigned*
UKI carrying the same initramfs plus debug kargs, and boot the installed disk
with Secure Boot disabled. The disk is unchanged; only the loader differs. The
lab can do this — ask and I will wire it up.

---

## How to get another run

Lane: `frostyard/lab`, `argo/workflow-templates/run-secure-install-tests.yaml`.

```bash
kubectl create -f argo/snosi-secure-install-test.yaml     # published ISO
```

Add `iso-path` to use a locally built ISO instead; the lane then prints
`*** This run is NOT evidence about published media.`

Artefacts persist on the lab host at `/var/lib/snosi-lab/secure/logs/`, outside
the cleanup trap:

| file | contents |
|---|---|
| `<workflow>.log` | full harness log |
| `<workflow>-serial.log` | guest serial console (the boot itself) |
| `<workflow>-esp.txt` | ESP listing, every `.efi` signature, UKI sections + cmdline, partition table, `blkid`, `luksDump` tokens |

If you need something else captured from the guest or the disk, the dump block
is in that template and I can add to it — a run takes ~25 minutes.

---

## RESOLVED — root cause confirmed

**systemd 261 moved the gpt-auto symlink rules out of `99-systemd.rules` (their
systemd 257 home, which dracut installs by name) into `90-image-dissect.rules`,
which dracut's rules list does not install.** Diagnosis by the agent working
#517; independently confirmed here against the real image and initramfs.

`usr/lib/udev/rules.d/90-image-dissect.rules` **in the image** carries exactly
the missing symlinks:

```
19: ENV{ID_PART_GPT_AUTO_ROOT}!="1", GOTO="gpt_auto_root_end"
21:   ENV{ID_FS_TYPE}!="crypto_LUKS", ENV{ID_FACTORY_RESET}!="on", SYMLINK+="gpt-auto-root"
23:   ENV{ID_FS_TYPE}=="crypto_LUKS", ENV{ID_FACTORY_RESET}!="on", SYMLINK+="gpt-auto-root-luks"
30: ENV{DM_UUID}=="CRYPT-*", ENV{DM_NAME}=="root", …            SYMLINK+="gpt-auto-root"
34: ENV{DEVTYPE}=="disk", ENV{ID_PART_GPT_AUTO_ROOT_DISK}=="1", IMPORT{builtin}="dissect_image probe"
```

Presence in the **initramfs** (38 rules files total):

| rules file | in initramfs? |
|---|---|
| `99-systemd.rules` — where these rules lived in systemd 257 | **yes** |
| `60-persistent-storage.rules` | yes |
| `60-persistent-storage-dm.rules` | yes |
| **`90-image-dissect.rules`** — where systemd 261 put them | **NO** |

`image-dissect` appears **zero** times in the image's dracut systemd module.

### Why this explains every observation

1. The generator runs and writes `systemd-cryptsetup@root.service` with
   `BindsTo=dev-gpt\x2dauto\x2droot\x2dluks.device` — confirmed, we ran it.
2. No udev rule in the initrd ever creates `/dev/gpt-auto-root-luks` (line 23 is
   the only thing that would, and it is absent).
3. The unit therefore never activates → `cryptsetup.target` completes trivially
   **with nothing beneath it**, exactly as the console shows.
4. No unlock → no `/dev/mapper/root` → line 30 never fires → `/dev/gpt-auto-root`
   never appears → `sysroot.mount` times out → emergency mode.

It also explains the earlier puzzle that `60-persistent-storage-dm.rules` only
`IMPORT{db}`s `ID_PART_GPT_AUTO_ROOT` and nothing in the initrd sets it: the
setter moved into the missing file too.

### Notes on the fix

Forcing `90-image-dissect.rules` into the initramfs is the right shape. Two
things worth confirming when it lands:

- The file uses `IMPORT{builtin}="dissect_image probe"` and
  `IMPORT{builtin}="factory_reset status"`. Those are udevd builtins, so they
  come with the 261 `systemd-udevd` already in the initrd — but worth asserting
  rather than assuming.
- Nothing in the image's udev rules *sets* `ID_PART_GPT_AUTO_ROOT` with `=`;
  it comes from the `dissect_image` builtin driven by lines 34–35 of the same
  file. Copying the whole file brings that chain with it. Copying only the
  symlink lines would not.

The decisive proof is a secure-install lane run reaching SSH rather than
emergency mode. Everything above is necessary but not sufficient evidence.

---

## Original open question (kept for history)

## Open question

**Why does the generator create the root mount but not detect the partition as
encrypted, under the production cmdline (`rw composefs=?<digest>`, no `root=`),
when `blkid` plainly reports `crypto_LUKS` on a partition with the correct root
DPS type GUID?**

Candidate classes I have *not* eliminated:

1. The generator's dissection takes a different path in auto mode than in force
   mode and never inspects the partition for LUKS.
2. `efi_loader_get_device_part_uuid()` succeeds but resolves to a disk on which
   the dissection then behaves differently than expected.
3. The generated cryptsetup unit *is* written but never activated, because its
   `BindsTo=dev-gpt\x2dauto\x2droot\x2dluks.device` never resolves — which would
   need a `/dev/gpt-auto-root-luks` symlink rule, and I could not find one in the
   initramfs (only the dm-gated `gpt-auto-root` rule).

### Class 3 is where I would start — with the caveat that I have been wrong here before

These are **verified facts** about the initramfs's udev rules:

```
$ grep -rn "ID_PART_GPT_AUTO_ROOT" usr/lib/udev/
60-persistent-storage-dm.rules:38:IMPORT{db}="ID_PART_GPT_AUTO_ROOT"
60-persistent-storage-dm.rules:46:ENV{ID_PART_ENTRY_SCHEME}=="gpt", ENV{ID_PART_GPT_AUTO_ROOT}=="1", SYMLINK+="gpt-auto-root"
99-systemd.rules:96:  … ENV{ID_PART_GPT_AUTO_ROOT_DISK_NEEDS_LOOP}=="1", …   ← a DIFFERENT variable

$ grep -rn "root.luks" usr/lib/udev/rules.d/
  NONE
```

That is: `60-persistent-storage.rules` (the non-dm file) **is** present, and

- **no rule anywhere in the initramfs creates a `/dev/gpt-auto-root-luks`
  symlink**, and
- **no rule anywhere in the initramfs *sets* `ID_PART_GPT_AUTO_ROOT`** — the dm
  rule only `IMPORT{db}`s it, i.e. reads a value something else was supposed to
  have stored.

The generated unit's `BindsTo=dev-gpt\x2dauto\x2droot\x2dluks.device` can only
resolve if that device node exists. If nothing creates it, a perfectly correct
unit sits unactivated, `cryptsetup.target` completes trivially with nothing
beneath it, and `/dev/gpt-auto-root` never appears — **which is exactly what the
console shows**.

**Do not treat that as the answer.** I do not know whether systemd creates that
symlink by another mechanism (a udev builtin, or `systemd-udevd`'s internal
handling rather than a rules file), and I have not checked upstream's full rule
set against what dracut installs. It is the first thing I would test, not a
conclusion — I already misdiagnosed this issue once by reasoning from an absent
file.
