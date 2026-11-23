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
   ([ADR-0027](adr/0027-seal-lockdown-into-the-secure-uki-command-line.md)),
   with `splash quiet` appended when the rootfs ships `plymouthd`
   ([ADR-0033](adr/0033-seal-the-plymouth-splash-into-the-secure-uki-command-line.md)).
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
   `262.2-1` since 2026-11-19: its `ukify.py` changes (stricter
   `--pcr-banks` and `--phases` list parsing, zstd zboot decompression, the
   EFI firmware header magic, key-output conflict checks) do not change the
   arguments of `assemble-uki.sh`; its `--phases` value has no empty entry.
   The first secure assembly on `262.2-1` is the next `build-images.yml` run
   on main (see "Forky systemd family rechecks" below).
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

Each suite pins its own exact Frostyard build pair for every OCI bootc
profile. `shared/packages/bootc/mkosi.conf` includes the two suite fragments,
and the fragment of the build's suite applies (ADR-0037). The shared fragment
holds no bootc, libostree-1-1 or libgpgme entry.

Both suites pin bootc 1.17.4 / libostree 2026.7 from the
[frostyard/bootc-debian release `bootc-1.17.4-ostree-2026.7-202611180102`](https://github.com/frostyard/bootc-debian/releases/tag/bootc-1.17.4-ostree-2026.7-202611180102)
(source `ea7c3c22d445b80dd692e001fd8e5d84854a9d0d`), each its own
`~deb13`/`~deb14` build, read from the `image` component of each suite's
index at repository.frostyard.org on 2026-11-22.
`shared/packages/bootc/trixie.conf` selects:

- `bootc=1.17.4-frostyard202611180102~deb13`
- `libostree-1-1=2026.7-frostyard202611180102~deb13`
- `libgpgme11t64`

Its contract is `shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json`.

Forky pins its own pair. `shared/packages/bootc/forky.conf` selects:

- `bootc=1.17.4-frostyard202611180102~deb14`
- `libostree-1-1=2026.7-frostyard202611180102~deb14`
- `libgpgme45` (the forky name of `libgpgme11t64`; the forky libostree
  depends on it)

Forky has its own contract copy,
`shared/bootc-secure/suite/forky/tree/usr/lib/snosi/bootc-secure.json`.
`shared/bootc-secure/forky.conf` adds that tree after
`shared/bootc-secure/tree`, so the forky file replaces the trixie file in a
forky image. The copy now equals the trixie contract in all fields. The
copy and its 3 movable fields stay so the suites can diverge again:
`assembly.bootc_version` (`1.17.4`), `assembly.compatibility`
(`bootc-1.17.4-storage-digest-v1`) and `installer.minimum_versions.bootc`
(`1.17.4`). Host-side secure assembly reads the contract of the suite that
`SNOSI_BOOTC_SECURE_SUITE` selects (unset is trixie;
[ADR-0038](adr/0038-publish-signed-forky-test-images.md)):
`assemble-uki.sh`, `buildah-package.sh` and `ci/verify-published-image.sh`
load it through `shared/bootc-secure/compatibility.sh`, and the packager fails
when the rootfs `VERSION_CODENAME` is of another suite.

bootc 1.17.4 does not write `timeout 5` to the ESP `loader/loader.conf` at
install (upstream commit `cbd34248659c3c95de03032de3d2c5f6a1f92e1b`,
"sd-boot: Pick loader.conf from the image"). It copies
`/usr/lib/bootc/install/systemd-boot/loader.conf` from the image after
`bootctl install`. Without that file, the systemd-boot menu is hidden. The
shared tree ships
`shared/bootc-secure/tree/usr/lib/bootc/install/systemd-boot/loader.conf`
with the single line `timeout 5`, reaching both suites for the same
5-second menu.

ostree 2026.6 fixes
[ostree#3681](https://github.com/ostreedev/ostree/issues/3681): with libostree
2026.5, a system Flatpak update that applies a static delta fails.
libostree 2026.7 fixes
[GHSA-phq3-47fg-9gvv](https://github.com/ostreedev/ostree/security/advisories/GHSA-phq3-47fg-9gvv)
(a pull with `sign-verify-summary=true` skipped the summary signature check
when the remote served no summary) and
[GHSA-67f3-qw4m-mv3w](https://github.com/ostreedev/ostree/security/advisories/GHSA-67f3-qw4m-mv3w)
(an unsigned static delta index could make a mirror abort the pulling
process), and [ostree#3690](https://github.com/ostreedev/ostree/pull/3690)
(finalize through the boot fd), which changes the ostree backend's
finalize; snosi installs with `--composefs-backend`.

The pin scope is those fragments only. They add no global APT preference and
change no sysext or base package selection; every other entry in the shared
fragment stays a floating Debian or Forky selector.
`test/bootc-secure-static-test.sh` enforces the exact selectors of each suite.
It requires the upstream part of each bootc package version to agree with
`assembly.bootc_version` of that suite's contract (the full Debian version
does not equal that field). It requires each contract to be consistent, as
`shared/bootc-secure/compatibility.sh` requires, and the forky contract to
equal the trixie contract except the 3 bootc fields. It requires each suite
fragment to match only its own `Release=`, and all four product profiles
(`floe`, `snow`, `snowfield`, `sundog`) to include the shared fragment. It
rejects a removed, floating or disagreeing entry. The guard proves selector
values and version agreement only; it cannot show that revalidation occurred.

The fragment also runs `shared/packages/bootc/finalize/bootc-pair.chroot` in
every OCI bootc build, so the PR mechanics builds and the main secure builds
check the pair that the image ships: `bootc --version` names
`assembly.bootc_version`, the hidden storage-digest command exists, and
`libostree-1-1` is at least 2026.6 (the ostree#3681 floor). The static test
runs it against stubs, and rejects a pinned libostree below that floor. The
guard shows that the fixed library is in the image. It does not run a
static-delta Flatpak update; that needs a booted image and a remote that
serves static deltas, which is lab work.

### Pair evidence: 1.17.4 / 2026.7 (2026-11-22)

- Packages: the 4 debs were downloaded from repository.frostyard.org and
  matched the SHA256 of the `image` index of trixie and forky, whose
  InRelease files verify with the Frostyard key.
- Rootfs probe: the published trixie Floe `20261122174320` and forky Floe
  `forky-20261117162644` rootfs were each moved to exactly the new pair with
  `dpkg -i` and run in a rootfs-only bwrap sandbox. Before the move, each
  ran its old pair (trixie 1.17.3/2026.6, forky 1.17.4/2026.6). After it,
  `bootc --version` printed `bootc 1.17.4` in both, `bootc container --help`
  and `bootc container compute-composefs-digest-from-storage --help` exited
  0, and `ldd` resolved `libostree-1.so.1` from the new package. Both help
  texts are byte-identical to the old pair of each suite and between the
  suites (trixie 1.17.3 to 1.17.4 included).
- `bootc-pair.chroot` passed in both rootfs against the new contract
  (`bootc 1.17.4, libostree-1-1 2026.7-frostyard202611180102~deb13` and
  `~deb14`, storage-digest command present), and failed on trixie against
  the old 1.17.3 contract (`expected bootc 1.17.3, observed bootc 1.17.4`).
- Digest stability: on one fixed tree (784 MiB, 3607 entries: `etc`,
  `usr/bin`, `usr/lib/systemd`, `usr/lib/os-release`, empty `boot` and
  `sysroot`, all mtimes 0), all four combinations (trixie 1.17.3/2026.6,
  forky 1.17.4/2026.6, trixie 1.17.4/2026.7, forky 1.17.4/2026.7) print
  the same `compute-composefs-digest` value for `--erofs-version v1` and
  for `v2`, in 2 runs each. Agreement for that tree only, not a source-level
  proof.
- Upstream: bootc v1.17.3..v1.17.4 was read for the forky pair (below);
  for trixie it adds the `loader.conf` change (handled with the shared
  `loader.conf`), `install: Reject a config stateroot on composefs-only
  images` (snosi ships no install config with a stateroot) and
  `generator: skip fstab editor for read-only root`. libostree
  v2026.6..v2026.7: the 2 advisories, `bootconfig: reject newlines when
  writing loader entries`, `lib/refs: Validate collection IDs read from
  summaries and repos` and ostree#3690; the package depends on the same
  libraries as 2026.6.
- Secure assembly on bootc 1.17.4 (with libostree 2026.6) already passed on
  forky for all four products: forky-publish runs
  [44125211959](https://github.com/frostyard/snosi/actions/runs/44125211959)
  (floe `forky-20261117162644`),
  [44125233050](https://github.com/frostyard/snosi/actions/runs/44125233050)
  (snow `forky-20261117162606`),
  [44125259062](https://github.com/frostyard/snosi/actions/runs/44125259062)
  (snowfield `forky-20261117162734`) and
  [44125281364](https://github.com/frostyard/snosi/actions/runs/44125281364)
  (sundog `forky-20261117162653`), 2026-11-17, each with
  `bootc-pair: bootc 1.17.4, libostree-1-1 2026.6-frostyard202611132023~deb14`
  and both `Image packaged` lines.
- Not yet shown: the forky pair in secure assembly, which the next
  `forky-publish.yml` dispatch of each product shows (until then the forky
  secure evidence is the 1.17.4/2026.6 runs above). A lab install showing
  the 5-second menu on trixie, and a booted static-delta Flatpak update,
  are not done.

**Secure revalidation (trixie, 2026-11-23):** as for 1.17.3 (below), no
pre-merge build could run the full Task 1-3 rootfs proof and the Task 5
artifact and negative tests that Mandatory revalidation (below) requires,
because secure-build runs only on `main` (the `native-build` environment
allows only `main`). The first main `build-images.yml` run after the pin
([#1368](https://github.com/frostyard/snosi/pull/1368)) is that
revalidation; `Validate locally assembled secure artifact` runs before
`Push immutable version tag`, so a failure would have published nothing. It
passed:
[run 45111303366](https://github.com/frostyard/snosi/actions/runs/45111303366)
at `95298263227a6a057f93a403a42948a589207188` (2026-11-23). In each of the
four secure-build legs, `bootc-pair.chroot` reported `bootc 1.17.4,
libostree-1-1 2026.7-frostyard202611180102~deb13, storage-digest command
present`, the second storage-digest probe matched the first (the build
prints `Image packaged` for the version tag only after that comparison), the
locally assembled and the published secure artifact validations passed, and
the initramfs gpt-auto structural validation passed. Published, signed and
attested, with
`io.snosi.bootc.secureboot-assembly=bootc-1.17.4-storage-digest-v1`, and
promoted to `latest`:

| Product | Version | Digest |
| --- | --- | --- |
| floe | `20261123042359` | `sha256:5996f1b8743578e0c2d65c266cd69d28fca7f31a960415b6f8cf4135a3a4107e` |
| snow | `20261123042417` | `sha256:59bf3480f795b3f09f3fd851760b3976212c3742330380cec66cfaa04133c0a2` |
| snowfield | `20261123042348` | `sha256:8cbe202d504e317ee403fe8d91c1eba7cf7f7b9110d76d5b42f53ebf193740f2` |
| sundog | `20261123042324` | `sha256:59b7bd814266bc065437ffa7efc670b36aaf43482d0352dfcfd23aea966558df` |

Evidence for the earlier trixie pair 1.17.3 / 2026.6 (2026-11-04, history):

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

### Forky pair evidence (1.17.4 / 2026.6, history)

The forky pair is the frostyard/bootc-debian release
`bootc-1.17.4-ostree-2026.6-202611132023` (Build run 43501170071, source
`6f0df0d8c3f20fc1e94fb27082bdf32a85c19718`), read from the `image` component
of the forky index at repository.frostyard.org on 2026-11-13. Evidence
(2026-11-13):

- Rootfs probe: a clean `debian:forky` container installed exactly this pair
  from the Frostyard repository, with `libgpgme45` 2.2.0-2. `bootc --version`
  printed `bootc 1.17.4`, `bootc container --help` and
  `bootc container compute-composefs-digest-from-storage --help` ran, and
  `bootc-pair.chroot` passed against the forky contract copy. Both help texts
  are byte-identical to 1.17.3 from the trixie pair, probed the same way in a
  clean `debian:trixie` container.
- Digest stability: on one fixed tree (all mtimes 0, with `boot` and `sysroot`
  directories), 1.17.3 on trixie and 1.17.4 on forky print the same
  `compute-composefs-digest` value for `--erofs-version v1` and for `v2`, in
  2 runs each. This shows agreement for that tree only; it is not a
  source-level proof that the algorithm is unchanged.
- Upstream v1.17.3..v1.17.4 (27 commits, read by subject, and by diff where a
  subject touches an install path that snosi uses): `sd-boot: Pick loader.conf
  from the image` changes the installed menu timeout (handled above with the
  shared `loader.conf`). `prepare-install: Check for composefs cmdline in UKI
  Addons` rejects a composefs command line in a global addon at install prep;
  `snosi-kargs` refuses every `composefs=` argument (`dangerous_reason`), and
  Firn installs no addon.
  `gc: Only GC UKI Artifacts if boot type is UKI` narrows GC to UKI boots,
  which is the snosi boot type. `container aboot/ukify: allow specifying
  --erofs-version=v1-only` changes commands that snosi does not use. No
  subject names the hidden storage-digest command.
- The forky mechanics build of Floe runs `bootc-pair.chroot` against this
  pair.

Forky secure assembly path: `.github/workflows/forky-publish.yml` (manual
dispatch from main) builds the 1 forky product that the dispatch selects
(Floe, Snow, Snowfield or Sundog) with `SNOSI_BOOTC_SECURE_SUITE=forky`,
assembles and validates the secure artifact against the forky contract, and
publishes only an immutable `forky-<version>` test tag (ADR-0038, ADR-0039).

The forky-publish runs listed above (2026-11-17) were the secure-assembly
and publication evidence for 1.17.4/2026.6. A lab install, update and rollback
on forky is not recorded here.

Previous pins (history):

- Trixie `bootc=1.17.3-frostyard202611042030~deb13` with
  `libostree-1-1=2026.6-frostyard202611042030~deb13`, from the
  frostyard/bootc-debian release `bootc-1.17.3-ostree-2026.6-202611042030`
  (Build run 41907166706; evidence above, main run 41939252558).
- Forky `bootc=1.17.4-frostyard202611132023~deb14` with
  `libostree-1-1=2026.6-frostyard202611132023~deb14`
  (frostyard/bootc-debian run 43501170071).
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

## Forky systemd family rechecks

`shared/download/forky-versions.json` records the Forky `systemd` source
version whose four rechecks last passed (`shared/download/check-forky-systemd.sh`
lists them). The family itself is not pinned: every build installs the
current `<pkg>/forky`.

**262-1 to 262.2-1 (2026-11-19, frostyard/snosi#1349):**

1. Bootc build/root check. The 4 `mechanics-build` jobs of #1349 (run
   44575109852) installed the whole family at 262.2-1, and
   `bootc-pair.chroot` passed in each (bootc 1.17.3, libostree-1-1
   2026.6, storage-digest command present). The published Floe
   `20261118181423` rootfs, moved to exactly 262.2-1 for all 21 installed
   packages of the `systemd` source and with nothing else changed, ran
   `bootc --version` (`bootc 1.17.3`), `bootc container --help` and
   `bootc container compute-composefs-digest-from-storage --help` in a
   rootfs-only bwrap sandbox, each with exit 0.
2. Issue 517. `rules.d/90-image-dissect.rules` is identical in upstream v262
   and v262.2 and in the 2 rootfs above (it carries the
   `gpt-auto-root-luks` symlink rules at lines 23-24). The dracut 106 log of
   the #1349 Floe build lists it in the initramfs.
3. NvPCR masks. The 4 definitions (`cryptsetup`, `hardware`, `login`,
   `verity`), the units `systemd-pcrproduct.service` and
   `systemd-pcrlogin@.service`, and their Debian install lines are unchanged;
   the image file lists of `usr/lib/nvpcr`, `usr/lib/systemd/system` and
   `usr/lib/systemd` are unchanged; the #1349 builds report both units
   masked. v262.2 makes an unauthorized NvPCR initialization a graceful skip
   (`systemd-tpm2-setup` exits `EX_CONFIG`, `systemd-pcrextend --graceful`
   skips `ENETDOWN`). That reduces the harm of an unmasked writer but does
   not make NvPCRs usable: snosi UKIs still carry no initrd NvPCR policy. The
   masks stay.
4. snosi-health cryptsetup texts. All texts that `snosi-health` S5 matches
   are unchanged in `src/cryptsetup/cryptsetup.c`,
   `src/shared/cryptsetup-tpm2.c` and `src/shared/tpm2-util.c` of v262.2.
   v262.2 separates `-EUCLEAN` from a policy mismatch: it now logs "PCR
   values kept changing while unsealing the TPM2 secret, giving up..."
   followed by "TPM2 operation failed, falling back to traditional
   unlocking: Structure needs cleaning" (v262 logged "TPM policy does not
   match current system state"). The existing "Structure needs cleaning"
   match classifies that as `PCR_CHANGED`; `test/snosi-health-test.sh` has a
   case with the v262.2 lines.

Not yet shown on 262.2-1: the Task 1-3 rootfs proof and the Task 5 artifact
tests, which need the protected secure build. The first `build-images.yml`
run on main after 2026-11-19 runs them; `Validate locally assembled secure
artifact` runs before `Push immutable version tag`, so a failure publishes
nothing.

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
is the unit of evidence, not of change. Each suite has its own pair, contract
and fragment:

| Suite | Contract | Fragment |
| --- | --- | --- |
| trixie | `shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json` | `shared/packages/bootc/trixie.conf` |
| forky | `shared/bootc-secure/suite/forky/tree/usr/lib/snosi/bootc-secure.json` | `shared/packages/bootc/forky.conf` |

When the bootc of a suite changes, these fields move with it in one change:
`assembly.bootc_version`, `assembly.compatibility` and
`installer.minimum_versions.bootc` in the contract of that suite, and the bootc
selector in the fragment of that suite. The same change must update the
expected pins of that suite in `test/bootc-secure-static-test.sh`; a mismatch
between that file and the fragment fails the guard. Until revalidation passes,
the pin stays.
