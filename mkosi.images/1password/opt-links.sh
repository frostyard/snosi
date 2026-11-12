#!/bin/bash
# Re-point and validate the absolute /opt/1Password symlinks the 1Password deb
# postinst creates. The relocation to /usr/lib/1Password moves the directory
# but leaves those links dangling (frostyard/snosi#1279).
set -euo pipefail

mode=${1:?expected rewrite or check}
root=${2:?expected build root}
# "/" and "<buildroot>/" are both a plain prefix once the trailing slash is
# gone, so every path below is "$root/usr/...".
root=${root%/}

case "$mode" in
    rewrite|check) ;;
    *) echo "Unknown mode: $mode" >&2; exit 1 ;;
esac

old=/opt/1Password
relocated=/usr/lib/1Password
max_hops=40

# Print, NUL separated, every symlink under ROOT/usr.
find_links() {
    [[ -d "$root/usr" ]] || return 0
    find "$root/usr" -type l -print0
}

# Succeed only when LINK, a symlink, resolves to an existing path inside ROOT.
# Resolution stays inside ROOT, never on the host: an absolute target is
# re-anchored at ROOT, a relative one is joined to the link's directory.
resolves_in_root() {
    local link="$1" target hops=0
    while (( hops++ < max_hops )); do
        target=$(readlink -- "$link") || return 1
        if [[ "$target" == /* ]]; then
            target="$root$target"
        else
            target="$(dirname -- "$link")/$target"
        fi
        if [[ ! -L "$target" ]]; then
            [[ -e "$target" ]] && return 0
            return 1
        fi
        link="$target"
    done
    return 1
}

do_check() {
    local link target bad=0
    while IFS= read -r -d '' link; do
        target=$(readlink -- "$link") || continue
        if [[ "$target" == "$old" || "$target" == "$old"/* ]]; then
            echo "1password: ${link#"$root"} still points at $old" >&2
            bad=1
        fi
    done < <(find_links)

    while IFS= read -r -d '' link; do
        if ! resolves_in_root "$link"; then
            echo "1password: ${link#"$root"} does not resolve inside the image" >&2
            bad=1
        fi
    done < <( [[ -d "$root$relocated" ]] && find "$root$relocated" -type l -print0 )

    while IFS= read -r -d '' link; do
        target=$(readlink -- "$link") || continue
        [[ "$target" == *1Password/* ]] || continue
        if ! resolves_in_root "$link"; then
            echo "1password: ${link#"$root"} does not resolve inside the image (target $target)" >&2
            bad=1
        fi
    done < <( [[ -d "$root/usr/bin" ]] && find "$root/usr/bin" -maxdepth 1 -type l -print0 )

    (( bad == 0 ))
}

if [[ "$mode" == rewrite ]]; then
    while IFS= read -r -d '' link; do
        target=$(readlink -- "$link") || continue
        if [[ "$target" == "$old" || "$target" == "$old"/* ]]; then
            ln -sfn -- "$relocated${target#"$old"}" "$link"
        fi
    done < <(find_links)
fi

do_check
