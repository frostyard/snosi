# Containerfile Build Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace mkosi's broken OCI output with a Containerfile build that copies in mkosi's directory output, fixing the PAX header bug that breaks bootc/composefs.

**Architecture:** mkosi builds rootfs as `Format=directory`. A 2-line `Containerfile` (`FROM scratch` / `COPY . /`) packages it into a proper OCI image via podman (local) or buildah (CI). Labels/annotations passed via build-time flags only.

**Tech Stack:** mkosi, podman, buildah, just, GitHub Actions (redhat-actions/buildah-build, redhat-actions/push-to-registry)

**Design doc:** `docs/plans/2026-02-20-containerfile-build-design.md`

---

### Task 1: Rename shared/outformat/oci/ to shared/outformat/image/

**Files:**
- Rename: `shared/outformat/oci/` -> `shared/outformat/image/`

**Step 1: Rename the directory via git mv**

```bash
git mv shared/outformat/oci shared/outformat/image
```

**Step 2: Verify the finalize script is intact**

```bash
cat shared/outformat/image/finalize/mkosi.finalize.chroot
```

Expected: the bootc cleanup script (rm /boot, /home, etc.) unchanged.

**Step 3: Commit**

```bash
git add -A && git commit -m "refactor: rename shared/outformat/oci to shared/outformat/image"
```

---

### Task 2: Change mkosi output format from OCI to directory

**Files:**
- Modify: `shared/outformat/image/mkosi.conf`

**Step 1: Replace the mkosi.conf contents**

Change from:

```ini
[Output]
Format=oci
OciLabels=containers.bootc=1
          org.opencontainers.image.title=%i
OciAnnotations=containers.bootc=1
               org.opencontainers.image.vendor=frostyard
               org.opencontainers.image.title=%i
```

To:

```ini
[Output]
Format=directory
```

Remove all `OciLabels` and `OciAnnotations` lines (they don't apply to directory format).

**Step 2: Commit**

```bash
git add shared/outformat/image/mkosi.conf && git commit -m "feat: switch mkosi output from oci to directory format"
```

---

### Task 3: Update all 6 profile configs

**Files:**
- Modify: `mkosi.profiles/snow/mkosi.conf`
- Modify: `mkosi.profiles/snowloaded/mkosi.conf`
- Modify: `mkosi.profiles/snowfield/mkosi.conf`
- Modify: `mkosi.profiles/snowfieldloaded/mkosi.conf`
- Modify: `mkosi.profiles/cayo/mkosi.conf`
- Modify: `mkosi.profiles/cayoloaded/mkosi.conf`

For each profile, make these 3 edits:

**Step 1: Update Include path**

Change:
```
Include=%D/shared/outformat/oci/mkosi.conf
```
To:
```
Include=%D/shared/outformat/image/mkosi.conf
```

Also update the comment from `# OCI Output` to `# Image Output`.

**Step 2: Update FinalizeScripts path**

Change:
```
FinalizeScripts=%D/shared/outformat/oci/finalize/mkosi.finalize.chroot
```
To:
```
FinalizeScripts=%D/shared/outformat/image/finalize/mkosi.finalize.chroot
```

Also update the comment from `# oci finalize` to `# image finalize`.

**Step 3: Remove OciLabels and OciAnnotations lines**

Delete these two lines from each profile's `[Output]` section:

```
OciLabels=org.opencontainers.image.description="..."
OciAnnotations=org.opencontainers.image.description="..."
```

**Step 4: Commit**

```bash
git add mkosi.profiles/*/mkosi.conf && git commit -m "refactor: update profile configs for directory output and image paths"
```

---

### Task 4: Create the Containerfile

**Files:**
- Create: `Containerfile`

**Step 1: Create the Containerfile at repo root**

```dockerfile
FROM scratch
COPY . /
```

That's it. Two lines.

**Step 2: Commit**

```bash
git add Containerfile && git commit -m "feat: add Containerfile for OCI image build from directory output"
```

---

### Task 5: Update the Justfile

**Files:**
- Modify: `Justfile`

**Step 1: Add the _containerfile-build helper recipe**

Add this private recipe (after the existing private targets):

```just
[private]
_containerfile-build profile description:
    podman build \
      --label containers.bootc=1 \
      --annotation containers.bootc=1 \
      --annotation org.opencontainers.image.vendor=frostyard \
      --annotation "org.opencontainers.image.title={{profile}}" \
      --annotation "org.opencontainers.image.description={{description}}" \
      -f Containerfile \
      -t {{profile}} \
      output/{{profile}}/
```

**Step 2: Update each public profile target**

Each public target now chains mkosi (sudo) then containerfile-build (user). Update all 6:

```just
snow:
    sudo PATH="$PATH" {{just}} _snow
    {{just}} _containerfile-build snow "Snow Linux OS Image"

snowloaded:
    sudo PATH="$PATH" {{just}} _snowloaded
    {{just}} _containerfile-build snowloaded "Snow Loaded Linux OS Image"

snowfield:
    sudo PATH="$PATH" {{just}} _snowfield
    {{just}} _containerfile-build snowfield "Snowfield Linux OS Image"

snowfieldloaded:
    sudo PATH="$PATH" {{just}} _snowfieldloaded
    {{just}} _containerfile-build snowfieldloaded "Snow Field Loaded Linux OS Image"

cayo:
    sudo PATH="$PATH" {{just}} _cayo
    {{just}} _containerfile-build cayo "Cayo Linux Server Image"

cayoloaded:
    sudo PATH="$PATH" {{just}} _cayoloaded
    {{just}} _containerfile-build cayoloaded "Cayo Loaded Linux Server Image"
```

**Step 3: Update the test-install target**

Change the default from a path to an image name:

```just
test-install image="snow":
    sudo PATH="$PATH" {{just}} _test-install {{image}}
```

**Step 4: Commit**

```bash
git add Justfile && git commit -m "feat: add containerfile-build step to Justfile targets"
```

---

### Task 6: Update the test script

**Files:**
- Modify: `test/bootc-install-test.sh`

**Step 1: Add local podman image detection**

Replace the current image loading logic (lines 87-122) with this resolution order:

```bash
if podman image exists "$INPUT" 2>/dev/null; then
    # Local podman image (e.g., "snow" or "localhost/snow:latest")
    IMAGE_REF="$INPUT"
    echo "Using local image: $IMAGE_REF"
elif is_registry_ref "$INPUT"; then
    IMAGE_REF="$INPUT"
    echo "Pulling registry image: $IMAGE_REF"
    podman pull "$IMAGE_REF"
elif [[ -f "$INPUT" ]]; then
    # OCI archive file
    local_ref="localhost/snosi-test:latest"
    echo "Loading OCI archive: $INPUT"
    skopeo copy "oci-archive:$INPUT" "containers-storage:$local_ref"
    IMAGE_REF="$local_ref"
    IMAGE_LOADED="$IMAGE_REF"
    echo "Image loaded as: $IMAGE_REF"
else
    echo "Error: $INPUT is not a local image, registry ref, or archive file" >&2
    exit 1
fi
```

This removes:
- The OCI directory path (`skopeo copy oci:<dir>`)
- The entire re-layering workaround (`podman export | podman import`, lines 109-119)
- The `local_ref` intermediate image for directory loads

**Step 2: Commit**

```bash
git add test/bootc-install-test.sh && git commit -m "feat: update test to accept local podman images, remove OCI re-layering workaround"
```

---

### Task 7: Update CI workflow

**Files:**
- Modify: `.github/workflows/build-images.yml`

**Step 1: Simplify the mkosi build step**

Remove `--oci-labels` and `--oci-annotations` flags. Keep `--image-version`:

```yaml
- name: Build rootfs
  run: |
    sudo mkosi --profile ${{ matrix.profile }} \
      --image-version "${{ steps.version.outputs.tag }}" \
      build
```

**Step 2: Add buildah-build step**

After the mkosi build step, add:

```yaml
- name: Build OCI image
  uses: redhat-actions/buildah-build@v2
  with:
    containerfiles: ./Containerfile
    context: ./output/${{ matrix.profile }}
    image: ${{ matrix.profile }}
    tags: ${{ steps.version.outputs.tag }} latest
    labels: |
      containers.bootc=1
    oci-annotations: |
      containers.bootc=1
      org.opencontainers.image.vendor=frostyard
      org.opencontainers.image.title=${{ matrix.profile }}
      org.opencontainers.image.version=${{ steps.version.outputs.tag }}
      org.opencontainers.image.created=${{ steps.date.outputs.date }}
      org.opencontainers.image.source=https://github.com/${{ github.repository_owner }}/${{ env.REPO_NAME }}/blob/${{ github.sha }}/mkosi.conf
      org.opencontainers.image.url=https://github.com/${{ github.repository_owner }}/${{ env.REPO_NAME }}/tree/${{ github.sha }}
      org.opencontainers.image.documentation=https://raw.githubusercontent.com/${{ github.repository_owner }}/${{ env.REPO_NAME }}/${{ github.sha }}/README.md
```

**Step 3: Replace skopeo push with push-to-registry action**

Remove the "Login to GitHub Container Registry" and "Push image to registry" steps. Replace with:

```yaml
- name: Push image to registry
  if: github.event_name != 'pull_request'
  uses: redhat-actions/push-to-registry@v2
  with:
    image: ${{ matrix.profile }}
    tags: ${{ steps.version.outputs.tag }} latest
    registry: ghcr.io/${{ github.repository_owner }}
    username: ${{ github.actor }}
    password: ${{ secrets.GHCR_PAT }}
```

**Step 4: Commit**

```bash
git add .github/workflows/build-images.yml && git commit -m "feat: replace skopeo OCI push with buildah-build and push-to-registry"
```

---

### Task 8: Verify locally

**Step 1: Run a profile build to verify mkosi directory output**

```bash
just snow
```

Expected: mkosi produces `output/snow/` as a directory tree (not OCI layout), then `podman build` creates the image.

**Step 2: Verify the image exists in podman storage**

```bash
podman images | grep snow
```

Expected: `localhost/snow` image listed.

**Step 3: Verify labels and annotations**

```bash
podman inspect snow --format '{{.Config.Labels}}'
```

Expected: `containers.bootc=1` label present.

**Step 4: Run the test**

```bash
just test-install snow
```

Expected: test loads the local podman image directly (no re-layering), bootc install succeeds, VM boots, tests pass.

**Step 5: Commit any fixes discovered during verification**
