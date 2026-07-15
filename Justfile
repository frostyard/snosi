set dotenv-load := true

just := `which just`

# mkosi runs from a repo-local checkout pinned to the same commit as the
# systemd/mkosi action in CI (single source of truth: build.yml, which the
# other workflows mirror). Delete .mkosi/ to discard it, or override with
# `just mkosi=/usr/bin/mkosi <target>` to use a system install.
mkosi_commit := `grep -m1 -oE 'systemd/mkosi@[0-9a-f]+' .github/workflows/build.yml | cut -d@ -f2`
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

test-install image="output/snow":
    sudo PATH="$PATH" {{just}} _test-install {{image}}

run-qemu image="output/snow":
    sudo PATH="$PATH" DISK_SIZE=50G {{just}} _run-qemu {{image}}

# Fetch mkosi into .mkosi/ when missing or not at the CI-pinned commit.
# Runs as the invoking user (before sudo) so the checkout is not root-owned.
[private]
ensure-mkosi:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{mkosi}}" != "{{mkosi_dir}}/bin/mkosi" ]; then
        exit 0  # mkosi was overridden on the command line; use it as-is
    fi
    if [ -x "{{mkosi}}" ] && [ "$(git -C "{{mkosi_dir}}" rev-parse HEAD 2>/dev/null)" = "{{mkosi_commit}}" ]; then
        exit 0
    fi
    command -v python3 >/dev/null || { echo "error: python3 is required to run mkosi" >&2; exit 1; }
    echo "Installing mkosi @ {{mkosi_commit}} (CI pin) into {{mkosi_dir}}"
    rm -rf "{{mkosi_dir}}"
    git init -q "{{mkosi_dir}}"
    git -C "{{mkosi_dir}}" fetch -q --depth=1 https://github.com/systemd/mkosi.git "{{mkosi_commit}}"
    git -C "{{mkosi_dir}}" checkout -q --detach FETCH_HEAD

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
_test-install image="output/snow":
    ./test/bootc-install-test.sh {{image}}

[private]
_run-qemu image="output/snow":
    ./test/run-qemu.sh {{image}}
