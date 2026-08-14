# Native A/B prototype & installer history

> Extracted from `AGENTS.md` (see snosi#727) to keep the top-level agent
> instructions focused. This document is the historical build journal and
> phase-by-phase narrative for the native A/B products and the installer ISO.
>
> **Authoritative contracts live elsewhere** and take precedence over anything
> here:
> - Native A/B naming/path/policy contracts: `docs/native-ab-contracts.md`
>   (statically enforced by `test/native-ab-contracts-test.sh`).
> - Publication pipeline: `docs/native-ab-publication.md`.
> - Slot/capacity sizing: `docs/native-ab-capacities.md`.
>
> Treat the material below as background and rationale, not as a live spec.

### Native A/B Prototype

Naming, path, and policy contracts for the production native A/B products
(`cayo-ab`, `snow-ab`, `snowfield-ab`) are frozen in
`docs/native-ab-contracts.md` and enforced statically by
`test/native-ab-contracts-test.sh`. Read that document before adding or
renaming anything under the native A/B tree — it is the source of truth, not
this section. Known deviations of the current prototype from the frozen
contract are tracked in `test/native-ab-contracts-allow.txt`, not silently
carried forward. `check-native-publication-guard.sh` (wired into
`validate.yml`) is the standalone static gate for the contract's §15
publication guard: it requires every profile literally named `cayo-ab`,
`snow-ab`, or `snowfield-ab` to carry shim/Secure Boot/PCR-signing markers,
an NvPCR-disable finalize reference, the ab-root outformat include, the
committed update pubring, and no final-root `KernelModules=` filter, and it
hard-fails if `cayo-ab-raw` ever picks up a publication marker. Since Phase 3
all three production profiles exist and pass the guard: the check follows a
profile's `[Include]=shared/native-ab-secure` line as a plain textual
reachability check (not a general `Include=` resolver — only this one
documented fragment) so the markers can live in the shared fragment instead
of being restated per profile.

**Generic output + per-product channels (Phase 3):** `shared/outformat/ab-root/`
carries ONLY product-neutral disk/boot mechanics — `Format=disk`,
`SplitArtifacts=`, `Bootable=yes`, `Initrds=`/`KernelModulesInitrd=no`,
`KernelCommandLine=`, the shared `tree/` (fstab, the etc-overlay dracut
module, the legacy-updater masks, the sysupdate-timer preset, the
`native-ab` marker), and the finalize script. It carries NO
`RepartDirectories=`, NO `*.transfer` files, and NO final-root
`KernelModules=` filter — `test/native-ab-contracts-test.sh` asserts all
three unconditionally. Every one of those three lives instead in
`shared/native-ab/channels/<product>/` (`cayo`, `snow`, `snowfield` —
`docs/native-ab-contracts.md` §12), which supplies its own
`RepartDirectories=` (the 6 repart defs, ImageId-based labels and
mkosi-internal `SplitName=`, 1 GiB ESP) and its own
`tree/usr/lib/sysupdate.d/` (the 3 OS transfers, frozen R2 URL, `<ImageId>-ab`
channel-prefixed `Source MatchPattern=`, `<ImageId>`-based `Target
MatchPattern=` labels — §3 labels are ImageId-scoped, not channel-scoped, so
they never change when a new channel starts publishing). A profile consumes
native A/B output by `Include=`ing BOTH the generic `shared/outformat/ab-root/mkosi.conf`
fragment AND exactly one channel's `mkosi.conf`; mkosi's list-setting
accumulation means the channel's `ExtraTrees=`/`RepartDirectories=` add to,
not replace, the generic fragment's. `mkosi.profiles/cayo-ab-raw` and the
production `cayo-ab` both `Include=` the `cayo` channel; `snow-ab` and
`snowfield-ab` (Task 3.2) `Include=` the `snow`/`snowfield` channels
respectively. All root+verity slot sizes are now VALIDATED against real
native builds, not provisional: cayo is 5 GiB root / 256 MiB verity
(~23.8% headroom); snow is 8 GiB root / 256 MiB verity (~33.8% headroom,
measured content ~5.29 GiB — smaller than the earlier bootc-derived
provisional estimate, which conservatively over-counted bootc/ostree/grub
tooling that native profiles never install); snowfield reuses the same
8 GiB / 256 MiB slot (~29.5% headroom, measured content ~5.64 GiB — the
Surface kernel's larger driver/firmware set costs about 374 MiB more than
snow's backports kernel, still comfortably inside the slot). See
`docs/native-ab-capacities.md` for full measured numbers and the headroom
definition.

**Module policy (Phase 3):** release native profiles ship the complete
packaged kernel module/firmware set — no final-root `KernelModules=` pruning
(`docs/native-ab-contracts.md` §9). The virtio-only filter that used to live
in the shared `ab-root` fragment moved into `mkosi.profiles/cayo-ab-raw/mkosi.conf`
directly (the one dev fixture permitted to carry it — a QEMU-only
restriction to keep dracut's `--no-hostonly` initrd self-contained and avoid
mkosi's dependency sweep failing on unresolved Debian module aliases);
the three production profiles (`cayo-ab`, `snow-ab`, `snowfield-ab`) build
with the full module set. The generic tree's
`usr/lib/dracut/dracut.conf.d/30-bootc-standard.conf` is a DELIBERATE
same-named override: `ExtraTrees=` composition overwrites files at
identical relative paths, so this file replaces (not supplements) the base
image's copy of the same name, which is how `add_dracutmodules+=" lvm crypt
etc-overlay "` replaces the base's `"... bootc"` line rather than both
surviving into the same `dracut.conf.d` directory — the filename match is
load-bearing and `test/native-ab-static-test.sh` asserts it holds by finding
whichever base file adds the `bootc` dracut module and checking ab-root's
tree shadows it at the identical relative path.

**The `ExtraTrees=` shadow alone is not early enough for every kernel package
(Task 3.2 root cause, `dracut[E]: Module 'bootc' cannot be found`):** mkosi's
build order is `install_skeleton_trees()` -> `install_distribution()`
(installs `Packages=`) -> `install_extra_trees()` (confirmed in
`.mkosi/mkosi/__init__.py` `build_image()`), so the `ExtraTrees=` shadow of
`30-bootc-standard.conf` above only lands AFTER packages — including the
kernel — are installed. Debian's own `linux-image-amd64` (cayo-ab/snow-ab)
defers its kernel-postinst dracut regeneration via a dpkg trigger and never
hits this window, but the linux-surface kernel package (`snowfield-ab`) runs
`/etc/kernel/postinst.d/dracut` SYNCHRONOUSLY as part of its own postinst,
at which point the base image's un-shadowed copy (requesting the `bootc`
module, which native profiles never install) is still in effect, and the
build hard-fails. Fixed by ALSO pulling the identical canonical file in via
`SkeletonTrees=%D/shared/outformat/ab-root/tree/usr/lib/dracut/dracut.conf.d/
30-bootc-standard.conf:/usr/lib/dracut/dracut.conf.d/30-bootc-standard.conf`
in `shared/outformat/ab-root/mkosi.conf` — SkeletonTrees run BEFORE package
installation, so the shadow is in effect from the very start of the
buildroot regardless of which kernel's postinst hook happens to run
synchronously. No file duplication: same source path, two composition
mechanisms. The `ExtraTrees=` copy is still required (it is what
`test/native-ab-static-test.sh` checks, and it is the one that would win if
a future kernel ever overwrote this path mid-install). Verified harmless for
cayo-ab/snow-ab (rebuilt with the fix, artifact tests still pass, root
content size unchanged to within build-metadata noise).

`mkosi.profiles/cayo-ab-raw` (renamed from `cayo-ab` in Phase 1; `Output=`
changed to match, `ImageId=cayo` unchanged) is an isolated experimental disk
profile, a permanent, never-published dev fixture per
`docs/native-ab-contracts.md` §1 — the name `cayo-ab` is reserved for the
eventual secure production posture. Its initrd
must mount persistent `var` and overlay `/etc` before switch-root; never add a
host system-service fallback. The image ships `machine-id=uninitialized`, and
first boot commits a unique ID into the overlay upperdir. The installer grows
only the final ext4 `var` partition. OS transfers are mandatory, UUID-bearing,
and `Verify=yes`; do not enable `systemd-sysupdate.timer` until a dedicated
`/usr/lib/systemd/import-pubring.gpg` and signed publication pipeline exist.
Partition payloads must use XZ: Debian's systemd 257 `systemd-pull` does not
decode Zstandard URL payloads and writes them compressed into the target slot.
Partition transfers must reset `PartitionFlags=0` before applying `ReadOnly=yes`.
The kernel postinstall exports its dracut archive to
`$ARTIFACTDIR/io.mkosi.initrd`; `Initrds=` and `KernelModulesInitrd=no` prevent
mkosi from silently embedding an unrelated default initrd instead. The custom
dracut module depends on `systemd-veritysetup` so the UKI `roothash` creates the
verified root before the overlay service runs. Until signed publication is
available, the image finalizer masks both sysupdate timers in `/etc`: initrd PID
1 starts before real-root preset policy is visible, so a preset alone cannot
reliably prevent first-boot timer enablement. Manual sysupdate remains available.
GPT partition labels for the dynamic root/verity slots are `<ImageId>_<version>_r`
and `<ImageId>_<version>_v` (`docs/native-ab-contracts.md` §3; shortened from the
prototype's original `_root`/`_root_verity` suffixes in Phase 1 to stay under the
30-code-unit ceiling at the frozen 14-digit version length) — set per-product
in `shared/native-ab/channels/<product>/mkosi.repart/{10-root-verity,11-root}.conf`
(Phase 3; formerly a single shared `shared/outformat/ab-root/mkosi.repart/`)
and matched by the `Target MatchPattern=` in the corresponding channel
`*.transfer` files. Native
images must never run the legacy bootc or nbc update machinery: the base image
ships `bootc-update-stage.timer`/`.service`, `nbc-update-download.timer`/`.service`,
and the user-scope `bootc-update-notify.path`/`.service` unconditionally (shared
with the bootc profiles), so `shared/outformat/ab-root/tree/usr/lib/systemd/{system,user}/`
masks each one with a same-named `/dev/null` symlink — the same mechanism used for
`systemd-growfs-root.service`. Upstream's own `bootc-fetch-apply-updates.*` ships
inside the `bootc` deb itself, which native profiles never install, so those two
units need no mask. Native also masks `plymouth-read-write.service`: root is
permanently read-only EROFS, so its `plymouth update-root-fs --read-write`
notification is meaningless, and on minisnow it intermittently blocked forever
before `sysinit.target` (solid cursor, no network, runtime watchdog still fed,
Magic SysRq responsive). Failed boots started the unit without finishing it;
successful boots completed it in 40-53 ms. `test/native-ab-static-test.sh`
asserts every mask exists.
`test/native-ab-update-test.sh` validates N to N+1 to N+2 to N+3 with four real
mkosi builds: signed-manifest acceptance/rejection, missing UKI/verity and bad
checksum rejection, inactive-slot reuse, dm-verity boot, explicit rollback,
boot-count fallback from a corrupted unblessed update, and `/var` plus `/etc`
persistence.

`test/native-ab-components-test.sh` is the Phase 1 exit-criterion QEMU test: it
builds two real `cayo-ab-raw` versions itself, boots N, and asserts no failed
systemd units and the bootc/nbc/systemd-sysupdate masks from above; that
`/usr/lib/sysupdate.d/` contains only the three OS transfers (no `.feature`
files) while `systemd-sysupdate components` enumerates all 22 shipped sysext
components; that two independently versioned ad hoc test components
(`testa`/`testb`, created under `/etc/sysupdate.<name>.d/`) update via
`--component=` without touching OS partitions, the ESP, or each other's
version; that an unqualified N to N+1 OS update succeeds with both test
components still enabled and `/var/lib/extensions.d` untouched; and that
`snosi-etc-diff`/`snosi-etc-drift-report.service` correctly report, diff, and
restore live `/etc` drift against `/.etc.lower` with no leftover bind mounts.
It caught a real bug: the `KernelModules=` allowlist (originally in the
shared `ab-root` fragment, moved to `mkosi.profiles/cayo-ab-raw/mkosi.conf`
in Phase 3 — see "Module policy" above) excluded `nf_tables`/`nfnetlink`, so
the base image's unconditionally-shipped, preset-enabled `nftables.service`
failed on every native A/B boot ("Unable to initialize Netlink socket:
Protocol not supported") — fixed by adding both modules to the allowlist.

**Publication naming pipeline and test parameterization (Phase 3):**
`shared/native-ab/publish/prepare-native-publication.sh` converts one built
native profile's mkosi outputs (`Output=`, e.g. `cayo-ab`) into the frozen
`docs/native-ab-contracts.md` §4 public names. Product and version come from
that profile's own JSON manifest (`.config.name`/`.config.version`); channel
is the given `Output=` value, validated to equal `<product>-ab` — this is
what makes the script refuse to "publish" the never-shipped `cayo-ab-raw`
dev fixture, as a mechanism, not a convention. PARTUUIDs come from `sfdisk
--json` on the built disk, located by GPT partition name (needs neither a
loop device nor root — confirmed against a real 16 GiB disk). `--xz`
appends `.xz` to the root/root-verity/disk artifacts (the real §4 form);
without it the same base names are produced unsuffixed, an
intentionally-not-frozen fast path for local iteration and QEMU test
fixtures. Also emits an unsigned `SHA256SUMS` (signing is the Phase 7
promotion step) and a `publication-info.json` record. NOT wired into
`PostOutputScripts=`: every individual permission concern checks out
(`sfdisk --json` needs no root, `$OUTPUTDIR` is fully populated by
post-output time — both verified directly), but the script's job is to copy
5-23 GiB of root/root-verity/disk artifacts a second time, and
`PostOutputScripts=` runs on every single `mkosi build` — every local dev
iteration and every profile in the `build-images.yml` matrix — which would
silently double per-build disk consumption regardless of whether that
build is ever published, echoing the recorded "CI Disk Exhaustion"
incident; kept manual, for the (not yet built, Phase 7) protected
promotion job to invoke deliberately. `test/native-publish-test.sh`
validates the naming/derivation logic against a synthetic fixture
(`truncate` + `sfdisk` script mode, no root, no image build), including that
a `*-ab-raw` profile name is rejected; `test/native-ab-contracts-test.sh`
also runs it internally so a naming drift fails that same static gate.
`test/native-ab-update-test.sh` and `test/native-ab-components-test.sh`
accept `PROFILE`/`IMAGE_ID`/`CHANNEL` env overrides (defaults
`cayo-ab-raw`/`cayo`/`cayo-ab`, byte-equivalent to the prior hardcoded
behavior) — partition labels and transfer partition `Target
MatchPattern=` stay `IMAGE_ID`-based (GPT labels are never
channel-scoped, §3) while OS transfer `Source`/UKI names stay
`CHANNEL`-based, matching the real shipped channel transfers even for the
default `cayo-ab-raw` fixture (whose own build output is never itself
named `cayo-ab`). `native-ab-components-test.sh`'s N+1 OS update fixture is
now generated by running the profile's build output (symlinked under its
`$CHANNEL` name) through the publisher with `--xz`, so that leg exercises
the real public contract end to end instead of hand-rolled fixture naming.

**Shared secure posture fragment (`shared/native-ab-secure/`, Phase 3):**
until Phase 3 the secure posture lived directly in the standalone
`mkosi.profiles/cayo-ab-secure` spike profile. That profile is retired
(`git rm`); its content moved almost verbatim into
`shared/native-ab-secure/mkosi.conf`, an includable fragment carrying
everything except identity (the `[Output]` block: `ImageId=`/`Output=` differ
per product) and the payload/kernel/channel `[Include]=`s (also per-profile).
`mkosi.profiles/{cayo-ab,snow-ab,snowfield-ab}/mkosi.conf` are now the
production posture: each is ONLY `[Config]` (the `Dependencies=` header),
`[Output]` (identity), and `[Include]` — `Include=%D/shared/native-ab-secure/mkosi.conf`
listed FIRST (see "Payload composition" above for why the ordering matters),
then the product's `shared/composition/<cayo|snow>/mkosi.conf`,
`shared/kernel/<backports|surface>/mkosi.conf`,
`shared/outformat/ab-root/mkosi.conf`, and
`shared/native-ab/channels/<cayo|snow|snowfield>/mkosi.conf`. `just cayo-ab`,
`just snow-ab`, `just snowfield-ab` build them (mirroring the bootc profile
targets). Standard Secure Boot
uses Debian's Microsoft-signed shim and MOK-signed systemd-boot; generated snosi
UKIs are signed by `mkosi.key`/`mkosi.crt` and require one-time enrollment of
that certificate through shim's MokManager. GRUB is unsuitable because its
generated configuration hard-codes the build-time UKI and ignores sysupdate's
Type #2 entries and boot counters. Never use mkosi Secure Boot auto-enroll,
UEFI setup mode, or custom firmware db keys for this path. The installer creates
LUKS2 `/var` per machine after expanding the final partition; never publish a
pre-encrypted `/var`, which would clone LUKS metadata and key material. Always
retain a recovery passphrase outside the installed disk. TPM enrollment uses
the signed PCR 11 policy key with an empty raw-PCR set and explicitly disables
automatic pcrlock policy selection. Do not bind PCR 7 in the
installer: its Debian-signed boot authority differs from the installed
MOK-signed UKI, so the value changes before first boot. A raw PCR 11 value would
break each A/B update. The initrd explicitly detects LUKS and invokes
`systemd-cryptsetup attach`; GPT auto-discovery does not unlock `var` during this
dracut phase. Raw ext4 remains only for `cayo-ab-raw`, the never-published dev
fixture. LUKS2 creation,
MOK enrollment, enforced Secure Boot, TPM auto-unlock, TPM replacement failure,
recovery unlock, and PCR signing-key rotation are validated in Incus. Update,
rollback, and boot-count fallback are also validated end to end with the sole
new-key TPM token. **The PCR signing key MUST be RSA-2048** (default exponent
65537) — the only algorithm the full unlock chain accepts, proven live
2026-07-16 on systemd 261.1-3 + swtpm. RSA-4096 fails at `Esys_LoadExternal`
(`TPM_RC_VALUE`: optional in the TPM2 spec, absent from swtpm and many hardware
TPMs; see also systemd #30546), and ECC fails at `Esys_VerifySignature`
(`TPM_RC_SCHEME`: systemd 261's `tpm2_policy_authorize()` hardcodes RSASSA, no
ECDSA branch) — in both cases enrollment succeeds but every auto-unlock fails,
on every profile (NOT Surface-specific). Both bit real production key swaps
(RSA-4096, then ECC P-256) after the dev-key `125/125` runs
below; see `docs/native-ab-contracts.md` §7 for the full matrix. The MOK key stays
RSA-4096 (Secure Boot, firmware-verified, never touches the TPM). The three production profiles upgrade the complete systemd family to
Forky 261+ through the shared fragment's profile-only, low-priority APT source; never expose that
source to the base or normal profiles, and keep all exact-version systemd
libraries and companion packages qualified together.
Do not implement signing-key overlap as two independent TPM tokens. A controlled
systemd 261.1 test continued from a raw-PCR-mismatched token 0 to token 1, but a
real signed-policy key mismatch returned `ENXIO` and stopped before token 1. The
validated rotation sequence uses a transition UKI whose PCR 11 policies are
signed by both keys while `.pcrpkey` contains the new key. Archive the old private
key under `.snosi-private/history/`, make the new key active, and set
`PCR_SIGNING_KEY_PREVIOUS` to the old key's filename for transition builds. Keep
the old TPM token until every supported rollback UKI contains the new signature;
then remove it and verify the same transition UKI unlocks with the new token.
Validate each production build with
`test/native-ab-secure-artifact-test.sh` (`OUTPUT_NAME` env var, or explicit
`output/<name>.manifest output/<name>.efi` args, selects which profile's
artifacts to check; defaults to `cayo-ab`), which checks root-package coherence,
the initrd's private systemd library and TPM token plugin, and UKI PCR sections.
When given the old certificate and new public key, it also requires eight PCR
signatures: four policies signed once by each key, with the new key in `.pcrpkey`.
`test/native-ab-secure-artifact-negative-test.sh` mutates those sections and
requires rejection. `test/native-ab-secure-rotation-test.sh` is the destructive
runtime proof for an already MOK-enrolled disposable VM. It requires `--yes`, an
exact machine ID, a working external recovery key, and root SSH. It uses
guest-local `systemd-sysupdate` with a verified ephemeral signed manifest,
establishes old-only and new-only TPM states, and requires two unattended boots
of the identical transition UKI. Never point it at a production host. It
intentionally does not automate MokManager or VM creation, and N-through-N+3
rollback/fallback is validated separately by
`test/native-ab-secure-update-test.sh`. That destructive harness requires
N+1/N+2 dual-signed artifacts, an N+3 new-only artifact, exact machine and Incus
instance identities, and the external recovery key. It verifies alternating
slots, sole-new-key unlock, explicit rollback, re-arms the successfully tested
N+3 entry as `+3-0`, corrupts its root, observes three emergency boots, and
requires automatic N+2 fallback plus the exhausted `+0-3` entry.
A clean production-profile build is
validated: its ESP contains Debian-signed shim, MokManager, and MOK-signed
systemd-boot, and its MOK-signed UKI contains `.pcrpkey` and `.pcrsig`. In pinned mkosi,
`UnifiedKernelImages=unsigned` means build locally; `SecureBoot=yes` still signs
the result. Setting it to `signed` incorrectly requests a distro-prebuilt UKI.
Never store durable keys or retained test artifacts under `.mkosi-private`:
mkosi owns that directory and `mkosi clean -ff` removes it. Use the gitignored
`.snosi-private` directory.

Systemd 261 NvPCR anchor credentials embed the PCR signing public key and have
no supported migration operation. A dual-signed transition can read an old
anchor, but a new-only UKI then fails `systemd-tpm2-setup`, `systemd-pcrproduct`,
and `systemd-pcrlogin` with `ENXIO`. None of the three production profiles consume NvPCR
attestation, so `shared/native-ab-secure/finalize/disable-nvpcr.chroot` (`FinalizeScripts=`
in the shared fragment, run before every consumer's image finalize) masks every
shipped NvPCR definition plus the product/login writers. Keep TPM SRK setup and
the signed-PCR-11 LUKS path enabled. Do not delete/recreate the anchor or TPM NV
indexes as a key-rotation shortcut; that changes the attestation baseline.

**Update signing pubring (Phase 3; .pgp fix 2026-07-17):** bootc images ship
only the Frostyard repository key at BOTH
`/usr/lib/systemd/import-pubring.gpg` AND `/usr/lib/systemd/import-pubring.pgp`.
Native profiles overlay those paths with the combined repository + OS-update
ring (`shared/sysext/keys/import-pubring.gpg`) through `file:target`
`ExtraTrees=` pairs in `shared/outformat/ab-root/mkosi.conf`
(the pinned mkosi's `install_tree()` copies a single file when a target is
given — confirmed in `.mkosi/mkosi/__init__.py`). **The `.pgp` name is the one
systemd 261 actually reads** (meson: `VENDOR_KEYRING_PATH =
libexecdir/import-pubring.pgp`; pull verification has NO legacy `.gpg`
fallback for the /usr path — only `/etc/systemd/import-pubring.gpg` keeps a
legacy name). Shipping only `.gpg` made every REAL `systemd-sysupdate` pull
fail with `gpg: Can't check signature: No public key` — root-caused live on
minisnow 2026-07-17, the first-ever pull against the real origin; every QEMU
harness injects the `/etc` legacy override and so never saw it. The `.gpg`
copy stays because snosi's own tools (`snosi-update-status --check`, the
stager's probe) reference it explicitly; existing broken installs remediate
with `cp /usr/lib/systemd/import-pubring.gpg /etc/systemd/import-pubring.gpg`
(remove that copy after crossing to a fixed build — it shadows the vendor
ring across future key rotations). `test/native-ab-static-test.sh` asserts
both ExtraTrees pairs. The shipped-vendor-keyring trust path is now also
exercised LIVE by `test/native-ab-secure-boot-test.sh` — the only harness
that can: the `.pgp`-reading systemd 261 runs only on the production
profiles it boots, while Trixie's systemd 257 (what `cayo-ab-raw` boots,
i.e. every other update harness including `native-ab-publication-test.sh`'s
existing no-override leg) still reads the OLD `/usr` `.gpg` name (verified
via `strings` on `systemd-pull`) and so structurally cannot cover the
`.pgp` link. That harness installs NO `/etc/systemd/import-pubring.*`
override; it bakes its ephemeral test keyring over the committed pair at
BOTH `/usr` names via two mkosi CLI `--extra-tree` flags (CLI list-setting
values append after config-file values and ExtraTrees overwrite in install
order — needed because the committed pubring is the production key, whose
private half is offline-only), asserts the swap and the `/etc`-override
absence in-guest, verifies its Step 6 signed update hop through the vendor
`.pgp` path, and proves enforcement by rejecting a wrong-key-signed index
through the same shipped ring (Step 6c). Its `SKIP_BUILD=1` mode therefore
also requires `SIGNING_GNUPGHOME` (the homedir whose key the prebuilt
images embed).
The combined runtime ring carries both the PRODUCTION update-signing key and
the Frostyard repository key used to verify signed sysext manifests. The
narrower native publication trust root remains
`shared/native-ab/keys/import-pubring.gpg` (ed25519; fingerprint, custody,
and rotation procedure in `shared/native-ab/keys/README.md`); its private
half is offline-only (for CI, the `native-promotion` environment's
`NATIVE_UPDATE_SIGNING_KEY` secret) and is never committed and never placed
in `.snosi-private/`. QEMU update tests generate their own ephemeral keys —
injected at `/etc/systemd/import-pubring.gpg` (the `cayo-ab-raw` harnesses)
or baked over the `/usr` pair at build time
(`test/native-ab-secure-boot-test.sh`, above) — and never need this key.

**Signed sysext metadata:** every sysext transfer uses `Verify=true` and
repogen publishes a detached `SHA256SUMS.gpg` beside each component manifest.
The repository-only bootc ring and combined native ring close that trust path;
`test/sysext-signature-verification-test.sh` freezes the least-privilege
keyring wiring. Keep every sysext `.feature` defaulting to `Enabled=false`:
signature verification authenticates updates but does not change the opt-in
policy.
The repogen signing release and signature backfill for every existing component
must precede publication of an image containing this client-side change.

**Release-ordering constraint (sysext component migration):** as of the
migration that split the shared `/usr/lib/sysupdate.d/` target into
per-sysext `/usr/lib/sysupdate.<name>.d/` components (see "Sysext
Constraints" below), base images built from this tree must not be
merged/published until a `frostyard-updex` release with component discovery
(`feat/sysupdate-components`) is published to the Frostyard APT repo — an
older updex binary cannot discover component-scoped sysexts, silently
dropping every sysext from update offers.

**Automated Secure Boot + TPM + desktop validation (Phase 5,
`test/native-ab-secure-boot-test.sh`):** proves the whole secure chain in
QEMU with no MokManager interaction — `virt-fw-vars --add-mok` pre-enrolls
the Snosi MOK into a copy of `OVMF_VARS_4M.ms.fd` (Microsoft keys already
enrolled ⇒ Secure Boot enforced), paired with `OVMF_CODE_4M.secboot.fd` and
an attached swtpm TPM2 device. Installs a real build via
`cayo-ab-install-spike.sh --allow-file --encrypt-var` (no
`--mok-certificate`: that flag drives `mokutil --import` against the
*host's* live EFI variable store, which is wrong for a loopback install —
MOK enrollment happens entirely on the guest's OVMF varstore instead), types
the first-boot recovery passphrase on the serial console automatically (no
expect/socat on this host; a single Python process both logs and drives the
console — two separate connections to one `server=on,wait=off` QEMU chardev
socket do not both work, confirmed live), enrolls a signed-PCR-11 TPM token
in-guest exactly like `native-ab-secure-rotation-test.sh`'s `enroll_token`,
and proves unattended TPM auto-unlock survives a real signed update hop to a
new UKI. QEMU's `-tpmdev emulator` chardev must point at swtpm's `--ctrl`
socket, not `--server` — `--server` hangs QEMU at startup indefinitely (this
and other bugs found while building the harness are recorded in the test's
own comments). Requires `swtpm`/`swtpm-tools` and `virt-fw-vars`
(`virt-firmware` PyPI package); on a snosi dev host itself (read-only `/usr`
sysext overlay, no `apt-get install`), install both via Homebrew/`pip3
install --user`, and resolve `$SUDO_USER`'s real home for `PATH`/`HOME` since
plain `sudo` resets `$HOME` to `/root` (breaks `pip --user` site-packages
resolution). **`--full-window` is the Phase 5 exit-criterion mode** (default
mode unchanged without the flag): four real builds, N→N+1→N+2→N+3 secure
hops with exact `InstancesMax=2` slot accounting (root-label set exactly
{N+1,N+2} then {N+2,N+3}, each new version physically reusing the vacuumed
slot), explicit rollback via `bootctl set-oneshot` and return to default,
and boot-count fallback: N+3 re-armed to `+3-0`, its root corrupted from
the HOST while the VM is off, three power-cycles observed decrementing
`+2-1`/`+1-2`/`+0-3` via host-side read-only ESP loop-mounts between
cycles, fourth boot auto-selects N+2 under SB with TPM unlock and intact
state. swtpm terminates whenever its QEMU client exits, so each host-side
power-cycle re-arms swtpm against the SAME persistent `--tpmstate` dir
(never reinitialize it — the enrolled token's sealed state lives there);
guest-initiated reboots never hit this because QEMU stays alive. Phase 5
exit evidence: 120/120 assertions green (2026-07-15, snow-ab,
N=20260715042306 → N+3=20260715044206, fallback to N+2). NvPCR journal
errors are asserted PER BOOT (shared `assert_nvpcr_journal_clean` helper
called after every boot that reaches SSH — `journalctl -b` only sees the
current boot, so the earlier end-of-sequence-only checks silently missed
every boot before the last one), raising the totals to 58 (default mode) /
125 (`--full-window`); re-validated green 125/125 (2026-07-15, snow-ab,
N=20260715074012 → N+3=20260715075918, rollback and fallback to N+2).

**`snow-linux-live-setup.service` native-boot decision:** this unit's only
gate used to be a negative run-once marker
(`ConditionPathExists=!/var/lib/snow-linux-live-setup.done`), indistinguishable
from a freshly installed native A/B system's true first boot (fresh `/var`,
marker absent) — an unpatched native install would have created a
passwordless sudo `snow` user on first boot. Fixed by adding
`ConditionKernelCommandLine=snow-linux.live=1`, the same positive live-media
signal `docker.socket.d/override.conf`, `incus.socket.d/override.conf`, and
`brew-setup.service` already use (inverted: `!snow-linux.live=1`, since those
skip themselves on live media — `snow-linux-live-setup.service` is the
inverse case, it must run ONLY on live media). Decision: native Snow does
**not** get its own first-setup flow reusing this unit; a real installed
system simply never sets `snow-linux.live=1` and this unit correctly never
fires. `test/native-ab-secure-boot-test.sh` asserts the unit is
`ActiveState=inactive` with `ConditionResult=no` (not failed) on a fresh
native install, and that no `snow` user exists.

**Secure Snowfield: Surface module-trust decision + lockdown fix (Phase 6):**
`snowfield-ab` runs through the same `test/native-ab-secure-boot-test.sh`
harness as `snow-ab` (`PROFILE=snowfield-ab`; `IMAGE_ID` derives to
`snowfield`, which already routed it through the `HAS_DESKTOP` gate before
Phase 6). Two new pieces of coverage, both gated on `IMAGE_ID == snowfield`:

- `test/snowfield-artifact-test.sh` (new script, invoked by the harness
  right after the existing profile-neutral `native-ab-secure-artifact-test.sh`)
  proves, against a real built profile: the manifest contains every package
  parsed live out of `shared/kernel/surface/mkosi.conf` (39 packages) and no
  `linux-image-amd64`; the UKI's `.linux` section decodes (via `file`) to a
  `bzImage` whose embedded version string contains `-surface`;
  `/usr/lib/modules/<surface-kver>` exists in the root erofs artifact;
  firmware completeness is spot-checked by querying each firmware-carrying
  package's OWN dpkg file list (via `dpkg-query --admindir=<mounted
  root>/usr/lib/sysimage/dpkg`, the relocated in-artifact dpkg database) and
  confirming those exact paths exist on disk — not a hardcoded guess (real
  finding: `firmware-iwlwifi`'s ucode ships FLAT under
  `/usr/lib/firmware/iwlwifi-*.ucode`, no subdirectory); the UKI's initrd
  (extracted via `objcopy --dump-section .initrd=`) carries
  `dm-verity.ko`/`dm-crypt.ko`, the `tpm2-tss` dracut module +
  `libtss2-esys.so`, the `etc-overlay` dracut module, `erofs.ko`,
  `nvme.ko`/`usb-storage.ko`, dracut's own `qemu` module, and the Surface
  early-boot family (`surface_aggregator`, `surface_aggregator_registry`,
  `intel-lpss`, `intel-lpss-pci`, `8250_dw`, `hid-surface`, `surface_hid`,
  `surface_hid_core`, `surface_kbd`). **The harness's own flagged risk of
  "missing virtio in the surface kernel initrd" did not materialize:**
  dracut's `--no-hostonly` module selection (unmodified, pre-existing)
  already includes a `qemu` dracut module plus `virtio-gpu`/`virtio-rng`/
  `virtiofs`/etc. as loadable `.ko` files; the disk/net/PCI virtio drivers
  (`virtio_blk`/`virtio_scsi`/`virtio_pci`/`virtio_net`) don't appear as
  separate `.ko` files at all because this kernel's `.config` compiles them
  DIRECTLY INTO vmlinuz (confirmed against `modules.builtin`, alongside
  `ext4`, `vfat`, `dm-mod`, `tpm_tis`, `tpm_crb`, `xhci-hcd`, `xhci-pci`) —
  builtin beats "present in the initrd" for guaranteed early availability.
- A new "Step 3c" in the harness itself, run on first boot right after the
  existing (profile-neutral) lockdown assertion: `keyctl show
  %:.builtin_trusted_keys` holds an `asymmetric` module-signing key — and,
  strengthened in the Phase 6 review follow-up (2026-07-15), the SPECIFIC
  signing certificate is bound end-to-end: the harness extracts the
  embedded build-time certificate from the booted UKI's `.linux` payload
  host-side and asserts the guest module's `modinfo -F sig_key` equals the
  cert's SERIAL and the keyring entry's trailing hex equals the cert's
  SKID. Those are two structurally DIFFERENT identifiers (`sig_key` is the
  module PKCS#7 signerInfo's issuer+serial reference; the keyring
  description hex is the certificate's Subject Key Identifier), so naively
  grepping `sig_key` in `keyctl` output can never match — measured live on
  a snosi host (backports kernel), the snow-ab UKI, and the Surface
  vmlinuz, all three of which validated the extraction + both equalities;
  `isofs.ko` (a hardware-free filesystem module) and `surface_aggregator.ko`
  (a genuine Surface in-tree module) both report `modinfo -F signer` =
  "Build time autogenerated kernel key" with the SAME `sig_key` fingerprint
  (now asserted at fingerprint level, not just signer-CN level),
  and both load successfully; a trivial out-of-tree module built IN-GUEST
  against `linux-headers-surface` (gcc/make are present in the built image —
  base's own `Packages=` "Utilities" stanza; confirmed by mounting the
  built root artifact directly, since the profile's own `.manifest` JSON
  only lists packages installed at the PROFILE stage, not ones inherited
  from `base`, so `gcc`/`make` genuinely don't appear there despite being
  in the final rootfs) is genuinely unsigned and is REJECTED
  (`insmod: ERROR: could not insert module ...: Key was rejected by
  service`, `dmesg`: `Loading of unsigned module is rejected`).

**Decision (docs/native-ab-contracts.md §7 has the full writeup):**
in-tree Surface kernel modules do NOT need re-signing with the Secure
Boot/MOK key, and no second (linux-surface-authored) certificate needs
enrollment. `CONFIG_MODULE_SIG_ALL=y` signs every in-tree module — core and
Surface alike — with the kernel package's own per-build ephemeral key, and
that key is in the booted guest's builtin trusted keyring. Phase 8's
installer does not need a Surface-specific enrollment step. Re-run this
decision if the Surface kernel package ever changes to a differently-signed
or externally-supplied build.

**A real bug found and fixed while investigating (unrelated to the
module-trust decision itself, but found by the same first-boot lockdown
assertion the harness already runs unconditionally):** the very first
`snowfield-ab` run through this harness FAILED the pre-existing,
profile-neutral "kernel lockdown is in integrity or confidentiality mode"
assertion — `/sys/kernel/security/lockdown` read `[none] integrity
confidentiality` under fully enforced Secure Boot with a Measured,
MOK-signed UKI chain (64/65 assertions passed; only this one failed).
Root cause, confirmed via the `.config` shipped with `linux-headers-surface`
inside the built root artifact: `CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y`, and
a full grep of that same `.config` for `SECURE_BOOT`/`LOCK_DOWN` found no
build-time "raise lockdown when EFI Secure Boot is on" wiring at all —
concretely, `grep -n 'LOCK_DOWN\|SECURITY_LOCKDOWN' boot/config-6.19.8-surface-3`
against the cached `linux-image-6.19.8-surface-3` deb shows
`CONFIG_SECURITY_LOCKDOWN_LSM=y`, `CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y`,
`CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y`, and
`# CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY is not set` — but no
`CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT` line at all (not even as a commented-out
"is not set" — that symbol is a Debian/Ubuntu patch, not mainline, so its total
absence means the linux-surface source tree does not carry the SB→lockdown patch
at all) — unlike the backports kernel `cayo-ab`/`snow-ab` use, which evidently DOES
carry that wiring (Phase 5 never saw this). A related discovery while
diagnosing it: module-signature enforcement was NOT actually broken by
this — the unsigned test module in Step 3c was rejected even while lockdown
sat at `none`, meaning module-signing enforcement on this kernel is wired
directly to EFI Secure Boot detection independent of the Lockdown LSM's
reported level (`CONFIG_MODULE_SIG_FORCE` is also not set, ruling out that
mechanism) — but lockdown's OTHER protections (kexec restriction,
`/dev/mem`, debugfs, BPF, hibernation) were genuinely inactive, a real gap
distinct from (but adjacent to) the module-trust question. **Fix:** added
`KernelCommandLine=lockdown=integrity` to the SHARED secure fragment
(`shared/native-ab-secure/mkosi.conf`), not the generic `ab-root` fragment
(`cayo-ab-raw`, the never-signed dev fixture, also consumes `ab-root` and
must not have lockdown forced on it). `lockdown=` is a standard
`early_param` that only RAISES the compiled initial level
(`lock_kernel_down()` only takes effect when the requested level is
stricter), so this is a safe, idempotent floor for `cayo-ab`/`snow-ab` too —
their lockdown posture no longer depends on an accident of the backports
kernel's own Kconfig defaults, which the Surface kernel simply doesn't
share. Confirmed present in the rebuilt UKI's `.cmdline` PE section via
`objcopy --dump-section`. Rebuilding with the fix and re-running the full
harness turned the `dmesg` boot log's "Lockdown: systemd-logind:
hibernation is restricted" line from absent to present — direct evidence
the broader lockdown protections are now actually active, not just the
module-signing path that was already working by a separate mechanism.
**User-visible consequence, not just a security win:** `lockdown=integrity`
(and `confidentiality`) unconditionally blocks hibernation (S4) on ALL
three production profiles now carrying the explicit `KernelCommandLine=`,
including the snowfield laptop profile where hibernation is a real,
previously-working end-user feature — this is an intentional, accepted
trade-off of closing the lockdown gap, not an oversight. Suspend/resume
(S3) is unaffected by lockdown and must keep working. See the PENDING HUMAN
GATE checklist below, which now requires confirming S4 fails gracefully
(no crash/hang) on real hardware rather than expecting it to succeed.

**VM validation result:** `sudo PROFILE=snowfield-ab
test/native-ab-secure-boot-test.sh` (default mode, no `--full-window` —
see "PENDING HUMAN GATE" below for why) passed with the lockdown fix in
place: install, first boot under enforced SB, TPM enrollment/auto-unlock,
desktop assertions (`graphical.target`/`gdm.service`, the hicolor
icon-cache sysext fixture), Step 3c module-trust, and a full signed
N→N+1 secure update hop with `/var`+`/etc` persistence and rollback-entry
retention. `--full-window` (the complete N..N+3 + rollback +
boot-count-fallback window) was deliberately NOT run for snowfield in
Phase 6 — see `docs/native-ab-capacities.md` "PROVISIONAL-pending-hardware"
for why a second QEMU-only pass wasn't worth it ahead of the mandatory
hardware gate below.

**Empirical re-proof on a second consumer of the shared fragment
(2026-07-15, Phase 6 review follow-up):** `sudo PROFILE=cayo-ab
test/native-ab-secure-boot-test.sh` (default mode) — the FIRST-ever run of
this live-boot harness for the server profile — passed 47/47. This proves
(1) the backports kernel tolerates the explicit `lockdown=integrity` now on
the shared secure fragment (that kernel's own SB→lockdown wiring and the
explicit parameter coexist; the harness's unconditional lockdown assertion
read `none [integrity] confidentiality`), and (2) the `HAS_DESKTOP` gating
behaves for cayo (Step 5a/5b desktop assertions correctly skipped). The run
also root-caused a real server-profile difference in the harness itself:
cayo's initrd carries no plymouth, so the first-boot passphrase prompt is
systemd's raw TTY agent shape ending in `(press TAB for no echo)` + ANSI
reset AFTER the colon, which the console pump's original colon-at-end-of-
buffer regex could never match (first boot wedged until the SSH timeout);
the pump's prompt matcher now accepts both shapes (see `prompt_re` in
`test/native-ab-secure-boot-test.sh`).

**PENDING HUMAN GATE — representative Surface hardware validation:** QEMU
has no Surface-specific hardware (touch, pen, keyboard/cover, Surface
storage/network/power controllers), so everything above validates the
Secure Boot/TPM/lockdown/module-trust chain and the generic OS mechanics
only. The plan's actual Phase 6 exit criterion — "representative Surface
hardware passes installation, desktop boot, update, rollback, and fallback
with required modules loaded" — is out of scope for this machine and is a
checklist for the user to run on real Surface hardware:

1. Build and validate artifacts locally first (fast, no hardware needed):
   `just snowfield-ab` (or `mkosi --profile snowfield-ab build`), then
   `sudo test/snowfield-artifact-test.sh` and
   `OUTPUT_NAME=snowfield-ab test/native-ab-secure-artifact-test.sh ...
   single` (see `test/native-ab-secure-boot-test.sh`'s own invocation for
   the exact argument list).
2. Full QEMU regression before touching hardware:
   `sudo PROFILE=snowfield-ab test/native-ab-secure-boot-test.sh
   --full-window` — this has NOT been run for snowfield yet (Phase 6
   deliberately skipped it; see above) and should be green before spending
   hardware time.
3. On the real Surface device: build the network-installer ISO
   (`shared/native-installer/tools/build-iso.sh`, or reuse the published
   `isos/native/v1/` artifact — see "Installer ISO boot chain" and
   `docs/native-ab-contracts.md` §8), write it to USB with a raw `dd`/`cp`
   that preserves the ISO9660 volume ID (Ventoy/Rufus ISO-DD label-rewriting
   defeats the installer-medium self-refusal), enroll the Snosi MOK
   certificate (`mkosi.crt`) via MokManager during its signed-shim boot, then
   run `/usr/libexec/snosi-install --product snowfield-ab ...
   --encrypt-var --recovery-key-file <path outside the disk>` against the real
   disk. The full ISO -> non-interactive encrypted install -> MOK-enrolled
   enforced/unattended-boot flow is proven in QEMU for `cayo-ab`/`snow-ab` by
   `test/native-installer-e2e-test.sh` (Phase 8 exit, 75/75); this hardware
   step is the Surface-specific analogue of that harness. The older
   `test/cayo-ab-install-spike.sh` real-device path still works but is the
   superseded 8.1 spike, not the shipped `snosi-install` CLI.
4. Verify TPM enrollment (`systemd-cryptenroll --unlock-key-file=<recovery
   key path> --tpm2-device=auto --tpm2-pcrs= --tpm2-pcrlock=
   --tpm2-public-key=.snosi-private/pcr-signing.pub
   --tpm2-public-key-pcrs=11 <var device>` — mirrors `enroll_token` in
   `test/native-ab-secure-rotation-test.sh:319` exactly, including the
   `--unlock-key-file=`/`--tpm2-pcrlock=` flags: do not drop them, they are
   required to authenticate the enrollment and to pin the policy to raw
   PCR11-off/pcrlock-off) and confirm unattended reboot auto-unlocks `/var`
   with zero prompts.
5. Confirm hardware function under the installed, Secure-Boot-enforced,
   lockdown-active kernel: touch, pen, keyboard/type-cover, Surface storage
   controller, wifi/networking, and power management all work — this is the
   one thing no QEMU run can prove. Power management specifically means:
   - Suspend/resume (S3) MUST work — lockdown does not affect S3.
   - Hibernation (S4) is EXPECTED TO BE BLOCKED by `lockdown=integrity`
     (see the lockdown-fix note above) — do not treat a hibernation failure
     as a regression. Instead confirm the block is GRACEFUL: the attempt
     (e.g. `systemctl hibernate`) fails cleanly with a logged
     "Lockdown: ...: hibernation is restricted" denial and the system
     remains usable, rather than crashing or hanging.
   - battery status reporting works.
6. Publish a real N+1 build (or use the same local-HTTP-origin pattern the
   harness uses) and confirm a signed update hop, then explicit rollback
   (`bootctl set-oneshot`) and boot-count fallback (re-arm to `+N-0`,
   corrupt the root partition, power-cycle) all work with the SAME hardware
   still functional after each transition — repeat the Step 3c module-trust
   checks post-update to confirm the decision above still holds for
   whatever kernel build ships in the update.
7. Record results (pass/fail per item above, kernel/firmware versions,
   Surface model) back into `docs/native-ab-capacities.md`'s snowfield
   section and flip it from "PROVISIONAL-pending-hardware" once every item
   passes.

**Publication and signing pipeline (Phase 7).** `shared/native-ab/publish/`
has, on top of `prepare-native-publication.sh`: `publish-candidate.sh`,
`verify-remote.sh`, `promote.sh`, `withdraw.sh`, a shared `publish-lib.sh`,
and `generate-sbom.sh` (closes the old `docs/native-ab-contracts.md` §4
`.sbom.spdx.json` gap by generating a real SPDX 2.3 JSON document directly
from mkosi's own package manifest — no `syft`, no network, no root; see the
script's header for why `syft` was investigated and rejected). Every script
takes a `dest` (`/local/dir` for rehearsal, or `rclone:<remote>:<bucket>
[/prefix]` for a real remote — see `publish-lib.sh`'s header) and, for
`verify-remote.sh`/`promote.sh`, a separate HTTP `base-url` (the public read
path — writes go through `rclone`, verification/re-signing reads back over
HTTP). `promote.sh` is the only script touching the private key
(`--signing-key <file>` imported into an ephemeral GNUPGHOME, or
`--gnupghome <existing homedir>` — never hardcoded); it re-downloads every
final object over HTTP to hash before regenerating `SHA256SUMS` (never
trusts local disk), archives the outgoing signed pair to
`.history/<version>/` before overwriting it (**only if that outgoing pair
itself still verifies against `--pubring`** — an already-broken outgoing
index is skipped rather than clobbering a good archive from an earlier
promotion; root-caused live during the Phase 7 rehearsal's own tamper-case
sequencing, see `docs/native-ab-publication.md`/the Phase 7 task report),
and publishes `SHA256SUMS.gpg` strictly before `SHA256SUMS`, both
`Cache-Control: no-store`. `withdraw.sh` `gpgv`-verifies an archived pair
against the pubring before touching anything live and refuses outright on a
missing or mismatched pair. Full operational runbook (key ceremony,
candidate->verify->promote->purge with real `rclone`/Cloudflare commands,
retention, interim protected-builder constraints):
`docs/native-ab-publication.md`. Local rehearsal, no real R2/Cloudflare:
`test/native-ab-publication-test.sh` (QEMU, needs root/KVM, builds real
`cayo-ab-raw` images — deliberately NOT `cayo-ab`, since the DEV pubring
ships on every native A/B image regardless of Secure Boot posture and this
test is about the update-signature trust path, not the boot-chain trust
path) and `test/native-publication-pipeline-test.sh` (fast, synthetic
fixture, wired into `validate.yml`). Both serve their local HTTP origin with
`test/lib/range-http-server.py`, not plain `python3 -m http.server` — the
stdlib's `SimpleHTTPRequestHandler` has no Range support at all (confirmed
against the Python 3.13 stdlib source), which would make `verify-remote.sh`'s
mandatory range-GET check silently meaningless.

### Installer ISO (Phase 8)

`mkosi.profiles/native-installer/` is a payload-free network-installer image
(no Snow/Snowfield/Cayo content, `Dependencies=`/`BaseTrees=` both reset to
empty so it never inherits the shared bootc/sysext base). `Bootable=no`:
mkosi's own UKI/systemd-boot signing is unused entirely. mkosi has no ISO/El
Torito output format at all, so `shared/native-installer/tools/build-iso.sh`
assembles the actual bootable ISO OUTSIDE mkosi (same pattern as
`shared/outformat/image/buildah-package.sh`), pulling docs/native-ab-contracts.md
§8's Debian-trusted chain (shim-signed, grub-efi-amd64-signed,
shim-helpers-amd64-signed for MokManager, linux-image-amd64 -- all
Debian-signed packages, not anything this repo signs) straight out of the
built rootfs. The installer userspace is the ENTIRE built rootfs packed as
the kernel's own initramfs (cpio+zstd, no dracut, no switch_root — a
top-level `/init -> usr/lib/systemd/systemd` symlink means systemd just
boots directly as PID 1 with the packed tree as final root).

Three boot-chain gotchas, all root-caused live by bisection (full detail:
`docs/design/overview.md` "Installer ISO"): (1) `grub-efi-amd64-signed`'s prefix is
baked in at `/EFI/debian` — `grub.cfg` must live there, AND ALSO be
duplicated into the plain ISO9660 tree (not just the appended FAT ESP
partition), since GRUB's prefix search resolves against the ISO9660 volume
specifically when booted through real El Torito/CD-ROM emulation. (2)
`fbx64.efi` (the shim fallback/NVRAM-registration loader) must NEVER be
shipped in `EFI/BOOT/` alongside shim — its mere presence makes OVMF reset
the machine instantly with zero diagnostic output, before shim even
attempts to load GRUB; `mmx64.efi` (MokManager, the thing actually needed)
is unaffected and ships normally. (3) The kernel command line must be
`console=ttyS0,115200n8` ONLY — adding a second `console=tty0` hangs PID 1
completely silently, but only when Secure Boot is enforced against a
POPULATED varstore (real Microsoft PK/KEK/db) with no GPU device attached;
this looks exactly like a kernel/systemd deadlock (ruled out systemd-pstore,
systemd-udev-trigger, systemd-journal-flush, and the audit subsystem
individually before finding it) until traced to that one kernel argument.
Separately, `Locale=`/`Keymap=`/`Timezone=`/`Hostname=`/`RootPassword=hashed:`
must all be set explicitly (mkosi runs `systemd-firstboot` at build time),
or `systemd-firstboot.service` blocks the whole boot forever on an
interactive prompt with no TTY to answer it — same silent-hang shape as (3),
different root cause.

`test/native-installer-iso-test.sh` validates: ESP structural checks
(signed-binary issuer strings via `sbverify`, packed-initramfs content,
systemd-family version, the version-stamped filename/volid/release-file —
below), a QEMU positive boot with Secure Boot ENFORCED against a
freshly-copied, NEVER-enrolled `OVMF_VARS_4M.ms.fd` (must reach SSH with
`mokutil --sb-state` reporting enabled), and a negative proof on the SAME
never-enrolled varstore — grub's own unsigned monolithic EFI image,
signed with the project's real `mkosi.key`/`mkosi.crt` in place of the
trusted GRUB, must be rejected by shim itself ("Security Violation"),
proving the positive boot is a genuine enforcement result and not an
accidentally-permissive OVMF config. `check-native-publication-guard.sh`
already excludes `native-installer` (it only matches `cayo-ab`/`snow-ab`/
`snowfield-ab` by literal name) — no code change was needed there.

`shared/native-installer/tools/build-iso.sh` takes an OUTPUT DIRECTORY (not
a caller-chosen file path) and always writes the frozen public name
(`snosi-native-installer_<version>_x86-64.iso`, docs/native-ab-contracts.md
"Installer ISO"), embedding VERSION in both the ISO9660 volid and a
`/etc/snosi-installer-release` file written into the packed rootfs at
assembly time (VERSION is only known then, not at the earlier `mkosi build`
time). The profile also ships hardware firmware (`shared/kernel/stock/
mkosi.conf`'s full `firmware-*` set plus snow/cayo's per-vendor extras) so
network installs work on real machines, not just virtio-only QEMU fixtures.

**`shared/native-installer/tree/usr/libexec/snosi-install`** (Task 8.2) is
the real product-aware CLI installer, replacing the phase-8.1 placeholder
(`test/cayo-ab-install-spike.sh` shipped verbatim at
`/usr/libexec/snosi-install-spike` — that spike script itself is UNCHANGED
and still what every existing QEMU harness drives; its GPT-relocate/
var-grow/LUKS logic is PORTED, not sourced, into `snosi-install`). Full
21-step interactive + `--non-interactive` flow (every prompt has a flag),
plus `snosi-install --restage-mok` recovery for a skipped/mistyped/timed-out
MokManager enrollment. Fetches and `gpgv`-verifies the product's signed R2
index against `/usr/lib/snosi/os-update-pubring.gpg`, streams the decompressed
disk image onto the target while hashing the compressed bytes received
(wipes the partition table on ANY mismatch — see the script's own header
for the full design rationale), extracts the TPM PCR-11 signing public key
from the disk's OWN just-written UKI (`objcopy --dump-section .pcrpkey=`,
self-contained, no external key), and enrolls TPM/MOK exactly matching
`test/native-ab-secure-rotation-test.sh`'s `enroll_token`. MOK enrollment is
genuinely non-interactive-capable via `mokutil --generate-hash`/`--import
--hash-file` (not a workaround — a real, if under-documented, mokutil
feature). Root SSH key install writes into the persistent `/etc` overlay
upperdir (`/root` is dm-verity-sealed read-only, always) via a new
`AuthorizedKeysFile` drop-in shipped on the installed product,
`shared/outformat/ab-root/tree/etc/ssh/sshd_config.d/
10-snosi-authorized-keys.conf`. **First-user creation** (2026-07-16, found
because a fresh native snow install boots to an unusable GDM greeter —
`snow-first-setup` is an XDG *autostart*, post-login only, so nothing can
create the FIRST user; the contract assigns that to the installer):
interactive prompts (empty username skips, with a warning) or
`--username`/`--user-password-file`(0600-checked, pre-download)/
`--user-fullname`/`--no-create-user`. `seed_first_user()` ro-mounts the
just-written root erofs for the image's pristine `/.etc.lower` baseline
(uid/gid allocation from ≥1000, group existence, `/etc/skel`, the `shadow`
group's numeric gid for file ownership), copies passwd/group/shadow/gshadow
into the `/etc` overlay upper on var with the new account appended
(SHA512-crypt via `openssl passwd -6 -stdin`), joins `sudo` (Debian's admin
group — warns loudly if the image lacks it) plus the standard desktop set
(adm cdrom dip video plugdev users netdev lpadmin scanner audio, each only
if the image defines it), and creates the skel-seeded home at var `home/`
(image `/home` → `/var/home`). The wholesale passwd copy-up is the overlay
steady state anyway — systemd-sysusers rewrites `/etc/passwd` on first boot,
which copies it up regardless. **System settings + deferred first-boot
provisioning** (Phase 1 of the first-boot design, 2026-07-16; the GTK
installer frontend is the planned Phase 2): `--hostname`/`--locale`/
`--timezone`/`--keyboard` (interactive prompts with defaults; `-` skips a
setting) are plain `/etc`-overlay-upper writes at seed time (`hostname`,
`locale.conf` `LANG=`, `timezone`+`localtime` symlink, `vconsole.conf` XKB
triplet matching first-setup's format), while the two duties that NEED the
booted target — sysext feature enablement and the core desktop Flatpak set —
are only RECORDED at install time (`--enable-feature` repeatable,
`--core-flatpaks`/`--no-core-flatpaks`; desktop products default to core
flatpaks on, `cayo-ab` refuses the flag) into `/var/lib/snosi/first-boot.json`
and performed by **`snosi-firstboot.service`** (`shared/outformat/ab-root/
tree`, static-wants infra unit, `After=network-online.target`,
`TimeoutStartSec=0`): `updex --silent features enable <f> --now` per feature
(verified against updex 1.3.0 source — `features enable` reads the union of
the legacy dir and every discovered component, so the per-component sysext
migration needs no syntax change) plus flathub system remote + the core set
read from snow-first-setup's OWN `core.json`
(`/usr/share/org.frostyard.FirstSetup/snow_first_setup/core.json`, single
source of truth with its Mode 3 wizard; deduplicated — the list has carried
duplicates), skipping gracefully where flatpak/core.json are absent (cayo).
Retry semantics: any failure exits 1 WITHOUT the
`/var/lib/snosi/first-boot.done` marker so the unit re-runs next boot; every
operation is idempotent. This division retires first-setup's Mode 2 on
native installs (Mode 1/nbc is retired with nbc; Mode 3 per-user login
wizard is unchanged and verified working on native).
`test/snosi-firstboot-test.sh` (fixture, PATH-stubbed updex/flatpak, wired
into `validate.yml`) covers the fan-out, dedup, retry, and no-op paths.
`shared/native-ab/keys/mok-2026.crt`
(committed public certificate — a plain copy of gitignored `mkosi.crt`, safe
to commit for the same reason as `import-pubring.gpg`; shipped in-image at the
version-neutral path `/usr/lib/snosi/mok.crt`) ships alongside the pubring via
`ExtraTrees=`. `test/snosi-install-test.sh` covers the pure logic (index
parsing/verification, disk-refusal filters, argument validation matrix,
streamed-verify mismatch handling, restage-mok argument handling) via
fixtures, wired into `validate.yml`; full disk-write/LUKS/TPM/MOK behavior
is proven end to end by `test/native-installer-e2e-test.sh` (Phase 8 exit —
see "Phase 8 exit: real ISO install proof" below), which drives a real
build+publish+install+enrolled-boot of `cayo-ab` and `snow-ab`. Known
limitation: the installer-medium self-refusal (`disk_is_installer_medium()`)
detects the ISO's ISO9660 volume ID, so label-rewriting USB writers (Ventoy,
Rufus in ISO/DD mode) that strip or replace that volume ID when staging the
image defeat the check, while a raw `dd`/`cp` of the ISO preserves it and is
correctly detected. Full design notes: `docs/design/overview.md` "snosi-install CLI
(Task 8.2)".

**Graphical setup wizard (`shared/native-installer/setup-gui/`, 2026-07-17):**
`snosi-install` now also carries a machine-readable GUI contract —
`--print-defaults` (products with capacity floors + per-product core-flatpaks
policy, interactive defaults, every validation regex), `--list-disks-json`
(installable disks + refusal reasons), and `--json-progress` (line-delimited
proto-1 event stream: `start`/`phase`/`log`/`error`/`done` at main()'s nine
section boundaries; byte-level download progress is deliberately NOT in proto
1 — the download is a five-stage pipeline with no clean byte hook, and
receivers must ignore unknown events so it can be added compatibly). The GTK4/
libadwaita kiosk `snosi-setup` (in-tree Python/GI package, installed to
`/usr/lib/snosi-setup`, launcher symlink `/usr/bin/snosi-setup`; GTK-free
`setup_gui/model.py` holds all logic — validation, argv assembly, event-stream
parsing — with `test/snosi-setup-model-test.py` covering it, wired into
`validate.yml`) drives exactly one `snosi-install --non-interactive
--json-progress` invocation and performs no privileged operation itself.
**Page-protocol gotcha:** `SetupWindow._show` disables Next on every page
transition; each page's `set_page_active()` must re-enable it (the `Page`
base does `set_ready(True)`), so an override that forgets leaves Next
permanently disabled — the features page shipped exactly that bug when its
catalog-fetch override landed (fixed 2026-07-20: the page is fully optional,
so it enables Next unconditionally via `super().set_page_active()`).
`test/snosi-setup-pages-test.py` (widget-level, wired into `validate.yml`,
skips cleanly with exit 0 where GTK4/libadwaita or a display is missing)
regression-tests it. **Activation is a static wants link + unit Conditions** (`snosi-setup.service`,
`ConditionPathExistsGlob=/dev/dri/card*`,
`ConditionKernelCommandLine=!snosi.textmode=1`), with `getty@tty1` stopped
IMPERATIVELY in `ExecStartPre`, never via `Conflicts=`: Conflicts stops the
conflicting unit at transaction-build time, BEFORE this unit's Conditions
evaluate, so a statically-wanted unit with Conflicts kills getty even on the
no-display boot where its own Condition then fails — ExecStartPre runs only
after Conditions pass, i.e. only when the kiosk really starts, so the
text-mode fallback never loses getty (and `OnFailure=getty@tty1` restores it
on a crash-loop). A udev DRM device-pull was tried and abandoned: DRM cards
emit an `add` then a `bind` uevent and the `bind` drops `:systemd:` from the
device's CURRENT_TAGS at coldplug, so the `.device` unit never pulled the
kiosk on a real boot (it worked only on a manual `udevadm trigger`). The ISO
gains the cage/GTK4/Mesa-llvmpipe/python3-gi/cantarell stack plus the picker
data files (`locales`/`xkb-data`/`tzdata`, else the pickers silently degrade).
The ~1.6 GB uncompressed rootfs zstd-compresses to a ~590 MB packed
initramfs, so the GUI ISO is ~700 MB — only ~100 MB more than the ~600 MB
text-only ISO. **ISO size is NOT a reliable text-vs-GUI discriminator**
(they are ~100 MB apart); check for `usr/bin/snosi-setup` in the packed
initramfs instead. **Feature catalog (2026-07-17):** the wizard's
sysext page is a checkbox list, not a type-the-id field. Source of truth:
each product build generates a product-curated catalog
(`shared/outformat/ab-root/finalize/features-catalog.finalize`, non-chroot,
reads `$BUILDROOT/usr/lib/sysupdate.*.d/*.feature`) written in-image at
`/usr/share/snosi/features.json` AND published as the frozen
`<channel>_<version>.features.json` (contract §4, listed in the signed
SHA256SUMS). Curation via `X-Snosi-Products=` in a `.feature` file
(comma-separated bare products; absent = all — ten desktop-only features
carry `snow,snowfield`); verified live that systemd-sysupdate 261 (zero
warnings at debug) and updex ≥1.3.0 both ignore the key cleanly.
`snosi-install --print-features --product X` fetches it hash-verified via
the signed index (GUI page + the text-mode numbered prompt both use it);
releases predating the catalog fall back to manual entry, and
`snosi-firstboot` skips seeded features the installed image doesn't define
(warn, no retry-forever). `test/snosi-setup-boot-test.sh` (local, root+KVM,
not in CI) boots the real ISO twice under enforced Secure Boot — virtio-vga
(kiosk up: cage + the GTK app, getty yielded, no crash loop) and no-display
(getty fallback, Condition-skipped cleanly) — 13/13; the serial text flow is
never affected either way. Design/plan: `docs/plans/2026-07-17-graphical-
installer-plan.md`.

The Phase 7 candidate/verify/promote/withdraw publication pipeline
(`shared/native-ab/publish/`) now also publishes this ISO, under the flat
`isos/native/v1/` namespace (docs/native-ab-contracts.md §5) via a new
`prepare-iso-publication.sh` and a `dest_path` field in
`publication-info.json` (`publish-candidate.sh`/`promote.sh` read it instead
of always deriving `os/native/v1/<product>/x86-64`; `withdraw.sh` grew an
optional `--dest-path` override). See `docs/native-ab-publication.md`
"Installer ISO publication" for the operational runbook and
`docs/design/overview.md`'s "Publication pipeline generalization for the ISO" for
a latent `promote.sh` bug this generalization surfaced and fixed (an
outgoing-index archival regex that only matched `*.manifest.json` entries,
silently killing `promote.sh` via `set -e`+`pipefail` on the second
promotion of any publication type with none — the ISO has none).

**Stable installer download URL:**
`https://repository.frostyard.org/isos/native/v1/snosi-native-installer-latest-x86-64.iso`
is an uncacheable `302` served by `workers/native-installer-redirect/`. The
Worker reads the live `isos/native/v1/SHA256SUMS` through a direct R2 binding,
strictly selects its single frozen installer filename, confirms the target
exists, and redirects to the immutable object; it has no separate latest state
and never proxies ISO bytes. Do not replace this with bucket listing, a mutable
ISO alias, or a hardcoded version. The redirect is discovery only:
`SHA256SUMS.gpg` plus the listed SHA-256 remain the trust boundary. Edge code
deploys separately via `deploy-native-installer-redirect.yml`; every ISO
promotion and withdrawal must run `verify-installer-redirect.sh` only AFTER
`verify-published-index.sh` authenticates the served index.
The binding's production bucket is `frostyardrepo` (the same value as
`NATIVE_R2_BUCKET`); the deploy workflow compares config to that secret and
requires `wrangler r2 bucket info` to succeed before deployment. This guard is
load-bearing because Wrangler 4 auto-provisions a missing named bucket -- a
stale `frostyard-repository` example created an empty wrong bucket during the
first deployment and left the Worker returning `503`.
`CF_WORKERS_API_TOKEN` deliberately has R2 Storage READ, never WRITE: it needs
to inspect the existing bucket during preflight, while missing-resource
provisioning must fail at authorization even if the config/secret guard regresses.

### Phase 8 exit: real ISO install proof

`test/native-installer-e2e-test.sh` is the Phase 8 exit criterion — the sole
test proving a user can take the shipped network-installer ISO to a running,
Secure-Boot-enforced, TPM-unlocked native A/B system on stock artifacts, no
keyring injection, no hand-editing. Per run it builds the ISO fresh (so commit
99f4921's own-boot-medium refusal is exercised in the REAL initramfs, not a
fixture) and builds+publishes `cayo-ab` and `snow-ab` through the actual
`prepare -> publish-candidate -> verify-remote -> promote` pipeline (DEV signing
key) to a local origin served by `test/lib/range-http-server.py`; trust leg is
the stock shipped `import-pubring.gpg`. Per product it boots a VM with a VIRGIN
never-enrolled `OVMF_VARS_4M.ms.fd` + persistent swtpm against a blank disk sized
to the product's `minimum_disk_bytes()` (sourced from `snosi-install`, not
duplicated) plus a 3 GiB margin so grow-to-end runs, then drives seven steps:
(2) ISO boots to installer with SB enabled; (3, cayo-ab only) own-boot-medium
install refused before any write to the ISO device; (4) non-interactive
encrypted-`/var` install (recovery key, TPM enroll, MOK password file — first
proving a world/group-readable file is refused), asserting one `systemd-tpm2`
LUKS token, a recovery keyslot, a grown `var`, and `--test-passphrase` unlock;
(5) pre-enrollment boot fails with shim's Security Violation; (6) `--restage-mok`
succeeds (cayo-ab gets a dedicated fresh-ISO-boot restage; snow-ab skips it);
(7) host-side `virt-fw-vars --add-mok` into the SAME varstore simulates
MokManager approval, then the installed system boots fully enforced and fully
unattended — asserting SB enforced, kernel lockdown, `/var` on the LUKS mapper
via unattended TPM unlock, the `/etc` overlay, `IMAGE_ID`/`IMAGE_VERSION`, every
`install-info.json` field, clean `snosi-update-status`, no failed units, and that
the recovery passphrase still opens `/var`. cayo-ab runs the full sequence;
snow-ab runs steps 2, 4, 5, 7; `snowfield-ab` is behind `--with-snowfield` (off
by default — QEMU cannot represent Surface hardware). Two Step-7 device details
matter: the final boot detaches the ISO so the target disk shifts from `/dev/vdb`
to `/dev/vda` — derive the `/var` backing partition from the open mapper
(`cryptsetup status var`), never from a device letter captured on an
ISO-attached boot; and `--test-passphrase` (a read-only header check) is used
rather than `cryptsetup open` of a second mapper, because the installer's own
`systemd-gpt-auto-generator` legitimately auto-activates the `var` GPT-type
partition once it is a valid LUKS2 volume and holds the device busy.

First green run 75/75 (2026-07-15, cayo-ab full + snow-ab partial, ISO
ISO `snosi-native-installer_20260716003626_x86-64.iso` (product images 20260715203830/20260715204023), ~17 min wall). The test also fixed real product bugs it
surfaced: the network-installer ISO was missing `fdisk` (ships `sfdisk`, which
moved out of `util-linux`), `binutils` (`objcopy`, for `.pcrpkey` extraction),
and `openssl`; and `snosi-install` wrote several tool-diagnostic streams to
stdout instead of stderr (corrupting values captured by command substitution),
dumped a UKI section to `/dev/null` (objcopy always exits 1 doing that — now a
real scratch file), and did not retry the LUKS mapper close. Full step breakdown
and bug list: `docs/design/testing.md` "Phase 8 (ISO install end-to-end)".

### Native `/var` Factory State

The native installer creates a fresh per-machine `/var`; nothing written to
image `/var` at build time survives an install (see the disk-layout note in
"Native A/B Prototype" above). This applies just as much to `cayo`/`snow`/
`snowfield` bootc images: repart's `11-root.conf`/`21-root-empty.conf`
(`ExcludeFilesTarget=/var/`) and `30-var.conf` (no `CopyFiles=`) mean the
disk image's `var` partition ships EMPTY from the build itself — the
installer doesn't need to wipe anything, there is nothing there to begin
with. Two build-time mechanisms cover this:

**A. The `/var` inventory audit** (`shared/composition/var-audit.finalize`,
a non-chroot `FinalizeScript` — it runs on the host and reads `$BUILDROOT`,
`$SRCDIR`, `$IMAGE_ID` directly, no `mkosi-chroot` needed) walks every file,
symlink, and EMPTY directory under `$BUILDROOT/var` at the end of the
build (non-empty directories are represented by their contents, not
themselves) and classifies each against a per-product outcome map:
`shared/composition/cayo/var-outcomes.txt` (used by `cayo` bootc AND
`cayo-ab-raw`/`cayo-ab` native, since they share
`shared/composition/cayo/mkosi.conf`) and `shared/composition/
snow/var-outcomes.txt` (used by `snow`/`snowfield` bootc AND `snow-ab`/
`snowfield-ab` native, since they share `shared/composition/snow/mkosi.conf`).
Map format: `<glob><TAB><outcome>`
per line, `#` comments, outcome one of:

- `image-metadata` — belongs to the immutable root (the dpkg database and
  the compiled aspell dictionaries; see B below).
- `tmpfiles` — a shipped `/usr/lib/tmpfiles.d/*.conf` rule recreates this
  path (directory or symlink) on every boot.
- `discard` — build residue, deliberately lost (caches, logs, machine
  state, dpkg/apt/ucf/deb-systemd-helper bookkeeping, package-trigger
  scratch state).
- `installer-seed` — written by the installer after `mkfs` (none yet).

The audit FAILS the build on any unclassified path (with the full list) or
any map glob that matched nothing in that build ("stale" — keeps the map
from silently drifting from reality), and on success writes `usr/share/
snosi/var-inventory.txt` (`<outcome>\t/var/<path>`, sorted) into the image.
Wired as the LAST `FinalizeScripts=` entry in
`shared/composition/{cayo,snow}/mkosi.conf`, after the shared image
finalize (`shared/outformat/image/finalize/mkosi.finalize.chroot`, which
does the dpkg relocation below) — verified via `mkosi --profile <p>
summary` that this resolves to `[image finalize.chroot, var-audit.finalize,
ab-root finalize.chroot]` for native profiles; `shared/outformat/ab-root/
finalize/mkosi.finalize.chroot` runs after the audit but never touches
`/var` (only `/etc`), so the ordering is safe.

**Updating a map when a package adds new `/var` state:** a build failure
lists every unclassified path. Classify each: if a shipped tmpfiles rule
already creates it (check the actually-built image's `/usr/lib/tmpfiles.d/`,
not just this repo's hand-authored overlay — most of a Trixie desktop's
tmpfiles rules are package-shipped, e.g. `dbus.conf`, `colord.conf`),
outcome is `tmpfiles`; otherwise default to `discard` with a one-line
comment UNLESS a booted system plainly needs it (chase it to a tmpfiles fix
or flag it, don't silently discard). List more specific globs before
broader ones matching the same subtree — the audit classifies by the FIRST
matching glob, top to bottom, and only that glob counts as "used" for the
stale check. A path that can appear in two structurally different shapes
across builds (see the dpkg example below) needs ONE glob with a bare `*`
covering both shapes, not two separate globs — with two globs, whichever
shape didn't occur in a given build makes the other glob spuriously
"stale" and fails that build.

**B. dpkg database relocation (native only).** The native-gated block in
`shared/outformat/image/finalize/mkosi.finalize.chroot` (guarded by the
same `/usr/lib/snosi/native-ab` marker as the sysupdate-timer masking
above) moves `/var/lib/dpkg` to `/usr/lib/sysimage/dpkg` and leaves a
RELATIVE symlink (`../../usr/lib/sysimage/dpkg`) in its place, BEFORE the
audit runs. `mkosi`'s own package-manifest generation
(`manifest.record_packages()` → `dpkg-query --admindir=$BUILDROOT/var/lib/
dpkg`) runs earlier in the build, before any `FinalizeScripts` execute, so
the relocation never affects the generated package manifest. A matching
native-only tmpfiles rule, `shared/outformat/ab-root/tree/usr/lib/
tmpfiles.d/00-snosi-dpkg.conf`, recreates the same symlink on a fresh
installer-created `/var`. **The `00-` filename prefix is load-bearing**:
apt's own shipped tmpfiles rule (`apt.conf`) also creates `/var/lib/dpkg` as
a plain directory, and `tmpfiles.d(5)` resolves same-path conflicts across
files by lexicographic filename order (earliest-named file's line wins,
the rest are logged as harmless "duplicate" errors, not a boot failure —
verified locally with `systemd-tmpfiles --create --root=<scratch>`);
renaming this file changes which one wins. bootc images (`cayo`, `snow`,
`snowfield`) are unaffected: the relocation only runs when
`/usr/lib/snosi/native-ab` exists, so their real `/var/lib/dpkg` ships
unchanged, same as before this change — verified directly on a built
`snow` image (`var/lib/dpkg` is a real, populated directory there, not a
symlink). This is also why the outcome maps need a single `lib/dpkg*`
glob rather than separate exact/subtree globs: the SAME map file classifies
both the native relocation-symlink shape and the bootc real-directory
shape, in different builds.

**Compiled aspell dictionaries get the identical treatment** (same
native-gated finalize block): `/var/lib/aspell/*.rws` are generated by the
`aspell-autobuildhash` dpkg trigger at package-configure time, are NOT
dpkg-tracked (confirmed via `dpkg -L aspell-en`, which lists only the
static `/usr/lib/aspell/*.alias` files), and are reached at runtime through
ABSOLUTE `/usr/lib/aspell/<dict>.rws -> /var/lib/aspell/<dict>.rws`
symlinks in aspell's dict-dir — on a fresh installer-created `/var` those
symlinks dangled and spell-checking silently lost every dictionary (the
audit's original flagged gap). The trigger never reruns on a booted
immutable image, so the dictionaries belong to the immutable root:
`/var/lib/aspell` is relocated to `/usr/lib/sysimage/aspell` with the same
relative symlink left behind, and `shared/outformat/ab-root/tree/usr/lib/
tmpfiles.d/00-snosi-aspell.conf` recreates the symlink on a fresh `/var`
(the `00-` prefix beats the base image's own `aspell.conf` directory rule,
exactly like `00-snosi-dpkg.conf` vs `apt.conf`). The relocation runs even
where the directory is empty (`cayo` — aspell/aspell-en are snow-only
packages) so every native product ships one shape and the shared tmpfiles
rule never dangles; both maps classify it `lib/aspell*	image-metadata`
with the same dual-shape bare-`*` glob as dpkg.

`test/native-ab-components-test.sh`'s "Step 1.5: factory /var" block
verifies all of this on a booted native image: the dpkg and aspell
symlinks' exact targets, `/usr/lib/sysimage/aspell` present, `dpkg-query -W
systemd`/`dpkg-query -W 'linux-image-*'` both resolving,
`usr/share/snosi/var-inventory.txt` present with at least one
`image-metadata` line including `/var/lib/aspell`, and no new failed
units.
