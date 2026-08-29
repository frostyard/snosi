# Buildah OCI Packaging Implementation Plan

**Status:** Shipped — `shared/outformat/image/buildah-package.sh` packages the rootfs and `mkosi.images/base/mkosi.conf` sets `Format=directory`.  
**Last verified:** 2026-08-29

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace mkosi's broken OCI tar output with `buildah mount` + `cp -a` + `commit` to produce composefs-rs compatible images that preserve all file metadata (SUID, SGID, xattrs, capabilities).

**Architecture:** Switch mkosi from `Format=oci` to `Format=directory` so it outputs a raw rootfs. A new `buildah-package.sh` script packages that rootfs into a proper OCI image using buildah's mount/commit workflow, which bypasses the `COPY`/`buildah copy` SUID-dropping bug. CI and local test workflows call this script instead of skopeo for image creation.

**Tech Stack:** mkosi (directory output), buildah (image packaging), skopeo (registry auth), bash

---

### Task 1: Rename shared output format directory

The directory is called `oci` but will no longer produce OCI directly. Rename for clarity.

**Files:**
- Rename: `shared/outformat/oci/` -> `shared/outformat/image/`

**Step 1: Rename the directory**

```bash
git mv shared/outformat/oci shared/outformat/image
```

**Step 2: Commit**

```bash
git add shared/outformat/image
git commit -m "refactor: rename shared/outformat/oci to shared/outformat/image"
```

---

### Task 2: Change mkosi output format to directory

**Files:**
- Modify: `shared/outformat/image/mkosi.conf`

**Step 1: Update the mkosi output config**

Replace the entire file with:

```ini
[Output]
Format=directory
```

Remove the `OciLabels` and `OciAnnotations` — these are meaningless for directory output and will be applied by buildah instead.

**Step 2: Verify mkosi accepts this**

```bash
sudo mkosi --profile snow summary 2>&1 | grep -i format
```

Expected: shows `Format: directory` (or similar). If mkosi errors on leftover `OciLabels`/`OciAnnotations` in the profile configs, proceed to Task 3. If it silently ignores them, also proceed to Task 3 (we'll clean them up anyway).

**Step 3: Commit**

```bash
git add shared/outformat/image/mkosi.conf
git commit -m "feat: switch mkosi output from OCI to directory format"
```

---

### Task 3: Update all 6 profile configs

Every profile references the old `oci` path in two places: `Include=` and `FinalizeScripts=`. All profiles also have `OciLabels`/`OciAnnotations` that should be removed (buildah will set these).

**Files:**
- Modify: `mkosi.profiles/snow/mkosi.conf`
- Modify: `mkosi.profiles/snowloaded/mkosi.conf`
- Modify: `mkosi.profiles/snowfield/mkosi.conf`
- Modify: `mkosi.profiles/snowfieldloaded/mkosi.conf`
- Modify: `mkosi.profiles/cayo/mkosi.conf`
- Modify: `mkosi.profiles/cayoloaded/mkosi.conf`

**Step 1: In each profile, make these changes:**

1. Change `Include=%D/shared/outformat/oci/mkosi.conf` to `Include=%D/shared/outformat/image/mkosi.conf`
2. Change `FinalizeScripts=%D/shared/outformat/oci/finalize/mkosi.finalize.chroot` to `FinalizeScripts=%D/shared/outformat/image/finalize/mkosi.finalize.chroot`
3. Remove the `OciLabels=` and `OciAnnotations=` lines from the `[Output]` section
4. Update the `# OCI Output` and `# oci finalize` comments to `# Image Output` and `# image finalize`

**Step 2: Verify mkosi summary works**

```bash
sudo mkosi --profile snow summary
```

Expected: no errors, shows `Format: directory`.

**Step 3: Commit**

```bash
git add mkosi.profiles/
git commit -m "refactor: update profiles for directory output format"
```

---

### Task 4: Create buildah-package.sh script

This is the core of the fix. The script packages a rootfs directory into an OCI image using buildah's mount workflow, preserving all file metadata.

**Files:**
- Create: `shared/outformat/image/buildah-package.sh`

**Step 1: Write the script**

```bash
#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Package a rootfs directory into an OCI container image using buildah.
#
# Uses buildah mount + cp -a + commit to preserve ALL file metadata:
# SUID/SGID bits, xattrs, file capabilities, ACLs, hardlinks, ownership.
# This bypasses buildah copy/COPY which has a known SUID-dropping bug.
#
# Usage: buildah-package.sh <rootfs-dir> <image-ref> [label=value ...]
#
# Examples:
#   buildah-package.sh output/snow localhost/snow:latest
#   buildah-package.sh output/snow ghcr.io/frostyard/snow:v1 \
#       org.opencontainers.image.version=v1 \
#       org.opencontainers.image.description="Snow Linux OS Image"
set -euo pipefail

ROOTFS_DIR="$1"
IMAGE_REF="$2"
shift 2

[[ -d "$ROOTFS_DIR" ]] || { echo "Error: rootfs directory does not exist: $ROOTFS_DIR" >&2; exit 1; }

echo "=== Packaging rootfs into OCI image ==="
echo "  rootfs: $ROOTFS_DIR"
echo "  image:  $IMAGE_REF"

# Create empty container
container=$(buildah from scratch)

# Mount and copy rootfs preserving all metadata
mountpoint=$(buildah mount "$container")
cp -a "$ROOTFS_DIR"/. "$mountpoint"/
buildah umount "$container"

# Apply standard bootc labels
buildah config \
    --label "containers.bootc=1" \
    --label "org.opencontainers.image.vendor=frostyard" \
    "$container"

# Apply additional labels passed as arguments
for label in "$@"; do
    buildah config --label "$label" "$container"
done

# Commit to image
buildah commit "$container" "$IMAGE_REF"
buildah rm "$container"

echo "=== Image packaged: $IMAGE_REF ==="
```

**Step 2: Make executable**

```bash
chmod +x shared/outformat/image/buildah-package.sh
```

**Step 3: Verify the script works locally (requires sudo + buildah)**

```bash
# Build a rootfs first
sudo mkosi --profile snow build

# Package it
sudo ./shared/outformat/image/buildah-package.sh output/snow localhost/snow-test:latest

# Verify SUID bits survived
sudo podman run --rm localhost/snow-test:latest stat -c '%a %n' /usr/bin/sudo
# Expected: 4755 /usr/bin/sudo (or similar, the leading 4 indicates SUID)

# Verify bootc label
sudo podman inspect localhost/snow-test:latest | grep containers.bootc
# Expected: "containers.bootc": "1"

# Cleanup
sudo podman rmi localhost/snow-test:latest
```

**Step 4: Commit**

```bash
git add shared/outformat/image/buildah-package.sh
git commit -m "feat: add buildah-package.sh for metadata-preserving OCI packaging"
```

---

### Task 5: Update CI workflow

Replace the skopeo-based OCI push with buildah packaging + push. The mkosi build step no longer needs `--oci-labels`/`--oci-annotations` since buildah handles them.

**Files:**
- Modify: `.github/workflows/build-images.yml`

**Step 1: Update the matrix to include per-profile descriptions**

Change the matrix from a simple list to an include-based matrix so each profile carries its description:

```yaml
    strategy:
      matrix:
        include:
          - profile: cayo
            description: "Cayo Linux Server Image"
          - profile: cayoloaded
            description: "Cayo Loaded Linux Server Image"
          - profile: snow
            description: "Snow Linux OS Image"
          - profile: snowloaded
            description: "Snow Loaded Linux OS Image"
          - profile: snowfield
            description: "Snowfield Linux OS Image"
          - profile: snowfieldloaded
            description: "Snow Field Loaded Linux OS Image"
```

**Step 2: Simplify the mkosi build step**

Remove `--oci-labels` and `--oci-annotations` flags (buildah will set these). Keep `--image-version` for manifest versioning:

```yaml
      - name: Build Image
        run: |
          sudo mkosi --profile ${{ matrix.profile }} \
            --image-version "${{ steps.version.outputs.tag }}" \
            build
```

**Step 3: Replace the skopeo push step with buildah package + push**

Replace the "Push image to registry" step:

```yaml
      - name: Package and push image
        if: github.event_name != 'pull_request'
        env:
          IMAGE: ghcr.io/${{ github.repository_owner }}/${{ matrix.profile }}
        run: |
          # Package rootfs into OCI image with buildah
          sudo ./shared/outformat/image/buildah-package.sh \
            output/${{ matrix.profile }} \
            "$IMAGE:${{ steps.version.outputs.tag }}" \
            "org.opencontainers.image.title=${{ matrix.profile }}" \
            "org.opencontainers.image.description=${{ matrix.description }}" \
            "org.opencontainers.image.version=${{ steps.version.outputs.tag }}" \
            "org.opencontainers.image.created=${{ steps.date.outputs.date }}" \
            "org.opencontainers.image.source=https://github.com/${{ github.repository_owner }}/${{ env.REPO_NAME }}/blob/${{ github.sha }}/mkosi.conf" \
            "org.opencontainers.image.url=https://github.com/${{ github.repository_owner }}/${{ env.REPO_NAME }}/tree/${{ github.sha }}" \
            "org.opencontainers.image.documentation=https://raw.githubusercontent.com/${{ github.repository_owner }}/${{ env.REPO_NAME }}/${{ github.sha }}/README.md"

          # Push versioned tag
          sudo buildah push \
            --creds="${{ github.actor }}:${{ secrets.GHCR_PAT }}" \
            "$IMAGE:${{ steps.version.outputs.tag }}" \
            "docker://$IMAGE:${{ steps.version.outputs.tag }}"

          # Tag and push latest
          sudo buildah tag \
            "$IMAGE:${{ steps.version.outputs.tag }}" \
            "$IMAGE:latest"
          sudo buildah push \
            --creds="${{ github.actor }}:${{ secrets.GHCR_PAT }}" \
            "$IMAGE:latest" \
            "docker://$IMAGE:latest"
```

**Step 4: Remove the skopeo login step**

The skopeo login step can be removed since `buildah push --creds` handles auth inline. If other steps still need skopeo auth, keep it.

**Step 5: Commit**

```bash
git add .github/workflows/build-images.yml
git commit -m "feat: use buildah for OCI image packaging in CI

Replaces skopeo copy of mkosi OCI output with buildah mount+cp+commit.
Preserves SUID/SGID bits, xattrs, and file capabilities that were
lost with the previous approach."
```

---

### Task 6: Update test script for directory input

The test script currently handles OCI directory input via skopeo + podman export/import re-layering. With directory output, it needs to use buildah instead.

**Files:**
- Modify: `test/bootc-install-test.sh`

**Step 1: Replace the local path handling in Step 1 (Load image)**

The registry ref path stays the same. The local path handling changes from skopeo+podman to buildah:

Replace lines 91-122 (the `else` branch of `is_registry_ref`) with:

```bash
    # Local rootfs directory
    [[ -e "$INPUT" ]] || { echo "Error: Path does not exist: $INPUT" >&2; exit 1; }
    [[ -d "$INPUT" ]] || { echo "Error: $INPUT is not a directory" >&2; exit 1; }

    IMAGE_REF="localhost/snosi-test:latest"
    IMAGE_LOADED="$IMAGE_REF"

    # Package rootfs directory into OCI image using buildah.
    # Uses mount + cp -a + commit to preserve SUID/SGID, xattrs, capabilities.
    SCRIPT_DIR_ABS="$(cd "$SCRIPT_DIR/.." && pwd)"
    "$SCRIPT_DIR_ABS/shared/outformat/image/buildah-package.sh" \
        "$INPUT" "$IMAGE_REF"

    echo "Image loaded as: $IMAGE_REF"
```

**Step 2: Update the cleanup function**

The cleanup already handles `IMAGE_LOADED` via `podman rmi`. Since buildah commit stores in the same containers-storage, `podman rmi` still works. No change needed.

**Step 3: Update the comment at the top of the file**

Change the header comment to reflect that it accepts a rootfs directory (not OCI directory):

```bash
# Usage: ./test/bootc-install-test.sh <rootfs-directory-or-registry-ref>
#
# Examples:
#   ./test/bootc-install-test.sh output/snow              # rootfs directory from mkosi
#   ./test/bootc-install-test.sh ghcr.io/frostyard/snow:latest  # registry ref
```

**Step 4: Commit**

```bash
git add test/bootc-install-test.sh
git commit -m "feat: update test script to package rootfs via buildah

Replaces the lossy podman export/import re-layering workaround with
buildah mount+cp+commit, which preserves all file metadata."
```

---

### Task 7: Verify end-to-end locally

This task validates the full pipeline before pushing.

**Step 1: Build a rootfs**

```bash
just snow
```

Verify output is a rootfs directory (not OCI):

```bash
ls output/snow/
# Expected: usr/ etc/ var/ boot/ ... (rootfs tree, NOT oci-layout/index.json/blobs/)
```

**Step 2: Test the buildah packaging script standalone**

```bash
sudo ./shared/outformat/image/buildah-package.sh output/snow localhost/snow-verify:latest

# Check SUID on sudo
sudo podman run --rm localhost/snow-verify:latest stat -c '%a %n' /usr/bin/sudo
# Expected: 4755 /usr/bin/sudo

# Check file capabilities on ping (if present)
sudo podman run --rm localhost/snow-verify:latest getcap /usr/bin/ping
# Expected: /usr/bin/ping cap_net_raw=ep (or similar)

# Check bootc label
sudo podman inspect localhost/snow-verify:latest | grep -A1 containers.bootc
# Expected: "containers.bootc": "1"

# Cleanup
sudo podman rmi localhost/snow-verify:latest
```

**Step 3: Run the full integration test**

```bash
just test-install output/snow
```

Expected: VM boots, SSH connects, all test tiers pass.

**Step 4: Commit (if any fixups needed)**

---

### Task 8: Update CLAUDE.md if needed

If any conventions changed (e.g., output format references, script pipeline docs), update CLAUDE.md to reflect the new architecture.

**Files:**
- Modify: `CLAUDE.md` (only if needed)

**Step 1: Check if CLAUDE.md references the old path or format**

Search for `shared/outformat/oci` and `Format=oci` in CLAUDE.md. Update any references to reflect the new `shared/outformat/image` path and `Format=directory` output.

**Step 2: Commit if changed**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for directory output format"
```

---

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| mkosi errors on `OciLabels`/`OciAnnotations` with `Format=directory` | Task 2 removes them from shared config; Task 3 removes from profiles |
| `buildah` not available on CI runner | Pre-installed on `ubuntu-24.04` (buildah 1.33.7). Fallback: `sudo apt-get install buildah` |
| Disk space doubled during `cp -a` | CI aggressive cleanup already frees ~30GB. Can `rm -rf output/$profile` after buildah commit if tight |
| `buildah push` auth doesn't work with skopeo-stored creds | Using `--creds` flag directly on `buildah push` instead |
| `--image-version` flag breaks with `Format=directory` | Keep it — only affects manifest postoutput script via `$IMAGE_VERSION` env var, not the directory name |

## Rollback

If this breaks CI: revert all commits and re-add `Format=oci` to `shared/outformat/image/mkosi.conf` (renaming back to `oci/` is optional). The git history from PR #83's revert shows the previous working state.
