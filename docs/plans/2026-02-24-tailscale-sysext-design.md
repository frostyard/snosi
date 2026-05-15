# Tailscale Sysext Design

## Overview

Add a Tailscale system extension (sysext) to snosi, providing the Tailscale VPN client and daemon as an optional overlay. Follows the established Docker sysext pattern — APT-based package installation with factory defaults for /etc configuration.

## Package Source

Official Tailscale APT repository (`pkgs.tailscale.com/stable/debian`), consistent with how Docker, 1Password, and other third-party packages are sourced. Requires adding:
- APT source list: `mkosi.sandbox/etc/apt/sources.list.d/tailscale.list`
- Signing key: `mkosi.sandbox/etc/apt/keyrings/tailscale-archive-keyring.gpg`

## What the Sysext Provides

- `/usr/bin/tailscale` — CLI tool
- `/usr/sbin/tailscaled` — daemon binary
- `/lib/systemd/system/tailscaled.service` — upstream systemd unit
- `/usr/share/factory/etc/default/tailscaled` — factory default config (port + flags)
- `/usr/lib/tmpfiles.d/tailscale.conf` — restores /etc/default/tailscaled at boot
- `/usr/lib/systemd/system-preset/40-tailscale.preset` — auto-enables tailscaled.service
- `/usr/lib/systemd/system/multi-user.target.d/10-tailscale.conf` — `Upholds=tailscaled.service` drop-in for reliable boot activation

## /etc Configuration Handling

The `tailscaled.service` unit has `EnvironmentFile=/etc/default/tailscaled`. Without this file, the service fails to start (known Trixie issue, tailscale/tailscale#18424). Since sysexts can only write to `/usr`:

1. `mkosi.finalize` copies `/etc/default/tailscaled` to `/usr/share/factory/etc/default/tailscaled`
2. tmpfiles.d `C` directive copies it to `/etc/default/tailscaled` at boot if not already present

## Service Enablement

System preset enables `tailscaled.service` by default. User authenticates post-boot via `tailscale up`.

The preset alone is insufficient for reliable boot-time activation of sysext-provided services. At PID 1 startup the sysext is not yet merged, so the `/etc/systemd/system/multi-user.target.wants/tailscaled.service` symlink's target is missing; systemd silently drops the dangling `Wants=` reference. After `reload-sysext.service` merges the overlay and runs `daemon-reload`, the previously-evaluated wants list for `multi-user.target` is not re-triggered for the newly-available unit.

The fix is a `multi-user.target.d/10-tailscale.conf` drop-in (shipped inside the sysext) that uses `Upholds=tailscaled.service`. Since this drop-in is brand-new to systemd after the daemon-reload, it is processed cleanly when `multi-user.target` activates — ensuring tailscaled starts on every boot. See [Flatcar sysext docs](https://www.flatcar.org/docs/latest/provisioning/sysext/) for background.

## Runtime State

All persistent state lives in `/var/lib/tailscale/` (managed by systemd `StateDirectory=tailscale`). No build-time state needed.

## Dependencies

The `tailscale` package requires `iptables`. `iproute2` is recommended. Both are available in the base image.

## No Special Handling Needed

- No `/opt` relocation (installs to `/usr/bin` and `/usr/sbin`)
- No system user/group (runs as root)
- No one-shot setup service (no post-merge configuration)
- No socket activation (daemon creates its own socket)

## File Structure

```
mkosi.sandbox/etc/apt/
  keyrings/tailscale-archive-keyring.gpg
  sources.list.d/tailscale.list

mkosi.images/tailscale/
  mkosi.conf
  mkosi.postinst.chroot
  mkosi.finalize
  mkosi.extra/usr/lib/
    systemd/system-preset/40-tailscale.preset
    systemd/system/multi-user.target.d/10-tailscale.conf  ← Upholds= drop-in
    tmpfiles.d/tailscale.conf

mkosi.conf  (add tailscale to Dependencies)
```
