# Frostyard integration contracts

This is the current producer/consumer map for Snosi's bootc OCI images,
sysexts and Firn ISO. Native A/B, nbc, `snosi-install` and
`snosi-firstboot` integrations were removed by
[ADR-0018](adr/0018-remove-native-ab-and-nbc-lanes.md); past wire formats
are recorded in [prototype history](native-ab-prototype-history.md).
Fragility: 🔴 implicit and easy to break; 🟡 partially enforced; 🟢 schema
checked or type-safe. Consult the producer's source and the named tests
before changing an interface.

## Installed tools and boundaries

| Producer | Consumer | Contract |
| --- | --- | --- |
| Frostyard bootc/libostree debs | `shared/packages/bootc/mkosi.conf` in each OCI profile | The bootc CLI/storage digest implementation must work against the selected Forky systemd family; repeat build-root bwrap checks on version changes. |
| `frostyard-updex` deb | Base sysext `.feature`/`.transfer` registrations, chairlift and Pilothouse | Per-component systemd-sysupdate discovery and Updex's CLI/Go SDK schema; keep the component-capable release ahead of clients. |
| `frostyard-chairlift` / `snow-first-setup` debs | Snow/Snowfield package set | Desktop feature UI and setup functionality; the retired native OS firstboot backend does not ship. |
| Pilothouse deb | Optional `pilothouse` sysext | Broker probes Updex and container backends independently; absent endpoints must not prevent startup. |
| frostyard/apt-publisher | Snosi APT sandbox (`frostyard.sources`) | Signed `trixie` indexes under `https://repository.frostyard.org/debian/`, signed with the same `frostyard.gpg` key; a `build` dispatch to Snosi after each publication from a producer that notifies it. |
| repogen | Sysext transfers | Per-component `SHA256SUMS.gpg` and versioned EROFS filenames under `ext/<component>/`. |
| Snosi ISO publisher | Firn download and `workers/native-installer-redirect/` | Signed `isos/native/v1/SHA256SUMS` and detached signature; Worker reads the index and redirects to the named immutable ISO. |

The base no longer installs `frostyard-nbc` or
`nbc-update-download.service` (`test/no-nbc-test.sh`). Only bootc profiles
are built. The public ISO signing ring and MOK/PCR identities remain at
`shared/native-ab/keys/` because Firn, bootc-secure and external lab bootc
lanes use that path; the native-named directory is not an OS update source.

## Updex and sysext discovery

The base ships one `sysupdate.<name>.d/` directory per sysext with
`<name>.feature` and `<name>.transfer`. These download `/usr`-only EROFS
overlays into `/var/lib/extensions.d/` for systemd-sysext; Updex exposes
components and features to chairlift/Pilothouse. Keep each component in its
own definitions directory: systemd-sysupdate version-locks enabled transfers
sharing a directory. The source uses `Verify=true` with the Frostyard
repository key installed at both systemd vendor keyring names; the client
verifies `SHA256SUMS.gpg` before trusting hashes. `test/sysext-signature-verification-test.sh`
guards this trust path. For the `/usr`-only authoring and service activation
constraints see [sysext design](design/sysexts.md).

Updex `features check --json` and `features update --json` can emit top-level
or nested `null` instead of `[]` for an empty Go nil slice. Pilothouse's
feature-check parser accepts the terminal `null` as empty; `features list`
is still expected to be an array. Downstream broker maintenance state may
emit `updates:null` and clients must not assume `[]`. Chairlift uses Updex's
Go SDK for its feature read path and is nil-safe; its SDK version must remain
compatible with the installed Updex. Shape changes need coordinated tests
and releases. A future schema-owning update/sysext API is discussed in the
[daemon design](plans/2026-07-20-update-api-daemon-design.md).

## Bootc status and update state

`bootc status --format json` is consumed by
`mkosi.images/base/mkosi.extra/usr/libexec/bootc-update-stage`,
`mkosi.images/base/mkosi.extra/usr/bin/snosi-update-status`, and chairlift.
The updater reads `spec.image` plus booted/staged/rollback digests and
checks the staged `imageDigest` against the Podman-pulled manifest digest.
`bootc switch` to an identical spec can silently no-op, so a successful
command exit is not a stage proof. The signature policy accepts narrowly
scoped GHCR repositories, then allows already-verified local
`containers-storage:` for bootc consumption.

The sole shipped stager writes two key/value files under `/run/snosi/`:

```text
update-check: outcome=current|staged|held-rollback|failed
              checked_at=<timestamp>, image=<ref>, running_version=<label>, remote_version=<label>
update-staged: image=<ref>, digest=sha256:<hex>, staged_at=<timestamp>
```

`snosi-update-status`, the motd hook and desktop notifier read these files.
The notifier acknowledges each staged digest once. Files under `/run` clear
at reboot. `snosi-update-status --pkg-diff` resolves only an identity-matched
write-once package sidecar through
`mkosi.images/base/mkosi.extra/usr/lib/snosi/staged-packages.sh`:

```text
/run/snosi/staged-packages -> staged-packages.sha256-<64hex>
/run/snosi/staged-packages.sha256-<64hex>/identity     # digest=sha256:<hex>
/run/snosi/staged-packages.sha256-<64hex>/packages.txt # staged image bytes
```

The library still parses `version=<14-digit>` identities as a retained API,
even though no shipped stager publishes one; do not remove the parser as an
incidental native-lane cleanup. A mismatched sidecar is treated as missing
and the CLI warns/skips the diff without masking ordinary update status.
`test/pkg-diff-test.sh` pins parse, identity and atomic symlink publication.

## Public repository and ISO signing

frostyard/apt-publisher publishes signed Frostyard APT indexes under
`debian/dists/<codename>/`; Snosi reads `trixie`
([core ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md)).
The legacy `dists/stable/` suite is frozen. Repogen publishes signed sysext
metadata under `ext/<component>/`. Sysext object names follow
`<name>_<version>_<os-version>_<arch>.raw.zst`; feature/transfer discovery
and the GPG trust ring belong to the base image, not the Firn ISO. Bootc OCI
images publish to `ghcr.io/frostyard/` by immutable signed digest before
promoting `latest`.

The retained Firn ISO publisher in `shared/native-ab/publish/` stages an
immutable `snosi-installer_<14-digit>_x86-64.iso` below `isos/native/v1/`,
verifies candidate bytes over the public HTTP origin, then promotes an
OpenPGP-signed checksum index signature-first/manifest-last. The public
`shared/native-ab/keys/import-pubring.gpg` authenticates that index.
`workers/native-installer-redirect/` derives the uncacheable stable URL
from the live index, without an independent version pointer. There is no
automatic ISO retention workflow. Future deletion of published objects is
subject to [ADR-0018's exact-object gate](adr/0018-remove-native-ab-and-nbc-lanes.md).
