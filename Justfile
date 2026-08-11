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
    (cd "$src" && CGO_ENABLED=0 go build \
        -ldflags "-X main.version=$version -X main.commit=$commit -X main.date=$build_time -X main.builtBy=snosi-justfile" \
        -o "$out" ./cmd/firn-cli)
    echo "built $out ($version, $commit)"

[private]
_firn-installer: _clean
    {{mkosi}} --profile firn-installer build

[private]
_firn-installer-iso: _clean
    {{mkosi}} --profile firn-installer build
    ./shared/firn-installer/tools/build-iso.sh output/firn-installer output "$(date -u +%Y%m%d%H%M%S)"

[private]
_test-install image="output/snow":
    ./test/bootc-install-test.sh {{image}}

[private]
_run-qemu image="output/snow":
    ./test/run-qemu.sh {{image}}
