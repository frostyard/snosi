# bootc Migration Record — 2026-07-03/04

Durable record of the day snosi's bootc path went from "never tested" to a
fully validated install + update pipeline and a working live-installer ISO.
Written as the reference for the nbc retirement; companion plan with the
phase-by-phase criteria: [`plans/2026-07-03-bootc-update-validation-plan.md`](plans/2026-07-03-bootc-update-validation-plan.md).

## Starting point

Goal: retire `nbc` (interim A/B installer/updater) in favor of pure bootc.
Debian support in bootc had matured, but `test-install.yml` had never passed
and no bootc update had ever been attempted on a snosi image.

## Root causes found (in order of discovery)

1. **CI never tested anything.** `test-install.yml` ran the install test
   without sudo; bootc refuses rootless podman (`/proc/1 is owned by 65534`).
   Every historical run failed before touching the image. → **PR #344**.
2. **Installed systems never got SSH host keys.** The image ships an empty
   `/etc/machine-id`; systemd treats *empty* as "initialize an ID, but NOT
   first boot" (only a missing file or `uninitialized` triggers first-boot
   semantics), so Debian's `ConditionFirstBoot`-gated `sshd-keygen.service`
   never ran and sshd crash-looped. → **PR #343**: base-image drop-in that
   regenerates keys whenever they are missing. Rule of thumb recorded in
   CLAUDE.md: run-once units must key on marker paths, never
   `ConditionFirstBoot`; an empty `Condition*=` in a drop-in resets ALL
   conditions, so restate the stock unit's others.
3. **Staged updates never applied.** `bootc composefs-finalize-staged` died
   at every shutdown with `Merging: a path led outside of the filesystem`.
   Chain: `snow-linux-live-setup.service` self-disabled at first boot via
   `ExecStartPost=systemctl disable %n`, deleting its `.wants`/`.requires`
   symlinks from live `/etc`; bootc's /etc merge calls symlink-following
   `metadata_optional()` on those paths in the NEW deployment's `/etc` and
   escapes its cap-std sandbox. → **PR #347** (marker-file pattern instead of
   runtime disable; CLAUDE.md now forbids runtime `systemctl enable/disable`
   in units) + upstream report
   [bootc#2278](https://github.com/bootc-dev/bootc/issues/2278) (the
   `metadata_optional` → lstat fix; still present on upstream main).
4. **Registry-transport composefs pull is broken** in bootc 1.16.2 AND 1.16.3
   (`bootc switch docker://…` → `Failed to pull config … unexpected EOF
   reading tar entry`): blob is intact, podman pulls it fine in the same
   guest, `--transport containers-storage` works. Known upstream issue; the
   1.16.3 composefs bump (**PR #348**) did not fix it. **All update tooling
   uses podman-pull + `bootc switch --transport containers-storage` until
   upstream fixes registry transport.**

## What was validated (all on real published images, QEMU/KVM)

- **Install:** `bootc install to-disk --composefs-backend --filesystem btrfs`
  → boots to `is-system-running=running`, zero failed units. Also validated
  `to-filesystem` onto pre-made partitions (the installer path).
- **Updates:** `test/bootc-update-test.sh` (**PR #349**) — single hops both
  directions between real timestamp tags, staged→booted→rollback digest
  continuity, and a **13/13 persistence matrix**: `/var` data, users/homes,
  podman storage, journal continuity, `/opt` bind, new/modified/deleted
  `/etc` files, hostname, NetworkManager profiles, and the two sentinels —
  **SSH host keys and machine-id stable across every reboot, hop, and
  rollback**.
- **Rollback (`ROLLBACK=1`):** previous deployment boots, slots swap exactly,
  `/var` written on the rolled-back-from deployment persists. Facts for
  tooling: after `bootc rollback`, `spec.image` reverts to the rolled-back-to
  ref; bootc refuses `switch` to an image matching the rollback deployment's
  fs-verity digest — updaters must treat that as a no-op (no flip-flop).
- **Automated updates (PR #350):** `bootc-update-stage.timer` (hourly,
  stage-only, applies at next natural reboot — nbc parity). Soak-validated:
  the shipped timer staged a real published update unattended and a natural
  reboot applied it. `bootc-fetch-apply-updates.timer` is preset-disabled
  (it force-reboots and `preset-all` was enabling it; its
  `/run/ostree-booted` gate — confirmed absent on composefs — is the only
  thing keeping it inert). **PR #351**: prune the podman transfer cache
  before pulling (soak found ENOSPC; `/var` needs ~2× image-size headroom).
- **Digest semantics:** containers-storage installs record the storage
  (config) digest, not the registry manifest digest — never compare
  `bootc status` digests against `skopeo inspect` for that transport.
- **composefs on-disk layout** (root partition): writable `/etc` is
  per-deployment at `state/deploy/<verity>/etc`; `/var` is shared at
  `state/os/default/var`; BLS entries carry `composefs=<verity>` matching the
  deploy dir; persistent journal readable offline via
  `journalctl -D state/os/default/var/log/journal`; `bootc config-diff`
  prints the /etc diff (invaluable for debugging merges).

## Installer + live ISO (frostyard forks)

Replaced the nbc/first-setup install flow with Universal Blue's
`bootc-installer` (GTK4 + Go backend `fisherman`, lineage: Vanilla OS →
tuna-os → projectbluefin). Its systemd-boot/composefs path installed snow
**unmodified** (verified before any changes). Forks: `frostyard/bootc-installer`
and `frostyard/fisherman` (backend is a git submodule — `git submodule
update --init`).

- **frostyard/fisherman#1:** cosign signature verification — new recipe field
  `cosignPubKey`; resolves tag → digest, verifies the immutable digest ref,
  pins the install to it; fail-closed; local sources skip. **Media must ship
  cosign v2.6.x** (v3 fails key verification on images with GitHub
  attestations — verified). Also Snow Loaded/Snowfield catalog entries.
- **frostyard/bootc-installer#1:** Snow recipe.json (`selinuxDisabled: true`
  for AppArmor images, cosign key path), Debian groups (`wheel`→`sudo`,
  dropped `libvirt` — not in snow; `useradd` fails on unknown groups),
  `cosignPubKey` pass-through.
- **frostyard/fisherman#2:** composefs pulls now land in the scratch-rooted
  store (target disk on live media) with the transfer store dropped after
  OCI export — fixes guaranteed ENOSPC on live media (see below).

**ISO builder: `frostyard/titanoboa`** branch `feat/bootc-installer-live`:
post-rootfs hook installs the installer Flatpak (upstream bundle + GNOME
runtime), stages `/etc/bootc-installer/{recipe.json,images.json,cosign.pub,
live-iso-mode}`, autostart + polkit for the `snow` live user, and swaps the
patched frostyard fisherman into the Flatpak. Build:
`HOOK_post_rootfs=.github/workflows/bootc-installer_postrootfs.sh just build
ghcr.io/frostyard/snow:latest` → 3.5G ISO.

Three debugging lessons from getting the ISO working:

1. **Flatpak sandboxes always get a private `/var`, even with
   `--filesystem=host`.** Snow homes live at `/var/home`, so everything the
   installer "staged into `$HOME`" was invisible to the host-side pkexec
   launch (instant failure at "Become Legend"). Live-media fix: mask
   `home.mount` + `useradd HOME=/home`. Durable fork fix (TODO): stage via
   `flatpak-spawn --host` writes.
2. **fisherman's composefs pull went to default podman storage** — the live
   RAM overlay, which cannot hold snow's ~10G of extracted layers (ENOSPC at
   layer 128/128 at 8G and 16G RAM alike). Fixed in frostyard/fisherman#2.
3. **just 1.55 compat** in titanoboa's Justfile (`set lists := true`;
   `which()` replaced by env-with-default for `PODMAN`).

**Result: full pipeline verified in QEMU** — ISO boot → GNOME live session →
GUI installer → cosign-capable backend → composefs install to disk →
systemd-boot → installed Snow with first-boot user creation and flatpak
seeding. Online installs need a ~30G+ target disk (pull + OCI cache + deploy
all share it) until images are embedded in the ISO.

## Constraints that shape the nbc retirement

- **nbc-installed hosts cannot adopt bootc in place** (`bootc status` →
  `spec.image: null`; different partition layout). Fleet migration =
  reinstall via the new ISO. Runbook still to be written (plan Phase 7).
- **Update-hop eligibility floor:** only images built from commits containing
  `8e5da3a` (in-tree bootc/ostree) participate in update testing.
- **Registry `bootc upgrade` stays blocked** on the upstream pull bug; the
  shipped timer's podman transfer sidesteps it (and enforces
  `containers-policy.json` at pull time — the hook for signature enforcement
  on updates).

## PR ledger (2026-07-03/04)

| Repo | PR | What |
|---|---|---|
| snosi | #342 | Justfile bootstraps mkosi at the CI-pinned commit (no local/CI drift) |
| snosi | #343 | SSH host key generation drop-in (first-boot semantics fix) |
| snosi | #344 | test-install.yml runs as root |
| snosi | #345 | virtiofsd in base image (bcvk support) |
| snosi | #346 | bootc update validation plan |
| snosi | #347 | live-setup marker file instead of runtime systemctl disable |
| snosi | #348 | bootc 1.16.2 → 1.16.3 |
| snosi | #349 | update-sequence test harness + persistence matrix + rollback |
| snosi | #350 | bootc-update-stage timer (nbc-parity staging) |
| snosi | #351 | prune transfer cache before pull |
| bootc-dev/bootc | [#2278](https://github.com/bootc-dev/bootc/issues/2278) | /etc merge follows symlinks out of its sandbox (filed upstream) |
| frostyard/fisherman | #1 | cosign verification + digest pinning; Snow catalog |
| frostyard/fisherman | #2 | composefs pull into scratch-rooted storage |
| frostyard/bootc-installer | #1 | Snow recipe, Debian groups, cosign pass-through |
| frostyard/titanoboa | branch `feat/bootc-installer-live` | bootc-installer live media (replaces nbc hook) |

## Remaining work

- Plan Phases 3/6/7: ≥3-hop chains and the `:latest`/`bootc upgrade` flow
  (blocked upstream), failure injection, real-hardware soak, migration
  runbook.
- Installer: fork Flatpak CI build (stop binary-swapping fisherman on media),
  offline image embedding in the ISO, upstream the `/var`-home staging fix
  and composefs pull fix to projectbluefin, app-id rebrand.
- nbc removal PR once the plan's go/no-go criteria are met (contents listed
  in the plan).
