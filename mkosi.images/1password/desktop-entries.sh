#!/bin/bash
# Rewrite and validate the desktop entries shipped by the 1Password deb.
set -euo pipefail

mode=${1:?expected rewrite or check}
root=${2:?expected build root}
apps="$root/usr/share/applications"
resources="$root/usr/lib/1Password/resources"

case "$mode" in
    rewrite|check) ;;
    *) echo "Unknown mode: $mode" >&2; exit 1 ;;
esac

entries=()
if [[ -d "$apps" ]]; then
    while IFS= read -r -d '' file; do entries+=("$file"); done < <(
        find "$apps" -maxdepth 1 -type f \( -iname '*1password*.desktop' -o -iname '*onepassword*.desktop' \) -print0
    )
fi
if [[ -d "$resources" ]]; then
    while IFS= read -r -d '' file; do entries+=("$file"); done < <(
        find "$resources" -type f -iname '*.desktop' -print0
    )
fi

if [[ "$mode" == rewrite ]]; then
    for file in "${entries[@]}"; do
        sed -i 's|/opt/1Password|/usr/lib/1Password|g' "$file"
    done
fi

for name in 1password.desktop com.onepassword.OnePassword.desktop; do
    file="$apps/$name"
    if [[ ! -f "$file" ]] || ! grep -Eq '^Exec=/usr/lib/1Password/1password([[:space:]]|$)' "$file"; then
        echo "1password: missing or invalid launcher: $file" >&2
        exit 1
    fi
done
if [[ ! -x "$root/usr/lib/1Password/1password" ]]; then
    echo "1password: relocated executable is missing or not executable" >&2
    exit 1
fi
for file in "${entries[@]}"; do
    if grep -Fq '/opt/1Password' "$file"; then
        echo "1password: stale /opt path in $file" >&2
        exit 1
    fi
done
