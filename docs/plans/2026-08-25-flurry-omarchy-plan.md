# Plan: Flurry — Omarchy v4 replica profile

**Status:** In progress — `mkosi.profiles/flurry.conf` builds and flurry ships as a product; later phases are still open.  
**Last verified:** 2026-08-29

<!--
Plans are updated as work lands: check off what shipped, renumber what moved.
Every phase MUST have a "Done when" — a demonstrable outcome, not an activity.
-->

Flurry is a new bootc-only desktop product (`ImageId=flurry`) that replicates
[Omarchy v4 "Quattro"](https://github.com/basecamp/omarchy) (Hyprland +
Quickshell) on the snosi Debian Trixie immutable base, as faithfully as the
platform allows. Approach decided with the maintainer: vendor omarchy
verbatim at a pinned commit; remap its pacman/AUR/snapper/limine machinery
onto snosi mechanisms (bootc image updates, A/B rollback, flatpak/brew/mise,
sysexts); vendor only essential missing pieces (JetBrainsMono Nerd Font,
mise); accept graceful degradation for omarchy's in-house Arch-only apps.

Key platform facts this rests on (verified 2026-08-25):

- The entire Hyprland stack is in **trixie-backports** (hyprland 0.55.2,
  quickshell 0.3.0, uwsm, hyprpicker, hyprsunset, xdg-desktop-portal-hyprland,
  hyprland-qtutils), consumed via the existing `pkg/trixie-backports` explicit
  selection mechanism (`shared/packages/flurry/mkosi.conf`).
- Omarchy v4 configures Hyprland in **Lua** (`hyprland.lua`, the `hl.*` API).
  That API is upstream Hyprland (landed 0.55); every `hl.*` name omarchy uses
  was verified present in Hyprland v0.55.2's `src/config/lua/` bindings.
- Quickshell 0.3.0 (Debian) ships all `Quickshell.*` QML modules omarchy's
  `shell/` imports, including `Networking` and `Services.Polkit`.
- `gum`, `xdg-terminal-exec`, foot, sddm, fcitx5 are in plain trixie;
  ghostty, lazydocker, and neovim ≥ 0.12 come from the debian.griffo.io repo
  the sandbox already carries; `tealdeer` provides `tldr`.

## Phase 1 — Buildable skeleton profile ✅

- `mkosi.profiles/flurry/mkosi.conf` (snow-shaped transport+kernel selector:
  bootc packages + bootc-secure + composition/flurry + kernel/backports +
  outformat/image).
- `shared/composition/flurry/mkosi.conf`, `shared/packages/flurry/mkosi.conf`,
  `shared/flurry/tree/` (snow-derived bootc infrastructure minus
  GNOME/bazaar/incus, plus `display-manager.service -> sddm.service` static
  alias and an sddm tmpfiles rule), `flurry.postinst.chroot` (os-release,
  `systemctl enable sddm`, gnome-keyring stripped from sddm PAM). The build
  runs Omarchy's pinned `default-keyring.sh` against `/etc/skel`, so every
  first-boot user starts with Omarchy's passwordless default keyring.
- `shared/composition/flurry/var-outcomes.txt` + the `flurry)` arm in
  `shared/composition/var-audit.finalize`.
- Justfile `flurry`/`_flurry` targets; `validate.yml` summary loop includes
  flurry.
- **Done when:** `just flurry` builds green and the var audit passes.

## Phase 2 — Omarchy vendoring + override layer ✅

- Pinned downloads in `shared/download/image-checksums.json` (`omarchy` at
  commit 9301092404…, `jetbrains-mono-nerd` 3.5.1, `mise` 2026.8.12) with
  matching update checks in `.github/workflows/check-dependencies.yml`
  (omarchy follows release tags, not HEAD — every re-pin needs override
  triage).
- `shared/flurry/scripts/build/omarchy.chroot`: installs the tree per
  omarchy's `docs/file-layout.md` (`/usr/share/omarchy`, `/usr/bin` symlinks,
  `/etc/skel` seeding with migrations pre-marked, `/etc` drop-ins, uwsm
  session, SDDM + plymouth themes, fontconfig, chromium flags translated to
  `/etc/chromium.d`), excluding Arch-only machinery (libalpm/limine/snapper/
  pacman/mkinitcpio).
- `shared/flurry/omarchy-overrides/`: whole-file replacements for ~45
  commands — pkg primitives reimplemented on dpkg, `omarchy-update` driving
  `bootc-update-stage`/`snosi-update-status`, `omarchy-snapshot` →
  `bootc rollback` guidance, tailscale install/remove → the tailscale sysext
  via updex, sshd setup → Debian `ssh.service`, the rest gum-styled guidance
  stubs. `install/user/first-run/enable-user-units.sh` is a no-op; user
  units are enabled by `usr/lib/systemd/user-preset/90-flurry.preset`.
- Build-time neutralization guard in `omarchy.chroot`: fails the build on
  any system-scope `systemctl enable|disable|mask` left in the installed
  omarchy `bin/` that is not allowlisted in
  `shared/flurry/omarchy-neutralize-allow.txt` (only user-invoked admin
  actions may be allowlisted). This closes the vendored-content blind spot of
  `check-runtime-etc-guard.sh` and fails closed on future re-pins.
- **Done when:** the built image carries `/usr/share/omarchy` with overrides
  applied and the guard green.

## Phase 3 — Session integration ✅ (build-verified; boot pending)

- Vendored essentials via `shared/flurry/scripts/build/flurry-extras.chroot`
  (Nerd Font + mise).
- Presets: system preset additions in the flurry tree; user preset
  `90-flurry.preset` for omarchy's user services.
- **Done when:** first boot reaches SDDM with the omarchy theme and a
  Hyprland/Quickshell session starts (see Verification below).

## Verification

1. `just flurry`; guards: `check-duplicate-packages.sh`,
   `check-runtime-etc-guard.sh`, `check-required-by-guard.sh`, shellcheck at
   `-S warning`.
2. Initrd carries the omarchy plymouth theme (`lsinitrd`).
3. QEMU boot: sddm active with the omarchy theme; session login →
   `hyprctl configerrors` empty (Lua config parses on 0.55.2);
   `journalctl -t omarchy-shell` free of QML type errors;
   `omarchy-theme-set tokyo-night` works; `omarchy-update`/`omarchy-pkg-*`
   behave per the remap; `useradd -m` seeds the omarchy skel.

## QEMU bring-up findings (2026-08-25, first live sessions)

Verified working in a KVM/virtio-gpu VM: SDDM renders the omarchy greeter
(Wayland, via `start-hyprland`), login reaches the omarchy Hyprland session,
`hyprctl configerrors` is EMPTY on hyprland 0.55.2 (after the qconsole
patch), the Quickshell bar/workspaces/tray render, theme background applies,
tiling works, and the omarchy CLI overrides behave (`omarchy-version`,
`omarchy-update-available`, `omarchy-pkg-present`, `omarchy-channel-*`).

Version-drift compat patches now applied by `omarchy.chroot` (each
grep-guarded so an omarchy re-pin that changes the target fails the build):
- hyprland 0.55.2: Lua `monitor.reserved` is nil (0.56 API) — guarded
  default in `default/hypr/qconsole.lua`.
- foot 1.21: no `[colors-dark]` section and no `cursor=` key in colors —
  template rewritten to `[colors]` + a `[cursor]` section.
- Qt 6.8: `transient` is still a QML reserved word (unreserved in 6.9) —
  local renamed in `shell/plugins/notifications/Service.qml`.

Test-only scaffolding (not shipped): the QEMU flow installs via
`test/lib/vm.sh` then seeds a `flurry`/`flurry` user + SDDM
`/var/lib/sddm/state.conf` (`Last User/Session`) — omarchy's password-only
greeter submits `userModel.lastUser`, which is empty on a virgin install.
SHIPPED FIX (2026-08-25): `flurry-sddm-state-seed.service` (flurry tree,
static wants, `Before=display-manager.service`,
`ConditionPathExists=!/var/lib/sddm/state.conf`) seeds the state for the
machine's sole uid>=1000 account on first boot, covering every install
method; SDDM owns the file from the first real login.

Live-VM findings (2026-08-26, root-caused on the user's incus install):
- **Screensaver refused to launch** ("only runs in Alacritty, Foot, Ghostty,
  or Kitty"): `omarchy-launch-screensaver` gates on
  `xdg-terminal-exec --print-id`, which landed upstream in 0.13.0; trixie's
  0.12.3 *discards* the unknown option (and launches a bare terminal), so the
  id was always empty. Fixed by vendoring upstream v0.14.3 (single-file
  POSIX-sh reference implementation, flag superset of 0.12.3) over
  `/usr/bin/xdg-terminal-exec` in `flurry-extras.chroot` — pinned in
  `image-checksums.json`, tracked by check-dependencies, and guarded by a
  build-time `dpkg --compare-versions` check that fails the build (retire
  signal) once Debian ships >= 0.13. `omarchy-default-terminal`'s show/set
  flow depends on the same flag.
- **Nautilus/GTK icons rendered as scaled-up blurs**: Yaru/Adwaita icons are
  almost entirely SVG and `librsvg2-common` (the SVG gdk-pixbuf loader) is
  only a Recommends of the GTK stack, which mkosi does not install; snow
  inherits it via the GNOME meta packages. Added to the flurry package set.
  (Omarchy's Arch `theme-system.sh` Yaru action-icon symlinks are NOT
  needed: Debian's yaru-theme-icon already ships
  go-previous/next-symbolic.svg in scalable/actions.)
- **Screensaver renderer missing** (issue #786): `omarchy-screensaver`
  runs `ttfx` (omacom-io's Rust port of terminaltexteffects; omarchy
  migration 1786355450 replaced the Python original). No deb, no upstream
  binaries — first built in-tree (`ttfx.chroot`, retired 2026-08-26),
  now installed from the frostyard APT repo like the rest of the
  omarchy in-house apps (frostyard/omarchy-apps; see the tier-1 block in
  shared/packages/flurry/mkosi.conf).
- **Dead `~/Projects` bookmark**: upstream `omarchy-provision-user`
  bookmarks Projects in gtk-3.0/bookmarks but only mkdirs
  Downloads/Pictures/Videos — a genuine upstream gap (only the v3→v4
  upgrade script creates it). Compat-patched the mkdir line; candidate for
  an upstream basecamp PR.

## Installer integration (firn, 2026-08-25)

Firn is the installer (single TUI binary; ISO built by snosi's
`firn-installer` profile). Flurry appears in the picker via
`shared/firn-installer/catalog.json`, shipped to `/etc/firn/catalog.json`
— firn's documented wholesale-override seam (firn ADR-0010 puts the
catalog on the media side; firn's compiled-in list stays as fallback).
The same change fixed a pre-existing ISO gap: the medium shipped neither
the `cosign` CLI nor `/usr/lib/snosi/cosign.pub`, which firn's preflight
requires for every bootc catalog entry (`scripts/build/cosign.chroot`,
pinned in image-checksums and refreshed by the check-dependencies cosign
check). Remaining firn-side item: on composefs installs firn defers the
/etc/skel copy to a first-boot tmpfiles `C` rule, and a wizard-pasted SSH
key pre-creates the home dir, silently skipping skel — fatal for flurry
(all omarchy dotfiles are skel); fix belongs in firn's
`internal/sysconfig` (tracked as a firn PR).

## Later / ideas

- ~~CI publication~~ DONE (alpha matrix, 2026-08-25): flurry is in the
  `build-images.yml` secure-build + PR matrices and `build-mechanics.yml`;
  policy.json carries the `ghcr.io/frostyard/flurry` `sigstoreSigned` scope
  (test updated); the publication guard, verify/promote scripts, and static
  test all include flurry. Still deferred: adding flurry to the future
  Firn-native Snosi lifecycle lane; that needs secure install fixtures that do
  not exist yet.
- Native A/B `flurry-ab` (channel fragment, repart, sysupdate transfers, CI).
- Vendor gpu-screen-recorder (screen recording is stubbed), tensaku
  (screenshot editing falls back), voxtype, localsend, moonlight-qt,
  obsidian/pinta (flatpak seeding instead?).
- `hyprland-preview-share-picker` is absent: `config/hypr/xdph.conf` names it
  as `custom_picker_binary` — verify xdph falls back cleanly, else trim the
  skel config.
- ufw-docker integration when the docker sysext is enabled.
- ~~Sysext deltas shadow-downgrading flurry's backports libs (issue
  #781)~~ FIXED (2026-08-26): the nine desktop-app sysexts now build
  against `gui-base` so their deltas carry no product-divergent GUI libs;
  see docs/design/sysexts.md "Desktop-App Sysexts Build Against gui-base".
  Residual: server sysexts (incus) and externally-built sysexts remain
  outside the guarantee — an updex merge-time shadow check (issue #781
  option 4) is the future defense for those.
- First-login blips seen in the VM, benign but untriaged: a stray ghostty
  instance killed by `omarchy-restart-terminal`'s SIGUSR2 during the initial
  theme-set (terminal selection order?). RESOLVED since: fumon's
  crash-loop was collateral of the broken notification daemon (fixed by the
  `transient` patch; fumon now works and toasts real failures), and
  user-scope `podman.service` ("unexpected fd received from systemd", exit
  125 — likely also failing on snow, worth checking there) is
  preset-disabled on flurry in favor of podman.socket activation.
- Full session verification (build 11): `hyprctl configerrors` empty, zero
  Quickshell plugin errors, zero failed system units, notifications render
  (update prompt + first-run welcome + fumon), `omarchy-theme-set
  catppuccin` switches wallpaper/terminal/bar end to end.
- omarchy-provision-owner-style first-boot user creation.
- Promote the brew unit copies (snow/cayo/flurry all carry identical files)
  to base `mkosi.extra`.

## Open questions

- **Hyprland 0.55.2 vs omarchy's tracked 0.56.x**: property-level Lua/config
  drift is possible even with all API names present. Decided by the QEMU boot
  check (`hyprctl configerrors`); fallback is a flurry-owned compat shim in
  `bootstrap.lua` or waiting for the 0.56 backport.
