set dotenv-load := true

just := `which just`

# mkosi runs from a repo-local checkout pinned to the same commit as the
# systemd/mkosi action in CI (single source of truth: build.yml, which the
# other workflows mirror; shared/native-ab/ci/bootstrap-mkosi.sh derives the
# pin itself from build.yml). Delete .mkosi/ to discard it, or override with
# `just mkosi=/usr/bin/mkosi <target>` to use a system install.
mkosi_dir := justfile_directory() / ".mkosi"
mkosi := mkosi_dir / "bin" / "mkosi"

default:
    {{just}} --list --unsorted

clean: ensure-mkosi
    sudo PATH="$PATH" {{just}} _clean

sysexts: ensure-mkosi
    sudo PATH="$PATH" {{just}} _sysexts

snow: ensure-mkosi
    sudo PATH="$PATH" {{just}} _snow

snowfield: ensure-mkosi
    sudo PATH="$PATH" {{just}} _snowfield

cayo: ensure-mkosi
    sudo PATH="$PATH" {{just}} _cayo

cayo-ab: ensure-mkosi
    sudo PATH="$PATH" {{just}} _cayo-ab

snow-ab: ensure-mkosi
    sudo PATH="$PATH" {{just}} _snow-ab

snowfield-ab: ensure-mkosi
    sudo PATH="$PATH" {{just}} _snowfield-ab

native-installer-iso: ensure-mkosi
    sudo PATH="$PATH" {{just}} _native-installer-iso

# Single-installer ISO for all image families (firn ADR-0010, successor to
# native-installer; see shared/firn-installer/README.md). The firn binary is
# built from a sibling firn checkout by _firn-binary, which runs as the
# invoking user BEFORE sudo (same reasoning as ensure-mkosi: the artifact
# must not be root-owned, and root has no Go toolchain/module cache).
# FIRN_SRC defaults to ../firn relative to this repo's root -- worktree
# users must set it to a real checkout, e.g.:
#   FIRN_SRC=~/projects/frostyard/firn just firn-installer
firn-installer: ensure-mkosi _firn-binary
    sudo PATH="$PATH" {{just}} _firn-installer

firn-installer-iso: ensure-mkosi _firn-binary
    sudo PATH="$PATH" {{just}} _firn-installer-iso

# Build the offline flatpak seed tree consumed by the installer ISO (firn
# ADR-0006 media obligation: seed the core desktop apps + runtime so the
# install-time offline path is the common path, not the degraded one). This
# is SLOW and needs network + several GiB of disk: it downloads every app in
# shared/firn-installer/core.json plus their GNOME/freedesktop runtimes from
# Flathub. Run it BEFORE `just firn-installer-iso` -- that recipe picks the
# tree up automatically if it exists (output/firn-flatpak-seed) and builds a
# seeded ISO; skip it and the ISO is built without a seed and firn falls back
# to network at install time (ADR-0006 report-don't-fail).
#
# Runs as the INVOKING user (never sudo): `flatpak --user` writes the tree
# directly with no polkit/system-helper round-trip, and a root-owned tree
# would need chown fixups anyway. build-iso.sh squashes the tree with
# -all-root so the medium presents a root-owned /var/lib/flatpak, matching a
# real system installation and what firn's tar-copy expects.
firn-flatpak-seed:
    #!/usr/bin/env bash
    set -euo pipefail
    core="{{justfile_directory()}}/shared/firn-installer/core.json"
    seed="{{justfile_directory()}}/output/firn-flatpak-seed"
    [[ -f "$core" ]] || { echo "Error: missing $core" >&2; exit 1; }
    command -v flatpak >/dev/null || { echo "Error: flatpak not found on build host" >&2; exit 1; }
    # x86-64 is the only installer arch today (build-iso.sh emits
    # snosi-installer_<version>_x86-64.iso); pin it so a non-x86 build host
    # still seeds the medium's arch, not its own.
    arch=x86_64
    # The medium seeds SYSTEM flatpaks, but we build the tree via a --user
    # installation pointed at $seed (FLATPAK_USER_DIR): the on-disk layout is
    # identical (repo/ + app/ + runtime/ + exports/, bare-user-only repo) and
    # `flatpak list --system` reads it verbatim once it is mounted at
    # /var/lib/flatpak. Building --user avoids needing root or a running
    # flatpak-system-helper/polkit on the build host.
    #
    # CRITICAL isolation: point FLATPAK_SYSTEM_DIR and FLATPAK_CONFIG_DIR at
    # throwaway EMPTY dirs so the build host's OWN flatpak installations are
    # invisible during resolution. Without this, if the host already has e.g.
    # org.gnome.Platform installed, flatpak treats the app's runtime
    # dependency as already satisfied and does NOT copy it into $seed -- the
    # seed then ships apps with no runtime and the offline install is broken.
    seedtmp="{{justfile_directory()}}/output/.firn-flatpak-seed-hidden"
    rm -rf "$seed" "$seedtmp"
    mkdir -p "$seed" "$seedtmp/system" "$seedtmp/config"
    export FLATPAK_USER_DIR="$seed"
    export FLATPAK_SYSTEM_DIR="$seedtmp/system"
    export FLATPAK_CONFIG_DIR="$seedtmp/config"
    # Pin Flathub as the seed remote (same remote firn adds at install time
    # for the network-download leg, internal/flatpak/flatpak.go).
    flatpak remote-add --user --if-not-exists \
        flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    # Read the app IDs from the vendored core.json. This copy MUST track
    # frostyard/first-setup's snow_first_setup/core.json (the single source of
    # truth firn ALSO reads at install time for core_flatpaks, see
    # internal/flatpak/flatpak.go coreJSONPath) -- re-vendor it when
    # first-setup's list changes. sort -u dedups the human-maintained list
    # (it has carried duplicates, e.g. Loupe).
    mapfile -t ids < <(python3 -c 'import json,sys; print("\n".join(e["id"] for e in json.load(open(sys.argv[1]))["core"] if e.get("id")))' "$core" | sort -u)
    echo "Seeding ${#ids[@]} core flatpaks (+ runtimes) for $arch into $seed"
    for id in "${ids[@]}"; do
        echo "--- $id"
        flatpak install --user -y --noninteractive --arch="$arch" flathub "$id"
    done
    rm -rf "$seedtmp"
    echo "=== seeded refs ==="
    FLATPAK_SYSTEM_DIR="$seed" flatpak list --system --columns=ref
    echo "seed tree ready: $seed ($(du -sh "$seed" | cut -f1))"

test-install image="output/snow":
    sudo PATH="$PATH" {{just}} _test-install {{image}}

run-qemu image="output/snow":
    sudo PATH="$PATH" DISK_SIZE=50G {{just}} _run-qemu {{image}}

# Fetch mkosi into .mkosi/ when missing or not at the CI-pinned commit.
# Runs as the invoking user (before sudo) so the checkout is not root-owned.
# Delegates to shared/native-ab/ci/bootstrap-mkosi.sh, the single
# implementation of "how mkosi gets bootstrapped from build.yml's pin" also
# used by .github/workflows/build-native-images.yml's build jobs -- see that
# script's header and shared/native-ab/ci/check-mkosi-pin.sh ("Mkosi Pin
# Governance": "CI must derive local and workflow mkosi from the same
# commit and fail if they diverge").
[private]
ensure-mkosi:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{mkosi}}" != "{{mkosi_dir}}/bin/mkosi" ]; then
        exit 0  # mkosi was overridden on the command line; use it as-is
    fi
    "{{justfile_directory()}}/shared/native-ab/ci/bootstrap-mkosi.sh" "{{mkosi_dir}}"

# Private targets (run as root via sudo)

[private]
_clean:
    {{mkosi}} clean -ff

[private]
_sysexts: _clean
    {{mkosi}} build

[private]
_snow: _clean
    {{mkosi}} --profile snow build

[private]
_snowfield: _clean
    {{mkosi}} --profile snowfield build

[private]
_cayo: _clean
    {{mkosi}} --profile cayo build

[private]
_cayo-ab: _clean
    {{mkosi}} --profile cayo-ab build

[private]
_snow-ab: _clean
    {{mkosi}} --profile snow-ab build

[private]
_snowfield-ab: _clean
    {{mkosi}} --profile snowfield-ab build

[private]
_native-installer-iso: _clean
    {{mkosi}} --profile native-installer build
    ./shared/native-installer/tools/build-iso.sh output/native-installer output "$(date -u +%Y%m%d%H%M%S)"

# Build the firn TUI binary into shared/firn-installer/tree/usr/bin/firn
# (gitignored; the image postinst refuses to build without it -- see
# shared/firn-installer/README.md. TODO: replace with a frostyard-firn
# Packages= entry once firn cuts a release). CGO_ENABLED=0: the binary runs
# inside the ISO rootfs and must not depend on the build host's libc.
# Version stamping mirrors firn's own Makefile LDFLAGS
# (main.version/commit/date/builtBy), so the medium's firn reports the
# source checkout's `git describe` version.
[private]
_firn-binary:
    #!/usr/bin/env bash
    set -euo pipefail
    src="${FIRN_SRC:-{{justfile_directory()}}/../firn}"
    [[ -d "$src" ]] || { echo "Error: firn checkout not found at $src -- set FIRN_SRC (see shared/firn-installer/README.md)" >&2; exit 1; }
    version=$(git -C "$src" describe --tags --always --dirty 2>/dev/null || echo dev)
    commit=$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo none)
    build_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    out="{{justfile_directory()}}/shared/firn-installer/tree/usr/bin/firn"
    # Keep the go build + module caches off $HOME so this works as any
    # user, including root on an image-based build host whose /root is a
    # read-only erofs ($HOME/.cache and $HOME/go would both EROFS).
    export GOCACHE="${GOCACHE:-{{justfile_directory()}}/output/.go-build-cache}"
    export GOPATH="${GOPATH:-{{justfile_directory()}}/output/.go-path}"
    mkdir -p "$GOCACHE" "$GOPATH"
    (cd "$src" && CGO_ENABLED=0 go build \
        -ldflags "-X main.version=$version -X main.commit=$commit -X main.date=$build_time -X main.builtBy=snosi-justfile" \
        -o "$out" ./cmd/firn-cli)
    echo "built $out ($version, $commit)"

[private]
_firn-installer: _clean
    {{mkosi}} --profile firn-installer build

[private]
_firn-installer-iso: _clean
    #!/usr/bin/env bash
    set -euo pipefail
    {{mkosi}} --profile firn-installer build
    # Pick up the offline flatpak seed if `just firn-flatpak-seed` built one.
    # Absent -> a seedless ISO and firn falls back to network at install time
    # (ADR-0006 report-don't-fail); NEVER a hard failure here. mkosi clean (the
    # _clean dep) only removes its own firn-installer output, not this sibling
    # dir, so a seed built before the ISO recipe survives.
    seed="{{justfile_directory()}}/output/firn-flatpak-seed"
    if [[ -d "$seed/repo" ]]; then
        echo "Using offline flatpak seed: $seed"
        export FIRN_FLATPAK_SEED_DIR="$seed"
    else
        echo "No flatpak seed at $seed; building seedless ISO (network fallback, ADR-0006). Run 'just firn-flatpak-seed' first to seed."
    fi
    ./shared/firn-installer/tools/build-iso.sh output/firn-installer output "$(date -u +%Y%m%d%H%M%S)"

[private]
_test-install image="output/snow":
    ./test/bootc-install-test.sh {{image}}

[private]
_run-qemu image="output/snow":
    ./test/run-qemu.sh {{image}}
