# Inline bootc + ostree Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compile ostree and bootc from pinned source inside the snosi base image build, and remove the `bootc` and `libostree-1-1` APT packages that came from the (now-archived) Frostyard packaging repo.

**Architecture:** A `postinst.chroot` script runs inside the base image chroot. It installs build dependencies via apt, downloads SHA256-verified release tarballs through the existing `verified_download` helper, compiles ostree (autotools) and bootc (Cargo, offline vendored) directly into the image's `/usr`, then purges the build-only dependencies. The two ex-APT packages are dropped from `mkosi.images/base/mkosi.conf`, and ostree's runtime shared libraries are added to `Packages=` so they survive the post-build purge.

**Tech Stack:** mkosi, bash, autotools (ostree), Cargo/rustc (bootc), Debian Trixie.

## Global Constraints

- **bootc version:** `v1.16.2` — tarball `bootc-1.16.2.tar.zstd`, vendor `bootc-1.16.2-vendor.tar.zstd`.
- **ostree version:** `v2026.1` — tarball `libostree-2026.1.tar.xz`.
- **Rust toolchain:** Debian Trixie's `rustc` (1.85) is too OLD to build bootc 1.16.2 — its xtask/build deps (`cargo_metadata`, `cargo-platform`) need rustc >= 1.91 despite the crate's declared MSRV of 1.85. The build script installs a pinned toolchain (`RUST_VERSION=1.96.0`) via `rustup` (from `BuildPackages=`) and runs `make` under `rustup run "$RUST_VERSION"`. (Do NOT rely on Debian's rustc/cargo.)
- **Pinning:** every external download has a `checksums.json` entry (URL + SHA256 + version) and a matching update check in `.github/workflows/check-dependencies.yml`. Never `latest`/branch names.
- **Shell scripts:** `set -euo pipefail` at top; build scripts that run in chroot use `.chroot` extension; pass shellcheck (`validate.yml` enforces it).
- **Build mechanism:** ostree/bootc are compiled by a mkosi **BuildScript**; build deps come from `BuildPackages=` (build-overlay only) and the artifacts are installed to `$DESTDIR`. The image rootfs has no `apt`, so build deps are NOT apt-installed in-script. Build deps must NOT remain in the final image (mkosi discards the overlay automatically).
- **Immutable FS:** all compiled files land under `/usr` (ostree's `--sysconfdir=/etc` config files are the one intentional exception, matching prior dpkg behavior).
- **Verified SHA256 values (computed 2026-06-29):**
  - ostree `libostree-2026.1.tar.xz`: `8e77c285dd6fa5ec5fb063130390977be727fe11107335ed8778a40385069e95`
  - bootc `bootc-1.16.2.tar.zstd`: `b407aa47a61ecda39256c3e3dbeef25c31585c5644ad6d40f5397522a4d2edc7`
  - bootc vendor `bootc-1.16.2-vendor.tar.zstd`: `53d759ca521144a675af67e68d23c3f5f18dca784e4e900052d0cfdc4467732b`

---

### Task 1: Pin sources in checksums.json

**Files:**
- Modify: `shared/download/checksums.json`

**Interfaces:**
- Produces: three `verified_download` keys — `ostree`, `bootc`, `bootc-vendor` — consumed by the build script in Task 3.

- [ ] **Step 1: Add the three entries**

Add these keys to the JSON object in `shared/download/checksums.json` (alongside existing entries; mind the trailing commas so the file stays valid JSON):

```json
  "ostree": {
    "url": "https://github.com/ostreedev/ostree/releases/download/v2026.1/libostree-2026.1.tar.xz",
    "sha256": "8e77c285dd6fa5ec5fb063130390977be727fe11107335ed8778a40385069e95",
    "version": "2026.1"
  },
  "bootc": {
    "url": "https://github.com/bootc-dev/bootc/releases/download/v1.16.2/bootc-1.16.2.tar.zstd",
    "sha256": "b407aa47a61ecda39256c3e3dbeef25c31585c5644ad6d40f5397522a4d2edc7",
    "version": "1.16.2"
  },
  "bootc-vendor": {
    "url": "https://github.com/bootc-dev/bootc/releases/download/v1.16.2/bootc-1.16.2-vendor.tar.zstd",
    "sha256": "53d759ca521144a675af67e68d23c3f5f18dca784e4e900052d0cfdc4467732b",
    "version": "1.16.2"
  }
```

- [ ] **Step 2: Verify the file is valid JSON and keys resolve**

Run:
```bash
jq -e '.ostree.url, .bootc.url, ."bootc-vendor".url' shared/download/checksums.json
```
Expected: prints the three URLs, exit 0 (no JSON parse error).

- [ ] **Step 3: Verify the helper can resolve and download+checksum each key**

Run (uses the real helper end-to-end against the network):
```bash
CHECKSUMS_FILE=shared/download/checksums.json bash -c '
  source shared/download/verified-download.sh
  for k in ostree bootc bootc-vendor; do
    verified_download "$k" "/tmp/vd-$k" || exit 1
  done'
```
Expected: `Verified ostree`, `Verified bootc`, `Verified bootc-vendor`; exit 0. (A checksum mismatch here means the pinned SHA256 is wrong — stop and fix.)

- [ ] **Step 4: Commit**

```bash
git add shared/download/checksums.json
git commit -m "feat: pin ostree v2026.1 and bootc v1.16.2 source tarballs"
```

---

### Task 2: Write the bootc + ostree build script

**Files:**
- Create: `shared/bootc/build/bootc.chroot`

**Interfaces:**
- Consumes: `verified_download` keys `ostree`, `bootc`, `bootc-vendor` (Task 1); `$SRCDIR/shared/download/verified-download.sh`.
- Produces: `/usr/bin/bootc`, `/usr/bin/ostree`, `libostree` shared libs under `/usr/lib/<multiarch>`, bootc systemd units + dracut module — relied on by Task 3's wiring and Task 5's smoke checks.

Notes for the implementer:
- This is a mkosi **BuildScript** (wired via `BuildScripts=` in Task 3), NOT a postinstall script. It runs inside the build overlay, which has the image's packages plus the `BuildPackages=` toolchain. There is NO `apt` in this script — mkosi installs the build deps (the image rootfs has no apt; that is why the earlier postinst.chroot approach failed). Follow the `$SRCDIR`-sourcing pattern from `shared/snow/scripts/build/hotedge.chroot` (also a BuildScript).
- The overlay is discarded after the script; only files placed in `$DESTDIR` are copied into the image. So ostree is installed twice: `make install DESTDIR="$DESTDIR"` (to ship) and `make install DESTDIR=` (explicitly empty — overrides the `DESTDIR` mkosi exports into the build env — so it installs into the overlay's real `/usr`, where the bootc build finds ostree-1.pc and loads libostree). bootc installs once: `make install-all DESTDIR="$DESTDIR"`.
- ostree tarball extracts to `libostree-2026.1/` and ships a prebuilt `configure` (no `autogen.sh`/submodules needed).
- bootc source extracts to `bootc-1.16.2/`; the vendor tarball extracts to a `vendor/` dir that must sit at `bootc-1.16.2/vendor/`, and bootc ships `.cargo/vendor-config.toml` to wire it up for an offline build.

- [ ] **Step 1: Write the script**

Create `shared/bootc/build/bootc.chroot`:

```bash
#!/bin/bash
# Compile ostree and bootc from pinned source and install them into the image.
# Replaces the formerly-APT-installed `bootc` and `libostree-1-1` packages
# (built by the now-archived frostyard/bootc-debian recipe).
#
# This runs as a mkosi BuildScript: it executes inside the build overlay, which
# contains the image's packages PLUS the build-only packages from BuildPackages=
# (Task 3). The overlay — and therefore every build dependency — is discarded
# after this script; only what we install into $DESTDIR is copied into the final
# image. So there is no apt install/purge here: mkosi provides the toolchain and
# mkosi cleans it up.
set -euo pipefail
if [[ "${DEBUG_BUILD:-0}" == "1" ]]; then
    set -x
fi

# Pinned Rust toolchain. Debian's rustc (1.85) is too OLD to build bootc 1.16.2
# (xtask/build deps need >= 1.91). Install this exact toolchain via rustup.
RUST_VERSION="1.96.0"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

source "$SRCDIR/shared/download/verified-download.sh"

MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"

# --- Install the pinned Rust toolchain into the (discarded) build overlay ---
export RUSTUP_HOME="$WORK/rustup"
export CARGO_HOME="$WORK/cargo"
rustup toolchain install "$RUST_VERSION" --profile minimal

# --- Build ostree. Install into $DESTDIR (ships in the image) AND into the
#     overlay's live /usr (so the bootc build below can link against it). ---
verified_download "ostree" "$WORK/ostree.tar.xz"
tar -xJf "$WORK/ostree.tar.xz" -C "$WORK"
OSTREE_SRC="$(find "$WORK" -maxdepth 1 -type d -name 'libostree-*' | head -n1)"
[[ -n "$OSTREE_SRC" ]] || { echo "Error: ostree source dir not found" >&2; exit 1; }
(
    cd "$OSTREE_SRC"
    ./configure \
        --prefix=/usr \
        --libdir="/usr/lib/${MULTIARCH}" \
        --sysconfdir=/etc \
        --with-curl \
        --with-dracut
    make -j"$(nproc)"
    make install DESTDIR="$DESTDIR"
    # DESTDIR= explicitly empty: override the DESTDIR mkosi exports into the
    # build env, so this install reaches the overlay's real /usr (needed so the
    # bootc build can find ostree-1.pc and run the bootc binary for docgen).
    make install DESTDIR=
)
ldconfig

# --- Build bootc (offline, vendored crates); install into $DESTDIR. ---
verified_download "bootc" "$WORK/bootc.tar.zstd"
verified_download "bootc-vendor" "$WORK/bootc-vendor.tar.zstd"
tar --use-compress-program=unzstd -xf "$WORK/bootc.tar.zstd" -C "$WORK"
BOOTC_SRC="$(find "$WORK" -maxdepth 1 -type d -name 'bootc-*' | head -n1)"
[[ -n "$BOOTC_SRC" ]] || { echo "Error: bootc source dir not found" >&2; exit 1; }
# Vendor tarball extracts a top-level vendor/ dir; place it inside the source
# tree and activate the shipped offline cargo config.
tar --use-compress-program=unzstd -xf "$WORK/bootc-vendor.tar.zstd" -C "$BOOTC_SRC"
cp "$BOOTC_SRC/.cargo/vendor-config.toml" "$BOOTC_SRC/.cargo/config.toml"
(
    cd "$BOOTC_SRC"
    export PKG_CONFIG_PATH="/usr/lib/${MULTIARCH}/pkgconfig:/usr/share/pkgconfig"
    export CARGO_NET_OFFLINE=true
    # Run make under the pinned toolchain so nested `cargo` calls use it.
    rustup run "$RUST_VERSION" make bin
    rustup run "$RUST_VERSION" make install-all DESTDIR="$DESTDIR"
)

echo "bootc and ostree built and installed into \$DESTDIR"
```

- [ ] **Step 2: Verify it passes shellcheck**

Run:
```bash
shellcheck shared/bootc/build/bootc.chroot
```
Expected: no output, exit 0. (`validate.yml` runs shellcheck on PRs — this must be clean.)

- [ ] **Step 3: Verify executable bit**

Run:
```bash
chmod +x shared/bootc/build/bootc.chroot
test -x shared/bootc/build/bootc.chroot && echo OK
```
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add shared/bootc/build/bootc.chroot
git commit -m "feat: add in-tree bootc + ostree source build script"
```

---

### Task 3: Wire the build into the base image and drop the APT packages

**Files:**
- Modify: `mkosi.images/base/mkosi.conf`

**Interfaces:**
- Consumes: the build script `shared/bootc/build/bootc.chroot` (Task 2).
- Produces: a base image that no longer pulls `bootc`/`libostree-1-1` from APT and runs the source build instead.

- [ ] **Step 1: Remove the two ex-APT packages**

In `mkosi.images/base/mkosi.conf`, delete these two lines (the `# bootc` block at ~line 103-105):
```
# bootc
Packages=bootc
         libostree-1-1
```
Replace the block with ostree's/bootc's runtime shared-library dependencies (these ship in the image and are what the compiled binaries link against at runtime):
```
# ostree/bootc runtime libraries (ostree + bootc are compiled from source in
# shared/bootc/build/bootc.chroot; these are their runtime link deps)
Packages=libcurl4t64
         libglib2.0-0t64
         libgpgme11t64
         libarchive13t64
         libsystemd0
         zlib1g
         libfuse3-4
         libsoup-3.0-0
         liblzma5
         libzstd1
         libmount1
         libselinux1
         libcom-err2
         libext2fs2t64
```
(Several of these already appear in the existing `# Runtime libraries for ostree/bootc` block at ~line 50 — that's fine, duplicates are harmless, but you may consolidate them into one block.)

- [ ] **Step 2: Wire the build script as a BuildScript and add the build packages**

Add these to the `[Content]` section of `mkosi.images/base/mkosi.conf`. The build deps go in `BuildPackages=` — mkosi installs them into the build overlay only, so they never ship in the image (this is what makes the apt-purge dance unnecessary):
```
BuildScripts=%D/shared/bootc/build/bootc.chroot

# Build-only deps for compiling ostree + bootc (overlay only; not shipped)
BuildPackages=build-essential
              pkg-config
              autoconf
              automake
              libtool
              bison
              dpkg-dev
              xz-utils
              zstd
              libcurl4-openssl-dev
              libssl-dev
              libsystemd-dev
              libgpgme-dev
              libarchive-dev
              libfuse3-dev
              libglib2.0-dev
              libzstd-dev
              liblzma-dev
              libsoup-3.0-dev
              e2fslibs-dev
              libext2fs-dev
              libmount-dev
              libselinux1-dev
              gobject-introspection
              libgirepository1.0-dev
              go-md2man
              rustup
```
(If the build later reports a missing header/lib, add the corresponding `-dev` package here — this is the expected one-or-two-iteration tuning the plan calls out. Because these are overlay-only, adding extras here is cheap and safe.)

- [ ] **Step 3: Verify bootc/libostree are no longer image packages**

Run:
```bash
mkosi --directory . summary 2>/dev/null | grep -iE "^\s*Packages:.*\b(bootc|libostree-1-1)\b" && echo "STILL PRESENT (bad)" || echo "no bootc/libostree image package — good"
```
Expected: `no bootc/libostree image package — good`.

- [ ] **Step 4: Verify the build script is scheduled**

Run:
```bash
mkosi --directory . summary 2>/dev/null | grep -i "bootc.chroot" && echo "build script wired"
```
Expected: shows `bootc.chroot` under Build Scripts; `build script wired`.

- [ ] **Step 5: Commit**

```bash
git add mkosi.images/base/mkosi.conf
git commit -m "feat: build bootc/ostree from source in base via BuildScript, drop frostyard APT packages"
```

---

### Task 4: Add dependency update checks

**Files:**
- Modify: `.github/workflows/check-dependencies.yml`

**Interfaces:**
- Consumes: `checksums.json` keys `ostree`, `bootc`, `bootc-vendor` (Task 1).
- Produces: weekly PRs that bump those pins when upstream releases.

The workflow has two relevant steps: the `check` step (id `check`) that detects updates and sets `$GITHUB_OUTPUT` flags, and the `Update checksums` step that rewrites `checksums.json`. Add to BOTH, mirroring the `code-server` blocks exactly (release tag stripped of leading `v`).

- [ ] **Step 1: Add detection blocks to the `check` step**

In the `Check for dependency updates` step, after the `code-server` block (around line 52), add:

```bash
          # Check ostree
          CURRENT_OSTREE=$(jq -r '.ostree.version' "$CHECKSUMS")
          LATEST_OSTREE=$(curl -s https://api.github.com/repos/ostreedev/ostree/releases/latest | jq -r '.tag_name' | sed 's/^v//')
          if [[ -n "$LATEST_OSTREE" && "$LATEST_OSTREE" != "$CURRENT_OSTREE" ]]; then
            UPDATES="${UPDATES}ostree: $CURRENT_OSTREE -> $LATEST_OSTREE\n"
            echo "ostree_update=true" >> $GITHUB_OUTPUT
            echo "ostree_version=$LATEST_OSTREE" >> $GITHUB_OUTPUT
          fi

          # Check bootc (bootc + bootc-vendor version together)
          CURRENT_BOOTC=$(jq -r '.bootc.version' "$CHECKSUMS")
          LATEST_BOOTC=$(curl -s https://api.github.com/repos/bootc-dev/bootc/releases/latest | jq -r '.tag_name' | sed 's/^v//')
          if [[ -n "$LATEST_BOOTC" && "$LATEST_BOOTC" != "$CURRENT_BOOTC" ]]; then
            UPDATES="${UPDATES}bootc: $CURRENT_BOOTC -> $LATEST_BOOTC\n"
            echo "bootc_update=true" >> $GITHUB_OUTPUT
            echo "bootc_version=$LATEST_BOOTC" >> $GITHUB_OUTPUT
          fi
```

- [ ] **Step 2: Add rewrite blocks to the `Update checksums` step**

In the `Update checksums` step, after the `code-server` block (around line 135), add:

```bash
          if [[ "${{ steps.check.outputs.ostree_update }}" == "true" ]]; then
            VER="${{ steps.check.outputs.ostree_version }}"
            URL="https://github.com/ostreedev/ostree/releases/download/v${VER}/libostree-${VER}.tar.xz"
            TMP=$(mktemp)
            curl -fsSL -o "$TMP" "$URL"
            SHA=$(sha256sum "$TMP" | cut -d' ' -f1)
            jq --arg u "$URL" --arg s "$SHA" --arg v "$VER" \
              '.ostree.url=$u | .ostree.sha256=$s | .ostree.version=$v' \
              "$CHECKSUMS" > tmp.json && mv tmp.json "$CHECKSUMS"
            rm -f "$TMP"
          fi

          if [[ "${{ steps.check.outputs.bootc_update }}" == "true" ]]; then
            VER="${{ steps.check.outputs.bootc_version }}"
            URL="https://github.com/bootc-dev/bootc/releases/download/v${VER}/bootc-${VER}.tar.zstd"
            VURL="https://github.com/bootc-dev/bootc/releases/download/v${VER}/bootc-${VER}-vendor.tar.zstd"
            TMP=$(mktemp); VTMP=$(mktemp)
            curl -fsSL -o "$TMP" "$URL"
            curl -fsSL -o "$VTMP" "$VURL"
            SHA=$(sha256sum "$TMP" | cut -d' ' -f1)
            VSHA=$(sha256sum "$VTMP" | cut -d' ' -f1)
            jq --arg u "$URL" --arg s "$SHA" --arg v "$VER" \
               --arg vu "$VURL" --arg vs "$VSHA" \
              '.bootc.url=$u | .bootc.sha256=$s | .bootc.version=$v
               | .["bootc-vendor"].url=$vu | .["bootc-vendor"].sha256=$vs | .["bootc-vendor"].version=$v' \
              "$CHECKSUMS" > tmp.json && mv tmp.json "$CHECKSUMS"
            rm -f "$TMP" "$VTMP"
          fi
```

- [ ] **Step 3: Verify the workflow is valid YAML**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/check-dependencies.yml'))" && echo "valid YAML"
```
Expected: `valid YAML`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/check-dependencies.yml
git commit -m "ci: track ostree and bootc release updates"
```

---

### Task 5: Build verification (integration)

**Files:** none (verification only)

**Interfaces:**
- Consumes: everything from Tasks 1-3.

> This is the real test: a clean build that compiles both projects and an
> in-image smoke check. Build-dependency lists for from-source compiles often
> need one or two iterations — if the build fails on a missing header/lib, add
> the corresponding `-dev` package to `BUILD_DEPS` in `shared/bootc/build/bootc.chroot`,
> re-run, and amend Task 2's commit.

- [ ] **Step 1: Clean build of the base (via a downstream image)**

Run (root/sudo required, per project build docs):
```bash
just snow
```
Expected: build completes without error; in particular the `bootc.chroot` post-install step compiles ostree and bootc and the apt purge runs at the end.

- [ ] **Step 2: Smoke-check the built rootfs**

Run (adjust path to the snow output rootfs directory):
```bash
sudo chroot output/snow /usr/bin/bootc --version
sudo chroot output/snow /usr/bin/ostree --version
```
Expected: bootc prints `1.16.2` (or a version string containing it); ostree prints `2026.1`.

- [ ] **Step 3: Confirm build deps did not ship**

Run:
```bash
sudo chroot output/snow bash -c 'command -v rustc cargo cc autoconf 2>/dev/null; dpkg -l | grep -E "libgpgme-dev|libarchive-dev|^ii  rustc" || echo "no build deps present"'
```
Expected: `no build deps present` (the toolchain and `-dev` packages were purged). `gcc`/`make` may still be present because base installs them — that's expected and fine.

- [ ] **Step 4: Confirm the bootc dracut module is present**

Run:
```bash
sudo find output/snow/usr/lib/dracut/modules.d -maxdepth 1 -iname '*bootc*'
```
Expected: a bootc dracut module directory exists (consumed by `30-bootc-standard.conf`).

- [ ] **Step 5: No commit** (verification only). If `BUILD_DEPS` needed changes, amend the Task 2 commit instead.

---

### Task 6: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md` (if it documents image contents / bootc origin)
- Modify/Create: `yeti/` content (architecture/decision rationale)

**Interfaces:** none.

- [ ] **Step 1: Update CLAUDE.md**

In `CLAUDE.md`, document that bootc and ostree are compiled from pinned source in `shared/bootc/build/bootc.chroot` during the base image build (not installed from the Frostyard APT repo). Note the version pins live in `checksums.json` and are tracked by `check-dependencies.yml`, and that build dependencies are installed and purged within the script. Add `shared/bootc/` to the Key Directories section.

- [ ] **Step 2: Update README.md if applicable**

Run:
```bash
grep -ni "bootc" README.md
```
If the README states where bootc comes from or lists APT-sourced components, update it to reflect the in-tree source build. If there is nothing relevant, skip.

- [ ] **Step 3: Update yeti/ context**

Run:
```bash
ls yeti/ && grep -rni "bootc\|libostree" yeti/ | head
```
Add or update the relevant yeti doc with the rationale (Frostyard packaging repo archived; Trixie has no bootc and only ostree 2025.2; we compile v2026.1/v1.16.2 in-tree for a self-contained build) and the build mechanics (postinst chroot, vendored offline cargo build, build-dep purge, runtime libs pinned in base `Packages=`).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md yeti/
git commit -m "docs: document in-tree bootc/ostree source build"
```

---

## Notes on risk / execution

- **No apt in the image (root cause of the first build failure):** the image rootfs has no `apt`/`apt-get`/`apt-mark` — mkosi drives the package manager from outside the image. So build deps CANNOT be apt-installed in-script. They are declared in `BuildPackages=` (Task 3); mkosi installs them into the build overlay and discards them afterward. This is why the script is a `BuildScript`, not a postinstall `.chroot`.
- **ostree double-install:** the BuildScript installs ostree both to `$DESTDIR` (ships) and to the overlay `/usr` (so bootc can link against libostree during its build). Only `$DESTDIR` persists into the image.
- **runtime libs:** ostree/bootc runtime link deps are in base `Packages=` (Task 3) so they ship and the compiled binaries resolve them at runtime. Do not remove them from `Packages=`.
- **verify at Task 5:** the clean build must confirm `bootc`/`ostree` work in the image and that build deps (`rustc`, `cargo`, `-dev` libs) did NOT ship (they shouldn't, since they were overlay-only).
- **Build time:** every clean build now compiles ostree + bootc. Expect several extra minutes per image build. This is the accepted cost of dropping the external APT dependency.

---

## Addendum (added during execution): dpkg registration

The in-tree build installs ostree/bootc as plain files; nothing registers them
in the dpkg database, so `dpkg -l` / `apt list --installed` (and the
`common-postinst.sh` package manifest) wouldn't show them. To mirror the old
`.deb` install, a `PostInstallationScript` registers them:

- **File:** `shared/bootc/postinst/bootc-register.chroot`; wired via
  `PostInstallationScripts=` in `mkosi.images/base/mkosi.conf` (runs after the
  BuildScript's `$DESTDIR` is merged, alongside the implicit base postinst).
- **Mechanism:** builds **metadata-only** stub `.deb`s for `libostree-1-1`
  (version `.ostree.version`) and `bootc` (version `.bootc.version`,
  `Depends: libostree-1-1`) with `dpkg-deb`, then `dpkg -i`s them. The packages
  carry no files — the binaries/libs come from the BuildScript — so dpkg records
  presence/version without owning the files.
- **Relies on:** `dpkg` being Essential (always in the image) and
  `CleanPackageMetadata=no` (dpkg DB retained).
