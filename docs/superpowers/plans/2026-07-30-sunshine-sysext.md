# Sunshine Sysext Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add LizardByte Sunshine as an independently updateable, desktop-only `sunshine` sysext that users start explicitly from its desktop launcher.

**Architecture:** Download the immutable official Debian Trixie package through Snosi's checksum-verifying helper, install its native `/usr` payload and runtime dependencies into an overlay image, and publish it through the existing component-scoped systemd-sysupdate path. Preserve upstream's user service, udev rules, module loading, and file capabilities, but add no automatic user-session activation.

**Tech Stack:** mkosi, Debian packages, Bash, systemd-sysext/systemd-sysupdate, systemd user units, udev, Linux file capabilities, GitHub Actions YAML, jq.

## Global Constraints

- The component and dpkg package names are exactly `sunshine`.
- The initial artifact is `https://github.com/LizardByte/Sunshine/releases/download/v2026.516.143833/sunshine-debian-trixie-amd64.deb` with SHA-256 `b9b65f2be93b3e30be0710a940a616b1381da5bc6d858dce33bc0094d7fd4131` and version `2026.516.143833`.
- Install the official `.deb` through `verified_download()` and `dpkg -i`; do not extract or maintain a downstream repack.
- The sysext may ship only `/usr` content and must not add runtime `/etc` or `/var` mutations.
- Preserve `cap_sys_admin,cap_sys_nice+p` on `/usr/bin/sunshine`, `60-sunshine.rules`, and `60-sunshine.conf`.
- Preserve upstream's user service and desktop launcher, but do not add a user preset, static target link, or `Upholds=` activation.
- The feature is disabled by default and offered only to `snow,snowfield`.
- Retain `Verify=false`, matching the repository's accepted native sysext-signature risk.
- Strip any hicolor icon cache from the sysext delta.
- Update relevant documentation in `CLAUDE.md`, `README.md`, and `yeti/`.

---

### Task 1: Package And Register Sunshine

**Files:**
- Create: `mkosi.images/sunshine/mkosi.conf`
- Create: `mkosi.images/sunshine/mkosi.postinst.chroot`
- Create: `mkosi.images/sunshine/required-paths.txt`
- Create: `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.sunshine.d/sunshine.transfer`
- Create: `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.sunshine.d/sunshine.feature`
- Modify: `shared/download/sysext-checksums.json`
- Modify: `mkosi.conf:3-23`
- Modify: `check-profile-dependencies.sh:7-28`
- Modify: `test/native-ab-components-test.sh:527-529`

**Interfaces:**
- Consumes: `verified_download <key> <destination>` from `shared/download/verified-download.sh`; the shared sysext post-output, required-path, and icon-cache finalizers.
- Produces: image `sunshine`, dpkg version source `sunshine`, systemd-sysupdate component `sunshine`, and current symlink `/var/lib/extensions.d/sunshine.raw`.

- [ ] **Step 1: Add failing inventory assertions**

Add `sunshine` in alphabetical position to `check-profile-dependencies.sh`'s `sysexts` array and `test/native-ab-components-test.sh`'s `expected_sysext_components` array. Do not add it to `mkosi.conf` yet.

- [ ] **Step 2: Prove the new registration assertion fails**

Run:

```bash
grep -q '^[[:space:]]*sunshine$' mkosi.conf
```

Expected: exit 1 because the root dependency is not registered yet.

- [ ] **Step 3: Add immutable download metadata**

Add this object to `shared/download/sysext-checksums.json` and retain valid JSON:

```json
"sunshine": {
  "url": "https://github.com/LizardByte/Sunshine/releases/download/v2026.516.143833/sunshine-debian-trixie-amd64.deb",
  "sha256": "b9b65f2be93b3e30be0710a940a616b1381da5bc6d858dce33bc0094d7fd4131",
  "version": "2026.516.143833"
}
```

- [ ] **Step 4: Create the sysext configuration**

Create `mkosi.images/sunshine/mkosi.conf`:

```ini
[Config]
Dependencies=base

[Output]
ImageId=sunshine
Output=sunshine
Overlay=yes
ManifestFormat=json
Format=sysext

[Content]
Bootable=no
BaseTrees=%O/base
PostOutputScripts=%D/shared/sysext/postoutput/sysext-postoutput.sh
FinalizeScripts=%D/shared/sysext/finalize/sysext-required-paths.sh,%D/shared/sysext/finalize/sysext-strip-icon-cache.sh
Packages=debianutils
         libcap2
         libcurl4t64
         libdrm2
         libevdev2
         libgbm1
         libglib2.0-0t64
         libgtk-3-0t64
         libayatana-appindicator3-1
         libicu76
         libminiupnpc18
         libnotify4
         libnuma1
         libopus0
         libpipewire-0.3-0t64
         libpulse0
         libssl3t64
         libva2
         libva-drm2
         libvulkan1
         libwayland-client0
         libx11-6

[Build]
Environment=KEYPACKAGE=sunshine
```

Use the Trixie package names from the upstream package's generated dependency list; do not retain duplicate compatibility alternatives such as both `libcurl4` and `libcurl4t64`.

- [ ] **Step 5: Create the verified package installer**

Create executable `mkosi.images/sunshine/mkosi.postinst.chroot`:

```bash
#!/bin/bash
set -euo pipefail

if [[ "${DEBUG_BUILD:-0}" == "1" ]]; then
    set -x
fi

# shellcheck disable=SC1091
source "$SRCDIR/shared/download/verified-download.sh"
DEBS=$(mktemp -d)
trap 'rm -rf "$DEBS"' EXIT
verified_download "sunshine" "$DEBS/sunshine.deb"

dpkg -i "$DEBS/sunshine.deb"
```

Set mode `0755`. Let mkosi discover the conventionally named postinstall; do not duplicate it in `PostInstallationScripts=`.

- [ ] **Step 6: Define the shipped-payload contract**

Create `mkosi.images/sunshine/required-paths.txt`:

```text
# sunshine sysext: self-hosted game streaming host for Moonlight
/usr/bin/sunshine
/usr/lib/modules-load.d/60-sunshine.conf
/usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service
/usr/lib/udev/rules.d/60-sunshine.rules
/usr/share/applications/dev.lizardbyte.app.Sunshine.desktop
/usr/share/icons/hicolor/scalable/apps/dev.lizardbyte.app.Sunshine.svg
/usr/share/sunshine/apps.json
/usr/share/sunshine/web/index.html
```

- [ ] **Step 7: Add component-scoped update metadata**

Create `sunshine.transfer`:

```ini
[Transfer]
Features=sunshine
Verify=false

[Source]
Type=url-file
Path=https://repository.frostyard.org/ext/sunshine/
MatchPattern=sunshine_@v_%w_%a.raw.zst \
             sunshine_@v_%w_%a.raw.xz \
             sunshine_@v_%w_%a.raw.gz \
             sunshine_@v_%w_%a.raw

[Target]
Type=regular-file
Path=/var/lib/extensions.d/
MatchPattern=sunshine_@v_%w_%a.raw.zst \
             sunshine_@v_%w_%a.raw.xz \
             sunshine_@v_%w_%a.raw.gz \
             sunshine_@v_%w_%a.raw
CurrentSymlink=sunshine.raw
```

Create `sunshine.feature`:

```ini
[Feature]
Description=Self-hosted game streaming host for Moonlight
Documentation=https://docs.lizardbyte.dev/projects/sunshine/
Enabled=false
X-Snosi-Products=snow,snowfield
```

- [ ] **Step 8: Register the image**

Add `sunshine` in alphabetical position to root `mkosi.conf`'s `Dependencies=` list. Keep the guard and native component arrays alphabetically aligned with the root inventory.

- [ ] **Step 9: Run focused static checks**

Run:

```bash
jq -e '.sunshine == {
  url: "https://github.com/LizardByte/Sunshine/releases/download/v2026.516.143833/sunshine-debian-trixie-amd64.deb",
  sha256: "b9b65f2be93b3e30be0710a940a616b1381da5bc6d858dce33bc0094d7fd4131",
  version: "2026.516.143833"
}' shared/download/sysext-checksums.json
shellcheck mkosi.images/sunshine/mkosi.postinst.chroot
./test/native-ab-contracts-test.sh
```

Expected: all commands exit 0 with no findings.

- [ ] **Step 10: Commit the package and component**

```bash
git add mkosi.images/sunshine mkosi.images/base/mkosi.extra/usr/lib/sysupdate.sunshine.d \
  shared/download/sysext-checksums.json mkosi.conf check-profile-dependencies.sh \
  test/native-ab-components-test.sh
git commit -m "feat: add Sunshine sysext"
```

---

### Task 2: Automate Sunshine Release Updates

**Files:**
- Modify: `.github/workflows/check-dependencies.yml:54-147,155-300`

**Interfaces:**
- Consumes: workflow helpers `gh_api()` and `ver_gt()` plus checksum key `.sunshine` from Task 1.
- Produces: outputs `sunshine_update` and `sunshine_version`, passed as `SUNSHINE_UPDATE` and `SUNSHINE_VERSION` to checksum regeneration.

- [ ] **Step 1: Prove updater wiring is absent**

Run:

```bash
if grep -q 'sunshine_update' .github/workflows/check-dependencies.yml; then
    exit 1
fi
```

Expected: exit 0 before implementation.

- [ ] **Step 2: Add latest stable release detection**

Add after the GitHub Copilot check:

```bash
# Check Sunshine
CURRENT_SUNSHINE=$(jq -r '.sunshine.version' "$CHECKSUMS")
LATEST_SUNSHINE=$(gh_api https://api.github.com/repos/LizardByte/Sunshine/releases | jq -r '[.[] | select(.draft == false and .prerelease == false)][0].tag_name' | sed 's/^v//')
if [[ -n "$LATEST_SUNSHINE" && "$LATEST_SUNSHINE" != "null" ]] && ver_gt "$LATEST_SUNSHINE" "$CURRENT_SUNSHINE"; then
  UPDATES="${UPDATES}sunshine: $CURRENT_SUNSHINE -> $LATEST_SUNSHINE\n"
  echo "sunshine_update=true" >> "$GITHUB_OUTPUT"
  echo "sunshine_version=$LATEST_SUNSHINE" >> "$GITHUB_OUTPUT"
fi
```

- [ ] **Step 3: Pass outputs through environment variables**

Add to the checksum-update step's `env:` block:

```yaml
SUNSHINE_UPDATE: ${{ steps.check.outputs.sunshine_update }}
SUNSHINE_VERSION: ${{ steps.check.outputs.sunshine_version }}
```

- [ ] **Step 4: Add checksum regeneration**

Add after the GitHub Copilot updater branch:

```bash
if [[ "$SUNSHINE_UPDATE" == "true" ]]; then
  VER="$SUNSHINE_VERSION"
  URL="https://github.com/LizardByte/Sunshine/releases/download/v${VER}/sunshine-debian-trixie-amd64.deb"
  TMP=$(mktemp)
  curl -fsSL -o "$TMP" "$URL"
  SHA=$(sha256sum "$TMP" | cut -d' ' -f1)
  jq --arg u "$URL" --arg s "$SHA" --arg v "$VER" \
    '.sunshine.url=$u | .sunshine.sha256=$s | .sunshine.version=$v' \
    "$CHECKSUMS" > tmp.json && mv tmp.json "$CHECKSUMS"
  rm -f "$TMP"
fi
```

- [ ] **Step 5: Validate workflow syntax and data flow**

Run:

```bash
actionlint .github/workflows/check-dependencies.yml
grep -q 'sunshine_update=true' .github/workflows/check-dependencies.yml
grep -q 'SUNSHINE_VERSION.*steps.check.outputs.sunshine_version' .github/workflows/check-dependencies.yml
grep -q 'LizardByte/Sunshine/releases/download/v${VER}/sunshine-debian-trixie-amd64.deb' .github/workflows/check-dependencies.yml
```

Expected: all commands exit 0 and actionlint emits no findings.

- [ ] **Step 6: Commit updater automation**

```bash
git add .github/workflows/check-dependencies.yml
git commit -m "ci: track Sunshine releases"
```

---

### Task 3: Document And Prove The Runtime Contract

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `yeti/OVERVIEW.md`
- Modify: `yeti/sysexts.md`
- Modify: any exact sysext count/list found by the inventory search

**Interfaces:**
- Consumes: component behavior implemented in Tasks 1 and 2.
- Produces: synchronized human and AI documentation plus static and artifact-level verification evidence.

- [ ] **Step 1: Inventory exact sysext lists and counts**

Run:

```bash
rg -n '20 sysext|20 shipped|github-copilot.*incus|pilothouse.*podman|vscode\)' CLAUDE.md README.md yeti docs test check-profile-dependencies.sh mkosi.conf
```

Expected: output identifies all complete inventories that must become 21-component inventories. Do not update historical statements whose count is intentionally tied to an earlier event.

- [ ] **Step 2: Update project inventories**

Apply these semantic changes:

```text
CLAUDE.md:
- Change the current output count from 20 to 21 and insert sunshine alphabetically in the complete list.
- Add a concise Sunshine sysext note recording the official pinned Trixie deb, manual user-service startup, retained capability, uhid modules-load entry, udev rules, and desktop-only scope.

README.md:
- Add Sunshine to output, detailed sysext, command/example, architecture, and CI inventory lists.
- Describe it as a self-hosted game streaming host for Moonlight.
- Reconcile current complete counts to 21.

yeti/OVERVIEW.md:
- Add Sunshine to complete sysext lists and direct-download dependency descriptions.
- Reconcile current complete counts to 21.

yeti/sysexts.md:
- Add `sunshine | sunshine | Sunshine self-hosted game streaming host (official pinned Trixie .deb via verified_download)` to Current Sysexts.
- Add Sunshine to the direct-download exception list.
- Add a Sunshine subsection documenting native /usr layout, upstream user unit and manual launcher, no preset/Upholds activation, retained cap_sys_admin/cap_sys_nice file capability, uhid modules-load and udev access rules, and hicolor cache stripping.
```

- [ ] **Step 3: Run repository static validation**

Run:

```bash
jq empty shared/download/sysext-checksums.json
actionlint .github/workflows/check-dependencies.yml
shellcheck mkosi.images/sunshine/mkosi.postinst.chroot
./test/verified-download-split-checksums-test.sh
./test/sysext-required-paths-test.sh
./test/native-ab-contracts-test.sh
./check-runtime-etc-guard.sh
git diff --check
```

Expected: every command exits 0 with no new findings.

- [ ] **Step 4: Validate resolved mkosi configuration**

Run:

```bash
sudo .mkosi/bin/mkosi summary > /dev/null
./check-profile-dependencies.sh
sudo .mkosi/bin/mkosi --image sunshine summary
```

Expected: all commands exit 0; Sunshine resolves as an overlay sysext with `KEYPACKAGE=sunshine`, while each OCI profile remains dependent only on `base`.

- [ ] **Step 5: Build Sunshine and inspect its artifacts**

Run:

```bash
sudo .mkosi/bin/mkosi --image sunshine build
```

Expected: checksum verification succeeds, dpkg installs Sunshine `2026.516.143833`, every required path passes, the icon cache is stripped, and post-output emits a versioned `sunshine_2026.516.143833_*` sysext plus manifest.

Identify the uncompressed sysext artifact emitted in `output/`, then mount it read-only at a temporary directory and run:

```bash
getcap <mountpoint>/usr/bin/sunshine
test ! -e <mountpoint>/usr/share/icons/hicolor/icon-theme.cache
test -f <mountpoint>/usr/lib/modules-load.d/60-sunshine.conf
test -f <mountpoint>/usr/lib/udev/rules.d/60-sunshine.rules
test -f <mountpoint>/usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service
grep -qx 'uhid' <mountpoint>/usr/lib/modules-load.d/60-sunshine.conf
```

Expected: `getcap` prints `<mountpoint>/usr/bin/sunshine cap_sys_admin,cap_sys_nice=p`; every other command exits 0. Keep the artifact mounted through Step 6. If mkosi emits only a compressed artifact, decompress it to `/tmp/opencode` before mounting; do not alter tracked outputs.

- [ ] **Step 6: Verify manifest and manual-start policy**

Run against the emitted manifest and mounted artifact:

```bash
jq -e '.. | objects | select(.name? == "sunshine") | .version == "2026.516.143833"' output/sunshine*.manifest
grep -q '^WantedBy=graphical-session.target$' <mountpoint>/usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service
! test -e <mountpoint>/usr/lib/systemd/user-preset/40-sunshine.preset
! find <mountpoint>/usr/lib/systemd/user -path '*/graphical-session.target.wants/*Sunshine*' -print -quit | grep -q .
```

Expected: all commands exit 0, proving the package version and that Sunshine is available through its installable user unit without sysext-added automatic activation.

Unmount the artifact and remove its temporary mount directory after these checks.

- [ ] **Step 7: Commit documentation and any verification fixes**

```bash
git add CLAUDE.md README.md yeti/OVERVIEW.md yeti/sysexts.md
git add -u
git commit -m "docs: document Sunshine sysext"
```

- [ ] **Step 8: Inspect the complete branch**

Run:

```bash
git status --short
git diff --check origin/main...HEAD
git diff --stat origin/main...HEAD
git log --oneline origin/main..HEAD
```

Expected: the worktree is clean; only the design, plan, Sunshine implementation, inventories/tests, updater, and documentation differ from `origin/main`.

---

### Task 4: Publish The Pull Request

**Files:**
- Create remotely: pull request targeting `main`

**Interfaces:**
- Consumes: verified commits from Tasks 1-3.
- Produces: a GitHub pull request for review.

- [ ] **Step 1: Rebase the implementation on current main if needed**

Run:

```bash
git fetch origin main
git merge-base --is-ancestor origin/main HEAD
```

Expected: exit 0. If it exits 1, merge `origin/main` non-interactively, resolve only Sunshine-related conflicts, and rerun the full Task 3 static validation.

- [ ] **Step 2: Push the feature branch**

Run:

```bash
git push -u origin HEAD
```

Expected: push succeeds and establishes upstream tracking.

- [ ] **Step 3: Open the pull request**

Run:

```bash
gh pr create --base main --head "$(git branch --show-current)" \
  --title "feat: add Sunshine sysext" \
  --body-file /tmp/opencode/sunshine-pr-body.md
```

Before the command, create `/tmp/opencode/sunshine-pr-body.md` containing:

```markdown
## Summary
- add the official pinned Sunshine Trixie package as a desktop-only sysext
- preserve upstream uhid, udev, file-capability, and manual user-service behavior
- add component publication metadata and automated release tracking

## Testing
- list each static command run and its result
- record the real sysext build and capability inspection result
- identify any environment-blocked check explicitly instead of claiming it passed
```

Expected: `gh` returns the new pull request URL targeting `main`.
