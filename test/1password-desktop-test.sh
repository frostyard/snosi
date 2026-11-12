#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$ROOT_DIR/mkosi.images/1password/desktop-entries.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
apps="$work/usr/share/applications"
resources="$work/usr/lib/1Password/resources"
mkdir -p "$apps" "$resources"
touch "$work/usr/lib/1Password/1password"
chmod +x "$work/usr/lib/1Password/1password"

for file in "$apps/1password.desktop" "$apps/com.onepassword.OnePassword.desktop" \
            "$apps/extra-1Password.desktop" "$resources/com.onepassword.OnePassword.desktop"; do
    printf '[Desktop Entry]\nExec=/opt/1Password/1password %%U\n' > "$file"
done
printf 'Exec=/opt/other/app\n' > "$apps/other.desktop"

if "$script" check "$work"; then
    echo 'FAIL: stale launchers passed validation' >&2; exit 1
fi
"$script" rewrite "$work"
"$script" check "$work"
for file in "$apps/1password.desktop" "$apps/com.onepassword.OnePassword.desktop" \
            "$apps/extra-1Password.desktop" "$resources/com.onepassword.OnePassword.desktop"; do
    grep -Fxq 'Exec=/usr/lib/1Password/1password %U' "$file"
done
grep -Fxq 'Exec=/opt/other/app' "$apps/other.desktop"
printf 'Exec=/opt/1Password/1password %%U\n' > "$resources/com.onepassword.OnePassword.desktop"
if "$script" check "$work"; then
    echo 'FAIL: stale resource entry passed validation' >&2; exit 1
fi
rm "$apps/com.onepassword.OnePassword.desktop"
if "$script" check "$work"; then
    echo 'FAIL: missing launcher passed validation' >&2; exit 1
fi
echo '1password-desktop-test: PASSED'
