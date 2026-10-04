# snosi

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/frostyard/snosi/badge)](https://scorecard.dev/viewer/?uri=github.com/frostyard/snosi)

Snosi builds Debian Trixie bootc OCI images and `/usr`-only system extensions
(sysexts) with [mkosi](https://github.com/systemd/mkosi). The four products are:

| Product | Purpose | Kernel |
| --- | --- | --- |
| **Snow** (`snow`) | GNOME workstation | Trixie backports |
| **Snowfield** (`snowfield`) | GNOME workstation for Surface devices | linux-surface |
| **Floe** (`floe`) | Headless Podman server | Trixie backports |
| **Sundog** (`sundog`) | KDE Plasma Wayland workstation | Trixie backports |

Firn offers only these four bootc choices. **Snowfield is untested on
representative Surface hardware**: its catalog inclusion gate was waived,
not passed. Fresh-install evidence for Snow, Floe and Sundog is pending:
no minideb lab install has produced any yet. Fixture coverage does not establish
production Secure Boot support, nor signed update/rollback evidence; see
[secure bootc operations](docs/bootc-secure-operations.md).

## Download and install

- [Firn bootc installer (latest x86-64)](https://repository.frostyard.org/isos/native/v1/snosi-installer-latest-x86-64.iso)
- [Installer checksums](https://repository.frostyard.org/isos/native/v1/SHA256SUMS)
  and [OpenPGP signature](https://repository.frostyard.org/isos/native/v1/SHA256SUMS.gpg)

The `native` segment in the retained ISO URL is a publication namespace, not
an A/B installer choice. Follow the [installation guide](docs/installing.md)
to verify the ISO, select a disk and install safely. Native A/B and nbc hosts
receive no new images or updates: back up, reinstall with Firn, and restore
state following the [migration guide](docs/nbc-to-bootc-migration.md).
Repository cleanup deletes no published artifacts; future disposal requires
the exact-object gate in
[ADR-0018](docs/adr/0018-remove-native-ab-and-nbc-lanes.md). For the removed
implementation see [native prototype history](docs/native-ab-prototype-history.md).

## Architecture

The root `mkosi.conf` builds the base image and sysexts. Each of the four
`mkosi.profiles/` profiles resets inherited dependencies to `base`, includes
bootc packages and `shared/bootc-secure/mkosi.conf`, and composes its
product payload, kernel and directory output format from `shared/` fragments.
The build uses BuildScripts, PostInstallationScripts, FinalizeScripts and
PostOutputScripts. See [overview](docs/design/overview.md) and
[build pipeline](docs/design/build-pipeline.md) for exact ordering.

Images keep `/usr` immutable, `/etc` deployment-managed and `/var`
persistent. Sysexts overlay `/usr` only; packages that install into `/opt`
must be relocated under `/usr` and factory `/etc` captures must be limited
to tmpfiles-referenced paths. See [sysext design](docs/design/sysexts.md).
The base contains the bootc updater, staged-update status and notifier.
`bootc-update-stage.timer` checks hourly, pulls with Podman under the image
signature policy, verifies the staged digest, and waits for a natural reboot.
`snosi-update-status --pkg-diff` compares the running and locally staged
package inventories. The secure bootc
[`snosi-kargs` CLI](docs/snosi-kargs.md) writes a signed append-only
cmdline addon measured into PCR 12, outside the PCR-11 unlock policy.

`shared/native-ab/keys/` remains at its existing path: external bootc lab
consumers fetch its public MOK/PCR keys and protected OCI builds verify their
signing identities against them. `shared/native-ab/ci/` contains the retained
mkosi pin helpers for the ISO. The ISO publisher under
`shared/native-ab/publish/` and the
`workers/native-installer-redirect/` Worker remain operational. Neither
directory name implies a buildable native A/B product.

## Build and verify locally

Install `just`, Git and Python 3; mkosi is bootstrapped at the commit pinned
in `.github/workflows/build.yml` by the Justfile. Image builds and VM installs
need the documented privileged build/runtime tools.

```bash
just                      # List available recipes
just sysexts              # Build base and system extensions
just snow                 # GNOME OCI image
just snowfield            # Surface-kernel GNOME OCI image (hardware untested)
just floe                 # Headless OCI image
just sundog               # KDE Plasma OCI image
just test-install         # Bootc install test in QEMU/KVM
just run-qemu             # Interactive bootc VM
```

The [CI/CD design](docs/design/ci-cd.md) documents sysext and OCI publication,
Firn ISO publishing, and validation; [testing](docs/design/testing.md)
separates non-root fixtures from live installation and lifecycle evidence.
Protected OCI publication signs and validates an immutable digest before
promoting `latest`. Local PR builds have no publication credentials.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md), the
[Code of Conduct](CODE_OF_CONDUCT.md), and the
[documentation index](docs/README.md). Report vulnerabilities privately via
[SECURITY.md](SECURITY.md), not a public issue.
