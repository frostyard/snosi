#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
dropin="$repo_root/mkosi.images/pilothouse/mkosi.extra/usr/lib/systemd/system/pilothoused.service.d/10-snosi-backends.conf"
required_paths="$repo_root/mkosi.images/pilothouse/required-paths.txt"
dependency_helper="$repo_root/shared/download/deb-dependencies.sh"
checksums="$repo_root/shared/download/sysext-checksums.json"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/pilothouse-sysext-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

pilothouse_arguments=(
    '--socket /run/pilothouse/broker.sock'
    '--socket-group pilothouse'
    '--admin-group sudo'
    '--updex /usr/bin/updex'
    '--podman-socket /run/podman/podman.sock'
    '--docker unix:///var/run/docker.sock'
    '--incus'
    '--k3s /usr/bin/k3s'
)

assert_count() {
    local expected=$1 pattern=$2 file=$3
    local actual
    actual=$(grep -Ec -- "$pattern" "$file" || true)
    if [[ "$actual" -ne "$expected" ]]; then
        printf 'expected %s match(es) for %s in %s, found %s\n' \
            "$expected" "$pattern" "$file" "$actual" >&2
        exit 1
    fi
}

assert_fixed_count() {
    local expected=$1 text=$2 file=$3
    local actual
    actual=$(grep -oF -- "$text" "$file" | wc -l || true)
    if [[ "$actual" -ne "$expected" ]]; then
        printf 'expected %s occurrence(s) of %s in %s, found %s\n' \
            "$expected" "$text" "$file" "$actual" >&2
        return 1
    fi
}

assert_pilothouse_arguments() {
    local file=$1 argument

    for argument in "${pilothouse_arguments[@]}"; do
        assert_fixed_count 1 "$argument" "$file" || return 1
    done

    if ! grep -Eq -- '(^|[[:space:]])--incus([[:space:]]|$)' "$file"; then
        printf 'expected --incus to have a whitespace or EOL boundary in %s\n' "$file" >&2
        return 1
    fi
}

pilothouse_version=$(jq -er '.pilothouse.version' "$checksums")
if ! dpkg --compare-versions "$pilothouse_version" ge 0.8.0; then
    printf 'expected pinned Pilothouse version >= 0.8.0, found %s in %s\n' \
        "$pilothouse_version" "$checksums" >&2
    exit 1
fi

grep -qx '/usr/lib/systemd/system/pilothoused.service.d/10-snosi-backends.conf' "$required_paths"
assert_count 1 '^ExecStart=$' "$dropin"
assert_count 1 '^ExecStart=/usr/bin/pilothoused ' "$dropin"
assert_pilothouse_arguments "$dropin"

# A line-based match must not accept duplicate arguments on one ExecStart line.
duplicate_arguments="$scratch/duplicate-arguments.conf"
{
    printf '%s' 'ExecStart=/usr/bin/pilothoused'
    printf ' %s' "${pilothouse_arguments[@]}"
    printf ' %s\n' '--incus'
} >"$duplicate_arguments"
if assert_pilothouse_arguments "$duplicate_arguments" 2>/dev/null; then
    printf 'expected duplicate --incus arguments to be rejected\n' >&2
    exit 1
fi

unit_root="$scratch/root"
unit_dir="$unit_root/usr/lib/systemd/system"
mkdir -p "$unit_dir/pilothoused.service.d" "$unit_root/usr/bin"
cat >"$unit_dir/sysinit.target" <<'EOF'
[Unit]
Description=System Initialization
EOF
cat >"$unit_dir/pilothoused.service" <<'EOF'
[Unit]
Description=Pilothouse privileged broker

[Service]
Type=simple
ExecStart=/usr/bin/pilothoused --socket /run/pilothouse/broker.sock --socket-group pilothouse --admin-group sudo
EOF
cp "$dropin" "$unit_dir/pilothoused.service.d/10-snosi-backends.conf"
touch "$unit_root/usr/bin/pilothoused"
chmod +x "$unit_root/usr/bin/pilothoused"
systemd-analyze verify --root="$unit_root" pilothoused.service

# shellcheck source=/dev/null
source "$dependency_helper"

build_deb() {
    local name=$1 depends=$2 output=$3
    local root="$scratch/$name"
    mkdir -p "$root/DEBIAN"
    {
        printf 'Package: %s\nVersion: 1.0\nArchitecture: all\nMaintainer: Snosi Test <test@example.invalid>\nDescription: dependency fixture\n' "$name"
        if [[ -n "$depends" ]]; then
            printf 'Depends: %s\n' "$depends"
        fi
    } >"$root/DEBIAN/control"
    dpkg-deb --build "$root" "$output" >/dev/null
}

dpkg_version=$(dpkg-query -W -f='${Version}' dpkg)
build_deb no-dep '' "$scratch/no-dep.deb"
build_deb satisfied "dpkg (>= $dpkg_version) | snosi-never-installed" "$scratch/satisfied.deb"
build_deb unsatisfied 'snosi-deliberately-missing-dependency' "$scratch/unsatisfied.deb"

assert_deb_dependencies_satisfied "$scratch/no-dep.deb"
assert_deb_dependencies_satisfied "$scratch/satisfied.deb"
if assert_deb_dependencies_satisfied "$scratch/unsatisfied.deb"; then
    printf 'expected unsatisfied dependency expression to fail\n' >&2
    exit 1
fi

printf 'pilothouse-sysext-test: PASSED\n'
