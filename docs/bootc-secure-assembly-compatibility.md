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
3. Direct `ukify build` can produce a MOK-signed UKI with the exact command
   line `rw composefs=?<ID> lockdown=integrity`: `rw`, exactly one
   `composefs=?<ID>` argument and `lockdown=integrity`
   ([ADR-0027](adr/0027-seal-lockdown-into-the-secure-uki-command-line.md)).
   The UKI has one kernel/initramfs pair, an RSA-2048 PCR public key, and four
   PCR policies per signer.
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
   It runs with `--entrypoint=/usr/bin/ukify`, so a future image `CMD` or
   `ENTRYPOINT` cannot intercept the ukify arguments, and with
   `--security-opt label=type:unconfined_t` instead of `:z`/`:Z` bind
   suffixes, which would relabel host credential files. It uses no Podman
   secrets, no credential directory mount and no retained container
   (`--rm`).
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
and not re-checked since, so the bind stays; the 1.17.1 and 1.17.3 probes passed with
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

- `bootc=1.17.3-frostyard202611042030~deb13`
- `libostree-1-1=2026.6-frostyard202611042030~deb13`

They come from the frostyard/bootc-debian release
`bootc-1.17.3-ostree-2026.6-202611042030` (Build run 41907166706), read from the
`image` component of the trixie index at repository.frostyard.org on
2026-11-04. ostree 2026.6 fixes
[ostree#3681](https://github.com/ostreedev/ostree/issues/3681): with libostree
2026.5, a system Flatpak update that applies a static delta fails.

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

The fragment also runs `shared/packages/bootc/finalize/bootc-pair.chroot` in
every OCI bootc build, so the PR mechanics builds and the main secure builds
check the pair that the image ships: `bootc --version` names
`assembly.bootc_version`, the hidden storage-digest command exists, and
`libostree-1-1` is at least 2026.6 (the ostree#3681 floor). The static test
runs it against stubs, and rejects a pinned libostree below that floor. The
guard shows that the fixed library is in the image. It does not run a
static-delta Flatpak update; that needs a booted image and a remote that
serves static deltas, which is lab work.

Evidence for this pair (2026-11-04):

- Rootfs probe: a clean `debian:trixie` container installed exactly this pair
  from the Frostyard repository. `bootc --version` printed `bootc 1.17.3`,
  `bootc container --help` and
  `bootc container compute-composefs-digest-from-storage --help` ran, and
  `bootc-pair.chroot` passed. The hidden command's help text is byte-identical
  to 1.17.1 (same `--erofs-version` option, default `v1`). `bootc container
  --help` adds only the new `aboot` subcommand.
- Digest stability: on one fixed tree (all mtimes 0), 1.17.1 and 1.17.3 print
  the same `compute-composefs-digest` value for `--erofs-version v1` and for
  `v2`, deterministically across runs. This shows agreement for that tree
  only; it is not a source-level proof that the algorithm is unchanged.
- Upstream v1.17.1..v1.17.3 (71 commits, read by subject only): no subject
  names the hidden command or the composefs digest computation. Install and ESP changes
  add aboot and explicit repart directories, select the booted ESP by
  `LoaderDevicePartUUID`, and strip the efivarfs attribute header when bootc
  reads EFI variables; the Type #2 install is re-proven only by the main secure
  build and a lab install. `container: Replace composefs digest kargs
  instead of append` changes only `bootc container ukify`, which snosi does
  not use (direct ukify). `fix: distinguish OCI manifest annotations from
  config labels` keeps the manifest annotation first; snosi sets both
  (#1125). New: bootc now stages global UKI addons with an update (it copies
  `loader/addons` to `loader/addons.staged` and swaps the two at finalize)
  and garbage-collects unreferenced `bootc_composefs-*` global addons. GC
  does not touch `50-snosi-cmdline-local.addon.efi`; `snosi-kargs` mirrors
  `apply` and `revert` into the staged copy so the swap does not undo them
  (see `docs/snosi-kargs.md`).
- PR mechanics builds of all four products with this pair, with
  `bootc-pair.chroot` in each build.

**Secure revalidation (exception accepted by Brian, T846a, 2026-11-04):** no
pre-merge build could run the full Task 1-3 rootfs proof and the Task 5
artifact and negative tests that Mandatory revalidation (below) requires,
because secure-build runs only on `main` (the `native-build` environment
allows only `main`). Brian accepted the first main build as that
revalidation. It passed:
[run 41939252558](https://github.com/frostyard/snosi/actions/runs/41939252558)
at `144bdacb81bbe670833c0a373e207a25d3e5d064` (2026-11-05). In each of the
four secure-build legs, `bootc-pair.chroot` reported `bootc 1.17.3,
libostree-1-1 2026.6-frostyard202611042030~deb13, storage-digest command
present`, the second storage-digest probe matched the first (the build
prints `Image packaged` only after that comparison), the locally assembled and
the published secure artifact validations passed, and the initramfs gpt-auto
structural validation passed. Published, signed and attested, with
`io.snosi.bootc.secureboot-assembly=bootc-1.17.3-storage-digest-v1`, and
promoted to `latest`:

| Product | Version | Digest |
| --- | --- | --- |
| floe | `20261105001249` | `sha256:35cb54004c2b4eac084c127986aa0def77e71b9c6c775c9369da43648d3783cf` |
| snow | `20261105001236` | `sha256:82f06d9f3defffa0c74b072f11139c8596037431d6270aea883b83c23698a3ba` |
| snowfield | `20261105001345` | `sha256:92fb0e4dfa6ac1ee04974b23fbd1bc78c2ae98ee7266fad3e20e4775246cf467` |
| sundog | `20261105001226` | `sha256:a32c0c2751ccabdae09e521cee344edc47bd06177f79ba7ee58e3da40f7bc4e8` |

Not done yet: an N (1.17.1) to N+1 (1.17.3) lab lifecycle run, and a booted
static-delta Flatpak update (ostree#3681).

Previous pins (history):

- `bootc=1.17.1-frostyard202610252315~deb13` with
  `libostree-1-1=2026.5-frostyard202610252315~deb13`, from source SHA
  `7927290da94822f05a0b2ae9cb15c67187db7e4a` (draft PR #1151, never merged).
  [Run 40315411491](https://github.com/frostyard/snosi/actions/runs/40315411491)
  built all four products as mechanics builds;
  [run 40370164077](https://github.com/frostyard/snosi/actions/runs/40370164077)
  built Snow secure (both probes agreed, artifact validation passed, signed tag
  `20261026133822`, `latest` did not move); lab run
  `run-snow-bootc-lifecycle-l6596` (2026-10-26, frostyard/lab#160) staged and
  booted N+1 `20261026133822` (1.17.1) from N `20261025113924` (1.16.8), ran
  `bootc rollback`, and N booted again
  (`PASS: verified_five_fresh_boots;fsverity_known_defect=7.2.11+deb14-amd64`).
  The rootfs check ran `bootc --version`, `bootc container --help` and the
  hidden command's `--help` in a rootfs-only bwrap sandbox of that tag, with
  Forky systemd 262-1.
- `bootc=1.16.8-frostyard202610040153~deb13` with
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
contained in v1.17.1 and later) passes the config verity and skips the full
composefs re-hash of every layer at stage time. That re-read was the
stage-time trigger of the spurious Btrfs fs-verity `FILE CORRUPTED!` reports in
[#1130](https://github.com/frostyard/snosi/issues/1130). In l6596 the stager
was still 1.16.8, so the effect is first observable when a 1.17.1 or later host
stages a later update. The kernel defect stays.

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
