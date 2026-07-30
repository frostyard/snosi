#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/sunshine-capabilities-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/shared/download" "$scratch/bin"
cp "$repo_root/mkosi.images/sunshine/mkosi.postinst.chroot" "$scratch/postinst"

cat >"$scratch/shared/download/verified-download.sh" <<'EOF'
verified_download() {
    :
}
EOF

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

printf 'sunshine-capabilities-test: PASSED\n'
