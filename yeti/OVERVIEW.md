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
root/verity sizes validated against real native builds for all three
products as of Task 3.2 — see
`docs/native-ab-capacities.md`) and `tree/usr/lib/sysupdate.d/` (the 3 OS
transfers, frozen `os/native/v1/<product>/x86-64/` URL, `<ImageId>-ab_`
channel-prefixed `Source MatchPattern=`, `<ImageId>_`-based `Target
MatchPattern=` labels). A profile `Include=`s BOTH the generic fragment and
exactly one channel; `cayo-ab-raw` and the production `cayo-ab` both include
the `cayo` channel, `snow-ab` includes `snow`, and `snowfield-ab` includes
`snowfield` (Task 3.2 gave every channel a real consuming profile). Release
channels ship the
complete packaged kernel module/firmware set (`docs/native-ab-contracts.md`
§9) — the virtio-only dev filter that used to live in the shared fragment
now lives only in `mkosi.profiles/cayo-ab-raw/mkosi.conf`, the one dev
fixture permitted to carry it; the three production profiles build with the full set.
Measured against the former `cayo-ab-secure` spike (Phase 3) and reconfirmed
against the real `cayo-ab` production build (Task 3.2, 999364 vs 999267
erofs blocks — a small difference from profile-identity/manifest metadata,
not payload): the full module set barely changes UKI
size (dracut's own non-hostonly selection logic bounds it, not the
mkosi-level module filter) but grows `/usr/lib/firmware`
from 21 MiB to 1019 MiB, which left cayo's then-frozen 4 GiB root slot
under 5% headroom instead of the required 20% (spare/total-slot
definition, §12). Fixed in a Phase 3 follow-up: cayo's root slot is now
5 GiB (~23.8% headroom against the same measured content), with the
verity slot scaled in step from 128 MiB to 256 MiB per the verity:root
ratio rule. `snow-ab` (~5.29 GiB content, ~33.8% headroom against 8 GiB)
and `snowfield-ab` (~5.64 GiB content, ~29.5% headroom against 8 GiB) were
both measured for real in Task 3.2 too, confirming the 8 GiB/256 MiB slot
sizing that had been provisional since Phase 3. See
`docs/native-ab-capacities.md` for the full measurement and
headroom-definition writeup.

**SkeletonTrees fix for early kernel-postinst dracut runs (Task 3.2):** the
`ExtraTrees=` shadow of `30-bootc-standard.conf` (above) only takes effect
AFTER package installation (mkosi build order: `install_skeleton_trees` ->
`install_distribution` -> `install_extra_trees`). `snowfield-ab`'s first
build failed outright — `dracut[E]: Module 'bootc' cannot be found` — because
the `linux-image-surface` package runs its `/etc/kernel/postinst.d/dracut`
hook SYNCHRONOUSLY during its own postinst (Debian's `linux-image-amd64`
defers the equivalent hook via a dpkg trigger and never hits this window),
so it saw the base image's un-shadowed copy (still requesting the `bootc`
module) before the shadow ever landed. Fixed by pulling the SAME canonical
file in a second time via `SkeletonTrees=` in
`shared/outformat/ab-root/mkosi.conf` (no duplication, one source, two
composition mechanisms), which runs before packages install. Reconfirmed
harmless for `cayo-ab`/`snow-ab` by rebuilding both with the fix.

**Publication naming pipeline (Task 3.3).**
`shared/native-ab/publish/prepare-native-publication.sh` turns one built
native profile's mkosi outputs into the frozen `docs/native-ab-contracts.md`
§4 public names. It takes an mkosi output directory and a profile's
`Output=` value (e.g. `cayo-ab`), reads product (`ImageId`) and version from
that profile's own JSON manifest (`.config.name`/`.config.version` — version
validated against the frozen `^[0-9]{14}$` grammar), and validates the given
`Output=` value equals `<product>-ab` — a real safety property, not a
convention: it is the mechanism that refuses to "publish" the never-shipped
`cayo-ab-raw` dev fixture, independent of the publication guard's static
config-marker check. Root/root-verity PARTUUIDs come from `sfdisk --json` on
the built disk image, located by GPT partition name (`<product>_<version>_r`
/`_v`, §3) — this needs neither a loop device nor root, confirmed against a
real 16 GiB disk. `--xz` compresses root/root-verity/disk with `xz -T0` and
appends `.xz` (the real, frozen §4 form); without it the same base names are
produced unsuffixed, an explicitly-not-frozen fast path used only by the
QEMU test fixtures (below) and local iteration. Output also includes an
unsigned `SHA256SUMS` (signing is the Phase 7 promotion step) and a
`publication-info.json` pipeline record (product/channel/version/PARTUUIDs/
artifact sizes/source commit). Deliberately NOT wired into
`PostOutputScripts=`: doing so is technically possible (post-output scripts
get `$OUTPUTDIR` fully populated, and `sfdisk --json` needs no root — both
verified directly), but the script's job is to copy the 5-23 GiB
root/root-verity/disk artifacts a second time, and `PostOutputScripts=` runs
on every single `mkosi build` — every local dev iteration and every profile
in the `build-images.yml` matrix — which would silently double per-build
disk consumption on every build regardless of whether it is ever published,
the same failure shape as the recorded "CI Disk Exhaustion" incident. Kept
manual, intended for the `build-*` jobs in `.github/workflows/build-native-
images.yml` (Phase 7), which control their own disk budget deliberately (see
"Native build/publish workflow (Phase 7)" below). `test/native-publish-test.sh`
exercises the naming/derivation logic against a synthetic fixture (`truncate`
+ `sfdisk` script mode for a fake GPT, no root, no image build);
`test/native-ab-contracts-test.sh` also runs it so a naming drift fails that
same static gate. `test/native-ab-update-test.sh` and
`test/native-ab-components-test.sh` accept `PROFILE`/`IMAGE_ID`/`CHANNEL`
env overrides (default `cayo-ab-raw`/`cayo`/`cayo-ab`, byte-equivalent to
their prior hardcoded behavior); `native-ab-components-test.sh`'s N+1 OS
update fixture is now generated by running the profile's build output
(symlinked under its `$CHANNEL` name, since the publisher's own name-equals-
channel check would otherwise reject the never-published `-raw` profile
name) through the publisher with `--xz`, so that leg of the test exercises
the real public contract end to end instead of hand-rolled fixture naming.

**Publication and signing pipeline (Phase 7).** `shared/native-ab/publish/`
gained four more scripts on top of `prepare-native-publication.sh`:
`publish-candidate.sh`, `verify-remote.sh`, `promote.sh`, `withdraw.sh`, plus
a shared `publish-lib.sh` and `generate-sbom.sh`. All are `--help`'d,
`set -euo pipefail`, shellcheck-clean, and share one `dest`-addressing
convention (`publish-lib.sh`'s header): a plain local directory for
rehearsal, or `rclone:<remote>:<bucket>[/prefix]` for a real remote — every
script appends the frozen `os/native/v1/<product>/x86-64/` path itself, so
`dest` is always the bucket/origin root. `verify-remote.sh`/`promote.sh`
additionally take an HTTP `base-url` (the public read path) separate from
`dest` (the write path) — writes go through `rclone`, verification/signing
read back over the same HTTP path a real client would use. Local-rehearsal
writes are atomic (temp file + rename, same pattern as
`prepare-native-publication.sh`) and record Cache-Control *intent* as a
`<name>.meta.json` sidecar (a plain directory/http.server origin can't be
told to emit custom headers); real-remote uploads set the header directly
via `rclone --header-upload`.

`generate-sbom.sh` closes the `docs/native-ab-contracts.md` §4 gap
(`<channel>_<version>.sbom.spdx.json` was previously never produced):
rather than shelling out to `syft` (which was investigated and rejected —
see the script's own header — mkosi's package manifest.json already has
everything needed, syft would need root/a mounted tree to scan a raw disk
image and isn't installed on build hosts by default), it generates a real
SPDX 2.3 JSON document directly from the same manifest.json
`prepare-native-publication.sh` already reads, with one root "operating
system" package CONTAINS-related to every installed deb package (purl
references, SPDXID charset-sanitized package names). No network, no root,
no external tool. `prepare-native-publication.sh` now writes the SBOM
unconditionally and lists it as a 6th `SHA256SUMS` entry / `artifacts.sbom`
publication-info.json field.

`publish-candidate.sh` uploads to a per-version candidate sub-path
(`.candidate/<version>/`, this repo's own convention, never a final name).
`verify-remote.sh` independently re-checks every candidate object over HTTP:
size, full-GET SHA-256, and >=2 byte-range GETs compared against the same
range read locally — this is what caught that plain `python3 -m
http.server`'s `SimpleHTTPRequestHandler` has **no Range support at all**
(confirmed against the Python 3.13 stdlib source: every ranged GET silently
returns the full 200 body), which would have made the range check
meaningless. `test/lib/range-http-server.py` is a ~100-line stdlib-only
substitute that actually honors `Range:` (206 Partial Content, streamed, not
loaded into memory — matters at multi-gigabyte artifact sizes) and is what
both `verify-remote.sh`'s own local rehearsal and
`test/native-ab-publication-test.sh` serve the origin with.

`promote.sh` is the one script that touches the private signing key
(`--signing-key <file>`, imported into an ephemeral 0700 `GNUPGHOME` removed
on exit, or `--gnupghome <existing homedir>` — never a hardcoded path). It
copies verified candidates to final names, then **re-downloads every final
object over HTTP and hashes the downloaded bytes** to build the new
`SHA256SUMS` (never trusts local disk or the copy step, per the plan's
"Generate SHA256SUMS over the exact bytes served" step — this would catch a
copy that silently truncated/corrupted on the storage backend). Before
overwriting an existing signed index, it archives the outgoing pair to
`.history/<version>/` (this repo's own retention mechanism, not part of the
frozen public contract) — this is what `withdraw.sh` restores from later.
Upload order is hardcoded: `SHA256SUMS.gpg` first, `SHA256SUMS` last, both
`Cache-Control: no-store` — verified live via nanosecond `stat -c %y`
comparison in both the logic-level smoke test and the QEMU rehearsal (plain
`%Y` integer-second mtimes were too coarse to observe the ordering on a fast
local run). `--purge-hook <cmd>` is the documented Cloudflare-purge
extension point, a no-op locally.

`withdraw.sh` `gpgv`-verifies an archived `.history/<version>/` pair against
the pubring **before touching anything live**, and refuses outright (exit 1,
nothing written) on a missing pair or a cryptographic mismatch — it never
creates a new signature, only replays an already-signed one, per the plan's
"restore ... using the same signature-first, manifest-last sequence".

**Stable native-installer download.** The one moving user-facing URL,
`/isos/native/v1/snosi-native-installer-latest-x86-64.iso`, is implemented by
the isolated `workers/native-installer-redirect/` Cloudflare Worker. It reads
the strongly-consistent R2 `isos/native/v1/SHA256SUMS` through a binding,
strictly selects the one frozen installer filename, `head()`s the target, and
returns `302` with `Cache-Control: no-store`; malformed/ambiguous state is a
`503`, never a guessed version. It carries NO pointer of its own and never
streams the ~700 MB ISO. This makes `promote.sh`'s existing manifest-last write
the atomic redirect switch and makes `withdraw.sh`'s restored manifest the
automatic rollback. The Worker does not verify OpenPGP: discovery and trust are
deliberately separate, and clients still authenticate `SHA256SUMS.gpg` then the
ISO hash. `.github/workflows/deploy-native-installer-redirect.yml` deploys edge
code independently; `verify-installer-redirect.sh` is the mandatory
post-promotion/post-withdrawal probe.
The production binding is the existing `frostyardrepo` bucket. The deploy job
parses `wrangler.jsonc`, compares it with the repository's `NATIVE_R2_BUCKET`
secret, and verifies the bucket exists before deployment; this is specifically
to defeat Wrangler 4's automatic provisioning of typoed/missing resources.

`test/native-ab-publication-test.sh` is the full local end-to-end rehearsal:
two real `cayo-ab-raw` builds (N, N+1) published under the real `cayo-ab`
channel name (the by-now-established "stage build outputs under
`$CHANNEL`-named symlinks" trick, since `prepare-native-publication.sh`
validates its channel *argument*, not which mkosi profile physically
produced the bytes — see `test/native-ab-updateux-test.sh`'s header for the
same pattern). Deliberately uses `cayo-ab-raw` (no Secure Boot/MOK) rather
than the secure `cayo-ab` profile: `shared/native-ab/keys/README.md`
documents that the update-signing pubring ships at `/usr/lib/systemd/import-pubring.gpg`
on **every** native A/B image via the shared `shared/outformat/ab-root/
mkosi.conf` fragment, `cayo-ab-raw` included, so booting it and never
touching `/etc/systemd/import-pubring.gpg` exercises the
"verify a promotion signature against the stock shipped pubring" trust path
without paying for OVMF Secure Boot + MOK enrollment (orthogonal Phase 6
machinery). CAVEAT (learned from the 2026-07-17 `.pgp` outage, commit
91718d7): this is NOT byte-identical to a production profile's trust path —
`cayo-ab-raw` runs Trixie's systemd 257, whose vendor keyring is the OLD
`/usr/lib/systemd/import-pubring.gpg` name, while the production profiles'
Forky systemd 261 reads `/usr/lib/systemd/import-pubring.pgp` with no
`/usr` `.gpg` fallback. This leg therefore proves the promotion-signature
half (signed index vs. shipped ring) but could not, and did not, catch
shipping the ring under only the 257 name; the 261 `.pgp` vendor path is
covered by `test/native-ab-secure-boot-test.sh`, which bakes an ephemeral
ring over both `/usr` names at build time and runs with no `/etc` override
(see `yeti/testing.md`). The QEMU leg: boot N, `/etc/
sysupdate.d` origin override (same documented whole-file-replacement
mechanism as `native-ab-updateux-test.sh`) pointed at the local rehearsal
origin, stage promoted N+1 via `snosi-sysupdate-stage`, reboot, assert N+1.
Then three fail-closed tamper cases, each built from a fabricated
higher-version filename set hardlinked to N+1's own real, already-verified
bytes (no 3rd multi-gigabyte build — the same trick `native-ab-updateux-
test.sh`'s tamper case uses) run through the *real* candidate/verify/promote
pipeline before being corrupted in the one specific way each case names: (a)
a payload byte flipped in the already-promoted final object (signature and
manifest still match each other, just not the actual bytes on disk); (b) the
manifest rolled back to N+1's own real (just-archived) `SHA256SUMS` content
while the just-uploaded signature for the fake version stays — a signature
that covers different bytes than what `SHA256SUMS` now contains, i.e. `gpgv`
itself rejects the pair even before any guest is involved; (c) a full
promotion signed with a throwaway, never-imported-anywhere key. All three
leave the guest on N+1 (`outcome=failed`, no staged semaphore, no partition
labeled with the fake version). The test finishes by withdrawing back to
N+1's own archived pair and confirming the guest's stager reports
`outcome=current`. Not wired into `validate.yml` (same reason none of the
other QEMU harnesses are — it needs sudo, KVM, and builds real images). The
static logic (candidate/verify/promote/withdraw against a synthetic
fixture, no image build, no real R2) is a separate, fast, CI-wired script:
`test/native-publication-pipeline-test.sh`, run from the same `shell-lint`
job in `validate.yml` as `test/native-publish-test.sh`.

**Native build/publish workflow (Phase 7).**
`.github/workflows/build-native-images.yml` automates the whole procedure
above against real GitHub Actions runners. It is deliberately a thin
caller -- every real step is a call into one of the scripts above,
`shared/native-ab/ci/bootstrap-mkosi.sh` (below), or `test/native-ab-secure-
artifact-test.sh` / `test/snowfield-artifact-test.sh`; no build/publish
logic lives directly in the YAML. Jobs: `pin-check` (governance gate, see
below) -> `prepare` (assigns one version/revision shared by every product
this run, mirroring `build-images.yml`'s own version tag) -> `build-cayo` /
`build-snow` / `build-snowfield` (independent jobs, not a matrix, each
gated on the `native-build` protected GitHub environment which holds the
Secure Boot/MOK and PCR signing private keys as environment secrets --
written to `mkosi.key`/`mkosi.crt`/`.snosi-private/pcr-signing.{key,crt}`
immediately before the one `mkosi build` step that needs them, removed by
an `if: always()` cleanup step right after) -> `test-public-origin` (one
matrix job, `verify-remote.sh` against the REAL public URL, not the write
path) -> `promote-cayo` / `promote-snow` / `promote-snowfield` (independent
jobs gated on the `native-promotion` protected environment, which holds the
OpenPGP update-signing key; runs `promote.sh`) -> `release-notes`
(non-blocking). Only small pipeline records (`publication-info.json`,
`SHA256SUMS`, tiny marker files) ever cross job boundaries as Actions
artifacts -- the multi-gigabyte payload objects go straight from a
`build-*` job's runner to R2 via `rclone` and are re-verified over HTTP by
later jobs, never re-uploaded as Actions artifacts. Each `test-public-
origin` matrix leg and each `promote-*` job independently downloads its own
product's upstream artifact with `continue-on-error: true` and no-ops
(does not fail) when it is absent, so one product's build/verify failure
never blocks another's promotion -- the same pattern `build-images.yml`'s
own `release` job already uses for its `snow-tag` artifact. Trigger is
`workflow_dispatch` + main-branch `push` ONLY (interim protected-builder
rule, `docs/native-ab-publication.md` "Interim protected-builder
constraints": until mkosi supports split final assembly from signing, the
`build-*` jobs themselves ARE the protected builder). A single
`concurrency` group with `cancel-in-progress: false` prevents two runs from
interleaving `promote.sh` invocations. **Production R2 upload has not been
exercised through this workflow** -- see `docs/native-ab-publication.md`'s
"CI publication flow" / "First production publication checklist" sections
for the full secret inventory and what remains before the first real run.

`shared/native-ab/ci/bootstrap-mkosi.sh` and `shared/native-ab/ci/check-
mkosi-pin.sh` implement "Mkosi Pin Governance" (the plan: "CI must derive
local and workflow mkosi from the same commit and fail if they diverge").
`bootstrap-mkosi.sh <target-dir>` is now the ONE implementation of "fetch
mkosi at the commit build.yml's `systemd/mkosi@<sha>` action pins" --
Justfile's `ensure-mkosi` recipe delegates to it instead of carrying its
own copy of the same six lines, and `build-native-images.yml`'s `build-*`
jobs call it directly (no `uses: systemd/mkosi@<sha>` action, so there is
no second literal pin that could drift from build.yml's). `check-mkosi-
pin.sh` is the explicit regression guard: it asserts build.yml's pin is a
full 40-character commit SHA, that `build-native-images.yml` carries no
conflicting `systemd/mkosi@<sha>` literal of its own, and (when a `.mkosi/`
checkout is present) that its HEAD matches the pin exactly. Both scripts
are dry-runnable with no network/build required for the no-checkout-yet
case; `pin-check` runs `check-mkosi-pin.sh` before any build job starts,
and each `build-*` job re-runs it right after its own bootstrap step.

`mkosi.profiles/cayo-ab-raw` (renamed from `cayo-ab` in Phase 1; the name
`cayo-ab` now names the production secure posture — see below — and
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
profiles never install, so it needs no mask. The same native tree masks
`plymouth-read-write.service`: native root is permanently read-only EROFS, and
the distro unit's infinite-timeout `plymouth update-root-fs --read-write`
occasionally blocked before `sysinit.target` on minisnow (2026-07-17). PID 1
continued feeding the hardware watchdog and the kernel handled Magic SysRq,
but no later target was dispatched; every failed boot lacked the unit's
completion message while successful boots completed it in 40-53 ms. The
installer grows only the final `var` partition. OS transfers use `Verify=yes`,
but unattended updates stay disabled until the dedicated OS OpenPGP keyring
and signed publication pipeline exist. Partition payloads use XZ because the
Debian systemd 257 `systemd-pull` build does not support Zstandard; unsupported
compressed payloads are written verbatim and then fail dm-verity activation.
`test/native-ab-update-test.sh` runs a four-build N through N+3 sequence. It
asserts missing UKI/verity and checksum failures are transactional, verifies a
tampered signed manifest is rejected and a valid ephemeral signature accepted,
boots a one-shot rollback, proves alternating physical slot reuse, and corrupts
unblessed N+3 so systemd-boot exhausts all three tries and falls back to N+2.

The shared `shared/native-ab-secure/mkosi.conf` fragment (`Include=`d by the
three production profiles `cayo-ab`, `snow-ab`, `snowfield-ab`; the former
standalone `cayo-ab-secure` spike profile that originated this content was
retired in Task 3.2) answers the security-design questions
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
writer units. None of the three production profiles use NvPCR attestation, so the
shared fragment's finalize
script masks all packaged NvPCR definitions and the product/login writers while
retaining SRK setup and signed-PCR LUKS unlock. A fresh new-only build and sole
fresh-key TPM token booted without those failures.

The shared `shared/native-ab-secure/mkosi.conf` fragment upgrades the complete exact-version systemd family to Forky
261+ using its own `SandboxTrees=` APT source pinned at priority 50. The
base, `cayo-ab-raw`, and the normal bootc profiles remain on Trixie; only the
three production native profiles that `Include=` the fragment run Forky.

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
`snowfield`) and native ones (`cayo-ab-raw`, `cayo-ab`, `snow-ab`,
`snowfield-ab`), so the SAME
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

### Native A/B Update UX (phase 4)

Native images never run bootc/nbc. `/usr/libexec/snosi-sysupdate-stage`
(`shared/outformat/ab-root/tree`, system service+timer) is the native analog
of `bootc-update-stage`: `systemd-sysupdate check-new` against the DEFAULT
sysupdate target (no `--definitions=`), then `systemd-sysupdate update
<version>` if newer (installs into the inactive slots only), then its OWN
post-stage verification -- re-fetches `SHA256SUMS` and checks the newly
labeled partitions' PARTUUIDs against the embedded UUIDs, and checks the
matching UKI exists in the ESP (transfer numbering 10/20/90 stands in for
ordering). Never reboots; fails loudly (`outcome=failed`) on any mismatch.
The PARTUUID read is retried (`udevadm settle` + bounded re-read loop):
`lsblk` reads udev's property db, which refreshes ASYNCHRONOUSLY after
sysupdate's GPT writes, and reading immediately after `update` returns can
see a mixed stale view -- observed live 2026-07-15 (full-window QEMU run):
the reused root slot showed its NEW label with the OLD pre-vacuum PARTUUID
even though the on-disk GPT was provably correct (the next boot and the next
hop's identical verification both passed). `udevadm settle` alone is not
sufficient (it returns early when udev's watch event has not yet been
synthesized), hence the retry loop; a real mismatch still fails with the
same error after retries are exhausted.

It speaks the exact same `/run/snosi/update-check`/`/run/snosi/update-staged`
state-file language as the bootc stager, with one schema extension: the
semaphore carries `version=<14-digit>` on native instead of bootc's
`digest=sha256:...` (never both). The three shared consumers --
`/etc/update-motd.d/86-bootc-update-staged` (ships once, in base, never
forked), `/usr/libexec/bootc-update-notify` (ditto), and
`usr/bin/snosi-update-status` -- all key off whichever field is present, and
`snosi-update-status` additionally dispatches its ENTIRE backend
(`native_status()` vs `bootc_status()`) on `/usr/lib/snosi/native-ab` before
ever calling the `bootc` CLI, which isn't installed on native images at all.

No native `held-rollback`: `systemd-sysupdate`'s `InstancesMax=2` accounting
treats both on-disk root slots as "installed" when deciding what's newer, so
a version already sitting in either slot -- including one the admin just
rolled away from -- is never re-offered by `check-new` in the first place;
bootc's separate rollback-deployment pointer (the thing that can collide with
an unchanged registry pull) has no sysupdate equivalent to collide with. The
one real adjacent case handled explicitly: a version already downloaded into
the inactive slot by an earlier run this boot, waiting for reboot, is
detected (remote_version equals the other slot's version) and re-asserts the
semaphore instead of re-downloading.

Desktop notification: native-named user units `snosi-update-notify.path`/
`.service` (parallel to the masked bootc-named pair, same tree) both
`ExecStart=` the SAME `/usr/libexec/bootc-update-notify` script -- no
duplicated notification logic between transports -- with an unconditional
static `graphical-session.target.wants/` link (a passive path watcher is
harmless even when nothing is ever staged).

Activation policy is inert by default: `snosi-sysupdate-stage.timer` ships
with no `[Install]` section, and no build creates a wants-link for it unless
`SNOSI_NATIVE_AUTOSTAGE=1` was set in the build environment (forwarded into
the ab-root finalize `.chroot` script via `Environment=SNOSI_NATIVE_AUTOSTAGE`
under `shared/outformat/ab-root/mkosi.conf`'s new `[Build]` section). A
static `/usr/lib/systemd/system/timers.target.wants/` link, created by that
finalize script, not a preset -- an already-installed image whose first boot
predates a publication-enabled release would never pick up a brand-new
preset-only enablement, but the static link ships correctly with the very
update that introduces it. `test/native-ab-updateux-test.sh` is the Phase 4
exit-criterion QEMU test: it boots a publication-disabled N, stages a
publication-enabled N+1 (built with `SNOSI_NATIVE_AUTOSTAGE=1`), reboots, and
asserts `snosi-sysupdate-stage.timer` is ACTIVE post-reboot -- proving the
static link travels with the image itself, not with any first-boot or
preset-reconcile machinery. See `yeti/testing.md` for the full assertion
sequence including the ack-gated notification and tampered-signature
fail-closed cases.

### Installer ISO (phase 8)

`mkosi.profiles/native-installer/` (Include=`shared/native-installer/mkosi.conf`)
is a payload-free network-installer image: no Snow/Snowfield/Cayo content, no
`Dependencies=`, `BaseTrees=` reset to empty (cancels the root `mkosi.conf`'s
`BaseTrees=%O/base` -- this profile must never inherit the shared bootc/
sysext base). `Format=directory`, `Bootable=no`: mkosi's own UKI/systemd-boot/
signing pipeline is not used at all. docs/native-ab-contracts.md §8's boot
chain -- Microsoft firmware db -> Debian-signed shim -> Debian-signed GRUB ->
Debian-signed stock kernel -> installer initrd/userspace -- is assembled
entirely OUTSIDE mkosi by `shared/native-installer/tools/build-iso.sh`
(mkosi has no ISO/El Torito output format at all -- checked the pinned man
page's `Format=` enumeration). That script pulls the signed boot chain
material straight out of the built rootfs (packages, not anything mkosi
signs): `shim-signed`, `grub-efi-amd64-signed`, `shim-helpers-amd64-signed`
(ships MokManager `mmx64.efi` -- NOT shipped by `shim-signed` itself), and
`linux-image-amd64` (confirmed genuinely Debian-signed via `sbverify`, not
just conventionally named -- "Debian Secure Boot Signer 2022 - linux" /
"Debian Secure Boot CA"). These stay on the trixie release; only the
cryptsetup/TPM/systemd family is pinned `/forky` (reusing
`shared/native-ab-secure/package-manager`'s `SandboxTrees=` verbatim, per
contract §8's "coherent Forky systemd 261" requirement even though the boot
KERNEL is stock trixie).

The installer userspace is the ENTIRE built rootfs packed as the kernel's
initramfs (cpio+zstd, `find`+`cpio` must run in the SAME subshell as the
`cd` that scopes them -- a `cd` in a subshell that is only the first stage
of a pipe does not affect the next pipeline stage). A top-level
`/init -> usr/lib/systemd/systemd` symlink (added by
`shared/native-installer/postinst/mkosi.postinst.chroot`) means there is no
`switch_root`: systemd boots directly as PID 1 with the packed tree as final
root (no `/etc/initrd-release`, so systemd never enters "initrd mode").
`Locale=`/`Keymap=`/`Timezone=`/`Hostname=`/`RootPassword=hashed:` are all
set explicitly in `shared/native-installer/mkosi.conf` so `systemd-firstboot`
has nothing left to prompt for -- root-caused live: left unset,
`systemd-firstboot.service` blocks the ENTIRE boot indefinitely on an
interactive timezone prompt with no TTY to answer it, which looks exactly
like a silent kernel/systemd deadlock (traced via `rdinit=/bin/bash`,
`systemd.mask=`, and QEMU monitor `info registers` showing the vCPU
genuinely halted, not spinning, before finding the real cause).

ESP layout gotchas, both confirmed live by bisecting a working boot down to
individual files/kernel args: (1) `grub-efi-amd64-signed`'s monolithic image
has its prefix baked in at `/EFI/debian` (`strings ... | grep '^/EFI'`), so
`grub.cfg` must exist at that literal path -- AND, separately, booting
through real El Torito/CD-ROM emulation resolves GRUB's prefix search
against the ISO9660 volume, not the appended GPT/FAT partition, so
`build-iso.sh` places a copy of `grub.cfg` directly in the ISO9660 tree too
(the large kernel/initramfs stay ESP-only; `grub.cfg`'s `search --file`
re-targets `$root` to wherever they actually are). Shim's compiled-in
second-stage/MokManager names have no directory component (confirmed via a
UTF-16LE string dump of `shimx64.efi.signed`: `\\grubx64.efi`, `\mmx64.efi`)
-- it looks in ITS OWN directory, so copies of grub/mmx64 live in
`EFI/BOOT/` (required anyway for El Torito's `/EFI/BOOT/BOOTX64.EFI`
fallback path). (2) `fbx64.efi` (the shim-helpers-amd64-signed fallback/
NVRAM-registration loader) is deliberately never shipped, even though the
package provides it: with it present in `EFI/BOOT/` alongside shim, OVMF
resets the machine instantly with ZERO diagnostic output, before shim even
attempts to load `grubx64.efi` -- isolated by bisecting file-by-file on a
minimal FAT image; removing only `fbx64.efi` (keeping `mmx64.efi` and
everything else) boots normally. (3) The kernel command line is
`console=ttyS0,115200n8` ONLY -- no second `console=tty0`. With Secure Boot
enforced against a POPULATED varstore (real Microsoft PK/KEK/db, i.e. the
exact fixture the boot-chain proof itself requires) and no GPU device,
adding `console=tty0` hangs PID 1 completely silently; single-console boots,
and dual-console boots against a non-SB or empty/setup-mode varstore, are
unaffected -- reads as an OVMF GOP/console-negotiation interaction specific
to enforced SB with a populated varstore, not a defect in this image's own
init handling.

`test/native-installer-iso-test.sh` is the exit-criterion validation:
structural checks against the built ESP (loop-mounted, no boot needed --
signed-binary issuer/subject assertions via `sbverify`, packed-initramfs
content via `cpio -t`, systemd-family version via the manifest), a QEMU
positive boot with Secure Boot ENFORCED against a freshly-copied, NEVER
enrolled `OVMF_VARS_4M.ms.fd` (proving the pre-enrollment chain reaches SSH
and `mokutil --sb-state` reports enabled), and a negative proof on the SAME
never-enrolled varstore: grub's own UNSIGNED monolithic EFI image, signed
with the project's real `mkosi.key`/`mkosi.crt` (the same key
`shared/native-ab-secure/mkosi.conf` uses for every production native
profile) in place of the trusted GRUB, is rejected by shim itself
("Verification failed: (0x1A) Security Violation") -- proving the positive
boot is a genuine Secure Boot enforcement result, not an accidentally-
permissive OVMF configuration. `check-native-publication-guard.sh`'s
production-name matching (`cayo-ab`/`snow-ab`/`snowfield-ab` only) already
excludes `native-installer` with no code change needed.

Two carry-over fixes from the phase 8.1 review, both in
`shared/native-installer/tools/build-iso.sh`: (1) the script's 2nd argument
is now an OUTPUT DIRECTORY, not a caller-chosen file path -- it always
writes the frozen public name (`snosi-native-installer_<version>_x86-64.iso`,
docs/native-ab-contracts.md "Installer ISO") inside it, and stamps the
version into both the ISO9660 volume ID (`SNOSI_INSTALLER_<version>`, 30
d-characters, under the 32-char limit) and a
`/etc/snosi-installer-release` file written into the packed rootfs
immediately before the cpio/zstd step (VERSION is only known at ISO-
ASSEMBLY time, not at the earlier `mkosi build` time, so this can't be
baked in by the profile's own postinst); (2) the iso-test's cryptsetup
check is anchored to `usr/sbin/cryptsetup$` (both `/sbin/cryptsetup` and
`/usr/sbin/cryptsetup` exist under merged-`/usr`, the former a symlink) --
an earlier unanchored `cryptsetup$` pattern would also pass against any
unrelated path ending in that literal string. The profile also gained a
firmware package block (`firmware-linux-free`/`-nonfree`/`-linux` plus the
same per-vendor `firmware-*` set `shared/kernel/stock/mkosi.conf` ships,
plus network-adapter extras from `shared/packages/snow`/`shared/packages/
cayo`) so the installer can actually reach a network on real hardware, not
just virtio-only QEMU fixtures.

`test/native-installer-e2e-test.sh` is the higher-level Phase 8 exit proof: where
`native-installer-iso-test.sh` validates the boot chain structurally and via
positive/negative Secure Boot boots, the e2e test drives a REAL install of both
`cayo-ab` and `snow-ab` — build+publish through the actual publication pipeline to
a local origin, boot the fresh ISO on a virgin never-enrolled `OVMF_VARS_4M.ms.fd`
+ persistent swtpm, run a non-interactive encrypted-`/var` install (recovery key +
TPM enrollment + MOK password file), prove the pre-enrollment Security Violation,
simulate MokManager approval via host-side `virt-fw-vars --add-mok` into the same
varstore, then boot the installed system fully enforced and fully unattended and
assert SB enforced, kernel lockdown, unattended TPM `/var` unlock, the `/etc`
overlay, `IMAGE_ID`/`IMAGE_VERSION`, `install-info.json`, clean
`snosi-update-status`, and no failed units. It also de-risks commit 99f4921's
own-boot-medium refusal in the real initramfs (cayo-ab step 3). First green run
75/75 (2026-07-15); see yeti/testing.md "Phase 8 (ISO install end-to-end)" for the
full step breakdown and the real product bugs it surfaced.

### snosi-install CLI (Task 8.2)

`shared/native-installer/tree/usr/libexec/snosi-install` replaces the
phase-8.1 placeholder (`test/cayo-ab-install-spike.sh` shipped verbatim at
`/usr/libexec/snosi-install-spike`) with the full 21-step flow from the
plan's "First-Round CLI Installer". The spike test script itself is
UNCHANGED (still shipped at its own path, still what every existing QEMU
harness drives) -- its GPT-relocate/var-grow/LUKS logic is PORTED, not
sourced, into `snosi-install`'s own functions: factoring a shared lib was
rejected because it would touch a script several already-green, multi-hour
QEMU suites depend on, for no behavioral gain at this stage. If a bug
surfaces in that logic later, both near-identical copies need the fix.

Design decisions worth knowing before touching this script:

- **Testability via a `BASH_SOURCE[0] == $0` guard**, not an env var: `main`
  only runs when the file is executed directly, so `test/snosi-install-
  test.sh` can `source` it (via `test/lib/snosi-install-test-helpers.sh`,
  which adds thin wrapper functions around a few internals that set output
  globals) and call individual functions. Each call happens in its OWN
  `bash -c` subprocess, so a function's `die` (a plain `exit 1`) only ends
  that one subprocess -- never the test harness.
- **`PUBRING` is a top-level assignment, not only set inside `main()`**:
  `set -u` means a function like `fetch_verified_index` referencing
  `$PUBRING` would hit "unbound variable" if sourced without `main()` ever
  running. `SNOSI_INSTALL_PUBRING`/`SNOSI_INSTALL_LSBLK_JSON`/
  `SNOSI_INSTALL_SELF_DEVICE` are the only test hooks; none exist on a real
  target machine.
- **Streamed download+verify, not download-then-verify-then-write**: a FIFO
  + backgrounded `sha256sum` lets `curl | tee fifo | xz -dc | dd` hash the
  exact compressed bytes received while simultaneously writing the
  decompressed image to the target disk. `.disk.raw.xz` objects are
  multiple GiB; requiring 2x that in scratch space before ever touching the
  target disk was rejected as impractical for install-target machines with
  little free space anywhere but the target disk itself. Tradeoff: a
  failure (network error, corrupt xz stream, or a checksum mismatch found
  only after the full write) is only detectable AFTER bytes have already
  landed on disk -- `wipe_target()` (wipefs + reread, or truncate for
  `--allow-file` regular-file targets) always runs before returning
  non-zero, so a partially/incorrectly-written image is never left looking
  installable.
- **TPM enrollment is self-contained**: the PCR-11 signing public key is
  extracted from the JUST-WRITTEN disk's own UKI (`objcopy --dump-section
  .pcrpkey=...`, same invocation as `test/native-ab-secure-artifact-
  test.sh`), mounting the disk's ESP and reading `EFI/Linux/<channel>_
  <version>.efi` -- an initial install always ships exactly that name, no
  `+l-d` update suffix (docs/native-ab-contracts.md §4). No external key
  distribution needed at install time. The `systemd-cryptenroll` invocation
  mirrors `test/native-ab-secure-rotation-test.sh`'s `enroll_token`
  EXACTLY: empty raw PCRs, signed PCR 11 only, `--tpm2-pcrlock=` (disabled),
  `--tpm2-device=auto`.
- **MOK enrollment is fully non-interactive-capable via a real mokutil
  feature, not a workaround**: `mokutil --import` normally reads a password
  interactively via termios, which cannot be scripted. `mokutil
  --generate-hash=<password>` (prints a sha512crypt hash to stdout) plus
  `mokutil --import <cert> --hash-file <hashfile>` stages the identical
  enrolling request with zero interactive prompts -- confirmed via
  `mokutil(1)`'s SYNOPSIS/OPTIONS on the installer's own `mokutil 0.7.2`.
  Interactive mode still prompts twice with match validation
  (`mok_password_twice`) and prints `explain_mok_next_boot`'s blue-screen
  walkthrough before AND after staging (plan: "explain the exact next-boot
  interaction before staging the request").
- **`--restage-mok` validates arguments BEFORE `need_root()`**, mirroring
  `main()`'s own ordering: a missing/empty `--mok-password-file` is a usage
  error, not a hardware problem, and this is what makes it unit-testable
  without root. It auto-detects (or validates an explicit `--disk`) the
  installed disk by finding exactly one esp+var partition-label pair, then
  refuses to stage anything unless it can find a real `EFI/Linux/*.efi` on
  that ESP (a sanity check against restaging a request onto something that
  is not actually a real install).
- **Root SSH key install (`--ssh-authorized-key`) cannot write to `/root`**:
  the root filesystem is dm-verity-sealed and read-only, at install time
  AND at runtime -- `/root/.ssh/authorized_keys` can never exist for real.
  A new drop-in, `shared/outformat/ab-root/tree/etc/ssh/sshd_config.d/
  10-snosi-authorized-keys.conf`, adds `AuthorizedKeysFile /etc/ssh/
  authorized_keys.d/%u` as a SECOND lookup location (Debian's stock
  `sshd_config` already `Include`s `sshd_config.d/*.conf`), which resolves
  under the SAME persistent `/etc` overlay upperdir the 95etc-overlay
  dracut module mounts at boot
  (`var/lib/snosi/etc-overlay/upper`, `shared/outformat/ab-root/tree/usr/
  lib/dracut/modules.d/95etc-overlay/etc-overlay-mount.sh`) -- so
  `snosi-install` (during its `/var` mount, alongside writing
  `/var/lib/snosi/install-info.json`) can seed a key there directly, before
  first boot, with no new mechanism.
- **MOK certificate is committed, public material**: same
  reasoning as the existing `import-pubring.gpg` -- a certificate is
  exactly the thing you hand out for verification. `shared/native-ab/keys/
  mok-2026.crt` is a plain copy of the gitignored `mkosi.crt`; it ships into
  the installer at the version-neutral path `/usr/lib/snosi/mok.crt`
  (ExtraTrees=) and the
  update pubring ships at `/usr/lib/snosi/os-update-pubring.gpg` (same
  file, same single-canonical-copy pattern as the ab-root fragment's own
  `/usr/lib/systemd/import-pubring.gpg` copy -- deliberately a SEPARATE
  path/copy, not shared, since the installer and the installed OS have
  independent trust boundaries and lifecycles).

`test/snosi-install-test.sh` covers the pure logic via fixtures (index
parsing/verification against a local HTTP origin + ephemeral gpg key,
disk-refusal filters against fixture `lsblk -b -J -O` JSON, name derivation,
the full `--non-interactive` argument validation matrix, streamed-verify
mismatch handling against a small fixture payload, `--restage-mok` argument
handling) -- wired into `validate.yml`. It deliberately does NOT cover
actual disk writes, LUKS/TPM enrollment, or MOK against real EFI variables;
that needs a full product build and a real (or QEMU) install target, which
is a later task, not this fast per-PR check.

### Publication pipeline generalization for the ISO (Task 8.2)

The Phase 7 candidate/verify/promote/withdraw pipeline
(`shared/native-ab/publish/`) was generalized to also publish the installer
ISO under the FLAT `isos/native/v1/` namespace (docs/native-ab-contracts.md
§5 -- no per-product/x86-64 subpath, since there is exactly one installer).
Minimal change: `publication-info.json` now carries an explicit `dest_path`
field (both `prepare-native-publication.sh`, which sets it to
`os/native/v1/<product>/x86-64` exactly reproducing the old hardcoded
behavior, and the new `prepare-iso-publication.sh`, which sets it to
`isos/native/v1`); `read_publication_info()` in `publish-lib.sh` reads it
into `PUB_DEST_PATH`; `publish-candidate.sh`/`promote.sh` use
`$PUB_DEST_PATH` directly instead of always computing `product_path
"$PUB_PRODUCT"`. `withdraw.sh` (which has no prepared-dir -- it is an
incident-response tool taking `<product> <version> <dest>` directly) grew
an optional `--dest-path <path>` override for the same reason, defaulting
to the unchanged `product_path()` derivation when omitted.
`prepare-iso-publication.sh` sets BOTH `product` and `channel` to the
literal string `snosi-native-installer` (matching the frozen object name's
own prefix, `snosi-native-installer_<version>_x86-64.iso`) rather than
following the OS pipeline's product-vs-channel split, since that string IS
what `promote.sh`'s outgoing-index archival step greps for.

That archival step (`old_version="$(grep -oE "${PUB_CHANNEL}_[0-9]{14}
\\.manifest\\.json" ...)"`) turned out to have a LATENT bug, only surfaced
by adding a publication type with no `*.manifest.json` entry at all: under
`set -o pipefail`, `grep` finding zero matches exits 1, and since the whole
pipeline was the right-hand side of a plain variable assignment (not a
condition), `set -e` silently killed `promote.sh` -- no error message, just
an abrupt exit -- the SECOND time an ISO version was promoted (the first
promotion has no outgoing index yet, so the archival code path, and the
bug, never ran). Fixed by generalizing the pattern to match any `<channel>_
<14-digit-version>` prefix (not only `.manifest.json`) and adding `|| true`
at both grep stages, so "the outgoing index cannot be parsed" degrades to
the existing "nothing to archive" log line instead of an unrelated-looking
silent death. Caught by `test/native-publication-pipeline-test.sh`'s new
"ISO-shaped fixture leg", which is the first test in this suite to promote
the SAME (non-manifest-bearing) publication type twice in a row.

A second latent bug in the same archive block surfaced during the first
REAL promotion against R2 (2026-07-16): `publish-lib.sh`'s
`dest_object_exists()` trusted `rclone lsf`'s exit code, but that exit code
is BACKEND-DEPENDENT for a missing object -- directory backends (rclone's
`local`) exit 3, while bucket backends (S3/R2) have no real directories, so
`lsf`/`cat`/`copyto` of a nonexistent object are all just empty-prefix
listings: exit 0, empty output, no file produced. On R2 this made a first
promotion take the misleading "already advertises (or is unparseable)"
branch (the false "exists" led to `dest_read_object` producing an empty
file via `rclone cat`, whose version grep then matched nothing); archiving
was still correctly skipped, but a false "exists" could have masked real
archive/restore bugs. Fix (all three helpers now judge by produced OUTPUT,
never rclone's exit status): `dest_object_exists` compares `lsf` output to
the object's basename; `dest_read_object` uses `copyto` and requires the
outfile to actually exist afterward; `dest_copy_object`'s rclone branch
gained the same explicit source-exists refusal its local branch always
had (a missing source was a silent no-op copy on bucket backends).
Covered by `test/native-publication-pipeline-test.sh`'s "dest backend
semantics" leg, which asserts missing-vs-present behavior is identical on
a local-dir dest and on a REAL S3 backend (`rclone serve s3` against a
temp dir, reproducing the exact R2 shape; skipped when rclone is not
installed), plus a first-promotion assertion that `promote.sh` prints
"No existing signed index to archive (first promotion ...)".

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
mkosi.profiles/             # Transport+kernel selector profiles (7: cayo, snow,
  snow/                     # snowfield, cayo-ab-raw, cayo-ab, snow-ab,
  cayo/                     # snowfield-ab). Each profile: mkosi.conf +
  ...                       # (native only) its own transport-specific extras.
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

`mkosi.profiles/cayo-ab-raw` and `mkosi.profiles/cayo-ab` (the native A/B
dev fixture and its production successor) `Include=shared/composition/cayo/mkosi.conf` the same way the bootc
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
- `check-native-publication-guard.sh` — static gate for `docs/native-ab-contracts.md` §15: requires any profile literally named `cayo-ab`/`snow-ab`/`snowfield-ab` to carry shim/Secure Boot/PCR-signing/NvPCR/pubring markers and no `KernelModules=` filter, and hard-fails `cayo-ab-raw` if it ever gains a publication marker; run by CI. Since Phase 3 all three production profiles exist and pass the guard for real; `cayo-ab-raw` continues to pass the "must stay unpublishable" side of the check

## CI/CD

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `build.yml` | Push/PR/dispatch | Build base + sysexts, publish to R2 |
| `build-images.yml` | Push/PR/repository_dispatch/dispatch | Matrix build of 6 profiles, push OCI to ghcr.io, generate SBOMs, sign with Cosign |
| `build-native-images.yml` | Push/PR/repository_dispatch/dispatch; promotion excluded from PRs | Native A/B products + installer ISO build, candidate publish, public-origin verify, protected promote (Phase 7/8) |
| `deploy-native-installer-redirect.yml` | Main changes under the Worker / dispatch | Test and deploy the R2-index-derived stable installer redirect |
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
