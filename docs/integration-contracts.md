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
| Frostyard bootc/libostree debs | `shared/packages/bootc/mkosi.conf` in each OCI profile; each suite's pair in `shared/packages/bootc/{trixie,forky}.conf` | The bootc CLI/storage digest implementation must work against the selected Forky systemd family; repeat build-root bwrap checks on version changes. |
| `frostyard-updex` deb | Base sysext `.feature`/`.transfer` registrations, chairlift and Pilothouse | Per-component systemd-sysupdate discovery and Updex's CLI/Go SDK schema; keep the component-capable release ahead of clients. |
| `frostyard-chairlift` deb | Snow/Snowfield and Sundog package sets | Desktop feature UI; the retired native OS firstboot backend does not ship. |
| `frostyard-chairlift` deb (`/usr/bin/chairlift-first-run`, chairlift ADR-0014) | Snow tree autostart entry `/etc/xdg/autostart/org.frostyard.ChairLift.FirstRun.desktop` | `Type=Application`, only the keys `Name`, `GenericName`, `Comment` (and their localized forms), `Exec`, `Icon`, `Terminal=false`, `NoDisplay`, `StartupNotify`, `Categories` and `Version` (no `TryExec`, `OnlyShowIn`, `Hidden` or other launch condition), `Exec=/usr/bin/chairlift-first-run` exactly, and the program executable by every user; the program gates on `${XDG_CONFIG_HOME:-~/.config}/chairlift/first-run.done` or the legacy `snow-first-setup.done`, and `--mark-done` writes both. The deb ships no autostart entry. 🟢 `first-login.finalize` fails Snow/Snowfield without the executable, with another `Exec`, or with zero or two first-login entries ([ADR-0028](adr/0028-first-login-runs-chairlift-first-run.md)). |
| Snow tree `/usr/share/snow/first-run/apps.json` | chairlift first run (`first_run_apps_group`, default `apps_path`) | First-setup's shape: category → `[{name, id, active?}]`, `active` defaults to true, ids are valid Flatpak application IDs and unique. Snosi ships no chairlift config. At most 1 MiB. 🟢 `first-login-check.py` (finalize and `test/first-login-trigger-test.sh`) fails the build on every fault chairlift's `LoadApps`/`ParseApps` rejects, and also on a duplicate JSON key or an empty category key; chairlift hides the Apps step on a bad list. |
| Pilothouse deb | Optional `pilothouse` sysext | Broker probes Updex and container backends independently; absent endpoints must not prevent startup. |
| frostyard/apt-publisher | Snosi APT sandbox (`frostyard.sources`) | Signed `trixie` indexes (components `main` and `image`) under `https://repository.frostyard.org/debian/`, signed with the same `frostyard.gpg` key; a `build` dispatch to Snosi after each publication from a producer that notifies it. |
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
verifies `SHA256SUMS.gpg` before trusting hashes. The secure bootc composition
restores that keyring after `systemd-container/forky` overwrites `.pgp`.
`test/sysext-signature-verification-test.sh` guards this trust path statically
and, with `--rootfs`, on every built OCI tree. For the `/usr`-only authoring and service activation
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
command exit is not a stage proof. The stager's strict update policy in `/usr`
(`/usr/lib/snosi/containers/bootc-policy.json`) accepts narrowly scoped GHCR
repositories, then allows already-verified local `containers-storage:` for
bootc consumption.

The sole shipped stager writes two key/value files under `/run/snosi/`:

```text
update-check: outcome=current|staged|held-rollback|failed
              checked_at=<timestamp>, image=<ref>, running_version=<label>, remote_version=<label>
              error_class=network|registry|signature|disk_space|lock|other   (outcome=failed only)
update-staged: image=<ref>, digest=sha256:<hex>, staged_at=<timestamp>
```

`snosi-update-status`, the motd hook and desktop notifier read these files.
Readers take keys by name, so they ignore keys they do not know. 🟢
`error_class` ([ADR-0029](adr/0029-snosi-health-records-problems.md)) is the
class of the stderr of the stager's podman and bootc calls, picked by fixed
patterns; it never holds error text. `snosi-health` reads it for
`update_stage_failed`; `test/bootc-container-policy-test.sh` pins 1 case for
each class.
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

## Core Flatpak sets

🟢 Each bootc image carries its product's core Flatpak set in the OCI label
`org.frostyard.core-flatpaks`; Firn reads it before installing when a
recipe sets `core_flatpaks = true`
([firn ADR-0018](https://github.com/frostyard/firn/blob/main/docs/adr/0018-image-published-core-flatpaks-label.md)).
The value is compact JSON, `{"version":1,"flatpaks":[{"id":…,"name":…}]}`.
Sources are `flatpaks/snow.json` (Snow and Snowfield) and
`flatpaks/sundog.json`; Floe maps to no file and carries no label key.
`flatpaks/core-flatpaks.py` holds the product mapping, validates the files
(Flatpak application IDs, names, no duplicates, no empty set), prints each
build's label argument, and checks the packaged image before push in every
`buildah-package.sh` lane. `test/core-flatpaks-test.sh` pins the contract.

Installed systems cannot easily read their image's label, so each image
also ships its set at `/usr/share/frostyard/<IMAGE_ID>.core-flatpaks.json`,
a byte copy of its source file beside the core ADR-0003 provenance files.
The org namespace (core ADR-0004) lets other products, such as chairlift,
read it. Snowfield's file carries Snow's set and Floe ships none.
`shared/composition/core-flatpaks.finalize` installs it and
`core-flatpaks.postoutput` fails the build when the output tree's file is
missing, changed or unexpected. Nothing reconciles installed Flatpaks with a
changed set.

`label` refuses to print while any source is invalid or stale, so a build
cannot stamp a label the repository disagrees with. The secure lane checks
the label again on the pushed, signed digest before `latest` is promoted,
and `test/core-flatpaks-test.sh` requires every packaging lane to pass the
label and check it.

The Firn ISO carries no core list: its former
`/usr/share/firn/core-flatpaks.json` fallback gave every product Snow's
set and was retired once the ISO's Firn read the label.
`flatpaks/legacy/firn-core-flatpaks.json`, Snow's set in the legacy
`{"core": [...]}` shape and generated from `flatpaks/snow.json`, now feeds
only `just firn-flatpak-seed`. `snow-first-setup` no longer ships
([ADR-0028](adr/0028-first-login-runs-chairlift-first-run.md)) and is
withdrawn from APT ([ADR-0031](adr/0031-first-setup-retired-without-a-soak.md));
its `core.json` defined no set.

## Public repository and ISO signing

frostyard/apt-publisher publishes signed Frostyard APT indexes under
`debian/dists/<codename>/`; Snosi reads the `main` and `image` components of
`trixie`
([core ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md),
[ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md)).
`image` holds Frostyard image-only builds; it is empty until ADR-0059 step 5
moves `bootc`, `libostree-1-1` and `incus*` into it. Only the build sandbox
(`frostyard.sources`) enables it; installed images carry no Frostyard APT
source.
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

## Problem records (snosi-health)

🟢 `snosi-health` ([ADR-0029](adr/0029-snosi-health-records-problems.md)) is
the system collector of frostyard/core's problem reports (schema
`frostyard.problem/1`,
[core spec](https://github.com/frostyard/core/blob/main/docs/specs/problem-report.md)).
It publishes these files together as 1 recoverable transaction (staged in
`.pending/`, a `COMMIT` marker, then renames; ADR-0029):

| File | Mode | Content |
| --- | --- | --- |
| `/var/lib/snosi-health/problems.json` | 0644 root | Format 1: `format`, `schema`, `generated`, `image` (`id`, `version`), `secure`, `client`, and `problems[]` with `id`, `kind`, `detail`, `week`, `first_seen`, `last_seen`, `occurrences`, `reportable`. `detail` holds only v1 report fields whose value passes its v1 property schema; `reportable` is true only when the envelope validates. No journal text, command line, path, username, unit instance, hostname, machine ID or boot ID. At most 200 records, none older than 90 days |
| `/var/lib/snosi-health/details.json` | 0640 root:sudo | Format 1: for each `id`, `kind`, `local` (the detail before sanitizing), `extra` (full unit names, a crash's executable path) and up to 5 journal texts of at most 1024 characters |
| `/var/lib/snosi-health/state.json`, `journal.cursor` | 0600 root | Private collector state: boot slots, the hashes of the last counted inputs, the updex feature keys, and the system-journal cursor |

Consumers: chairlift's Problems page (both files; `details.json` only for
`sudo` members), `snosi-health --list`, and Floe's sender
`snosi-health-report` ([ADR-0030](adr/0030-floe-sends-problem-reports-with-admin-consent.md)),
which builds a report document with a new `report_id` from a reportable
record and posts it (below). A consumer must accept a `null` `image.id`,
`image.version` or `client` (a host that is not a snosi product). The
collector's inputs are other contracts:

- `/run/snosi/update-check` (above), with `error_class`;
- `bootc status --format json`: `.status.booted.image.version` and
  `.status.rollback.image.version`;
- `/var/lib/updex/last-run.json`, format 1
  ([updex spec](https://github.com/frostyard/updex/blob/main/docs/specs/last-run-record.md)):
  an absent file or another format is no record; only features of origin
  `image` or `catalog` count; an unknown `outcome` or `error_class` becomes
  `other`;
- the system journal: systemd-coredump entries and the frostyard library's
  entries (`MESSAGE_ID` `8915bdd215c84cbab0c31c05a1a33e7e`, `FROSTYARD_*`
  fields validated by core's spec rule 4), and this boot's
  systemd-cryptsetup and kernel lines. The systemd-cryptsetup texts are
  systemd v262's; the Forky sentinel PR body asks for a recheck.

`test/snosi-health-test.sh` validates the output against a pinned byte copy
of core's `v1.json` (`test/fixtures/snosi-health/schema/`) with
`test/lib/json_schema_subset.py`.

### Problem reports from Floe

🟢 Only the tree `shared/snosi-report/tree` ships the sender
([ADR-0030](adr/0030-floe-sends-problem-reports-with-admin-consent.md)):
`/usr/libexec/snosi-health-report`, `snosi-health-report.service`,
`snosi-health-report.timer`, `06-snosi-health-report.preset` and the motd hook
`/etc/update-motd.d/87-snosi-health-reporting`. Snow, Snowfield and Sundog
ship no sender: chairlift's Problems page sends their reports. Base's
`snosi-health` dispatches `reporting` and `send` to the sender, and prints
that problem reporting is not part of the image when it is absent.

| File | Mode | Content |
| --- | --- | --- |
| `/etc/snosi-health/reporting.conf` | 0644 root | Written only by `sudo snosi-health reporting on` and `sudo snosi-health reporting off`: 2 comment lines, `enabled=` 0 or 1, `schema=` (consent is for `frostyard.problem/1` only), `decided_at=` (UTC RFC 3339) and `endpoint=` when a valid one was set. Only lines starting with those 4 keys count and the last value wins; `off` never deletes the file. No image ships this path. `/var/lib/snosi-health/.post.lock` carries the decision: a post holds it and re-reads the file, and `reporting on` and `off` take it after writing, so `off` returns only after the post in flight and no later post starts |
| `/var/lib/snosi-health/sent.jsonl` | 0644 root | 1 line for each posted document: `sent_at` (UTC RFC 3339 of that post, read again before each post), `status` (`accepted` or `rejected`), `http_status`, `problem_id` (16 hex, `null` for the count) and the posted `report`. Only a send that posts every report it selected rewrites the file: it drops entries older than 90 days and lines that are not JSON or have no string `sent_at` ([ADR-0032](adr/0032-sent-jsonl-pruning-and-core-file-override.md)); until then a line that is not JSON is skipped by the reader |

HTTP contract with frostyard/problem-intake
([intake API](https://github.com/frostyard/problem-intake/blob/main/docs/specs/intake-api.md)):
`POST` to `https://report.frostyard.org/v1/report` by default (or the
`endpoint=` of the consent file) with `Content-Type: application/json`, no
`User-Agent`, no `Accept`, no redirect followed, 7 seconds between 2 requests,
and curl `-q` as its first argument so no `~/.curlrc` can add a header, follow
a redirect or set a proxy. At most 20 problem reports a day and 1 `count` a
week; a report of kind `crash` is never sent. A run stops with exit 0 and lets
the next run select again when its clock passes midnight, or the end of the
ISO week of its count, before the next post.

| Answer | Sender |
| --- | --- |
| 2xx | record the document as `accepted` |
| 400, 413, 415 | record it as `rejected`; it is never retried |
| 429, 503, another code, a redirect, a curl failure | stop the run, record nothing, exit 0; the next daily run tries again |

`snosi-health --validate` (base, any user, no lock and no state) is the 1
validator of a report document: it reads JSON values from stdin, prints each
valid one as compact JSON, 1 per line, and exits 1 when any is invalid or the
input is not JSON. The sender asks it about every document before a post. 🟢
`test/snosi-health-report-test.sh` (a fake intake on 127.0.0.1, no root, no
image build).
