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

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Write every symlink under DIR to OUT, NUL separated. A find that fails (an
# unreadable subdirectory, say) would make a partial scan look complete, so
# run it as a plain command: its exit status is never lost in a pipeline or a
# process substitution.
scan_links() {
    local dir="$1" out="$2"
    shift 2
    : > "$out"
    [[ -d "$dir" ]] || return 0
    if ! find "$dir" "$@" -type l -print0 > "$out"; then
        echo "1password: cannot scan $dir for symlinks; the scan is incomplete" >&2
        return 1
    fi
}

# Succeed only when LINK resolves to an existing path inside ROOT. Resolution
# stays inside ROOT, never on the host: walk the components one at a time from
# ROOT, follow any symlink met on the way (an absolute target restarts at ROOT,
# a relative one continues from that component's parent), and let ".." never
# climb above ROOT. realpath, readlink -f, cd and a bare -e on a path that
# still holds an unresolved symlink would all consult the host.
resolves_in_root() {
    local link="$1" cur="" comp target hops=0
    local -a pending=() add=()
    local rest remaining p

    rest=${link#"$root"}
    IFS=/ read -r -a pending <<< "$rest"

    while (( ${#pending[@]} > 0 )); do
        comp=${pending[0]}
        pending=("${pending[@]:1}")

        case "$comp" in
            ''|.) continue ;;
            ..)
                # Drop the last resolved component, never going above ROOT.
                cur=${cur%/*}
                continue
                ;;
        esac

        if [[ -L "$root$cur/$comp" ]]; then
            hops=$((hops + 1))
            if (( hops > max_hops )); then
                return 1
            fi
            target=$(readlink -- "$root$cur/$comp") || return 1
            IFS=/ read -r -a add <<< "$target"
            pending=("${add[@]}" "${pending[@]}")
            if [[ "$target" == /* ]]; then
                cur=""
            fi
            # A relative target continues from the parent, which is $cur.
            continue
        fi

        # A component that is followed by another one must be a directory.
        remaining=0
        for p in "${pending[@]}"; do
            case "$p" in ''|.) continue ;; esac
            remaining=1
            break
        done
        if (( remaining )) && [[ -e "$root$cur/$comp" && ! -d "$root$cur/$comp" ]]; then
            return 1
        fi
        cur="$cur/$comp"
    done

    [[ -e "$root$cur" ]]
}

do_check() {
    local link target bad=0 scanned=0 resolved=0
    local all="$tmpdir/usr.links" lib="$tmpdir/lib.links" bin="$tmpdir/bin.links"

    scan_links "$root/usr" "$all" || exit 1
    while IFS= read -r -d '' link; do
        scanned=$((scanned + 1))
        target=$(readlink -- "$link") || continue
        if [[ "$target" == "$old" || "$target" == "$old"/* ]]; then
            echo "1password: ${link#"$root"} still points at $old" >&2
            bad=1
        fi
    done < "$all"

    scan_links "$root$relocated" "$lib" || exit 1
    while IFS= read -r -d '' link; do
        resolved=$((resolved + 1))
        if ! resolves_in_root "$link"; then
            echo "1password: ${link#"$root"} does not resolve inside the image" >&2
            bad=1
        fi
    done < "$lib"

    scan_links "$root/usr/bin" "$bin" -maxdepth 1 || exit 1
    while IFS= read -r -d '' link; do
        target=$(readlink -- "$link") || continue
        [[ "$target" == *1Password/* ]] || continue
        resolved=$((resolved + 1))
        if ! resolves_in_root "$link"; then
            echo "1password: ${link#"$root"} does not resolve inside the image (target $target)" >&2
            bad=1
        fi
    done < "$bin"

    echo "1password: opt-links $mode: $scanned links under /usr scanned for $old, $resolved 1Password links resolved"
    # /usr/bin/1password always exists: no link at all means a wrong ROOT,
    # and a check over nothing proves nothing.
    if (( resolved == 0 )); then
        echo "1password: no 1Password link found under $root/usr" >&2
        bad=1
    fi
    (( bad == 0 ))
}

if [[ "$mode" == rewrite ]]; then
    all="$tmpdir/rewrite.links"
    scan_links "$root/usr" "$all" || exit 1
    while IFS= read -r -d '' link; do
        target=$(readlink -- "$link") || continue
        if [[ "$target" == "$old" || "$target" == "$old"/* ]]; then
            ln -sfn -- "$relocated${target#"$old"}" "$link"
        fi
    done < "$all"
fi

do_check
