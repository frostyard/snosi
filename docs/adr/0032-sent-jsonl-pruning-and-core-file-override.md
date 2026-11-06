# 0032 — sent.jsonl pruning and the core-file override, as the code does them

- **Status:** Accepted
- **Date:** 2026-11-06

## Context

ADR-0030 says:

> After a run, entries older than 90 days are rewritten away (temp file and
> rename).

That sentence is too broad. `prune_sent` in
`shared/snosi-report/tree/usr/libexec/snosi-health-report` has 1 call, after
the post loop of `send_reporting`. `reporting on`, `off` and `status`,
`send --dry-run`, a send with reporting off, a send while another send holds
the lock, and a send with no valid `problems.json` exit before it. A send that selects no report
also exits before it. A send that stops early, because the post lock is not
free in 60 seconds, reporting turns off, the UTC day or ISO week changes, or
intake answers with a code outside 2xx, 400, 413 and 415, exits before it too.
`docs/integration-contracts.md` says the same in its `sent.jsonl` row.

ADR-0029 says in its Consequences:

> Debugging a crash needs a host drop-in `Storage=external` in
> `/etc/systemd/coredump.conf.d/`.

That sentence does not state which host drop-in wins or how stack text behaves.
In systemd v262, all `coredump.conf.d/*.conf` drop-ins in `/etc`, `/run` and
`/usr/lib` sort by file name. For a single-value option, the file that sorts
last wins. A drop-in in `/etc` with the same name as a file in `/usr/lib`
replaces the image file completely. Drop-ins override the main file
`/etc/systemd/coredump.conf` ([systemd v262 standard configuration](https://github.com/systemd/systemd/blob/v262/man/standard-conf.xml)).

The image file `50-snosi.conf` sets `Storage=none` and `ProcessSizeMax=1G`.
`coredump_submit` makes no stack text for a core larger than
`ProcessSizeMax`. With `Storage=none`,
systemd-coredump reads at most `ProcessSizeMax` of the core. A larger core is
truncated, and its stack text can be incomplete. With `Storage=external`, a
stored core can be as large as `ExternalSizeMax`. A core larger than
`ProcessSizeMax` still gets no stack text while `ProcessSizeMax` remains 1G.
`coredumpctl debug` can still open a stored core
([systemd v262 coredump configuration](https://github.com/systemd/systemd/blob/v262/man/coredump.conf.xml),
[systemd v262 coredump submission](https://github.com/systemd/systemd/blob/v262/src/coredump/coredump-submit.c)).

## Decision

1. **`sent.jsonl` is pruned only at the end of a full send.** The sender
   rewrites `sent.jsonl` with a temporary file and rename only after a send
   posts every report it selected and records each answer. It then keeps only
   JSON lines whose `sent_at` is a string at or after the 90-day cutoff. It
   drops lines that are not JSON, lines without a string `sent_at`, and older
   entries. If `jq` fails, the file stays unchanged. A dry run, a run that
   posts nothing and a run that stops early leave the file unchanged. This
   replaces the ADR-0030 sentence.
2. **A host override of core storage sorts after `50-snosi.conf`.** To keep
   core files, an administrator adds a drop-in in
   `/etc/systemd/coredump.conf.d/` whose name sorts after
   `50-snosi.conf`. For example, `60-keep-cores.conf` contains:

   ```ini
   [Coredump]
   Storage=external
   ```

   A drop-in that sorts before `50-snosi.conf`, or a setting in
   `/etc/systemd/coredump.conf`, loses to the image's `Storage=none`.
   A drop-in named `50-snosi.conf` in `/etc` replaces the image file whole, so
   `ProcessSizeMax` falls back to the systemd default (32G on 64-bit).
   With a drop-in of another name, `ProcessSizeMax=1G` in `50-snosi.conf`
   still limits stack text. To get
   stack text for a process whose core is larger, the same drop-in also sets
   a larger `ProcessSizeMax=`. systemd-coredump then reads and writes up to
   that size. This replaces the ADR-0029 consequence bullet.

## Consequences

- ADR-0029 and ADR-0030 stay Accepted. Their status lines point here, and the
  2 statements are read through this ADR.
- No code changes are made by this ADR.
- After `reporting off`, `sent.jsonl` keeps all of its entries, including
  older entries, until a later full send prunes it.
- While reporting is on and the install time is known, the weekly count is due
  once in each ISO week, so a full send usually happens at least once a week.
- `coredump.finalize` checks only the image files at build time. It does not
  see a drop-in that an administrator adds on a host. A host drop-in is the
  administrator's choice.

## Alternatives considered

- **Edit ADR-0029 and ADR-0030 in place:** rejected by
  `docs/adr/TEMPLATE.md`; accepted ADRs stay unchanged except for their status
  line and successor pointers.
- **Change the sender to prune after every run:** rejected because it changes
  the shipped Floe script to fit a sentence. The file grows only when reports
  are posted, and a full send prunes it.

## References

- Amends: [ADR-0029](0029-snosi-health-records-problems.md),
  [ADR-0030](0030-floe-sends-problem-reports-with-admin-consent.md)
- Shapes: [docs/integration-contracts.md](../integration-contracts.md)
- Sender: [snosi-health-report](../../shared/snosi-report/tree/usr/libexec/snosi-health-report)
- Core settings: [50-snosi.conf](../../shared/bootc-secure/tree/usr/lib/systemd/coredump.conf.d/50-snosi.conf)
- Build guard: [coredump.finalize](../../shared/bootc-secure/finalize/coredump.finalize)
- Test: [snosi-health-report-test.sh](../../test/snosi-health-report-test.sh),
  section 8b
- Systemd v262: [standard-conf.xml](https://github.com/systemd/systemd/blob/v262/man/standard-conf.xml),
  [coredump.conf.xml](https://github.com/systemd/systemd/blob/v262/man/coredump.conf.xml),
  [coredump-submit.c](https://github.com/systemd/systemd/blob/v262/src/coredump/coredump-submit.c)
