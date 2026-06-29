# Design: Move bootc + ostree build into the snosi base image

**Date:** 2026-06-29
**Branch:** `feat/inline-bootc-build`
**Status:** Approved (design)

## Background

snosi currently installs `bootc` and `libostree-1-1` as APT packages from the
Frostyard repository (`repository.frostyard.org`). These packages were produced
by the now-archived private repo `frostyard/bootc-debian`, whose CI cloned
upstream ostree (`v2025.6`) and bootc (`main`), compiled both, built `.deb`
packages, and published them to the Frostyard R2-backed APT repo.

Problems with the status quo:

- The packaging source repo is archived, so bootc is effectively **frozen** at
  the last published build (`bootc 0.0.202602092157.main-frostyard1`, built
  2026-02-09).
- Debian Trixie ships **no** real `bootc` package (only unrelated `bootcd`,
  `qbootctl`, `systemd-bootchart`) and ships `libostree-1-1` at `2025.2-1`,
  older than what recent bootc needs.
- The build lives outside snosi, so the OS image build depends on an external
  APT repo and an out-of-tree, archived recipe.

## Goal

Build ostree and bootc **from pinned source inside the snosi base image build**,
and remove the two Frostyard APT packages (`bootc`, `libostree-1-1`). The result
is a self-contained image build with no external APT dependency for bootc.

## Decisions

| Decision | Choice |
|----------|--------|
| Version pinning | Pin to release tags, recorded in `checksums.json` (SHA256), tracked by `check-dependencies.yml` |
| ostree version | `v2026.1` (latest; upgrade from the proven `v2025.6`) |
| bootc version | `v1.16.2` (latest stable; upgrade from the old `main` track) |
| Where the compile happens | A mkosi **BuildScript** (`BuildScripts=`) running in the build overlay; artifacts installed to `$DESTDIR` and copied into the image |
| Build deps | Declared in `BuildPackages=` — mkosi installs them into the build overlay only and discards them (never shipped). NOT apt-installed in-script: the image rootfs has no `apt`. |
| ostree scope | Compile ostree too (replicate recipe); do not rely on Debian's 2025.2 |

> **Revised after first build attempt:** the original design used a
> `postinst.chroot` that apt-installed build deps. That failed — the image
> rootfs contains no `apt` (mkosi manages packages externally). The mechanism
> was changed to the mkosi-native BuildScript + BuildPackages + `$DESTDIR`
> pattern, which also removes the build-dep purge logic entirely (the overlay
> is discarded automatically). ostree is installed twice in the BuildScript:
> to `$DESTDIR` (ships) and to the overlay `/usr` (so bootc links against it).

> Note: confirm bootc 1.16's minimum required ostree version before finalizing.
> ostree `v2026.1` is newer than the proven `v2025.6`, so it is expected to
> satisfy bootc 1.16; bootc requires a *minimum* ostree, and newer is acceptable.

## Components

### 1. `shared/download/checksums.json` — two new entries

- `ostree`:
  - URL: `https://github.com/ostreedev/ostree/releases/download/v2026.1/libostree-2026.1.tar.xz`
  - The official release tarball bundles git submodules (libglnx, etc.) and a
    pregenerated `configure`, so `autogen.sh`/`git submodule` are **not** needed.
  - `sha256` + `version` fields per existing convention.
- `bootc`:
  - URL: the `v1.16.2` source tarball (GitHub release asset or
    `/archive/refs/tags/v1.16.2.tar.gz`).
  - `Cargo.lock` pins exact crate versions; `make bin` fetches them from
    crates.io during the build (the chroot has network). Reproducible given the
    pinned tag + lockfile.
  - `sha256` + `version` fields.

### 2. `shared/bootc/build/bootc.chroot` — new build script

Wired into the base image via `PostInstallationScripts=` in
`mkosi.images/base/mkosi.conf`. Uses `set -euo pipefail` and sources
`shared/download/verified-download.sh`. Flow mirrors the proven recipe:

1. `apt-get update` + `apt-get install --no-install-recommends` the build deps:
   `build-essential pkg-config autoconf automake libtool bison git curl
   ca-certificates dpkg-dev libcurl4-openssl-dev libssl-dev libsystemd-dev
   libgpgme-dev libarchive-dev libfuse3-dev libglib2.0-dev libzstd-dev
   liblzma-dev libsoup-3.0-dev e2fslibs-dev libext2fs-dev libmount-dev
   libselinux1-dev gobject-introspection libgirepository1.0-dev dracut
   go-md2man` plus a Rust toolchain.
   - **Rust toolchain via rustup (revised after build attempt #2).** bootc
     v1.16.2's library crate *declares* MSRV `1.85.0`, but its **build tooling**
     (the `xtask` manpage generator and its vendored deps `cargo_metadata`
     `0.23.1` → rustc 1.86, `cargo-platform` `0.3.3` → rustc 1.91) requires a
     much newer rustc. Debian Trixie's `rustc 1.85.0` therefore cannot *build*
     bootc, despite "meeting" the declared MSRV. The original frostyard recipe
     used `rustup` for exactly this reason.
   - The build script installs a **pinned** toolchain (`RUST_VERSION`, currently
     `1.96.0`, the latest stable ≥ 1.91) via `rustup` (the `rustup` package from
     `BuildPackages=`; no `curl | sh`), and runs `make` under
     `rustup run "$RUST_VERSION"`. rustup verifies toolchain signatures. Bump
     `RUST_VERSION` alongside bootc when a newer toolchain is needed.
2. **ostree:** `verified_download "ostree"` → extract → from the source dir:
   ```
   MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
   ./configure --prefix=/usr --libdir="/usr/lib/${MULTIARCH}" \
       --sysconfdir=/etc --with-curl --with-dracut
   make -j"$(nproc)"
   make install        # installs directly into the image
   ldconfig
   ```
3. **bootc:** `verified_download "bootc"` → extract → from the source dir:
   ```
   export PKG_CONFIG_PATH="/usr/lib/${MULTIARCH}/pkgconfig:/usr/share/pkgconfig"
   make bin
   make install-all    # installs bootc binary, systemd units, dracut module
   ```
4. `ldconfig`.
5. Cleanup: `apt-get purge` the build deps, `apt-get autoremove --purge`,
   `apt-get clean`, remove `/var/lib/apt/lists/*`, and any temp build dirs (via
   a `trap ... EXIT`).

Failure handling: explicit error + non-zero exit if extracted source
directories are not found (pattern borrowed from `hotedge.chroot`).

### 3. `mkosi.images/base/mkosi.conf` — package changes

- Remove `bootc` (line 104) and `libostree-1-1` (line 105) from `Packages=`.
- Ensure ostree's **runtime** shared-library deps are present in `Packages=`
  (so removing the compiled-against `-dev` packages doesn't strand the runtime
  libs): `libcurl4t64`, `libglib2.0-0t64`, `libgpgme11t64`, `libarchive13t64`,
  `libsystemd0`, `zlib1g`, `libfuse3-4`, `libsoup-3.0-0`, `liblzma5`,
  `libzstd1`, `libmount1`, `libselinux1`, and the e2fs runtime libs. Most are
  already pulled in by the base; add any that are missing.
- Add the `PostInstallationScripts=` entry for the new build script.

### 4. `.github/workflows/check-dependencies.yml` — update checks

Add update checks for the ostree and bootc release tags, matching the existing
per-dependency pattern, so weekly PRs bump `checksums.json` when new releases
appear.

## Error handling

- All scripts: `set -euo pipefail`.
- `verified_download()` already aborts on checksum mismatch.
- Explicit guard if a source directory fails to extract.
- Build-dep cleanup runs even on the success path; a `trap` removes temp dirs.

## Testing / verification

- In-image smoke: `bootc --version` and `ostree --version` succeed; the bootc
  dracut module is present (`/usr/lib/dracut/modules.d/.../bootc` referenced by
  `30-bootc-standard.conf`).
- `test/tests/01-installation.sh` already asserts `bootc status` succeeds on a
  bootc-deployed image — exercised by the existing install test.
- Local gate before declaring done: a clean `just` build of the base (and at
  least one downstream image, e.g. `snow`) succeeds, and `mkosi summary` is
  clean. Confirm `bootc`/`libostree-1-1` are no longer pulled from APT and the
  compiled binaries are present with no build deps left in the image.

## Documentation

Per project rules, update after implementation:

- `CLAUDE.md` — bootc/ostree are compiled from source in the base image, not
  installed from the Frostyard APT repo; document the new build script.
- `README.md` — note the in-tree bootc/ostree build if relevant.
- `yeti/` — architecture/decision rationale for AI context.

## Tradeoffs

- Compiling ostree (autotools) + bootc (Rust release build) on every **clean**
  build (`just` always runs `mkosi clean` first) adds several minutes to the
  base image build and therefore to every downstream image. Accepted as the
  cost of removing the external APT dependency.

## Out of scope

- Re-publishing bootc to the Frostyard APT repo (we are removing that
  dependency, not maintaining it).
- Changes to sysexts or non-base images beyond what inheriting the new base
  requires.
