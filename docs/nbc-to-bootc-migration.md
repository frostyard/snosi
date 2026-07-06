# nbc → bootc Migration Runbook

Operator runbook for migrating hosts installed with **nbc** (the legacy A/B
partition installer/updater) to **bootc/composefs** deployments.

Companion documents:

- [`2026-07-03-bootc-migration-record.md`](2026-07-03-bootc-migration-record.md) —
  the validation record this runbook is built on (root causes, what was
  tested, PR ledger). Read it once before your first migration.
- [`plans/2026-07-03-bootc-update-validation-plan.md`](plans/2026-07-03-bootc-update-validation-plan.md) —
  phase-by-phase go/no-go criteria for retiring nbc fleet-wide.

> **Status:** the bootc install and single-hop update paths are validated in
> QEMU/KVM on real published images (see the migration record). The items in
> [Remaining validation](#remaining-validation-before-fleet-wide-migration)
> are still open — migrate pilot machines first, not the whole fleet.

---

## 1. Identify what you have (inventory)

Per host, determine the install type. The mechanisms are mutually exclusive
and each auto-updater no-ops on the other's install type, so a mixed fleet is
safe during the transition.

| Check | nbc host | bootc host |
|---|---|---|
| `bootc status --format json \| jq .spec.image` | `null` | the followed image ref |
| `systemctl is-enabled nbc-update-download.timer` | active/enabled (in use) | present but inert |
| `systemctl list-timers bootc-update-stage.timer` | present but no-ops | active, staging updates |
| Partition layout | A/B root partitions | single root; composefs `state/deploy/<verity>/` dirs |

The authoritative test is the first row: `spec.image: null` means
**not bootc-managed** — this is exactly the guard
`/usr/libexec/bootc-update-stage` uses to no-op on nbc hosts.

Record per host: hostname, image variant (snow/snowloaded/snowfield/…,
`/etc/os-release`), disk size, whether it uses tailscale, himmelblau/Entra,
podman workloads, and any sysexts enabled via systemd-sysupdate.

## 2. Migration approach: reinstall, not conversion

**nbc hosts cannot be converted to bootc in place.** This is documented in
the migration record ("Constraints that shape the nbc retirement") and the
validation plan: an nbc install is an A/B partition layout with no bootc
deployment state (`spec.image: null`); there is no adoption path. The
migration is a **fresh `bootc install` via the live installer ISO, followed
by state restore**.

Installer media: the bootc-installer live ISO (frostyard forks of
`bootc-installer`/`fisherman`; ISO built from `frostyard/titanoboa`, branch
`feat/bootc-installer-live` — see the migration record for build
instructions). The installer verifies the image with cosign and pins the
install to the resolved digest.

### Disk sizing preconditions

- **Install:** online installs need a **~30G+ target disk** — image pull,
  OCI cache, and the deployment all share the target until images are
  embedded in the ISO.
- **Steady state:** `/var` needs **~2× image-size headroom** for updates:
  the hourly updater pulls via podman into `/var/lib/containers` before
  `bootc switch` copies it into the composefs repo. The updater prunes the
  transfer cache *before* each pull (PR #351), but the headroom must exist.

## 3. Back up host state (before wiping)

The reinstall destroys everything on the target disk. Capture, per host, to
external storage (not the target disk):

| What | Where | Notes |
|---|---|---|
| `/etc` deltas | diff against the image's `/usr/etc` (or just archive `/etc`) | On the new system, only *restore the delta* (hostname, NetworkManager profiles, custom configs). Do not blanket-copy old `/etc` over a bootc deployment — its `/etc` is a merged overlay that bootc reconciles on every update. |
| Machine identity (optional) | `/etc/ssh/ssh_host_*`, `/etc/machine-id` | Only if you need SSH host key / machine-id continuity. Otherwise let first boot regenerate (the base image regenerates missing SSH host keys — see the `sshd-keygen.service.d` drop-in). |
| `/var` data | `/var/home` (user homes), app state dirs your workloads use | `/home` is a bind to `/var/home`. |
| podman | named volumes (`podman volume export`), image list, quadlet/systemd units | Container *storage* is re-pullable; volumes are not. |
| tailscale | `/var/lib/tailscale` | Restoring it preserves the node identity; otherwise plan to re-`tailscale up` and re-authorize. |
| himmelblau / Entra | `/var/lib/himmelblau` (+ `/etc/himmelblau` if customized) | If not restored, plan an Entra re-join and cached-credential re-enrollment. |
| Enabled sysexts | `ls /etc/sysupdate.*` drop-ins / feature enablement state | Sysext features default `Enabled=false`; note which were opted in so you can re-enable. |
| Package/host quirks | `packagediff.sh` output, crontabs, non-default timers | Anything hand-installed outside the image won't survive; it must move into an image/sysext or be re-applied. |

Verify the backup is readable from another machine **before** proceeding.

## 4. Reinstall via the bootc installer ISO

1. Boot the live ISO, run the installer, select the matching image variant
   (keep snow → snow, snowloaded → snowloaded, etc. so installed package
   expectations match).
2. Let the installer complete (cosign-verified, digest-pinned install to
   disk) and reboot into the installed system.
3. Complete first-boot setup (user creation).

## 5. Restore and re-enroll

1. Restore `/var` payloads: homes into `/var/home`, podman volumes, app
   state. Keep ownership/UIDs consistent with the users created at install.
2. Apply the `/etc` **delta** only: hostname
   (`hostnamectl set-hostname …`), NetworkManager connections, and any
   custom config files. Prefer `nmcli`/`hostnamectl`/drop-ins over copying
   whole directories.
3. Re-enroll network/identity services: restore `/var/lib/tailscale` (or
   `tailscale up` fresh), restore/rejoin himmelblau.
4. Re-enable the sysext features the host used (systemd-sysupdate feature
   enablement + `systemd-sysupdate update` / reboot to merge), then confirm
   with `systemd-sysext status`.
5. Recreate podman workloads from volumes + unit files; `podman pull` images
   as needed.

## 6. Post-migration verification

Run all of these before calling the host migrated:

```bash
# bootc-managed, correct image, no surprises
bootc status                       # spec.image = the followed ref (NOT null);
                                   # booted deployment matches the intended variant

# system health
systemctl is-system-running        # expect: running
systemctl --failed                 # expect: 0 units

# auto-update path is live
systemctl list-timers bootc-update-stage.timer   # timer active, next run scheduled
journalctl -u bootc-update-stage.service         # after first run: pulled/"nothing to stage"

# updates apply on natural reboot (after the first real update lands)
bootc status                       # staged deployment appears after staging;
                                   # becomes booted after the next reboot
```

Digest caveat for any tooling/spot-checks: containers-storage installs record
the **storage (config) digest**, not the registry manifest digest — never
compare `bootc status` digests against `skopeo inspect`.

Also verify workloads: user login + home contents, tailscale connectivity,
Entra sign-in (if applicable), podman services, expected sysexts merged.

## 7. How updates behave after migration

- `bootc-update-stage.timer` runs **hourly**: podman pulls the followed
  image, then `bootc switch --transport containers-storage` stages it. The
  update **applies at the next natural reboot** (no forced reboot — nbc
  download-only parity).
- podman does the transfer because bootc's **registry-transport composefs
  pull is broken upstream on snosi images** (known bug; `bootc upgrade`
  against the registry stays blocked until it's fixed). Side benefit: podman
  enforces `containers-policy.json` at pull time.
- The updater no-ops when the pulled digest is already booted or staged, and
  **never re-stages a digest equal to the rollback deployment** — after an
  admin `bootc rollback`, it will not flip-flop back to the rolled-away-from
  version (bootc refuses that switch anyway).

## 8. Rollback and abort guidance

**Before wiping (abort):** nothing on the host has changed until the
installer writes the disk — power off and the nbc host is untouched. Keep
the backup regardless.

**Installer failed mid-write:** the disk is in an undefined state but the
backup plus ISO make the procedure repeatable — rerun the install. There is
no path back to the previous nbc system on that disk once the installer has
started writing; if a host cannot tolerate that window, image the disk
beforehand or migrate on a replacement disk and keep the nbc disk as the
physical rollback.

**After migration (OS-level rollback):** `bootc rollback` swaps to the
previous deployment and applies at reboot. Facts to rely on (validated in
the update-test matrix):

- `/var` (homes, podman, journal) is **shared across deployments** — data
  written after an update persists through a rollback.
- After `bootc rollback`, `spec.image` reverts to the rolled-back-to ref and
  the auto-updater will not re-stage the rolled-away-from digest.
- To move forward again deliberately: `bootc switch` to the desired
  ref/digest (or wait for the *next* published image, which the updater will
  stage normally).

**Backing out of the migration entirely:** reinstall nbc media and restore
from the same backup set. Treat this as a last resort — it re-enters the
system being retired.

## Remaining validation before fleet-wide migration

Open items (validation plan Phases 3/6/7) — until these close, migrate in
pilot waves and keep backups longer:

- **Multi-hop upgrade chains (≥3 hops)** — only single hops are validated.
- **`bootc upgrade` / `:latest` registry flow** — blocked on the upstream
  registry-transport pull bug; podman transfer is the workaround.
- **Failure injection** (power loss during stage/finalize, disk-full paths).
- **Real-hardware soak** (≥2 weeks, ≥2 real published updates) — validation
  to date is QEMU/KVM.
- This runbook rehearsed once end-to-end on the lab machine (plan Phase 7).
