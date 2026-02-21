# Containerfile Build Design

Replace mkosi's OCI output with a Containerfile build that copies in directory output. mkosi's OCI tar implementation has broken PAX extension headers that cause composefs-rs (used by bootc) to fail.

## Approach

mkosi outputs `Format=directory` (plain rootfs tree). A trivial `Containerfile` (`FROM scratch` / `COPY . /`) packages it into a proper OCI image via podman (local) or buildah (CI). Labels and annotations are passed entirely via build-time flags.

## Changes

### mkosi Configuration

- Rename `shared/outformat/oci/` to `shared/outformat/image/`.
- `shared/outformat/image/mkosi.conf`: set `Format=directory`, remove `OciLabels` and `OciAnnotations`.
- `shared/outformat/image/finalize/mkosi.finalize.chroot`: unchanged (bootc cleanup still applies to directory output).
- All 6 profile configs (`snow`, `snowloaded`, `snowfield`, `snowfieldloaded`, `cayo`, `cayoloaded`):
  - Update `Include=` path from `shared/outformat/oci/mkosi.conf` to `shared/outformat/image/mkosi.conf`.
  - Update `FinalizeScripts=` path from `shared/outformat/oci/finalize/` to `shared/outformat/image/finalize/`.
  - Remove `OciLabels=` and `OciAnnotations=` lines from `[Output]` section.

### Containerfile (new, repo root)

```dockerfile
FROM scratch
COPY . /
```

Invoked with context pointing at the mkosi directory output:

```bash
podman build \
  --label containers.bootc=1 \
  --annotation containers.bootc=1 \
  --annotation org.opencontainers.image.vendor=frostyard \
  --annotation org.opencontainers.image.title=snow \
  --annotation "org.opencontainers.image.description=Snow Linux OS Image" \
  -f Containerfile \
  -t snow \
  output/snow/
```

### Justfile

Split each target so mkosi runs via sudo and podman build runs as the regular user. Add a private `_containerfile-build` helper to reduce duplication:

```just
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

Public targets chain mkosi (sudo) then containerfile-build (user):

```just
snow:
    sudo PATH="$PATH" {{just}} _snow
    {{just}} _containerfile-build snow "Snow Linux OS Image"
```

If podman can't read root-owned output files, a chown step may be needed between the two commands.

### CI Workflow (build-images.yml)

Replace mkosi OCI flags + skopeo with buildah/push actions:

1. **mkosi build** -- same command but without `--oci-labels`/`--oci-annotations` flags.
2. **buildah-build** -- `redhat-actions/buildah-build@v2` with Containerfile, context at `output/<profile>`, labels/annotations as parameters.
3. **push-to-registry** -- `redhat-actions/push-to-registry@v2` replaces manual skopeo login + copy.

### Test Script (test/bootc-install-test.sh)

- Remove the `podman export | podman import` re-layering workaround (lines 109-119). No longer needed since podman/buildah produce correct tar layers.
- Remove OCI directory handling path (`skopeo copy oci:<dir>`).
- Add local podman image detection: if `podman image exists "$INPUT"` succeeds, use it directly as `IMAGE_REF`.
- Keep registry ref path (podman pull) and OCI archive path (skopeo copy oci-archive:).

Resolution order: local podman image > registry ref > OCI archive file.

## What Gets Deleted

- `OciLabels` and `OciAnnotations` from all mkosi configs.
- The `podman export | podman import` workaround in the test script.
- `skopeo` login and manual copy steps in CI.
- OCI directory handling in the test script.
