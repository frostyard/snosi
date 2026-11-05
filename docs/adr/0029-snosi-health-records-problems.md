# 0029 — snosi-health records problems; Floe sends with admin consent

- **Status:** Accepted
- **Date:** 2026-11-05

## Context

Problems on installed snosi hosts are invisible to the project. A failed
image unit, an update that never stages, a TPM unlock that needs retries
after a release, a sysext update that fails, a composefs or verity error,
and crashes of image programs and frostyard apps show only in a journal that
nobody reads. frostyard/core
[ADR-0069](https://github.com/frostyard/core/blob/main/docs/adr/0069-report-problems-local-first-opt-in-with-one-sender-per-host.md)
and its spec
[problem-report.md](https://github.com/frostyard/core/blob/main/docs/specs/problem-report.md)
define the fixed schema `frostyard.problem/1` and the rule: local first,
opt-in, one sender per host. Plan T857 gives snosi the system collector.

Facts that constrain it:

- The journal is readable by `adm`/`systemd-journal` members only; a
  world-readable file must not copy journal text past that ACL.
- `FROSTYARD_*` journal fields can be forged by any user with `systemd-cat`
  (core spec rule 4).
- Unit names, mount unit names, instances and coredump paths can contain
  user names and paths.
- No image shipped systemd-coredump. The Debian package ships
  `kernel.core_pattern=|/usr/lib/systemd/systemd-coredump %P %u %g %s %t %c
  %h %d %F %I` and `fs.suid_dumpable=2`, and it stores core files on disk by
  default (`Storage=external`, `ProcessSizeMax=32G`).
- CVE-2025-4598: a crashed set-user-ID process whose PID is reused could let
  systemd-coredump give the core of the privileged process to the user.
  systemd 258 and 257.6 fixed it with the kernel's dumpable flag (`%d`) and
  the pidfd of the crashed process (`%F`).
- The bootc stager wrote only `outcome=failed` for a failed stage; the reason
  stayed in the journal as free text.

## Decision

**Collector.** Base ships `/usr/bin/snosi-health` (bash and jq),
`snosi-health.service` and `snosi-health.timer`. The timer runs 3 minutes
after boot and then hourly (`OnBootSec=3min`, `OnUnitActiveSec=1h`,
`RandomizedDelaySec=5min`) and is `WantedBy=timers.target` only. The
service is a oneshot at idle CPU and I/O priority with
`TimeoutStartSec=5min`, no network (`PrivateNetwork=yes`,
`RestrictAddressFamilies=AF_UNIX`), `ProtectSystem=full`, `ProtectHome=yes`,
`StateDirectory=snosi-health`, no `Before=`, no `[Install]`, and no ordering
on a login or graphical unit. `06-snosi-health.preset` enables the timer;
`shared/outformat/image/finalize/snosi-health-timer.finalize` fails the build
when the preset has no units, no collector or no
`system timers.target.wants/snosi-health.timer` manifest entry
([ADR-0002](0002-ship-no-enablement-symlinks-in-etc.md)). Every external
command has a `timeout`; a `flock` keeps 2 runs apart.

**Inputs** (kinds of core's spec):

| Kind | Source |
| --- | --- |
| `unit_failed` | `systemctl list-units --failed` and `systemctl show -p Result,FragmentPath`; the instance is stripped (`user@1000.service` → `user@.service`); `shipped` is true only for a fragment under `/usr/lib/systemd/system/` |
| `update_stage_failed` | `/run/snosi/update-check` `outcome=failed`, its new `error_class` key, `remote_version`, and `bootc --version` |
| `booted_older_image` | `bootc status --format json`: the rollback deployment's version label is newer than the booted one; `how` is `manual_rollback` with `outcome=held-rollback`, else `unknown` |
| `sysext_update_failed` | only `/var/lib/updex/last-run.json` format 1 (updex `docs/specs/last-run-record.md`); origin `image` or `catalog` only |
| `tpm_unlock` | this boot's `SYSLOG_IDENTIFIER=systemd-cryptsetup` journal lines (initrd included), matched against the texts of systemd v262 and tpm2-tss's ESYS logger; only a retry or a fallback is recorded |
| `integrity_error` | this boot's kernel lines at warning or worse (fs-verity, dm-verity, overlayfs verity and erofs as `composefs`), counted in the buckets `1`, `2-10`, `>10` |
| `crash` | system-journal coredump entries (`MESSAGE_ID=fc2e22bc6ee647b6b90729ab34a250b1`) with `_UID` and `COREDUMP_UID` below 1000; `exe` only for a program under `/usr` |
| `app_problem` | system-journal library entries (`MESSAGE_ID=8915bdd215c84cbab0c31c05a1a33e7e`) with `_UID` below 1000; every `FROSTYARD_*` value must pass the spec, else the entry is dropped |

`crash` and `app_problem` read new entries only, through 1 journal cursor in
the state directory (90 days on the first run). The cursor moves only after
the records are on disk. `unit_failed`, `booted_older_image`, `tpm_unlock`
and `integrity_error` count at most once for each boot; a different value
in the same boot (a bigger bucket) replaces that boot's record. A new
`update-check` or `last-run.json` content counts once.

A fallback to a passphrase or a recovery key is recorded as `outcome`
`other`: systemd v262 logs no line that tells which secret was typed. Users
from `1000` up are left out of `crash` and `app_problem`, because chairlift
reads those from the user's own journal (one sender for each record).

**`/var/lib/snosi-health/problems.json`** (mode 0644, format 1):

```json
{"format": 1, "schema": "frostyard.problem/1", "generated": "<RFC 3339 UTC>",
 "image": {"id": "<IMAGE_ID or null>", "version": "<IMAGE_VERSION or null>"},
 "secure": true, "client": "snosi-health/<IMAGE_VERSION>",
 "problems": [{"id": "<16 hex>", "kind": "…", "detail": {…}, "week": "YYYY-Www",
               "first_seen": "…", "last_seen": "…", "occurrences": 1, "reportable": true}]}
```

- `image` comes from `/usr/lib/os-release` `IMAGE_ID` and `IMAGE_VERSION`
  (null when outside the schema); `secure` is true when `/proc/cmdline`
  holds the token `lockdown=integrity`, which the sealed UKI command line of
  every secure product carries ([ADR-0027](0027-seal-lockdown-into-the-secure-uki-command-line.md)).
- `id` is the first 16 hex digits of sha256 of the kind and the canonical
  JSON of the local detail; records merge by `id` across runs (first seen
  kept, last seen and occurrences updated). `week` is the ISO week of
  `last_seen` in UTC.
- `detail` holds only fields of the kind whose value matches its v1
  property schema; a failing value is dropped. A unit that is not shipped
  keeps only `result`. `reportable` is true only when the envelope plus the
  detail validates against `frostyard.problem/1`.
- No `MESSAGE`, command line, path, username, unit instance, hostname,
  machine ID or boot ID. Records older than 90 days go; at most 200 stay
  (the oldest `last_seen` goes first). The previous file is re-sanitized on
  every write.

**`/var/lib/snosi-health/details.json`** (mode 0640, `root:sudo`, format 1):
for each `id`, the kind, the local detail, extra local names (full unit names,
the core's executable path) and up to 5 journal texts of at most 1024
characters. `state.json` (0600) holds the boot ID, the boot-scoped slots and
the hashes of the last counted `update-check` and `last-run.json`. Every file
is written to a temp file in the same directory, then `chmod`, `chown` and
`mv -f`. `snosi-health --list` prints `problems.json` for any user.

**Test hooks** ([ADR-0009](0009-snosi-env-var-classes.md), class 3, paired):
`SNOSI_HEALTH_TEST_ROOT` prefixes every path and the root check relaxes only
with `SNOSI_HEALTH_TEST_HOOKS=1`; the root alone is inert, and hooks=1 without
a root or any value other than 0 or 1 is refused. The hooks are not in
`--help`.

**update-check `error_class`.** On `outcome=failed`, `bootc-update-stage`
adds 1 line `error_class=network|registry|signature|disk_space|lock|other`.
The stderr of `podman pull`, `podman image inspect` and the bootc calls also
goes to a private temp file (and still to the journal); fixed patterns pick
the class. No error text enters the file; no other key or outcome changes.

**systemd-coredump.** `systemd-coredump/forky` joins the Forky systemd family
in `shared/bootc-secure/mkosi.conf`, so all 4 products ship it, with
`libdw1t64` and `libelf1t64` from Trixie (mkosi installs no Recommends or
Suggests; systemd-coredump dlopens them for the stack text).
`shared/bootc-secure/tree/usr/lib/systemd/coredump.conf.d/50-snosi.conf`
sets `Storage=none` (no core file is kept; the journal entry and its stack
text remain) and `ProcessSizeMax=1G`. The package's `fs.suid_dumpable=2`
(suidsafe) stays: with `%d` (the dumpable flag) and `%F` (the pidfd) in the
core pattern, systemd 262 identifies the crashed process by its pidfd and does
not give the core of a process that was not dumpable to the user; that is the
CVE-2025-4598 fix. With `Storage=none` no core file exists in any case.
`shared/bootc-secure/finalize/coredump.finalize` fails the build unless the
binary exists, `Storage` resolves to `none` and `ProcessSizeMax` to at most
1G, the resolved `kernel.core_pattern` pipes to systemd-coredump with `%d`
and `%F`, no `sysctl.d` file sets `fs.suid_dumpable=1`, and `libdw.so.1` and
`libelf.so.1` exist.

**Floe sender (later work, plan T857 task t20).** On Floe, the admin turns
reporting on with `sudo snosi-health reporting on`; a daily timer then sends
reportable records. That sender, its consent file and its motd line are not
part of this change. This change sends nothing and opens no socket other
than `AF_UNIX`.

## Consequences

- chairlift's Problems page and `snosi-health --list` have one local,
  schema-checked source for system problems. A later sender adds only a
  `report_id` to a reportable record.
- `problems.json` is world-readable but holds only enum values and
  pattern-checked versions and names. The journal text stays behind the
  journal ACL or in `details.json` for `sudo` members.
- A failed stage before the pull knows no target version, so a network
  failure is recorded but is not reportable (`target_version` is required).
- Crashes keep no core file on any image. Debugging a crash needs a host
  drop-in `Storage=external` in `/etc/systemd/coredump.conf.d/`.
- The new `systemd-coredump` system account comes from the package's
  sysusers file; existing hosts get it at the next boot.
- `tpm_unlock` parses systemd text, which can change with a systemd update:
  the Forky sentinel PR body carries a fourth recheck,
  "snosi-health systemd-cryptsetup text".
- In systemd 262, `systemd-coredumpd.service` upholds
  `systemd-coredump-register.service` (a `RemainAfterExit=yes` oneshot), which
  switches `kernel.core_pattern` to the coredump socket
  (`@@/run/systemd/coredumpd/kernel`) when the kernel supports it; on other
  kernels the `sysctl.d` pipe pattern applies, and its `%F` needs a newer
  kernel than Trixie's stock 6.12. The build guard checks the pipe pattern,
  not the running kernel. The lab check (T857 t7) must prove that a
  `kill -SEGV` gives a crash record on each product and kernel.
- `/var/lib/snosi-health` is created by `StateDirectory=` at run time, so no
  image ships it and the var-audit maps need no line
  ([ADR-0001](0001-var-factory-state-outcome-maps.md)).

## Alternatives considered

- **A Go or Python collector:** base already ships bash and jq; a new
  runtime or binary package adds a release lane for a small parser.
- **Copy journal text into problems.json:** it would bypass the journal ACL
  and leak paths and names.
- **Count every hourly sighting:** a unit that stays failed would count 24
  times a day; boot-scoped slots count it once for each boot.
- **Keep core files (`Storage=external`):** disk use and memory images of
  processes on every host, for a debugging need that a host drop-in covers.
- **Classify stage errors in snosi-health from the journal:** it would parse
  free text later and outside the stager; the stager knows its own commands.

## References

- Shapes: [integration-contracts.md](../integration-contracts.md#problem-records-snosi-health),
  [design/build-pipeline.md](../design/build-pipeline.md),
  [design/testing.md](../design/testing.md)
- Implemented by: `mkosi.images/base/mkosi.extra/usr/bin/snosi-health`,
  `mkosi.images/base/mkosi.extra/usr/lib/systemd/system/snosi-health.{service,timer}`,
  `mkosi.images/base/mkosi.extra/usr/lib/systemd/system-preset/06-snosi-health.preset`,
  `mkosi.images/base/mkosi.extra/usr/libexec/bootc-update-stage`,
  `shared/bootc-secure/mkosi.conf`,
  `shared/bootc-secure/tree/usr/lib/systemd/coredump.conf.d/50-snosi.conf`
- Guarded by: `test/snosi-health-test.sh`,
  `test/snosi-health-timer-guard-test.sh`, `test/coredump-guard-test.sh`,
  `test/bootc-container-policy-test.sh` (error classes),
  `test/check-forky-systemd-test.sh` (the recheck)
- Builds on: [ADR-0001](0001-var-factory-state-outcome-maps.md),
  [ADR-0002](0002-ship-no-enablement-symlinks-in-etc.md),
  [ADR-0003](0003-runtime-etc-mutation-ban.md),
  [ADR-0009](0009-snosi-env-var-classes.md),
  [ADR-0013](0013-no-requiredby-enablement-prune-stale-requires.md),
  [ADR-0027](0027-seal-lockdown-into-the-secure-uki-command-line.md),
  [core ADR-0069](https://github.com/frostyard/core/blob/main/docs/adr/0069-report-problems-local-first-opt-in-with-one-sender-per-host.md),
  [updex last-run record](https://github.com/frostyard/updex/blob/main/docs/specs/last-run-record.md)
