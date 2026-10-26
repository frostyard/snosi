# Bootc Secure Assembly Compatibility Contract

`shared/bootc-secure/assemble-uki.sh` is a maintained compatibility adapter
for the Frostyard `bootc` package version recorded in
`shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json` at
`assembly.bootc_version`. That field is the canonical active version; the
derived `assembly.compatibility` value identifies the matching assembly
contract. This adapter is not an upstream-stable bootc interface.

The chunk-before-seal ordering this contract pins is decided in
[ADR-0012](adr/0012-chunked-layers-cadence-xattrs-chunk-before-seal.md).

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
5. Forky `systemd-ukify` ships executable `/usr/bin/ukify`. The package is
   not version-pinned: the secure fragment selects `systemd-ukify/forky`, so the
   candidate gets whatever Forky carries at build time, and nothing checks its
   version or hash. Observed versions: `261.1-3` when this contract was written
   (package SHA-256
   `817b8ea0a8953f9fb4b42d91f04ed1511bbb1e76cee466497dfb955cb246aa34`, recorded
   history only) and `262-1` since 2026-09-28. On 2026-09-29, 262-1's
   `ukify build` passed local secure assembly plus
   `test/bootc-secure-artifact-test.sh` on floe. Protected main run
   36479923888 had already done the same for floe on 2026-09-28. systemd 262
   changes only `ukify inspect --json` output, which this path does not use.
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
through that chunked candidate's own bootc binary. Every digest probe runs
through the single shared helper `shared/bootc-secure/storage-digest-probe.sh`
(`snosi_storage_composefs_digest`, sourced by `buildah-package.sh`,
`assemble-uki.sh`, and `test/bootc-secure-spike-test.sh` — never re-inline the
`podman run` shape). The helper binds a host-filesystem scratch directory over
the container's `/var/tmp`: bootc hardcodes its temporary composefs repository
at `/var/tmp` inside the container (`TMPDIR` is ignored), observed on 1.16.8
and not re-checked on 1.17.1, so the bind stays; the 1.17.1 probes passed with
it. composefs object writes use `O_TMPFILE`, which fuse-overlayfs does not
support
— GitHub runner image ubuntu24/20260810.271 (podman 5.8.4) forces
`mount_program = fuse-overlayfs`, and without the bind every probe fails with
`os error 95`. The mount changes only the execution environment; the digest is
computed from containers-storage content and is unaffected (proven on runner
image 20260810.271, 2026-08-13). It invokes the assembler,
then derives the final image from the chunked candidate and overlays only the
assembled `/boot` tree. The final candidate's own bootc performs the second and
only other digest probe, which must return the authoritative digest exactly.
There is no protected post-assembly chunk pass. The final image is labelled
`io.snosi.bootc.secureboot-capable=true` only after that comparison and the
credential scan pass. Non-secure builds explicitly carry `false`; key presence
is never a capability signal.

## Build-input package pin

`shared/packages/bootc/mkosi.conf` selects one exact Frostyard build pair for
every OCI bootc profile:

- `bootc=1.17.1-frostyard202610252315~deb13`
- `libostree-1-1=2026.5-frostyard202610252315~deb13`

The pin scope is that fragment only. It adds no global APT preference and
changes no sysext or base package selection; every other entry in the fragment
stays a floating Debian or Forky selector. `test/bootc-secure-static-test.sh`
enforces both exact selectors, requires the upstream part of the bootc package
version to agree with `assembly.bootc_version` in
`shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json` (the full Debian
version does not equal that field), requires all four product profiles
(`floe`, `snow`, `snowfield`, `sundog`) to include the fragment, and rejects a
removed, floating or disagreeing entry. The guard proves selector values and
version agreement only; it cannot show that revalidation occurred.

Evidence for this pair, from source SHA
`7927290da94822f05a0b2ae9cb15c67187db7e4a` (draft PR #1151, never merged):

- [Run 40315411491](https://github.com/frostyard/snosi/actions/runs/40315411491)
  built all four products (floe, snow, snowfield, sundog) as mechanics builds
  with exactly these two versions.
- [Run 40370164077](https://github.com/frostyard/snosi/actions/runs/40370164077)
  built Snow secure. Both storage-digest probes agreed, the locally assembled
  and the policy-copied secure artifact validation passed, and it published
  the signed tag `20261026133822`. `latest` did not move.
- Lab run `run-snow-bootc-lifecycle-l6596` (2026-10-26, frostyard/lab#160): N
  `20261025113924` (bootc 1.16.8) staged and booted N+1 `20261026133822`
  (bootc 1.17.1), `bootc rollback` ran on 1.17.1, and N booted again. Result
  `PASS: verified_five_fresh_boots;fsverity_known_defect=7.2.11+deb14-amd64`.
- Rootfs check (2026-10-26): in the signed tag `20261026133822`, with Forky
  systemd 262-1, `bootc --version`, `bootc container --help` and
  `bootc container compute-composefs-digest-from-storage --help` ran in a
  rootfs-only bwrap sandbox.

The secure assembly on 1.17.1 is proven on Snow only. Floe, Snowfield and
Sundog get their first 1.17.1 secure assembly in the first main build after
this change. That build is the remaining check.

Previous pin (history): `bootc=1.16.8-frostyard202610040153~deb13` with
`libostree-1-1=2026.3-frostyard202610040153~deb13`. Its evidence was
[run 40229646374](https://github.com/frostyard/snosi/actions/runs/40229646374),
which built all four products with exactly those two versions, and
[run 40245723511](https://github.com/frostyard/snosi/actions/runs/40245723511),
which built all four rootfs products and then failed before publication with
`expected bootc 1.16.8, observed bootc 1.17.1`. The floating entries had
resolved to the then-current APT candidates: bootc 1.17.1, and libostree
2026.5. That failure is why the pin exists.

The pin is not a compatibility claim for any other version. A later bootc
needs its own evidence before it can replace the pin.

Follow-up to #1130: upstream bootc commit `9aad3dd87` (first in v1.16.12,
contained in v1.17.1) passes the config verity and skips the full composefs
re-hash of every layer at stage time. That re-read was the stage-time trigger
of the spurious Btrfs fs-verity `FILE CORRUPTED!` reports in
[#1130](https://github.com/frostyard/snosi/issues/1130). In l6596 the stager
was still 1.16.8, so the effect is first observable when a 1.17.1 host stages
a later update. The kernel defect stays.

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

An upgrade of either package needs the revalidation above on the complete
pair. Either package can keep its companion after that revalidation; the pair
is the unit of evidence, not of change. When bootc changes, these contract
fields move with it in one change: `assembly.bootc_version`,
`assembly.compatibility`, `installer.minimum_versions.bootc` and the bootc
selector in `shared/packages/bootc/mkosi.conf`. The same change must update the
expected pins in `test/bootc-secure-static-test.sh`; a mismatch between that
file and the fragment fails the guard. Until revalidation passes, the pin
stays.
