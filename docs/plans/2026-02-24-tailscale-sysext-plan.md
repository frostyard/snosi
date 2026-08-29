# Tailscale Sysext Implementation Plan

**Status:** Shipped — `mkosi.images/tailscale/` and `sysupdate.tailscale.d/tailscale.transfer` are in tree.  
**Last verified:** 2026-08-29

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a Tailscale VPN sysext to snosi following the established Docker sysext pattern.

**Architecture:** APT-based sysext using official Tailscale repo. Factory defaults pattern for `/etc/default/tailscaled`. System preset for service enablement.

**Tech Stack:** mkosi sysext, systemd tmpfiles.d/system-preset, APT

---

### Task 1: Add Tailscale APT repository and signing key

**Files:**
- Create: `mkosi.sandbox/etc/apt/sources.list.d/tailscale.list`
- Create: `mkosi.sandbox/etc/apt/keyrings/tailscale-archive-keyring.gpg`

**Step 1: Download the Tailscale signing key**

```bash
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
  -o mkosi.sandbox/etc/apt/keyrings/tailscale-archive-keyring.gpg
```

**Step 2: Create the APT sources list**

Create `mkosi.sandbox/etc/apt/sources.list.d/tailscale.list`:
```
deb [arch=amd64 signed-by=/etc/apt/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main
```

This follows the exact same pattern as Docker (`docker.list`) and 1Password (`1password.list`): `signed-by` points to `/etc/apt/keyrings/` (the mkosi.sandbox path maps to this at build time).

**Step 3: Commit**

```bash
git add mkosi.sandbox/etc/apt/keyrings/tailscale-archive-keyring.gpg \
        mkosi.sandbox/etc/apt/sources.list.d/tailscale.list
git commit -m "feat(tailscale): Add Tailscale APT repository and signing key"
```

---

### Task 2: Create the sysext mkosi.conf

**Files:**
- Create: `mkosi.images/tailscale/mkosi.conf`

**Step 1: Create the sysext directory**

```bash
mkdir -p mkosi.images/tailscale
```

**Step 2: Create mkosi.conf**

Create `mkosi.images/tailscale/mkosi.conf`:
```ini
[Config]
Dependencies=base

[Output]
ImageId=tailscale
Output=tailscale
Overlay=yes
ManifestFormat=json
Format=sysext

[Content]
Bootable=no
BaseTrees=%O/base
PostOutputScripts=%D/shared/sysext/postoutput/sysext-postoutput.sh
Environment=KEYPACKAGE=tailscale

Packages=tailscale
```

This mirrors `mkosi.images/docker/mkosi.conf` exactly. `KEYPACKAGE=tailscale` tells the shared postoutput script to extract the version from the `tailscale` package in the manifest.

**Step 3: Commit**

```bash
git add mkosi.images/tailscale/mkosi.conf
git commit -m "feat(tailscale): Add sysext mkosi configuration"
```

---

### Task 3: Create the postinstall script

**Files:**
- Create: `mkosi.images/tailscale/mkosi.postinst.chroot`

**Step 1: Create mkosi.postinst.chroot**

Create `mkosi.images/tailscale/mkosi.postinst.chroot`:
```bash
#!/bin/bash
# Post-install script for sysext
# Add any customizations here
set -euo pipefail

if [[ "${DEBUG_BUILD:-0}" == "1" ]]; then
    set -x
fi
```

This is the standard minimal postinstall script, identical to Docker's. Tailscale doesn't need any post-install customization.

**Step 2: Make it executable**

```bash
chmod +x mkosi.images/tailscale/mkosi.postinst.chroot
```

**Step 3: Commit**

```bash
git add mkosi.images/tailscale/mkosi.postinst.chroot
git commit -m "feat(tailscale): Add postinstall script"
```

---

### Task 4: Create the finalize script (factory defaults)

**Files:**
- Create: `mkosi.images/tailscale/mkosi.finalize`

**Step 1: Create mkosi.finalize**

Create `mkosi.images/tailscale/mkosi.finalize`:
```bash
#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -e

# Capture /etc/default/tailscaled to factory defaults for tmpfiles.d to restore at boot.
# The tailscaled.service unit requires EnvironmentFile=/etc/default/tailscaled.
# Without this file, the service fails to start (tailscale/tailscale#18424).
mkdir -p "$BUILDROOT/usr/share/factory/etc/default"

if [ -e "$BUILDROOT/etc/default/tailscaled" ]; then
    cp --archive --update=none "$BUILDROOT/etc/default/tailscaled" \
       "$BUILDROOT/usr/share/factory/etc/default/"
fi
```

This follows the Docker finalize script pattern. It captures `/etc/default/tailscaled` (the only /etc file Tailscale installs) into the factory defaults location.

**Step 2: Make it executable**

```bash
chmod +x mkosi.images/tailscale/mkosi.finalize
```

**Step 3: Commit**

```bash
git add mkosi.images/tailscale/mkosi.finalize
git commit -m "feat(tailscale): Add finalize script for factory defaults"
```

---

### Task 5: Create tmpfiles.d and system-preset configs

**Files:**
- Create: `mkosi.images/tailscale/mkosi.extra/usr/lib/tmpfiles.d/tailscale.conf`
- Create: `mkosi.images/tailscale/mkosi.extra/usr/lib/systemd/system-preset/40-tailscale.preset`

**Step 1: Create directory structure**

```bash
mkdir -p mkosi.images/tailscale/mkosi.extra/usr/lib/tmpfiles.d
mkdir -p mkosi.images/tailscale/mkosi.extra/usr/lib/systemd/system-preset
```

**Step 2: Create tmpfiles.d config**

Create `mkosi.images/tailscale/mkosi.extra/usr/lib/tmpfiles.d/tailscale.conf`:
```
# Copy Tailscale daemon config from factory defaults
C /etc/default/tailscaled - - - - -
```

The `C` directive copies from `/usr/share/factory/etc/default/tailscaled` to `/etc/default/tailscaled` at boot, but only if the target doesn't already exist. This preserves user modifications.

**Step 3: Create system-preset**

Create `mkosi.images/tailscale/mkosi.extra/usr/lib/systemd/system-preset/40-tailscale.preset`:
```
enable tailscaled.service
```

**Step 4: Commit**

```bash
git add mkosi.images/tailscale/mkosi.extra/
git commit -m "feat(tailscale): Add tmpfiles.d and system-preset for boot-time config"
```

---

### Task 6: Register the sysext in root mkosi.conf

**Files:**
- Modify: `mkosi.conf:3` (add `tailscale` to Dependencies list)

**Step 1: Add tailscale to Dependencies**

In `mkosi.conf`, add `tailscale` to the Dependencies list (alphabetical order, after `podman`):

```ini
[Config]
# list base + any sysexts that get built by default
Dependencies=base
             1password-cli
             debdev
             dev
             docker
             incus
             podman
             tailscale
```

**Step 2: Commit**

```bash
git add mkosi.conf
git commit -m "feat(tailscale): Register sysext in root mkosi.conf"
```

---

### Task 7: Verify the build

**Step 1: Run the sysext build**

```bash
just sysexts
```

Expected: Build completes successfully. The `tailscale` sysext appears in `output/` with a versioned filename like `tailscale_<version>_amd64.raw`.

**Step 2: Verify output artifacts**

```bash
ls -la output/tailscale*
```

Expected: Versioned sysext file, symlink, and manifest.

**Step 3: Verify factory defaults are present**

Inspect the built sysext to confirm `/usr/share/factory/etc/default/tailscaled` is present:

```bash
sudo unsquashfs -l output/tailscale | grep factory
```

Expected: `/usr/share/factory/etc/default/tailscaled` appears in the listing.

**Step 4: Commit any adjustments if needed**
