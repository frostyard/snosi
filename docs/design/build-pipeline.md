# Build pipeline

Decisions: [ADR-0001](../adr/0001-var-factory-state-outcome-maps.md)
(`/var` inventory), [ADR-0002](../adr/0002-ship-no-enablement-symlinks-in-etc.md)
(presets), [ADR-0004](../adr/0004-sysext-authoring-rules.md) (sysexts),
[ADR-0005](../adr/0005-profiles-as-transport-kernel-selectors.md)
(composition), [ADR-0012](../adr/0012-chunked-layers-cadence-xattrs-chunk-before-seal.md)
(OCI chunking), and [ADR-0018](../adr/0018-remove-native-ab-and-nbc-lanes.md)
(bootc-only output). Removed native mechanisms are recorded in
[prototype history](../native-ab-prototype-history.md).

## Deployment package metadata

The product `package-metadata.finalize` runs after package installation and
the main image finalize. It copies the full dpkg database into
`/usr/lib/sysimage/dpkg`, then installs `shared/outformat/image/dpkg.conf` as
`/usr/lib/tmpfiles.d/dpkg.conf`. Installing this rule after the snapshot is
essential: mkosi runs tmpfiles before finalizers, when base and product roots
still need a normal writable database. The shipped rule maintains per-file `L+`
links for `status`, `info`, `triggers`, `diversions`, `available` and
`arch-native` from `/var/lib/dpkg` to that snapshot. At boot it replaces stale
identity files and populated directories; repeated runs repair the same links.
See [ADR-0021](../adr/0021-query-deployment-package-metadata.md).

The parent `/var/lib/dpkg` remains a real directory. `alternatives/`,
`statoverride`, `lock*`, `updates/` and `parts/` remain real writable state.
Debian's dpkg-query binary and dpkg defaults stay unchanged. apt, PackageKit,
python-apt and scanners reading the standard status path therefore see the
same deployment identity after tmpfiles runs. Administrator alternatives
choices remain writable and persist across updates.

Mutable host package changes remain unsupported. In particular,
`dpkg-divert --add` can replace the `diversions` link with a local file;
the next tmpfiles run restores the link, discarding those local metadata
changes. Rollback between fixed images selects the earlier snapshot.
**Rollback to a pre-fix image leaves dangling links** because it lacks the
snapshot: dpkg-query reports no packages and apt lists none until rolling
forward. This is the one rollback across the transition.

The frozen `/usr/share/frostyard/<image>.packages.txt` API is unchanged.
Run `python3 test/live/package-metadata.py` after a fresh installation, two
successive image updates, and rollback: it compares package queries and apt
against the frozen inventory and running systemd/bootc versions, and checks
the link layout. Fixture coverage in `test/package-metadata-test.py` does not
replace these live lifecycle checks.


## Configuration and script phases

The root `mkosi.conf` depends on `base` and all sysexts for `just sysexts`.
Each of the four bootc profiles clears inherited `Dependencies=` before
adding `Dependencies=base`. Profiles include
`shared/packages/bootc/mkosi.conf`, `shared/bootc-secure/mkosi.conf`, their
product composition and kernel fragments, and
`shared/outformat/image/mkosi.conf`. `shared/composition/floe/`,
`shared/composition/snow/` and `shared/composition/sundog/` collect package,
tree and script inputs; Snowfield shares Snow's composition with the Surface
kernel. Include order controls mkosi list-valued settings (`Packages=`,
`FinalizeScripts=`, etc.): confirm a changed order with `mkosi summary`.
`check-profile-dependencies.sh` guards against rebuilding sysexts for every
profile. mkosi's `ToolsTree=default` uses `mkosi.tools.sandbox/`; target APT
settings use `mkosi.sandbox/`. Network retry/timeouts need both trees.

Snow, Snowfield and Sundog install `fprintd` and `libpam-fprintd` for desktop
fingerprint authentication. The shared desktop tmpfiles rule creates
`/var/lib/fprint` with mode 0700; fprintd also declares it as a systemd state
directory. Its D-Bus service starts on demand. Debian's fprintd PAM profile
remains disabled in `common-auth`; enrollment and broader PAM use are optional
([user guidance](../installing.md#fingerprint-readers)).

A file that replaces a package's dpkg conffile (for example
`etc/plymouth/plymouthd.conf`) ships through `ExtraTrees=`, which lands after
dpkg runs. Never ship it through `SkeletonTrees=`: dpkg then finds a
pre-existing conffile, prompts, and the build fails at EOF on mkosi's
non-interactive stdin (`shared/composition/snow/mkosi.conf`).

Image builds have four phases, in order:

1. **BuildScripts:** `shared/scripts/build/brew.chroot` installs Homebrew;
   Snow/Snowfield also run verified Hotedge, Logomenu and Bazaar Companion
   downloads through `shared/snow/scripts/build/`. Build scripts must write
   image content under `$DESTDIR`: mkosi discards the build overlay. For the
   same reason, a build-only tool a script needs goes in `BuildPackages=`
   (for example `jq` in `shared/firn-installer/mkosi.conf`); the script does
   not install it.
   Downloads use `shared/download/verified-download.sh` and pinned SHA-256
   metadata, not unchecked network content. That helper retries 5 times with a
   10-second delay on any curl error, including a connection reset, and it
   never retries a checksum mismatch. Frostyard's `bootc` and
   `libostree-1-1` arrive as debs from the configured APT source, not an
   in-tree source build. Each suite pins that pair to one exact Frostyard
   build in `shared/packages/bootc/{trixie,forky}.conf` (ADR-0037). They are
   revalidated together, because secure assembly depends on both
   ([compatibility contract](../bootc-secure-assembly-compatibility.md)).
2. **PostInstallationScripts:** kernel dracut postinstall, shared
   `shared/scripts/common-postinst.sh`, and the product's setup prepare
   os-release, package inventory and service state. The kernel postinstall
   builds the initramfs through `shared/kernel/scripts/build-initramfs.sh`:
   dracut 106 can exit 0 with no libc and no dynamic loader in the
   initramfs when its temporary directory is named `dracut.ko*`
   ([dracut-ng 5c53a810](https://github.com/dracut-ng/dracut-ng/commit/5c53a810bbc983efeaec17d88ac06a697059a201),
   fixed in 109), so the helper checks the listing for `libc.so.6` and runs
   dracut again, at most 3 times (`test/kernel-initramfs-retry-test.sh`). Package `/opt` payloads
   destined for immutable images or sysexts must be relocated under `/usr`.
3. **FinalizeScripts:** `shared/outformat/image/finalize/mkosi.finalize.chroot`
   normalizes the image, writes `/etc/machine-id` as `uninitialized`, removes
   SSH host keys and the ssl-cert snakeoil pair, strips `/etc` enablement
   symlinks, records
   `/usr/share/snosi/enablement-manifest.txt` and sets `user.component`
   xattrs for OCI chunking. Presets recreate links on true first boot.
   `shared/security/no-private-keys.finalize` then fails the build if any
   build-time private key remains ([ADR-0019](../adr/0019-no-build-time-private-keys-in-images.md));
   sysexts run it on `/usr` and `/opt` through
   `shared/sysext/finalize/sysext-no-private-keys.sh`. Every sysext also runs
   `shared/sysext/finalize/sysext-upholds-guard.sh`, which fails an
   `Upholds=` of a condition-gated unit (delta, then the base tree from
   `$MKOSI_CONFIG`; snosi#1113).
   Every sysext also runs `shared/sysext/finalize/sysext-reload-manager-guard.sh`,
   which fails a delta that ships an entry under `usr/lib/systemd/system`
   without `extension-release.<ImageId>` carrying `EXTENSION_RELOAD_MANAGER=1`,
   so PID 1 loads the units in the same boot (snosi#1189;
   [ADR-0026](../adr/0026-sysexts-with-system-units-reload-the-manager.md)).
   The five Lodge suite sysexts also run `shared/sysext/finalize/sysext-lodge-accounts-guard.sh`,
   which fails a delta that ships a Lodge app manifest without lodge's own
   `u lodge` sysusers line, or a `*.service`/`*.socket` that names a user or
   group its sysusers.d files do not declare. It parses the unit files only
   (comments and `\` continuations handled as systemd does, the last scalar
   assignment wins, `SupplementaryGroups=` accumulates, `DynamicUser=` skips
   only `User=` and `Group=`), and it does not emulate drop-in merging: a
   drop-in that sets `User=`, `Group=`, `SupplementaryGroups=`, `DynamicUser=`,
   `SocketUser=` or `SocketGroup=` fails the build, so the key belongs in the
   unit file ([ADR-0035](../adr/0035-lodge-app-sysexts-declare-user-lodge.md);
   snosi#1245).
   `shared/composition/var-audit.finalize` audits per-product `/var` outcome
   maps and rejects unclassified or stale entries.
   `shared/composition/core-flatpaks.finalize` ships the product's
   [core Flatpak set](../integration-contracts.md#core-flatpak-sets) under
   `/usr/share/frostyard/`.
   `shared/outformat/image/finalize/updex-timer.finalize` fails the build
   when a preset enables `updex-update.timer` or
   `updex-suite-switch.service` and the unit or its enablement-manifest
   entry is missing (see
   [sysexts](sysexts.md#automatic-sysext-updates-updex-update-timer)).
   `shared/outformat/image/finalize/snosi-health-timer.finalize` does the
   same for `snosi-health.timer`, its service and `/usr/bin/snosi-health`,
   for Floe's `snosi-health-report.timer` with its service and
   `/usr/libexec/snosi-health-report`, and it fails a build that ships
   `/etc/snosi-health` ([ADR-0029](../adr/0029-snosi-health-records-problems.md),
   [ADR-0030](../adr/0030-floe-sends-problem-reports-with-admin-consent.md)).
   `shared/bootc-secure/finalize/coredump.finalize` (secure composition)
   fails the build unless systemd-coredump ships with `Storage=none`,
   `ProcessSizeMax` at most 1G, `%d` and `%F` in `kernel.core_pattern`, no
   `fs.suid_dumpable=1`, and libdw and libelf.
4. **PostOutputScripts:** `shared/manifest/postoutput/mkosi.postoutput`
   records the image manifest; `shared/composition/core-flatpaks.postoutput`
   fails the build unless the output tree's core Flatpak set matches its
   source; sysext postoutput scripts derive versioned names. `sysextmv.sh`
   and `manifestmv.sh` arrange CI publication output.

The sysext build is two mkosi invocations (`just sysexts`, and the "Build
main and sysexts" plus "Build himmelblau sysext" steps of `build.yml`). The
first builds `base`, `gui-base` and every root `Dependencies=` sysext. The
second runs with `--dependency= --dependency=base --dependency=himmelblau
--sandbox-tree=shared/himmelblau/sandbox --incremental=no --cache-only=never`:
only the himmelblau APT source reaches that sandbox. `--cache-only=never`
forces the repository metadata sync that brings in the himmelblau source; mkosi
57907f58 skips the sync when the incremental base cache is current. mkosi
requires `--incremental=no` with it. Base rebuilds non-incrementally in the
second invocation.
`SandboxTrees=` is universal, so a source in `mkosi.sandbox/` would apply to
every image of every invocation ([ADR-0020](../adr/0020-scope-third-party-apt-sources.md)).
Outputs of both invocations are collected after the second one.

The base includes `pciutils`/`usbutils` and NFS account sysusers definitions
for `_rpc` and `statd`. `test/nfs-system-accounts-test.sh` verifies fresh
and existing account/state handling. Sysext factory `/etc` captures must
match only tmpfiles `C` targets; copying the buildroot's full `/etc` would
publish sensitive base state. See [sysext design](sysexts.md).

## Suite-specific content

The Debian release is a build input
([ADR-0037](../adr/0037-build-forky-as-a-second-suite.md)): `mkosi --release
forky` builds the same composition on forky, and trixie stays the default.
mkosi cannot remove a list item, so content that differs between the suites
lives in files whose only `[Match]` is `Release=trixie` or `Release=forky`.
`test/suite-isolation-test.sh` requires every trixie summary to stay the same
when the forky fragments are cut out. The suite-specific content today:

| Content | Trixie | Forky |
| --- | --- | --- |
| bootc/libostree pair and libgpgme | `shared/packages/bootc/trixie.conf`: 1.17.3 `~deb13`, `libgpgme11t64` | `shared/packages/bootc/forky.conf`: 1.17.4 `~deb14`, `libgpgme45` |
| Secure assembly contract (`/usr/lib/snosi/bootc-secure.json`) | `shared/bootc-secure/tree` | `shared/bootc-secure/suite/forky/tree`, added after the shared tree by `shared/bootc-secure/forky.conf` |
| systemd-boot `loader.conf` at install | bootc 1.17.3 writes `timeout 5` itself | the forky tree ships `/usr/lib/bootc/install/systemd-boot/loader.conf` (`timeout 5`); bootc 1.17.4 copies it |
| Isolation pin (forky source, `n=forky` at 50) | `shared/bootc-secure/trixie.conf` adds `shared/bootc-secure/package-manager` | not read: the forky suite sandbox gives the forky source |
| dracut TPM module list (`20-tpm-luks.conf`) | `systemd-pcrphase` (dracut 106) | `systemd-pcrextend` (dracut 112), in `shared/suite/forky/{base,floe,snow}-tree` |
| Product APT backports source and pin (`shared/floe/tree`, `shared/snow/tree`) | `trixie-backports` | `forky-backports`, in `shared/suite/forky/floe-tree` (Floe and Sundog, added last by `shared/suite/forky/floe.conf`) and `shared/suite/forky/snow-tree` (Snow and Snowfield, added last by `shared/suite/forky/snow.conf`) |
| `/var` outcome map | `var-outcomes.txt` plus `var-outcomes.trixie.txt` | `var-outcomes.txt` plus `var-outcomes.forky.txt` |
| Kernel and backports | `shared/kernel/backports/trixie.conf` | `shared/kernel/backports/forky.conf` |
| Surface firmware and mesa (Snowfield; the linux-surface packages stay shared) | `shared/kernel/surface/trixie.conf`: `trixie-backports` pins | `shared/kernel/surface/forky.conf`: the same packages from forky, with no suffix |
| Snow and Snowfield packages | `shared/packages/snow/trixie.conf`: `libpeas-1.0-0`, `libraw23t64`, and 6 packages that forky does not ship (`libvdpau-va-gl1`, `libxatracker2`, `packagekit-tools`, `vdpau-driver-all`, `xserver-xorg-video-qxl`, `xserver-xorg-video-vmware`) | `shared/packages/snow/forky.conf`: `libpeas-1.0-1`, `libraw25`; forky's `packagekit` ships `pkgcli` in place of `pkcon`, and no image calls `pkcon` |
| `RemovePackages=frostyard-igloo` (Snow, Snowfield, Sundog) | `shared/packages/{snow,sundog}/trixie.conf` | none: only trixie publishes `frostyard-igloo`, and apt fails to purge a name that no index has |
| Sysext set | `mkosi.conf.d/trixie.conf` adds `sunshine` to the root `Dependencies=` | no `sunshine`: upstream publishes no forky deb, and the pinned `debiantrixie` deb depends on `libminiupnpc18`, which forky does not ship |
| Host-side contract and tag form (`SNOSI_BOOTC_SECURE_SUITE`, ADR-0038) | unset, empty or `trixie`: the `shared/bootc-secure/tree` contract and `^[0-9]{14}$` tags | `forky`: the forky contract copy and `^forky-[0-9]{14}$` tags; the packager requires rootfs `VERSION_CODENAME=forky`; promotion to `latest` refuses |

`test/bootc-secure-static-test.sh` requires the forky contract to equal the
trixie contract except the three bootc version fields.
`test/tss-user-initrd-static-test.sh` requires each forky
`20-tpm-luks.conf` to equal its trixie copy with the one module name changed.
`shared/composition/var-audit.finalize` reads the suite map
`shared/composition/<product>/var-outcomes.$RELEASE.txt` after the product
map when it exists; a path that only one suite ships goes there, and
`test/var-audit-suite-map-test.sh` covers it. The floe, snow (also read by
Snowfield) and sundog maps each have a trixie and a forky suite map: trixie
ships `lib/python/python3.13_installed`, `log/README` and the `wtmp`, `btmp`
and `lastlog` files; forky ships `lib/python/python3.14_installed`.

A sysext package list names the real package where a trixie name is a virtual
package: `libasound2t64` and `libcurl3t64-gnutls` (1password, edge). On
trixie each virtual name has only that provider, so the solve is the same; on
forky `libasound2` has 2 providers and `libcurl3-gnutls` has none.

The host-side secure scripts (`assemble-uki.sh`, `buildah-package.sh`,
`ci/push-immutable-image.sh`, `ci/verify-published-image.sh`,
`ci/promote-published-image.sh`) read the suite from
`SNOSI_BOOTC_SECURE_SUITE` through the helpers of
`shared/bootc-secure/compatibility.sh`
([ADR-0038](../adr/0038-publish-signed-forky-test-images.md)). An unknown
value fails. `.github/workflows/forky-publish.yml` sets it to `forky`; no other
workflow sets it, so every trixie caller keeps the default.

## Secure bootc assembly

`shared/bootc-secure/mkosi.conf` selects a coherent Forky systemd family
from an isolated low-priority APT source. Its schema-1 image contract is
`shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json`; Firn consumes
the secure installation subset. The fragment supplies MOK/PCR public
identities and the required initramfs tooling. The sealed UKI command line
carries `lockdown=integrity`
([ADR-0027](../adr/0027-seal-lockdown-into-the-secure-uki-command-line.md)).
When the rootfs ships `usr/sbin/plymouthd` (Snow, Snowfield, Sundog),
`assemble-uki.sh` appends `splash quiet`; Floe keeps the plain line
([ADR-0033](../adr/0033-seal-the-plymouth-splash-into-the-secure-uki-command-line.md)).
mkosi `KernelCommandLine=` reaches no bootc product.
The fragment's bootc kargs.d file stays, but it does not reach a Type #2 UKI. Private keys
remain caller-owned. `build-images.yml` checks supplied credentials against
`shared/native-ab/keys/mok-2026.crt` and
`shared/native-ab/keys/pcr-signing-2026.pub`; external lab bootc consumers
also depend on that path.

Protected `shared/outformat/image/buildah-package.sh` packaging first chunks
the pristine OCI candidate with `chunkah-package.sh`. Candidate-image bootc
computes the storage composefs digest; `shared/bootc-secure/assemble-uki.sh`
uses that digest to build a MOK-signed UKI and signed bootloader stage. The
final image inherits the chunked layers with only `/boot` overlaid, and a
second digest probe must agree. No post-assembly chunk pass is permitted.
The assembler runs ukify inside the pinned candidate, offline, with
read-only credential binds, a public-only writable work area and no retained
private material. See the
[compatibility contract](../bootc-secure-assembly-compatibility.md) for
revalidation triggers and [secure operations](../bootc-secure-operations.md)
for support/evidence limits. The Frostyard bootc/libostree package pair that
this adapter binds is pinned exactly per suite in
`shared/packages/bootc/{trixie,forky}.conf` and
guarded by `test/bootc-secure-static-test.sh`; a change to either version is a
revalidation trigger, not a routine bump.

Before packaging, `probe_rootfs_bootc_version` in `buildah-package.sh` runs
`chroot ROOTFS /usr/bin/bootc --version` and requires
`bootc $BOOTC_SECURE_VERSION`. A path into a rootfs does not activate that
rootfs's dynamic loader and libraries, so the probe uses `chroot` with only
the host `/proc` bind-mounted. It refuses a missing or already-mounted
`ROOTFS/proc`, unmounts its own bind on every exit path, and fails when that
unmount fails, so the mount never reaches an OCI layer or the composefs
identity. The version gate adds no host bootc, host libostree, `bwrap` or APT
prerequisite.

Every TPM-enabled dracut profile (base, Snow and Floe `20-tpm-luks.conf`) that
adds `tpm2-tss` must also force-add the `95tss-user` module: the tpm2-tss
tmpfiles and udev rules run in the initrd and fail there without the `tss`
passwd and group entries (snosi#723). `test/tss-user-initrd-static-test.sh`
enforces it in `validate.yml`.

Forky can change independently of the Frostyard bootc/libostree debs. The
daily `shared/download/forky-versions.json` sentinel creates a review PR
when Debian's systemd source advances. Rebuild a secure profile and execute
`bootc --version` plus `bootc container --help` in its isolated root; also
recheck the Issue 517 `90-image-dissect.rules` inclusion through
`shared/bootc-secure/tree/usr/lib/dracut/dracut.conf.d/35-gpt-auto-udev-rules.conf`
and NvPCR masks in `shared/bootc-secure/finalize/disable-nvpcr.chroot`,
and the systemd-cryptsetup texts that `snosi-health` parses (ADR-0029).
`test/check-forky-systemd-test.sh` enforces the sentinel consumer and PR
obligations. Signed-PCR-11 LUKS unlock is retained while unused NvPCR writers
are masked. The most recent build-root compatibility recheck is in `AGENTS.md`.

## Runtime update and policy

The base's `bootc-update-stage.timer` invokes
`mkosi.images/base/mkosi.extra/usr/libexec/bootc-update-stage`: it uses
Podman to pull under the strict update policy in
`/usr/lib/snosi/containers/bootc-policy.json` (ADR-0025; the system
`/etc/containers/policy.json` accepts workload images), prunes stale
transfer images before pulling, stages locked (`--download-only`), checks that
the staged digest equals the pulled manifest digest, and only then unlocks the
deployment with `bootc upgrade --from-downloaded`, which performs no new fetch.
A deployment staged from a tag that moved stays locked, so it never applies. No
reboot is forced. It writes
`/run/snosi/update-check` on each run and `/run/snosi/update-staged` on a
successful stage. Outcomes include `current`, `staged`, `held-rollback` and
`failed`. The motd hook, desktop notification and `snosi-update-status`
consume this state; the desktop helper is ack-gated per digest and requires
`libnotify-bin` on graphical products. `snosi-update-status --check` compares
the followed registry image's version label; `--pkg-diff` compares the
running inventory with the *local* staged inventory, without reading the
network or a mutable dpkg database.

Published images carry `org.opencontainers.image.version` as both a config
label and a manifest annotation, and both equal the image's os-release
`IMAGE_VERSION`. bootc reads the version from the manifest annotation, so
`shared/outformat/image/check-image-version.sh` checks the packaged image
and the pushed digest.

The `mkosi.images/base/mkosi.extra/usr/lib/snosi/staged-packages.sh` sidecar
library writes an identity-bound, write-once package inventory and atomically
swaps its `/run/snosi/staged-packages` symlink. The sole shipped producer uses
`digest=sha256:...`; its `version=<14-digit>` parser remains a shared-library
API and is covered by `test/pkg-diff-test.sh`, not a native OS updater.
Missing or mismatched sidecars warn and skip package diff without changing
ordinary status. `bootc-update-stage` captures the image package list before
staging; a capture failure cannot leave a falsely successful stage.

Runtime `/etc` deletions and unit self-disablement break the bootc deployment
merge. Use a persistent `/var` run-once marker instead; the image finalize
keeps masks but removes build-time enablement links from `/etc`, leaving
first-boot presets to recreate them. `check-runtime-etc-guard.sh` and
`check-required-by-guard.sh` prevent these regressions. The base's
`snosi-etc-diff` compares live `/etc` with the booted image's pristine tree;
`preset-reconcile.service` applies newly added enablement policy without
re-enabling units an administrator disabled.
`check-user-tmpfiles-guard.sh` checks tracked source paths and rule contents,
not target mappings, build output or package files. It rejects paths at or
under the unread `usr/lib/user-tmpfiles.d` directory and rules under any
`user-tmpfiles.d/` that name `.config/containers`. The retired rule was
deleted, not moved: per-user policy would hide the system policy ([policy-scope plan, Phase 3](../plans/2026-10-29-container-policy-scope-plan.md#phase-3--retire-rootless-provisioning-done)).

`snosi-kargs` builds one MOK-signed, append-only global ESP cmdline addon for
secure bootc installations. It is measured into PCR 12 and excluded from the
signed-PCR-11 unlock policy; consult [the operator contract](../snosi-kargs.md).
The Snow Plymouth theme and bounded DRM/fbcon barrier ship from
`shared/snow/tree/`, including
`shared/snow/tree/usr/lib/systemd/system/plymouth-start.service.d/10-wait-drm.conf`
(real root only). `dracut --no-hostonly` puts Plymouth and the configured
theme in the initramfs of every product that ships it, and the sealed
`splash` argument selects the graphical theme
([ADR-0033](../adr/0033-seal-the-plymouth-splash-into-the-secure-uki-command-line.md)).

## Publication input metadata

`shared/download/sysext-checksums.json` pins direct sysext downloads and
triggers sysext builds. An entry with an `attestation` object (the first-party
suite sysexts `lodge`, `notesd`, `maild`, `porterd` and `readd`) is also checked
by `shared/download/verify-attestations.sh`
([ADR-0024](../adr/0024-verify-attestations-of-first-party-sysext-debs.md)).
`shared/download/image-checksums.json` pins OCI
profile downloads and triggers image builds. `package-versions.json` tracks
external sysext APT changes as a review sentinel, not an APT version pin;
`forky-versions.json` records the last acknowledged Forky systemd source
version. The weekly dependency and daily package workflows open PRs, never
auto-merge. The retained ISO publish scripts in `shared/native-ab/publish/`
promote a signed Firn index at `isos/native/v1/` using a protected signing
credential; ISO retention is not automated.
See [CI/CD](ci-cd.md) for publication gates.
