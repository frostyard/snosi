# Cayo Ship Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship the cayo server image and cayoloaded variant by rebasing onto main, auditing packages/configs, and creating a clean PR.

**Architecture:** cayo is a headless server profile (podman, no desktop). cayoloaded extends cayo with docker + incus baked in (not sysexts). The virt package set gets split into virt-base (headless) and virt (GUI) so both snowloaded and cayoloaded can reuse appropriate pieces.

**Tech Stack:** mkosi profiles, Debian packaging, systemd presets/sysusers/tmpfiles, GitHub Actions CI

---

### Task 1: Rebase cayo onto main

**Files:**
- N/A (git operation)

**Step 1: Rebase**

```bash
git rebase main
```

The cayo commit is a pure addition (92 new files). Conflicts may appear in:
- `.github/workflows/build-images.yml` (both branches added cayo to matrix)
- `.gitignore` (both branches added cayo homebrew exclusion)
- `Justfile` (both branches added cayo target)

These should auto-resolve or need trivial resolution (keep both/either since they're identical changes).

**Step 2: Verify rebase**

```bash
git log --oneline -5
git diff main --stat
```

Expected: cayo's additions show as the only diff from main.

**Step 3: Commit (rebase completes automatically)**

No explicit commit needed - rebase replays the cayo commit on top of main.

---

### Task 2: Fix brew build script for cayo

**Problem:** `shared/snow/scripts/build/brew.chroot` hardcodes the output path to `shared/snow/tree/usr/share/homebrew.tar.zst`. Cayo's ExtraTrees only includes `shared/cayo/tree/`, so the homebrew tarball never makes it into the cayo image.

**Files:**
- Create: `shared/cayo/scripts/build/brew.chroot`
- Modify: `mkosi.profiles/cayo/mkosi.conf:24`

**Step 1: Create cayo brew build script**

Create `shared/cayo/scripts/build/brew.chroot`:

```bash
#!/bin/bash
set -euo pipefail

# this script installs Homebrew in a temporary location and then
# creates a compressed tarball of the installation at
# shared/cayo/tree/usr/share/homebrew.tar.zst

source "$SRCDIR/shared/download/verified-download.sh"

rm -f "$SRCDIR/shared/cayo/tree/usr/share/homebrew.tar.zst"

verified_download "brew-install" "/tmp/brew-install"
touch /.dockerenv
env --ignore-environment "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "HOME=/home/linuxbrew" "NONINTERACTIVE=1" /usr/bin/bash /tmp/brew-install
mkdir -p /out && \
tar --zstd -cvf "$SRCDIR/shared/cayo/tree/usr/share/homebrew.tar.zst" "/home/linuxbrew/.linuxbrew"

rm -f /tmp/brew-install
rm -f /.dockerenv
rm -rf /home/linuxbrew
```

Make it executable: `chmod +x shared/cayo/scripts/build/brew.chroot`

**Step 2: Update cayo profile to use cayo's brew script**

In `mkosi.profiles/cayo/mkosi.conf`, change:

```
BuildScripts=%D/shared/snow/scripts/build/brew.chroot
```

to:

```
BuildScripts=%D/shared/cayo/scripts/build/brew.chroot
```

**Step 3: Commit**

```bash
git add shared/cayo/scripts/build/brew.chroot mkosi.profiles/cayo/mkosi.conf
git commit -m "fix: use cayo-specific brew build script

The snow brew script writes homebrew tarball to snow's tree,
but cayo's ExtraTrees only includes cayo's tree."
```

---

### Task 3: Audit cayo packages

**Files:**
- Modify: `shared/packages/cayo/mkosi.conf`

**Step 1: Run package dedup check**

After rebase, `check-duplicate-packages.sh` should be available from main. Run it:

```bash
bash check-duplicate-packages.sh
```

Review output for packages in cayo that duplicate base.

**Step 2: Remove desktop/mobile mismatches**

Remove these packages from `shared/packages/cayo/mkosi.conf`:

- `switcheroo-control` (GPU switching, laptop/desktop only)
- `modemmanager` (cellular modem, not server)
- `mobile-broadband-provider-info` (cellular providers, not server)
- `ppp` (PPP dial-up, not server)
- `wamerican` (spelling dictionary, not server essential)
- `nm-connection-editor` (currently in RemovePackages - remove the package AND the RemovePackages entry since we're not installing it)
- `libmbim-utils` (mobile broadband interface, not server)
- `libqmi-utils` (Qualcomm modem interface, not server)

**Step 3: Review the diffoscope package section**

The large "Server-relevant diffoscope packages" section (lines 43-171) contains packages that appear to come from a diffoscope comparison with snow. Review each category:

- **Keep:** Server-useful packages (cryptsetup, grub, linux-cpupower, linux-perf, mdadm, sshfs, systemd-timesyncd, thin-provisioning-tools, xxd, pigz, realmd, e2fsprogs-l10n)
- **Keep:** Container deps already needed (libcriu2, python3-pycriu, criu - for podman live migration)
- **Keep:** Perl/lib packages that are deps of kept packages (don't remove manually - apt handles deps)
- **Remove if not a dependency:** `lynx`, `lynx-common` (text browser), `os-prober` (multi-boot desktop tool), `qemu-block-extra` (not needed without qemu), `libvirt-l10n` (no libvirt in base cayo), `libhivex0`, `libwin-hivex-perl`, `wimtools`, `libwim15t64` (Windows tools)

Note: Be conservative. If unsure whether a package is a dependency of something else, keep it. Apt will error at build time if a needed dep is missing.

**Step 4: Commit**

```bash
git add shared/packages/cayo/mkosi.conf
git commit -m "chore: audit cayo packages for headless server

Remove desktop/mobile packages not appropriate for a
headless server image: switcheroo-control, modemmanager,
mobile-broadband-provider-info, ppp, wamerican, and
Windows/desktop utilities."
```

---

### Task 4: Fix cayo tree cosmetics

**Files:**
- Rename: `shared/cayo/tree/usr/share/snow/` -> `shared/cayo/tree/usr/share/cayo/`
- Modify: `shared/cayo/tree/var/lib/AccountsService/users/snow`
- Modify: `shared/cayo/tree/usr/share/cayo/bundles/README.txt` (after rename)

**Step 1: Rename snow directory to cayo**

```bash
git mv shared/cayo/tree/usr/share/snow shared/cayo/tree/usr/share/cayo
```

**Step 2: Update bundle README path references**

In `shared/cayo/tree/usr/share/cayo/bundles/README.txt`, change:

```
brew bundle --file=/usr/share/snow/xxx.Brewfile
```

to:

```
brew bundle --file=/usr/share/cayo/xxx.Brewfile
```

**Step 3: Fix AccountsService user file**

Either rename `shared/cayo/tree/var/lib/AccountsService/users/snow` to reference the appropriate user, or remove it if `firstsetup` isn't relevant for a server image. Since cayo is a server (no first-setup GUI), remove it:

```bash
rm shared/cayo/tree/var/lib/AccountsService/users/snow
```

If cayo has a first-setup flow, keep but rename. Verify by checking if `snow-first-setup` or similar is in cayo packages (it's not - it's GNOME-specific).

**Step 4: Check for other snow references**

```bash
grep -r "snow" shared/cayo/ --include="*.conf" --include="*.chroot" --include="*.fish" --include="*.txt" --include="*.service"
```

Fix any remaining references. Known safe references:
- `bbrew.png` in `usr/share/cayo/` - this is the brew icon, fine to keep as-is

**Step 5: Commit**

```bash
git add -A shared/cayo/
git commit -m "chore: rename snow references to cayo in cayo tree

Rename usr/share/snow/ to usr/share/cayo/, update bundle
README paths, remove snow-specific AccountsService config."
```

---

### Task 5: Refactor virt into virt-base + virt

**Files:**
- Create: `shared/packages/virt-base/mkosi.conf`
- Create: `shared/packages/virt-base/tree/` (copy from existing virt tree)
- Modify: `shared/packages/virt/mkosi.conf`
- Modify: `mkosi.profiles/snowloaded/mkosi.conf`

**Step 1: Create virt-base package set (headless incus)**

Create `shared/packages/virt-base/mkosi.conf`:

```ini
[Content]
# Incus headless (from Zabbly repo in mkosi.sandbox)
Packages=apparmor
         attr
         dnsmasq-base
         fuse3
         genisoimage
         iptables
         btrfs-progs
         libbtrfs0t64
         iw
         nftables
         pci.ids
         rsync
         squashfs-tools
         xdelta3
         xz-utils
         qemu-kvm
         qemu-utils
         ipxe-qemu
         incus
         incus-client
         incus-base
         incus-extra
         incus-ui-canonical
```

Note: `qemu-system-gui`, `qemu-system-modules-spice`, and `virt-viewer` are excluded (GUI packages).

**Step 2: Copy virt tree to virt-base**

```bash
cp -r shared/packages/virt/tree shared/packages/virt-base/tree
```

The tree contains incus presets and sysusers (40-incus.preset, dnsmasq.conf, rdma.conf) which are needed for both GUI and headless.

**Step 3: Update virt to include virt-base + GUI packages**

Replace `shared/packages/virt/mkosi.conf` with:

```ini
[Content]
# GUI packages for desktop incus usage
Packages=qemu-system-gui
         qemu-system-modules-spice
         virt-viewer

[Include]
# Headless incus base
Include=%D/shared/packages/virt-base/mkosi.conf
```

**Step 4: Update snowloaded to use virt tree from virt-base**

In `mkosi.profiles/snowloaded/mkosi.conf`, change:

```
ExtraTrees=%D/shared/packages/virt/tree
```

to:

```
ExtraTrees=%D/shared/packages/virt-base/tree
```

(The tree is now in virt-base. snowloaded still includes full `virt` packages via Include.)

**Step 5: Verify snowfieldloaded**

Check if `mkosi.profiles/snowfieldloaded/mkosi.conf` also references `shared/packages/virt/tree`. If so, update the same way.

**Step 6: Commit**

```bash
git add shared/packages/virt-base/ shared/packages/virt/mkosi.conf
git add mkosi.profiles/snowloaded/mkosi.conf mkosi.profiles/snowfieldloaded/mkosi.conf
git commit -m "refactor: split virt into virt-base (headless) and virt (GUI)

virt-base contains headless incus packages (no virt-viewer,
qemu-system-gui, qemu-system-modules-spice). virt includes
virt-base plus GUI packages. snowloaded/snowfieldloaded use
full virt, cayoloaded will use virt-base."
```

---

### Task 6: Create shared docker-onimage package set

**Files:**
- Create: `shared/packages/docker-onimage/mkosi.conf`
- Create: `shared/packages/docker-onimage/tree/usr/lib/systemd/system-preset/30-docker.preset`
- Create: `shared/packages/docker-onimage/tree/usr/lib/sysusers.d/docker.conf`
- Create: `shared/packages/docker-onimage/tree/usr/lib/tmpfiles.d/docker.conf`

**Step 1: Create docker-onimage package set**

This is for baking docker directly into an image (not as a sysext). Create `shared/packages/docker-onimage/mkosi.conf`:

```ini
[Content]
# Docker CE (from docker.com repo in mkosi.sandbox)
Packages=docker-ce
         docker-ce-cli
         containerd.io
         docker-buildx-plugin
         docker-compose-plugin
         docker-ce-rootless-extras
```

**Step 2: Create docker-onimage tree**

These files enable docker services when baked into the image. Copied from the docker sysext extras at `mkosi.images/docker/mkosi.extra/`.

Create `shared/packages/docker-onimage/tree/usr/lib/systemd/system-preset/30-docker.preset`:

```
enable docker.socket
enable containerd.service
```

Note: This uses `30-` prefix to match cayo's existing `30-docker.preset` filename, which will be overridden in cayoloaded since cayoloaded includes cayo tree first (disable) then docker-onimage tree (enable).

Create `shared/packages/docker-onimage/tree/usr/lib/sysusers.d/docker.conf`:

```
g docker - -
```

Create `shared/packages/docker-onimage/tree/usr/lib/tmpfiles.d/docker.conf`:

```
# Copy Docker/containerd configs from factory defaults
C /etc/default/docker - - - - -
C /etc/docker - - - - -
C /etc/containerd - - - - -
```

**Step 3: Commit**

```bash
git add shared/packages/docker-onimage/
git commit -m "feat: add docker-onimage package set for baked-in docker

Reusable package set for profiles that want docker baked
directly into the image (not as a sysext). Includes packages,
systemd preset, sysusers, and tmpfiles."
```

---

### Task 7: Create cayoloaded profile

**Files:**
- Create: `mkosi.profiles/cayoloaded/mkosi.conf`

**Step 1: Create cayoloaded profile config**

Create `mkosi.profiles/cayoloaded/mkosi.conf`:

```ini
[Config]
Dependencies=base

[Build]
Environment=IMAGE_DESC="Cayo Loaded Linux Server Image"

[Output]
ImageId=cayoloaded
Output=cayoloaded
ManifestFormat=json

[Content]
# cayo tree (base server config)
ExtraTrees=%D/shared/cayo/tree
# virt-base tree (incus enable presets, sysusers)
ExtraTrees=%D/shared/packages/virt-base/tree
# docker-onimage tree (docker enable presets, sysusers, tmpfiles)
ExtraTrees=%D/shared/packages/docker-onimage/tree
# OCI postoutput for tags
PostOutputScripts=%D/shared/outformat/oci/postoutput/mkosi.postoutput
# manifest postoutput
PostOutputScripts=%D/shared/manifest/postoutput/mkosi.postoutput
# dracut
PostInstallationScripts=%D/shared/kernel/scripts/postinst/mkosi.postinst.chroot
# image customizations (uses cayo postinstall)
PostInstallationScripts=%D/shared/cayo/scripts/postinstall/cayo.postinst.chroot
# oci finalize
FinalizeScripts=%D/shared/outformat/oci/finalize/mkosi.finalize.chroot
# brew build script
BuildScripts=%D/shared/cayo/scripts/build/brew.chroot

[Include]
# cayo packages (server base + podman)
Include=%D/shared/packages/cayo/mkosi.conf
# backports kernel
Include=%D/shared/kernel/backports/mkosi.conf
# docker on-image
Include=%D/shared/packages/docker-onimage/mkosi.conf
# incus headless (virt-base)
Include=%D/shared/packages/virt-base/mkosi.conf
# OCI Output
Include=%D/shared/outformat/oci/mkosi.conf
```

Key design decisions:
- Uses cayo's tree as base (inherits APT repos, server systemd config, brew setup)
- virt-base tree's `40-incus.preset` (enable) overwrites cayo tree's `40-incus.preset` (disable)
- docker-onimage tree's `30-docker.preset` (enable) overwrites cayo tree's `30-docker.preset` (disable)
- Uses cayo's postinstall script (sets PRETTY_NAME="Cayo Linux", etc.)
- Uses cayo's brew script (writes to cayo tree path)

**Step 2: Verify the cayo postinstall handles IMAGE_ID correctly**

Check `shared/cayo/scripts/postinstall/cayo.postinst.chroot` uses `$IMAGE_ID` for the package list filename. The profile sets `ImageId=cayoloaded` so `IMAGE_ID=cayoloaded`. Verify the postinstall doesn't hardcode "cayo" where it should use `$IMAGE_ID`.

Looking at the postinstall: `apt list --installed 2>/dev/null > /usr/share/frostyard/"${IMAGE_ID}".packages.txt` - uses `$IMAGE_ID`, good.

But: `PRETTY_NAME="Cayo Linux"` and `NAME="Cayo Linux"` are hardcoded. For cayoloaded, these should say "Cayo Loaded Linux" or similar. Options:
- a) Keep "Cayo Linux" for both (simplest - the loaded variant is still Cayo)
- b) Make it configurable via IMAGE_DESC environment variable

Decision: Keep "Cayo Linux" for both. The loaded variant is still Cayo, just with more packages. The IMAGE_ID distinguishes them in package lists and build artifacts.

**Step 3: Commit**

```bash
git add mkosi.profiles/cayoloaded/mkosi.conf
git commit -m "feat: add cayoloaded server profile

cayoloaded = cayo + docker + incus baked in (not sysexts).
Uses virt-base for headless incus and docker-onimage for
baked-in docker. Server-focused, no GUI packages."
```

---

### Task 8: Update CI, Justfile, .gitignore, README

**Files:**
- Modify: `.github/workflows/build-images.yml`
- Modify: `Justfile`
- Modify: `.gitignore` (if needed)
- Modify: `README.md`

**Step 1: Add cayoloaded to CI build matrix**

In `.github/workflows/build-images.yml`, update the matrix:

```yaml
        profile: ["cayo", "cayoloaded", "snow", "snowloaded", "snowfield", "snowfieldloaded"]
```

**Step 2: Add cayoloaded to Justfile**

Add after the `cayo` target:

```just
cayoloaded: clean
    mkosi --profile cayoloaded build
```

**Step 3: Check .gitignore**

The existing `.gitignore` has `shared/cayo/tree/usr/share/homebrew.tar.zst`. cayoloaded uses the same brew script and tree, so no additional entry needed.

**Step 4: Update README**

Add cayo and cayoloaded to the image table (after snowfieldloaded row):

```markdown
| **cayo**            | Headless server with podman + backports kernel      | OCI archive   |
| **cayoloaded**      | cayo + Docker + Incus (baked in)                    | OCI archive   |
```

Update the architecture diagram to include cayo:

```
                              base                <- Debian Trixie + bootc foundation
                                |
                +---------------+---------------+
                |                               |
             sysexts                         profiles
    +----+----+----+----+----+----+            |
    |    |    |    |    |    |    |     +------+------+
  1pass debdev dev docker incus podman |              |
                                     snow           cayo
                               +------+------+       |
                               |      |      |    cayoloaded
                          snowloaded  |  snowfieldloaded
                                  snowfield
```

Update the Profile Structure section:

```
mkosi.profiles/
├── cayo/           <- Headless server + podman
├── cayoloaded/     <- cayo + Docker + Incus
├── snow/           <- GNOME desktop + backports kernel
├── snowfield/      <- GNOME desktop + Surface kernel
├── snowloaded/     <- snow + extra packages (Edge, Incus)
└── snowfieldloaded/<- snowfield + extra packages
```

Update the Profile Comparison table to include cayo variants:

```markdown
| **cayo**            | backports | -                    | `kernel/backports`, `packages/cayo`, `outformat/oci`                            |
| **cayoloaded**      | backports | Docker, Incus        | + `packages/docker-onimage`, `packages/virt-base`                               |
```

Update the Build Commands section:

```bash
# Build cayo server image
just cayo

# Build cayo with docker + incus
just cayoloaded
```

Update the build-images.yml description:

```
1. Runs a matrix build of all 6 profiles (cayo, cayoloaded, snow, snowloaded, snowfield, snowfieldloaded)
```

**Step 5: Commit**

```bash
git add .github/workflows/build-images.yml Justfile README.md
git commit -m "chore: add cayoloaded to CI, Justfile, and README

Add cayoloaded to build matrix, build targets, and
documentation. Update architecture diagram to show
cayo/cayoloaded server variants."
```

---

### Task 9: Shell script hardening and cleanup

**Files:**
- Review: `shared/cayo/scripts/postinstall/cayo.postinst.chroot`
- Review: `shared/cayo/scripts/build/brew.chroot` (created in Task 2)
- Review: `shared/cayo/tree/usr/bin/bbrew-helper`
- Review: `shared/cayo/tree/usr/libexec/bls-gc`
- Review: `shared/cayo/tree/usr/libexec/install-incus-agent`

**Step 1: Review cayo.postinst.chroot**

The script already has `set -euo pipefail`. Check for:
- Unnecessary `env` command on line ~7 (debug output - remove for production)
- Hardcoded paths that should use variables
- Cleanup of commented-out code (`# Add build information to os-release` with commented echo)
- Remove `rm -f /usr/share/applications/fish.desktop` if fish.desktop isn't installed in cayo (it's a desktop file)

**Step 2: Review helper scripts**

Check `usr/bin/bbrew-helper` - already uses `#!/usr/bin/bash`. Consider adding `set -euo pipefail`.

Check `usr/libexec/bls-gc` and `usr/libexec/install-incus-agent` for shell strictness.

**Step 3: Run shellcheck**

```bash
shellcheck shared/cayo/scripts/postinstall/cayo.postinst.chroot
shellcheck shared/cayo/scripts/build/brew.chroot
shellcheck shared/cayo/tree/usr/bin/bbrew-helper
shellcheck shared/cayo/tree/usr/libexec/bls-gc
shellcheck shared/cayo/tree/usr/libexec/install-incus-agent
```

Fix any warnings.

**Step 4: Commit**

```bash
git add shared/cayo/
git commit -m "chore: harden cayo shell scripts

Apply shellcheck fixes, remove debug output, clean up
commented-out code."
```

---

### Task 10: Final validation and PR

**Step 1: Run package dedup check**

```bash
bash check-duplicate-packages.sh
```

Verify no duplicates between cayo and base.

**Step 2: Verify mkosi configs are syntactically valid**

```bash
mkosi --profile cayo summary 2>&1 | head -20
mkosi --profile cayoloaded summary 2>&1 | head -20
```

Both should parse without errors.

**Step 3: Verify all expected files exist**

```bash
# Cayo profile
test -f mkosi.profiles/cayo/mkosi.conf && echo "OK: cayo profile"
test -f shared/packages/cayo/mkosi.conf && echo "OK: cayo packages"
test -f shared/cayo/scripts/build/brew.chroot && echo "OK: cayo brew"
test -f shared/cayo/scripts/postinstall/cayo.postinst.chroot && echo "OK: cayo postinst"

# Cayoloaded profile
test -f mkosi.profiles/cayoloaded/mkosi.conf && echo "OK: cayoloaded profile"

# Virt split
test -f shared/packages/virt-base/mkosi.conf && echo "OK: virt-base packages"
test -f shared/packages/virt/mkosi.conf && echo "OK: virt packages"
test -d shared/packages/virt-base/tree && echo "OK: virt-base tree"

# Docker on-image
test -f shared/packages/docker-onimage/mkosi.conf && echo "OK: docker-onimage"
test -d shared/packages/docker-onimage/tree && echo "OK: docker-onimage tree"
```

**Step 4: Push and create PR**

```bash
git push -u origin cayo --force-with-lease
```

Create PR:

```bash
gh pr create --title "feat: add cayo server image and cayoloaded variant" --body "$(cat <<'EOF'
## Summary

- **cayo**: Headless server image with podman, backports kernel, homebrew, and server-tuned systemd config
- **cayoloaded**: cayo + Docker CE + Incus baked into the image (not sysexts)
- **virt refactor**: Split virt packages into virt-base (headless) and virt (GUI) for reuse
- **docker-onimage**: New shared package set for baking Docker directly into images
- **Package audit**: Removed desktop/mobile packages from cayo (switcheroo-control, modemmanager, etc.)
- **Cleanup**: Shell hardening, snow->cayo naming fixes, cayo-specific brew script

## Architecture

```
cayo = base + cayo packages (podman) + backports kernel + brew
cayoloaded = cayo + docker-onimage + virt-base (headless incus)
```

## Test plan

- [ ] `mkosi --profile cayo summary` parses without errors
- [ ] `mkosi --profile cayoloaded summary` parses without errors
- [ ] `just cayo` builds successfully
- [ ] `just cayoloaded` builds successfully
- [ ] Cayo image boots and podman works
- [ ] Cayoloaded image boots with docker and incus services running
- [ ] snowloaded still builds (virt refactor didn't break it)

Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
