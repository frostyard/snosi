<!-- readme-kind: image -->
# snosi

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/frostyard/snosi/badge)](https://scorecard.dev/viewer/?uri=github.com/frostyard/snosi)

snosi builds Debian Trixie bootc OCI images and `/usr`-only system
extensions (sysexts) with [mkosi](https://github.com/systemd/mkosi), for
people who want a desktop or server that installs and updates as one image.

**Status:** pre-release. Snow, Floe and Sundog pass VM fresh installs; Snowfield is untested on Surface hardware.

**Documentation:** [frostyard.org/docs](https://frostyard.org/docs/)

## Images

| Image | Purpose | Base |
| --- | --- | --- |
| **Snow** (`snow`) | GNOME workstation | Debian Trixie, newer Debian kernel |
| **Snowfield** (`snowfield`) | GNOME workstation for Surface devices | Debian Trixie, linux-surface kernel |
| **Floe** (`floe`) | Headless Podman server | Debian Trixie, newer Debian kernel |
| **Sundog** (`sundog`) | KDE Plasma Wayland workstation | Debian Trixie, newer Debian kernel |

`shared/kernel/` selects each kernel and says which suite it comes from.
The sysexts add optional software to any image; the
[sysext design](docs/design/sysexts.md) lists them.

## Install

Download the Firn installer, check it, and follow the
[installation guide](docs/installing.md):

- [Firn installer ISO (x86-64)](https://repository.frostyard.org/isos/native/v1/snosi-installer-latest-x86-64.iso)
- [SHA256SUMS](https://repository.frostyard.org/isos/native/v1/SHA256SUMS) and its [signature](https://repository.frostyard.org/isos/native/v1/SHA256SUMS.gpg)

The `native` segment in the URL is a publication namespace, not an install
choice. Firn offers the four bootc choices above. Native A/B and nbc hosts
get no new images: reinstall with Firn as the
[migration guide](docs/nbc-to-bootc-migration.md) says.
Repository cleanup deletes no published artifacts; any disposal needs the
exact-object gate of [ADR-0018](docs/adr/0018-remove-native-ab-and-nbc-lanes.md).

## How it works

The root `mkosi.conf` builds the base image and the sysexts; each product
profile in `mkosi.profiles/` adds its payload, kernel and the secure bootc
fragment. `/usr` is immutable, `/etc` is managed by the deployment and
`/var` persists. On an installed host, `bootc-update-stage.timer` pulls the
next signed image and stages it for the next reboot, and
`updex-update.timer` stages sysext updates for the next boot. The
[overview](docs/design/overview.md) has the details.

## Limits

- Snowfield ships untested on representative Surface hardware: its catalog
  gate is waived, not passed.
- Fixture tests do not establish production Secure Boot support or signed
  update and rollback evidence; see
  [secure bootc operations](docs/bootc-secure-operations.md).

## Develop

```sh
mise install   # the pinned tools (Node for the make gate)
make ci        # what ci.yml runs
just           # list the build recipes (mkosi is bootstrapped at its pin)
```

Image builds and VM tests need root and privileged tools: see the
[build pipeline](docs/design/build-pipeline.md) and
[testing](docs/design/testing.md).

## Where to go next

- [AGENTS.md](AGENTS.md): the rules for agents and contributors.
- [CONTRIBUTING.md](CONTRIBUTING.md): how to contribute.
- [docs/README.md](docs/README.md): the decisions, designs, specs and plans.
- [SECURITY.md](SECURITY.md): report a vulnerability privately.
- [LICENSE](LICENSE): MIT.
