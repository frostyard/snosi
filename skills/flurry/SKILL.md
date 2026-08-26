---
name: flurry
description: >
  Work on flurry, snosi's Omarchy-replica Hyprland desktop. WHEN: changing
  anything under shared/flurry/ or shared/composition/flurry/, re-pinning the
  vendored omarchy, debugging a flurry session/build, adding packages to the
  flurry set, or extending flurry with omarchy-style apps/plugins. WHEN NOT:
  snow/cayo work, sysext authoring, installer (firn) internals.
---

# Flurry — the Omarchy replica

Flurry (`ImageId=flurry`) is a bootc-only OCI desktop replicating
[Omarchy v4](https://github.com/basecamp/omarchy) (Hyprland + Quickshell +
SDDM) on the snosi Debian Trixie base. Design history, verified platform
facts, live-session findings, and the follow-up list live in
`docs/plans/2026-08-25-flurry-omarchy-plan.md` — read it before structural
changes. Origin story: PRs #772–#778, firn#81, issue #777.

## File map

- `mkosi.profiles/flurry/mkosi.conf` — transport+kernel selector only
  (bootc packages, bootc-secure, composition, backports kernel, image out).
- `shared/composition/flurry/mkosi.conf` — ExtraTrees/scripts wiring;
  `var-outcomes.txt` + the `flurry)` arm in
  `shared/composition/var-audit.finalize` (build hard-fails without both).
- `shared/packages/flurry/mkosi.conf` — the package set. Every comment in
  it is load-bearing; read them before "simplifying".
- `shared/flurry/tree/` — snow-derived bootc infra (dracut conf, presets,
  tmpfiles, brew units) plus flurry-owned pieces:
  `display-manager.service -> sddm.service` static alias,
  `flurry-sddm-state-seed.service` (+ `usr/libexec/` script),
  `user-preset/90-flurry.preset`.
- `shared/flurry/scripts/build/omarchy.chroot` — the vendor script (below).
- `shared/flurry/scripts/build/flurry-extras.chroot` — Nerd Font + mise.
- `shared/flurry/omarchy-overrides/` — whole-file command replacements.
- `shared/flurry/omarchy-neutralize-allow.txt` — guard allowlist.
- Pins: `omarchy`, `jetbrains-mono-nerd`, `mise` in
  `shared/download/image-checksums.json`, refreshed by
  `.github/workflows/check-dependencies.yml` (omarchy follows release TAGS,
  not HEAD, deliberately).

## The three-layer vendoring discipline

1. **Verbatim vendor**: `omarchy.chroot` downloads the pinned tarball and
   installs it per omarchy's `docs/file-layout.md` (tree to
   `/usr/share/omarchy`, bin symlinks, `/etc/skel` seeding with all
   migrations pre-marked, `/etc` drop-ins, SDDM/plymouth themes, uwsm
   session to `/usr/share/wayland-sessions` — never `/usr/local`, which is
   /var-backed here). Arch-only machinery (libalpm, limine, snapper,
   pacman, mkinitcpio) is never installed. File modes come from the
   tarball — a blanket chmod once stripped exec bits from shell plugin
   scripts and broke the clipboard (root-caused live).
2. **Override layer**: ~45 whole-file replacements in
   `omarchy-overrides/bin/`, each keeping its `# omarchy:` header so the
   CLI router/menu still work. Remaps: `omarchy-update` →
   `/usr/libexec/bootc-update-stage` + `snosi-update-status` (NEVER raw
   `bootc upgrade` — its registry-transport pull is broken for snosi
   images); `omarchy-snapshot` → `bootc rollback` guidance; tailscale →
   `updex --silent features enable tailscale --now` (validated live);
   pkg/AUR commands → flatpak/brew/mise guidance; channels → single-stream
   no-op. `install/user/first-run/enable-user-units.sh` is a no-op — user
   units are enabled by `90-flurry.preset` (presets, never runtime
   systemctl; ADR-0003).
3. **Compat patches**: surgical, grep-guarded seds in `omarchy.chroot` for
   trixie-vs-Arch version drift. Every patch names its removal condition;
   every guard FAILS THE BUILD if a re-pin changes the target — that is
   the design, not an inconvenience. Current set: hyprland 0.55.2 Lua
   `monitor.reserved` nil-guard (remove at hyprland ≥ 0.56 in backports);
   foot 1.21 `[colors-dark]`→`[colors]` + `cursor=`→`[cursor]` (remove at
   foot ≥ 1.23); Qt 6.8 QML reserved word `transient` renamed in the
   notifications plugin (remove at Qt ≥ 6.9); Homebrew PATH appended to
   `default/bash/env-bootstrap` (the single PATH authority: skel .bashrc,
   uwsm env.d, profile.d, rc chain all source it — hook PATH/env things
   THERE, nowhere else; no shell on either product is a login shell, so
   `/etc/profile.d` alone never reaches desktop terminals).

**Fail-closed guards** (the vendored-content answer to
`check-runtime-etc-guard.sh`, which cannot see downloaded content): the
vendor script greps the installed `bin/` for system-scope
`systemctl enable|disable|mask` and fails on anything not in
`omarchy-neutralize-allow.txt` (only user-INVOKED admin actions belong
there — sshd setup/remove today).

## Re-pin workflow (omarchy version bumps)

check-dependencies proposes a PR on new omarchy release tags. Expect the
build to fail closed; that is the triage signal. For each tripped guard:
re-read the upstream change, decide keep/adapt/drop the patch or override,
then re-run. Afterwards: full build + QEMU session check (below), scan
`journalctl -t omarchy-shell` for new QML errors (Qt-version drift shows
up there), and diff `bin/` for NEW commands that touch pacman/systemctl.

## Build & verify loop

```bash
just flurry                      # or: sudo .mkosi/bin/mkosi --profile flurry -f build
```
- var-audit failures list unclassified/stale /var paths — that output IS
  the workflow for updating `var-outcomes.txt` (globs: bare `*` covers
  empty-dir and populated shapes; `/**` children only).
- QEMU test (no installer needed): install via `test/lib/vm.sh` helpers
  (`load_image` / `create_disk` / `install_to_disk`, DISK_SIZE=50G), then
  seed a test user + SDDM state (an unseeded greeter submits user "" —
  omarchy's theme is password-only and reads `userModel.lastUser`; on real
  installs `flurry-sddm-state-seed.service` does this). Boot with
  `-vga none -device virtio-gpu-pci` (single GPU) and a QMP socket for
  screendumps; SSH in for checks.
- Session acceptance: `hyprctl configerrors` EMPTY; `journalctl --user -t
  omarchy-shell` free of `plugin load failed`/`Expected token`;
  `systemctl --user --failed` clean (bazaar/podman are preset-disabled —
  base ships their units); `omarchy-theme-set <theme>` end to end; app
  launches work (`gtk-launch` from libgtk-3-bin — omarchy launches EVERY
  desktop entry via `uwsm-app -- gtk-launch <id>`).
- **Sysext caveat (root-caused live)**: app sysexts built as deltas vs
  BASE carry every GUI lib base lacks -- chatgpt/claude-desktop ship
  trixie's libxkbcommon 1.7, which shadow-downgrades flurry's backports
  1.13 on merge and kills Hyprland at the next greeter start (harmless
  same-version shadowing on snow). Until the sysext/product lib story is
  resolved (see the tracking issue), treat lib-heavy Electron sysexts as
  incompatible with flurry; recovery is deleting the extension symlink
  from /var/lib/extensions (offline if needed) and rebooting.
- incus VM testing: default storage pool may be a small loop file — a
  sparse 50G root + a multi-GB podman pull can ENOSPC-kill qemu (state
  ERROR). Check `incus storage info default` first.

## apt resolution rules (both root-caused live; do not relearn)

1. apt NEVER auto-selects a priority-100 backports version for a
   transitive dependency — any both-suite dep needing backports must be
   explicitly `/trixie-backports` suffixed (libxkbcommon trio).
2. The 3.0 solver resolves a backports package's deps PREFERRING
   same-archive versions — which can drag a strictly-versioned trixie
   family into unsatisfiability (xdg-desktop-portal-hyprland → pipewire);
   the fix is moving the whole family explicitly, every member suffixed.
   Debug resolver mysteries in a podman trixie container with the repo's
   sandbox apt config + the BASE IMAGE's dpkg status, and delta-minimize
   with a predicate pinned to the exact conflict message.

## Extending flurry with your own omarchy-style apps

Omarchy's in-house apps (omacalc, tensaku, …) are just binaries plus these
integration surfaces — all available on flurry:

- **TUI app**: `omarchy-tui-install <name> <command> <float|tile> <icon>`
  writes a desktop entry with `Exec=xdg-terminal-exec
  --app-id=TUI.float -e <cmd>`; Hyprland window rules style the
  TUI.float/TUI.tile app-ids. A brew/mise-installed binary + this = a
  first-class launcher app.
- **Web app**: `omarchy-webapp-install <name> <url> [icon]` → chromium
  `--app=` windows via `omarchy-launch-webapp`.
- **Bar/shell extension**: Quickshell plugins —
  `~/.config/omarchy/plugins/<id>/manifest.json`, managed by
  `omarchy-plugin-{add,enable,disable}`; shipped plugins under
  `/usr/share/omarchy/shell/plugins/` are the reference. Enabled state in
  `~/.config/omarchy/shell.json`.
- **Theme hooks**: user templates in `~/.config/omarchy/themed/*.tpl`
  render on every `omarchy-theme-set` with the palette
  (`{{ key }}`/`{{ key_rgb }}`/`{{ mix a b n% }}`); lifecycle hooks in
  `~/.config/omarchy/hooks/<event>.d/`.
- **Menu entries**: `~/.config/omarchy/extensions/omarchy-menu.jsonc`
  extends the Super+Space menu.
- Shipping one IN the image: brew formula or vendored binary via a
  BuildScript + a desktop entry in the vendor script's skel step; respect
  KEYPACKAGE-style pinning (verified_download + check-dependencies).

## Safety constraints (inherited, enforced by CI)

No runtime `systemctl enable/disable` in any shipped path (ADR-0003); no
`RequiredBy=` in shipped units (ADR-0013); enablement via presets or
static /usr wants only; ExtraTrees never SkeletonTrees for conffiles;
build scripts write `$DESTDIR`, never `$SRCDIR`; new verified downloads
need a check-dependencies entry; new GHCR products need a policy.json
scope + `test/bootc-secure-publication-test.sh` +
`test/bootc-container-policy-test.sh` expectations (both enumerate scopes
literally).
