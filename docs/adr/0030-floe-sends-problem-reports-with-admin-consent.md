# 0030 — Floe sends problem reports with admin consent

- **Status:** Accepted; the `sent.jsonl` pruning statement is amended by [ADR-0032](0032-sent-jsonl-pruning-and-core-file-override.md)
- **Date:** 2026-11-05

## Context

[ADR-0029](0029-snosi-health-records-problems.md) ships the system collector
`snosi-health`: it records the problems of a host in
`/var/lib/snosi-health/problems.json` and sends nothing. That ADR left the
Floe sender as later work (plan T857 task t20) and named what it would add: a
`report_id` on a reportable record.

frostyard/core
[ADR-0069](https://github.com/frostyard/core/blob/main/docs/adr/0069-report-problems-local-first-opt-in-with-one-sender-per-host.md)
and its [problem-report spec](https://github.com/frostyard/core/blob/main/docs/specs/problem-report.md)
fix the rule: local first, opt-in, and **one sender per host**. Snow,
Snowfield and Sundog ship chairlift, whose Problems page sends the reports of
a user's own session. Floe is the server product: it has no chairlift and no
desktop session, so without a system sender a Floe host can never report
anything, and no one learns that an image update failed on a server.

The public promise of this feature is
<https://frostyard.org/privacy/problem-reports/>: what is sent, what is not,
and that it is off until the administrator agrees.

The intake Worker ([intake API](https://github.com/frostyard/problem-intake/blob/main/docs/specs/intake-api.md))
defines the HTTP contract: `POST /v1/report` answers 202
`{"status":"accepted"}`; 503 (kill switch, `Retry-After: 86400`) while the
switch is not `off`; 429 over 10 requests in 60 seconds for one key; 415 for a
media type other than `application/json`; 413 over 8192 bytes; 400 for a body
that is not a valid `frostyard.problem/1` document; 502 and 500 for an
upstream or unexpected failure. A redirect is a failure, never a success.

Facts that shape the decision:

- `problems.json` is world-readable and holds only enum values,
  pattern-checked names and versions. A report that leaves the host is public
  in the same way, and it carries a program name for a crash.
- Plan T857 (row S7) keeps crash reports local in phases 1 and 2 on every
  product: native stacks and their symbolization are phase 3 work with their
  own privacy review, and the privacy page promises no crash report until
  then.
- The Floe tree `shared/floe/tree` is also included by
  `shared/composition/sundog/mkosi.conf`, so a file placed there ships on
  Sundog too. The sender must ship on Floe only (core ADR-0069).
- [ADR-0009](0009-snosi-env-var-classes.md) classes every `SNOSI_*`
  variable; an operator setting is not one of them.
- [ADR-0002](0002-ship-no-enablement-symlinks-in-etc.md) and
  [ADR-0003](0003-runtime-etc-mutation-ban.md) forbid enablement symlinks in
  `/etc` and any runtime mutation of `/etc` by a shipped payload.

## Decision

**Consent file.** `/etc/snosi-health/reporting.conf` (0644 root) is the one
switch. `sudo snosi-health reporting on|off` writes it as a whole: 2 comment
lines (who wrote it, the privacy URL), then `enabled=1` or `enabled=0`,
`schema=frostyard.problem/1`, `decided_at=<UTC RFC 3339>` and, only when a
valid one was already there, `endpoint=`. The directory is created with
`install -d -m 0755`, the file is staged beside itself, `chmod 0644`, and
moved into place by rename. `off` never deletes the file: the decision stays
readable, and the endpoints of a later `on` survive. The reader takes only
lines that start with `enabled=`, `schema=`, `decided_at=` or `endpoint=`,
the last value of a key wins, comments and every other line are ignored, and
reporting is **on** only when `enabled=1` **and** `schema=frostyard.problem/1`.
A consent for another schema version therefore sends nothing. `reporting
status` works for any user and prints 4 states: on since a date, off by
choice since a date, off (not chosen yet), and off with a consent for another
schema plus the command that agrees to this one.

**Consent holds through a run.** A run can last minutes, so the file is not
read only at start. `snosi-health-report` holds
`/var/lib/snosi-health/.post.lock` for the duration of 1 post and reads the
consent file again under it; when the file says off, the run releases the
lock, prints "problem reporting was turned off; stopping" and exits 0.
`reporting on|off` writes the file first and then takes the same lock (60 s
timeout): the decision waits for the post in flight and no later post of that
run starts, so `reporting off` never returns while the sender still posts.

**No `/etc/snosi-health` in any image.** The file exists only after an
administrator runs 1 of those commands, so an image never ships consent. The
unmodified answer of every Floe install is "off".

**Endpoint is a file key, not a variable.** `endpoint=` holds a plain
`http(s)` URL (no query, no fragment, no credentials). An invalid value makes
a send refuse with an error and exit 1; an absent value uses
`https://report.frostyard.org/v1/report`. ADR-0009 leaves no class for an
operator setting like this, and a file key is visible, editable and testable.

**One sender, Floe only.** The sender is
`/usr/libexec/snosi-health-report`, shipped from a tree of its own,
`shared/snosi-report/tree`, which only `shared/composition/floe/mkosi.conf`
adds. The base collector dispatches `snosi-health reporting …` and
`snosi-health send …` to it, and on any other product prints that problem
reporting is not part of that image and that chairlift's Problems page sends
the reports. The dispatch runs before the root check, because `status` and
`send --dry-run` are for every user.

**Selection.** A run takes `.problems[]` that are `reportable`, of the kinds
`unit_failed`, `update_stage_failed`, `booted_older_image`,
`sysext_update_failed`, `tpm_unlock`, `integrity_error` and `app_problem`,
orders them oldest `last_seen` first, and posts at most 20 a day (minus what
already went out that UTC day). **`crash` is never sent**: crash reports stay
on the host in phases 1 and 2 of plan T857 (no sender on any product sends
one), and a test fails if this sender posts one. A problem is sent once for
each ISO week: the send key is the pair (problem id, record week), kept in
`sent.jsonl`, so an hourly collector run cannot post the same problem twice
and a problem that stays broken is reportable again in a later week.

**Weekly count.** Once an ISO week the sender adds 1 `count` report: the age
of the install in `<1w`, `<1m`, `<6m`, `>=6m` (the birth time of `/var` when
the filesystem records it, else the mtime of `/etc/machine-id`) and the image
channel `latest` when `bootc status --format json` ends `.spec.image.image`
with `:latest`, else `other`. `bootc status` needs root, so when it fails or is
absent (a dry run by another user) the sender reads the same image reference
from the `image=` key of the stager's world-readable `/run/snosi/update-check`;
with neither, the channel is `other`. The count
answers "how many hosts run this, and how old are they" without reporting
anything about a person. Without a known install time the count waits.

**One validator.** Base's collector owns `--validate`: it reads report
documents as JSON values from stdin, prints each valid one as compact JSON,
prints `snosi-health: report N fails frostyard.problem/1` for each invalid
one, and exits 1 when any is invalid or the input is not JSON. It needs no
root, takes no lock and writes no state. The sender validates every document
with it and drops an invalid one with a warning: an invalid report stays
local.

**Posting.** Each document is 1 `curl` POST with `-q` (`--disable`) as its
first argument, then `--proto '=http,https'`, `--connect-timeout 10`,
`--max-time 30`, an empty `-A ''`, `-H 'Accept:'` to remove the header,
`-H 'Content-Type: application/json'`, the compact JSON as `--data-binary`,
`-o /dev/null -w '%{http_code}'` and **no `-L`**. `-q` must come first or curl
ignores it: a user's `~/.curlrc` must not add a header, follow a redirect or
set a proxy on a report. Between 2 requests the sender sleeps 7 seconds, so a
run stays under the Worker's 10 requests a minute. The order is problems
first, then the count.

**The clock of each post.** The UTC day, the ISO week and `sent_at` belong to
the post, not to the run start. Before each post the sender reads the clock
again: when its UTC day differs from the day the run started, the run stops
with a message and exits 0, and when the document is the weekly count and the
clock's ISO week differs from the week in that document, the run stops too.
The next daily run selects again, so a run that crosses midnight cannot post
the reports of yesterday under yesterday's count of 20. `sent_at` in
`sent.jsonl` is the clock of that post.

**Answers.** 2xx is `accepted`. 400, 413 and 415 are `rejected` and never
retried: the intake has judged the document itself. Any other answer (429,
503, a 5xx, a redirect that curl refuses to follow, a curl failure) stops the
run at once: nothing is recorded for that document, a warning names the code,
the command exits 0, and the next daily run tries again.

**`sent.jsonl`.** `/var/lib/snosi-health/sent.jsonl` (0644 root) records what
was posted, 1 line for each accepted or rejected document:
`{"sent_at":"<UTC RFC 3339>","status":"accepted|rejected","http_status":<int>,"problem_id":"<16 hex>"|null,"report":<the document>}`.
The count has no problem id. After a run, entries older than 90 days are
rewritten away (temp file and rename). A bad line is skipped by the reader, so
it never hides the rest.

**Timer and units.** `snosi-health-report.timer` runs daily
(`RandomizedDelaySec=4h`, `Persistent=true`) and
`06-snosi-health-report.preset` always enables it: the script, not an
administrator, is the gate. `snosi-health-report.service` is a oneshot with
`ConditionPathExists=/etc/snosi-health/reporting.conf`, `Nice=19`,
`IOSchedulingClass=idle`, `TimeoutStartSec=15min`, `ProtectSystem=strict`,
`ProtectHome=yes`, `PrivateTmp=yes`, `NoNewPrivileges=yes`, no `[Install]`
and no `Before=`. `StateDirectory=snosi-health` creates the state directory.
The network: `After=network-online.target`, `Wants=network-online.target`,
`RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`.

**motd.** `87-snosi-health-reporting` prints 1 line, "Problem reporting is
off. See `snosi-health reporting --help`.", while the consent file has no
`enabled=0` or `enabled=1` line, so every admin who logs in to a Floe server
learns that reporting waits for a decision.

**Build guard.** `shared/outformat/image/finalize/snosi-health-timer.finalize`
now also fails a build that ships `/etc/snosi-health`, and fails a build
whose preset enables `snosi-health-report.timer` while
`usr/libexec/snosi-health-report`, its timer or its service is missing, or
`system timers.target.wants/snosi-health-report.timer` is missing from the
enablement manifest. Both timers are checked in every run, so 1 failure never
hides the other.

**Test hooks.** The sender copies the collector's paired hooks
([ADR-0009](0009-snosi-env-var-classes.md) class 3): `SNOSI_HEALTH_TEST_HOOKS`
(only `""`, `0` or `1`) plus `SNOSI_HEALTH_TEST_ROOT`, and, only under them, a
fixed clock `SNOSI_HEALTH_TEST_NOW`, a request pace `SNOSI_HEALTH_TEST_PACE`
(0 to 60) and a clock step `SNOSI_HEALTH_TEST_CLOCK_STEP` (0 to 86400
seconds): the step moves the clock forward by 1 step for each report the run
already posted, so a fixture can walk a run over midnight or over the end of
an ISO week. The report_id source is always the real
`/proc/sys/kernel/random/uuid`, never the test root. The hooks are not in
`--help`.

## Consequences

- A Floe administrator can turn problem reporting on with 1 command, see
  exactly what would be sent with `snosi-health send --dry-run`, and see what
  was sent in `sent.jsonl`. The project learns about failed updates, TPM
  unlock retries and integrity errors on servers it otherwise never hears
  from.
- **A stop between the POST and the append can send 1 duplicate.** The intake
  has no idempotency key, so the next run posts that document again.
- `reporting off` waits at most 60 s for the post in flight. If a post runs
  longer, the command prints a warning and returns; that post finishes, and no
  later post starts because the run reads the file again under the lock.
- `install_age` depends on the birth time of `/var`, which some filesystems do
  not record; the fallback is the mtime of `/etc/machine-id`, which is close
  to the first boot but not exact.
- **Dry-run `report_id` values differ from the real ones**, because each
  document gets a new random id; a dry run therefore cannot be compared byte
  for byte with a later `sent.jsonl` line.
- The sender is the only Floe payload that opens a network socket to a project
  service. A bug in the selection is a privacy problem, not only a bug: a
  change to the kind list, the age buckets or the channel is a change to the
  public promise and needs the privacy page updated.
- 400, 413 and 415 are final: a document the intake refuses is never repaired
  or retried, because a repair would change what the host claims.
- A host whose `/etc/snosi-health/reporting.conf` is malformed (no `enabled=`
  line) reports nothing and says so in the motd line: a silent failure is
  visible at login.
- Sundog includes the Floe tree, so the report payload lives in its own tree;
  a product that wants the sender later adds 1 `ExtraTrees=` line, and the
  build guard then requires its units in that image.
- The desktops keep 1 sender (chairlift). Base ships no sender, so Snow,
  Snowfield and Sundog answer `snosi-health send` with a pointer to
  chairlift instead of sending a second report of the same problem.

## Alternatives considered

- **A sender in base, for every image:** Snow, Snowfield and Sundog would then
  have 2 senders for one host (chairlift's Problems page and this one), which
  core ADR-0069 forbids, and they would report a system problem twice.
- **A `SNOSI_*` environment variable for the endpoint:** ADR-0009 classes no
  operator setting as a variable, a variable is invisible in the image and the
  service, and a test hook and a real setting would share 1 namespace.
- **`systemctl enable` at run time (or at first boot):** ADR-0002 and 0003
  forbid payload enablement in `/etc`; the preset enables the timer, and the
  script gates on consent.
- **Sending `crash` records now:** plan T857 keeps crash reports local until
  phase 3, which adds stacks and their own privacy review. Floe's system
  crashes stay in `problems.json` and `details.json`.
- **Retrying a 429 or a 503 inside the run:** the intake already asks for a
  day (`Retry-After: 86400`), and a retry would double the request rate that
  the 429 protects.
- **Rounding the count to a weekly summary of every kind:** a per-kind
  histogram grows with every schema version and says more about a host than
  the 2 fields the privacy page promises.

## References

- Shapes and contracts: [integration-contracts.md](../integration-contracts.md#problem-records-snosi-health),
  [design/testing.md](../design/testing.md), [design/overview.md](../design/overview.md)
- Implemented by: `shared/snosi-report/tree/usr/libexec/snosi-health-report`,
  `shared/snosi-report/tree/usr/lib/systemd/system/snosi-health-report.service`,
  `shared/snosi-report/tree/usr/lib/systemd/system/snosi-health-report.timer`,
  `shared/snosi-report/tree/usr/lib/systemd/system-preset/06-snosi-health-report.preset`,
  `shared/snosi-report/tree/etc/update-motd.d/87-snosi-health-reporting`,
  `shared/composition/floe/mkosi.conf`,
  `mkosi.images/base/mkosi.extra/usr/bin/snosi-health` (`--validate`, the
  `reporting`/`send` dispatch),
  `shared/outformat/image/finalize/snosi-health-timer.finalize`
- Guarded by: `test/snosi-health-report-test.sh`,
  `test/snosi-health-timer-guard-test.sh`, `test/snosi-health-test.sh`
- Builds on: [ADR-0002](0002-ship-no-enablement-symlinks-in-etc.md),
  [ADR-0003](0003-runtime-etc-mutation-ban.md),
  [ADR-0009](0009-snosi-env-var-classes.md),
  [ADR-0029](0029-snosi-health-records-problems.md),
  [core ADR-0069](https://github.com/frostyard/core/blob/main/docs/adr/0069-report-problems-local-first-opt-in-with-one-sender-per-host.md),
  [intake API](https://github.com/frostyard/problem-intake/blob/main/docs/specs/intake-api.md),
  [privacy of problem reports](https://frostyard.org/privacy/problem-reports/)
