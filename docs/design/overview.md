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
catalog gate was waived, not passed. Snow, Floe and Sundog
have VM fresh-install PASS evidence from minideb lab runs (2026-10-24/25; see
[testing](testing.md)).
This does not prove secure update/rollback.
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

Snow and Snowfield support the screen-reader switches in both GDM and the
GNOME session. Their package set explicitly supplies the AT-SPI accessibility
bus (at-spi2-core), Orca and speech-dispatcher, since Recommends are disabled.
Validate activation and a consumer with `python3 test/live/snow-accessibility.py`
in each fresh session, then exercise Orca with the screen-reader switch.

Sundog explicitly selects Plasma's executable helpers, settings and editors,
System Monitor, Hunspell English spelling, Dolphin preview plugins, wallet
management, GTK appearance/Preview integration, Thunderbolt controls, Info
Center's probe tools, and offline Help. Selective recommendations are required
because mkosi builds with Debian Recommends disabled. Plasma's autoloaded
`gtkconfig` module manages XSettings; package composition needs no additional
session service. Gwenview, Okular, KCalc and Skanpage are not native: they
come from Sundog's core Flatpak set, which Firn offers enabled by default.
The image keeps their host-side support explicit: `kimageformat6-plugins`
for native Qt image formats and `libsane1` for scanner udev rules.

The [desktop-completeness plan](../plans/2026-10-05-sundog-desktop-completeness-plan.md)
records artifact and VM package validation, followed by the
[Flatpak-defaults plan](../plans/2026-10-05-sundog-flatpak-defaults-plan.md).
Each product's core Flatpak set is published as an image label and shipped
at `/usr/share/frostyard/<IMAGE_ID>.core-flatpaks.json`; see
[integration contracts](../integration-contracts.md#core-flatpak-sets).
Nothing migrates existing installs or reconciles installed Flatpaks with a
changed set.

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

All products use base's zram swap policy: LZ4 compression, half of RAM capped
at 4 GiB. The generator package and configuration have one owner in base.
An empty `/etc/systemd/zram-generator.conf` disables the vendor default;
administrators can instead override its size/compression there. Run
`python3 test/live/zram-policy.py` after a fresh boot and image update to
check the active swap unit, device size and algorithm. Rolling back to an
image without the generator stops creating zram on the next boot.

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
Plymouth otherwise races DRM discovery or the fbcon handoff. The splash
arguments `splash quiet` are sealed into the UKI command line of every
product that ships Plymouth (Snow, Snowfield, Sundog;
[ADR-0033](../adr/0033-seal-the-plymouth-splash-into-the-secure-uki-command-line.md)). For persistent custom arguments,
[`snosi-kargs`](../snosi-kargs.md) signs a global ESP addon measured into PCR
12, outside signed-PCR-11 LUKS unlock policy.

## Snow GTK theme

Snow and Snowfield ship the Snow theme, built only from the colour tokens of
frostyard/core's design system
([ADR-0034](../adr/0034-snow-gtk-theme.md)). It has three layers under
`shared/snow/tree/usr/share/themes/Snow/`:

| Layer | File | Reaches |
|---|---|---|
| libadwaita colours | `libadwaita/gtk.css` | libadwaita apps, through each user's `~/.config/gtk-4.0/gtk.css` |
| GTK 3 theme | `gtk-3.0/gtk.css` | GTK 3 apps, through `gtk-theme='Snow'` |
| GTK 4 theme | `gtk-4.0/gtk.css` | GTK 4 apps without libadwaita (GTK's dark built-in theme) |

libadwaita ignores `gtk-theme`, so a new account gets
`/etc/skel/.config/gtk-4.0/gtk.css`, a single `@import` of the libadwaita
layer. GTK loads that file at user priority, where any rule beats the
application's own. The layer therefore sets only colour variables, their
named colours and two one-property rules for libadwaita's fixed greys
(`banner`, `toast`). Existing accounts keep stock colours until the user
copies the skel file. Flatpak applications are not recoloured; they follow
the dark scheme and blue accent through the portal. The
`zz0-01-snowlinux-desktop.gschema.override` defaults are
`color-scheme='prefer-dark'`, `gtk-theme='Snow'`, `accent-color='blue'` and
the font `Inter Variable 11` from `fonts-inter-variable`.

`test/fixtures/frostyard-design/colors.css` is the sha256-pinned copy of
core's tokens. `test/snow-gtk-theme-test.py` rejects a theme colour that is
not a token, any other rule in the libadwaita layer, a named colour that
differs from its variable, a skel file that does more than import the layer,
and a font setting whose package is missing. To change a colour, change the
token in core first, copy the file again and update the pin. Recheck the
layer against libadwaita's `defaults-dark.css` when libadwaita moves.

## First login

Snow and Snowfield start chairlift's first run at the first graphical login
([ADR-0028](../adr/0028-first-login-runs-chairlift-first-run.md)). The image
owns the trigger and the app list; chairlift owns the flow and the done
markers. `shared/snow/tree/etc/xdg/autostart/org.frostyard.ChairLift.FirstRun.desktop`
runs `/usr/bin/chairlift-first-run` (from `frostyard-chairlift`), which exits
at once when the user finished the first run or SNOW First Setup before it.
The app picker reads `shared/snow/tree/usr/share/snow/first-run/apps.json`.
Sundog and Floe have no first-login app. `shared/composition/first-login.finalize`
fails a build with zero or two first-login entries on Snow or Snowfield, any
on Sundog or Floe, a different `Exec`, or no executable
`/usr/bin/chairlift-first-run`; `test/first-login-trigger-test.sh` checks the
trees, the list shape and the finalize in `validate.yml`. Base ships
`/etc/profile.d/snosi-brew.sh`, which gives non-root login shells the Homebrew
environment when brew is installed.

## Rootless Podman API

Base presets disable eager `podman.service` startup; the socket retains
its package default. A request to `$XDG_RUNTIME_DIR/podman/podman.sock`
activates the API. This applies to Snow, Snowfield, Floe and Sundog.

Before user managers start, a one-time migration removes only the standard
global `default.target.wants/podman.service` vendor link on installs already
using the preset-owned enablement model. The current image manifest must
exclude that link. This is a scoped exception to the runtime etc guard:
the link was created at runtime, not shipped in the booted image.
Masks, custom units/links, per-user choices and socket enablement are
untouched; no preset-all or mass re-enable runs. A deliberately enabled
per-user daemon remains enabled. The marker under `/var/lib/snosi/`
prevents subsequent overrides being undone. Rolling back does not recreate
the removed global link; an administrator can deliberately enable the API
again if needed.

Acceptance requires an actual `curl --unix-socket
"$XDG_RUNTIME_DIR/podman/podman.sock" http://localhost/_ping` returning
`OK`, plus Podman CLI and rootful bootc checks after fresh install/update.
Do not add subordinate IDs to GDM. Isolated socket tests on Podman 5.4.2
and systemd 262 are evidence for the protocol, not proof of all login-time
behavior or of the original FD failure's precise cause.

## Updates and sysexts

The base's `bootc-update-stage.timer` pulls the followed OCI image using
Podman under the strict update policy in
`/usr/lib/snosi/containers/bootc-policy.json`, stages a checked digest without
rebooting, and records `/run/snosi/update-check` and
`/run/snosi/update-staged`. The motd, desktop notifier, and
`snosi-update-status` consume that state. `--pkg-diff` reads an
identity-bound local staged-package sidecar; the shared library at
`mkosi.images/base/mkosi.extra/usr/lib/snosi/staged-packages.sh` retains its
`version=` parser as an API even though the sole shipped producer uses
`digest=`. Details are in [build pipeline](build-pipeline.md).

The base's `snosi-health.timer` (3 minutes after boot, then hourly, at idle
priority) runs `snosi-health`, which records failed image units, failed
stages (the stager's `error_class`), rollbacks, failed sysext updates
(updex's `last-run.json`), TPM unlock retries, integrity errors, system
crashes (systemd-coredump with `Storage=none`) and frostyard app problems in
`/var/lib/snosi-health/problems.json` and `details.json`. It sends nothing;
only Floe ships the opt-in sender `snosi-health-report`, whose daily timer
posts at most 20 reportable problems and 1 weekly count once the
administrator runs `snosi-health reporting on`
([ADR-0029](../adr/0029-snosi-health-records-problems.md),
[ADR-0030](../adr/0030-floe-sends-problem-reports-with-admin-consent.md),
[integration contracts](../integration-contracts.md#problem-records-snosi-health)).

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
