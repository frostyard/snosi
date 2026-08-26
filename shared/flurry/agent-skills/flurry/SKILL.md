---
name: flurry
description: >
  REQUIRED companion to the omarchy skill on Flurry (snosi's Debian-based
  Omarchy). Use whenever installing/removing software, updating the system,
  managing channels/snapshots/rollback, enabling services (tailscale,
  docker, 1password), or when any omarchy/Arch advice would invoke pacman,
  yay, AUR, mkinitcpio, limine, or snapper. Excludes desktop customization
  (hypr config, bar, themes) — the omarchy skill covers that unchanged.
---

# Flurry — how this Omarchy differs

This machine looks and behaves like Omarchy, but it is **Flurry**: an
immutable, image-based Debian system (snosi/bootc). The desktop layer —
Hyprland config, keybindings, themes, the bar, terminals — is stock
omarchy; follow the omarchy skill for all of it. Everything below the
desktop is different, and Arch instructions WILL mislead you.

## Software installation (never pacman/yay/AUR — none exist here)

- GUI apps: `flatpak install <app>` (Flathub is configured).
- CLI/dev tools: `brew install <tool>` or `mise use -g <tool>`.
- System services: snosi **sysexts** via
  `sudo updex --silent features enable <name> --now`
  (tailscale, docker, 1password, vscode, …; `updex features list`).
- `apt` exists but MUST NOT install packages: /usr is a read-only image;
  apt is for inspection only (`apt list --installed`). The `omarchy-pkg-*`
  and `omarchy-install-*` commands already route to the right mechanism —
  prefer them.
- **Sysext warning**: Electron-app sysexts (chatgpt, claude-desktop) are
  currently incompatible with Flurry — their bundled GUI libraries shadow
  Flurry's newer graphics stack and break the next login. If a boot lands
  on a black screen after enabling one, remove its symlink from
  /var/lib/extensions and reboot.

## Updates, snapshots, rollback

- The OS updates as ONE image, staged automatically (hourly) and applied
  on reboot. `omarchy-update` triggers the same engine manually. NEVER run
  raw `bootc upgrade` or suggest `bootc switch <registry-ref>` — the
  registry-transport pull is broken for these images; the snosi stager
  (podman transfer) is the only supported path.
- Status: `snosi-update-status` (root); reboot-pending is announced by
  motd and a desktop notification.
- There is exactly one release channel; `omarchy-channel-*` are
  informational no-ops.
- No snapper/btrfs snapshots: the previous image IS the snapshot. Broken
  update → `sudo bootc rollback && sudo reboot`.
- `omarchy-refresh-limine`/`omarchy-plymouth-set` are no-ops: bootloader
  and boot splash are baked into the signed image.

## System layout differences

- `/usr` read-only; `/etc` writable and diffable (`snosi-etc-diff`);
  state in `/var`; homes at `/var/home`; Homebrew at `/home/linuxbrew`
  (on PATH via omarchy's env-bootstrap).
- Enabling/disabling systemd services with `systemctl` works as an admin
  action, but shipped automation must never do it (image policy).
- Debian package names differ from Arch (fd-find, tealdeer for tldr,
  libgtk-3-bin for gtk-launch); check `apt list --installed` before
  telling the user something is missing.

## Not (yet) on Flurry

gpu-screen-recorder (screen recording is stubbed), tensaku, voxtype,
cliamp, herdr, omacalc/omacut/omawrite, localsend, obsidian, pinta —
suggest flatpak equivalents where they exist rather than Arch packages.
