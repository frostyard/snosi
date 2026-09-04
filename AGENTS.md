# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

snosi is a bootable container image build system using [mkosi](https://github.com/systemd/mkosi) to produce Debian Forky-based immutable OS images and system extensions (sysexts).

**Base release: Debian Forky (testing) since 2026-09** (`docs/adr/0014-move-base-release-to-forky.md`): `mkosi.conf` `Release=forky`, every profile and sysext builds from that one release, and NO mkosi config may pin a package to a suite by name (`pkg/forky`, `pkg/trixie-backports`, …) — `test/native-ab-static-test.sh` fails the tree if one appears, and `test/bootc-secure-static-test.sh` fails if the retired per-fragment forky APT sandbox returns. Testing's `base-files` ships no `VERSION_ID`, so `mkosi.images/base/mkosi.postinst.chroot` appends `VERSION_ID="14"` (Debian's number for forky) to `/usr/lib/os-release`; that single value drives the `_14_` in every published sysext filename (`sysext-postoutput.sh`), the `%w` in every sysupdate `.transfer` MatchPattern, and the `VERSION_ID` mkosi copies into each sysext's extension-release — installs still running a trixie image (`%w`=13) keep matching the `_13_` artifacts and never see forky-built sysexts, so the last trixie sysext set must stay published until those installs have taken a forky base. Two Frostyard-built debs still hard-depend on trixie's `libgpgme11t64` (forky ships `libgpgme45`): `libostree-1-1` (blocks the three OCI bootc profiles `cayo`/`snow`/`snowfield`) and `incus-base` (blocks the `incus` sysext, which also needs `libnet1` → forky's `libnet9`); both need rebuilds in frostyard/bootc-debian and the Frostyard incus packaging before those targets build again (proven 2026-09-04: base, gui-base, and every base-built sysext up to incus built; incus failed at apt on exactly that dependency). Docker publishes no forky suite, so `docker.sources` deliberately stays on `trixie` (static Go binaries; Depends verified against forky). Sunshine uses LizardByte's `ubuntu-26.04` deb because its sonames (libicu78, libminiupnpc21, glibc 2.43) are forky's. Never list a virtual package name that has more than one provider on forky: `libasound2` is provided by both `libasound2t64` and `liboss4-salsa-asound2` there, so apt reports "no installation candidate" (1password/edge now say `libasound2t64`); single-provider virtuals (`libgtk-3-0`, `libcurl4`, `qemu-kvm`) still resolve. `shared/kernel/backports` was folded into `shared/kernel/stock` (forky's own 7.1.12 kernel and mesa 26.1 are newer than trixie-backports had; `forky-backports` exists but is empty). The `/var` outcome maps changed too (python3.14; `log/{wtmp,lastlog,btmp}` and `log/README` no longer land at build time) — the audit fails closed in both directions, so a release bump is expected to surface there first. Images are deployed via bootc/systemd-boot with atomic updates.

**Outputs:** 2 OCI desktop images (snow, snowfield), 1 OCI server image (cayo), and 27 sysext overlay images (1password, 1password-cli, azurevpn, bitwarden, chatgpt, claude-desktop, code-server, coder, debdev, dev, docker, edge, github-copilot, incus, k3s, lemonade, localsend, moonlight, nix, obsidian, paseo, pilothouse, podman, sunshine, tailscale, voxtype, vscode).

## Build Commands

Requires: just, git, python3, root/sudo access. mkosi itself is auto-bootstrapped: the Justfile fetches systemd/mkosi into a repo-local, gitignored `.mkosi/` checkout at the exact commit pinned by the `systemd/mkosi@<sha>` action in `.github/workflows/build.yml` (read at runtime — no drift between local and CI), and runs `.mkosi/bin/mkosi` from there. Delete `.mkosi/` to discard it; override with `just mkosi=/usr/bin/mkosi <target>` to use a system install.

```bash
just                    # List targets
just sysexts            # Build base + all 27 sysexts
just snow               # Build snow desktop image
just snowfield          # Build snowfield (Surface kernel)
just cayo               # Build cayo server image
just clean              # Remove build artifacts
just test-install       # Run bootc install test
just run-qemu           # Run image in QEMU
```

All `just` targets run `mkosi clean` first (clean build every time).

**Optional bcvk testing:** bcvk is a local convenience for exercising the OCI
bootc images and does not replace `just test-install` or its CI workflow. OCI
profiles include `bubblewrap` because bcvk runs `bwrap` from the target image;
`virtiofsd` already ships in base. bcvk 0.18 requires an explicit host-side
`podman pull` before `bcvk libvirt run` (`--pull=never`). OCI bootc profiles
use `SecureBoot=no` and do not build or enroll the native A/B MOK signing
chain, so they do not currently boot under bcvk's enrolled-key Secure Boot
firmware. Use `--firmware uefi-insecure` only for bcvk install-mechanics
testing. Do not represent this as Secure Boot validation or change the
established bootc installation/testing path because of it.

**Bootc secure composition (Task 4, 2026-07-28):** `cayo`, `snow`, and
`snowfield` include `shared/bootc-secure/mkosi.conf`; native A/B profiles never
include it. The fragment lists its coherent systemd family explicitly (all
from the forky base since 2026-09; until then an isolated low-priority Forky
APT sandbox pinned it on top of Trixie), adds `lockdown=integrity` via
`/usr/lib/bootc/kargs.d/10-lockdown.toml` (the only effective immutable-karg
mechanism for the directory-format bootc profiles; do not use mkosi
`KernelCommandLine=` here), and ships only the existing native public MOK
certificate and RSA-2048 PCR public key at `/usr/lib/snosi/`. Its schema-1
`/usr/lib/snosi/bootc-secure.json` is the rootfs contract for later assembly
and installer tasks; schema 1 pins its encrypted root mapper as `root`, which
the reconciler and deferred installer must use. It is not a signed-UKI production path: do not add private
key material or claim Secure Boot support until Tasks 5 onward pass.
Task 8a extends schema 1's additive `installer` object with the exact installer
contract now consumed by Firn: pinned versions, 1 GiB ESP and 30
GiB online-install disk floors, immutable Cosign acceptance, DPS LUKS2/Btrfs,
Type #2-only bootc options, MOK/TPM/recovery policy, provenance, restage, and
ESP repair. `/usr/lib/snosi/bootc-secure.json` is the machine-readable
installer contract; `docs/bootc-secure-install-contract.md` retains the retired
Task 9 adapter protocol for compatibility and fixture history.
Frostyard's bootc/libostree debs are built for trixie and are a deliberate
cross-suite compatibility risk, not an inferred package guarantee. Task 4
validated one real cayo build with bootc 1.16.3, libostree 2026.2, and systemd
261.1-3, then ran `bootc --version` and `bootc container --help` in a bwrap
root containing only that output. Repeat that build/root check when either the
Frostyard debs or the base release changes — on the forky base the current
`libostree-1-1` deb is unresolvable (`libgpgme11t64`), so that check is the
first gate for the rebuilt debs.
**Issue 517 (2026-08-06) — Forky udev moved the gpt-auto symlink rules out of
dracut's reach:** systemd 257 shipped the udev rules creating
`/dev/gpt-auto-root[-luks]` in `99-systemd.rules` (which dracut installs by
name); systemd 261 moved them into `90-image-dissect.rules`, which dracut
106's hardcoded rules list does not install. The initrd's
`systemd-gpt-auto-generator` still unconditionally writes
`systemd-cryptsetup@root.service` bound to `/dev/gpt-auto-root-luks` (the
generator does not probe the disk; udev's blkid builtin sets
`ID_PART_GPT_AUTO_ROOT` and the rules create the symlink), so the unit sits
unactivated, `cryptsetup.target` completes empty, `sysroot.mount` times out
on `dev-gpt-auto-root.device`, and every secure bootc install drops to
emergency mode. Fixed by
`shared/bootc-secure/tree/usr/lib/dracut/dracut.conf.d/35-gpt-auto-udev-rules.conf`
(`install_items+=" /usr/lib/udev/rules.d/90-image-dissect.rules "`; the file
is shipped by `udev/forky`). `test/bootc-secure-artifact-test.sh`'s
initramfs validation now fails any UKI whose unpacked initramfs has no udev
rule creating `gpt-auto-root-luks`, and `test/bootc-secure-static-test.sh`
pins the drop-in. Native A/B profiles are unaffected (verity root via UKI
`roothash=`, explicit `systemd-cryptsetup attach` for `var` — no gpt-auto
dependency). Upstream dracut-ng (as of 2026-08) still lacked
`90-image-dissect.rules` in `01systemd-udevd`; forky's dracut 112
(`11systemd-udevd`, checked 2026-09-04) lists it natively, so on the forky
base the drop-in is redundant but kept — the artifact test, not the dracut
version, is the proof. dracut 112 also renamed `01systemd-pcrphase` to
`11systemd-pcrextend` (the base/cayo/snow `20-tpm-luks.conf` drop-ins name
the new module) and systemd 261 moved `systemd-pcrextend` into
`systemd-tpm`, which base now installs explicitly; without both, every
dracut run fails with `Module 'systemd-pcrphase' cannot be found`.

**Bootc UKI assembly (Task 5, 2026-07-28):**
`shared/bootc-secure/assemble-uki.sh` and the secure branch of
`shared/outformat/image/buildah-package.sh` formalize the observed bootc 1.16.8
hidden storage-digest plus direct two-pass ukify behavior as a maintained,
fail-closed compatibility contract. This is NOT upstream-stable. Secure builds
must set `SNOSI_BOOTC_SECURE=1` and caller-owned MOK/PCR credentials; Buildah
packages and chunks a pristine first pass, then obtains its storage composefs
ID from that chunked candidate image. It first places the MOK-signed
systemd-boot source at `/usr/lib/snosi/bootc/systemd-bootx64.efi`, constructs
the UKI and ESP copy below `/boot`, and derives the final image from the
chunked candidate with that `/boot` tree as its only filesystem overlay. The
final candidate's bootc performs the second of exactly two digest probes and
must retain the ID; protected builds never chunk after assembly. It emits the explicit
`io.snosi.bootc.secureboot-capable=true` label; non-secure builds emit `false`.
Before first-pass packaging, the root packager temporarily bind-mounts only host
`/proc` into the complete mkosi rootfs and runs the exact bootc version probe
through chroot, so target libraries rather than the CI host ABI resolve. It
refuses pre-mounted/missing rootfs proc paths and unmounts before any image
mutation. Storage-digest authority remains bootc inside the candidate OCI image.
Direct ukify executes as `/usr/bin/ukify` inside the chunked first-pass
candidate with network disabled, individual read-only credential mounts, and a
public-only writable work mount. Protected run 30579247524 reached this point
but cayo job 90995134482 failed because the unprivileged candidate could not
read its mode-restricted in-image initramfs; no validation, push, signing, or
promotion ran. Before execution, the assembler canonicalizes the discovered
in-root kernel/initrd paths, copies their bytes to mode-0644 `linux`/`initrd`
work inputs, and passes only those fixed work paths to ukify. It compares both
work inputs against the canonical protected rootfs originals after execution,
then compares final UKI sections against those same originals. The candidate
supplies pinned systemd-ukify 261.1-3 and its dependencies; no host ukify is
accepted. The disposable container and mounts never enter a layer. Host
`.linux`/`.initrd` byte checks remain valid because first-pass packaging is a
byte-identical `cp -a` snapshot.
Candidate execution drops all Linux capabilities and runs as the common numeric
owner of its mode-0600 credential files; it never adds read-bypass capabilities.
Every storage-digest probe runs through the ONE shared helper
`shared/bootc-secure/storage-digest-probe.sh` (`snosi_storage_composefs_digest`,
sourced by `buildah-package.sh`, `assemble-uki.sh`, and
`test/bootc-secure-spike-test.sh`); never re-inline the `podman run` shape. The
helper binds a host scratch dir over the container's `/var/tmp` because bootc
1.16.8 hardcodes its temp composefs repo there (`TMPDIR` ignored) and composefs
object writes use `O_TMPFILE`, which fuse-overlayfs lacks — GitHub runner image
ubuntu24/20260810.271 (podman 5.8.4) forces `mount_program = fuse-overlayfs`,
which broke every secure "Package image" step with `os error 95` (root-caused
2026-08-13; jobs landing on the older 20260720.247 image passed, making the
failure look profile-dependent when it was a runner-image lottery). The bind
cannot affect the digest: it is computed from containers-storage content, not
the probe container's rootfs.
The active and optional
previous PCR public identities remain in the unmounted assembler gate directory;
only copies enter the writable work mount and must compare byte-for-byte with
the protected identities after execution.
The optional dual-PCR mode requires the previous certificate positionally and
its matching private key only through `SNOSI_BOOTC_PREVIOUS_PCR_KEY`. Never
copy private keys into the rootfs, OCI layers, labels, logs, or retained temp
state. Task 5 derives fingerprints only from those exact caller-owned private
keys and rejects matches in the rootfs, mounted OCI filesystem/config, sanitized
ukify log, and scan state; it deliberately permits unrelated package/example
keys and does not use documentation/MIME exclusions. Re-run Tasks 1-3 and Task 5 artifact/negative validation before changing
bootc/libostree, ukify/systemd, chunkah, Buildah derivation, the `/boot`
exclusion, or any observed command/output shape. See
`docs/bootc-secure-assembly-compatibility.md`.

**Bootc shim second-stage reconciliation (Task 7, 2026-07-28):** secure OCI
assembly retains the MOK-signed systemd-boot at
`/usr/lib/snosi/bootc/systemd-bootx64.efi` because an installed ESP can shadow
`/boot`. `snosi-bootc-bootloader-reconcile.service` is active only through its
static `/usr/lib/systemd/system/multi-user.target.wants/` link, has no
`[Install]` section, and never writes enablement under `/etc`. It derives
exactly one ESP beside the booted encrypted-root backing partition; it mounts
only an unmounted ESP, and refuses an already-mounted read-only ESP without
remounting or writing it. It MOK-verifies the immutable source and a same-filesystem
temporary copy, syncs, and atomically replaces only `EFI/BOOT/grubx64.efi`.
The prior second stage is restored byte-for-byte if post-replacement sync fails.
Shim `BOOTX64.EFI` and MokManager `mmx64.efi` are never modified. Reconciliation
intentionally permits rollback: the authenticated deployment currently booted,
not a monotonic version, selects the replacement.
The real cayo proof validates immutable-source assembly, OCI retention, and
signature binding only; executing this reconciler against an installed FAT ESP
is deferred to the Task 9 secure-install runtime harness.

**Secure bootc installation ownership (core ADR-0031, 2026-08-12):**
Firn is the sole supported secure bootc installer. Its enforced-Secure-Boot E2E
and the lab `run-firn-install-tests` matrix own fresh-install proof for cayo,
snow, and snowfield. Never restore or pin the retired Dakota/Fisherman Task 9
adapter lane. `test/bootc-secure-install-test.sh --fixtures` remains
always-runnable, fail-closed coverage of image invariants and the frozen legacy
adapter contract; it is not current installer E2E evidence. Installed-image
update, recovery, rotation, and bootloader reconciliation remain Snosi-owned
responsibilities and require a Firn-native lifecycle lane. Snowfield retains
the separate representative Surface hardware gate.

**Assertions shared by the install and update harnesses live in exactly ONE
place: `test/lib/bootc-secure-assertions.sh`** (`esp_cat`,
`composefs_from_cmdline`, `type2_only`, `signed_pcr11_token`,
`root_backing_device`). Neither harness may re-define them;
`test/bootc-secure-static-test.sh` fails the build if either does. Independent
copies drift silently and the drift is load-bearing — three of four had
diverged, and `type2_only` had come to accept only `efi` while bootc writes
`uki`, so the update leg could not pass on any composefs install while the
install harness asserted the same property and passed. Two facts these
assertions encode are easy to get wrong from first principles and must not be
"simplified" back: bootc leaves `/boot` UNMOUNTED unless it is using it, so BLS
entries are read off the ESP located by GPT type GUID, never from
`/boot/loader/entries`; and on a composefs deployment `/` is an overlay, so the
root filesystem is probed on `/dev/mapper/root`, never with `findmnt /`.

This is the sixth defect in this subsystem caused by a fix landing in one of
two sibling paths (`ssh_key`/`ssh_private_key`, `uki`/`efi` in the recovery
runner, `findmnt /` vs the composefs mapper, NvPCR masked on native but not
bootc, the nightly's stale copy of the KVM step, and this). When a fix applies
to a behaviour that exists twice, move the behaviour rather than copying the
fix.

**Task 9 secure update harness (2026-07-29):**
`test/bootc-secure-update-test.sh --fixtures` validates the mode-0600,
path-only install handoff and marked external update protocol. Live mode
requires immutable N+1/N+2 refs with distinct 14-digit image versions, an
atomic publisher for the same tracking tag,
and a causal negative runner; it runs the production updater for first switch
and steady-state upgrade, then asserts every secure runtime and persistence
invariant across updates and rollback. The former Dakota-produced install
handoff is retired; live evidence now requires a Snosi-owned Firn-native
lifecycle lane plus authorized secure artifacts. Snowfield still needs the
representative Surface hardware gate.
The retained handoff's TPM state/socket paths are reused exactly; all Task 9
LUKS checks derive the single backing `/dev` device from `cryptsetup status
root`, and guest MOK verification uses the immutable guest certificate plus a
public fingerprint comparison rather than a host certificate path.

**Task 10 CI and evidence status (2026-07-29):** `build-images.yml` PR
`mechanics-build` is secretless, non-publishing, and can produce only
`io.snosi.bootc.secureboot-capable=false` mechanics images. Protected
`secure-build` is the sole OCI publisher: it uses the four `NATIVE_*` secrets
only around local assembly/validation, requires the supplied public MOK/PCR
identities to byte-match `shared/native-ab/keys/mok-2026.crt` and
`shared/native-ab/keys/pcr-signing-2026.pub`, deletes credentials before any
registry write, validates an immutable version digest, then moves `latest`.
The protected package step forwards the secure flag and credential paths as
explicit sudo command assignments; GitHub step environment values do not cross
sudo implicitly, and secret bytes remain only in the mode-0600 files.
Every GHCR read and write in secure verification and promotion receives the
Docker login config explicitly: inspections use `--authfile`, root policy copy
uses source-only `--src-authfile`, and promotion uses source and destination
auth files. The run-scoped `GITHUB_TOKEN` is the only GHCR credential:
`secure-build` grants `packages: write`, while `release` grants only
`packages: read`; Buildah and ORAS receive it through stdin. Shell `run:`
steps expose `github.actor` only through the quoted `GHCR_USER` environment
variable; never interpolate GitHub context values directly into shell source.
The successful
three-profile mechanics publication run `31150007630` proves repository-token
write access to the same cayo, snow, and snowfield packages, so a long-lived
GHCR PAT is neither required nor permitted. Pinned Cosign v2.6.1 receives
registry auth through command-scoped
`DOCKER_CONFIG`; it has no registry-config flag. Version-tag resolution must
equal the pushed digest before policy copy. The verifier never relies on sudo
preserving a usable user runtime auth path or on root Buildah's credential-store
defaults.
Local and policy-copied artifact validation use host Podman to execute the
candidate image's pinned bootc; they do not require or accept an independently
installed host bootc as the storage-digest authority.
A failed candidate never moves `latest`. `native-build` must be restricted in
GitHub settings to protected/default branches; native PRs use disposable
RSA-4096 MOK and RSA-2048 PCR credentials and cannot publish. Fixture/static contracts and candidate scaffolding are complete, but they are
not live lifecycle evidence. Firn owns fresh-install proof; update, recovery,
rotation, bootloader-reconciliation, and Snowfield hardware validation remain
unproven until authorized signed secure artifacts and the appropriate
Firn-native or hardware lanes exist. Do not claim production bootc Secure Boot
support from these contracts.
Deferred publication follow-ups: bind SBOM signing to the exact uploaded
referrer digest, gate Snow release creation on complete metadata publication,
decide whether `latest` moves only after metadata completion, and make general
output cleanup unconditional where retained runners require it.

**Bootc secure operations (Task 11, 2026-07-29):**
`docs/bootc-secure-operations.md` is the normative reference for the secure
fresh-install support boundary, recovery credential custody, MOK/TPM/ESP
recovery, rotation, incident response, and evidence retention. It links to the
installer and assembly contracts rather than replacing them. Operations and
documentation contracts are complete; live release evidence remains BLOCKED.

**Persistent custom kernel arguments (`snosi-kargs`, issue 601, 2026-08-08):**
secure bootc and production native A/B profiles ship systemd 261's addon stub,
`systemd-ukify`, `sbsigntool`, and OpenSSL. The base
`usr/bin/snosi-kargs` CLI stores state and optional machine-local signing
material under `/var/lib/snosi/kargs/`, builds an addon by invoking `ukify
build` WITHOUT `--linux`, and atomically installs the verified artifact at
`<ESP>/loader/addons/50-snosi-cmdline-local.addon.efi`. This is a GLOBAL addon:
arguments append after the embedded UKI command line, apply to every UKI, and
measure into PCR 12; they never remove embedded arguments and do not enter the
signed-PCR-11 LUKS policy. Keep the root/verity/LUKS/emergency refusal list and
typed `--force` confirmation fail-closed. `--unsigned` is permitted only when
`mokutil` reports Secure Boot disabled. A generated local key is mode 0600 and
requires explicit MOK enrollment; docs must retain the warning that a
disk-resident MOK key widens boot trust and may widen module trust depending on
the kernel/shim MOK policy. Offline `--key`/`--cert` signing remains supported.
`usr/lib/snosi/esp.sh` is the shared ESP authority for this CLI and the bootc
second-stage reconciler: `bootctl --print-esp-path` first, then the encrypted
root's single colocated ESP, never remounting an existing read-only mount.
`test/snosi-kargs-test.sh` covers the fixture/security matrix.
`test/native-ab-secure-boot-test.sh` now requires signed load, PCR 11
stability/PCR 12 change, TPM unlock, corrupt-signature fail-open, and native
sysupdate survival. Bootc update persistence is still `BLOCKED:` pending a
Firn-native Snosi lifecycle lane and authorized artifacts; it must not be
claimed from fixture or native evidence. User and recovery guidance lives in
`docs/snosi-kargs.md`.

**Bootc OCI signature policy (Task 6, 2026-07-28):** secure bootc profiles ship
`/etc/containers/policy.json` with global `reject` and exact
`sigstoreSigned` scopes only for `ghcr.io/frostyard/cayo`, `snow`, and
`snowfield`; each uses the committed public-only `cosign.pub` copied to
`/usr/lib/snosi/cosign.pub`. Cosign v2.6.1 signatures record repository rather
than tag identities, so this MUST use `signedIdentity: matchRepository` and
the GHCR `registries.d` entry MUST retain `use-sigstore-attachments: true`.
LOCAL transports are accepted with `insecureAcceptAnything`: `containers-storage`
(so bootc consumes the image Podman's signed `docker` pull already accepted),
plus `tarball`, `docker-archive`, `oci-archive`, `dir`, and `oci` so an operator
can do ordinary image work on an installed system — `podman load`, `podman
import`, OCI layouts. Those bytes are already on the machine and under the
operator's control; the boundary this policy exists to enforce is the REGISTRY
one. Blocking them was also inconsistent rather than strict: `podman build`
FROM scratch consults no transport at all, so arbitrary local images were always
constructible — the prohibition cost usability and bought nothing.

**Do not broaden `docker`** to a namespace or global acceptance, and do not
change `default` from `reject`. That is the half that matters, and
`test/bootc-container-policy-test.sh` fails if either moves: it requires every
`docker` scope to stay `sigstoreSigned`, forbids a catch-all `docker` scope, and
pins the default to `reject`. Verified against the real policy that an unsigned
`docker.io` pull and an unsigned `ghcr.io/frostyard/cayo` pull are both still
refused while `podman import` succeeds. Secure install
paths must not use `--skip-fetch-check`. Local rootfs test fixtures use their
own disposable permissive policy only; registry paths use a disposable HOME
containing the restrictive policy so host configuration is never changed.
`bootc-update-stage` must retain Podman's containers-storage transfer and its
staged storage-digest check; a failed pull, including policy rejection, clears
`/run/snosi/update-staged` and leaves the existing EXIT trap to record
`outcome=failed`. Run `test/bootc-container-policy-test.sh`; set `RUN_LIVE=1`
(and optionally `LIVE_IMAGES=cayo,snow,snowfield`) to verify published
signatures, wrong key, unsigned, and wrong-repository rejection through Podman.

**Bootc sealed-UKI feasibility gate (Tasks 1-2, 2026-07-28):**
`test/bootc-secure-spike-test.sh --fixtures` is the non-root fixture layer for
MOK/PCR validation, single-kernel discovery, pre-existing-UKI refusal, and the
expected `/boot/EFI/Linux/<kernel>.efi` output path. Its default mode is a hard,
fail-closed rootfs proof: it requires `output/cayo`, `bootc`, `ukify`,
`sbverify`, Buildah, and disposable `BOOTC_SECURE_MOK_KEY`,
`BOOTC_SECURE_MOK_CERT`, and `BOOTC_SECURE_PCR_KEY` inputs. If any is absent it
prints `BLOCKED:` and exits 2, never a false security PASS. The PR/push
bootc-secure contract jobs run this fixture mode, the root-only
`test/task2-recovery-key-bytes-test.sh` disposable-LUKS regression after
installing `cryptsetup`, and `test/task3-console-pump-test.py`. They never run
the default live QEMU/OVMF/swtpm feasibility proof. Source inspection
of pinned bootc 1.16.3 identifies `bootc container ukify --rootfs ROOT --
<ukify-options>` as the interface that computes the composefs SHA-512 ID and
forwards trailing options to ukify; the live pinned-stack rootfs proof observed
that interface. The gate
independently recomputes that ID with `bootc container compute-composefs-digest`,
builds the UKI before copying it below `/boot/EFI/Linux`, and requires the
copied UKI's `.cmdline` `composefs=` value, `.linux`/`.initrd`, `.pcrpkey`,
`.pcrsig`, and MOK signature to validate both before and after
`shared/outformat/image/buildah-package.sh`. This is a feasibility harness, not
the production assembly path (Task 5); do not describe the secure bootc path as
proven until the default rootfs proof completes. Live pinned-stack evidence
shows its directory-rootfs invocation with `--allow-missing-verity` emits
`composefs=?<128-hex-digest>`: composefs-rs uses the leading `?` as the
insecure/missing-fsverity marker. The gate strips that marker only to compare
the digest; this feasibility build does not prove production fs-verity
enforcement.
The `.linux` and `.initrd` comparisons are exact byte comparisons; any mismatch
is fail-closed and an investigation gate, not a condition to normalize away.
Task 2 extends the same harness with 19 fixture assertions and a live external
installer route: it creates a 1 GiB ESP and x86-64 DPS root GPT partition,
formats LUKS2/Btrfs with a disposable recovery key, and invokes `bootc install
to-filesystem --composefs-backend --bootloader systemd --root-mount-spec ""`
without `--karg`. The pinned 1.16.3 source accepts the empty mount specification
as the signal to omit root kernel arguments and requires no CLI kargs for a
Type #2 UKI. Directory-rootfs digest `03a...` differs from the OCI-reconstructed
deployment digest `97dcc...` because OCI reconstruction normalizes metadata, so
Task 2 packages a pristine first-pass OCI image, calls hidden `bootc container
compute-composefs-digest-from-storage`, directly invokes ukify with
`composefs=?<OCI-digest>`, injects the signed UKI only under `/boot/EFI/Linux`,
then packages and recomputes the final image. The observed first/final/installed
IDs are exactly `97dcccf026688eddbe0d4503a9528ef35b31ce15144b5aed3ab6f662b2997e0471e34a66642e1d1aeeb5d1621a0ce6ad5632e07fae9aa13d1a10ea610538afbb`.
The live install verifies Type #2-only BLS metadata and the copied UKI's exact
kernel/initrd/PCR/MOK binding. This proves feasibility only: the hidden digest
command and direct ukify duplication are not production-stable interfaces. Task
5 remains gated on a supported pinned upstream/bootc-debian assembly interface
or an explicit maintained compatibility contract; do not move this logic into
installer shell code. Both the storage digest probe and `to-filesystem` run the
bootc binary in the temporary cayo OCI image (observed 1.16.3), not the host
binary. Current bootc writes a BLS `efi=` entry pointing at
`EFI/Linux/bootc/bootc_composefs-<id>.efi`; the fixture and live validator pin
that observed feasibility shape and reject raw `linux`/`initrd` BLS entries.
Task 2 never boots its disk; Task 3 owns the boot proof. The external-layout
cleanup uses a per-process mapper and recursively unmounts only its recorded
target before closing that mapper and detaching that loop device, with bounded
retries so an unrelated host loop is never touched.
Task 3's live secure-OVMF run observes DPS discovery and a
`systemd-cryptsetup@root` recovery prompt without root/LUKS kernel arguments.
Its socket pump now sends the disposable key after serial quiet, proven by a
socket fixture and the live `[task3: typed recovery passphrase]` marker. The
following cryptsetup rejection is BLOCKED: Task 2's `--key-file` input includes
a trailing newline while the interactive path strips it. Do not alter kargs or
storage until a focused key-byte proof establishes the recovery contract.
That focused proof now passes after Task 2 switched its recovery producer to
`printf '%s'`: the live gate reaches `/dev/mapper/root`, mounts Btrfs, completes
`bootc-root-setup`, and switch-roots. It then BLOCKS later because real-root PID
1 cannot populate `/etc` during first boot (`Read-only file system`), followed
by failed TPM setup/drift-report/logind units and no SSH. This is a distinct
post-switch-root investigation; do not change `/etc` or services in this gate.
The next `rw`-only cmdline proof passes real-root first boot and reaches SSH;
the direct ukify command now carries exactly `rw composefs=?<OCI-digest>` and
fixture-rejects root/LUKS identifiers. Task 3 now has a fail-closed temporary
ESP assertion: it derives the backing disk from the booted root LUKS partition,
requires exactly one sibling EFI System Partition, mounts it read-only at
`/run/task3-esp`, and runs `bootctl --esp-path=/run/task3-esp --no-pager
status`, requiring Secure Boot, Measured UKI, and the installed Type #2 path.
Zero or multiple ESP candidates fail fixture coverage; the guest cleanup trap
unmounts the temporary mount. It does not add an fstab entry, boot mount spec,
kernel argument, or persistent mount policy. The apparent post-readiness SSH
failure was actually `bootctl status` returning nonzero after printing complete
valid status because optional EFI-variable state was absent; the harness now
ignores only that informational exit status and still fail-closes on the
required text. The live gate passes the ESP assertion, requires exactly one
signed-PCR-11 TPM token, creates the recovery file mode 0600, and shreds the
guest enrollment credentials before reboot. It records the current kernel boot
ID and requires a different boot ID after reboot so the old sshd cannot produce
a false unattended-boot pass. The second boot reaches SSH with no
additional serial key input, TPM-unlocks the encrypted DPS root, and the
original recovery key still passes `cryptsetup open --test-passphrase`. Task 3
is therefore a complete feasibility PASS. This does not remove Task 5's
supported-interface gate or make the direct hidden-command/two-pass assembly
production-ready.

## Architecture

### Configuration Composition

mkosi configs use `Include=` directives to compose reusable fragments. The composition chain:

- `mkosi.conf` (root) declares base + sysext dependencies
- `mkosi.images/` contains base image and sysext definitions
- `mkosi.profiles/` defines transport+kernel selector variants (snow, snowfield, cayo — the app-bundling "loaded" variants were retired 2026-07 in favor of sysexts; cayo-ab-raw is the permanent, never-published native A/B dev fixture, and cayo-ab/snow-ab/snowfield-ab are the production native A/B profiles, see below)
- `shared/` contains reusable fragments: kernel configs, package sets, output format, scripts, and `shared/composition/` (per-product payload fragments, see below)

Each profile composes: package sets + kernel variant + output format + build/postinstall/finalize/postoutput scripts.

**Payload composition (`shared/composition/`):** `shared/composition/cayo/mkosi.conf` and `shared/composition/snow/mkosi.conf` are the single per-product definitions of ExtraTrees, PostInstallationScripts (dracut postinst, then the product postinst.chroot), BuildScripts (brew, plus snow's hotedge/logomenu/bazaar/surface-cert), the manifest PostOutputScript, the image FinalizeScript, and an `[Include]` of the product's package set. Every profile that ships that product's payload — bootc (`cayo`/`snow`/`snowfield`) and native (`cayo-ab-raw`, `cayo-ab`, `snow-ab`, `snowfield-ab`) alike — `Include=`s the fragment instead of restating it, so the two transports cannot drift apart. Profiles themselves reduce to transport+kernel selectors: bootc profiles add `Include=shared/packages/bootc/mkosi.conf` (before the composition include, so `Packages=` accumulates in the same order as before the refactor) and `Include=shared/outformat/image/mkosi.conf`; native profiles never include the bootc packages fragment and instead include `shared/outformat/ab-root/mkosi.conf`. The three production native profiles (`cayo-ab`, `snow-ab`, `snowfield-ab`) reduce to `[Config]`/`[Output]`/`[Include]` only (Phase 3) — every setting, including the secure posture, lives in `[Include]`d fragments: `Include=%D/shared/native-ab-secure/mkosi.conf` is listed FIRST, before the composition include, so its `FinalizeScripts=disable-nvpcr.chroot` resolves before the composition fragment's image finalize (mkosi accumulates list settings in `Include=` encounter order across the whole resolved config) — the resolved FinalizeScripts order stays disable-nvpcr -> image finalize -> var-audit.finalize -> ab-root finalize, verified via `mkosi --profile <p> summary`.

**Plymouth splash + Snow theme (2026-07-17):** all snow/snowfield images ship a Snow-branded plymouth theme in `shared/snow/tree` (two-step `snow.plymouth` with bgrt-style cross-theme `ImageDir=` reusing Debian's spinner assets; the flower `watermark.png` injected into the spinner dir — the deb-unowned path two-step loads watermarks from; `Theme=snow` in `etc/plymouth/plymouthd.conf`). Ship the conffile via ExtraTrees ONLY — a SkeletonTrees copy of a dpkg conffile makes dpkg prompt at install and the build dies at EOF on non-interactive stdin (proven live). The theme reaches initrds because the FINAL initrd is generated by the dracut PostInstallationScript, which runs after ExtraTrees. Making the splash actually RENDER on native A/B took four stacked root-caused mechanisms (bootc needs none of this — bootc injects `rhgb quiet` and has no serial console): (1) `KernelCommandLine=splash plymouth.ignore-serial-consoles` in `shared/composition/snow` — a configured serial console (`console=ttyS0`, from the ab-root fragment) otherwise makes plymouthd force details mode globally and skip DRM probing entirely; (2) native initrds omit the plymouth dracut module (`omit_dracutmodules` in the ab-root `30-bootc-standard.conf` override; cayo no-op) — initrd plymouth loses a premature-udev-change-event race against DRM device creation (Debian's kernel has no simpledrm) and falls back to text splash permanently; the real root's statically-wanted `plymouth-start.service` starts after DRM is up and shows the graphical theme deterministically; (3) desktop channels (`shared/native-ab/channels/{snow,snowfield}`) append `KernelCommandLine=console=tty0` — the channel is the only desktop fragment included AFTER ab-root, so tty0 lands last and wins `/dev/console`; with a serial `/dev/console`, plymouthd's local terminal is NULL and the un-backported upstream segfault (LP#2103533; fixed in plymouth 26.134.222, absent from all Debian suites incl. sid) kills it — the same bug also fires on ANY multi-GPU VM (QEMU default VGA + virtio = 2 GPUs; always pass `-vga none` in test VMs). (4) `plymouth-start.service.d/10-wait-drm.conf` (snow tree) holds plymouthd behind a second bounded `udevadm wait /dev/fb0` **console-handoff barrier** on top of the `/dev/dri/card0` DRM one: card0 appears before the kernel rebinds the VT layer from the dummy console to fbcon (`Console: switching to colour frame buffer device`, printed just before `fb0: <drv>drmfb`), and plymouthd started inside that window dies with SIGSEGV in the same unguarded 24.004.60 terminal path. This is snow-only and kernel-config-derived — Debian's generic `linux-image-amd64` (7.1.8 on trixie-backports, forky's 7.1.12-1 alike per `linux-config-7.1`) has `CONFIG_FRAMEBUFFER_CONSOLE=y` WITHOUT `CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER`, so fbcon binds the moment virtio_gpu's fbdev registers (measured t+4.95s, inside plymouth-start's 4.69–5.44s window, ~40ms after card0), while `linux-image-surface` (6.19.8) sets `DEFERRED_TAKEOVER=y` and never binds fbcon during boot, and cayo installs no plymouth at all. Symptom when it loses the race: `plymouth-start.service` `signal=SEGV` → `degraded` → `test-public-origin`'s boot smoke gate fails → `promote-snow` skips (main runs 33230153367, 33465852243; issue #850). PR builds never run that gate. Because `console=tty0` moves `systemd-ask-password-console`'s LUKS prompt off serial, `snosi-ask-password-serial.{service,path}` (ab-root tree, static sysinit wants, `install_items` into the native initrd) runs `systemd-tty-ask-password-agent --watch --console=/dev/ttyS0`, Condition-gated to desktop natives — this is what the QEMU harnesses' console pump now types the first-boot recovery passphrase into (raw-agent prompt shape, already matched). Validated: 71/71 secure-boot harness (snow-ab), QMP-screendump visual proof (flower at ~14s, GDM at 30s, no crash), bootc snow artifact check. Servers stay text: no splash karg reaches cayo (static-test-enforced). Kernel messages are now visible on the hardware screen pre-splash (no `quiet`) — deliberate open follow-up, not an accident.

**mkosi Include ordering matters for list settings:** mkosi accumulates list-valued settings (`Packages=`, `FinalizeScripts=`, `BuildScripts=`, etc.) across the whole resolved config in the order each `Include=` is textually encountered (recursing into included files at that point), not grouped by which file declared them. When refactoring composition, the arbiter is a byte-level diff of `mkosi cat-config`/`summary` output before and after — not a read of the source files. Two gotchas hit doing this: (1) `History=yes` (base `mkosi.conf`) caches the last-used `--profile` in `.mkosi-private/history/latest.json` (root-owned) and silently overrides `--profile` on every later invocation of read-only verbs like `cat-config` (prints "Ignoring --profile from the CLI"); `summary` has an explicit bypass for `-f`, but `cat-config` does not — `sudo rm -f .mkosi-private/history/latest.json` before capturing config snapshots. (2) `summary` output has three fields that are non-deterministic per invocation and must be normalized out of any diff: `Seed:` (fresh random UUID per run), `Prepare Scripts: /tmp/tmpXXXXXXXX/...mkosi-tools/mkosi.prepare` (random tools-tree extraction tmpdir), and `Image Version:` (defaults to the current wall-clock timestamp when unset) — none are derived from config content.

Root `mkosi.conf` depends on `base` plus all sysexts so `mkosi build`/`just sysexts` produces the sysext publishing set. Profile configs must start with an empty `Dependencies=` assignment followed by `Dependencies=base`; mkosi appends collection settings, so the empty assignment is required to avoid rebuilding every sysext for each profile image build.

### Script Pipeline (per image)

Scripts execute in order: **BuildScripts** (in chroot) -> **PostInstallationScripts** (after packages) -> **FinalizeScripts** (pre-output) -> **PostOutputScripts** (after image creation).

### Immutable Filesystem Constraints

- `/usr/` - Read-only. All binaries and libraries must live here.
- `/etc/` - Overlay on `/usr/etc`. Base configs in image, user changes persist.
- `/var/` - Persistent, writable. State, logs, container storage.
- `/opt/` - Bind mount to `/var/opt`. Writable at runtime but **shadowed by sysext overlays**.

**Critical pattern:** Packages installing to `/opt` must be relocated to `/usr/lib/<package>` at build time with symlinks in `/usr/bin`. This applies to both desktop images and sysexts.

**Runtime service enablement changes are forbidden:** units must never run `systemctl disable`/`enable` at runtime (e.g. via `ExecStartPost`) — it deletes/creates `.wants`/`.requires` symlinks in `/etc`, and any path removed from the live `/etc` relative to the booted image makes bootc's `/etc` merge fail at update finalize with "a path led outside of the filesystem" (bootc ≤ 1.16.3 follows the corresponding symlink in the new deployment's `/etc` out of its sandbox). The failure is silent from the user's perspective: `bootc-update-stage` keeps logging "staged" while every reboot discards the staged deployment and boots the old image (root-caused 2026-07-05 on `enable-incus-agent.service`). For run-once behavior, gate on a `/var` marker file instead (see `snow-linux-live-setup.service`). CI enforces this: `check-runtime-etc-guard.sh` (run by `validate.yml`) fails on runtime `systemctl disable/enable`, `/etc` deletions, and tmpfiles removal types on `/etc` in any shipped payload dir (`mkosi.extra/`, `shared/*/tree/`); escape hatch is a trailing `# etc-guard-allow: <reason>` comment.

**First-boot semantics:** the image ships `/etc/machine-id` containing the literal `uninitialized` (the machine-id(5) golden-image value), so the first boot of every install is a TRUE systemd first boot: `ConditionFirstBoot=yes` fires, PID 1 applies system unit presets, `preset-global.service` applies user-scope presets, and a unique machine ID is then generated and committed. (Before 2026-07 the image shipped an *empty* machine-id, which only means "generate an ID" and silently suppressed all first-boot semantics — the finalize comment claimed the opposite.) `systemd-firstboot.service` is preset-disabled so nothing prompts on the console; the installer and first-setup own locale/hostname/user. The `sshd-keygen.service.d` drop-in (path-gated on missing host keys) is kept because it also covers key deletion on existing installs.

**Enablement lives in presets, not shipped `/etc` symlinks:** the outformat finalize script strips ALL unit enablement symlinks (`.wants`/`.requires` entries and `[Install]` aliases, both system and user scope) from the image `/etc` after mkosi's build-time `preset-all` pass, recording them in `/usr/share/snosi/enablement-manifest.txt`. The manifest records only what presets can actually recreate: entries are dropped when the target unit is masked (in `/etc` by name, or anywhere via the recorded symlink resolving to `/dev/null` — the native ab-root tree masks the bootc/nbc updater units in `/usr/lib/systemd`) or when the recorded symlink dangles (unit no longer shipped — e.g. the native secure profiles' Forky systemd 261 upgrade removed `run-lock.mount` after base's Trixie preset pass enabled it; fixed 2026-07-17, previously these three deterministically failed `05-firstboot-presets.sh` parity on native and were allowlisted in `test/native-ab-secure-boot-test.sh`). First boot recreates them from the same preset policy as *runtime-created* `/etc` state — so an admin's `systemctl disable` deletes a runtime-created path and no longer breaks bootc's `/etc` merge (see below). Masks (`/dev/null` symlinks) and linked units (e.g. the dracut service links) are kept: presets cannot recreate those. Consequences: (1) enablement changes belong in `usr/lib/systemd/system-preset/` / `user-preset/` files, never in postinst `systemctl enable` or manual symlinks — mkosi runs `preset-all` (and `--global preset-all`) AFTER postinst scripts, so manual symlink surgery there is silently overridden by the preset pass; (2) a NEW image's changed preset policy does not re-apply wholesale to existing installs (first boot has passed) — `preset-reconcile.service` closes the gap incrementally: it diffs the image manifest against `/var/lib/snosi/enablement-manifest.applied`, presets ONLY units newly added to policy (creates-only, masked units win, admin disables are never fought), records policy removals for the drift report (never auto-disables), and snapshots the applied policy; (3) `test/tests/05-firstboot-presets.sh` verifies manifest parity on first boot; (4) **snosi infrastructure units use STATIC activation, not presets**: preset-reconcile, snosi-etc-drift-report, the notify user units, and preset-migration ship with NO `[Install]` section plus a static wants symlink in `/usr` (`multi-user.target.wants/`, user `graphical-session.target.wants/`, `sysinit.target.wants/`) — preset-based enablement of a NEW unit cannot bootstrap on installs whose first boot predates it (reconcile itself had this chicken-and-egg, caught 2026-07-06), while static /usr wants work everywhere immediately, keep zero `/etc` state, and are overridden with `systemctl mask` (not `disable`).

**Never use `RequiredBy=` in a shipped unit's `[Install]` section (ADR-0013, core ADR-0030):** first-boot presets persist `.requires` links in `/etc`, and when a later image retires the unit the dangling `Requires=` invalidates PID 1's very first transaction — the machine dies at "Failed to isolate default target" before any service runs or the journal persists (root-caused live 2026-08-12: `e08311f` retired `snow-linux-live-setup.service`, `RequiredBy=multi-user.target` + `display-manager.service`, and image `20260812205454` failed all three counted boots on every install first-booted before the retirement; A/B fallback saved the machines). Fresh installs — so every CI boot test — are immune, which is why no harness caught it. `check-required-by-guard.sh` (validate.yml; fixtures `test/required-by-guard-test.sh`) forbids `RequiredBy=` and shipped `*.requires/` links in payload dirs (escape hatch `# requiredby-guard-allow: <reason>`); hard deps go in the dependent unit's `[Unit] Requires=` or the static-wants pattern. Defensively, the native A/B initrd prunes stale `.requires` links from the persistent `/etc` upper before the overlay is assembled (`shared/outformat/ab-root/.../95etc-overlay/etc-overlay-prune.sh`, `.requires` ONLY — dangling `.wants` are harmless and sysext units are legitimately absent pre-merge; fixtures `test/etc-overlay-prune-test.sh`, wiring pinned by `test/native-ab-static-test.sh`), which also covers package-shipped `RequiredBy=` units the guard cannot see and retroactively heals installs already carrying stale links.

**Unit files must live in exactly ONE tree.** `shared/snow/tree` and `shared/cayo/tree` once carried byte-identical copies of base units (mount units, nbc-update-download); profile ExtraTrees overwrite base at image assembly, so a fix applied only to the base copy silently did not ship in any profile image (caught 2026-07-06: the nbc composefs gate). Base `mkosi.extra` is authoritative for shared units; profile trees carry only genuinely profile-specific files.

**Drift visibility:** `snosi-etc-diff` (root CLI) diffs live `/etc` against the booted image's pristine `/etc` (bind-mounts `/` to see under the `/etc` mount — no `/usr/etc` exists on composefs), with ignore globs in `/usr/lib/snosi/etc-diff.ignore` (+ optional `/etc/snosi/etc-diff.ignore`) for expected per-machine state. On native A/B images (marker `/usr/lib/snosi/native-ab`), root is EROFS and live `/etc` is an overlay whose lowerdir is `/.etc.lower` on that same root, so the bind-mount trick would expose `/.etc.lower` plus an empty `/etc` mountpoint dir; the script instead uses `/.etc.lower` directly as the pristine tree (no mount needed), and everything downstream — listing, path diff, restore — is identical between the two sources. Beyond the M/D/A path listing (which ends with a resolution footer), `snosi-etc-diff /etc/<path>` shows the actual difference (unified diff / symlink targets / permission lines) and `snosi-etc-diff --restore /etc/<path>` reverts a path to the image version (refuses locally-added paths — nothing to restore from). `snosi-etc-drift-report.service` writes M/D entries plus preset-policy removals to `/var/lib/snosi/etc-drift.report` each boot; a hash-gated user service (`snosi-etc-drift-notify`) raises one desktop notification per report *change* (not per boot), and `/etc/update-motd.d/85-snosi-etc-drift` surfaces it on headless logins. Keep the ignore list honest: entries that always drift (daemon-rewritten files) train users to dismiss the report.

### OS Update Staging (bootc)

On bootc-installed systems, updates are staged by `bootc-update-stage.timer` (hourly; base `mkosi.extra`): `/usr/libexec/bootc-update-stage` pulls the followed image via **podman**, then stages it with `bootc upgrade` when the spec already follows `containers-storage` (the steady state after the first staged update) or `bootc switch --transport containers-storage` otherwise — `bootc switch` to an IDENTICAL spec is a silent no-op in bootc ≤ 1.16.3 (composefs switch returns before staging when `new_spec == host.spec`), which made every install unable to take a second update while logging success (root-caused 2026-07-06). The script verifies post-stage that `.status.staged.image.imageDigest` equals the pulled digest and fails loudly otherwise. The update applies at the next natural reboot via `bootc-finalize-staged.service`. **Reboot-pending visibility:** after staging (or when finding an update already staged, e.g. via manual `bootc upgrade`), the script writes `/run/snosi/update-staged` (image/digest/timestamp; cleared automatically by the applying reboot). Two consumers: `/etc/update-motd.d/86-bootc-update-staged` (SSH/console logins) and `bootc-update-notify.path`/`.service` (user scope, desktop notification via `/usr/libexec/bootc-update-notify`, ack-gated per staged digest so it fires once per update, not per login). The desktop toast needs the `notify-send` CLI, which lives in `libnotify-bin` (NOT the transitively-pulled `libnotify4` library) — it ships only in the graphical package set (`shared/packages/snow/mkosi.conf`, used by snow+snowfield, not cayo); without it both `bootc-update-notify` and `snosi-etc-drift-notify` `command -v notify-send || exit 0` into silent no-ops. Both notify units set `StartLimitIntervalSec=0` because the stager writes the semaphore in several syscalls, so one staging emits a burst of `PathModified` triggers that otherwise trips systemd's default 5/10s start-limit and permanently fails the `.path` watcher (`unit-start-limit-hit`); the per-digest ack makes the repeat triggers harmless no-ops. **The `.path` units are `PathModified=` ONLY — never `PathExists=` (root-caused live 2026-08-26 on a desktop install):** level-triggered path conditions (`PathExists=`, `DirectoryNotEmpty=`, …) re-arm every time the triggered oneshot exits, and the semaphore persists until the applying reboot by design, so `PathExists=` retrigger-loops until systemd's path trigger limit (200/2s) permanently fails the watcher with `trigger-limit-hit` — the StartLimit fix had merely unmasked this second limiter. The login-while-pending case `PathExists=` used to cover is handled by a static `graphical-session.target.wants/` link on the SERVICE (condition- and ack-gated, so it no-ops when nothing is staged). A level-triggered path condition is acceptable only when the triggered unit is long-running (the `snosi-ask-password-serial` pair's `--watch` agent). `test/update-notify-units-test.sh` (validate.yml) pins the trigger shape, the wants links, and directive-parity between the bootc- and native-named twins. **Currency visibility:** the script also writes `/run/snosi/update-check` on EVERY run (`outcome=current|staged|held-rollback|failed` plus timestamp and running/remote version; an EXIT trap records `failed` on any error) so "up to date", "reboot pending", and "checker broken" are three distinguishable states instead of one silent one. The same motd hook prints one line per state, and `snosi-update-status` (root CLI) summarizes running version, last-check outcome, and staged deployment; `snosi-update-status --check` additionally queries the registry live via skopeo and compares `org.opencontainers.image.version` labels — always compare versions, never digests (the same build has a different digest per transport: registry vs ISO vs podman-loaded). podman does the transfer because bootc's registry-transport composefs pull currently fails on snosi images (known upstream bug) — and podman enforces `containers-policy.json` at pull time. The script no-ops when: not a bootc-managed system (nbc installs — `spec.image` is null), already running or already staged the pulled digest, or the pulled digest equals the **rollback** deployment (never auto-flip-flop back to a version the admin rolled away from; bootc refuses that switch anyway). Upstream's `bootc-fetch-apply-updates.timer` is preset-disabled: it force-reboots on update and is gated on `/run/ostree-booted`, which does not exist on composefs deployments. During the transition, `nbc-update-download.timer` still ships for nbc-installed hosts. bootc-update-stage no-ops on nbc installs (`spec.image` null check); the nbc units are gated with `ConditionKernelCommandLine=!composefs` because `nbc update` itself ERRORS (exit 1, permanently failed unit, degraded state) rather than no-opping on bootc/composefs installs (frostyard/nbc#139).

### Native A/B Update UX (Phase 4)

Native A/B images (`/usr/lib/snosi/native-ab` marker) never run bootc/nbc.
`/usr/libexec/snosi-sysupdate-stage` (system service+timer, `shared/outformat/ab-root/tree`) is the native analog of `bootc-update-stage`: it runs `systemd-sysupdate check-new` against the image's DEFAULT sysupdate target (`/usr/lib/sysupdate.d/`, no `--definitions=`), and if newer, `systemd-sysupdate update <version>` (installs into the inactive root/verity slots only), then independently re-verifies the result — re-fetches `SHA256SUMS` and confirms the newly-labeled partitions' PARTUUIDs match the embedded UUIDs, and confirms the matching UKI exists in the ESP (ordering proxy: sysupdate applies transfers 10/20/90 in order, so a present UKI implies the partition transfers already landed) — failing loudly (`outcome=failed`) if either check disagrees. The PARTUUID read is `udevadm settle` plus a bounded retry loop, not a single `lsblk` call: lsblk reads udev's property db, which refreshes ASYNCHRONOUSLY after sysupdate's GPT writes, and an immediate read can see a mixed stale view (observed live 2026-07-15 in the full-window QEMU run: the reused slot showed its new label with the old pre-vacuum PARTUUID while the on-disk GPT was provably correct — the next boot and the next hop's identical check both passed); `udevadm settle` alone is insufficient because it returns early when udev's watch event has not been synthesized yet. A real mismatch still fails identically once retries are exhausted. It never reboots. Speaks the exact same `/run/snosi/update-check` and `/run/snosi/update-staged` state-file language as the bootc stager (same field names: `outcome=`, `checked_at=`, `running_version=`, `remote_version=`), so the shared consumers below work unmodified — with one deliberate schema extension: `/run/snosi/update-staged` carries `version=<14-digit>` on native instead of bootc's `digest=sha256:...` (exactly one of the two is ever present on a given image), and every shared consumer (`/etc/update-motd.d/86-bootc-update-staged`, `/usr/libexec/bootc-update-notify`) now keys off whichever is present rather than hardcoding `digest=`.

**No native `held-rollback`, deliberately:** bootc's `held-rollback` outcome exists because ostree tracks an explicit separate rollback-deployment pointer that a re-pull of an unchanged registry tag can collide with. `systemd-sysupdate`'s `InstancesMax=2` accounting has no equivalent separate pointer — it treats BOTH on-disk root slots as "installed" when deciding what counts as newer, so a version already sitting in either slot (including one the admin just rolled away from) is never re-offered by `check-new` in the first place; there is nothing to hold. The one real adjacent case — a version already downloaded into the inactive slot by an earlier run this boot, waiting for reboot — is handled as an explicit "already staged" re-assertion branch instead (see the script's own header for the full reasoning).

**Three stager hardening rules, all root-caused live in the first QEMU run of `test/native-ab-updateux-test.sh`:** (1) capture `check-new` STDOUT ONLY — its progress lines ("Discovering installed instances…") are stderr log output, and capturing `2>&1` splices them into the version string (`update '<five lines of progress>' not found`); the parsed candidate is also validated against the frozen `^[0-9]{14}$` grammar. (2) `check-new`'s non-zero exit collapses "nothing newer" and every genuine failure into one code — the stager disambiguates with an independent probe (curl `SHA256SUMS`+`.gpg`, `gpgv` against the effective pubring): probe passes → `outcome=current` is the truth; probe fails → `outcome=failed`, never a fake "up to date". (3) a candidate NOT newer than the running version is reported `current`, never staged — kept as belt-and-suspenders even after the build-time UKI naming gap below was closed. Related: never exclude the booted slot from partition enumeration by comparing against `findmnt -o SOURCE /` — a dm-verity root mounts from `/dev/mapper/root`, never the partition path, so exclude by the running version's LABEL instead (`<ImageId>_<version>_r`); this bit both the stager and `snosi-update-status`'s rollback-slot lookup.

**Factory UKI naming aligned with the sysupdate transfer:** mkosi's own default UKI name is `&e-&k-&h` (entry-token-kernelversion-roothash, e.g. `cayo-7.0.13+deb13-amd64-<hash>.efi`), which never matched the channel transfer's `Target MatchPattern` (`<channel>_@v...efi`) — sysupdate's installed-version accounting (`list`/`pending`/vacuum/`InstancesMax`) never saw the factory-shipped UKI, and systemd-boot carried it forever as a third, unmanaged menu entry no update ever superseded. Fixed via `shared/outformat/ab-root/mkosi.conf`'s `UnifiedKernelImageFormat=&e` plus `shared/outformat/ab-root/finalize/mkosi.finalize.chroot` writing `/etc/kernel/entry-token` to `<channel>_<version>` (channel = `<ImageId>-ab`, version = `$IMAGE_VERSION`, both exported into `FinalizeScripts=` by mkosi) — `find_entry_token()` resolves `&e` via `kernel-install inspect`, which reads `/etc/kernel/entry-token` when present (`kernel-install(8)`, "auto" entry-token mode, the default). This has to happen in the buildroot's `/etc` before repart, not a `PostOutputScripts=` rename: mkosi's `install_kernel()` (which actually builds the UKI) runs strictly AFTER all `FinalizeScripts=` but BEFORE `make_disk()` formats the ESP partition from the buildroot's `/boot` (`.mkosi/mkosi/__init__.py` `build_image()`), and by the time `PostOutputScripts=` run the ESP has already been formatted into the disk image with no loop-device/mount access available in mkosi's script sandbox to edit a FAT filesystem in place. The write lands in the *fresh* post-mv `/etc` (this finalize script's first act renames the real `/etc` to `/.etc.lower` for the persistent overlay), not `/.etc.lower` — nothing at runtime ever re-reads `/etc/kernel/entry-token` on a booted dm-verity read-only root, so it only needs to exist on disk for mkosi's own build-time `kernel-install inspect` call. Verified empirically (`test/native-ab-updateux-test.sh` Step 1): a freshly-built N boots with `/boot/EFI/Linux/<channel>_<version>.efi` and `systemd-sysupdate list` reports the factory version as already installed without ever running the stager.

**Origin override for testing:** `sysupdate.d(5)` has no `NAME.transfer.d/` per-key drop-in mechanism (confirmed against upstream docs) — only whole-file override by identical filename, same precedence as `tmpfiles.d`/`sysctl.d` (`/etc` over `/usr/lib`). `test/native-ab-updateux-test.sh` drops complete replacement `*.transfer` files into `/etc/sysupdate.d/`, byte-identical to the shipped channel transfers except `[Source] Path=`, to redirect at a local HTTP fixture origin — the stager itself never reads an origin URL, so production and the test exercise the identical code path. The test also overrides the trust root the same way updates already do (`/etc/systemd/import-pubring.gpg` takes precedence over the shipped `/usr/lib/systemd/import-pubring.gpg` DEV key) — the shipped default is never weakened.

**Desktop notification:** native ships parallel, native-named user units `snosi-update-notify.path`/`.service` (`shared/outformat/ab-root/tree`, masked bootc-named units stay masked) with a static `graphical-session.target.wants/` link (unconditional — a passive watcher is harmless even when nothing is ever staged). Both unit pairs `ExecStart=` the SAME `/usr/libexec/bootc-update-notify` script — no duplicated notification logic between transports.

**`snosi-update-status`** dispatches on the native marker before ever touching the `bootc` CLI (which isn't installed on native images — calling it would hard-fail). The native backend adds: `systemd-sysupdate pending` (authoritative "is a newer version already installed" signal, independent of the possibly-stale `/run` semaphore), `systemd-bless-boot status` (good/bad/indeterminate/clean), and the other root slot's version (rollback candidate, via `lsblk`/`jq`). `--check` fetches `SHA256SUMS`+`SHA256SUMS.gpg` from the R2 index and verifies with `gpgv --keyring /usr/lib/systemd/import-pubring.gpg` before trusting any version it lists — same never-trust-an-unverified-index posture as the stager.

**Activation policy — CI enables it; the timer is inert without the build knob:** `snosi-sysupdate-stage.timer` ships with NO `[Install]` section (static-link activation only, per the infra-unit pattern above). Whether it is *activated* depends on a build-time knob: `shared/outformat/ab-root/finalize/mkosi.finalize.chroot` creates the static `/usr/lib/systemd/system/timers.target.wants/snosi-sysupdate-stage.timer` link ONLY when `SNOSI_NATIVE_AUTOSTAGE=1` is set in the build environment. **`build-native-images.yml`'s three product build steps now pass `SNOSI_NATIVE_AUTOSTAGE=1` (2026-07)**, so CI-published `cayo-ab`/`snow-ab`/`snowfield-ab` images auto-stage updates (hourly timer → staged into the inactive slot → applied on next natural reboot; never a forced reboot). A local `mkosi build` without the var in its environment still produces an inert-timer image (`systemctl is-enabled` = `static`, nothing starts it) — the knob must be set in the shell that runs mkosi, and passed through `sudo` (which strips the environment) as `sudo SNOSI_NATIVE_AUTOSTAGE=1 … mkosi …`. Images published BEFORE this change (≤ `20260717…` early builds) have the timer inert; such installs update only manually (`snosi-update-status --check`, then `/usr/libexec/snosi-sysupdate-stage`, then reboot) until they take one manual update onto an autostage-enabled build, after which it is self-sustaining. (The var is forwarded into the finalize `.chroot` script via `Environment=SNOSI_NATIVE_AUTOSTAGE` under `shared/outformat/ab-root/mkosi.conf`'s `[Build]` — `mkosi.1`: `Environment=` with a bare name passes through the host env var to prepare/build/postinstall/finalize scripts.) This is a static link, not a preset, for the same reason as every other snosi infra unit: an already-installed image whose first boot predates a publication-enabled release would never pick up a brand-new preset-only enablement, but a static link ships correctly with the very update that introduces it — verified end to end by `test/native-ab-updateux-test.sh` (boots a publication-disabled N, stages a publication-enabled N+1 built with `SNOSI_NATIVE_AUTOSTAGE=1`, reboots, and asserts the timer is ACTIVE post-reboot: the Phase 4 exit criterion). Independent of this knob, `systemd-sysupdate.timer`/`-reboot.timer` (upstream) stay masked in `/etc` unconditionally (`shared/outformat/image/finalize/mkosi.finalize.chroot`) — our stager replaces upstream's fetch+apply+immediate-reboot behavior permanently, publication-enabled or not.

### Base Image: bootc + ostree from Frostyard debs

The base package set explicitly includes `pciutils` and `usbutils`, so every
product provides host PCI and USB diagnostics without relying on transitive
dependencies.

bootc and ostree install as regular APT packages (`bootc`, `libostree-1-1` — the latter ships the library AND the ostree CLI) from the Frostyard repository, built and published by [frostyard/bootc-debian](https://github.com/frostyard/bootc-debian). Debian Trixie shipped no bootc package and only ostree 2025.2 (too old for current bootc), hence the external packaging; the current debs are built against trixie's `libgpgme11t64`, so they need a forky rebuild before the OCI profiles build on the forky base (ADR-0014).

- **Versions:** pinned in bootc-debian's `download/checksums.json`, tracked weekly by that repo's own `check-dependencies.yml` — snosi's dependency check does NOT cover them. Deb versions carry a `-frostyard<timestamp>` suffix so rebuilds of the same upstream version still sort newer in apt.
- **Build parity:** bootc-debian's `build.sh` mirrors the former in-tree mkosi BuildScript (same pinned tarballs, same checksums, same pinned Rust toolchain — Debian's rustc 1.85 is too old to build bootc 1.16.x). Its Build workflow publishes the debs and then dispatches a snosi image build.
- **Runtime libs:** the debs declare only a partial `Depends` list; base `Packages=` keeps the full set of runtime link deps explicit (`libfuse3-4`, `libsoup-3.0-0`, `liblzma5`, etc.) — do not remove them just because apt doesn't demand them.
- **History:** until 2026-07 these were compiled from source during the base image build (`shared/bootc/build/bootc.chroot` + stub-deb dpkg registration); that machinery is gone.

### Native A/B prototype & installer history

The detailed phase-by-phase build journal for the native A/B products
(`cayo-ab`, `snow-ab`, `snowfield-ab`), the installer ISO (Phase 8), the
Phase 8 real-install proof, and the native `/var` factory-state work has moved
to [`docs/native-ab-prototype-history.md`](docs/native-ab-prototype-history.md)
to keep this file focused.

The **authoritative** native A/B contracts are not in that history doc — read
these before changing anything under the native A/B tree:

- Naming/path/policy contracts: [`docs/native-ab-contracts.md`](docs/native-ab-contracts.md)
  (source of truth, enforced by `test/native-ab-contracts-test.sh`; known
  deviations tracked in `test/native-ab-contracts-allow.txt`).
- Publication pipeline: [`docs/native-ab-publication.md`](docs/native-ab-publication.md).
- Slot/capacity sizing: [`docs/native-ab-capacities.md`](docs/native-ab-capacities.md).


### Sysext Constraints

**Sysext udev rules and kernel modules (2026-08-28):** a
`/usr/lib/udev/rules.d/` entry shipped inside a sysext is applied on NO boot
unless the sysext also wires the post-merge reload.
`systemd-sysext.service` declares only `Before=sysinit.target` and carries no
ordering against `systemd-udevd.service`; udev wins in practice (live snow
install: udev 8.36s, merge 9.24s), parses its rules once at daemon start, and
is never told to look again. `OPTIONS+="static_node="` does not rescue this —
udev applies static-node permissions only at daemon startup, exactly when the
rule does not yet exist. Root-caused on voxtype: ydotool's `80-uinput.rules`
never applied, `/dev/uinput` stayed `root:root 0600`, `ydotoold` died
"Permission denied" and burned its five `Restart=always` attempts in ~0.5s into
`start-limit-hit`, and voxtype silently used `fallback_to_clipboard` — it
transcribed and typed nothing, with no error anywhere a user would look.
Sunshine had the same latent defect. Fix: `ExtraTrees=%D/shared/sysext/tree`
plus a `multi-user.target.d/10-<name>.conf` `Upholds=snosi-sysext-udev-reload.service`
drop-in. That unit runs `After=reload-sysext.service systemd-udevd.service`,
`Before=multi-user.target`, and executes `/usr/lib/snosi/sysext-udev-reload`:
`udevadm control --reload` -> `settle` -> `systemd-modules-load` ->
`udevadm trigger --action=add --subsystem-match=misc` -> `settle`. **The order
is the fix** — creating the device is what makes the reloaded rule fire, so the
modprobe must follow the reload; steps 1 and 3 are fail-closed, settle timeouts
are advisory. The `misc` scoping is deliberate: re-triggering `add` across
`input` would churn every keyboard and mouse through libinput/mutter.
`test/sysext-udev-reload-test.sh` (validate.yml) fixtures the order and
fail-closed behavior and enforces wiring parity from a DERIVED consumer set
(any sysext whose `required-paths.txt` claims a `/usr/lib/udev/rules.d/` or
`/usr/lib/modules-load.d/` path). Anything added to `shared/sysext/tree` must
be inert for every consumer — `ExtraTrees=` takes the whole tree.

**Sunshine sysext:** Sunshine is a desktop-only, self-hosted game-streaming
host for Moonlight installed from its official pinned deb (the
`ubuntu-26.04` build — LizardByte publishes no forky/testing deb, and that
build's libicu78/libminiupnpc21/glibc 2.43 Depends are exactly forky's
sonames) through `verified_download()`. Its native `/usr` layout retains the package's
`cap_sys_admin,cap_sys_nice` capability, `uhid` modules-load entry, and udev
access rules; those last two reach udev only through the post-merge reload
above. Its upstream user service is available for manual user startup; do not
add a preset or `Upholds=` activation for Sunshine itself.

**Voxtype sysext:** AI voice dictation for Wayland from the Frostyard APT
repository, bundling its own text-output chain (`wtype` for wlroots/Hyprland,
`ydotool` for GNOME/mutter — the only driver mutter supports; in forky
main, trixie only had it in backports — and `wl-clipboard` for the
fallback). It ships
`modules-load.d/60-voxtype.conf` for `uinput` and depends on the post-merge
udev reload above; without it dictation transcribes but inserts no text. Its
`ydotool.service.d/10-voxtype.conf` sets `RestartSec=5s` because the deb's
`Restart=always` at the default 100ms exhausts its start limit in half a
second.

**Pilothouse sysext:** Snosi overrides only `pilothoused.service` `ExecStart`
to retain the packaged Debian socket, socket-group, and sudo-group arguments
and explicitly configure Updex, Podman, Docker, and Incus. These are probe
opt-ins, not hard dependencies; unavailable endpoints remain unregistered and
nonfatal. The GitHub-release DEB's complete `Depends` expression must pass
`assert_deb_dependencies_satisfied` before `dpkg -i`; add newly required
runtime packages through `Packages=` rather than installing them implicitly.

**Desktop-app sysexts build against `gui-base`, not `base` (issue #781):**
app sysext deltas omit only packages their BUILD BASE has, so base-built
Electron/GTK deltas carried the whole GUI closure — and products that pinned
those libs from other suites (on the trixie base, snowfield pinned mesa from
backports via the Surface kernel fragment) got shadow-DOWNGRADED for all of
`/usr` on merge
(root-caused live 2026-08-25 on a since-retired Hyprland product, which
pinned xkbcommon/pipewire/alsa/mesa from backports). `mkosi.images/gui-base` is an
internal never-published directory image (base + common GUI lib closure);
the desktop-app sysexts (thirteen today; the wiring-parity test enumerates them) use `Dependencies=gui-base` +
`BaseTrees=%O/gui-base` + the `sysext-no-divergent-libs.sh` finalize
tripwire (fails the build on any delta file matching
`shared/sysext/divergent-lib-families.txt`). THE CONTRACT: every gui-base
package must be in EVERY desktop product's closure (presence, not
version, drives delta omission — each product supplies its own suite's
version at merge). Packages absent from a desktop product stay OUT
(libxss1/zenity/fonts-liberation/libayatana-appindicator3-1 today).
Wiring parity and script behavior are pinned by
`test/sysext-divergent-libs-test.sh` (validate.yml). Server sysexts stay
base-built (incus needs its qemu GUI libs on cayo); content-only rebases
require a `SYSEXT_REVISION` bump or the republish silently skips. Full
pattern: `docs/design/sysexts.md` "Desktop-App Sysexts Build Against
gui-base".

**A published sysext delta is frozen against the base it was built on
(2026-09-01):** an `Overlay=yes` delta omits every package its BUILD BASE
already had, so the `.raw` is an assertion about base's transitive closure at
build time that nothing revalidates later. Removing a package from base
therefore breaks every sysext published before that removal, and
`skip-duplicates` means an unchanged KEYPACKAGE version never republishes on
its own. Root-caused on incus/cayo: until 33455fc (2026-08-25, #771) base
transitively pulled a whole desktop through `network-manager-applet`'s
`policykit-1-gnome | polkit-1-auth-agent` virtual, so the 2026-08-04 incus
delta shipped `qemu-system-gui`, `libsdl2-2.0-0`, `libvte-2.91-0`,
`libgtk-vnc-2.0-0` and `virt-viewer` with NONE of their GTK3/media deps. After
#771 cayo has 24 unresolved sonames in that payload; the incus deb's bundled
`/usr/incus/bin/qemu-system-x86_64` (`DT_NEEDED: libepoxy.so.0`, and incusd's
`/usr/incus/lib/systemd/incusd` wrapper puts `/usr/incus/bin` first on `PATH`,
so it — not Debian's working `/usr/bin/qemu-system-x86_64` — is what gets
probed) could not load, incusd registered only the `lxc` driver, and every
`incus launch --vm` failed with `Instance type "virtual-machine" is not
supported on this server: Failed getting QEMU version`. Snow was unaffected
because GNOME supplies the same libs, which is why it reached a server product
undetected. **Bump `SYSEXT_REVISION` on affected sysexts in the same change
that shrinks base**, and pin load-bearing library paths in
`required-paths.txt` (the check runs against the delta, so a pinned
`/usr/lib/x86_64-linux-gnu/libepoxy.so.0` asserts the delta ships it — adding
the package to `Packages=` does NOT help, because omission is decided by
presence in base, not by how the package was requested). Diagnose with `ldd`
over `/usr/bin`, `/usr/sbin`, `/usr/libexec` (plus
`LD_LIBRARY_PATH=/usr/incus/lib/` for the bundled incus payload), never by
reading the package list. Blast radius for a base removal is bounded by
intersecting the set the old base supplied (one pre-change sysext's new
manifest minus its published `.raw`) with every other pre-change sysext's
current manifest; for #771 that was exactly `incus` and `dev`. Full pattern
and the procedure: `docs/design/sysexts.md` "A Sysext Delta Is Only Valid
Against the Base It Was Built On".

Sysexts can ONLY provide files under `/usr`. They cannot modify `/etc` or `/var` at runtime. Configs needed in `/etc` must be:

1. Captured to `/usr/share/factory/etc` during build (via `mkosi.finalize`) — capture ONLY the specific paths the sysext's tmpfiles rules reference, never all of `/etc` (the buildroot `/etc` is the merged base view; a full capture ships `/etc/shadow` and SSH host keys in the published sysext)
2. Injected at boot via systemd-tmpfiles

Every sysext must have matching `<name>.transfer` and `<name>.feature` files in their own component directory, `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.<name>.d/`. The `.transfer` file defines how systemd-sysupdate downloads the sysext; the `.feature` file provides metadata and defaults to `Enabled=false`. Use an existing component directory as a template. **Do not add sysext transfer/feature files to the shared `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/` target** — that directory is reserved for native-profile OS transfers only (see "Native A/B Prototype" below); systemd-sysupdate version-locks every enabled transfer sharing one definitions directory, so mixing sysext package versions into the OS transfer's directory would corrupt OS version resolution. **Release-ordering constraint:** this per-component layout requires component discovery support in `frostyard-updex` (landed upstream on branch `feat/sysupdate-components`); do not publish base images built after this migration until a frostyard-updex release with component discovery is available in the Frostyard APT repo — an older updex cannot discover component-scoped sysexts and every sysext update would silently stop being offered.

**Service activation in sysexts:** Do NOT rely on `WantedBy=multi-user.target` + preset alone. At boot, the sysext is not yet merged when PID 1 scans units — the `.wants/` symlink is dangling and silently dropped. Always ship a `usr/lib/systemd/system/multi-user.target.d/10-<name>.conf` drop-in inside the sysext with `[Unit]\nUpholds=<name>.service`. This drop-in is new to systemd after the post-merge daemon-reload, so activation fires correctly. The preset is still required for enabled state; the drop-in handles timing.

**Desktop applications in sysexts (icon visibility):** GTK, GNOME Shell (St), and Qt treat a present `/usr/share/icons/hicolor/icon-theme.cache` as an authoritative index whenever its mtime is >= the theme directory's mtime. Sysexts merge icons with upstream file timestamps (older than the image build), so an image-shipped cache stays "valid" and every sysext icon is invisible — the app shows GNOME's generic gear icon (root-caused 2026-07-07 on the emdash sysext). Fix, both halves mandatory: (1) the profile-image finalize (`shared/outformat/image/finalize/mkosi.finalize.chroot`) deletes the hicolor cache so GTK falls back to scanning the theme directories; (2) every sysext includes `shared/sysext/finalize/sysext-strip-icon-cache.sh` in `FinalizeScripts=` so a gtk-update-icon-cache dpkg trigger firing during the sysext build cannot smuggle a cache into the delta — a sysext-shipped cache shadows the (absent) base cache for the whole merged `/usr` and re-masks other sysexts' and newer base icons. The same script also strips `/usr/share/glib-2.0/schemas/gschemas.compiled`: a `glib-compile-schemas` dpkg trigger firing in a gui-base-derived sysext build compiles a cache from gui-base's schema set into the delta, which then shadows the base's complete cache and aborts gnome-session (`org.gnome.SessionManager` missing; root-caused 2026-08-26 on claude-desktop/chatgpt). Externally-built sysexts (other repos) must strip both caches too. Icons in `/usr/share/pixmaps` (e.g. VS Code's) are unaffected either way — unthemed fallback dirs are always scanned, never cached. Icons appear at the next session start; an already-running GNOME Shell may not notice a merge until re-login. Full pattern: `docs/design/sysexts.md` "Desktop Applications in Sysexts".

**GdkPixbuf loader caches in sysexts (2026-09-01):**
`/usr/lib/<triplet>/gdk-pixbuf-2.0/<abi>/loaders.cache` is another singleton,
but base-built graphical sysexts cannot strip it because cayo has no graphical
base cache. Any sysext that ships this cache must explicitly ship
`librsvg2-common` and the cache must register its
`libpixbufloader_svg.so`; `sysext-strip-icon-cache.sh` fails the build if
either half is absent. Root-caused live after dev r2, incus r2, and Paseo
0.7.0 merged on Snow: all three carried the same 2,582-byte loader cache with
no SVG entry. The sysext cache shadowed Snow's correct base cache, GNOME Shell
logged `Could not load a pixbuf from icon theme`, and most Adwaita SVG icons
rendered blank even though Snow's package manifest contained
`librsvg2-common` and the loader module existed. Content-only corrections must
bump each affected `SYSEXT_REVISION`; otherwise `skip-duplicates` leaves the
broken raw image published. Full contract and fixture coverage:
`docs/design/sysexts.md` and `test/sysext-authoring-contract-test.sh`.

The shared sysext postoutput script (`shared/sysext/postoutput/sysext-postoutput.sh`) handles versioned naming and manifest processing. It requires the `KEYPACKAGE` env var set in each sysext's `mkosi.conf`. If `SYSEXT_REVISION` is also set, the version gets a `+rN` suffix — bump this to force a republish of tree/content fixes when the KEYPACKAGE version hasn't changed (publishing skips existing filenames via `skip-duplicates`, so tree fixes otherwise never reach users; remove the setting when the package version bumps). Every sysext must also ship `mkosi.images/<name>/required-paths.txt` (one absolute path per line); the shared finalize check (`shared/sysext/finalize/sysext-required-paths.sh`) fails the build if any listed path is missing from the buildroot — guard against publishing structurally broken sysexts (the 2026-07-01 incus publish shipped with no incusd/CLI/units and nothing noticed). The sibling `shared/sysext/finalize/sysext-usr-only.sh` guard fails any delta with an entry below `/opt` (the empty mountpoint directory itself is permitted; symlinks are reported, never followed). It deliberately does NOT inspect `/var`: mkosi's sysext repart definition (`sysext.repart.d/10-root.conf`) copies exactly `/usr/` and `/opt/` into the published erofs, so buildroot `/var` — dpkg logs, package caches, postinst trigger state such as `/var/lib/emacsen-common` — is inert build residue that never ships, while `/opt` does ship and is shadowed at runtime by the `/var/opt` bind mount. `test/sysext-usr-only-test.sh` pins that `CopyFiles=` set whenever the `.mkosi` checkout is present, so a mkosi bump that widens the packed tree re-opens the question instead of silently widening the payload. An earlier draft of the guard checked `/var` too and had to grow a per-package residue allowlist one CI round at a time (dpkg.log, dictionaries-common, emacsen-common, coder's preinst home); do not reintroduce that. For `Overlay=yes` images the finalize `$BUILDROOT` is the sysext DELTA (upper layer), so list only paths the sysext itself ships — packages also present in the base image never appear in the delta and will always fail the check.

## Key Directories

- `shared/download/` - Verified download system: `sysext-checksums.json` pins direct downloads consumed by sysexts, `image-checksums.json` pins direct downloads consumed by OCI profile builds, `package-versions.json` tracks external APT package version sentinels for sysexts, and `verified-download.sh` provides the `verified_download()` helper
- `shared/kernel/` - Kernel configs (backports, surface, stock) and dracut scripts
- `shared/packages/` - Package set definitions, some with postinstall scripts for relocation
- `shared/outformat/image/` - Image output format config (directory), finalize scripts, `buildah-package.sh` (OCI packaging), and `chunkah-package.sh` (chunks non-secure OCI images and the pristine protected candidate before digest sealing; protected images are never re-chunked after assembly)
- `shared/sysext/postoutput/` - Shared sysext postoutput logic
- `mkosi.sandbox/etc/apt/` - External APT repo configs (Docker, Incus, linux-surface, Frostyard)

## Shell Script Conventions

- Use `set -euo pipefail` at the top of all scripts
- Build scripts running in chroot use `.chroot` extension
- External direct downloads must go through `verified_download()` with entries in `sysext-checksums.json` for sysext consumers or `image-checksums.json` for OCI profile consumers
- Pin external URLs to specific versions/commits, never `latest` or branch names
- When adding a new verified download, also add a corresponding update check to `.github/workflows/check-dependencies.yml`; sysext APT package sentinels go in `.github/workflows/check-packages.yml`
- Inline OCI build-tool pins that cannot live in checksum metadata are also tracked by `check-image-updates`; validate upstream values and require exactly one source match before editing them in place
- Both halves of the split checksum metadata (`sysext-checksums.json`, `image-checksums.json`) are covered by fixture tests: `test/verified-download-split-checksums-test.sh` for the read side (`verified_download`) and `test/update-checksums-split-test.sh` for the write side (`update-checksums.sh`'s ordered file selection, `CHECKSUMS_FILE` override, missing-file/absent-key hard-fails, and the no-partial-write guarantee). See `docs/design/build-pipeline.md` "Verified Download System" for the exact rules those tests pin.

## User Service Enablement in Chroot

`systemctl --user enable` does not work inside a mkosi chroot (no user session/D-Bus). System services are enabled via `systemctl enable` in `snow.postinst.chroot`, but user services require manually creating symlinks:

```bash
mkdir -p /etc/systemd/user/<target>.wants
ln -sf /usr/lib/systemd/user/<service> /etc/systemd/user/<target>.wants/<service>
```

The target (e.g. `gnome-session.target`) comes from the service's `WantedBy=` in its `[Install]` section.

**Known issue:** `deb-systemd-helper` creates `.dsh-also` tracking files in `/var/lib/systemd/deb-systemd-user-helper-enabled/` during the build but may not create the actual enablement symlinks in `/etc/systemd/user/`. If a user service isn't auto-starting after reboot, check whether its symlink is missing from `/etc/systemd/user/<target>.wants/` and compare against its `.dsh-also` file. A full sweep on 2026-07-01 found only two affected units, both resolved deliberately: `gnome-remote-desktop-headless` (removed — conflicts with the non-headless variant) and `rygel` (kept off — tracking removed in `snow.postinst.chroot`). Re-run the comparison when adding packages that ship user services.

## CI/CD

- `ai-fix-requested.yml` - Assigns an open issue to the Copilot coding agent when a maintainer applies `ai-fix-requested`, with manual dispatch for missed events. The REST assignment API requires the user-scoped `COPILOT_ASSIGNMENT_TOKEN` secret with fine-grained Actions, Contents, Issues, and Pull requests read/write access; `GITHUB_TOKEN` is an installation token and must not replace it. The workflow keeps default permissions empty, reads no issue text, revalidates the open state and label, and sends the repository's default branch as the agent base.
- `claude.yml` - ACMM-recognized GitHub Actions AI integration marker. It is manual-only, keeps default permissions empty, performs no checkout, uses no secrets, and points to the existing operational Copilot issue handoff rather than introducing another agent pathway.
- `triage.yml` - Adds one missing classification label (`acmm`, `bug`, `documentation`, `enhancement`, or `question`) from explicit issue-title signals on open, edit, or reopen. It never removes labels or overrides an existing classification, uses only job-scoped `issues: write`, and passes no issue text through workflow expressions or shell evaluation. The bug-report template applies `bug` exactly before heuristic triage runs.
- `build.yml` - Builds base + sysexts and publishes to Frostyard repo (Cloudflare R2) only outside pull requests. Its build job executes PR-controlled mkosi configuration under `sudo`, so that job's `GITHUB_TOKEN` is restricted to `contents: read`; it must not regain package, OIDC, or attestation write scope. `test/build-workflow-permissions-test.py`, wired into `validate.yml`, enforces that exact permission boundary. Push/PR triggers exclude Markdown, agent-context stores, the standalone installer ISO and redirect workflows, repository metadata, workflow files that never run on push/PR, and sibling push/PR workflow files it never reads, because none can affect sysext composition or publication; manual dispatch remains available. `build.yml` itself is never ignored by any workflow — it is the canonical mkosi pin source (`shared/native-ab/ci/bootstrap-mkosi.sh` and the Justfile read it). `test/workflow-path-filter-test.sh` pins all expensive-workflow ignore lists and the load-bearing non-ignores.
- `build-images.yml` - Push/PR triggers exclude Markdown, agent-context stores, the standalone installer ISO and redirect workflows, repository metadata, workflow files that never run on push/PR, and sibling push/PR workflow files it never reads; those paths cannot affect image inputs or validation, while manual/repository dispatch remains available. Superseded runs of the same ref are cancelled for push AND pull_request events (a new push to a PR branch previously left the prior three-profile mechanics matrix running to completion). Three-profile PR `mechanics-build` packages and smoke-tests locally with no secrets or registry writes. Protected `secure-build` runs only for main non-PR events in `native-build`: it transiently materializes the durable production MOK/PCR identities supplied by the four `NATIVE_*` secrets, deletes those runner-local files before registry writes, validates the local artifact, pushes/signs the immutable version digest, verifies labels/signature and policy-copied bytes remotely, then copies that verified digest to `latest`. Both jobs select the runner-bundled `runc` through a job-local `containers.conf.d` drop-in and verify it before building, avoiding the hosted Podman 5.8.4/default-crun incompatibility without changing shipped-image runtime policy. The Snow tag artifact is emitted only after its SBOM upload/signature, provenance attestation, and R2 manifest upload all succeed. The `release` job needs `secure-build`; it derives a predecessor only from newest-first GitHub Release `<!-- snow-tag: ... -->` markers whose older immutable Snow image has an exact `application/vnd.syft+json` referrer. It never falls back to arbitrary registry tags. If no eligible marker exists, it warns and safely skips changelog and release creation. Run `30627996880` passed all three protected secure image jobs (`cayo`, `snow`, `snowfield`), but its release changelog failed because the old fallback selected failed-build tag `20260731030941`, which had no SBOM. This repair is fixture-verified only, not live-proven, until a main-branch run creates or cleanly skips a Snow release using this resolver.
- `build-native-images.yml` (Phase 7) - Native A/B (`cayo-ab`/`snow-ab`/`snowfield-ab`) build/publish pipeline; a thin caller of `shared/native-ab/publish/*.sh` and `shared/native-ab/ci/*.sh` — see `docs/native-ab-publication.md`'s "CI publication flow" section for the full job graph, secret inventory, and the "First production publication checklist" that must be completed before it is allowed to touch real R2. Triggers on relevant push + PR changes to main (including `build.yml`, whose mkosi pin it reads) plus `workflow_dispatch`/`repository_dispatch`; ISO-only paths are ignored. PRs run only the non-publishing `build-pr` matrix with runner-generated RSA-4096 MOK and RSA-2048 PCR credentials. Production `build-{cayo,snow,snowfield}` and promotion stay outside PRs in their protected environments. Each product independently uploads, public-origin verifies, boots via `test/native-boot-smoke-test.sh`, and promotes, so one failure never blocks another. Range verification requires HTTP 206 plus exact `Content-Range` and byte count; each response is size-capped so ignored Range requests cannot pull a whole image. Each fresh promotion runner refreshes APT immediately before installing rclone.
- `build-installer-iso.yml` - Independent Firn installer ISO publication pipeline. Main pushes use a positive list of ISO build/trust/publication/smoke-test inputs; manual and generic org `build` repository dispatch remain because dispatches do not identify their source component. It has no PR trigger. `pin-check`/`prepare` feed `build-iso` in `native-build`, `test-public-origin-iso` re-downloads and boots the candidate to a serial login prompt, and `promote-iso` signs the index in `native-promotion` before verifying the served index and stable redirect. Its non-cancelling concurrency group serializes ISO publication without waiting on native product builds.
- `nightly-compliance.yml` - Runs the existing secretless runtime `/etc`, native publication, bootc publication, and signed-sysext policy contracts every day at 04:30 UTC and on manual dispatch. It has read-only contents access, performs no publication, and uses a non-cancelling concurrency group so a slow run is not hidden by the next schedule.
- `bootc-secure-nightly.yml` / `test-bootc-secure.yml` - The nightly runs secretless fixture contracts only; secure fresh-install E2E belongs to Firn's lab matrix under core ADR-0031. `test-bootc-secure-ci-test.sh` rejects retired Dakota full-window wiring and inventories the remaining Snowfield self-hosted hardware job, which is main-only and manual. `test-bootc-secure.yml`'s push/PR contracts job ignores agent-context stores, top-level Markdown, sysext/image dependency metadata, repository metadata, inert workflow files, and sibling workflows it never reads — but deliberately keeps `docs/**` and `build-images.yml` as triggers (`bootc-secure-docs-test.sh` validates `docs/bootc-secure-*.md`; `check-bootc-publication-guard.sh` validates `build-images.yml`), pinned by `test/workflow-path-filter-test.sh`.
- `check-dependencies.yml` - Weekly check for external dependency updates, creates target-specific PRs with updated checksums or inline OCI build-tool pins (Syft, compatible Cosign v2, chunkah digest). Version-based checks are downgrade-guarded (`ver_gt`, sort -V strictly-newer) — coder deliberately tracks its stable channel (GitHub "latest"), whose version numbers run behind mainline
- `check-packages.yml` - Daily check for external APT package version updates. Its 15-minute job timeout bounds the repository-write token lifetime if an external request stalls. `shared/download/latest-apt-version.sh` bounds each fetch to 60 seconds and 50 MiB compressed, independently caps decompressed `Packages` data at 50 MiB, rejects malformed/truncated indexes, and then creates a sentinel-update PR when versions change.
- `validate.yml` - shellcheck + runtime-/etc-guard (`check-runtime-etc-guard.sh`) + native A/B static/contracts/publication-guard checks + bootc secure publication/artifact/policy/installer/update fixture contracts + expensive-workflow path-filter regression checks + mkosi summary validation on PRs. It runs unfiltered on every push/PR (it is the always-on guard suite and also validates the redirect worker), but cancels superseded runs of the same ref via `concurrency`.
- The runtime `/etc` and duplicate-package guards have standalone TAP fixture suites at `test/runtime-etc-guard-test.sh` and `test/duplicate-packages-test.sh`; keep them wired into `validate.yml` when changing either guard.
- `test-install.yml` - Manual bootc installation test in QEMU/KVM
- `scorecard.yml` - Weekly OpenSSF supply-chain security analysis
## Documentation

**update documentation** After any change to source code, update relevant documentation in CLAUDE.md, README.md and `docs/`. A task is not complete without reviewing and updating relevant documentation.

**docs/ directory** All repository documentation lives in `docs/`, in frostyard/core's four-category shape (frostyard/core ADR-0025; table, index, and conventions in [docs/README.md](docs/README.md)): `docs/adr/` answers *why* (repo-local decisions, immutable once accepted), `docs/design/` answers *how it fits together* (living architecture docs; the entry point is `docs/design/overview.md`, formerly `yeti/OVERVIEW.md`), `docs/specs/` answers *what exactly the contract is* (changed only alongside implementing code), and `docs/plans/` answers *in what order* (phased plans). Read `docs/design/overview.md` and the files it links to for codebase context before performing tasks, and write all of `docs/` to be maximally useful to an AI agent understanding the codebase — detailed architecture, patterns, and decision rationale, naming exact paths and the test that enforces each fact. New docs start from their category's `TEMPLATE.md` and get indexed in `docs/README.md`. Repo-local decisions get an ADR in `docs/adr/` with the next number; decisions binding more than this repo go to frostyard/core, plus a line in [docs/org-adrs.md](docs/org-adrs.md). The `.memory/` inbox (below) drains into these docs. (The former `yeti/` AI-docs directory was folded into `docs/design/`.)

**.memory/ directory** `.memory/` is the repository's committed agent-learning store: `.memory/README.md` documents the conventions and `.memory/corrections.jsonl` is an append-only JSON Lines log of corrections (fields: `date`, `scope`, `correction`, `evidence`, `promoted_to`). Append an entry whenever a session establishes that a previously-held belief about this codebase was wrong, with the evidence that settled it; when a correction hardens into a general rule, promote it into `CLAUDE.md` or the relevant `docs/` page and set `promoted_to`. Never record secrets or personal data there — the directory is committed.

**Delivery metrics** `docs/metrics/README.md` defines the metrics snosi tracks about its own change-delivery process — PR acceptance rate (split by author, to detect drift between agent-authored and human-authored PRs), review iterations to merge, time to merge, and `validate.yml` first-pass rate — each with the exact on-demand `gh`/`jq` query that collects it. There is deliberately no scheduled collector, stored time series, or committed snapshot: the queries are the definition. Its "Acting on the numbers" table routes each adverse signal to a documentation or tooling fix (agent-PR acceptance drop → `AGENTS.md`/`CLAUDE.md`/`docs/`; recurring corrections → `.memory/corrections.jsonl`, then promotion), never to a process reminder.

## Org-wide decisions

Org-level conventions this repo follows are recorded as ADRs in
frostyard/core — see [docs/org-adrs.md](docs/org-adrs.md) for the list that
binds this repo. Change the ADR (in core) before changing behavior it covers.
