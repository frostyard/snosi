# 0014 — Build every image from Debian Forky; no per-package suite pins

- **Status:** Accepted
- **Date:** 2026-09-04

## Context

Until 2026-09 the whole tree built from `Release=trixie`, with three
suite-crossing mechanisms layered on top:

- the generic kernel, firmware, and mesa userspace came from
  `trixie-backports` through `shared/kernel/backports/mkosi.conf` (every
  package there carried a `/trixie-backports` suffix), while
  `shared/kernel/surface` pinned only firmware and mesa the same way;
- the secure fragments (`shared/bootc-secure`, `shared/native-ab-secure`,
  and the two installer fragments) reached systemd 261 by adding an
  isolated `SandboxTrees=` APT source for `forky` at priority 50 and
  suffixing all twenty systemd-family packages with `/forky`, guarded by
  a "Forky isolation" test that forbade the word anywhere else;
- two sysexts (lemonade, voxtype) depended on packages that existed only in
  trixie-backports and were selected through the sandbox's low backports
  pin.

Every one of those was a cross-suite ABI risk the tree had to manage by
hand (gui-base and the divergent-lib tripwire exist because one of them
bit, issue #781), and the Forky systemd family was already the
production runtime of every secure product. Forky itself now ships
systemd 261.2, linux 7.1.12 (newer than trixie-backports' 7.1.8), mesa
26.1.6, ydotool, libcpp-httplib0.41, incus 7.0, podman 5.8, and plymouth
24.004.60 (same version, so the snow splash workarounds still apply).

Facts that constrain the move, all verified against the archives on
2026-09-04:

- Debian testing's `base-files` writes no `VERSION_ID` into `os-release`
  (only `VERSION_CODENAME=forky`). Three snosi mechanisms key off that
  field: `sysext-postoutput.sh` names artifacts `<name>_<ver>_<VERSION_ID>_<arch>.raw`,
  every sysupdate `.transfer` matches `%w`, and mkosi copies the base's
  `VERSION_ID` into each sysext's `extension-release` for systemd-sysext's
  host match. `common-postinst.sh` would otherwise fall back to
  `VERSION_ID="1.0"` on product images only, desynchronizing all three.
- `forky-backports` exists but is empty.
- Docker publishes no `forky` suite; Tailscale and griffo.io do.
- Forky renamed or dropped several packages the tree listed
  (`libgpgme11t64` → `libgpgme45`, `libicu76` → `libicu78`,
  `libminiupnpc18` → `libminiupnpc21`, `libraw23t64` → `libraw25`,
  `libpeas-1.0-0` → `libpeas-1.0-1`, `libtss2-esys-3.0.2-0` → the `t64`
  name; `low-memory-monitor`, `packagekit-tools`, `libvdpau-va-gl1`,
  `libxatracker2`, `vdpau-driver-all`, `xserver-xorg-video-{qxl,vmware}`,
  and the `libcurl3-gnutls` compatibility name are gone).
- Frostyard's own `libostree-1-1` and `incus-base` debs are built for
  trixie and hard-depend on `libgpgme11t64` (`incus-base` also on
  `libnet1`, now `libnet9`).
- LizardByte publishes Sunshine for trixie and for Ubuntu 22.04/24.04/26.04
  only; the 26.04 build's Depends (`libicu78`, `libminiupnpc21`, glibc
  2.43) are exactly forky's.

## Decision

The tree builds from `Release=forky` in `mkosi.conf`, and every profile and
sysext takes every package from that one release:

- No mkosi config may pin a package to a suite by name.
  `test/native-ab-static-test.sh` greps every `*.conf` under `mkosi.conf`,
  `mkosi.images`, `mkosi.profiles`, and `shared` for a
  `pkg/<suite>[-backports]` token and fails the tree on the first hit;
  `test/bootc-secure-static-test.sh` additionally fails if the secure
  fragment regains a `SandboxTrees=` or a `package-manager/` tree.
- `shared/kernel/backports` is deleted; `shared/kernel/stock` is the single
  generic-kernel fragment and every non-Surface profile includes it.
  `shared/kernel/surface` keeps only the linux-surface packages special.
- The secure fragments and both installer fragments keep their explicit,
  unsuffixed systemd-family lists (the tooling they need is a stated
  dependency) and lose their forky sandbox trees.
- `mkosi.images/base/mkosi.postinst.chroot` appends `VERSION_ID="14"` and
  `VERSION="14 (forky)"` to `/usr/lib/os-release` when the codename is
  forky and no `VERSION_ID` is present, and fails the build for any other
  unmapped codename. Base is the only place this may happen so that
  product images and every sysext delta inherit one value.
- The backports sources and pins stay, renamed to `forky-backports`, so a
  future non-empty suite is available at priority 100 without touching the
  trees again; the pin matches on `n=` (codename) because the suite's
  Release file says `Suite: testing-backports`.
- Docker stays on its `trixie` suite with a comment; Tailscale and griffo
  move to `forky`. Sunshine's verified download moves to the
  `sunshine-ubuntu-26.04-amd64.deb` asset, and `check-dependencies.yml`
  tracks that asset.
- Renamed packages are updated in place; dropped packages are removed from
  the lists (`low-memory-monitor` from base, the six from snow). Virtual
  names with more than one provider are replaced by the real package:
  forky's `liboss4-salsa-asound2` also Provides `libasound2`, so apt
  refuses the bare name ("no installation candidate") and the 1password
  and edge lists say `libasound2t64`. Every other virtual name the tree
  lists (`libgtk-3-0`, `libcurl4`, `qemu-kvm`, …) still has exactly one
  provider and resolves.

## Consequences

- dracut moves from 106 to 112: the `01systemd-pcrphase` module is now
  `11systemd-pcrextend` (every `20-tpm-luks.conf` drop-in names the new
  module), and its binary moved into `systemd-tpm`, which base now installs
  explicitly — the first native build failed in dracut on exactly this.
  dracut 112's `11systemd-udevd` also installs `90-image-dissect.rules`
  natively, so the issue-517 drop-in is redundant but retained.
- The `/var` factory-state outcome maps (ADR-0001) change with the
  release: forky's python is 3.14 (`lib/python/python3.14_installed`), and
  `log/{wtmp,lastlog,btmp}` plus `log/README` no longer land at build time
  (util-linux/base-files stopped creating them; wtmpdb is the only login
  history left). The audit fails closed in both directions, so both maps
  were updated from cayo's real audit output; snow's map mirrors it.
- Verified on 2026-09-04: `mkosi summary` resolves for all eight profiles;
  a real build produced base, gui-base, and the 1password-cli, code-server,
  coder, debdev, dev, and docker sysexts with `VERSION_ID=14` in the base
  os-release, `VERSION_ID=14` in each extension-release, and `_14_`
  artifact names; a second sweep then built the remaining sysexts, so all
  26 non-incus sysexts (every one but `incus`) and `snow-ab` (GNOME 50.4,
  plymouth 24.004.60-5.2, snow's `/var` audit on the updated map) build
  on forky. `cayo-ab-raw` built end to end on forky (linux
  7.1.12-1, systemd 261.2-1, dracut 112-2, mesa 26.1.6-1); its UKI's
  `.osrel` carries `VERSION_ID="14"` and its initrd contains
  `systemd-pcrextend`, `90-image-dissect.rules`, `systemd-cryptsetup`, the
  etc-overlay module, and the serial ask-password units. Booted under
  OVMF in QEMU it reached SSH in 21 s on kernel 7.1.12+deb14 with
  systemd-boot/stub 261.2 and `VERSION_ID="14"` in the running os-release;
  the only failed unit was `run-rpc_pipefs.mount`, because the fixture's
  `KernelModules=` filter dropped `sunrpc.ko` while `nfs-client.target`
  enqueues the mount through `auth-rpcgss-module` → `rpc-gssd` →
  `rpc_pipefs.target` before their keytab conditions are checked; the
  fixture now lists `sunrpc` (production ships every module).
- BLOCKED until frostyard/bootc-debian and the Frostyard incus packaging
  publish forky builds: the three OCI bootc profiles (`cayo`, `snow`,
  `snowfield`) cannot resolve `libostree-1-1`, and the `incus` sysext
  cannot resolve `incus-base` (the same build failed there at apt on
  `libgpgme11t64`). The Task 4 bootc build/root check is the acceptance
  gate for the rebuilt debs.
- Installs still running a trixie image have `%w`=13 and keep matching the
  `_13_` artifacts; forky-built sysexts are invisible to them. The last
  trixie sysext set must stay published until every install has taken a
  forky base image, and the base/OS update has to reach a machine before
  its sysexts can.
- The secure native profiles no longer differ from `cayo-ab-raw` in
  systemd version; the `.gpg`/`.pgp` vendor-keyring caveat recorded for
  the raw fixture (systemd 257 vs 261) is historical.
- gui-base and the divergent-lib tripwire lose their live example (no
  product pins a second suite any more) but stay: delta omission is still
  decided by presence in the build base, and the next cross-suite pin
  would reopen the shadow-downgrade.
- Testing moves; a package rename or removal in the archive now surfaces
  at the next build instead of at the next stable point release. The
  daily `check-packages.yml` and weekly `check-dependencies.yml` do not
  cover Debian archive churn; a failed build is the detector.
- The Task 4 note that the Forky systemd family is a cross-suite risk
  against the Frostyard debs inverts: the debs are now the trixie-built
  side of the mismatch.

## Alternatives considered

- **Stay on trixie and keep widening the forky/backports pins:** every
  widened pin is another ABI seam of the kind issue #781 came from, and
  the secure products already ran forky's systemd; the tree was two
  releases at once in all but name.
- **Keep the secure fragments' `/forky` suffixes as a no-op:** a suffix
  that matches the base release is harmless today and a silent cross-suite
  pin the day the base moves again; the static test now forbids the
  pattern outright instead.
- **Set `VERSION_ID` in `common-postinst.sh` (product images) instead of
  base:** sysexts build on `%O/base` and would then carry no `VERSION_ID`
  in their extension-release while the host had one, failing the sysext
  match; the value has to originate below every consumer.
- **Rebuild Sunshine from the trixie deb by patching its Depends:** the
  binary links the newer sonames anyway; the Ubuntu 26.04 build is the
  one LizardByte actually built against those libraries.

## References

- Shapes: [design/overview.md](../design/overview.md),
  [design/build-pipeline.md](../design/build-pipeline.md),
  [design/sysexts.md](../design/sysexts.md), `README.md`, `AGENTS.md`
- Builds on: [ADR-0005](0005-profiles-as-transport-kernel-selectors.md)
  (profiles as transport+kernel selectors),
  [ADR-0006](0006-name-triggered-publication-guards.md) (static textual
  guards on the secure fragments)
- Enforced by: `test/native-ab-static-test.sh`,
  `test/bootc-secure-static-test.sh`, `test/sysext-postoutput-test.sh`
