# Plan: Prove the bootc update lifecycle on Firn-installed systems

**Status:** Planned — rewritten 2026-11-13. The 2026-07-03 version gated the nbc removal; ADR-0018 removed nbc without it, so its go/no-go list and nbc migration runbook are gone.  
**Last verified:** 2026-11-13

## Goal

Prove that a Firn-installed bootc system takes signed updates through the
shipped updater, keeps `/etc` and `/var` as documented, rolls back, and fails
safe, on all four products: Snow, Snowfield, Floe and Sundog. Fixtures and fresh
installs do not substitute for this proof; see [testing](../design/testing.md),
"Secure-bootc evidence boundary".

## Ownership

- snosi owns this plan, the local QEMU harness `test/bootc-update-test.sh` with
  `test/update-tests/persistence-write.sh` and `persistence-verify.sh`, the
  shipped updater `bootc-update-stage`, and the manifest validator of the
  [lab handoff spec](../specs/bootc-secure-lab-handoff.md).
- frostyard/lab owns the live lane `run-snow-bootc-lifecycle` and its records,
  as the
  [lab lane spec](https://github.com/frostyard/lab/blob/bda60a5f558d9edc8e0cdb030bcea67de813cd9d/docs/specs/bootc-lifecycle-lane.md)
  states.
- The lab lane is advisory: not scheduled and not a release gate, as its spec
  says. This plan never states a lab gate as snosi's.

## Evidence so far

- 2026-07-03, local QEMU harness on published tags: single hop, persistence
  matrix, rollback with `/var` kept, and the stager soak passed (findings log
  below). The stager shipped in
  [#350](https://github.com/frostyard/snosi/pull/350) (2026-07-03), fixed in
  [#369](https://github.com/frostyard/snosi/pull/369).
- The harness is still `unwired` in CI (see [testing](../design/testing.md));
  `.github/workflows/test-update.yml` was never created.
- Lab lane (signed N → N+1 → rollback N, Firn ISO install, Secure Boot, vTPM
  LUKS, the shipped `bootc-update-stage`, and five boots `installed-n`, `stage`,
  `boot-n-plus-1`, `rollback`, `boot-n`), per the pinned lab spec:
  - Snow main lane PASS `run-snow-bootc-lifecycle-tbjnp` (2026-10-26).
  - Snow `rj697` PASS (2026-11-05, bootc 1.17.1 to 1.17.3).
  - Floe main lane PASS `run-snow-bootc-lifecycle-v9bkv` (2026-10-29).
  - Sundog dev run PASS `dev-snow-bootc-lifecycle-rs6sh` (2026-10-30); no
    main-lane Sundog run yet.
  - Snowfield `FAILED: fsverity_errors` on linux-surface (2026-11-04,
    `dev-snow-bootc-lifecycle-v4cgb`,
    [#1130](https://github.com/frostyard/snosi/issues/1130)), after
    [#1214](https://github.com/frostyard/snosi/pull/1214) fixed kernel lockdown.
- Each lab run is 1 hop. No multi-hop, no `/etc` both-changed case and no
  failure injection is recorded anywhere.
- Open defect: [#1130](https://github.com/frostyard/snosi/issues/1130) "bootc:
  fs-verity errors recur during successful updates on both Snow and Floe".
- [testing](../design/testing.md),
  [bootc-secure-operations.md](../bootc-secure-operations.md) and the
  [handoff spec](../specs/bootc-secure-lab-handoff.md) still say update and
  rollback are unproven; Phase 5 below reconciles them.

## Phase 1 — Signed N/N+1 on every product

- [ ] Run the lab lane main path for Sundog.
- [ ] Run it for Snowfield after #1130 is fixed, or after the lab lists its
  kernel as a known defect.
- [ ] Run Floe on the current bootc pair (Snow `rj697` already ran N+1 on
  bootc 1.17.3). Run every product again each time the bootc/libostree pair or
  the systemd family changes (AGENTS.md, "Secure bootc and Forky systemd",
  asks for that revalidation).
- **Done when:** each of the 4 products has a main-lane PASS on a current
  image, or a named open defect issue.

## Phase 2 — Real-tag multi-hop

- [ ] Hop N → N+1 → N+2 on real published immutable version tags: at least 3
  consecutive hops, through the shipped stager, with `persistence-verify.sh`
  at every hop.
- [ ] Watch the `state/deploy/` count, the composefs object store size and ESP
  usage across hops. Unbounded growth is a defect.
- [ ] Run the mutable-tag flow too: `target_ref` follows a moving tag.
- Run it first with the local harness. Asking lab to extend its lane to N+2 is
  a lab issue, not a snosi change.
- **Done when:** 3 consecutive hops pass twice in a row, and deployment and ESP
  growth is bounded and recorded.

## Phase 3 — `/etc` when both sides change

- [ ] Find a file under `/etc` that differs between 2 published tags.
- [ ] Change it locally on N, update, and record which side wins. The old plan
  expected "local wins".
- [ ] Record `/etc` behavior on rollback too: the copies are per-deployment.
- [ ] Add the case to `persistence-verify.sh`.
- [ ] Document the observed semantics in the living design,
  [build-pipeline](../design/build-pipeline.md) or
  [testing](../design/testing.md), whichever the implementer finds holds
  update semantics.
- **Done when:** the semantics are documented and asserted by the harness.

## Phase 4 — Failure injection

Keep the 4 scenarios of the old plan. After each one the old deployment must
boot and `bootc status` must be coherent.

- [ ] Network cut mid-fetch.
- [ ] `/var` disk pressure, about 95 %.
- [ ] Power cut during staging.
- [ ] Power cut at finalize. Repeat it: the result is timing-dependent.
- [ ] Assert that a failed stage writes `error_class=` to
  `/run/snosi/update-check`, as AGENTS.md says it does.
- Signature refusal is not repeated here. The
  [container-policy-scope plan](2026-10-29-container-policy-scope-plan.md)
  covers the stager's refusal of an unsigned image under
  `/usr/lib/snosi/containers/bootc-policy.json` (Phases 1-2, with the
  wrong-key and wrong-identity cases in `test/bootc-container-policy-test.sh`)
  and the boot of an image with no MOK-signed UKI (its Phase 4).
- **Done when:** no scenario leaves the system unbootable or the bootc state
  corrupt, with the results recorded.

## Phase 5 — Record the evidence

- [ ] Update [testing](../design/testing.md) (Secure-bootc evidence boundary),
  [bootc-secure-operations](../bootc-secure-operations.md) and the status of
  the [handoff spec](../specs/bootc-secure-lab-handoff.md) with the lab results
  and the results of Phases 2-4.
- [ ] Update the [ROADMAP.md](../../ROADMAP.md) Near term item, and set this
  plan's status.
- [ ] Decide whether to wire `test/bootc-update-test.sh` into a manual workflow.
- **Done when:** no living doc contradicts the recorded evidence.

## Out of scope

- nbc, the native A/B lanes (ADR-0015, ADR-0018), the go/no-go list and the
  nbc migration runbook.
- Qualification on representative Surface hardware.
- Recovery, key rotation and ESP repair; see
  [bootc-secure-operations.md](../bootc-secure-operations.md).
- Any production support claim.

## Mapping from the 2026-07-03 phases

| Old phase | State | Where it went |
| --- | --- | --- |
| 1 — single hop | done 2026-07-03 (findings 3, 5) | closed |
| 2 — persistence | done, except the both-changed case | new Phase 3 |
| 3 — multi-hop and tag-following | open | new Phase 2 |
| 4 — rollback | done 2026-07-03 (finding 6), and in every lab lane PASS | closed |
| 5 — update automation | shipped ([#350](https://github.com/frostyard/snosi/pull/350), [#369](https://github.com/frostyard/snosi/pull/369); findings 7, 8) | closed |
| 6 — failure injection | open | new Phase 4 |
| 7 — real-hardware soak | hardware out of scope, migration runbook dropped | dropped |

`test/bootc-update-test.sh` refers to old Phases 1-3 in its header.

## Open questions

- Old-deployment GC policy and knobs for the composefs backend.
- Does a multi-hop run belong in the lab lane, or only in the local harness?

## Findings log (2026-07-03, before the rewrite)

Retained history from the original plan. References to nbc and to `yeti/` are
historical.

First runs of `test/bootc-update-test.sh` against real published tags:

1. **Registry-transport pull broken (bootc 1.16.2 AND 1.16.3):** `bootc switch docker://<ref>` fails deterministically on published snosi images with `Failed to pull config … unexpected EOF reading tar entry`. The blob is intact (host fetch OK), `podman pull` of the same tag inside the same guest succeeds, and `bootc switch --transport containers-storage` works. Known upstream issue; NOT fixed by the composefs bump in 1.16.3. **Until fixed upstream, the production update path must be `podman pull` + `bootc switch --transport containers-storage` — the Phase 5 timer must use this mechanism** (harness: `HOP_TRANSPORT=containers-storage`).
2. **`/etc` merge finalize bug (fixed for snosi, reported upstream):** any path removed from live `/etc` that exists as an escaping symlink in the new deployment's `/etc` aborts finalize with "a path led outside of the filesystem" (`metadata_optional` follows symlinks; [bootc#2278](https://github.com/bootc-dev/bootc/issues/2278)). snosi's trigger — `snow-linux-live-setup.service` self-disabling at runtime — removed in PR #347; CLAUDE.md now forbids runtime `systemctl disable/enable` in units.
3. **Full green run achieved** on the first all-fixes image (`20260703174338`, containing #343/#345/#347/#348): install → SSH with no injection → hop to `20260703151145` via containers-storage → finalize on natural shutdown → staged→booted→rollback digests exact → **13/13 persistence checks pass** (incl. SSH host key + machine-id stability, deleted-file persistence) → `is-system-running=running`.
4. **Answered:** `/run/ostree-booted` is **absent** on composefs-booted systems — upstream `bootc-fetch-apply-updates.timer` would never fire; the Phase 5 timer must not copy that condition. Also: bootc records the containers-storage digest (not registry manifest digest) for podman-run installs — never compare `bootc status` digests to `skopeo inspect` for that transport; double-finalize is safe (second run fails loudly on the BLS exchange rather than double-swapping).

Later the same day (post-fix tags `20260703174338` → `20260703184744`):

5. **Ascending hop green** (13/13, digests exact) — Phases 1–2 validated in both directions on production images.
6. **Phase 4 (rollback) green** via the harness's `ROLLBACK=1` phase: previous deployment boots, booted/rollback slots swap exactly, `/var` written on the rolled-back-from deployment persists, persistence matrix passes post-rollback. Two facts for update tooling: **after `bootc rollback`, `spec.image` reverts to the rolled-back-to deployment's ref**, and **bootc refuses to `switch` to an image whose fs-verity digest equals the current rollback deployment** ("Target image has the same fs-verity digest…") — auto-updaters must treat that as a no-op, never flip-flopping back to a version the admin rolled away from.
7. **Phase 5 implemented** (separate PR): `bootc-update-stage.timer/.service` + `/usr/libexec/bootc-update-stage` in base `mkosi.extra` — hourly, stage-only, applies at next natural reboot; podman transfer per finding 1; gated on `ConditionKernelCommandLine=composefs`; no-op guards (non-bootc system, already running/staged, rollback flip-flop) live-tested in a VM and on an nbc host. `bootc-fetch-apply-updates.timer` preset-disabled (force-reboots on update; `systemctl preset-all` had been enabling it despite its dead `/run/ostree-booted` gate).

8. **Phase 5 soak green** (first timer-image `20260703205913`, installed via the moving `:latest` ref): shipped units verified in the deployed image (`bootc-update-stage.timer` enabled+active, `bootc-fetch-apply-updates.timer` preset-disabled), correct "already running" no-op with digest logging, then — after `:latest` moved to `20260703220317` — the service **staged the update unattended** and a natural reboot applied it: booted digest == staged digest, previous deployment in the rollback slot, machine-id and SSH host key stable, `is-system-running=running`. One finding: the pull needs ~image-size headroom in `/var` on top of the previous run's cache (ENOSPC on a 20G soak VM) — fixed by pruning the transfer cache *before* pulling, not only after a successful switch. Remaining Phase 5 item: a calendar-driven soak (timer firing on its own schedule over multiple real publishes) happens implicitly once fleet machines run these images.

Still open for Phase 2 completeness: the "both-changed" `/etc` merge case (needs two tags whose `/etc` genuinely differs).

## References

- [ADR-0018](../adr/0018-remove-native-ab-and-nbc-lanes.md) removed nbc and
  the native A/B lanes;
  [ADR-0015](../adr/0015-retire-native-ab-images-and-nbc-installs.md) ended
  their support and routine publication.
- [testing](../design/testing.md): the gate and the secure-bootc evidence
  boundary; [bootc-secure-operations](../bootc-secure-operations.md): support
  status, recovery and evidence retention.
- [handoff spec](../specs/bootc-secure-lab-handoff.md): the manifest and its
  shape validator.
- [lab lane spec](https://github.com/frostyard/lab/blob/bda60a5f558d9edc8e0cdb030bcea67de813cd9d/docs/specs/bootc-lifecycle-lane.md):
  the live lane and its records.
- [test/bootc-update-test.sh](../../test/bootc-update-test.sh): the local
  harness; [ROADMAP.md](../../ROADMAP.md): the Near term item it serves.
- [native-ab-prototype-history](../native-ab-prototype-history.md): history of
  the removed lanes.
