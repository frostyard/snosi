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
- `mkosi.profiles/` defines desktop and server image variants (snow, snowfield, cayo — the app-bundling "loaded" variants were retired 2026-07 in favor of sysexts)
- `shared/` contains reusable fragments: kernel configs, package sets, output format, scripts

Each profile composes: package sets + kernel variant + output format + build/postinstall/finalize/postoutput scripts.

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

**Drift visibility:** `snosi-etc-diff` (root CLI) diffs live `/etc` against the booted image's pristine `/etc` (bind-mounts `/` to see under the `/etc` mount — no `/usr/etc` exists on composefs), with ignore globs in `/usr/lib/snosi/etc-diff.ignore` (+ optional `/etc/snosi/etc-diff.ignore`) for expected per-machine state. Beyond the M/D/A path listing (which ends with a resolution footer), `snosi-etc-diff /etc/<path>` shows the actual difference (unified diff / symlink targets / permission lines) and `snosi-etc-diff --restore /etc/<path>` reverts a path to the image version (refuses locally-added paths — nothing to restore from). `snosi-etc-drift-report.service` writes M/D entries plus preset-policy removals to `/var/lib/snosi/etc-drift.report` each boot; a hash-gated user service (`snosi-etc-drift-notify`) raises one desktop notification per report *change* (not per boot), and `/etc/update-motd.d/85-snosi-etc-drift` surfaces it on headless logins. Keep the ignore list honest: entries that always drift (daemon-rewritten files) train users to dismiss the report.

### OS Update Staging (bootc)

On bootc-installed systems, updates are staged by `bootc-update-stage.timer` (hourly; base `mkosi.extra`): `/usr/libexec/bootc-update-stage` pulls the followed image via **podman**, then stages it with `bootc upgrade` when the spec already follows `containers-storage` (the steady state after the first staged update) or `bootc switch --transport containers-storage` otherwise — `bootc switch` to an IDENTICAL spec is a silent no-op in bootc ≤ 1.16.3 (composefs switch returns before staging when `new_spec == host.spec`), which made every install unable to take a second update while logging success (root-caused 2026-07-06). The script verifies post-stage that `.status.staged.image.imageDigest` equals the pulled digest and fails loudly otherwise. The update applies at the next natural reboot via `bootc-finalize-staged.service`. **Reboot-pending visibility:** after staging (or when finding an update already staged, e.g. via manual `bootc upgrade`), the script writes `/run/snosi/update-staged` (image/digest/timestamp; cleared automatically by the applying reboot). Two consumers: `/etc/update-motd.d/86-bootc-update-staged` (SSH/console logins) and `bootc-update-notify.path`/`.service` (user scope, desktop notification via `/usr/libexec/bootc-update-notify`, ack-gated per staged digest so it fires once per update, not per login). The desktop toast needs the `notify-send` CLI, which lives in `libnotify-bin` (NOT the transitively-pulled `libnotify4` library) — it ships only in the graphical package set (`shared/packages/snow/mkosi.conf`, used by snow+snowfield, not cayo); without it both `bootc-update-notify` and `snosi-etc-drift-notify` `command -v notify-send || exit 0` into silent no-ops. Both notify units set `StartLimitIntervalSec=0` because the stager writes the semaphore in several syscalls, so one staging emits a burst of `PathModified` triggers that otherwise trips systemd's default 5/10s start-limit and permanently fails the `.path` watcher (`unit-start-limit-hit`); the per-digest ack makes the repeat triggers harmless no-ops. **Currency visibility:** the script also writes `/run/snosi/update-check` on EVERY run (`outcome=current|staged|held-rollback|failed` plus timestamp and running/remote version; an EXIT trap records `failed` on any error) so "up to date", "reboot pending", and "checker broken" are three distinguishable states instead of one silent one. The same motd hook prints one line per state, and `snosi-update-status` (root CLI) summarizes running version, last-check outcome, and staged deployment; `snosi-update-status --check` additionally queries the registry live via skopeo and compares `org.opencontainers.image.version` labels — always compare versions, never digests (the same build has a different digest per transport: registry vs ISO vs podman-loaded). podman does the transfer because bootc's registry-transport composefs pull currently fails on snosi images (known upstream bug) — and podman enforces `containers-policy.json` at pull time. The script no-ops when: not a bootc-managed system (nbc installs — `spec.image` is null), already running or already staged the pulled digest, or the pulled digest equals the **rollback** deployment (never auto-flip-flop back to a version the admin rolled away from; bootc refuses that switch anyway). Upstream's `bootc-fetch-apply-updates.timer` is preset-disabled: it force-reboots on update and is gated on `/run/ostree-booted`, which does not exist on composefs deployments. During the transition, `nbc-update-download.timer` still ships for nbc-installed hosts. bootc-update-stage no-ops on nbc installs (`spec.image` null check); the nbc units are gated with `ConditionKernelCommandLine=!composefs` because `nbc update` itself ERRORS (exit 1, permanently failed unit, degraded state) rather than no-opping on bootc/composefs installs (frostyard/nbc#139).

### Base Image: bootc + ostree from Frostyard debs

bootc and ostree install as regular APT packages (`bootc`, `libostree-1-1` — the latter ships the library AND the ostree CLI) from the Frostyard repository, built and published by [frostyard/bootc-debian](https://github.com/frostyard/bootc-debian). Debian Trixie ships no bootc package and only ostree 2025.2 (too old for current bootc), hence the external packaging.

- **Versions:** pinned in bootc-debian's `download/checksums.json`, tracked weekly by that repo's own `check-dependencies.yml` — snosi's dependency check does NOT cover them. Deb versions carry a `-frostyard<timestamp>` suffix so rebuilds of the same upstream version still sort newer in apt.
- **Build parity:** bootc-debian's `build.sh` mirrors the former in-tree mkosi BuildScript (same pinned tarballs, same checksums, same pinned Rust toolchain — Debian's rustc 1.85 is too old to build bootc 1.16.x). Its Build workflow publishes the debs and then dispatches a snosi image build.
- **Runtime libs:** the debs declare only a partial `Depends` list; base `Packages=` keeps the full set of runtime link deps explicit (`libfuse3-4`, `libsoup-3.0-0`, `liblzma5`, etc.) — do not remove them just because apt doesn't demand them.
- **History:** until 2026-07 these were compiled from source during the base image build (`shared/bootc/build/bootc.chroot` + stub-deb dpkg registration); that machinery is gone.

### Native A/B Prototype

Naming, path, and policy contracts for the eventual production native A/B
products (`cayo-ab`, `snow-ab`, `snowfield-ab`) are frozen in
`docs/native-ab-contracts.md` and enforced statically by
`test/native-ab-contracts-test.sh`. Read that document before adding or
renaming anything under the native A/B tree — it is the source of truth, not
this section. Known deviations of the current prototype from the frozen
contract are tracked in `test/native-ab-contracts-allow.txt`, not silently
carried forward.

`mkosi.profiles/cayo-ab` is an isolated experimental disk profile. Its initrd
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
`test/native-ab-update-test.sh` validates N to N+1 to N+2 to N+3 with four real
mkosi builds: signed-manifest acceptance/rejection, missing UKI/verity and bad
checksum rejection, inactive-slot reuse, dm-verity boot, explicit rollback,
boot-count fallback from a corrupted unblessed update, and `/var` plus `/etc`
persistence.

`mkosi.profiles/cayo-ab-secure` is the security spike. Standard Secure Boot
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
dracut phase. Raw ext4 remains only for the baseline spike. LUKS2 creation,
MOK enrollment, enforced Secure Boot, TPM auto-unlock, TPM replacement failure,
recovery unlock, and PCR signing-key rotation are validated in Incus. Update,
rollback, and boot-count fallback are also validated end to end with the sole
new-key TPM token. The secure profile upgrades the complete systemd family to
Forky 261+ through a profile-only, low-priority APT source; never expose that
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
Validate each secure build with
`test/native-ab-secure-artifact-test.sh`, which checks root-package coherence,
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
A clean secure-profile build is
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
and `systemd-pcrlogin` with `ENXIO`. The secure profile does not consume NvPCR
attestation, so `shared/cayo-ab-secure/finalize/disable-nvpcr.chroot` masks every
shipped NvPCR definition plus the product/login writers. Keep TPM SRK setup and
the signed-PCR-11 LUKS path enabled. Do not delete/recreate the anchor or TPM NV
indexes as a key-rotation shortcut; that changes the attestation baseline.

### Sysext Constraints

Sysexts can ONLY provide files under `/usr`. They cannot modify `/etc` or `/var` at runtime. Configs needed in `/etc` must be:

1. Captured to `/usr/share/factory/etc` during build (via `mkosi.finalize`) — capture ONLY the specific paths the sysext's tmpfiles rules reference, never all of `/etc` (the buildroot `/etc` is the merged base view; a full capture ships `/etc/shadow` and SSH host keys in the published sysext)
2. Injected at boot via systemd-tmpfiles

Every sysext must have matching `<name>.transfer` and `<name>.feature` files in `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/`. The `.transfer` file defines how systemd-sysupdate downloads the sysext; the `.feature` file provides metadata and defaults to `Enabled=false`. Use existing files as templates.

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
- `validate.yml` - shellcheck + runtime-/etc-guard (`check-runtime-etc-guard.sh`) + mkosi summary validation on PRs
- `test-install.yml` - Manual bootc installation test in QEMU/KVM
- `scorecard.yml` - Weekly OpenSSF supply-chain security analysis
## Documentation

**update documentation** After any change to source code, update relevant documentation in CLAUDE.md, README.md and the yeti/ folder. A task is not complete without reviewing and updating relevant documentation.

**yeti/ directory** The `yeti/` directory contains documentation written for AI consumption and context enhancement, not primarily for humans. Jobs like `doc-maintainer` and `issue-worker` instruct the AI to read `yeti/OVERVIEW.md` and related files for codebase context before performing tasks. Write content in this directory to be maximally useful to an AI agent understanding the codebase — detailed architecture, patterns, and decision rationale rather than user-facing guides.
