# Snosi contributor context

Snosi builds four Debian Trixie bootc OCI products (`snow`, `snowfield`,
`floe`, `sundog`) and `/usr`-only sysexts. Firn offers these four bootc choices
only. Snowfield ships **untested** on representative Surface hardware: its
catalog inclusion gate is waived, not passed. Snow and Floe have VM
fresh-install PASS evidence (lab run `bootc-only-iso-install-54wr4`,
minideb, 2026-10-24); Sundog failed `boot:no_report`
([#1123](https://github.com/frostyard/snosi/issues/1123)) and stays pending.
The Firn ISO takes the newest published Firn release (no pin).
Native A/B and NBC build/runtime lanes were removed; see
[ADR-0018](docs/adr/0018-remove-native-ab-and-nbc-lanes.md) and
[native prototype history](docs/native-ab-prototype-history.md).

## Build and layout

`just` lists targets; `just sysexts`, `just snow`, `just snowfield`,
`just sundog`, `just floe`, `just test-install` and `just run-qemu` cover
local builds and bootc tests. The Justfile bootstraps mkosi at the commit
pinned in `.github/workflows/build.yml`. The retained
`shared/native-ab/ci/bootstrap-mkosi.sh` and `check-mkosi-pin.sh` enforce
the same pin for the installer ISO; their directory name is historical.

The root `mkosi.conf` builds base plus sysexts. Each profile resets the
inherited `Dependencies=` list before adding `base`, then includes bootc
packages, `shared/bootc-secure/mkosi.conf`, its product composition/kernel,
and `shared/outformat/image/mkosi.conf`. mkosi list-valued settings accumulate
in `Include=` order: check the resolved summary when rearranging fragments.
The himmelblau APT source is scoped to `shared/himmelblau/sandbox/` and its
sysext builds in a separate mkosi invocation with
`--sandbox-tree=shared/himmelblau/sandbox`, in both `just sysexts` and
`build.yml` (ADR-0020). `test/third-party-apt-source-scope-test.sh` rejects a
new third-party source in `mkosi.sandbox/`.
The image script phases are BuildScripts, PostInstallationScripts,
FinalizeScripts and PostOutputScripts. Consult
[build pipeline](docs/design/build-pipeline.md) for the detailed composition.

`/usr` is immutable, `/etc` is deployment-managed and `/var` persists.
Sysexts overlay `/usr` only: relocate package `/opt` payloads into `/usr` and
capture only tmpfiles-referenced factory `/etc` values. Shipped runtime units
must not delete `/etc` paths or self-disable: use a `/var` run-once marker;
`check-runtime-etc-guard.sh` enforces this. Do not ship `RequiredBy=` or
`.requires/` enablement (`check-required-by-guard.sh`). Do not uphold a
condition-gated unit (`check-upholds-guard.sh`; for sysext deltas
`shared/sysext/finalize/sysext-upholds-guard.sh`).
Base owns the host VM runtime (`qemu-system-x86`, `qemu-utils`, `ovmf`);
every sysext runs `shared/sysext/finalize/sysext-no-base-owned.sh`, which
fails a delta that ships any glob in `shared/sysext/base-owned-paths.txt`.
Incus uses its bundled `/usr/incus` qemu, not Debian's.
The Frostyard repository key must be the content of
`/usr/lib/systemd/import-pubring.pgp`: `systemd-container/forky` overwrites
the base copy, so `shared/bootc-secure/mkosi.conf` restores it. Build-time enablement
is normalized into `/usr/share/snosi/enablement-manifest.txt`; presets
recreate links on true first boot (`/etc/machine-id` is `uninitialized`).

## Secure bootc and Forky systemd

**Bootc secure composition (Task 4):** all four OCI profiles include
`shared/bootc-secure/mkosi.conf`, whose isolated, low-priority Forky APT
source supplies a coherent systemd family. The secure image ships schema-1
`/usr/lib/snosi/bootc-secure.json` for Firn and protected UKI assembly.
Protected publication in `.github/workflows/build-images.yml` compares
the supplied MOK certificate and PCR public key against
`shared/native-ab/keys/mok-2026.crt` and
`shared/native-ab/keys/pcr-signing-2026.pub`; bootc-secure and Firn also
consume the public keys. External lab bootc lanes fetch them from snosi main,
so do not rename `shared/native-ab/keys/`. Private keys never enter images:
`shared/security/no-private-keys.finalize` fails any OCI or sysext build that
ships a build-time private key (ADR-0019); the image finalize removes SSH host
keys and ssl-cert's snakeoil pair.
`docs/bootc-secure-operations.md` governs support claims and lifecycle gates;
fixture success does not establish production Secure Boot support.

Forky is a compatibility risk with Frostyard bootc/libostree debs, not a
package-manager guarantee. Repeat that build/root check when either the
Frostyard debs or the selected systemd family changes: build a secure OCI
profile and run `bootc --version` and `bootc container --help` inside a
build-root-only bwrap sandbox, then validate the assembled artifact.
**Last repeated 2026-09-29:** Floe built against bootc 1.16.8, libostree
2026.3 and Forky systemd 262-1; bwrap commands and local artifact validation
passed. That run does not prove an installed boot on systemd 262.

**Issue 517:** Forky moved `gpt-auto-root-luks` udev rules to
`90-image-dissect.rules`, which dracut 106 did not automatically include.
`shared/bootc-secure/tree/usr/lib/dracut/dracut.conf.d/35-gpt-auto-udev-rules.conf`
installs the required rule; `test/bootc-secure-artifact-test.sh` verifies it
inside the UKI. Recheck when dracut or systemd moves the rule. NvPCR definitions
and writers are masked by `shared/bootc-secure/finalize/disable-nvpcr.chroot`:
our UKIs lack the initrd NvPCR definitions and `--sign-initrd-pcrs` policy,
while signed-PCR-11 LUKS unlock remains active. Recheck mask coverage on
Forky updates. The daily sentinel `shared/download/forky-versions.json`
opens a review PR when the source version advances; `test/check-forky-systemd-test.sh`
guards its consumers and three recheck obligations.

The secure bootc CLI `snosi-kargs` writes a signed global cmdline addon to
the ESP; arguments are append-only, measured into PCR 12 and excluded from
the signed PCR-11 unlock policy. Use `docs/snosi-kargs.md` for the operator
contract. Snow and Snowfield carry the Snow Plymouth theme from
`shared/snow/tree/usr/share/plymouth/themes/snow/`. The live
`shared/snow/tree/usr/lib/systemd/system/plymouth-start.service.d/10-wait-drm.conf`
waits (bounded) for `/dev/dri/card0` and `/dev/fb0` so Plymouth does not
race DRM discovery or the fbcon handoff. The bootc installer supplies its
own kernel arguments; no native A/B cmdline mechanism is needed.

## Updates and publication

On installed bootc systems, `bootc-update-stage.timer` pulls through Podman
under the signature policy and stages without forcing a reboot. It checks the
staged digest and writes `/run/snosi/update-check` and
`/run/snosi/update-staged`; the motd, desktop notifier and
`snosi-update-status` read this state. `--pkg-diff` uses the identity-bound
`mkosi.images/base/mkosi.extra/usr/lib/snosi/staged-packages.sh` sidecar.
That shared library retains `version=` support as an API even though the
only shipped stager publishes a bootc `digest=` identity; do not remove
its version parser without a separate interface decision.

`.github/workflows/build.yml` publishes sysexts; `build-images.yml` publishes
signed OCI images by immutable digest before promoting `latest`.
`build-installer-iso.yml` builds and signed-index-publishes the Firn ISO to
`isos/native/v1/`. `deploy-native-installer-redirect.yml` deploys the
retained `workers/native-installer-redirect/` stable-URL Worker. ISO
publication scripts under `shared/native-ab/publish/` and the public
`shared/native-ab/keys/import-pubring.gpg` remain live despite their names.
There is no automatic ISO retention workflow; its predecessor never ran
successfully for lack of R2 credentials. Repository cleanup deletes no R2
objects; any future deletion is gated per exact object by ADR-0018.

`validate.yml` runs static guards and non-root fixtures, including Firn
catalog/ISO publication, `test/no-nbc-test.sh` and
`test/retirement-plan-test.py`. `nightly-compliance.yml` repeats secretless
policy checks. Secure bootc install and update fixtures do not substitute
for live Firn install, update or rollback evidence. See
[CI/CD](docs/design/ci-cd.md) and [testing](docs/design/testing.md).

## Documentation

Keep living design and user guidance current with code. New decisions start
from `docs/adr/TEMPLATE.md`; accepted ADRs are immutable except status and
successor pointers. `docs/README.md` indexes decisions, designs, contracts,
plans and historical records. Use `.memory/README.md` for correction-log
conventions; do not record secrets.
