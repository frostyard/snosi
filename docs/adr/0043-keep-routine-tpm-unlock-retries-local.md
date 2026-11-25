# 0043 — Keep routine TPM unlock retries local

- **Status:** Accepted
- **Date:** 2026-11-25

## Context

[ADR-0029](0029-snosi-health-records-problems.md) records a `tpm_unlock`
problem whenever systemd-cryptsetup retries or falls back, and a record is
reportable when its envelope validates. Floe's sender
([ADR-0030](0030-floe-sends-problem-reports-with-admin-consent.md)) posts
reportable records.

[#1358](https://github.com/frostyard/snosi/issues/1358) measured what those
retries are on a real Secure Boot host (Snow, trixie stream):

- 54 boots in the persistent journal retried the root unseal with
  `TPM_RC_PCR_CHANGED` (ESYS `0x00000128`), 84 retries in all: 1 retry on
  30 boots, 2 on 19, 3 on 4, 4 on 1. 16 of the last 20 boots retried. Every
  boot unlocked; none came near systemd's limit (`RETRY_UNSEAL_MAX`, 30) or
  fell back to the passphrase.
- In a retrying boot no systemd PCR extend lands between the token lookup
  and the activation, and the initrd has no other userspace PCR writer. The
  changes come from the kernel: under Secure Boot the IMA arch policy
  measures each module's first load into PCR 10 while udev loads modules.
  `TPM_RC_PCR_CHANGED` follows the TPM's global PCR update counter, so a
  PCR outside the signed PCR 11 policy restarts the session too; systemd's
  `tpm2_unseal()` names IMA as the usual suspect and retries by design.
- Each unseal attempt takes about 1 s on that hardware TPM, which is why the
  swtpm lab VMs never retried.

No unit order can hold off a kernel measurement. So under ADR-0029 a healthy
Secure Boot host files `tpm_unlock` reports for most of its boots; that host
already held 3 reportable records, seen 19 times.

## Decision

snosi-health keeps recording every `tpm_unlock` as before, but a record with
`outcome` `ok_after_retry`, `tpm_rc` `PCR_CHANGED` and fewer than 10
`retries` is **not reportable**. It stays in `problems.json`,
`details.json` and `snosi-health --list` (`reportable: no`).

A `tpm_unlock` record stays reportable when it validates and:

- `retries` is 10, the collector's cap: the unlock needed a third of
  systemd's budget and added seconds to the boot; or
- `outcome` is not `ok_after_retry`: the unlock fell back to the passphrase
  or recovery key, including exhausted PCR retries; or
- `tpm_rc` is not `PCR_CHANGED`.

The rule is `local_only` in the collector's jq library, with the threshold
`tpm_report_retries` (10). Every run re-sanitizes the previous file, so
records written before an update lose `reportable` on the first run after it.

## Consequences

- Healthy Secure Boot hosts stop filing reports for systemd's designed retry.
  A host that drifts toward exhaustion still reports from 10 retries on, and
  every fallback still reports.
- The project no longer sees how common 1–9 retries are across hosts. The
  local record keeps the count on each host, and a recovery-key or passphrase
  fallback is still reported.
- `reportable` is no longer only "the envelope validates":
  `test/snosi-health-test.sh` checks that it is the envelope rule minus the
  local-only rule, at 1, 9, 10 and the cap, and for a fallback.
- #1358's original goal, boots with no `PCR_CHANGED` retry, cannot be met
  on real Secure Boot hardware without changing the measurement policy; this
  ADR replaces it.

## Alternatives considered

- **Order the PCR 11 phase extends before cryptsetup** (`Wants=cryptsetup-pre.target`
  for `systemd-pcrphase-initrd` and `systemd-pcrnvdone`): no systemd extend
  lands in the unseal on the measured host, so it changes nothing.
- **Stop measuring modules into PCR 10:** weakens the Secure Boot measurement
  chain to silence a designed retry.
- **Wait for udev to settle before the unseal:** slows every boot and still
  misses a module that loads later.
- **Never report an `ok_after_retry` record:** hides a host that keeps
  climbing toward systemd's limit until it falls back.
- **Keep reporting every retry:** files reports for healthy hosts on most
  boots.

## References

- Amends: [ADR-0029](0029-snosi-health-records-problems.md) (the `reportable` rule)
- Builds on: [ADR-0030](0030-floe-sends-problem-reports-with-admin-consent.md)
- Evidence: [#1358](https://github.com/frostyard/snosi/issues/1358)
- Shapes: [integration-contracts](../integration-contracts.md),
  [bootc secure operations](../bootc-secure-operations.md)
