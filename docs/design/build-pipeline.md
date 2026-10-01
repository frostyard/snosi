# Build pipeline

Decisions: [ADR-0001](../adr/0001-var-factory-state-outcome-maps.md)
(`/var` inventory), [ADR-0002](../adr/0002-ship-no-enablement-symlinks-in-etc.md)
(presets), [ADR-0004](../adr/0004-sysext-authoring-rules.md) (sysexts),
[ADR-0005](../adr/0005-profiles-as-transport-kernel-selectors.md)
(composition), [ADR-0012](../adr/0012-chunked-layers-cadence-xattrs-chunk-before-seal.md)
(OCI chunking), and [ADR-0018](../adr/0018-remove-native-ab-and-nbc-lanes.md)
(bootc-only output). Removed native mechanisms are recorded in
[prototype history](../native-ab-prototype-history.md).

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

Image builds have four phases, in order:

1. **BuildScripts:** `shared/scripts/build/brew.chroot` installs Homebrew;
   Snow/Snowfield also run verified Hotedge, Logomenu, Bazaar Companion and
   Surface certificate downloads through `shared/snow/scripts/build/`.
   Downloads use `shared/download/verified-download.sh` and pinned SHA-256
   metadata, not unchecked network content. Frostyard's `bootc` and
   `libostree-1-1` arrive as debs from the configured APT source, not an
   in-tree source build.
2. **PostInstallationScripts:** kernel dracut postinstall, shared
   `shared/scripts/common-postinst.sh`, and the product's setup prepare
   os-release, package inventory and service state. Package `/opt` payloads
   destined for immutable images or sysexts must be relocated under `/usr`.
3. **FinalizeScripts:** `shared/outformat/image/finalize/mkosi.finalize.chroot`
   normalizes the image, writes `/etc/machine-id` as `uninitialized`, removes
   SSH host keys, strips `/etc` enablement symlinks, records
   `/usr/share/snosi/enablement-manifest.txt` and sets `user.component`
   xattrs for OCI chunking. Presets recreate links on true first boot.
   `shared/composition/var-audit.finalize` audits per-product `/var` outcome
   maps and rejects unclassified or stale entries.
4. **PostOutputScripts:** `shared/manifest/postoutput/mkosi.postoutput`
   records the image manifest; sysext postoutput scripts derive versioned
   names. `sysextmv.sh` and `manifestmv.sh` arrange CI publication output.

The base includes `pciutils`/`usbutils` and NFS account sysusers definitions
for `_rpc` and `statd`. `test/nfs-system-accounts-test.sh` verifies fresh
and existing account/state handling. Sysext factory `/etc` captures must
match only tmpfiles `C` targets; copying the buildroot's full `/etc` would
publish sensitive base state. See [sysext design](sysexts.md).

## Secure bootc assembly

`shared/bootc-secure/mkosi.conf` selects a coherent Forky systemd family
from an isolated low-priority APT source. Its schema-1 image contract is
`shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json`; Firn consumes
the secure installation subset. The fragment supplies lockdown bootc kargs,
MOK/PCR public identities and the required initramfs tooling. Private keys
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
for support/evidence limits.

Forky can change independently of the Frostyard bootc/libostree debs. The
daily `shared/download/forky-versions.json` sentinel creates a review PR
when Debian's systemd source advances. Rebuild a secure profile and execute
`bootc --version` plus `bootc container --help` in its isolated root; also
recheck the Issue 517 `90-image-dissect.rules` inclusion through
`shared/bootc-secure/tree/usr/lib/dracut/dracut.conf.d/35-gpt-auto-udev-rules.conf`
and NvPCR masks in `shared/bootc-secure/finalize/disable-nvpcr.chroot`.
`test/check-forky-systemd-test.sh` enforces the sentinel consumer and PR
obligations. Signed-PCR-11 LUKS unlock is retained while unused NvPCR writers
are masked. The most recent build-root compatibility recheck is in `AGENTS.md`.

## Runtime update and policy

The base's `bootc-update-stage.timer` invokes
`mkosi.images/base/mkosi.extra/usr/libexec/bootc-update-stage`: it uses
Podman to pull under restrictive containers/image policy, prunes stale
transfer images before pulling, stages through bootc without forcing reboot,
and verifies the staged digest equals the pulled manifest digest. It writes
`/run/snosi/update-check` on each run and `/run/snosi/update-staged` on a
successful stage. Outcomes include `current`, `staged`, `held-rollback` and
`failed`. The motd hook, desktop notification and `snosi-update-status`
consume this state; the desktop helper is ack-gated per digest and requires
`libnotify-bin` on graphical products. `snosi-update-status --check` compares
the followed registry image's version label; `--pkg-diff` compares the
running inventory with the *local* staged inventory, without reading the
network or a mutable dpkg database.

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

`snosi-kargs` builds one MOK-signed, append-only global ESP cmdline addon for
secure bootc installations. It is measured into PCR 12 and excluded from the
signed-PCR-11 unlock policy; consult [the operator contract](../snosi-kargs.md).
The Snow Plymouth theme and bounded DRM/fbcon barrier ship from
`shared/snow/tree/`, including
`shared/snow/tree/usr/lib/systemd/system/plymouth-start.service.d/10-wait-drm.conf`.
Firn supplies the bootc installation kernel arguments.

## Publication input metadata

`shared/download/sysext-checksums.json` pins direct sysext downloads and
triggers sysext builds. `shared/download/image-checksums.json` pins OCI
profile downloads and triggers image builds. `package-versions.json` tracks
external sysext APT changes as a review sentinel, not an APT version pin;
`forky-versions.json` records the last acknowledged Forky systemd source
version. The weekly dependency and daily package workflows open PRs, never
auto-merge. The retained ISO publish scripts in `shared/native-ab/publish/`
promote a signed Firn index at `isos/native/v1/` using a protected signing
credential; ISO retention is not automated.
See [CI/CD](ci-cd.md) for publication gates.
