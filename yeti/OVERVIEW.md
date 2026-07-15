# snosi Overview

## Purpose

snosi is a bootable container image build system that uses [mkosi](https://github.com/systemd/mkosi) to produce Debian Trixie-based immutable OS images and system extensions (sysexts). It outputs OCI desktop/server images deployed via bootc/systemd-boot with atomic updates, plus EROFS sysext overlays distributed through systemd-sysupdate.

## Outputs

### Desktop Images (OCI, pushed to ghcr.io)

| Image | Kernel | Extras |
|-------|--------|--------|
| **snow** | backports | GNOME desktop, podman, flatpak |
| **snowfield** | linux-surface | GNOME desktop (Surface devices) |

### Server Images (OCI, pushed to ghcr.io)

| Image | Kernel | Extras |
|-------|--------|--------|
| **cayo** | backports | Headless server, podman |

### Native A/B Prototype

The frozen naming/path/policy contract for the eventual production native A/B
products (`cayo-ab`, `snow-ab`, `snowfield-ab` — channel `<ImageId>-ab`,
14-digit `YYYYMMDDHHMMSS` versions, `<ImageId>_<version>_r`/`_v` GPT labels,
`os/native/v1/<product>/x86-64/` R2 paths, sysupdate component topology, key
custody/rotation, capacity, and retention policy) lives in
`docs/native-ab-contracts.md` and is enforced statically by
`test/native-ab-contracts-test.sh` against an allowlisted set of tracked
prototype deviations (`test/native-ab-contracts-allow.txt`). Treat that
document as authoritative over anything below in this section, which
describes the current, pre-freeze prototype.

**Generic output + per-product channels (Phase 3).** `shared/outformat/ab-root/`
is product-neutral: disk/boot mechanics only (`Format=disk`,
`SplitArtifacts=`, `Bootable=yes`, `Initrds=`/`KernelModulesInitrd=no`,
`KernelCommandLine=`, the shared `tree/`, the finalize script). It carries
NO `RepartDirectories=`, NO `*.transfer` files, and NO `KernelModules=`
filter. `shared/native-ab/channels/{cayo,snow,snowfield}/` each carry
the product-specific half: `RepartDirectories=` (6 repart defs,
`<ImageId>_%A_r`/`_v` labels, mkosi-internal `SplitName=`, 1 GiB ESP,
provisional root/verity sizes for snow/snowfield — see
`docs/native-ab-capacities.md`) and `tree/usr/lib/sysupdate.d/` (the 3 OS
transfers, frozen `os/native/v1/<product>/x86-64/` URL, `<ImageId>-ab_`
channel-prefixed `Source MatchPattern=`, `<ImageId>_`-based `Target
MatchPattern=` labels). A profile `Include=`s BOTH the generic fragment and
exactly one channel; `cayo-ab-raw`/`cayo-ab-secure` both include the `cayo`
channel today, `snow`/`snowfield` channels exist and validate statically
but have no consuming profile until Task 3.2. Release channels ship the
complete packaged kernel module/firmware set (`docs/native-ab-contracts.md`
§9) — the virtio-only dev filter that used to live in the shared fragment
now lives only in `mkosi.profiles/cayo-ab-raw/mkosi.conf`, the one dev
fixture permitted to carry it; `cayo-ab-secure` builds with the full set.
Measured against cayo-ab-secure: the full module set barely changes UKI
size (dracut's own non-hostonly selection logic bounds it, not the
mkosi-level module filter) but grows `/usr/lib/firmware`
from 21 MiB to 1019 MiB, leaving cayo's contract-frozen 4 GiB root slot
under 5% headroom instead of the required 20% — flagged as an open
capacity concern for whichever phase creates the real production `cayo-ab`
profile, not fixed here (§12 marks cayo's slot "validated", not
provisional).

`mkosi.profiles/cayo-ab-raw` (renamed from `cayo-ab` in Phase 1; the name
`cayo-ab` is reserved for the eventual secure production posture and
`check-native-publication-guard.sh` hard-fails if `cayo-ab-raw` ever grows a
publication marker) is an isolated, non-production GPT disk prototype. It
uses systemd-boot UKIs, two fixed EROFS root slots with paired dm-verity slots,
a persistent ext4 `/var`, and an overlay `/etc` backed by `/var`. The full raw
disk is the installer artifact; `test/cayo-ab-install-spike.sh` performs a
checksum- and layout-guarded destructive write. The file-target option is only
for QEMU. Do not remove bootc or treat this as supported until signed manifests,
per-install identity, `/var` growth, rollback, and failure-injection tests pass.

The kernel postinstall passes its dracut archive to mkosi through
`$ARTIFACTDIR/io.mkosi.initrd`; the profile disables mkosi's unrelated default
and kernel-module initrd layers. That archive pulls in a oneshot that mounts
`var` and the persistent `/etc` overlay before switch-root. The executable
gates itself on `rd.etc.overlay`; failure must be fatal because a host-service
fallback would break true first-boot identity. Its dracut module explicitly
depends on `systemd-veritysetup`; otherwise `roothash` leaves
`/dev/mapper/root` unresolved. The image finalizer masks both sysupdate timers
in `/etc`; this survives first-boot preset population even though initrd PID 1
starts before the real-root preset policy is visible. Administrators can still
run updates manually or explicitly unmask the timers in the overlay. Separately,
`shared/outformat/ab-root/tree/usr/lib/systemd/{system,user}/` masks the legacy
bootc and nbc updater units (`bootc-update-stage.timer`/`.service`,
`nbc-update-download.timer`/`.service`, and the user-scope
`bootc-update-notify.path`/`.service`) with `/dev/null` symlinks, the same
mechanism used for `systemd-growfs-root.service`: the base image ships those
units unconditionally for the bootc profiles, and on native boot (no
`composefs=` kernel argument) `nbc-update-download`'s
`ConditionKernelCommandLine=!composefs` is true, so nbc would otherwise run
against a GPT layout it does not understand. Upstream's own
`bootc-fetch-apply-updates.*` ships inside the `bootc` deb, which native
profiles never install, so it needs no mask. The installer grows only the final `var` partition. OS transfers use `Verify=yes`,
but unattended updates stay disabled until the dedicated OS OpenPGP keyring
and signed publication pipeline exist. Partition payloads use XZ because the
Debian systemd 257 `systemd-pull` build does not support Zstandard; unsupported
compressed payloads are written verbatim and then fail dm-verity activation.
`test/native-ab-update-test.sh` runs a four-build N through N+3 sequence. It
asserts missing UKI/verity and checksum failures are transactional, verifies a
tampered signed manifest is rejected and a valid ephemeral signature accepted,
boots a one-shot rollback, proves alternating physical slot reuse, and corrupts
unblessed N+3 so systemd-boot exhausts all three tries and falls back to N+2.

The isolated `cayo-ab-secure` profile answers the security-design questions
without changing the baseline test image. Its chain is firmware Microsoft db ->
Debian signed shim -> MOK-signed systemd-boot -> MOK-signed snosi UKI. Debian shim
does not trust a locally signed UKI automatically, so the installer schedules
the certificate for the normal one-time MokManager enrollment; firmware setup
mode and custom db enrollment are explicitly disabled. `SignExpectedPcr=yes`
embeds a signed PCR 11 policy in each UKI. Per-machine LUKS2 `/var` enrollment
uses that authority with no raw PCR binding, allowing signed future and rollback
UKIs while rejecting an arbitrary measured payload. Secure Boot independently
enforces the shim/MOK trust chain. A separately stored recovery passphrase
remains mandatory for TPM clear or motherboard replacement. The installer
encrypts `/var` only after writing the generic raw image and growing its final
partition, preventing cloned volume keys and LUKS UUIDs. The initrd explicitly
unlocks LUKS `/var`, then falls back to raw ext4 for `cayo-ab-raw`. Static config and
real LUKS2 conversion have passed. A clean secure build also proved that the ESP
carries Debian-signed shim, MokManager, and MOK-signed systemd-boot and that the
generated MOK-signed UKI contains the
`.pcrpkey` and `.pcrsig` sections. Pinned mkosi calls local UKI construction
`UnifiedKernelImages=unsigned`; `SecureBoot=yes` signs that output. Incus then
validated MOK enrollment, enforced Secure Boot/kernel lockdown, TPM automatic
unlock through signed PCR 11 policy, TPM replacement failure, and recovery
unlock. The installer leaves the raw-PCR set empty: PCR 7 measured in the
Debian-signed installer differs from PCR 7 after the MOK-signed UKI boots. The
installer also passes an empty `--tpm2-pcrlock=` because systemd otherwise
auto-selects `/run/systemd/pcrlock.json` or `/var/lib/systemd/pcrlock.json` when
present, silently replacing the intended signed-PCR-only policy. The initrd must
explicitly detect LUKS and run `systemd-cryptsetup attach`; GPT auto
discovery does not create `/dev/mapper/var` at this dracut stage.
GRUB was rejected after an end-to-end update installed N+1 correctly but rebooted
N: its generated configuration chainloaded one build-time UKI and ignored the
new Type #2 entry and `+3-0` boot counter. systemd-boot is required for A/B
selection, boot counting, and fallback.
An Incus N+1 run then proved that MOK-signed systemd-boot selects and loads the
new UKI and that its new dm-verity root mounts. Two-token PCR signing-key overlap
was then disproved. Systemd 257 stopped at a stale lower-numbered token. A narrow
systemd 261.1 test fell through when token 0 had a raw-PCR mismatch, but the real
signed-policy mismatch returned `ENXIO` and stopped before valid token 1. Token
iteration is therefore error-dependent, and two independently signed TPM tokens
are not a rotation mechanism.

The validated rotation mechanism dual-signs each transition UKI's four PCR 11
policies with old and new keys while keeping the new key in `.pcrpkey`. The
mkosi `ukify` wrapper is opt-in through `PCR_SIGNING_KEY_PREVIOUS`, accepts only
a filename under `.snosi-private/history/`, derives the active public key from
the sandbox-bound private key, and delegates normal builds unchanged. A fresh
Incus VM with enrolled MOK and vTPM first booted the dual-signed UKI and unlocked
`/var` through old token 0/keyslot 1. After that slot was wiped, the identical
UKI rebooted under enforced Secure Boot and unlocked through new token 1/keyslot
2. The old token must remain until every supported rollback UKI contains the new
signature. `test/native-ab-secure-artifact-test.sh` verifies eight signatures,
four policy digests, both key fingerprints, and the new `.pcrpkey` in addition
to package and initrd coherence. The mutation test
`test/native-ab-secure-artifact-negative-test.sh` requires rejection of a
broken old/new policy pair and an old published `.pcrpkey`.

`test/native-ab-secure-rotation-test.sh` codifies the runtime sequence for an
already MOK-enrolled disposable VM. Its destructive boundary is explicit: the
caller must supply `--yes`, the exact guest machine ID, root SSH, and the external
recovery key. Before modifying LUKS metadata it proves that recovery key with
`cryptsetup --test-passphrase`. It transfers the transition root, verity image,
and UKI through guest-local `systemd-sysupdate`; an ephemeral OpenPGP key signs
the local HTTP manifest and `Verify=yes` is enforced. It then ensures only the
old signed-PCR token exists before the first unattended boot. After that boot it
enrolls the new token, removes the old token by fingerprint-discovered keyslot,
and requires a second unattended boot of the byte-identical UKI with only the
new token. Boot IDs, Secure Boot, lockdown, measured UKI state, roothash, LUKS2
`/var`, token policy, the firmware-reported running UKI hash, and system health
are checked. MokManager enrollment and VM/vTPM creation remain preconditions
rather than automated steps.

`test/native-ab-secure-update-test.sh` extends that proof across three retained
secure builds. N+1 and N+2 must be dual-signed, N+3 must be signed only by the
new key, and the target must begin on N+1 with only the new TPM token. The checked
run installed and booted N+2 and N+3, verified physical slot reuse, rolled back
to N+2, returned to N+3, re-armed its blessed entry as `+3-0`, corrupted its
dm-verity root, observed three N+3 emergency boots through the Incus console,
and required automatic N+2 fallback with N+3 left as `+0-3`. Secure Boot,
measured UKI identity, roothash, persistence, and sole-new-key LUKS policy were
checked after every successful boot.

The run also exposed two lifecycle constraints. First, `.mkosi-private` is
mkosi-owned and `mkosi clean -ff` removes it; durable active and archived PCR
keys belong in gitignored `.snosi-private`. Second, systemd 261's NvPCR anchor
credential embeds the PCR signing key and cannot be migrated. Dual-signed UKIs
can temporarily open an old anchor, but new-only UKIs fail the NvPCR setup and
writer units. `cayo-ab-secure` does not use NvPCR attestation, so its finalize
script masks all packaged NvPCR definitions and the product/login writers while
retaining SRK setup and signed-PCR LUKS unlock. A fresh new-only build and sole
fresh-key TPM token booted without those failures.

`cayo-ab-secure` upgrades the complete exact-version systemd family to Forky
261+ using a profile-only `SandboxTrees=` APT source pinned at priority 50. The
base, `cayo-ab-raw`, and production profiles remain on Trixie.

### Native `/var` Factory State (phase 2)

Every product's disk image ships with an EMPTY `var` partition, always —
this isn't installer behavior, it's baked in at build time. Confirmed by
reading `shared/native-ab/channels/cayo/mkosi.repart/11-root.conf` (Phase 3
moved the per-product repart defs out of the shared `ab-root` fragment; see
"Generic output + per-product channels" below)
(`ExcludeFilesTarget=/var/`, so the root erofs partition never gets any
`/var` content copied in) and `30-var.conf` (no `CopyFiles=` at all, so the
`var` ext4 partition is formatted and left empty). Mounting a built
`cayo-ab-raw` image and checking directly: the root partition's `/var/`
directory exists but is genuinely 0 entries. So the question "what happens
to everything a package build wrote under `/var`" isn't native-specific —
it's true of `cayo`/`snow`/`snowfield` bootc images too, they just don't
notice because ostree's first-deployment `/var` seed (a one-time copy on
FIRST bootc install, never repeated on updates) papers over it. Native has
no such seed at all: the installer's `mkfs` on the `var` partition is
the SAME empty state the image already shipped with.

Two build-time mechanisms address this, both landed together (phase 2,
2026-07-14):

**The audit** (`shared/composition/var-audit.finalize`) is a plain FinalizeScript
with no `.chroot` suffix — it deliberately runs OUTSIDE the chroot, on the
host, so it can just `find $BUILDROOT/var` directly instead of needing
`mkosi-chroot` machinery for what's fundamentally a host-side inventory
task. It's wired as the LAST `FinalizeScripts=` entry in `shared/
composition/cayo/mkosi.conf` and `shared/composition/snow/mkosi.conf` —
those two fragments are shared between bootc profiles (`cayo`, `snow`,
`snowfield`) and native ones (`cayo-ab-raw`, `cayo-ab-secure`), so the SAME
audit and the SAME per-product map run for both output formats. This
mattered concretely for one thing: the dpkg database. Native relocates it
(see below) so the audit sees a single relocation symlink; bootc doesn't
touch it, so the audit sees ~6000 individual real files under
`lib/dpkg/{info,alternatives,triggers,updates}`. One map glob (`lib/dpkg*`,
bare star not `/**`) has to cover BOTH shapes, because the audit also
fails the build on any map glob that matched NOTHING in that specific
build ("stale") — two separate globs (one for the symlink shape, one for
the real-directory shape) would make whichever shape didn't occur in a
given build spuriously flag the other glob as stale. The same dual-shape
trick shows up a few more times in the actual maps (`shared/composition/
cayo/var-outcomes.txt`, `shared/composition/snow/var-outcomes.txt`) for
paths that are sometimes an empty tmpfiles-managed directory and sometimes
hold real generated content (GNOME's `lib/xkb`/`lib/xfonts`, dpkg's own
`lib/AccountsService/users`).

Populating the maps was almost entirely mechanical: build with an empty
map (a single non-matching scaffold line to get past the "map has no
entries" guard), let the audit dump every real unclassified `/var` path in
one shot, cross-reference against every `*.conf` actually present in the
BUILT image's `/usr/lib/tmpfiles.d/` (not just this repo's hand-authored
overlay files — a Trixie desktop's tmpfiles rules are mostly
package-shipped, e.g. `dbus.conf`, `colord.conf`, the real `systemd.conf`
coredump/private rules), classify the rest as `discard` by default. Two
gotchas worth remembering if this needs redoing: (1) several hand-authored
tmpfiles.d files in this repo have no trailing newline, so naive
`cat file1 file2 | awk ...` silently glues the last line of one file onto
the first line of the next and drops real entries — always `echo` a
newline after each file before concatenating; (2) once a map has real
content, the FAST way to validate a change without a 20-40 min real build
is a synthetic scratch buildroot (`mkdir` + `touch` every path from a
saved real unclassified-paths dump) and invoking the script directly:
`BUILDROOT=<scratch> SRCDIR=<repo> IMAGE_ID=<cayo|snow> bash
shared/composition/var-audit.finalize`.

One real gap the audit surfaced and correctly refused to paper over
(flagged during phase 2, fixed since): `/var/lib/aspell/*.rws` (compiled
English dictionaries) are generated by the `aspell-autobuildhash` dpkg
trigger at package-configure time and are NOT dpkg-tracked content
(`dpkg -L aspell-en` lists only the static `/usr/lib/aspell/*.alias`
files). No tmpfiles rule reproduces them, and aspell reaches them through
ABSOLUTE `/usr/lib/aspell/<dict>.rws -> /var/lib/aspell/<dict>.rws`
symlinks in its dict-dir, so on a fresh installer `/var` every dictionary
lookup dangled and spell-checking silently had no dictionaries, with no
error anywhere. Fixed with the same relocation treatment as dpkg below
(chosen over the alternative first-boot regeneration unit: the trigger
only ever runs at package-configure time, so the compiled dictionaries are
build-determined content that belongs in the immutable root — regenerating
per machine would add first-boot cost and divergent state for no benefit);
both maps now classify `lib/aspell*` as `image-metadata`.

**dpkg relocation** (native only): the native-gated block in
`shared/outformat/image/finalize/mkosi.finalize.chroot` (same
`/usr/lib/snosi/native-ab` marker gate as the sysupdate-timer masking
above it) moves `/var/lib/dpkg` to `/usr/lib/sysimage/dpkg` and leaves a
relative symlink behind, before the audit runs. This is safe relative to
mkosi's own package-manifest generation because that runs earlier in the
build (`manifest.record_packages()`, before any `FinalizeScripts`
execute at all — verified by reading `.mkosi/mkosi/__init__.py`'s
`build_image()`), so the manifest always sees the real, unrelocated
database. A matching tmpfiles rule ships native-only at
`shared/outformat/ab-root/tree/usr/lib/tmpfiles.d/00-snosi-dpkg.conf` to
recreate the symlink on a truly fresh installer `/var`. The `00-` filename
prefix is load-bearing, not cosmetic: apt's own `apt.conf` tmpfiles rule
ALSO creates `/var/lib/dpkg` as a plain directory, and `tmpfiles.d(5)`
resolves same-path conflicts across config files by lexicographic filename
order (earliest file wins, everything else is logged as a harmless
"duplicate" error — confirmed locally with `systemd-tmpfiles --create
--root=<scratch>`, exit 0 either way). Rename this file and the wrong rule
silently wins. bootc images never see any of this — the relocation block
only runs when the native marker file exists, verified by inspecting a
built `snow` image directly (`var/lib/dpkg` is a real, non-empty directory
there).

**aspell relocation** (native only, same gated finalize block): moves
`/var/lib/aspell` to `/usr/lib/sysimage/aspell` and leaves the same
relative symlink, so the trigger-created absolute dict-dir symlinks
(`/usr/lib/aspell/<dict>.rws -> /var/lib/aspell/<dict>.rws`) resolve
through the relocation on both the built image and an installed system.
The matching native-only tmpfiles rule is `shared/outformat/ab-root/tree/
usr/lib/tmpfiles.d/00-snosi-aspell.conf`; its `00-` prefix is load-bearing
exactly like the dpkg one, this time against the base image's own
`aspell.conf` rule (`d /var/lib/aspell`). The relocation runs even where
the directory is EMPTY — `cayo` ships no aspell/aspell-en (snow-only
packages), only the bare tmpfiles-created directory — so every native
product has one shape, the shared tmpfiles symlink never dangles, and
each per-product map classifies one shape per output format with a single
dual-shape `lib/aspell*` glob.

`test/native-ab-components-test.sh`'s "Step 1.5: factory /var" block
(added phase 2, runs right after the "no failed legacy updaters" checks,
before the N→N+1 OS update) verifies all of this end to end on a booted
native image: the dpkg and aspell symlinks' exact relative targets,
`/usr/lib/sysimage/aspell` present in the immutable root, that
`dpkg-query -W systemd` and `dpkg-query -W 'linux-image-*'` both resolve
to real versions, that `usr/share/snosi/var-inventory.txt` exists with at
least one `image-metadata` line (including the `/var/lib/aspell` one), and
that none of this introduces a failed unit.

Also fixed along the way, unrelated to `/var` but discovered running a
real `cayo-ab-raw` build for the first time: `shared/manifest/postoutput/
mkosi.postoutput` searched for the built manifest by
`-name "$IMAGE_ID.manifest"`, but mkosi actually names it after `Output=`
(confirmed: "Saving manifest cayo-ab-raw.manifest" in the build log).
Native profiles deliberately keep `ImageId=cayo` (branding, sysext
compatibility) while setting a distinct `Output=cayo-ab-raw` (channel
naming) — see "Native A/B Prototype" above — so this always failed for
`cayo-ab-raw` and never for bootc `cayo`/`snow`/`snowfield`, where
`Output==ImageId`. It silently aborted the ENTIRE build before any output
artifact got moved into place, which is why nobody had noticed: nothing
downstream of a successful `cayo-ab-raw` build had run recently enough to
surface it. Fixed by reading the real `Output=` value from `$MKOSI_CONFIG`
(a JSON summary of the current image's settings available to
`PostOutputScripts`) via `python3` instead of assuming it equals
`$IMAGE_ID`.

### System Extensions (EROFS sysexts, published to Frostyard R2 repo)

1password, 1password-cli, azurevpn, bitwarden, claude-desktop, code-server, coder, debdev, dev, docker, edge, incus, lemonade, nix, podman, tailscale, vscode

## Architecture

### Directory Layout

```
mkosi.conf                  # Root config: distribution, dependencies, build settings
mkosi.version               # Version tag script (date-based, overridden by CI IMAGE_VERSION)
mkosi.clean                 # Clean script (rm -rf output/*)
mkosi.images/               # Image definitions (base + 17 sysexts)
  base/                     # Foundation image: systemd, bootc/ostree (frostyard debs), firmware, core utils
    mkosi.extra/            # Base filesystem overlay (dracut, systemd units/timers, sysupdate, tmpfiles, sysusers)
      usr/lib/sysupdate.<name>.d/  # per-sysext .transfer + .feature component dirs (one pair each, 17 total)
    mkosi.postinst.chroot   # Mount enablement, useradd home dir, bls-garbage-collect removal
    mkosi.finalize.chroot   # Masks systemd-networkd-wait-online
  docker/                   # Each sysext: mkosi.conf + optional extra/scripts
  tailscale/
  ...
mkosi.profiles/             # Transport+kernel selector profiles (5: cayo, snow,
  snow/                     # snowfield, cayo-ab-raw, cayo-ab-secure). Each
  cayo/                     # profile: mkosi.conf + (native only) its own
  ...                       # transport-specific extras.
shared/                     # Reusable fragments composed via Include=
  download/                 # Verified download metadata (sysext/image checksums, package version sentinels) + helpers
  kernel/                   # Kernel variant configs (backports, surface, stock)
  packages/                 # Package set configs (desktop/server bases, bootc runtime deps)
  composition/              # Per-product payload fragments (tree/scripts/packages),
                             # shared verbatim by every transport for that product
    cayo/                   # ExtraTrees + postinst/build/finalize/postoutput scripts + Include packages/cayo
    snow/                   # Same pattern with snow's extra BuildScripts (hotedge, logomenu, bazaar, surface-cert)
  scripts/                  # Shared scripts (common-postinst.sh sourced by all profiles, brew.chroot build script)
  outformat/image/          # bootc OCI output format, buildah/chunkah packaging
  outformat/ab-root/        # Native A/B GENERIC disk output format (product-neutral
                             # disk/boot mechanics only -- no RepartDirectories=,
                             # no *.transfer, no KernelModules=; Phase 3)
  native-ab/channels/       # Per-product native A/B fragments (cayo, snow, snowfield):
                             # RepartDirectories= (6 repart defs, ImageId labels,
                             # 1G ESP) + the 3 OS sysupdate.d transfers (Phase 3)
  sysext/postoutput/        # Shared sysext versioning and manifest logic
  manifest/postoutput/      # Image manifest processing
  snow/                     # Snow desktop: build scripts + tree overlay (consumed by shared/composition/snow)
  cayo/                     # Cayo server: postinstall scripts + tree overlay (consumed by shared/composition/cayo)
mkosi.sandbox/etc/apt/       # External APT repo configs + GPG keyrings
mkosi.tools.sandbox/etc/apt/ # APT config for mkosi's ToolsTree=default bootstrap
.github/workflows/          # CI/CD (build, publish, dependency checks, testing)
test/                       # Bootc install, update, rollback, and VM smoke test framework
docs/                       # Design specs, implementation plans, superpowers
sysextmv.sh                 # Moves sysext output files into output/sysexts/ subdirectory
manifestmv.sh               # Moves manifest files into output/manifests/ subdirectory
check-duplicate-packages.sh # Validates no duplicate packages across mkosi configs (CI pre-build check)
Justfile                    # Build targets (just sysexts, just snow, etc.)
```

### Configuration Composition

mkosi configs compose via `Include=` directives. Each profile pulls in reusable fragments:

Root `mkosi.conf` lists `base` plus all in-repo sysexts for the sysext publishing build. It also sets `ToolsTree=default` and `ToolsTreeSandboxTrees=mkosi.tools.sandbox`; files needed by the tools-tree package manager must go in `mkosi.tools.sandbox/`, while `mkosi.sandbox/` applies to the target image package manager. Both sandbox trees currently carry the same APT retry/timeout hardening. Each `mkosi.profiles/*/mkosi.conf` starts with `Dependencies=` and then `Dependencies=base` to reset mkosi's append-only collection semantics; profile image builds must not inherit the sysext list.

```
Profile (e.g., snow/mkosi.conf)                     # transport+kernel selector only
├── Include: shared/packages/bootc/mkosi.conf       # bootc/ostree runtime deps
├── Include: shared/composition/snow/mkosi.conf     # snow payload (see below)
├── Include: shared/kernel/backports/mkosi.conf     # Kernel variant
├── Include: shared/outformat/image/mkosi.conf      # Output format (directory)
└── Dependencies: base                              # Requires base image

shared/composition/snow/mkosi.conf                  # snow payload, shared by every transport
├── ExtraTrees: shared/snow/tree                    # Filesystem overlay
├── PostInstallationScripts: kernel postinst, then snow.postinst.chroot
├── BuildScripts: brew.chroot, hotedge.chroot, logomenu.chroot, bazaar.chroot, surface-cert.chroot
├── PostOutputScripts: mkosi.postoutput             # Manifest copy
├── FinalizeScripts: mkosi.finalize.chroot          # Pre-output scripts
└── Include: shared/packages/snow/mkosi.conf        # Package set
```

`mkosi.profiles/cayo-ab-raw` and `mkosi.profiles/cayo-ab-secure` (the native A/B
prototypes) `Include=shared/composition/cayo/mkosi.conf` the same way the bootc
`cayo` profile does, instead of restating ExtraTrees/scripts/packages — this is
what makes the cayo brew BuildScript and manifest PostOutputScript apply to
every transport instead of only bootc. They swap `shared/packages/bootc/mkosi.conf`
for nothing (native images never ship bootc) and `shared/outformat/image/mkosi.conf`
for TWO fragments: `shared/outformat/ab-root/mkosi.conf` (generic disk/boot
mechanics) AND `shared/native-ab/channels/cayo/mkosi.conf` (cayo's
`RepartDirectories=` + OS transfers — Phase 3 split; see "Generic output +
per-product channels" in CLAUDE.md). Because mkosi accumulates list settings
(`Packages=`, `FinalizeScripts=`, `ExtraTrees=`, `RepartDirectories=`, ...) in
`Include=` encounter order across the whole resolved config, the relative
order of `Include=` lines in a profile is significant whenever more than one
fragment sets the same key — verify any composition change with a `mkosi
cat-config`/`summary` diff, not just a source read.

The app-bundling "loaded" variants (snowloaded, snowfieldloaded, cayoloaded) were retired in 2026-07: every app they baked in (Edge, VS Code, Bitwarden, Azure VPN, Incus, Docker) is delivered as a sysext instead. The shared `packages/{edge,vscode,bitwarden,azurevpn}` fragments now serve only the sysext builds.

### Script Pipeline

Scripts execute in order per image build:

1. **BuildScripts** (in chroot) — Download/install items not available as packages: Homebrew, GNOME extensions, Surface secure boot cert. (bootc and ostree are NOT built here — they install as debs from the Frostyard APT repo, built by frostyard/bootc-debian; see [build-pipeline.md](build-pipeline.md).)
2. **PostInstallationScripts** (after packages) — Common logic via `shared/scripts/common-postinst.sh` (OS release branding, package list generation, cleanup, sysext infra), then profile-specific steps (GDM enablement, package relocation /opt → /usr/lib). Mount enablement and useradd home dir are handled by the base image's own postinst script.
3. **FinalizeScripts** (pre-output) — Remove ephemeral dirs (/boot, /home), create /sysroot and /nix mountpoints, set machine-id to `uninitialized` (real first-boot semantics: presets re-apply at first boot), strip unit enablement symlinks from /etc (recreated at first boot as runtime state; manifest in /usr/share/snosi/), clear SSH keys, compile GLib schemas, set file xattrs for chunkah
4. **PostOutputScripts** (after image creation) — Manifest processing, sysext versioned renaming

See [build-pipeline.md](build-pipeline.md) for details.

### Immutable Filesystem

```
/usr/       Read-only. All binaries, libraries, configs.
/etc/       Overlay on /usr/etc. Base from image, user changes persist.
/var/       Persistent, writable. Logs, state, container storage.
/home/      Persistent (/var/home bind). User data.
/opt/       Bind mount to /var/opt. Writable but shadowed by sysext overlays.
```

**Critical pattern:** Packages installing to `/opt` must be relocated to `/usr/lib/<package>` at build time with symlinks from `/usr/bin`. See [build-pipeline.md](build-pipeline.md#package-relocation).

### bootc Update Staging

The base image disables upstream `bootc-fetch-apply-updates.timer` and enables `bootc-update-stage.timer` instead. The custom `/usr/libexec/bootc-update-stage` script pulls the followed image with `podman`, stages it with `bootc switch --transport containers-storage`, and leaves the deployment to apply on the next normal reboot. This preserves download-only update semantics and avoids the current registry-transport composefs pull failure documented in the update validation plan.

### Sysext Architecture

Sysexts overlay `/usr` at runtime. They cannot modify `/etc` or `/var` directly. Each in-repo sysext:

- Has `Overlay=yes`, `Format=sysext`, `Dependencies=base`, `BaseTrees=%O/base`
- Sets `KEYPACKAGE` env var for version extraction from manifest
- Uses shared postoutput script for versioned naming
- Needs matching `.transfer` + `.feature` files in base image's own component directory, `usr/lib/sysupdate.<name>.d/` — never in the shared `usr/lib/sysupdate.d/` target, which is reserved for native-profile OS transfers (systemd-sysupdate version-locks everything in one definitions directory, so mixing sysext and OS versions there would corrupt version resolution)
- Configs needed in `/etc` go through `/usr/share/factory/etc` + systemd-tmpfiles

Every sysext built in this repository has a matching component directory here.

**Release-ordering constraint:** this per-component sysupdate layout requires
`frostyard-updex` component discovery (branch `feat/sysupdate-components`);
do not merge/publish base images built after this migration until that updex
release is published to the Frostyard APT repo, or an old updex silently
fails to discover any component-scoped sysext.

**Accepted risk — unsigned sysexts on native installs:** on native A/B
production candidates (`cayo-ab`, `snow-ab`, `snowfield-ab`), sysext
transfers keep `Verify=false` and every `.feature` defaults to
`Enabled=false`. This is an explicit accepted risk until signed
per-component metadata ships for sysexts; do not enable sysexts by default
on a native production candidate before that lands.

See [sysexts.md](sysexts.md) for details.

## Key Patterns

### Verified Downloads

Direct external downloads are pinned with URL + SHA256 in target-specific
metadata files under `shared/download/`:

- `sysext-checksums.json` — direct downloads consumed by sysext builds
- `image-checksums.json` — direct downloads consumed by OCI profile builds

Scripts use `verified_download(key, output_path)` from
`shared/download/verified-download.sh`; by default it searches both checksum
files. CI workflow `check-dependencies.yml` detects updates weekly and opens
target-specific PRs so sysext-only changes do not spend the OCI image matrix.

Package versions for selected APT-based sysext externals (VSCode `code`,
Docker, 1Password) are tracked separately in
`shared/download/package-versions.json`, checked daily by `check-packages.yml`.
This file is only a rebuild sentinel; mkosi still resolves packages from APT.

Current sysext checksum-managed downloads are 1Password desktop, Bitwarden,
code-server, coder, Azure VPN, and Microsoft Edge. Current image checksum-managed downloads are Homebrew
install script, Surface secure boot certificate, Hotedge, Logomenu, and Bazaar
Companion. Current APT version tracking covers `code`, `docker-ce`,
`1password-cli`, and `claude-desktop`; Edge is checksum-managed because the build installs a patched
downloaded `.deb`. `code-server` is a sysext exception: it is installed by
`mkosi.images/code-server/mkosi.postinst.chroot` with `verified_download()` +
`dpkg -i`, while `KEYPACKAGE=code-server` still drives version extraction from
the merged dpkg database.

### User Service Enablement in Chroot

`systemctl --user enable` does not work in mkosi chroot (no D-Bus session). Workaround:

```bash
mkdir -p /etc/systemd/user/<target>.wants
ln -sf /usr/lib/systemd/user/<service> /etc/systemd/user/<target>.wants/<service>
```

**Caution:** Check `Conflicts=` directives between related services. For example, `gnome-remote-desktop-headless.service` conflicts with `gnome-remote-desktop.service` — enabling both causes failures. When creating symlinks, explicitly remove any conflicting service symlinks.

### OCI Image Packaging

Images are built as directories, then packaged into OCI via `buildah-package.sh` using `buildah mount` + `cp -a` + `buildah commit`. This avoids `buildah COPY` which drops SUID bits (buildah#4463). Layer optimization is done via `chunkah-package.sh`.

CI sets `TMPDIR=/mnt/tmp` before mkosi/buildah/chunkah work because hosted runners have more free space on `/mnt` than on `/`; large loaded variants can exhaust `/var/tmp` if this is omitted.

### Shell Script Conventions

- `set -euo pipefail` at the top of all scripts
- `.chroot` extension for scripts running inside chroot
- External downloads via `verified_download()` only
- Pin external URLs to specific versions, never `latest`

### Runtime `/etc` Mutations Are Forbidden

Files that ship in runtime payload directories (`mkosi.extra/` and `shared/**/tree/`) must not delete or rewrite enablement state under `/etc` at runtime. On bootc/composefs installs, deleting shipped `/etc` paths can make the live `/etc` merge fail during `bootc-finalize-staged`, causing staged updates to be discarded while update logs still look successful.

Use build-time enablement/presets for desired service state. For run-once runtime units, gate with a `/var` marker such as `ConditionPathExists=!/var/lib/<unit>.done` plus an `ExecStartPost=touch ...` marker instead of `systemctl disable`/`enable`/`preset` from inside the guest. CI enforces this with `check-runtime-etc-guard.sh`; a flagged line needs a trailing `# etc-guard-allow: <reason>` only when the mutation is provably outside shipped `/etc` state.

## Configuration

### Build Requirements

- just, git, python3, root/sudo access
- mkosi is auto-bootstrapped by the Justfile into a gitignored `.mkosi/` checkout at the commit pinned by the `systemd/mkosi@<sha>` action in `.github/workflows/build.yml` (parsed at runtime, so local always matches CI); override with `just mkosi=/usr/bin/mkosi <target>`
- For CI: buildah, skopeo, podman, cosign, syft, oras

### Build Commands

```bash
just                    # List targets
just sysexts            # Build base + all 17 sysexts
just snow               # Build snow desktop
just snowfield          # Build snowfield (Surface)
just cayo               # Build cayo server
just clean              # Remove build artifacts
just test-install       # Run bootc install test
just run-qemu           # Run image in QEMU
```

All `just` targets run `mkosi clean` first (clean build every time).

### Key Environment Variables

| Variable | Where Set | Purpose |
|----------|-----------|---------|
| `KEYPACKAGE` | Sysext mkosi.conf `[Output]` | Package name for sysext version extraction |
| `IMAGE_ID` | Profile mkosi.conf | Image identifier (snow, cayo, etc.) |
| `IMAGE_VERSION` | mkosi.version (timestamp) | Build version (YYYYMMDDHHMMSS) |
| `BUILD_ID` | CI environment | Injected into os-release |
| `BREW_TREE` | Profile mkosi.conf | Tree path for Homebrew tarball output (e.g., `shared/snow/tree`) |
| `TMPDIR` | CI workflows / local env | mkosi, buildah, and chunkah workspace location; CI points it at `/mnt/tmp` for disk headroom |

### External APT Repositories

Target-image APT repositories are configured in `mkosi.sandbox/etc/apt/` with GPG keyrings. APT retry and timeout settings live in both `mkosi.sandbox/etc/apt/apt.conf.d/80-snosi-network-retries.conf` and `mkosi.tools.sandbox/etc/apt/apt.conf.d/80-snosi-network-retries.conf`; the latter is required because mkosi's default tools tree does not inherit the target-image sandbox.

- 1Password — CLI tool
- Debian Backports — Newer kernel + firmware + mesa
- Debian Griffo.io (debian.griffo.io) — Additional Debian packages
- Docker (docker.com) — Docker CE packages
- Frostyard (repository.frostyard.org) — Custom packages: bootc, libostree-1-1 (built by frostyard/bootc-debian), nbc, chairlift, updex, igloo, intuneme, snow-first-setup.
- Linux Surface (pkg.surfacelinux.com) — Surface kernel + tools
- Microsoft Edge (packages.microsoft.com) — Edge browser
- Microsoft VSCode (packages.microsoft.com) — VS Code editor
- Tailscale (pkgs.tailscale.com) — VPN client

## Developer Utilities (repo root)

- `compare-images.sh` — diffoscope-style comparison of two OCI images (extracts layers, handles whiteouts, reports file-level differences); dev tool, not used by CI
- `packagediff.sh` — diffs the build manifest against the running system's package list (`/usr/share/frostyard/<id>.packages.txt`)
- `check-duplicate-packages.sh` / `check-profile-dependencies.sh` — config sanity checks, run by CI
- `check-native-publication-guard.sh` — static gate for `docs/native-ab-contracts.md` §15: requires any profile literally named `cayo-ab`/`snow-ab`/`snowfield-ab` to carry shim/Secure Boot/PCR-signing/NvPCR/pubring markers and no `KernelModules=` filter, and hard-fails `cayo-ab-raw` if it ever gains a publication marker; run by CI, exits 0 with a note today (no production-named profile exists yet)

## CI/CD

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `build.yml` | Push/PR/dispatch | Build base + sysexts, publish to R2 |
| `build-images.yml` | Push/PR/repository_dispatch/dispatch | Matrix build of 6 profiles, push OCI to ghcr.io, generate SBOMs, sign with Cosign |
| `check-dependencies.yml` | Weekly (Mon 9am UTC) | Check external download updates, create PRs |
| `check-packages.yml` | Daily (8am UTC) | Check APT package version updates, create PRs |
| `validate.yml` | PR/push/dispatch | shellcheck + mkosi summary validation + profile dependency guard |
| `test-install.yml` | Manual dispatch | Bootc install test in QEMU/KVM |
| `scorecard.yml` | Weekly | OpenSSF supply-chain security analysis |

See [ci-cd.md](ci-cd.md) for details.

## Testing

The `test/` directory contains bootc installation and update test frameworks:

- `bootc-install-test.sh` — Orchestrator: loads OCI image, runs bootc install to-disk, boots in QEMU, runs tests via SSH
- 4-tier test suite: installation validation → service health → sysext validation → smoke tests
- `bootc-update-test.sh` — Orchestrator for update hops and optional rollback: installs a starting image, runs `bootc switch` to one or more target refs, reboots between hops, and verifies deployment slot continuity plus `/var` and `/etc` persistence markers

See [testing.md](testing.md) for details.

## Detailed Documentation

- [Build Pipeline](build-pipeline.md) — Script execution, package relocation, OCI packaging
- [Sysexts](sysexts.md) — Sysext creation, constraints, update mechanism
- [CI/CD](ci-cd.md) — Workflow details, publishing, dependency automation
- [Testing](testing.md) — Test framework architecture and tiers
