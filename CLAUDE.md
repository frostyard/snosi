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

### Native A/B Update UX (Phase 4)

Native A/B images (`/usr/lib/snosi/native-ab` marker) never run bootc/nbc.
`/usr/libexec/snosi-sysupdate-stage` (system service+timer, `shared/outformat/ab-root/tree`) is the native analog of `bootc-update-stage`: it runs `systemd-sysupdate check-new` against the image's DEFAULT sysupdate target (`/usr/lib/sysupdate.d/`, no `--definitions=`), and if newer, `systemd-sysupdate update <version>` (installs into the inactive root/verity slots only), then independently re-verifies the result — re-fetches `SHA256SUMS` and confirms the newly-labeled partitions' PARTUUIDs match the embedded UUIDs, and confirms the matching UKI exists in the ESP (ordering proxy: sysupdate applies transfers 10/20/90 in order, so a present UKI implies the partition transfers already landed) — failing loudly (`outcome=failed`) if either check disagrees. The PARTUUID read is `udevadm settle` plus a bounded retry loop, not a single `lsblk` call: lsblk reads udev's property db, which refreshes ASYNCHRONOUSLY after sysupdate's GPT writes, and an immediate read can see a mixed stale view (observed live 2026-07-15 in the full-window QEMU run: the reused slot showed its new label with the old pre-vacuum PARTUUID while the on-disk GPT was provably correct — the next boot and the next hop's identical check both passed); `udevadm settle` alone is insufficient because it returns early when udev's watch event has not been synthesized yet. A real mismatch still fails identically once retries are exhausted. It never reboots. Speaks the exact same `/run/snosi/update-check` and `/run/snosi/update-staged` state-file language as the bootc stager (same field names: `outcome=`, `checked_at=`, `running_version=`, `remote_version=`), so the shared consumers below work unmodified — with one deliberate schema extension: `/run/snosi/update-staged` carries `version=<14-digit>` on native instead of bootc's `digest=sha256:...` (exactly one of the two is ever present on a given image), and every shared consumer (`/etc/update-motd.d/86-bootc-update-staged`, `/usr/libexec/bootc-update-notify`) now keys off whichever is present rather than hardcoding `digest=`.

**No native `held-rollback`, deliberately:** bootc's `held-rollback` outcome exists because ostree tracks an explicit separate rollback-deployment pointer that a re-pull of an unchanged registry tag can collide with. `systemd-sysupdate`'s `InstancesMax=2` accounting has no equivalent separate pointer — it treats BOTH on-disk root slots as "installed" when deciding what counts as newer, so a version already sitting in either slot (including one the admin just rolled away from) is never re-offered by `check-new` in the first place; there is nothing to hold. The one real adjacent case — a version already downloaded into the inactive slot by an earlier run this boot, waiting for reboot — is handled as an explicit "already staged" re-assertion branch instead (see the script's own header for the full reasoning).

**Three stager hardening rules, all root-caused live in the first QEMU run of `test/native-ab-updateux-test.sh`:** (1) capture `check-new` STDOUT ONLY — its progress lines ("Discovering installed instances…") are stderr log output, and capturing `2>&1` splices them into the version string (`update '<five lines of progress>' not found`); the parsed candidate is also validated against the frozen `^[0-9]{14}$` grammar. (2) `check-new`'s non-zero exit collapses "nothing newer" and every genuine failure into one code — the stager disambiguates with an independent probe (curl `SHA256SUMS`+`.gpg`, `gpgv` against the effective pubring): probe passes → `outcome=current` is the truth; probe fails → `outcome=failed`, never a fake "up to date". (3) a candidate NOT newer than the running version is reported `current`, never staged — kept as belt-and-suspenders even after the build-time UKI naming gap below was closed. Related: never exclude the booted slot from partition enumeration by comparing against `findmnt -o SOURCE /` — a dm-verity root mounts from `/dev/mapper/root`, never the partition path, so exclude by the running version's LABEL instead (`<ImageId>_<version>_r`); this bit both the stager and `snosi-update-status`'s rollback-slot lookup.

**Factory UKI naming aligned with the sysupdate transfer:** mkosi's own default UKI name is `&e-&k-&h` (entry-token-kernelversion-roothash, e.g. `cayo-7.0.13+deb13-amd64-<hash>.efi`), which never matched the channel transfer's `Target MatchPattern` (`<channel>_@v...efi`) — sysupdate's installed-version accounting (`list`/`pending`/vacuum/`InstancesMax`) never saw the factory-shipped UKI, and systemd-boot carried it forever as a third, unmanaged menu entry no update ever superseded. Fixed via `shared/outformat/ab-root/mkosi.conf`'s `UnifiedKernelImageFormat=&e` plus `shared/outformat/ab-root/finalize/mkosi.finalize.chroot` writing `/etc/kernel/entry-token` to `<channel>_<version>` (channel = `<ImageId>-ab`, version = `$IMAGE_VERSION`, both exported into `FinalizeScripts=` by mkosi) — `find_entry_token()` resolves `&e` via `kernel-install inspect`, which reads `/etc/kernel/entry-token` when present (`kernel-install(8)`, "auto" entry-token mode, the default). This has to happen in the buildroot's `/etc` before repart, not a `PostOutputScripts=` rename: mkosi's `install_kernel()` (which actually builds the UKI) runs strictly AFTER all `FinalizeScripts=` but BEFORE `make_disk()` formats the ESP partition from the buildroot's `/boot` (`.mkosi/mkosi/__init__.py` `build_image()`), and by the time `PostOutputScripts=` run the ESP has already been formatted into the disk image with no loop-device/mount access available in mkosi's script sandbox to edit a FAT filesystem in place. The write lands in the *fresh* post-mv `/etc` (this finalize script's first act renames the real `/etc` to `/.etc.lower` for the persistent overlay), not `/.etc.lower` — nothing at runtime ever re-reads `/etc/kernel/entry-token` on a booted dm-verity read-only root, so it only needs to exist on disk for mkosi's own build-time `kernel-install inspect` call. Verified empirically (`test/native-ab-updateux-test.sh` Step 1): a freshly-built N boots with `/boot/EFI/Linux/<channel>_<version>.efi` and `systemd-sysupdate list` reports the factory version as already installed without ever running the stager.

**Origin override for testing:** `sysupdate.d(5)` has no `NAME.transfer.d/` per-key drop-in mechanism (confirmed against upstream docs) — only whole-file override by identical filename, same precedence as `tmpfiles.d`/`sysctl.d` (`/etc` over `/usr/lib`). `test/native-ab-updateux-test.sh` drops complete replacement `*.transfer` files into `/etc/sysupdate.d/`, byte-identical to the shipped channel transfers except `[Source] Path=`, to redirect at a local HTTP fixture origin — the stager itself never reads an origin URL, so production and the test exercise the identical code path. The test also overrides the trust root the same way updates already do (`/etc/systemd/import-pubring.gpg` takes precedence over the shipped `/usr/lib/systemd/import-pubring.gpg` DEV key) — the shipped default is never weakened.

**Desktop notification:** native ships parallel, native-named user units `snosi-update-notify.path`/`.service` (`shared/outformat/ab-root/tree`, masked bootc-named units stay masked) with a static `graphical-session.target.wants/` link (unconditional — a passive watcher is harmless even when nothing is ever staged). Both unit pairs `ExecStart=` the SAME `/usr/libexec/bootc-update-notify` script — no duplicated notification logic between transports.

**`snosi-update-status`** dispatches on the native marker before ever touching the `bootc` CLI (which isn't installed on native images — calling it would hard-fail). The native backend adds: `systemd-sysupdate pending` (authoritative "is a newer version already installed" signal, independent of the possibly-stale `/run` semaphore), `systemd-bless-boot status` (good/bad/indeterminate/clean), and the other root slot's version (rollback candidate, via `lsblk`/`jq`). `--check` fetches `SHA256SUMS`+`SHA256SUMS.gpg` from the R2 index and verifies with `gpgv --keyring /usr/lib/systemd/import-pubring.gpg` before trusting any version it lists — same never-trust-an-unverified-index posture as the stager.

**Activation policy — inert by default:** `snosi-sysupdate-stage.timer` ships with NO `[Install]` section (static-link activation only, per the infra-unit pattern above) and, in every build today, with NO wants-link either — `systemctl is-enabled` reports `static`, nothing ever starts it. `shared/outformat/ab-root/finalize/mkosi.finalize.chroot` creates the static `/usr/lib/systemd/system/timers.target.wants/snosi-sysupdate-stage.timer` link ONLY when `SNOSI_NATIVE_AUTOSTAGE=1` is set in the build environment (forwarded into the finalize `.chroot` script via `Environment=SNOSI_NATIVE_AUTOSTAGE` under `shared/outformat/ab-root/mkosi.conf`'s `[Build]` — `mkosi.1`: `Environment=` with a bare name passes through the host env var to prepare/build/postinstall/finalize scripts). This is a static link, not a preset, for the same reason as every other snosi infra unit: an already-installed image whose first boot predates a publication-enabled release would never pick up a brand-new preset-only enablement, but a static link ships correctly with the very update that introduces it — verified end to end by `test/native-ab-updateux-test.sh` (boots a publication-disabled N, stages a publication-enabled N+1 built with `SNOSI_NATIVE_AUTOSTAGE=1`, reboots, and asserts the timer is ACTIVE post-reboot: the Phase 4 exit criterion). Independent of this knob, `systemd-sysupdate.timer`/`-reboot.timer` (upstream) stay masked in `/etc` unconditionally (`shared/outformat/image/finalize/mkosi.finalize.chroot`) — our stager replaces upstream's fetch+apply+immediate-reboot behavior permanently, publication-enabled or not.

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

**Automated Secure Boot + TPM + desktop validation (Phase 5,
`test/native-ab-secure-boot-test.sh`):** proves the whole secure chain in
QEMU with no MokManager interaction — `virt-fw-vars --add-mok` pre-enrolls
the Snosi MOK into a copy of `OVMF_VARS_4M.ms.fd` (Microsoft keys already
enrolled ⇒ Secure Boot enforced), paired with `OVMF_CODE_4M.secboot.fd` and
an attached swtpm TPM2 device. Installs a real build via
`cayo-ab-install-spike.sh --allow-file --encrypt-var` (no
`--mok-certificate`: that flag drives `mokutil --import` against the
*host's* live EFI variable store, which is wrong for a loopback install —
MOK enrollment happens entirely on the guest's OVMF varstore instead), types
the first-boot recovery passphrase on the serial console automatically (no
expect/socat on this host; a single Python process both logs and drives the
console — two separate connections to one `server=on,wait=off` QEMU chardev
socket do not both work, confirmed live), enrolls a signed-PCR-11 TPM token
in-guest exactly like `native-ab-secure-rotation-test.sh`'s `enroll_token`,
and proves unattended TPM auto-unlock survives a real signed update hop to a
new UKI. QEMU's `-tpmdev emulator` chardev must point at swtpm's `--ctrl`
socket, not `--server` — `--server` hangs QEMU at startup indefinitely (this
and other bugs found while building the harness are recorded in the test's
own comments). Requires `swtpm`/`swtpm-tools` and `virt-fw-vars`
(`virt-firmware` PyPI package); on a snosi dev host itself (read-only `/usr`
sysext overlay, no `apt-get install`), install both via Homebrew/`pip3
install --user`, and resolve `$SUDO_USER`'s real home for `PATH`/`HOME` since
plain `sudo` resets `$HOME` to `/root` (breaks `pip --user` site-packages
resolution). **`--full-window` is the Phase 5 exit-criterion mode** (default
mode unchanged without the flag): four real builds, N→N+1→N+2→N+3 secure
hops with exact `InstancesMax=2` slot accounting (root-label set exactly
{N+1,N+2} then {N+2,N+3}, each new version physically reusing the vacuumed
slot), explicit rollback via `bootctl set-oneshot` and return to default,
and boot-count fallback: N+3 re-armed to `+3-0`, its root corrupted from
the HOST while the VM is off, three power-cycles observed decrementing
`+2-1`/`+1-2`/`+0-3` via host-side read-only ESP loop-mounts between
cycles, fourth boot auto-selects N+2 under SB with TPM unlock and intact
state. swtpm terminates whenever its QEMU client exits, so each host-side
power-cycle re-arms swtpm against the SAME persistent `--tpmstate` dir
(never reinitialize it — the enrolled token's sealed state lives there);
guest-initiated reboots never hit this because QEMU stays alive. Phase 5
exit evidence: 120/120 assertions green (2026-07-15, snow-ab,
N=20260715042306 → N+3=20260715044206, fallback to N+2). NvPCR journal
errors are asserted PER BOOT (shared `assert_nvpcr_journal_clean` helper
called after every boot that reaches SSH — `journalctl -b` only sees the
current boot, so the earlier end-of-sequence-only checks silently missed
every boot before the last one), raising the totals to 58 (default mode) /
125 (`--full-window`); re-validated green 125/125 (2026-07-15, snow-ab,
N=20260715074012 → N+3=20260715075918, rollback and fallback to N+2).

**`snow-linux-live-setup.service` native-boot decision:** this unit's only
gate used to be a negative run-once marker
(`ConditionPathExists=!/var/lib/snow-linux-live-setup.done`), indistinguishable
from a freshly installed native A/B system's true first boot (fresh `/var`,
marker absent) — an unpatched native install would have created a
passwordless sudo `snow` user on first boot. Fixed by adding
`ConditionKernelCommandLine=snow-linux.live=1`, the same positive live-media
signal `docker.socket.d/override.conf`, `incus.socket.d/override.conf`, and
`brew-setup.service` already use (inverted: `!snow-linux.live=1`, since those
skip themselves on live media — `snow-linux-live-setup.service` is the
inverse case, it must run ONLY on live media). Decision: native Snow does
**not** get its own first-setup flow reusing this unit; a real installed
system simply never sets `snow-linux.live=1` and this unit correctly never
fires. `test/native-ab-secure-boot-test.sh` asserts the unit is
`ActiveState=inactive` with `ConditionResult=no` (not failed) on a fresh
native install, and that no `snow` user exists.

**Secure Snowfield: Surface module-trust decision + lockdown fix (Phase 6):**
`snowfield-ab` runs through the same `test/native-ab-secure-boot-test.sh`
harness as `snow-ab` (`PROFILE=snowfield-ab`; `IMAGE_ID` derives to
`snowfield`, which already routed it through the `HAS_DESKTOP` gate before
Phase 6). Two new pieces of coverage, both gated on `IMAGE_ID == snowfield`:

- `test/snowfield-artifact-test.sh` (new script, invoked by the harness
  right after the existing profile-neutral `native-ab-secure-artifact-test.sh`)
  proves, against a real built profile: the manifest contains every package
  parsed live out of `shared/kernel/surface/mkosi.conf` (39 packages) and no
  `linux-image-amd64`; the UKI's `.linux` section decodes (via `file`) to a
  `bzImage` whose embedded version string contains `-surface`;
  `/usr/lib/modules/<surface-kver>` exists in the root erofs artifact;
  firmware completeness is spot-checked by querying each firmware-carrying
  package's OWN dpkg file list (via `dpkg-query --admindir=<mounted
  root>/usr/lib/sysimage/dpkg`, the relocated in-artifact dpkg database) and
  confirming those exact paths exist on disk — not a hardcoded guess (real
  finding: `firmware-iwlwifi`'s ucode ships FLAT under
  `/usr/lib/firmware/iwlwifi-*.ucode`, no subdirectory); the UKI's initrd
  (extracted via `objcopy --dump-section .initrd=`) carries
  `dm-verity.ko`/`dm-crypt.ko`, the `tpm2-tss` dracut module +
  `libtss2-esys.so`, the `etc-overlay` dracut module, `erofs.ko`,
  `nvme.ko`/`usb-storage.ko`, dracut's own `qemu` module, and the Surface
  early-boot family (`surface_aggregator`, `surface_aggregator_registry`,
  `intel-lpss`, `intel-lpss-pci`, `8250_dw`, `hid-surface`, `surface_hid`,
  `surface_hid_core`, `surface_kbd`). **The harness's own flagged risk of
  "missing virtio in the surface kernel initrd" did not materialize:**
  dracut's `--no-hostonly` module selection (unmodified, pre-existing)
  already includes a `qemu` dracut module plus `virtio-gpu`/`virtio-rng`/
  `virtiofs`/etc. as loadable `.ko` files; the disk/net/PCI virtio drivers
  (`virtio_blk`/`virtio_scsi`/`virtio_pci`/`virtio_net`) don't appear as
  separate `.ko` files at all because this kernel's `.config` compiles them
  DIRECTLY INTO vmlinuz (confirmed against `modules.builtin`, alongside
  `ext4`, `vfat`, `dm-mod`, `tpm_tis`, `tpm_crb`, `xhci-hcd`, `xhci-pci`) —
  builtin beats "present in the initrd" for guaranteed early availability.
- A new "Step 3c" in the harness itself, run on first boot right after the
  existing (profile-neutral) lockdown assertion: `keyctl show
  %:.builtin_trusted_keys` holds an `asymmetric` module-signing key — and,
  strengthened in the Phase 6 review follow-up (2026-07-15), the SPECIFIC
  signing certificate is bound end-to-end: the harness extracts the
  embedded build-time certificate from the booted UKI's `.linux` payload
  host-side and asserts the guest module's `modinfo -F sig_key` equals the
  cert's SERIAL and the keyring entry's trailing hex equals the cert's
  SKID. Those are two structurally DIFFERENT identifiers (`sig_key` is the
  module PKCS#7 signerInfo's issuer+serial reference; the keyring
  description hex is the certificate's Subject Key Identifier), so naively
  grepping `sig_key` in `keyctl` output can never match — measured live on
  a snosi host (backports kernel), the snow-ab UKI, and the Surface
  vmlinuz, all three of which validated the extraction + both equalities;
  `isofs.ko` (a hardware-free filesystem module) and `surface_aggregator.ko`
  (a genuine Surface in-tree module) both report `modinfo -F signer` =
  "Build time autogenerated kernel key" with the SAME `sig_key` fingerprint
  (now asserted at fingerprint level, not just signer-CN level),
  and both load successfully; a trivial out-of-tree module built IN-GUEST
  against `linux-headers-surface` (gcc/make are present in the built image —
  base's own `Packages=` "Utilities" stanza; confirmed by mounting the
  built root artifact directly, since the profile's own `.manifest` JSON
  only lists packages installed at the PROFILE stage, not ones inherited
  from `base`, so `gcc`/`make` genuinely don't appear there despite being
  in the final rootfs) is genuinely unsigned and is REJECTED
  (`insmod: ERROR: could not insert module ...: Key was rejected by
  service`, `dmesg`: `Loading of unsigned module is rejected`).

**Decision (docs/native-ab-contracts.md §7 has the full writeup):**
in-tree Surface kernel modules do NOT need re-signing with the Secure
Boot/MOK key, and no second (linux-surface-authored) certificate needs
enrollment. `CONFIG_MODULE_SIG_ALL=y` signs every in-tree module — core and
Surface alike — with the kernel package's own per-build ephemeral key, and
that key is in the booted guest's builtin trusted keyring. Phase 8's
installer does not need a Surface-specific enrollment step. Re-run this
decision if the Surface kernel package ever changes to a differently-signed
or externally-supplied build.

**A real bug found and fixed while investigating (unrelated to the
module-trust decision itself, but found by the same first-boot lockdown
assertion the harness already runs unconditionally):** the very first
`snowfield-ab` run through this harness FAILED the pre-existing,
profile-neutral "kernel lockdown is in integrity or confidentiality mode"
assertion — `/sys/kernel/security/lockdown` read `[none] integrity
confidentiality` under fully enforced Secure Boot with a Measured,
MOK-signed UKI chain (64/65 assertions passed; only this one failed).
Root cause, confirmed via the `.config` shipped with `linux-headers-surface`
inside the built root artifact: `CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y`, and
a full grep of that same `.config` for `SECURE_BOOT`/`LOCK_DOWN` found no
build-time "raise lockdown when EFI Secure Boot is on" wiring at all —
concretely, `grep -n 'LOCK_DOWN\|SECURITY_LOCKDOWN' boot/config-6.19.8-surface-3`
against the cached `linux-image-6.19.8-surface-3` deb shows
`CONFIG_SECURITY_LOCKDOWN_LSM=y`, `CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y`,
`CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y`, and
`# CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY is not set` — but no
`CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT` line at all (not even as a commented-out
"is not set" — that symbol is a Debian/Ubuntu patch, not mainline, so its total
absence means the linux-surface source tree does not carry the SB→lockdown patch
at all) — unlike the backports kernel `cayo-ab`/`snow-ab` use, which evidently DOES
carry that wiring (Phase 5 never saw this). A related discovery while
diagnosing it: module-signature enforcement was NOT actually broken by
this — the unsigned test module in Step 3c was rejected even while lockdown
sat at `none`, meaning module-signing enforcement on this kernel is wired
directly to EFI Secure Boot detection independent of the Lockdown LSM's
reported level (`CONFIG_MODULE_SIG_FORCE` is also not set, ruling out that
mechanism) — but lockdown's OTHER protections (kexec restriction,
`/dev/mem`, debugfs, BPF, hibernation) were genuinely inactive, a real gap
distinct from (but adjacent to) the module-trust question. **Fix:** added
`KernelCommandLine=lockdown=integrity` to the SHARED secure fragment
(`shared/native-ab-secure/mkosi.conf`), not the generic `ab-root` fragment
(`cayo-ab-raw`, the never-signed dev fixture, also consumes `ab-root` and
must not have lockdown forced on it). `lockdown=` is a standard
`early_param` that only RAISES the compiled initial level
(`lock_kernel_down()` only takes effect when the requested level is
stricter), so this is a safe, idempotent floor for `cayo-ab`/`snow-ab` too —
their lockdown posture no longer depends on an accident of the backports
kernel's own Kconfig defaults, which the Surface kernel simply doesn't
share. Confirmed present in the rebuilt UKI's `.cmdline` PE section via
`objcopy --dump-section`. Rebuilding with the fix and re-running the full
harness turned the `dmesg` boot log's "Lockdown: systemd-logind:
hibernation is restricted" line from absent to present — direct evidence
the broader lockdown protections are now actually active, not just the
module-signing path that was already working by a separate mechanism.
**User-visible consequence, not just a security win:** `lockdown=integrity`
(and `confidentiality`) unconditionally blocks hibernation (S4) on ALL
three production profiles now carrying the explicit `KernelCommandLine=`,
including the snowfield laptop profile where hibernation is a real,
previously-working end-user feature — this is an intentional, accepted
trade-off of closing the lockdown gap, not an oversight. Suspend/resume
(S3) is unaffected by lockdown and must keep working. See the PENDING HUMAN
GATE checklist below, which now requires confirming S4 fails gracefully
(no crash/hang) on real hardware rather than expecting it to succeed.

**VM validation result:** `sudo PROFILE=snowfield-ab
test/native-ab-secure-boot-test.sh` (default mode, no `--full-window` —
see "PENDING HUMAN GATE" below for why) passed with the lockdown fix in
place: install, first boot under enforced SB, TPM enrollment/auto-unlock,
desktop assertions (`graphical.target`/`gdm.service`, the hicolor
icon-cache sysext fixture), Step 3c module-trust, and a full signed
N→N+1 secure update hop with `/var`+`/etc` persistence and rollback-entry
retention. `--full-window` (the complete N..N+3 + rollback +
boot-count-fallback window) was deliberately NOT run for snowfield in
Phase 6 — see `docs/native-ab-capacities.md` "PROVISIONAL-pending-hardware"
for why a second QEMU-only pass wasn't worth it ahead of the mandatory
hardware gate below.

**Empirical re-proof on a second consumer of the shared fragment
(2026-07-15, Phase 6 review follow-up):** `sudo PROFILE=cayo-ab
test/native-ab-secure-boot-test.sh` (default mode) — the FIRST-ever run of
this live-boot harness for the server profile — passed 47/47. This proves
(1) the backports kernel tolerates the explicit `lockdown=integrity` now on
the shared secure fragment (that kernel's own SB→lockdown wiring and the
explicit parameter coexist; the harness's unconditional lockdown assertion
read `none [integrity] confidentiality`), and (2) the `HAS_DESKTOP` gating
behaves for cayo (Step 5a/5b desktop assertions correctly skipped). The run
also root-caused a real server-profile difference in the harness itself:
cayo's initrd carries no plymouth, so the first-boot passphrase prompt is
systemd's raw TTY agent shape ending in `(press TAB for no echo)` + ANSI
reset AFTER the colon, which the console pump's original colon-at-end-of-
buffer regex could never match (first boot wedged until the SSH timeout);
the pump's prompt matcher now accepts both shapes (see `prompt_re` in
`test/native-ab-secure-boot-test.sh`).

**PENDING HUMAN GATE — representative Surface hardware validation:** QEMU
has no Surface-specific hardware (touch, pen, keyboard/cover, Surface
storage/network/power controllers), so everything above validates the
Secure Boot/TPM/lockdown/module-trust chain and the generic OS mechanics
only. The plan's actual Phase 6 exit criterion — "representative Surface
hardware passes installation, desktop boot, update, rollback, and fallback
with required modules loaded" — is out of scope for this machine and is a
checklist for the user to run on real Surface hardware:

1. Build and validate artifacts locally first (fast, no hardware needed):
   `just snowfield-ab` (or `mkosi --profile snowfield-ab build`), then
   `sudo test/snowfield-artifact-test.sh` and
   `OUTPUT_NAME=snowfield-ab test/native-ab-secure-artifact-test.sh ...
   single` (see `test/native-ab-secure-boot-test.sh`'s own invocation for
   the exact argument list).
2. Full QEMU regression before touching hardware:
   `sudo PROFILE=snowfield-ab test/native-ab-secure-boot-test.sh
   --full-window` — this has NOT been run for snowfield yet (Phase 6
   deliberately skipped it; see above) and should be green before spending
   hardware time.
3. On the real Surface device: enroll the Snosi MOK certificate
   (`mkosi.crt`) via MokManager during a signed-shim boot of installer
   media (see "Installer ISO boot chain",
   `docs/native-ab-contracts.md` §8 — the Phase 8 ISO does not exist yet;
   until then, use whatever interim installer media Phase 6/7's state
   provides), then run the installer against the real disk (mirror
   `test/cayo-ab-install-spike.sh`'s non-`--allow-file` real-device path,
   `--encrypt-var --recovery-key-file <path outside the disk>`).
4. Verify TPM enrollment (`systemd-cryptenroll --unlock-key-file=<recovery
   key path> --tpm2-device=auto --tpm2-pcrs= --tpm2-pcrlock=
   --tpm2-public-key=.snosi-private/pcr-signing.pub
   --tpm2-public-key-pcrs=11 <var device>` — mirrors `enroll_token` in
   `test/native-ab-secure-rotation-test.sh:319` exactly, including the
   `--unlock-key-file=`/`--tpm2-pcrlock=` flags: do not drop them, they are
   required to authenticate the enrollment and to pin the policy to raw
   PCR11-off/pcrlock-off) and confirm unattended reboot auto-unlocks `/var`
   with zero prompts.
5. Confirm hardware function under the installed, Secure-Boot-enforced,
   lockdown-active kernel: touch, pen, keyboard/type-cover, Surface storage
   controller, wifi/networking, and power management all work — this is the
   one thing no QEMU run can prove. Power management specifically means:
   - Suspend/resume (S3) MUST work — lockdown does not affect S3.
   - Hibernation (S4) is EXPECTED TO BE BLOCKED by `lockdown=integrity`
     (see the lockdown-fix note above) — do not treat a hibernation failure
     as a regression. Instead confirm the block is GRACEFUL: the attempt
     (e.g. `systemctl hibernate`) fails cleanly with a logged
     "Lockdown: ...: hibernation is restricted" denial and the system
     remains usable, rather than crashing or hanging.
   - battery status reporting works.
6. Publish a real N+1 build (or use the same local-HTTP-origin pattern the
   harness uses) and confirm a signed update hop, then explicit rollback
   (`bootctl set-oneshot`) and boot-count fallback (re-arm to `+N-0`,
   corrupt the root partition, power-cycle) all work with the SAME hardware
   still functional after each transition — repeat the Step 3c module-trust
   checks post-update to confirm the decision above still holds for
   whatever kernel build ships in the update.
7. Record results (pass/fail per item above, kernel/firmware versions,
   Surface model) back into `docs/native-ab-capacities.md`'s snowfield
   section and flip it from "PROVISIONAL-pending-hardware" once every item
   passes.

**Publication and signing pipeline (Phase 7).** `shared/native-ab/publish/`
has, on top of `prepare-native-publication.sh`: `publish-candidate.sh`,
`verify-remote.sh`, `promote.sh`, `withdraw.sh`, a shared `publish-lib.sh`,
and `generate-sbom.sh` (closes the old `docs/native-ab-contracts.md` §4
`.sbom.spdx.json` gap by generating a real SPDX 2.3 JSON document directly
from mkosi's own package manifest — no `syft`, no network, no root; see the
script's header for why `syft` was investigated and rejected). Every script
takes a `dest` (`/local/dir` for rehearsal, or `rclone:<remote>:<bucket>
[/prefix]` for a real remote — see `publish-lib.sh`'s header) and, for
`verify-remote.sh`/`promote.sh`, a separate HTTP `base-url` (the public read
path — writes go through `rclone`, verification/re-signing reads back over
HTTP). `promote.sh` is the only script touching the private key
(`--signing-key <file>` imported into an ephemeral GNUPGHOME, or
`--gnupghome <existing homedir>` — never hardcoded); it re-downloads every
final object over HTTP to hash before regenerating `SHA256SUMS` (never
trusts local disk), archives the outgoing signed pair to
`.history/<version>/` before overwriting it (**only if that outgoing pair
itself still verifies against `--pubring`** — an already-broken outgoing
index is skipped rather than clobbering a good archive from an earlier
promotion; root-caused live during the Phase 7 rehearsal's own tamper-case
sequencing, see `docs/native-ab-publication.md`/the Phase 7 task report),
and publishes `SHA256SUMS.gpg` strictly before `SHA256SUMS`, both
`Cache-Control: no-store`. `withdraw.sh` `gpgv`-verifies an archived pair
against the pubring before touching anything live and refuses outright on a
missing or mismatched pair. Full operational runbook (key ceremony,
candidate->verify->promote->purge with real `rclone`/Cloudflare commands,
retention, interim protected-builder constraints):
`docs/native-ab-publication.md`. Local rehearsal, no real R2/Cloudflare:
`test/native-ab-publication-test.sh` (QEMU, needs root/KVM, builds real
`cayo-ab-raw` images — deliberately NOT `cayo-ab`, since the DEV pubring
ships on every native A/B image regardless of Secure Boot posture and this
test is about the update-signature trust path, not the boot-chain trust
path) and `test/native-publication-pipeline-test.sh` (fast, synthetic
fixture, wired into `validate.yml`). Both serve their local HTTP origin with
`test/lib/range-http-server.py`, not plain `python3 -m http.server` — the
stdlib's `SimpleHTTPRequestHandler` has no Range support at all (confirmed
against the Python 3.13 stdlib source), which would make `verify-remote.sh`'s
mandatory range-GET check silently meaningless.

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
- `build-native-images.yml` (Phase 7) - Native A/B (`cayo-ab`/`snow-ab`/`snowfield-ab`) build/publish pipeline; a thin caller of `shared/native-ab/publish/*.sh` and `shared/native-ab/ci/*.sh` — see `docs/native-ab-publication.md`'s "CI publication flow" section for the full job graph, secret inventory, and the "First production publication checklist" that must be completed before it is allowed to touch real R2. Trigger is `workflow_dispatch` + main-branch push ONLY (interim protected-builder rule: `build-*` jobs handle Secure Boot/MOK and PCR signing private keys via the protected `native-build` GitHub environment until mkosi supports split final assembly from signing; `promote-*` jobs handle the OpenPGP update-signing key via the protected `native-promotion` environment). `build-*`/`promote-*` are independent per-product jobs, not a matrix, so one product's failure never blocks another's. Production R2 upload has NOT been exercised through this workflow — only local rehearsal (`test/native-ab-publication-test.sh`, `test/native-publication-pipeline-test.sh`) and the workflow's structure (actionlint-clean, every script reference hand-verified) have been.
- `check-dependencies.yml` - Weekly check for external dependency updates, creates PRs with updated checksums. Version-based checks are downgrade-guarded (`ver_gt`, sort -V strictly-newer) — coder deliberately tracks its stable channel (GitHub "latest"), whose version numbers run behind mainline
- `check-packages.yml` - Daily check for APT package version updates, creates PRs
- `validate.yml` - shellcheck + runtime-/etc-guard (`check-runtime-etc-guard.sh`) + native A/B static/contracts/publication-guard checks + mkosi summary validation on PRs
- `test-install.yml` - Manual bootc installation test in QEMU/KVM
- `scorecard.yml` - Weekly OpenSSF supply-chain security analysis
## Documentation

**update documentation** After any change to source code, update relevant documentation in CLAUDE.md, README.md and the yeti/ folder. A task is not complete without reviewing and updating relevant documentation.

**yeti/ directory** The `yeti/` directory contains documentation written for AI consumption and context enhancement, not primarily for humans. Jobs like `doc-maintainer` and `issue-worker` instruct the AI to read `yeti/OVERVIEW.md` and related files for codebase context before performing tasks. Write content in this directory to be maximally useful to an AI agent understanding the codebase — detailed architecture, patterns, and decision rationale rather than user-facing guides.
