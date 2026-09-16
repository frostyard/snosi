#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/sunshine-capabilities-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/shared/download" "$scratch/bin"
cp "$repo_root/mkosi.images/sunshine/mkosi.postinst.chroot" "$scratch/postinst"
cp "$repo_root/shared/download/deb-dependencies.sh" "$scratch/shared/download/"

# Fixture debs mirroring the upstream control shape (runs of spaces between
# entries, as CMake's line-continuation leaves them in the raw field), using
# dependencies the host satisfies (dpkg is installed wherever dpkg-deb is) so
# the postinst's dependency assertion runs the real dpkg-checkbuilddeps. The
# upstream fixture stands in for v2026.914.233613+, whose Depends names Qt6
# only; the qt5 fixture replays the pre-v2026.914 control that the postinst
# used to strip and must now reject outright.
build_deb() {
    local depends=$1 output=$2
    local root
    root=$(mktemp -d "$scratch/deb.XXXXXX")
    mkdir -p "$root/DEBIAN"
    printf 'Package: sunshine\nVersion: 1.0\nArchitecture: all\nMaintainer: Snosi Test <test@example.invalid>\nDescription: dependency fixture\nDepends: %s\n' \
        "$depends" >"$root/DEBIAN/control"
    # Upstream ships its postinst mode 0644 (every release so far); --nocheck
    # lets the fixture carry the same defect, which dpkg -i tolerates.
    printf '#!/bin/sh\nexit 0\n' >"$root/DEBIAN/postinst"
    chmod 0644 "$root/DEBIAN/postinst"
    dpkg-deb --build --nocheck "$root" "$output" >/dev/null 2>&1
}
build_deb 'debianutils,             dpkg (>= 1.0)' "$scratch/upstream.deb"
build_deb 'debianutils,             libqt5widgets5,             libqt5svg5, dpkg (>= 1.0)' "$scratch/bogus-qt5.deb"

cat >"$scratch/shared/download/verified-download.sh" <<'EOF'
verified_download() {
    cp "${SUNSHINE_FIXTURE_DEB:?}" "$2"
}
EOF
export SUNSHINE_FIXTURE_DEB="$scratch/upstream.deb"

cat >"$scratch/bin/dpkg" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$scratch/bin/dpkg"

cat >"$scratch/bin/getcap" <<'EOF'
#!/bin/bash
printf '%s cap_sys_nice,cap_sys_admin=p\n' "$1"
EOF
chmod +x "$scratch/bin/getcap"

PATH="$scratch/bin:$PATH" SRCDIR="$scratch" "$scratch/postinst"

cat >"$scratch/bin/getcap" <<'EOF'
#!/bin/bash
printf '%s cap_sys_admin=p\n' "$1"
EOF
chmod +x "$scratch/bin/getcap"

if PATH="$scratch/bin:$PATH" SRCDIR="$scratch" "$scratch/postinst"; then
    printf 'expected Sunshine capability assertion to reject missing cap_sys_nice\n' >&2
    exit 1
fi

# Fail closed if upstream's Depends ever names Qt5 again: the binary links Qt6
# only, and dpkg would otherwise pull ~35 MB of dead Qt5 into the delta. The
# pre-v2026.914 strip-and-rebuild workaround is gone; do not reintroduce it.
cat >"$scratch/bin/getcap" <<'EOF'
#!/bin/bash
printf '%s cap_sys_nice,cap_sys_admin=p\n' "$1"
EOF
chmod +x "$scratch/bin/getcap"
if SUNSHINE_FIXTURE_DEB="$scratch/bogus-qt5.deb" PATH="$scratch/bin:$PATH" SRCDIR="$scratch" \
    "$scratch/postinst" 2>"$scratch/bogus-qt5.err"; then
    printf 'expected Sunshine postinst to fail closed when Depends references Qt5\n' >&2
    exit 1
fi
if ! grep -q 'references Qt5 again' "$scratch/bogus-qt5.err"; then
    printf 'expected the fail-closed Qt5 message, got:\n' >&2
    cat "$scratch/bogus-qt5.err" >&2
    exit 1
fi

# The dependency assertion still runs against the pristine deb: an unsatisfied
# Depends must fail before dpkg -i rather than being papered over.
build_deb 'debianutils, snosi-nonexistent-package-fixture' "$scratch/unsatisfied.deb"
if SUNSHINE_FIXTURE_DEB="$scratch/unsatisfied.deb" PATH="$scratch/bin:$PATH" SRCDIR="$scratch" \
    "$scratch/postinst" 2>"$scratch/unsatisfied.err"; then
    printf 'expected Sunshine postinst to fail closed on an unsatisfied Depends\n' >&2
    exit 1
fi
if ! grep -q 'not satisfied by the buildroot' "$scratch/unsatisfied.err"; then
    printf 'expected the unsatisfied-dependency message, got:\n' >&2
    cat "$scratch/unsatisfied.err" >&2
    exit 1
fi

printf 'sunshine-capabilities-test: PASSED\n'
