# Bootc Chunk-Before-Seal Design

## Problem

The protected bootc build currently assembles and validates a UKI before CI
runs `chunkah-package.sh`. The UKI binds its `composefs=` command-line argument
to the storage digest of the pre-chunk OCI image. Chunkah then rewrites the OCI
layer layout, changing the candidate's bootc storage digest. Local validation
passes before chunking, but validation of the policy-copied registry artifact
correctly rejects the published image because its UKI still names the old
digest.

Secure publication must retain the current chunkah optimization while ensuring
that the final published image has the same storage digest sealed into its UKI.

## Selected Flow

Secure packaging owns chunking and performs these operations in order:

1. Place the MOK-signed systemd-boot reconciliation source under
   `/usr/lib/snosi/bootc/` before any candidate packaging.
2. Package the pristine rootfs as a temporary non-capable OCI candidate with
   the final caller-supplied image metadata.
3. Run the existing pinned chunkah operation against that temporary candidate,
   preserving `--prune /sysroot/`, the configured maximum layer count, and the
   caller-supplied source epoch.
4. Run the chunked candidate's pinned bootc 1.16.3 to obtain the authoritative
   storage digest.
5. Run the candidate's ukify to build a UKI whose command line is exactly
   `rw composefs=?<digest>`, then add the UKI and signed ESP second stage to the
   source rootfs below `/boot`.
6. Create the final image by deriving it from the chunked candidate, copying
   only the assembled `/boot` tree into a final overlay layer, and replacing
   the non-capable label with the secure capability and assembly labels.
7. Run the final image's bootc storage-digest command and require byte-for-byte
   equality with the digest from step 4.
8. Scan the final OCI image for protected credential bytes before allowing the
   packager to succeed.

The workflow no longer invokes chunkah after secure packaging. Non-secure and
secretless mechanics packaging retain their existing flow unless they already
delegate chunking separately.

## Security Boundary

The chunked candidate, not the unchunked rootfs package, is storage-digest
authority. The final image inherits that candidate's optimized layers. Its only
filesystem delta is the `/boot` overlay permitted by the maintained bootc
compatibility contract; image configuration changes are limited to trusted
secure labels.

Private credentials remain caller-owned files. Chunkah receives no credential
mounts or credential environment values. Candidate ukify retains its existing
network, capability, ownership, read-only mount, redaction, byte-comparison,
and scan restrictions.

The packager must fail closed if:

- the source epoch needed by chunkah is absent or invalid;
- chunkah fails or does not produce the expected candidate reference;
- either storage-digest probe is malformed;
- final assembly changes any path outside `/boot`;
- the final digest differs from the chunked candidate digest;
- a private credential is found in the rootfs, image, logs, or retained state;
- cleanup cannot remove an incomplete final image or injected `/boot` output.

No image carrying `io.snosi.bootc.secureboot-capable=true` is retained or made
available for publication unless the final digest comparison and credential
scan pass.

## Interfaces

`buildah-package.sh` remains the protected build entry point. Secure mode
requires `SOURCE_DATE_EPOCH` for its internal chunkah call and continues to
honor `MAX_LAYERS`, defaulting to 128 as the standalone chunker does. The
workflow derives `SOURCE_DATE_EPOCH` from the checked-out commit and passes it
explicitly through the `sudo` boundary.

The chunking implementation should expose a reusable operation rather than
duplicating the pinned image reference and chunkah arguments. The standalone
`chunkah-package.sh` interface remains available for non-secure callers.

## Tests

Fixture tests must prove:

- chunking occurs after pristine packaging and before the authoritative digest;
- the existing pinned chunkah image and arguments are retained;
- the authoritative digest is read from the chunked candidate;
- the final image derives from that chunked candidate rather than from scratch;
- only `/boot` content is copied into the final filesystem layer;
- secure labels are applied only to the final candidate;
- equal pre-overlay and final digests succeed;
- a changed final digest fails and removes the incomplete final image;
- chunk failure, malformed digest output, and missing source epoch fail before
  publication;
- the protected workflow has no second post-assembly chunk step and explicitly
  forwards the source epoch through sudo;
- existing credential, UKI-section, local artifact, policy-copy, and
  publication guards remain green.

The real protected build remains the final evidence: local validation and the
policy-copied registry validation must both accept the same chunked-and-sealed
artifact before `latest` can move.

## Documentation

Update `CLAUDE.md`, `docs/bootc-secure-assembly-compatibility.md`,
`yeti/build-pipeline.md`, and relevant CI documentation to state that secure
chunking precedes digest sealing and that the final `/boot` overlay is the sole
post-digest filesystem mutation.
