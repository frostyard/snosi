# bootc Update Validation Plan

**Goal:** Prove that a sequence of bootc updates works on snosi images — including correct persistence of `/etc` and `/var` — with enough confidence to retire `nbc` (the interim A/B root installer/updater) and rely on bootc alone.

**Status:** Plan. Prereqs in flight: #343 (SSH host key generation — the SSH-based harness depends on it), #344 (CI runs the install test as root), #345 (virtiofsd in base, enables bcvk-based harness).

## What is already proven (2026-07-03)

Verified end-to-end on a snowloaded workstation (QEMU/KVM, published image):

- `bootc install to-disk --generic-image --via-loopback --composefs-backend --filesystem btrfs` of `ghcr.io/frostyard/snow:latest` succeeds (in-image bootc 1.16.2).
- The installed disk boots to `systemctl is-system-running` = `running` with zero failed units once SSH host keys exist (#343). Verity-backed composefs root, systemd-boot, BLS entries, healthy `bootc status`.
- composefs-backend on-disk layout (partition 3): writable `/etc` is a **per-deployment copy** at `state/deploy/<verity-digest>/etc`; writable `/var` is **shared across deployments** at `state/os/default/var` (`/root` → `/var/roothome`). `state/os/default/etc` does not exist.
- Offline post-mortem works: mount p3 and read the persistent journal via `journalctl -D state/os/default/var/log/journal`.

What has **never** been tested: any update. Everything below exists to close that gap.

## Facts that shape the tests

1. **Real published versions are available for hops.** ghcr.io keeps timestamp tags (e.g. `20260702011235` … `20260703151145`, several per day). Update sequences can use real, signed, published images — no synthetic image building needed.
   **Eligibility floor:** every image in a hop chain — especially the install tag A — must be built from a commit containing `8e5da3af9c1e6a4a935b0538777883d53bd318f4` ("compile bootc + ostree from source in the base image", merged 2026-06-29). Older images have no working/current in-image bootc, so neither installing them nor hopping from them is meaningful. To check a tag: read its source commit from the `org.opencontainers.image.url` label (`skopeo inspect --format '{{index .Labels "org.opencontainers.image.url"}}'`) and confirm `git merge-base --is-ancestor 8e5da3a <commit>`. As of 2026-07-03 every retained timestamp tag qualifies (oldest: `20260702011235`, source `f014f96e`), but the harness should assert this per tag rather than assume registry retention keeps it true.
2. **`bootc upgrade` follows the installed tag.** Timestamp tags never move, so the harness drives hops with `bootc switch <next-tag>` (identical staging/finalize/reboot machinery). The production flow (`:latest` + `bootc upgrade`) is exercised separately in Phase 3.
3. **bootc ships update automation, but its gate is suspect.** The image contains `bootc-fetch-apply-updates.timer/.service` (fetch + apply + **immediate reboot**) gated on `ConditionPathExists=/run/ostree-booted`. Whether the composefs backend creates `/run/ostree-booted` is unverified (`bootc status` reports `ostree: null`). nbc's semantics are download-only + apply at next natural reboot — a custom timer is probably needed for parity (Phase 5).
4. **nbc-installed hosts cannot adopt bootc in place.** On an nbc-installed snowloaded machine, `bootc status` reports `spec.image: null` — nbc's A/B partition layout is not a bootc deployment. Fleet migration means fresh `bootc install` per machine (Phase 7 runbook).
5. **Install-time flags to revisit for production:** the harness installs with `--skip-fetch-check`; update pulls should eventually enforce signature policy (see Open Questions).

## Test infrastructure

New orchestrator `test/bootc-update-test.sh`, reusing `test/lib/vm.sh` and `test/lib/ssh.sh`:

```
Usage: test/bootc-update-test.sh <install-ref> <hop-ref> [<hop-ref>...]
```

- Install `<install-ref>` to a raw disk (existing `install_to_disk`), boot, wait for SSH.
- Write persistence markers (Phase 2 script), record baseline (digests, fingerprints, machine-id).
- For each hop: `bootc switch <hop-ref>` in-VM → verify staged → reboot (keep the same disk; `vm_stop` without `vm_cleanup`) → wait for SSH → run verify script + existing test tiers.
- Needs `DISK_SIZE=20G` (multiple deployments + podman marker image) and a work dir on real disk, not tmpfs.

Runs locally (any KVM host — the workstation used for the install verification qualifies) and in CI as `.github/workflows/test-update.yml` (workflow_dispatch with `install_tag` / `hop_tags` inputs; same runner prereqs as `test-install.yml`, all podman/script steps under sudo). Once #345 ships, a bcvk-based variant (`bcvk to-disk` + `bcvk ephemeral`) can replace the hand-rolled VM plumbing, but the plan does not depend on it.

## Phase 1 — Single-hop update

Install the oldest **eligible** timestamp tag A (post-`8e5da3a`; see eligibility floor above), then `bootc switch` to tag B:

- After switch, `bootc status`: `status.staged.image.imageDigest` matches B's digest (resolve via `skopeo inspect` on the host for an independent value).
- After reboot: `status.booted` == B, `status.rollback` == A.
- `systemctl is-system-running` == `running`; `systemctl --failed` empty.
- Existing tiers 1–4 pass on the updated system.

Exit criterion: green run, twice in a row (flake check).

## Phase 2 — Persistence matrix

Marker scripts `test/tests/90-persistence-write.sh` (run once on the freshly installed system) and `91-persistence-verify.sh` (run after every subsequent boot/hop) so every hop re-asserts the whole matrix.

`/var` — expectation: **always persists** (single shared `state/os/default/var`):

| Marker | Assert after each hop |
|---|---|
| `/var/persist-test/data.txt` with known content | content + mtime unchanged |
| `useradd -m testuser` (home on `/var/home`) + file in home | user resolves, uid stable, file intact |
| `podman pull` a small image as root | image still in `/var/lib/containers` storage |
| journal boots | `journalctl --list-boots` grows by exactly 1 per reboot; pre-update boot logs still readable |
| `/opt` (bind to `/var/opt`): drop a file | file visible at both paths |

`/etc` — expectation: local changes carry into each new deployment's per-deployment copy. This is the highest-risk area; classify each case empirically and document the observed semantics in `yeti/`:

| Case | Marker | Expected |
|---|---|---|
| New local file | `/etc/persist-test.conf` | survives |
| Locally modified, unchanged in new image | append marker line to `/etc/motd` | survives with modification |
| Locally modified, **also changed in new image** | pick a file that actually differs between tags A and C (find one by diffing the two images' `/etc` with `podman run`; if none, note as untestable-with-real-tags) | **document observed winner** (ostree semantics: local wins) |
| Locally deleted image file | `rm` a shipped conf file | stays deleted |
| Identity | `hostnamectl set-hostname persist-test-vm` | hostname survives |
| Network config | NM keyfile in `/etc/NetworkManager/system-connections/` | profile survives |
| **SSH host keys** | record fingerprints on first boot | identical after every hop (also proves the #343 drop-in does not refire; SSH client reconnects with no host-key warning) |
| **machine-id** | record on first boot | identical after every reboot and hop (guards the empty-machine-id/transient-id class of bugs) |

## Phase 3 — Multi-hop sequence and tag-following

- Chain A → B → C (real eligible tags, oldest→newest), full Phase 2 verify at each hop.
- Deployment lifecycle: confirm old deployments are pruned/bounded (watch `state/deploy/` count, composefs object store size, ESP usage across hops — an unbounded ESP or object store is a NO-GO finding).
- Production flow: `bootc switch ghcr.io/frostyard/snow:latest`, then after the next real image publish, `bootc upgrade --check` followed by `bootc upgrade` — verifies the mutable-tag flow users will actually run.

## Phase 4 — Rollback

- After an A→B hop: `bootc rollback` → reboot → `status.booted` == A, `status.rollback` == B.
- `/var` markers written **while on B** persist after rollback (var is shared — users don't lose data on rollback).
- `/etc` on rollback: per-deployment copies mean changes made on B may be absent on A. Document observed behavior; define the user-facing expectation before nbc removal.
- Roll forward again (`bootc switch` B) → healthy. SSH host keys and machine-id stable throughout.

## Phase 5 — Update automation (nbc parity)

nbc today: `nbc-update-download.timer` → `nbc update --download-only`; the update applies at the next natural reboot. Candidate bootc replacements:

1. **Preferred:** custom `bootc-update-stage.timer/.service` running `bootc upgrade --quiet` — stages the update, applies on next reboot. Closest to nbc's desktop-friendly semantics. Ships in base `mkosi.extra` + preset, replacing the nbc units.
2. Upstream `bootc-fetch-apply-updates.timer` (`bootc update --apply` = fetch + reboot immediately): acceptable for cayo servers at most; too aggressive for desktops.

Validation items:

- Empirically check `/run/ostree-booted` on a composefs-booted VM. If absent, upstream-gated units never fire — our custom unit must not copy that condition (and consider filing a bootc upstream issue).
- Timer fires in VM soak (shorten `OnUnitInactiveSec` for test) → staged update appears unattended → natural reboot applies it → Phase 2 verify passes.
- `bootc-finalize-staged.service`: reboot while a staged update exists finalizes cleanly (this is the normal apply path — exercise it explicitly, not just `bootc switch` + immediate reboot).
- Confirm sysext updates (systemd-sysupdate, separate mechanism under `/var/lib/extensions`) still merge and function after a base-image hop.

## Phase 6 — Failure injection

All on the VM harness; after every scenario the system must boot the old version cleanly and `bootc status` must be coherent:

- **Network cut mid-fetch:** start `bootc switch`, drop the QEMU link (`set_link`) mid-pull → command errors cleanly, no staged garbage, retry after reconnect succeeds.
- **Disk pressure:** fill `/var` to ~95% (`fallocate`) → `bootc switch` fails with a clear error, no partial deployment, old system unaffected; after freeing space, retry succeeds.
- **Power cut during staging:** `kill -9` QEMU mid-switch → reboot → old version boots, re-run switch succeeds.
- **Power cut at finalize:** kill QEMU immediately after issuing `reboot` with a staged deployment (repeat several times; timing-dependent) → boots either old or new cleanly, never unbootable.

## Phase 7 — Real-hardware soak and fleet migration rehearsal

- Fresh `bootc install` of snow/snowloaded on one physical machine (spare/lab machine first — **not** the daily driver). Enable the Phase 5 timer. Live on it for ≥2 weeks spanning ≥2 real image publishes; keep notes on every update.
- One hop on Surface hardware (snowfield) to cover the kernel/dracut variant.
- Write the **migration runbook** for nbc-installed hosts (in-place adoption is impossible — `spec.image: null`, incompatible partition layout): capture `/etc` deltas and `/var` data, fresh `bootc install`, restore. Rehearse it once on the lab machine.

## Go/no-go criteria for nbc removal

GO when all of:

1. Three consecutive real-tag hops with a fully green persistence matrix (Phases 1–3).
2. Rollback verified including `/var` retention (Phase 4).
3. The chosen update timer staged and applied ≥2 updates unattended in VM soak (Phase 5).
4. No failure-injection scenario leaves the system unbootable or bootc state corrupted (Phase 6).
5. ≥2 weeks real-hardware soak including ≥2 real published updates (Phase 7).
6. Migration runbook for the nbc-installed fleet written and rehearsed once.

Then the removal PR: drop `frostyard-nbc` from base `Packages=` (`mkosi.images/base/mkosi.conf`), remove `nbc-update-download.service/.timer` from base/snow/cayo trees, replace the tier-2 assertion (`test/tests/02-services.sh` — nbc timer loaded) with the bootc timer assertion, update CLAUDE.md/README/yeti.

## Deliverables

- `test/bootc-update-test.sh` (+ `tests/90-persistence-write.sh`, `tests/91-persistence-verify.sh`)
- `.github/workflows/test-update.yml` (workflow_dispatch; install tag + hop tags as inputs)
- Documented `/etc` merge + rollback semantics in `yeti/`
- Phase 5 timer units (new PR) and, at GO, the nbc-removal PR
- Migration runbook for nbc-installed machines

## Open questions

- `/etc` both-changed merge semantics under the composefs backend (Phase 2 answers empirically).
- `/run/ostree-booted` presence on composefs-booted systems (Phase 5; possible upstream issue/drop-in).
- Old-deployment GC policy and knobs for the composefs backend (Phase 3).
- Signature enforcement on update pulls: installs currently use `--skip-fetch-check`; decide a containers-policy.json / sigstore policy so `bootc upgrade` verifies the same cosign signatures CI produces, and add a Phase 5 test that an unsigned/tampered image is rejected.
