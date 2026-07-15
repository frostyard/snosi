# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

snosi is a bootable container image build system using [mkosi](https://github.com/systemd/mkosi) to produce Debian Trixie-based immutable OS images and system extensions (sysexts). Images are deployed via bootc/systemd-boot with atomic updates.

**Outputs:** 2 OCI desktop images (snow, snowfield), 1 OCI server image (cayo), and 17 sysext overlay images (1password, 1password-cli, azurevpn, bitwarden, claude-desktop, code-server, coder, debdev, dev, docker, edge, incus, lemonade, nix, podman, tailscale, vscode).

## Build Commands

Requires: just, git, python3, root/sudo access. mkosi itself is auto-bootstrapped: the Justfile fetches systemd/mkosi into a repo-local, gitignored `.mkosi/` checkout at the exact commit pinned by the `systemd/mkosi@<sha>` action in `.github/workflows/build.yml` (read at runtime — no drift between local and CI), and runs `.mkosi/bin/mkosi` from there. Delete `.mkosi/` to discard it; override with `just mkosi=/usr/bin/mkosi <target>` to use a system install.

```bash
just                    # List targets
just sysexts            # Build base + all 17 sysexts
just snow               # Build snow desktop image
just snowfield          # Build snowfield (Surface kernel)
just cayo               # Build cayo server image
just clean              # Remove build artifacts
just test-install       # Run bootc install test
just run-qemu           # Run image in QEMU
```

All `just` targets run `mkosi clean` first (clean build every time).

## Architecture

### Configuration Composition

mkosi configs use `Include=` directives to compose reusable fragments. The composition chain:

- `mkosi.conf` (root) declares base + sysext dependencies
- `mkosi.images/` contains base image and sysext definitions
- `mkosi.profiles/` defines transport+kernel selector variants (snow, snowfield, cayo — the app-bundling "loaded" variants were retired 2026-07 in favor of sysexts; cayo-ab-raw is the permanent, never-published native A/B dev fixture, and cayo-ab/snow-ab/snowfield-ab are the production native A/B profiles, see below)
- `shared/` contains reusable fragments: kernel configs, package sets, output format, scripts, and `shared/composition/` (per-product payload fragments, see below)

Each profile composes: package sets + kernel variant + output format + build/postinstall/finalize/postoutput scripts.

**Payload composition (`shared/composition/`):** `shared/composition/cayo/mkosi.conf` and `shared/composition/snow/mkosi.conf` are the single per-product definitions of ExtraTrees, PostInstallationScripts (dracut postinst, then the product postinst.chroot), BuildScripts (brew, plus snow's hotedge/logomenu/bazaar/surface-cert), the manifest PostOutputScript, the image FinalizeScript, and an `[Include]` of the product's package set. Every profile that ships that product's payload — bootc (`cayo`/`snow`/`snowfield`) and native (`cayo-ab-raw`, `cayo-ab`, `snow-ab`, `snowfield-ab`) alike — `Include=`s the fragment instead of restating it, so the two transports cannot drift apart. Profiles themselves reduce to transport+kernel selectors: bootc profiles add `Include=shared/packages/bootc/mkosi.conf` (before the composition include, so `Packages=` accumulates in the same order as before the refactor) and `Include=shared/outformat/image/mkosi.conf`; native profiles never include the bootc packages fragment and instead include `shared/outformat/ab-root/mkosi.conf`. The three production native profiles (`cayo-ab`, `snow-ab`, `snowfield-ab`) reduce to `[Config]`/`[Output]`/`[Include]` only (Phase 3) — every setting, including the secure posture, lives in `[Include]`d fragments: `Include=%D/shared/native-ab-secure/mkosi.conf` is listed FIRST, before the composition include, so its `FinalizeScripts=disable-nvpcr.chroot` resolves before the composition fragment's image finalize (mkosi accumulates list settings in `Include=` encounter order across the whole resolved config) — the resolved FinalizeScripts order stays disable-nvpcr -> image finalize -> var-audit.finalize -> ab-root finalize, verified via `mkosi --profile <p> summary`.

**mkosi Include ordering matters for list settings:** mkosi accumulates list-valued settings (`Packages=`, `FinalizeScripts=`, `BuildScripts=`, etc.) across the whole resolved config in the order each `Include=` is textually encountered (recursing into included files at that point), not grouped by which file declared them. When refactoring composition, the arbiter is a byte-level diff of `mkosi cat-config`/`summary` output before and after — not a read of the source files. Two gotchas hit doing this: (1) `History=yes` (base `mkosi.conf`) caches the last-used `--profile` in `.mkosi-private/history/latest.json` (root-owned) and silently overrides `--profile` on every later invocation of read-only verbs like `cat-config` (prints "Ignoring --profile from the CLI"); `summary` has an explicit bypass for `-f`, but `cat-config` does not — `sudo rm -f .mkosi-private/history/latest.json` before capturing config snapshots. (2) `summary` output has three fields that are non-deterministic per invocation and must be normalized out of any diff: `Seed:` (fresh random UUID per run), `Prepare Scripts: /tmp/tmpXXXXXXXX/...mkosi-tools/mkosi.prepare` (random tools-tree extraction tmpdir), and `Image Version:` (defaults to the current wall-clock timestamp when unset) — none are derived from config content.

Root `mkosi.conf` depends on `base` plus all sysexts so `mkosi build`/`just sysexts` produces the sysext publishing set. Profile configs must start with an empty `Dependencies=` assignment followed by `Dependencies=base`; mkosi appends collection settings, so the empty assignment is required to avoid rebuilding every sysext for each profile image build.

### Script Pipeline (per image)

Scripts execute in order: **BuildScripts** (in chroot) -> **PostInstallationScripts** (after packages) -> **FinalizeScripts** (pre-output) -> **PostOutputScripts** (after image creation).

### Immutable Filesystem Constraints

- `/usr/` - Read-only. All binaries and libraries must live here.
- `/etc/` - Overlay on `/usr/etc`. Base configs in image, user changes persist.
- `/var/` - Persistent, writable. State, logs, container storage.
- `/opt/` - Bind mount to `/var/opt`. Writable at runtime but **shadowed by sysext overlays**.

**Critical pattern:** Packages installing to `/opt` must be relocated to `/usr/lib/<package>` at build time with symlinks in `/usr/bin`. This applies to both desktop images and sysexts.

**Runtime service enablement changes are forbidden:** units must never run `systemctl disable`/`enable` at runtime (e.g. via `ExecStartPost`) — it deletes/creates `.wants`/`.requires` symlinks in `/etc`, and any path removed from the live `/etc` relative to the booted image makes bootc's `/etc` merge fail at update finalize with "a path led outside of the filesystem" (bootc ≤ 1.16.3 follows the corresponding symlink in the new deployment's `/etc` out of its sandbox). The failure is silent from the user's perspective: `bootc-update-stage` keeps logging "staged" while every reboot discards the staged deployment and boots the old image (root-caused 2026-07-05 on `enable-incus-agent.service`). For run-once behavior, gate on a `/var` marker file instead (see `snow-linux-live-setup.service`). CI enforces this: `check-runtime-etc-guard.sh` (run by `validate.yml`) fails on runtime `systemctl disable/enable`, `/etc` deletions, and tmpfiles removal types on `/etc` in any shipped payload dir (`mkosi.extra/`, `shared/*/tree/`); escape hatch is a trailing `# etc-guard-allow: <reason>` comment.

**First-boot semantics:** the image ships `/etc/machine-id` containing the literal `uninitialized` (the machine-id(5) golden-image value), so the first boot of every install is a TRUE systemd first boot: `ConditionFirstBoot=yes` fires, PID 1 applies system unit presets, `preset-global.service` applies user-scope presets, and a unique machine ID is then generated and committed. (Before 2026-07 the image shipped an *empty* machine-id, which only means "generate an ID" and silently suppressed all first-boot semantics — the finalize comment claimed the opposite.) `systemd-firstboot.service` is preset-disabled so nothing prompts on the console; the installer and first-setup own locale/hostname/user. The `sshd-keygen.service.d` drop-in (path-gated on missing host keys) is kept because it also covers key deletion on existing installs.

**Enablement lives in presets, not shipped `/etc` symlinks:** the outformat finalize script strips ALL unit enablement symlinks (`.wants`/`.requires` entries and `[Install]` aliases, both system and user scope) from the image `/etc` after mkosi's build-time `preset-all` pass, recording them in `/usr/share/snosi/enablement-manifest.txt`. First boot recreates them from the same preset policy as *runtime-created* `/etc` state — so an admin's `systemctl disable` deletes a runtime-created path and no longer breaks bootc's `/etc` merge (see below). Masks (`/dev/null` symlinks) and linked units (e.g. the dracut service links) are kept: presets cannot recreate those. Consequences: (1) enablement changes belong in `usr/lib/systemd/system-preset/` / `user-preset/` files, never in postinst `systemctl enable` or manual symlinks — mkosi runs `preset-all` (and `--global preset-all`) AFTER postinst scripts, so manual symlink surgery there is silently overridden by the preset pass; (2) a NEW image's changed preset policy does not re-apply wholesale to existing installs (first boot has passed) — `preset-reconcile.service` closes the gap incrementally: it diffs the image manifest against `/var/lib/snosi/enablement-manifest.applied`, presets ONLY units newly added to policy (creates-only, masked units win, admin disables are never fought), records policy removals for the drift report (never auto-disables), and snapshots the applied policy; (3) `test/tests/05-firstboot-presets.sh` verifies manifest parity on first boot; (4) **snosi infrastructure units use STATIC activation, not presets**: preset-reconcile, snosi-etc-drift-report, the notify user units, and preset-migration ship with NO `[Install]` section plus a static wants symlink in `/usr` (`multi-user.target.wants/`, user `graphical-session.target.wants/`, `sysinit.target.wants/`) — preset-based enablement of a NEW unit cannot bootstrap on installs whose first boot predates it (reconcile itself had this chicken-and-egg, caught 2026-07-06), while static /usr wants work everywhere immediately, keep zero `/etc` state, and are overridden with `systemctl mask` (not `disable`).

**Unit files must live in exactly ONE tree.** `shared/snow/tree` and `shared/cayo/tree` once carried byte-identical copies of base units (mount units, nbc-update-download); profile ExtraTrees overwrite base at image assembly, so a fix applied only to the base copy silently did not ship in any profile image (caught 2026-07-06: the nbc composefs gate). Base `mkosi.extra` is authoritative for shared units; profile trees carry only genuinely profile-specific files.

**Drift visibility:** `snosi-etc-diff` (root CLI) diffs live `/etc` against the booted image's pristine `/etc` (bind-mounts `/` to see under the `/etc` mount — no `/usr/etc` exists on composefs), with ignore globs in `/usr/lib/snosi/etc-diff.ignore` (+ optional `/etc/snosi/etc-diff.ignore`) for expected per-machine state. On native A/B images (marker `/usr/lib/snosi/native-ab`), root is EROFS and live `/etc` is an overlay whose lowerdir is `/.etc.lower` on that same root, so the bind-mount trick would expose `/.etc.lower` plus an empty `/etc` mountpoint dir; the script instead uses `/.etc.lower` directly as the pristine tree (no mount needed), and everything downstream — listing, path diff, restore — is identical between the two sources. Beyond the M/D/A path listing (which ends with a resolution footer), `snosi-etc-diff /etc/<path>` shows the actual difference (unified diff / symlink targets / permission lines) and `snosi-etc-diff --restore /etc/<path>` reverts a path to the image version (refuses locally-added paths — nothing to restore from). `snosi-etc-drift-report.service` writes M/D entries plus preset-policy removals to `/var/lib/snosi/etc-drift.report` each boot; a hash-gated user service (`snosi-etc-drift-notify`) raises one desktop notification per report *change* (not per boot), and `/etc/update-motd.d/85-snosi-etc-drift` surfaces it on headless logins. Keep the ignore list honest: entries that always drift (daemon-rewritten files) train users to dismiss the report.

### OS Update Staging (bootc)

On bootc-installed systems, updates are staged by `bootc-update-stage.timer` (hourly; base `mkosi.extra`): `/usr/libexec/bootc-update-stage` pulls the followed image via **podman**, then stages it with `bootc upgrade` when the spec already follows `containers-storage` (the steady state after the first staged update) or `bootc switch --transport containers-storage` otherwise — `bootc switch` to an IDENTICAL spec is a silent no-op in bootc ≤ 1.16.3 (composefs switch returns before staging when `new_spec == host.spec`), which made every install unable to take a second update while logging success (root-caused 2026-07-06). The script verifies post-stage that `.status.staged.image.imageDigest` equals the pulled digest and fails loudly otherwise. The update applies at the next natural reboot via `bootc-finalize-staged.service`. **Reboot-pending visibility:** after staging (or when finding an update already staged, e.g. via manual `bootc upgrade`), the script writes `/run/snosi/update-staged` (image/digest/timestamp; cleared automatically by the applying reboot). Two consumers: `/etc/update-motd.d/86-bootc-update-staged` (SSH/console logins) and `bootc-update-notify.path`/`.service` (user scope, desktop notification via `/usr/libexec/bootc-update-notify`, ack-gated per staged digest so it fires once per update, not per login). The desktop toast needs the `notify-send` CLI, which lives in `libnotify-bin` (NOT the transitively-pulled `libnotify4` library) — it ships only in the graphical package set (`shared/packages/snow/mkosi.conf`, used by snow+snowfield, not cayo); without it both `bootc-update-notify` and `snosi-etc-drift-notify` `command -v notify-send || exit 0` into silent no-ops. Both notify units set `StartLimitIntervalSec=0` because the stager writes the semaphore in several syscalls, so one staging emits a burst of `PathModified` triggers that otherwise trips systemd's default 5/10s start-limit and permanently fails the `.path` watcher (`unit-start-limit-hit`); the per-digest ack makes the repeat triggers harmless no-ops. **Currency visibility:** the script also writes `/run/snosi/update-check` on EVERY run (`outcome=current|staged|held-rollback|failed` plus timestamp and running/remote version; an EXIT trap records `failed` on any error) so "up to date", "reboot pending", and "checker broken" are three distinguishable states instead of one silent one. The same motd hook prints one line per state, and `snosi-update-status` (root CLI) summarizes running version, last-check outcome, and staged deployment; `snosi-update-status --check` additionally queries the registry live via skopeo and compares `org.opencontainers.image.version` labels — always compare versions, never digests (the same build has a different digest per transport: registry vs ISO vs podman-loaded). podman does the transfer because bootc's registry-transport composefs pull currently fails on snosi images (known upstream bug) — and podman enforces `containers-policy.json` at pull time. The script no-ops when: not a bootc-managed system (nbc installs — `spec.image` is null), already running or already staged the pulled digest, or the pulled digest equals the **rollback** deployment (never auto-flip-flop back to a version the admin rolled away from; bootc refuses that switch anyway). Upstream's `bootc-fetch-apply-updates.timer` is preset-disabled: it force-reboots on update and is gated on `/run/ostree-booted`, which does not exist on composefs deployments. During the transition, `nbc-update-download.timer` still ships for nbc-installed hosts. bootc-update-stage no-ops on nbc installs (`spec.image` null check); the nbc units are gated with `ConditionKernelCommandLine=!composefs` because `nbc update` itself ERRORS (exit 1, permanently failed unit, degraded state) rather than no-opping on bootc/composefs installs (frostyard/nbc#139).

### Base Image: bootc + ostree from Frostyard debs

bootc and ostree install as regular APT packages (`bootc`, `libostree-1-1` — the latter ships the library AND the ostree CLI) from the Frostyard repository, built and published by [frostyard/bootc-debian](https://github.com/frostyard/bootc-debian). Debian Trixie ships no bootc package and only ostree 2025.2 (too old for current bootc), hence the external packaging.

- **Versions:** pinned in bootc-debian's `download/checksums.json`, tracked weekly by that repo's own `check-dependencies.yml` — snosi's dependency check does NOT cover them. Deb versions carry a `-frostyard<timestamp>` suffix so rebuilds of the same upstream version still sort newer in apt.
- **Build parity:** bootc-debian's `build.sh` mirrors the former in-tree mkosi BuildScript (same pinned tarballs, same checksums, same pinned Rust toolchain — Debian's rustc 1.85 is too old to build bootc 1.16.x). Its Build workflow publishes the debs and then dispatches a snosi image build.
- **Runtime libs:** the debs declare only a partial `Depends` list; base `Packages=` keeps the full set of runtime link deps explicit (`libfuse3-4`, `libsoup-3.0-0`, `liblzma5`, etc.) — do not remove them just because apt doesn't demand them.
- **History:** until 2026-07 these were compiled from source during the base image build (`shared/bootc/build/bootc.chroot` + stub-deb dpkg registration); that machinery is gone.

### Native A/B Prototype

Naming, path, and policy contracts for the production native A/B products
(`cayo-ab`, `snow-ab`, `snowfield-ab`) are frozen in
`docs/native-ab-contracts.md` and enforced statically by
`test/native-ab-contracts-test.sh`. Read that document before adding or
renaming anything under the native A/B tree — it is the source of truth, not
this section. Known deviations of the current prototype from the frozen
contract are tracked in `test/native-ab-contracts-allow.txt`, not silently
carried forward. `check-native-publication-guard.sh` (wired into
`validate.yml`) is the standalone static gate for the contract's §15
publication guard: it requires every profile literally named `cayo-ab`,
`snow-ab`, or `snowfield-ab` to carry shim/Secure Boot/PCR-signing markers,
an NvPCR-disable finalize reference, the ab-root outformat include, the
committed update pubring, and no final-root `KernelModules=` filter, and it
hard-fails if `cayo-ab-raw` ever picks up a publication marker. Since Phase 3
all three production profiles exist and pass the guard: the check follows a
profile's `[Include]=shared/native-ab-secure` line as a plain textual
reachability check (not a general `Include=` resolver — only this one
documented fragment) so the markers can live in the shared fragment instead
of being restated per profile.

**Generic output + per-product channels (Phase 3):** `shared/outformat/ab-root/`
carries ONLY product-neutral disk/boot mechanics — `Format=disk`,
`SplitArtifacts=`, `Bootable=yes`, `Initrds=`/`KernelModulesInitrd=no`,
`KernelCommandLine=`, the shared `tree/` (fstab, the etc-overlay dracut
module, the legacy-updater masks, the sysupdate-timer preset, the
`native-ab` marker), and the finalize script. It carries NO
`RepartDirectories=`, NO `*.transfer` files, and NO final-root
`KernelModules=` filter — `test/native-ab-contracts-test.sh` asserts all
three unconditionally. Every one of those three lives instead in
`shared/native-ab/channels/<product>/` (`cayo`, `snow`, `snowfield` —
`docs/native-ab-contracts.md` §12), which supplies its own
`RepartDirectories=` (the 6 repart defs, ImageId-based labels and
mkosi-internal `SplitName=`, 1 GiB ESP) and its own
`tree/usr/lib/sysupdate.d/` (the 3 OS transfers, frozen R2 URL, `<ImageId>-ab`
channel-prefixed `Source MatchPattern=`, `<ImageId>`-based `Target
MatchPattern=` labels — §3 labels are ImageId-scoped, not channel-scoped, so
they never change when a new channel starts publishing). A profile consumes
native A/B output by `Include=`ing BOTH the generic `shared/outformat/ab-root/mkosi.conf`
fragment AND exactly one channel's `mkosi.conf`; mkosi's list-setting
accumulation means the channel's `ExtraTrees=`/`RepartDirectories=` add to,
not replace, the generic fragment's. `mkosi.profiles/cayo-ab-raw` and the
production `cayo-ab` both `Include=` the `cayo` channel; `snow-ab` and
`snowfield-ab` (Task 3.2) `Include=` the `snow`/`snowfield` channels
respectively. All root+verity slot sizes are now VALIDATED against real
native builds, not provisional: cayo is 5 GiB root / 256 MiB verity
(~23.8% headroom); snow is 8 GiB root / 256 MiB verity (~33.8% headroom,
measured content ~5.29 GiB — smaller than the earlier bootc-derived
provisional estimate, which conservatively over-counted bootc/ostree/grub
tooling that native profiles never install); snowfield reuses the same
8 GiB / 256 MiB slot (~29.5% headroom, measured content ~5.64 GiB — the
Surface kernel's larger driver/firmware set costs about 374 MiB more than
snow's backports kernel, still comfortably inside the slot). See
`docs/native-ab-capacities.md` for full measured numbers and the headroom
definition.

**Module policy (Phase 3):** release native profiles ship the complete
packaged kernel module/firmware set — no final-root `KernelModules=` pruning
(`docs/native-ab-contracts.md` §9). The virtio-only filter that used to live
in the shared `ab-root` fragment moved into `mkosi.profiles/cayo-ab-raw/mkosi.conf`
directly (the one dev fixture permitted to carry it — a QEMU-only
restriction to keep dracut's `--no-hostonly` initrd self-contained and avoid
mkosi's dependency sweep failing on unresolved Debian module aliases);
the three production profiles (`cayo-ab`, `snow-ab`, `snowfield-ab`) build
with the full module set. The generic tree's
`usr/lib/dracut/dracut.conf.d/30-bootc-standard.conf` is a DELIBERATE
same-named override: `ExtraTrees=` composition overwrites files at
identical relative paths, so this file replaces (not supplements) the base
image's copy of the same name, which is how `add_dracutmodules+=" lvm crypt
etc-overlay "` replaces the base's `"... bootc"` line rather than both
surviving into the same `dracut.conf.d` directory — the filename match is
load-bearing and `test/native-ab-static-test.sh` asserts it holds by finding
whichever base file adds the `bootc` dracut module and checking ab-root's
tree shadows it at the identical relative path.

**The `ExtraTrees=` shadow alone is not early enough for every kernel package
(Task 3.2 root cause, `dracut[E]: Module 'bootc' cannot be found`):** mkosi's
build order is `install_skeleton_trees()` -> `install_distribution()`
(installs `Packages=`) -> `install_extra_trees()` (confirmed in
`.mkosi/mkosi/__init__.py` `build_image()`), so the `ExtraTrees=` shadow of
`30-bootc-standard.conf` above only lands AFTER packages — including the
kernel — are installed. Debian's own `linux-image-amd64` (cayo-ab/snow-ab)
defers its kernel-postinst dracut regeneration via a dpkg trigger and never
hits this window, but the linux-surface kernel package (`snowfield-ab`) runs
`/etc/kernel/postinst.d/dracut` SYNCHRONOUSLY as part of its own postinst,
at which point the base image's un-shadowed copy (requesting the `bootc`
module, which native profiles never install) is still in effect, and the
build hard-fails. Fixed by ALSO pulling the identical canonical file in via
`SkeletonTrees=%D/shared/outformat/ab-root/tree/usr/lib/dracut/dracut.conf.d/
30-bootc-standard.conf:/usr/lib/dracut/dracut.conf.d/30-bootc-standard.conf`
in `shared/outformat/ab-root/mkosi.conf` — SkeletonTrees run BEFORE package
installation, so the shadow is in effect from the very start of the
buildroot regardless of which kernel's postinst hook happens to run
synchronously. No file duplication: same source path, two composition
mechanisms. The `ExtraTrees=` copy is still required (it is what
`test/native-ab-static-test.sh` checks, and it is the one that would win if
a future kernel ever overwrote this path mid-install). Verified harmless for
cayo-ab/snow-ab (rebuilt with the fix, artifact tests still pass, root
content size unchanged to within build-metadata noise).

`mkosi.profiles/cayo-ab-raw` (renamed from `cayo-ab` in Phase 1; `Output=`
changed to match, `ImageId=cayo` unchanged) is an isolated experimental disk
profile, a permanent, never-published dev fixture per
`docs/native-ab-contracts.md` §1 — the name `cayo-ab` is reserved for the
eventual secure production posture. Its initrd
must mount persistent `var` and overlay `/etc` before switch-root; never add a
host system-service fallback. The image ships `machine-id=uninitialized`, and
first boot commits a unique ID into the overlay upperdir. The installer grows
only the final ext4 `var` partition. OS transfers are mandatory, UUID-bearing,
and `Verify=yes`; do not enable `systemd-sysupdate.timer` until a dedicated
`/usr/lib/systemd/import-pubring.gpg` and signed publication pipeline exist.
Partition payloads must use XZ: Debian's systemd 257 `systemd-pull` does not
decode Zstandard URL payloads and writes them compressed into the target slot.
Partition transfers must reset `PartitionFlags=0` before applying `ReadOnly=yes`.
The kernel postinstall exports its dracut archive to
`$ARTIFACTDIR/io.mkosi.initrd`; `Initrds=` and `KernelModulesInitrd=no` prevent
mkosi from silently embedding an unrelated default initrd instead. The custom
dracut module depends on `systemd-veritysetup` so the UKI `roothash` creates the
verified root before the overlay service runs. Until signed publication is
available, the image finalizer masks both sysupdate timers in `/etc`: initrd PID
1 starts before real-root preset policy is visible, so a preset alone cannot
reliably prevent first-boot timer enablement. Manual sysupdate remains available.
GPT partition labels for the dynamic root/verity slots are `<ImageId>_<version>_r`
and `<ImageId>_<version>_v` (`docs/native-ab-contracts.md` §3; shortened from the
prototype's original `_root`/`_root_verity` suffixes in Phase 1 to stay under the
30-code-unit ceiling at the frozen 14-digit version length) — set per-product
in `shared/native-ab/channels/<product>/mkosi.repart/{10-root-verity,11-root}.conf`
(Phase 3; formerly a single shared `shared/outformat/ab-root/mkosi.repart/`)
and matched by the `Target MatchPattern=` in the corresponding channel
`*.transfer` files. Native
images must never run the legacy bootc or nbc update machinery: the base image
ships `bootc-update-stage.timer`/`.service`, `nbc-update-download.timer`/`.service`,
and the user-scope `bootc-update-notify.path`/`.service` unconditionally (shared
with the bootc profiles), so `shared/outformat/ab-root/tree/usr/lib/systemd/{system,user}/`
masks each one with a same-named `/dev/null` symlink — the same mechanism used for
`systemd-growfs-root.service`. Upstream's own `bootc-fetch-apply-updates.*` ships
inside the `bootc` deb itself, which native profiles never install, so those two
units need no mask. `test/native-ab-static-test.sh` asserts every mask exists.
`test/native-ab-update-test.sh` validates N to N+1 to N+2 to N+3 with four real
mkosi builds: signed-manifest acceptance/rejection, missing UKI/verity and bad
checksum rejection, inactive-slot reuse, dm-verity boot, explicit rollback,
boot-count fallback from a corrupted unblessed update, and `/var` plus `/etc`
persistence.

`test/native-ab-components-test.sh` is the Phase 1 exit-criterion QEMU test: it
builds two real `cayo-ab-raw` versions itself, boots N, and asserts no failed
systemd units and the bootc/nbc/systemd-sysupdate masks from above; that
`/usr/lib/sysupdate.d/` contains only the three OS transfers (no `.feature`
files) while `systemd-sysupdate components` enumerates all 17 shipped sysext
components; that two independently versioned ad hoc test components
(`testa`/`testb`, created under `/etc/sysupdate.<name>.d/`) update via
`--component=` without touching OS partitions, the ESP, or each other's
version; that an unqualified N to N+1 OS update succeeds with both test
components still enabled and `/var/lib/extensions.d` untouched; and that
`snosi-etc-diff`/`snosi-etc-drift-report.service` correctly report, diff, and
restore live `/etc` drift against `/.etc.lower` with no leftover bind mounts.
It caught a real bug: the `KernelModules=` allowlist (originally in the
shared `ab-root` fragment, moved to `mkosi.profiles/cayo-ab-raw/mkosi.conf`
in Phase 3 — see "Module policy" above) excluded `nf_tables`/`nfnetlink`, so
the base image's unconditionally-shipped, preset-enabled `nftables.service`
failed on every native A/B boot ("Unable to initialize Netlink socket:
Protocol not supported") — fixed by adding both modules to the allowlist.

**Publication naming pipeline and test parameterization (Phase 3):**
`shared/native-ab/publish/prepare-native-publication.sh` converts one built
native profile's mkosi outputs (`Output=`, e.g. `cayo-ab`) into the frozen
`docs/native-ab-contracts.md` §4 public names. Product and version come from
that profile's own JSON manifest (`.config.name`/`.config.version`); channel
is the given `Output=` value, validated to equal `<product>-ab` — this is
what makes the script refuse to "publish" the never-shipped `cayo-ab-raw`
dev fixture, as a mechanism, not a convention. PARTUUIDs come from `sfdisk
--json` on the built disk, located by GPT partition name (needs neither a
loop device nor root — confirmed against a real 16 GiB disk). `--xz`
appends `.xz` to the root/root-verity/disk artifacts (the real §4 form);
without it the same base names are produced unsuffixed, an
intentionally-not-frozen fast path for local iteration and QEMU test
fixtures. Also emits an unsigned `SHA256SUMS` (signing is the Phase 7
promotion step) and a `publication-info.json` record. NOT wired into
`PostOutputScripts=`: every individual permission concern checks out
(`sfdisk --json` needs no root, `$OUTPUTDIR` is fully populated by
post-output time — both verified directly), but the script's job is to copy
5-23 GiB of root/root-verity/disk artifacts a second time, and
`PostOutputScripts=` runs on every single `mkosi build` — every local dev
iteration and every profile in the `build-images.yml` matrix — which would
silently double per-build disk consumption regardless of whether that
build is ever published, echoing the recorded "CI Disk Exhaustion"
incident; kept manual, for the (not yet built, Phase 7) protected
promotion job to invoke deliberately. `test/native-publish-test.sh`
validates the naming/derivation logic against a synthetic fixture
(`truncate` + `sfdisk` script mode, no root, no image build), including that
a `*-ab-raw` profile name is rejected; `test/native-ab-contracts-test.sh`
also runs it internally so a naming drift fails that same static gate.
`test/native-ab-update-test.sh` and `test/native-ab-components-test.sh`
accept `PROFILE`/`IMAGE_ID`/`CHANNEL` env overrides (defaults
`cayo-ab-raw`/`cayo`/`cayo-ab`, byte-equivalent to the prior hardcoded
behavior) — partition labels and transfer partition `Target
MatchPattern=` stay `IMAGE_ID`-based (GPT labels are never
channel-scoped, §3) while OS transfer `Source`/UKI names stay
`CHANNEL`-based, matching the real shipped channel transfers even for the
default `cayo-ab-raw` fixture (whose own build output is never itself
named `cayo-ab`). `native-ab-components-test.sh`'s N+1 OS update fixture is
now generated by running the profile's build output (symlinked under its
`$CHANNEL` name) through the publisher with `--xz`, so that leg exercises
the real public contract end to end instead of hand-rolled fixture naming.

**Shared secure posture fragment (`shared/native-ab-secure/`, Phase 3):**
until Phase 3 the secure posture lived directly in the standalone
`mkosi.profiles/cayo-ab-secure` spike profile. That profile is retired
(`git rm`); its content moved almost verbatim into
`shared/native-ab-secure/mkosi.conf`, an includable fragment carrying
everything except identity (the `[Output]` block: `ImageId=`/`Output=` differ
per product) and the payload/kernel/channel `[Include]=`s (also per-profile).
`mkosi.profiles/{cayo-ab,snow-ab,snowfield-ab}/mkosi.conf` are now the
production posture: each is ONLY `[Config]` (the `Dependencies=` header),
`[Output]` (identity), and `[Include]` — `Include=%D/shared/native-ab-secure/mkosi.conf`
listed FIRST (see "Payload composition" above for why the ordering matters),
then the product's `shared/composition/<cayo|snow>/mkosi.conf`,
`shared/kernel/<backports|surface>/mkosi.conf`,
`shared/outformat/ab-root/mkosi.conf`, and
`shared/native-ab/channels/<cayo|snow|snowfield>/mkosi.conf`. `just cayo-ab`,
`just snow-ab`, `just snowfield-ab` build them (mirroring the bootc profile
targets). Standard Secure Boot
uses Debian's Microsoft-signed shim and MOK-signed systemd-boot; generated snosi
UKIs are signed by `mkosi.key`/`mkosi.crt` and require one-time enrollment of
that certificate through shim's MokManager. GRUB is unsuitable because its
generated configuration hard-codes the build-time UKI and ignores sysupdate's
Type #2 entries and boot counters. Never use mkosi Secure Boot auto-enroll,
UEFI setup mode, or custom firmware db keys for this path. The installer creates
LUKS2 `/var` per machine after expanding the final partition; never publish a
pre-encrypted `/var`, which would clone LUKS metadata and key material. Always
retain a recovery passphrase outside the installed disk. TPM enrollment uses
the signed PCR 11 policy key with an empty raw-PCR set and explicitly disables
automatic pcrlock policy selection. Do not bind PCR 7 in the
installer: its Debian-signed boot authority differs from the installed
MOK-signed UKI, so the value changes before first boot. A raw PCR 11 value would
break each A/B update. The initrd explicitly detects LUKS and invokes
`systemd-cryptsetup attach`; GPT auto-discovery does not unlock `var` during this
dracut phase. Raw ext4 remains only for `cayo-ab-raw`, the never-published dev
fixture. LUKS2 creation,
MOK enrollment, enforced Secure Boot, TPM auto-unlock, TPM replacement failure,
recovery unlock, and PCR signing-key rotation are validated in Incus. Update,
rollback, and boot-count fallback are also validated end to end with the sole
new-key TPM token. The three production profiles upgrade the complete systemd family to
Forky 261+ through the shared fragment's profile-only, low-priority APT source; never expose that
source to the base or normal profiles, and keep all exact-version systemd
libraries and companion packages qualified together.
Do not implement signing-key overlap as two independent TPM tokens. A controlled
systemd 261.1 test continued from a raw-PCR-mismatched token 0 to token 1, but a
real signed-policy key mismatch returned `ENXIO` and stopped before token 1. The
validated rotation sequence uses a transition UKI whose PCR 11 policies are
signed by both keys while `.pcrpkey` contains the new key. Archive the old private
key under `.snosi-private/history/`, make the new key active, and set
`PCR_SIGNING_KEY_PREVIOUS` to the old key's filename for transition builds. Keep
the old TPM token until every supported rollback UKI contains the new signature;
then remove it and verify the same transition UKI unlocks with the new token.
Validate each production build with
`test/native-ab-secure-artifact-test.sh` (`OUTPUT_NAME` env var, or explicit
`output/<name>.manifest output/<name>.efi` args, selects which profile's
artifacts to check; defaults to `cayo-ab`), which checks root-package coherence,
the initrd's private systemd library and TPM token plugin, and UKI PCR sections.
When given the old certificate and new public key, it also requires eight PCR
signatures: four policies signed once by each key, with the new key in `.pcrpkey`.
`test/native-ab-secure-artifact-negative-test.sh` mutates those sections and
requires rejection. `test/native-ab-secure-rotation-test.sh` is the destructive
runtime proof for an already MOK-enrolled disposable VM. It requires `--yes`, an
exact machine ID, a working external recovery key, and root SSH. It uses
guest-local `systemd-sysupdate` with a verified ephemeral signed manifest,
establishes old-only and new-only TPM states, and requires two unattended boots
of the identical transition UKI. Never point it at a production host. It
intentionally does not automate MokManager or VM creation, and N-through-N+3
rollback/fallback is validated separately by
`test/native-ab-secure-update-test.sh`. That destructive harness requires
N+1/N+2 dual-signed artifacts, an N+3 new-only artifact, exact machine and Incus
instance identities, and the external recovery key. It verifies alternating
slots, sole-new-key unlock, explicit rollback, re-arms the successfully tested
N+3 entry as `+3-0`, corrupts its root, observes three emergency boots, and
requires automatic N+2 fallback plus the exhausted `+0-3` entry.
A clean production-profile build is
validated: its ESP contains Debian-signed shim, MokManager, and MOK-signed
systemd-boot, and its MOK-signed UKI contains `.pcrpkey` and `.pcrsig`. In pinned mkosi,
`UnifiedKernelImages=unsigned` means build locally; `SecureBoot=yes` still signs
the result. Setting it to `signed` incorrectly requests a distro-prebuilt UKI.
Never store durable keys or retained test artifacts under `.mkosi-private`:
mkosi owns that directory and `mkosi clean -ff` removes it. Use the gitignored
`.snosi-private` directory.

Systemd 261 NvPCR anchor credentials embed the PCR signing public key and have
no supported migration operation. A dual-signed transition can read an old
anchor, but a new-only UKI then fails `systemd-tpm2-setup`, `systemd-pcrproduct`,
and `systemd-pcrlogin` with `ENXIO`. None of the three production profiles consume NvPCR
attestation, so `shared/native-ab-secure/finalize/disable-nvpcr.chroot` (`FinalizeScripts=`
in the shared fragment, run before every consumer's image finalize) masks every
shipped NvPCR definition plus the product/login writers. Keep TPM SRK setup and
the signed-PCR-11 LUKS path enabled. Do not delete/recreate the anchor or TPM NV
indexes as a key-rotation shortcut; that changes the attestation baseline.

**Dev update signing pubring (Phase 3):** every native image (including
`cayo-ab-raw`) ships `/usr/lib/systemd/import-pubring.gpg` via a `file:target`
`ExtraTrees=` pair in `shared/outformat/ab-root/mkosi.conf` (the pinned
mkosi's `install_tree()` copies a single file when a target is given, not
only directories/tar archives — confirmed in `.mkosi/mkosi/__init__.py`).
The committed public keyring is a DEV-only ed25519 key
(`shared/native-ab/keys/import-pubring.gpg`, see
`shared/native-ab/keys/README.md`); its private half is
`.snosi-private/os-update-signing.key` (gitignored, never committed, never
printed — nothing in-repo signs with it yet, since dev/local `SHA256SUMS`
stay unsigned per `docs/native-ab-contracts.md` §7). This satisfies
`check-native-publication-guard.sh`'s pubring-committed check ahead of the
real Phase 7 signing pipeline; QEMU update tests generate their own
ephemeral keys and are unaffected. **Rotate this key before first production
publication** — see the README and contract §7 for the real key-ceremony
procedure.

**Accepted risk — unsigned sysexts on native installs:** native production
candidates (`cayo-ab`, `snow-ab`, `snowfield-ab`) ship every sysext transfer
with `Verify=false` and every sysext `.feature` defaulting to `Enabled=false`.
Unlike the three OS transfers (`Verify=yes`, signed-manifest enforced), sysext
downloads are not currently signature-verified. This is an explicit accepted
risk until signed per-component metadata ships for sysexts — do not flip any
sysext `.feature` to `Enabled=true` by default on a native production
candidate before that lands.

**Release-ordering constraint (sysext component migration):** as of the
migration that split the shared `/usr/lib/sysupdate.d/` target into
per-sysext `/usr/lib/sysupdate.<name>.d/` components (see "Sysext
Constraints" below), base images built from this tree must not be
merged/published until a `frostyard-updex` release with component discovery
(`feat/sysupdate-components`) is published to the Frostyard APT repo — an
older updex binary cannot discover component-scoped sysexts, silently
dropping every sysext from update offers.

### Native `/var` Factory State

The native installer creates a fresh per-machine `/var`; nothing written to
image `/var` at build time survives an install (see the disk-layout note in
"Native A/B Prototype" above). This applies just as much to `cayo`/`snow`/
`snowfield` bootc images: repart's `11-root.conf`/`21-root-empty.conf`
(`ExcludeFilesTarget=/var/`) and `30-var.conf` (no `CopyFiles=`) mean the
disk image's `var` partition ships EMPTY from the build itself — the
installer doesn't need to wipe anything, there is nothing there to begin
with. Two build-time mechanisms cover this:

**A. The `/var` inventory audit** (`shared/composition/var-audit.finalize`,
a non-chroot `FinalizeScript` — it runs on the host and reads `$BUILDROOT`,
`$SRCDIR`, `$IMAGE_ID` directly, no `mkosi-chroot` needed) walks every file,
symlink, and EMPTY directory under `$BUILDROOT/var` at the end of the
build (non-empty directories are represented by their contents, not
themselves) and classifies each against a per-product outcome map:
`shared/composition/cayo/var-outcomes.txt` (used by `cayo` bootc AND
`cayo-ab-raw`/`cayo-ab` native, since they share
`shared/composition/cayo/mkosi.conf`) and `shared/composition/
snow/var-outcomes.txt` (used by `snow`/`snowfield` bootc AND `snow-ab`/
`snowfield-ab` native, since they share `shared/composition/snow/mkosi.conf`).
Map format: `<glob><TAB><outcome>`
per line, `#` comments, outcome one of:

- `image-metadata` — belongs to the immutable root (the dpkg database and
  the compiled aspell dictionaries; see B below).
- `tmpfiles` — a shipped `/usr/lib/tmpfiles.d/*.conf` rule recreates this
  path (directory or symlink) on every boot.
- `discard` — build residue, deliberately lost (caches, logs, machine
  state, dpkg/apt/ucf/deb-systemd-helper bookkeeping, package-trigger
  scratch state).
- `installer-seed` — written by the installer after `mkfs` (none yet).

The audit FAILS the build on any unclassified path (with the full list) or
any map glob that matched nothing in that build ("stale" — keeps the map
from silently drifting from reality), and on success writes `usr/share/
snosi/var-inventory.txt` (`<outcome>\t/var/<path>`, sorted) into the image.
Wired as the LAST `FinalizeScripts=` entry in
`shared/composition/{cayo,snow}/mkosi.conf`, after the shared image
finalize (`shared/outformat/image/finalize/mkosi.finalize.chroot`, which
does the dpkg relocation below) — verified via `mkosi --profile <p>
summary` that this resolves to `[image finalize.chroot, var-audit.finalize,
ab-root finalize.chroot]` for native profiles; `shared/outformat/ab-root/
finalize/mkosi.finalize.chroot` runs after the audit but never touches
`/var` (only `/etc`), so the ordering is safe.

**Updating a map when a package adds new `/var` state:** a build failure
lists every unclassified path. Classify each: if a shipped tmpfiles rule
already creates it (check the actually-built image's `/usr/lib/tmpfiles.d/`,
not just this repo's hand-authored overlay — most of a Trixie desktop's
tmpfiles rules are package-shipped, e.g. `dbus.conf`, `colord.conf`),
outcome is `tmpfiles`; otherwise default to `discard` with a one-line
comment UNLESS a booted system plainly needs it (chase it to a tmpfiles fix
or flag it, don't silently discard). List more specific globs before
broader ones matching the same subtree — the audit classifies by the FIRST
matching glob, top to bottom, and only that glob counts as "used" for the
stale check. A path that can appear in two structurally different shapes
across builds (see the dpkg example below) needs ONE glob with a bare `*`
covering both shapes, not two separate globs — with two globs, whichever
shape didn't occur in a given build makes the other glob spuriously
"stale" and fails that build.

**B. dpkg database relocation (native only).** The native-gated block in
`shared/outformat/image/finalize/mkosi.finalize.chroot` (guarded by the
same `/usr/lib/snosi/native-ab` marker as the sysupdate-timer masking
above) moves `/var/lib/dpkg` to `/usr/lib/sysimage/dpkg` and leaves a
RELATIVE symlink (`../../usr/lib/sysimage/dpkg`) in its place, BEFORE the
audit runs. `mkosi`'s own package-manifest generation
(`manifest.record_packages()` → `dpkg-query --admindir=$BUILDROOT/var/lib/
dpkg`) runs earlier in the build, before any `FinalizeScripts` execute, so
the relocation never affects the generated package manifest. A matching
native-only tmpfiles rule, `shared/outformat/ab-root/tree/usr/lib/
tmpfiles.d/00-snosi-dpkg.conf`, recreates the same symlink on a fresh
installer-created `/var`. **The `00-` filename prefix is load-bearing**:
apt's own shipped tmpfiles rule (`apt.conf`) also creates `/var/lib/dpkg` as
a plain directory, and `tmpfiles.d(5)` resolves same-path conflicts across
files by lexicographic filename order (earliest-named file's line wins,
the rest are logged as harmless "duplicate" errors, not a boot failure —
verified locally with `systemd-tmpfiles --create --root=<scratch>`);
renaming this file changes which one wins. bootc images (`cayo`, `snow`,
`snowfield`) are unaffected: the relocation only runs when
`/usr/lib/snosi/native-ab` exists, so their real `/var/lib/dpkg` ships
unchanged, same as before this change — verified directly on a built
`snow` image (`var/lib/dpkg` is a real, populated directory there, not a
symlink). This is also why the outcome maps need a single `lib/dpkg*`
glob rather than separate exact/subtree globs: the SAME map file classifies
both the native relocation-symlink shape and the bootc real-directory
shape, in different builds.

**Compiled aspell dictionaries get the identical treatment** (same
native-gated finalize block): `/var/lib/aspell/*.rws` are generated by the
`aspell-autobuildhash` dpkg trigger at package-configure time, are NOT
dpkg-tracked (confirmed via `dpkg -L aspell-en`, which lists only the
static `/usr/lib/aspell/*.alias` files), and are reached at runtime through
ABSOLUTE `/usr/lib/aspell/<dict>.rws -> /var/lib/aspell/<dict>.rws`
symlinks in aspell's dict-dir — on a fresh installer-created `/var` those
symlinks dangled and spell-checking silently lost every dictionary (the
audit's original flagged gap). The trigger never reruns on a booted
immutable image, so the dictionaries belong to the immutable root:
`/var/lib/aspell` is relocated to `/usr/lib/sysimage/aspell` with the same
relative symlink left behind, and `shared/outformat/ab-root/tree/usr/lib/
tmpfiles.d/00-snosi-aspell.conf` recreates the symlink on a fresh `/var`
(the `00-` prefix beats the base image's own `aspell.conf` directory rule,
exactly like `00-snosi-dpkg.conf` vs `apt.conf`). The relocation runs even
where the directory is empty (`cayo` — aspell/aspell-en are snow-only
packages) so every native product ships one shape and the shared tmpfiles
rule never dangles; both maps classify it `lib/aspell*	image-metadata`
with the same dual-shape bare-`*` glob as dpkg.

`test/native-ab-components-test.sh`'s "Step 1.5: factory /var" block
verifies all of this on a booted native image: the dpkg and aspell
symlinks' exact targets, `/usr/lib/sysimage/aspell` present, `dpkg-query -W
systemd`/`dpkg-query -W 'linux-image-*'` both resolving,
`usr/share/snosi/var-inventory.txt` present with at least one
`image-metadata` line including `/var/lib/aspell`, and no new failed
units.

### Sysext Constraints

Sysexts can ONLY provide files under `/usr`. They cannot modify `/etc` or `/var` at runtime. Configs needed in `/etc` must be:

1. Captured to `/usr/share/factory/etc` during build (via `mkosi.finalize`) — capture ONLY the specific paths the sysext's tmpfiles rules reference, never all of `/etc` (the buildroot `/etc` is the merged base view; a full capture ships `/etc/shadow` and SSH host keys in the published sysext)
2. Injected at boot via systemd-tmpfiles

Every sysext must have matching `<name>.transfer` and `<name>.feature` files in their own component directory, `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.<name>.d/`. The `.transfer` file defines how systemd-sysupdate downloads the sysext; the `.feature` file provides metadata and defaults to `Enabled=false`. Use an existing component directory as a template. **Do not add sysext transfer/feature files to the shared `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/` target** — that directory is reserved for native-profile OS transfers only (see "Native A/B Prototype" below); systemd-sysupdate version-locks every enabled transfer sharing one definitions directory, so mixing sysext package versions into the OS transfer's directory would corrupt OS version resolution. **Release-ordering constraint:** this per-component layout requires component discovery support in `frostyard-updex` (landed upstream on branch `feat/sysupdate-components`); do not publish base images built after this migration until a frostyard-updex release with component discovery is available in the Frostyard APT repo — an older updex cannot discover component-scoped sysexts and every sysext update would silently stop being offered.

**Service activation in sysexts:** Do NOT rely on `WantedBy=multi-user.target` + preset alone. At boot, the sysext is not yet merged when PID 1 scans units — the `.wants/` symlink is dangling and silently dropped. Always ship a `usr/lib/systemd/system/multi-user.target.d/10-<name>.conf` drop-in inside the sysext with `[Unit]\nUpholds=<name>.service`. This drop-in is new to systemd after the post-merge daemon-reload, so activation fires correctly. The preset is still required for enabled state; the drop-in handles timing.

**Desktop applications in sysexts (icon visibility):** GTK, GNOME Shell (St), and Qt treat a present `/usr/share/icons/hicolor/icon-theme.cache` as an authoritative index whenever its mtime is >= the theme directory's mtime. Sysexts merge icons with upstream file timestamps (older than the image build), so an image-shipped cache stays "valid" and every sysext icon is invisible — the app shows GNOME's generic gear icon (root-caused 2026-07-07 on the emdash sysext). Fix, both halves mandatory: (1) the profile-image finalize (`shared/outformat/image/finalize/mkosi.finalize.chroot`) deletes the hicolor cache so GTK falls back to scanning the theme directories; (2) every sysext includes `shared/sysext/finalize/sysext-strip-icon-cache.sh` in `FinalizeScripts=` so a gtk-update-icon-cache dpkg trigger firing during the sysext build cannot smuggle a cache into the delta — a sysext-shipped cache shadows the (absent) base cache for the whole merged `/usr` and re-masks other sysexts' and newer base icons. Externally-built sysexts (other repos) must strip the cache too. Icons in `/usr/share/pixmaps` (e.g. VS Code's) are unaffected either way — unthemed fallback dirs are always scanned, never cached. Icons appear at the next session start; an already-running GNOME Shell may not notice a merge until re-login. Full pattern: `yeti/sysexts.md` "Desktop Applications in Sysexts".

The shared sysext postoutput script (`shared/sysext/postoutput/sysext-postoutput.sh`) handles versioned naming and manifest processing. It requires the `KEYPACKAGE` env var set in each sysext's `mkosi.conf`. If `SYSEXT_REVISION` is also set, the version gets a `+rN` suffix — bump this to force a republish of tree/content fixes when the KEYPACKAGE version hasn't changed (publishing skips existing filenames via `skip-duplicates`, so tree fixes otherwise never reach users; remove the setting when the package version bumps). Every sysext must also ship `mkosi.images/<name>/required-paths.txt` (one absolute path per line); the shared finalize check (`shared/sysext/finalize/sysext-required-paths.sh`) fails the build if any listed path is missing from the buildroot — guard against publishing structurally broken sysexts (the 2026-07-01 incus publish shipped with no incusd/CLI/units and nothing noticed). For `Overlay=yes` images the finalize `$BUILDROOT` is the sysext DELTA (upper layer), so list only paths the sysext itself ships — packages also present in the base image never appear in the delta and will always fail the check.

## Key Directories

- `shared/download/` - Verified download system: `sysext-checksums.json` pins direct downloads consumed by sysexts, `image-checksums.json` pins direct downloads consumed by OCI profile builds, `package-versions.json` tracks external APT package version sentinels for sysexts, and `verified-download.sh` provides the `verified_download()` helper
- `shared/kernel/` - Kernel configs (backports, surface, stock) and dracut scripts
- `shared/packages/` - Package set definitions, some with postinstall scripts for relocation
- `shared/outformat/image/` - Image output format config (directory), finalize scripts, `buildah-package.sh` (OCI packaging), and `chunkah-package.sh` (CI re-chunks the OCI image for efficient delta updates)
- `shared/sysext/postoutput/` - Shared sysext postoutput logic
- `mkosi.sandbox/etc/apt/` - External APT repo configs (Docker, Incus, linux-surface, Frostyard)

## Shell Script Conventions

- Use `set -euo pipefail` at the top of all scripts
- Build scripts running in chroot use `.chroot` extension
- External direct downloads must go through `verified_download()` with entries in `sysext-checksums.json` for sysext consumers or `image-checksums.json` for OCI profile consumers
- Pin external URLs to specific versions/commits, never `latest` or branch names
- When adding a new verified download, also add a corresponding update check to `.github/workflows/check-dependencies.yml`; sysext APT package sentinels go in `.github/workflows/check-packages.yml`

## User Service Enablement in Chroot

`systemctl --user enable` does not work inside a mkosi chroot (no user session/D-Bus). System services are enabled via `systemctl enable` in `snow.postinst.chroot`, but user services require manually creating symlinks:

```bash
mkdir -p /etc/systemd/user/<target>.wants
ln -sf /usr/lib/systemd/user/<service> /etc/systemd/user/<target>.wants/<service>
```

The target (e.g. `gnome-session.target`) comes from the service's `WantedBy=` in its `[Install]` section.

**Known issue:** `deb-systemd-helper` creates `.dsh-also` tracking files in `/var/lib/systemd/deb-systemd-user-helper-enabled/` during the build but may not create the actual enablement symlinks in `/etc/systemd/user/`. If a user service isn't auto-starting after reboot, check whether its symlink is missing from `/etc/systemd/user/<target>.wants/` and compare against its `.dsh-also` file. A full sweep on 2026-07-01 found only two affected units, both resolved deliberately: `gnome-remote-desktop-headless` (removed — conflicts with the non-headless variant) and `rygel` (kept off — tracking removed in `snow.postinst.chroot`). Re-run the comparison when adding packages that ship user services.

## CI/CD

- `build.yml` - Builds base + sysexts, publishes to Frostyard repo (Cloudflare R2)
- `build-images.yml` - Matrix build of 3 profiles (2 desktop + 1 server), resetting mkosi dependencies to `base` so sysexts are not rebuilt per profile. Pushes OCI to ghcr.io, generates SBOMs (Syft), attaches via ORAS, signs with Cosign (public key committed at `cosign.pub`; `test-install.yml` verifies it before tests). A non-blocking `release` job runs after the matrix on main-branch pushes and creates a GitHub Release whose body is a changelog generated by `frostyard/changelog-generator` diffing the new `snow` image against the previously published one.
- `check-dependencies.yml` - Weekly check for external dependency updates, creates PRs with updated checksums. Version-based checks are downgrade-guarded (`ver_gt`, sort -V strictly-newer) — coder deliberately tracks its stable channel (GitHub "latest"), whose version numbers run behind mainline
- `check-packages.yml` - Daily check for APT package version updates, creates PRs
- `validate.yml` - shellcheck + runtime-/etc-guard (`check-runtime-etc-guard.sh`) + native A/B static/contracts/publication-guard checks + mkosi summary validation on PRs
- `test-install.yml` - Manual bootc installation test in QEMU/KVM
- `scorecard.yml` - Weekly OpenSSF supply-chain security analysis
## Documentation

**update documentation** After any change to source code, update relevant documentation in CLAUDE.md, README.md and the yeti/ folder. A task is not complete without reviewing and updating relevant documentation.

**yeti/ directory** The `yeti/` directory contains documentation written for AI consumption and context enhancement, not primarily for humans. Jobs like `doc-maintainer` and `issue-worker` instruct the AI to read `yeti/OVERVIEW.md` and related files for codebase context before performing tasks. Write content in this directory to be maximally useful to an AI agent understanding the codebase — detailed architecture, patterns, and decision rationale rather than user-facing guides.
