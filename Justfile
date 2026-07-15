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
    ./shared/native-installer/tools/build-iso.sh output/native-installer output/native-installer.iso

[private]
_test-install image="output/snow":
    ./test/bootc-install-test.sh {{image}}

[private]
_run-qemu image="output/snow":
    ./test/run-qemu.sh {{image}}
