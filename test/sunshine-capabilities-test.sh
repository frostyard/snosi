#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/sunshine-capabilities-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/shared/download" "$scratch/bin"
cp "$repo_root/mkosi.images/sunshine/mkosi.postinst.chroot" "$scratch/postinst"
cp "$repo_root/shared/download/deb-dependencies.sh" "$scratch/shared/download/"

# Fixture deb mirroring the upstream control shape: the bogus Qt5 pair that
# the postinst must strip, separated by the runs of spaces CMake's
# line-continuation leaves in the raw field, surrounded by dependencies the
# host satisfies (dpkg is installed wherever dpkg-deb is). The postinst's
# dependency assertion runs the real dpkg-checkbuilddeps against the
# rewritten deb.
build_deb() {
    local depends=$1 output=$2
    local root
    root=$(mktemp -d "$scratch/deb.XXXXXX")
    mkdir -p "$root/DEBIAN"
    printf 'Package: sunshine\nVersion: 1.0\nArchitecture: all\nMaintainer: Snosi Test <test@example.invalid>\nDescription: dependency fixture\nDepends: %s\n' \
        "$depends" >"$root/DEBIAN/control"
    # Upstream ships its postinst mode 0644; --nocheck lets the fixture carry
    # the same defect so the postinst's chmod-before-rebuild path is exercised
    # (dpkg-deb -b refuses a 0644 maintainer script).
    printf '#!/bin/sh\nexit 0\n' >"$root/DEBIAN/postinst"
    chmod 0644 "$root/DEBIAN/postinst"
    dpkg-deb --build --nocheck "$root" "$output" >/dev/null 2>&1
}
build_deb 'debianutils,             libqt5widgets5,             libqt5svg5, dpkg (>= 1.0)' "$scratch/bogus-qt5.deb"
build_deb 'debianutils, dpkg' "$scratch/fixed-upstream.deb"

cat >"$scratch/shared/download/verified-download.sh" <<'EOF'
verified_download() {
    cp "${SUNSHINE_FIXTURE_DEB:?}" "$2"
}
EOF
export SUNSHINE_FIXTURE_DEB="$scratch/bogus-qt5.deb"

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

# Fail closed once upstream drops the bogus Qt5 pair: the workaround must be
# removed deliberately, never silently no-op.
cat >"$scratch/bin/getcap" <<'EOF'
#!/bin/bash
printf '%s cap_sys_nice,cap_sys_admin=p\n' "$1"
EOF
chmod +x "$scratch/bin/getcap"
if SUNSHINE_FIXTURE_DEB="$scratch/fixed-upstream.deb" PATH="$scratch/bin:$PATH" SRCDIR="$scratch" \
    "$scratch/postinst" 2>"$scratch/fixed-upstream.err"; then
    printf 'expected Sunshine postinst to fail closed when the Qt5 Depends pair is absent\n' >&2
    exit 1
fi
if ! grep -q 'remove this workaround' "$scratch/fixed-upstream.err"; then
    printf 'expected the fail-closed Qt5 message, got:\n' >&2
    cat "$scratch/fixed-upstream.err" >&2
    exit 1
fi

printf 'sunshine-capabilities-test: PASSED\n'
