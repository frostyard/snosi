# Snosi architecture overview

Decision records: [ADR-0001](../adr/0001-var-factory-state-outcome-maps.md)
(`/var` outcomes), [ADR-0005](../adr/0005-profiles-as-transport-kernel-selectors.md)
(composition), [ADR-0011](../adr/0011-mkosi-bootstrapped-and-pin-shared.md)
(mkosi pin), and [ADR-0018](../adr/0018-remove-native-ab-and-nbc-lanes.md)
(bootc-only output). Native A/B mechanisms are recorded in
[prototype history](../native-ab-prototype-history.md), not this living design.

## Products and installation

Snosi builds four Debian Trixie bootc OCI products with mkosi:

| Profile | Purpose | Kernel |
| --- | --- | --- |
| `snow` | GNOME workstation | Trixie backports |
| `snowfield` | GNOME workstation for Surface devices | linux-surface |
| `floe` | Headless server with Podman | Trixie backports |
| `sundog` | KDE Plasma Wayland workstation | Trixie backports |

Firn's `shared/firn-installer/catalog.json` offers exactly these four bootc
choices. **Snowfield is untested on representative Surface hardware.** Its
catalog gate was waived, not passed. Fresh-install evidence for Snow, Floe
and Sundog is pending: minideb lab installs will run after the Firn release
is pinned; none exists yet. They will not prove secure update/rollback.
For the secure-bootc support and recovery boundary see
[operations](../bootc-secure-operations.md). Firn's ISO is published under
`isos/native/v1/`; the native-named URL does not offer an A/B product.

## Composition and output

The root `mkosi.conf` declares `base` plus sysext dependencies. Each
`mkosi.profiles/<product>/mkosi.conf` clears that inherited list with
`Dependencies=` then adds `Dependencies=base`; otherwise each profile would
rebuild every sysext. The four profiles include
`shared/packages/bootc/mkosi.conf`, `shared/bootc-secure/mkosi.conf`, a
product composition under `shared/composition/`, its kernel fragment under
`shared/kernel/`, and `shared/outformat/image/mkosi.conf` for directory
output. Snowfield shares Snow's composition with the Surface kernel. Sundog
uses its own KDE composition. mkosi accumulates list settings in `Include=`
order; inspect `mkosi summary` and run `check-profile-dependencies.sh` when
changing profile includes. `shared/composition/var-audit.finalize` applies
per-product `/var` outcome maps (ADR-0001).

Sundog explicitly selects Plasma's executable helpers, settings and editors,
System Monitor, Hunspell English spelling, Dolphin preview plugins, wallet
management, GTK appearance/Preview integration, Thunderbolt controls, Info
Center's probe tools, and offline Help. Selective recommendations are required
because mkosi builds with Debian Recommends disabled. Plasma's autoloaded
`gtkconfig` module manages XSettings; package composition needs no additional
session service. Native Gwenview and Okular, including their handbooks, remain
in the image.

The [desktop-completeness plan](../plans/2026-10-05-sundog-desktop-completeness-plan.md)
records artifact and VM package validation, followed by the
[Flatpak-defaults plan](../plans/2026-10-05-sundog-flatpak-defaults-plan.md).
Each product's core Flatpak set is published as an image label; see
[integration contracts](../integration-contracts.md#core-flatpak-sets).
The follow-up covers the Firn release that reads it, existing-install
migration, and removing the native applications Sundog's set replaces.

Image builds run BuildScripts, PostInstallationScripts, FinalizeScripts and
PostOutputScripts; details and package relocation rules are in
[build pipeline](build-pipeline.md). The default mkosi tools tree has a
separate package-manager sandbox (`mkosi.tools.sandbox/`) from the target
image (`mkosi.sandbox/`).

`/usr` is immutable; `/etc` is managed across bootc deployments and `/var`
persists. A true first boot starts with `/etc/machine-id` set to
`uninitialized`. Presets recreate build-time enablement links in `/etc`;
the shipped policy is recorded in
`/usr/share/snosi/enablement-manifest.txt`. Runtime units must not remove
image-shipped `/etc` paths or self-disable: use a `/var` run-once marker.
`check-runtime-etc-guard.sh` and `check-required-by-guard.sh` enforce the
runtime mutation and `.requires/` bans. `snosi-etc-diff` reports drift
against the booted deployment's pristine `/etc`, with an optional restore
operation; the bootc path bind-mounts `/` to see below the live `/etc` mount.

## Secure composition and boot experience

The secure fragment uses an isolated, low-priority Forky APT source for a
coherent systemd family. It ships schema-1
`shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json` for Firn and
protected assembly. `build-images.yml` verifies the supplied public MOK and
PCR identities against `shared/native-ab/keys/`; the keys stay there because
external bootc lab lanes fetch them from snosi main. Private signing keys
must never enter an image. The daily Forky sentinel is
`shared/download/forky-versions.json`; changing it requires the bwrap
bootc/libostree build-root compatibility check, the dracut GPT-auto udev
rule check, and the NvPCR mask check (see `AGENTS.md`).

Snow and Snowfield carry the Snow Plymouth theme at
`shared/snow/tree/usr/share/plymouth/themes/snow/`. The
`shared/snow/tree/usr/lib/systemd/system/plymouth-start.service.d/10-wait-drm.conf`
drop-in waits with bounded timeouts for `/dev/dri/card0` and `/dev/fb0`:
Plymouth otherwise races DRM discovery or the fbcon handoff. Bootc/Firn
provides installation kernel arguments. For persistent custom arguments,
[`snosi-kargs`](../snosi-kargs.md) signs a global ESP addon measured into PCR
12, outside signed-PCR-11 LUKS unlock policy.

## Updates and sysexts

The base's `bootc-update-stage.timer` pulls the followed OCI image using
Podman under the system signature policy, stages a checked digest without
rebooting, and records `/run/snosi/update-check` and
`/run/snosi/update-staged`. The motd, desktop notifier, and
`snosi-update-status` consume that state. `--pkg-diff` reads an
identity-bound local staged-package sidecar; the shared library at
`mkosi.images/base/mkosi.extra/usr/lib/snosi/staged-packages.sh` retains its
`version=` parser as an API even though the sole shipped producer uses
`digest=`. Details are in [build pipeline](build-pipeline.md).

Sysexts are EROFS `/usr` overlays downloaded by per-component
systemd-sysupdate transfers and merged by systemd-sysext. They do not carry
`/etc` or `/var` payload; tmpfiles copies narrowly captured factory `/etc`
defaults when required. See [sysext design](sysexts.md). Cross-repository
producer/consumer boundaries are mapped in
[integration contracts](../integration-contracts.md).

## Publication and testing

`.github/workflows/build.yml` publishes sysexts. `build-images.yml` builds
four OCI profiles and signs immutable digest references before promoting
`latest`. `build-installer-iso.yml` builds Firn and publishes a signed index
at `isos/native/v1/`. Its public key and publication scripts remain under
`shared/native-ab/keys/` and `shared/native-ab/publish/`; the stable URL is
derived by `workers/native-installer-redirect/`. No automatic ISO retention
workflow remains and source cleanup deletes no R2 objects (ADR-0018).
`shared/native-ab/ci/` retains the mkosi pin helpers for the ISO.

`validate.yml` runs non-root contracts, guards and configuration checks;
privileged bootc install and secure lifecycle evidence belong to separate
lanes. See [CI/CD](ci-cd.md) and [testing](testing.md). Cross-session
corrections use `.memory/README.md`; repository governance is described in
`docs/README.md` and the policy-as-code tests.
