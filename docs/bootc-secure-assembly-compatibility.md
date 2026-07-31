# Bootc Secure Assembly Compatibility Contract

`shared/bootc-secure/assemble-uki.sh` is a maintained compatibility adapter
for the Frostyard `bootc` package at upstream version `1.16.3`. It is not an
upstream-stable bootc interface.

## Pinned behavior

The adapter relies on all of the following observed behavior:

1. A pristine OCI image can be chunked with the pinned chunkah operation before
   it runs the hidden command
   `bootc container compute-composefs-digest-from-storage IMAGE` and return one
   128-hex-character composefs ID.
2. Adding files only below `/boot` to an image derived from that chunked
   candidate does not change that OCI-derived ID.
3. Direct `ukify build` can produce a MOK-signed UKI with `rw` and exactly one
   `composefs=?<ID>` argument, one kernel/initramfs pair, an RSA-2048 PCR public
   key, and four PCR policies per signer.
4. `bootc install to-filesystem` consumes the resulting image as a Type #2 UKI
   deployment without raw `linux` or `initrd` BLS fallback.
5. Forky `systemd-ukify 261.1-3` ships executable `/usr/bin/ukify` (package
   SHA-256 `817b8ea0a8953f9fb4b42d91f04ed1511bbb1e76cee466497dfb955cb246aa34`).
6. Direct ukify runs inside the chunked first-pass candidate; that candidate's
   bootc remains storage-digest authority.
7. Final host byte comparisons depend on first-pass `cp -a` identity.
8. Candidate ukify runs with network disabled and all Linux capabilities dropped.
   It runs as the common numeric owner of its mode-0600 credentials; mismatches
   fail before Podman.
   Its authoritative active and optional previous PCR public identities remain
   outside the writable work mount; exposed copies must match after execution.
9. Protected run `30579247524` showed that this unprivileged candidate cannot
   read a mode-restricted in-image initramfs. The adapter canonicalizes each
   discovered in-root kernel/initrd source, stages only byte-identical mode-0644
   public copies at `/run/snosi-ukify-work/linux` and
   `/run/snosi-ukify-work/initrd`, and passes those fixed paths to ukify. It
   compares both exposed copies against their canonical protected rootfs sources
   after execution and compares final UKI sections against those originals.
   Symlink escapes are rejected; valid relative and rootfs-absolute internal
   symlinks resolve to their canonical source. The work mount holds no
   protected-mode duplicate or private credential; rootfs originals remain the
   sole authoritative protected inputs.

The cited protected run failed before validation, push, signing, or promotion;
this fixture-covered behavior is not live secure-publication evidence.

`buildah-package.sh` makes a first, unsigned-label OCI image, chunks it with
the pinned chunkah operation, and obtains the authoritative storage digest
through that chunked candidate's own bootc binary. It invokes the assembler,
then derives the final image from the chunked candidate and overlays only the
assembled `/boot` tree. The final candidate's own bootc performs the second and
only other digest probe, which must return the authoritative digest exactly.
There is no protected post-assembly chunk pass. The final image is labelled
`io.snosi.bootc.secureboot-capable=true` only after that comparison and the
credential scan pass. Non-secure builds explicitly carry `false`; key presence
is never a capability signal.

## Credentials and rotation

The public positional interface is:

```text
assemble-uki.sh ROOTFS MOK_KEY MOK_CERT PCR_KEY PCR_CERT [PREVIOUS_PCR_CERT]
```

The optional dual-PCR mode additionally requires
`SNOSI_BOOTC_PREVIOUS_PCR_KEY`; the private key must match
`PREVIOUS_PCR_CERT`. The primary key remains the `.pcrpkey` value and both
signers produce four policy signatures. Private keys are read only from the
caller paths, never copied to the rootfs, OCI layer, labels, or diagnostic
output. Temporary files are private and removed on exit.

## Mandatory revalidation

Before changing the Frostyard bootc/libostree package, bootc upstream version,
the selected systemd/ukify family, chunkah, Buildah derivation, or the `/boot`
exclusion, run the full Task 1-3 rootfs proof and Task 5 artifact/negative
tests against a newly built rootfs. Treat any change to the hidden command,
digest equality, UKI sections, PCR signature shape, Type #2 BLS layout, or
signed systemd-boot output as a hard stop. Update this compatibility contract
only with replacement evidence; do not silently normalize the changed shape.
