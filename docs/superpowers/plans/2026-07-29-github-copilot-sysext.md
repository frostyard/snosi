# GitHub Copilot Sysext Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub's official Copilot desktop application as the independently updateable, desktop-only `github-copilot` sysext.

**Architecture:** Download the immutable official x86-64 Debian package through Snosi's checksum-verifying helper, install its already-sysext-compatible `/usr` payload into an overlay image, and publish it through the existing component-scoped systemd-sysupdate path. Reuse dpkg package `github` as the version source and the existing required-path and icon-cache finalizers.

**Tech Stack:** mkosi, Debian packages, Bash, systemd-sysext/systemd-sysupdate, GitHub Actions YAML, jq.

## Global Constraints

- The component name is exactly `github-copilot`; the upstream dpkg package name is exactly `github`.
- The initial artifact is `https://github.com/github/app/releases/download/v1.1.2/GitHub-Copilot-linux-x64.deb` with SHA-256 `df80379b8e624eaf751c33758534f111bed7faf09b8d988e59ac7e0ab3dc9ff4`.
- Install the official `.deb`; do not extract the AppImage or add FUSE handling.
- The sysext may ship only `/usr` content and must not add runtime `/etc` or `/var` mutations.
- The feature is disabled by default and offered only to `snow,snowfield`.
- Retain `Verify=false` for this sysext, matching the repository's accepted native sysext-signature risk.
- Do not add a runtime service, preset, sysusers file, tmpfiles rule, `/etc` factory capture, relocation, or desktop-file rewrite.
- Do not commit changes unless the user explicitly requests a commit.

---

### Task 1: Package And Register The Sysext

**Files:**
- Create: `mkosi.images/github-copilot/mkosi.conf`
- Create: `mkosi.images/github-copilot/mkosi.postinst.chroot`
- Create: `mkosi.images/github-copilot/required-paths.txt`
- Create: `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.github-copilot.d/github-copilot.transfer`
- Create: `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.github-copilot.d/github-copilot.feature`
- Modify: `shared/download/sysext-checksums.json`
- Modify: `mkosi.conf:3-22`
- Modify: `check-profile-dependencies.sh:6-20`
- Modify: `test/native-ab-components-test.sh:18-20,527-529`

**Interfaces:**
- Consumes: `verified_download <key> <destination>` from `shared/download/verified-download.sh`; shared sysext post-output and finalize scripts.
- Produces: image `github-copilot`, dpkg key package `github`, systemd-sysupdate component `github-copilot`, and current symlink `/var/lib/extensions.d/github-copilot.raw`.

- [ ] **Step 1: Extend the dependency guard first**

Replace the partial `sysexts` array in `check-profile-dependencies.sh` with the complete root sysext inventory, including the not-yet-created component:

```bash
sysexts=(
    1password
    1password-cli
    azurevpn
    bitwarden
    claude-desktop
    code-server
    coder
    debdev
    dev
    docker
    edge
    github-copilot
    incus
    lemonade
    nix
    paseo
    pilothouse
    podman
    tailscale
    vscode
)
```

- [ ] **Step 2: Run the registration assertion to verify it fails**

Run:

```bash
grep -q '^[[:space:]]*github-copilot$' mkosi.conf
```

Expected: exit 1 because the new root image dependency is not registered yet.

- [ ] **Step 3: Add the pinned download metadata**

Add this object in sorted logical order to `shared/download/sysext-checksums.json` and retain valid JSON:

```json
"github-copilot": {
  "url": "https://github.com/github/app/releases/download/v1.1.2/GitHub-Copilot-linux-x64.deb",
  "sha256": "df80379b8e624eaf751c33758534f111bed7faf09b8d988e59ac7e0ab3dc9ff4",
  "version": "1.1.2"
}
```

- [ ] **Step 4: Create the image configuration**

Create `mkosi.images/github-copilot/mkosi.conf` with exactly this structure:

```ini
[Config]
Dependencies=base

[Output]
ImageId=github-copilot
Output=github-copilot
Overlay=yes
ManifestFormat=json
Format=sysext

[Content]
Bootable=no
BaseTrees=%O/base
PostOutputScripts=%D/shared/sysext/postoutput/sysext-postoutput.sh
FinalizeScripts=%D/shared/sysext/finalize/sysext-required-paths.sh,%D/shared/sysext/finalize/sysext-strip-icon-cache.sh
Packages=libayatana-appindicator3-1
         libwebkit2gtk-4.1-0
         libgtk-3-0

[Build]
Environment=KEYPACKAGE=github
```

- [ ] **Step 5: Create the verified package installer**

Create executable `mkosi.images/github-copilot/mkosi.postinst.chroot`:

```bash
#!/bin/bash
set -euo pipefail

if [[ "${DEBUG_BUILD:-0}" == "1" ]]; then
    set -x
fi

source "$SRCDIR/shared/download/verified-download.sh"
DEBS=$(mktemp -d)
trap 'rm -rf "$DEBS"' EXIT
verified_download "github-copilot" "$DEBS/github-copilot.deb"

dpkg -i "$DEBS/github-copilot.deb"
```

Set mode `0755`. Do not add package extraction or relocation code.
mkosi discovers the conventionally named `mkosi.postinst.chroot` automatically,
matching `mkosi.images/code-server`; do not also list it in
`PostInstallationScripts=`.

- [ ] **Step 6: Add delta integrity assertions**

Create `mkosi.images/github-copilot/required-paths.txt`:

```text
# github-copilot sysext: GitHub Copilot desktop application (Tauri)
/usr/bin/github
/usr/bin/git-credential-copilot
/usr/lib/GitHub Copilot
/usr/share/applications/GitHub Copilot.desktop
/usr/share/icons/hicolor/128x128/apps/github.png
```

- [ ] **Step 7: Add component-scoped update metadata**

Create `github-copilot.transfer`:

```ini
[Transfer]
Features=github-copilot
Verify=false

[Source]
Type=url-file
Path=https://repository.frostyard.org/ext/github-copilot/
MatchPattern=github-copilot_@v_%w_%a.raw.zst \
             github-copilot_@v_%w_%a.raw.xz \
             github-copilot_@v_%w_%a.raw.gz \
             github-copilot_@v_%w_%a.raw

[Target]
Type=regular-file
Path=/var/lib/extensions.d/
MatchPattern=github-copilot_@v_%w_%a.raw.zst \
             github-copilot_@v_%w_%a.raw.xz \
             github-copilot_@v_%w_%a.raw.gz \
             github-copilot_@v_%w_%a.raw
CurrentSymlink=github-copilot.raw
```

Create `github-copilot.feature`:

```ini
[Feature]
Description=GitHub Copilot agent-native desktop application
Documentation=https://github.com/github/app
Enabled=false
X-Snosi-Products=snow,snowfield
```

- [ ] **Step 8: Register the image and runtime inventory**

Add `github-copilot` to root `mkosi.conf`'s `Dependencies=` list in alphabetical position. In `test/native-ab-components-test.sh`, change the header's shipped-component count from 19 to 20 and add `github-copilot` to `expected_sysext_components` in sorted order.

- [ ] **Step 9: Run focused static verification**

Run:

```bash
jq -e '."github-copilot" == {
  url: "https://github.com/github/app/releases/download/v1.1.2/GitHub-Copilot-linux-x64.deb",
  sha256: "df80379b8e624eaf751c33758534f111bed7faf09b8d988e59ac7e0ab3dc9ff4",
  version: "1.1.2"
}' shared/download/sysext-checksums.json
shellcheck mkosi.images/github-copilot/mkosi.postinst.chroot
./check-profile-dependencies.sh
./test/native-ab-contracts-test.sh
```

Expected: jq exits 0, shellcheck emits no findings, and both repository guards pass.

---

### Task 2: Automate Upstream Release Updates

**Files:**
- Modify: `.github/workflows/check-dependencies.yml:54-138,151-279`

**Interfaces:**
- Consumes: `.github/workflows/check-dependencies.yml` helpers `gh_api()` and `ver_gt()` plus checksum key `."github-copilot"` created in Task 1.
- Produces: step outputs `github_copilot_update` and `github_copilot_version`; environment variables `GITHUB_COPILOT_UPDATE` and `GITHUB_COPILOT_VERSION` for the checksum-update step.

- [ ] **Step 1: Confirm updater metadata is not wired yet**

Run:

```bash
if grep -q 'github_copilot_update' .github/workflows/check-dependencies.yml; then
    exit 1
fi
```

Expected: exit 0 before implementation.

- [ ] **Step 2: Add latest-release detection**

Add this block after the Bitwarden check and before code-server:

```bash
# Check GitHub Copilot desktop app
CURRENT_GITHUB_COPILOT=$(jq -r '."github-copilot".version' "$CHECKSUMS")
LATEST_GITHUB_COPILOT=$(gh_api https://api.github.com/repos/github/app/releases | jq -r '[.[] | select(.draft == false and .prerelease == false)][0].tag_name' | sed 's/^v//')
if [[ -n "$LATEST_GITHUB_COPILOT" && "$LATEST_GITHUB_COPILOT" != "null" ]] && ver_gt "$LATEST_GITHUB_COPILOT" "$CURRENT_GITHUB_COPILOT"; then
  UPDATES="${UPDATES}github-copilot: $CURRENT_GITHUB_COPILOT -> $LATEST_GITHUB_COPILOT\n"
  echo "github_copilot_update=true" >> "$GITHUB_OUTPUT"
  echo "github_copilot_version=$LATEST_GITHUB_COPILOT" >> "$GITHUB_OUTPUT"
fi
```

- [ ] **Step 3: Pass outputs through the trusted environment boundary**

Add these entries to the update step's `env:` block:

```yaml
GITHUB_COPILOT_UPDATE: ${{ steps.check.outputs.github_copilot_update }}
GITHUB_COPILOT_VERSION: ${{ steps.check.outputs.github_copilot_version }}
```

- [ ] **Step 4: Add checksum regeneration**

Add this block after Bitwarden's updater branch:

```bash
if [[ "$GITHUB_COPILOT_UPDATE" == "true" ]]; then
  VER="$GITHUB_COPILOT_VERSION"
  URL="https://github.com/github/app/releases/download/v${VER}/GitHub-Copilot-linux-x64.deb"
  TMP=$(mktemp)
  curl -fsSL -o "$TMP" "$URL"
  SHA=$(sha256sum "$TMP" | cut -d' ' -f1)
  jq --arg u "$URL" --arg s "$SHA" --arg v "$VER" \
    '."github-copilot".url=$u | ."github-copilot".sha256=$s | ."github-copilot".version=$v' \
    "$CHECKSUMS" > tmp.json && mv tmp.json "$CHECKSUMS"
  rm -f "$TMP"
fi
```

- [ ] **Step 5: Validate workflow syntax and trust-boundary wiring**

Run:

```bash
actionlint .github/workflows/check-dependencies.yml
grep -q 'github_copilot_update=true' .github/workflows/check-dependencies.yml
grep -q 'GITHUB_COPILOT_VERSION.*steps.check.outputs.github_copilot_version' .github/workflows/check-dependencies.yml
grep -q 'github.com/github/app/releases/download/v${VER}/GitHub-Copilot-linux-x64.deb' .github/workflows/check-dependencies.yml
```

Expected: all commands exit 0 and actionlint emits no findings.

---

### Task 3: Reconcile Documentation And Prove The Build

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `yeti/sysexts.md`
- Modify: `yeti/OVERVIEW.md`
- Modify: `yeti/ci-cd.md`
- Modify: `docs/integration-contracts.md`
- Modify: `docs/native-ab-contracts.md`

**Interfaces:**
- Consumes: the component name, package source, runtime dependencies, and update topology implemented in Tasks 1 and 2.
- Produces: accurate human-facing and AI-facing inventories describing 20 sysexts and the component-scoped update layout.

- [ ] **Step 1: Locate every stale count and complete inventory**

Run:

```bash
rg -n '19 sysext|19 shipped|18 component|17 other|17 pairs|13 sysext|claude-desktop.*code-server|paseo.*pilothouse' CLAUDE.md README.md yeti docs
```

Expected: matches include the known stale inventories identified in the design review; use the output as the exact edit checklist.

- [ ] **Step 2: Update source-of-truth product inventories**

Make these exact semantic changes:

```text
CLAUDE.md:
- Change all complete sysext counts from 19 to 20.
- Insert github-copilot alphabetically in every complete sysext list.

README.md:
- Add a `github-copilot` output row: GitHub Copilot agent-native desktop application; sysext.
- Add it to the architecture diagram, detailed sysext table, and build workflow inventory.
- Reconcile those lists to all 20 root mkosi dependencies rather than preserving pre-existing omissions.
```

- [ ] **Step 3: Document the package and component mechanics**

Make these exact semantic changes:

```text
yeti/sysexts.md:
- Add `github-copilot | github | GitHub Copilot desktop app (official pinned .deb via verified_download; Tauri; native /usr layout)` to Current Sysexts.
- Add github-copilot to the direct-download exception list.
- Add a github-copilot subsection recording: no mkosi.extra, no relocation, no runtime service, no /etc capture, and shared hicolor cache stripping.

yeti/OVERVIEW.md:
- Change complete sysext/component counts to 20.
- Add github-copilot to complete lists and checksum-managed direct downloads.

yeti/ci-cd.md:
- Correct the stale sysext count to 20.

docs/integration-contracts.md:
- Keep pilothouse as the sole Frostyard-authored sysext and change the external count to 19.

docs/native-ab-contracts.md:
- Replace the stale shared-/usr/lib/sysupdate.d description with 20 component-scoped `/usr/lib/sysupdate.<name>.d/` transfer/feature pairs; retain `/usr/lib/sysupdate.d/` for the three OS transfers only.
```

- [ ] **Step 4: Run the full static validation set**

Run:

```bash
jq empty shared/download/sysext-checksums.json
actionlint .github/workflows/check-dependencies.yml
shellcheck mkosi.images/github-copilot/mkosi.postinst.chroot
./check-duplicate-packages.sh
./check-profile-dependencies.sh
./test/native-ab-static-test.sh
./test/native-ab-contracts-test.sh
./check-native-publication-guard.sh
git diff --check
```

Expected: every command exits 0 with no new findings.

- [ ] **Step 5: Resolve and build only the new image**

Run:

```bash
sudo .mkosi/bin/mkosi --image github-copilot summary
sudo .mkosi/bin/mkosi --image github-copilot build
```

Expected: summary resolves `github-copilot` with `KEYPACKAGE=github`; build verifies the pinned hash, installs package `github` version `1.1.2`, passes all five required paths, strips the hicolor cache, and emits a versioned `github-copilot_1.1.2_*` sysext plus manifest. If the repository's pinned mkosi uses a different image-selection spelling, use the equivalent selector reported by `.mkosi/bin/mkosi --help` without changing image semantics.

- [ ] **Step 6: Perform the graphical acceptance smoke where a Snow desktop session is available**

Install or merge the built sysext, start a fresh desktop session so shell caches are refreshed, then run:

```bash
command -v github
gtk-launch 'GitHub Copilot'
xdg-open 'github-app:'
```

Expected: `/usr/bin/github` is selected; the launcher has the GitHub Copilot icon; the application window remains running without dynamic-loader errors; and the registered URL scheme routes to the application. Do not sign in or create a repository session. If no graphical Snow/Snowfield session is available in the execution environment, record this step as not run rather than claiming success.

- [ ] **Step 7: Inspect the final diff**

Run:

```bash
git status --short
git diff --stat
git diff --check
```

Expected: only the planned sysext, updater, tests/inventories, design, plan, and documentation files are changed; no generated build outputs are tracked.
