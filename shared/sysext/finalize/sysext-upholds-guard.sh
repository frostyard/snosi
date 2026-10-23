#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared finalize script for every sysext: fail the build if a target drop-in
# in the delta (usr/lib/systemd/system/*.target.d/*.conf) has an Upholds=
# line for a unit that carries a Condition*= and is not a
# Type=oneshot + RemainAfterExit=yes unit.
#
# Why (snosi#1100, #1113): systemd retries an upheld unit whose condition
# fails, forever (k3s logged 93,566 journal lines on one host).
# check-upholds-guard.sh covers units the repository defines; it skips targets
# with no definition in the repo, which are the package-shipped units
# (tailscaled.service, docker.socket, ...). Only a build that has the
# unpacked package can see those, so this finalizer checks them on the delta.
#
# Resolution: each Upholds= target is looked up in the delta first, then in
# the base tree. FinalizeScripts run after mkosi unmounts the BaseTrees
# overlay, so $BUILDROOT is the delta only, and mkosi has already dropped from
# the delta every /usr path the base also ships: a unit shipped by base is
# never in the delta. The base tree is not mounted here, so it is located on
# the host: the first BaseTrees= entry of $MKOSI_CONFIG, mapped under $SRCDIR
# (the repository root, mounted at /work/src) through the non-targeted
# BuildSources= entry that holds it; without that, $SRCDIR/output/base.
# $SNOSI_SYSEXT_BASE_TREE overrides all of this (tests).
#
# Resolution rules: an instance (name@inst.service) without its own file uses
# the template (name@.service); a symlink to /dev/null is a mask and fails; any
# other symlink is an alias whose basename is resolved again (8 hops at most);
# a target with no unit file and no drop-in is a typo and fails. Drop-ins come
# from the delta and the base tree; the same basename in the delta wins; the
# order is by basename, after the main unit (last assignment wins).
#
# Escape hatch (same as check-upholds-guard.sh): a comment line
# `# upholds-guard-allow: <reason>` IMMEDIATELY above the Condition*= line
# exempts that line. It must be its own line: systemd has no inline comments.
set -euo pipefail

ID=${IMAGE_ID:-sysext}
UNITS=usr/lib/systemd/system
DELTA=${BUILDROOT:?sysext-upholds-guard: BUILDROOT not set}
SRC=${SRCDIR:-}

die() {
    echo "sysext-upholds-guard: $*" >&2
    exit 1
}

# --- locate the base tree ---------------------------------------------------
base=""
if [[ -n ${SNOSI_SYSEXT_BASE_TREE:-} ]]; then
    base=$SNOSI_SYSEXT_BASE_TREE
elif [[ -n ${MKOSI_CONFIG:-} && -f ${MKOSI_CONFIG} ]]; then
    command -v jq >/dev/null || die "jq is required to read \$MKOSI_CONFIG ($MKOSI_CONFIG)"
    host_base=$(jq -r '(.BaseTrees // [])[0] // "" | if type == "object" then (.Source // "") else . end' "$MKOSI_CONFIG")
    if [[ -n $host_base && -n $SRC ]]; then
        while IFS= read -r source; do
            [[ -n $source ]] || continue
            source=${source%/}
            if [[ $host_base == "$source" ]]; then
                base=$SRC
                break
            elif [[ $host_base == "$source"/* ]]; then
                base=$SRC/${host_base#"$source"/}
                break
            fi
        done < <(jq -r '(.BuildSources // [])[] | select(.Target == null) | .Source' "$MKOSI_CONFIG")
    fi
fi
if [[ -z $base ]]; then
    [[ -n $SRC ]] || die "cannot locate the base tree: SRCDIR is not set"
    base=$SRC/output/base
fi
[[ -d $base ]] || die "base tree $base is not a directory; refusing to pass vacuously (is the base image built to \$SRCDIR/output/base?)"
[[ -d $DELTA ]] || die "delta buildroot $DELTA is not a directory"

# --- helpers ----------------------------------------------------------------
label() { # absolute path -> delta:rel / base:rel
    case "$1" in
        "$DELTA"/*) printf 'delta:%s' "${1#"$DELTA"/}" ;;
        "$base"/*) printf 'base:%s' "${1#"$base"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

exists() { [[ -e $1 || -L $1 ]]; }

lookup() { # unit name -> path of the delta file, else the base file
    local p
    for p in "$DELTA/$UNITS/$1" "$base/$UNITS/$1"; do
        if exists "$p"; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

template_of() { # name@inst.suffix -> name@.suffix (fails when not an instance)
    [[ $1 =~ ^([^@]+)@(.+)\.([A-Za-z]+)$ ]] || return 1
    printf '%s@.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
}

# Follow drop-in symlinks inside the trees; print the readable file or nothing
# (nothing for /dev/null masks and dangling links).
content_path() {
    local p=$1 hops=0 t cand
    while [[ -L $p ]]; do
        hops=$((hops + 1))
        ((hops <= 8)) || return 0
        t=$(readlink "$p")
        [[ $t != /dev/null ]] || return 0
        if [[ $t == /* ]]; then
            cand=""
            if exists "$DELTA$t"; then cand=$DELTA$t; elif exists "$base$t"; then cand=$base$t; fi
            [[ -n $cand ]] || return 0
            p=$cand
        else
            p=$(dirname "$p")/$t
        fi
    done
    [[ -f $p ]] && printf '%s' "$p"
    return 0
}

truthy() {
    case "${1,,}" in yes | true | on | 1) return 0 ;; *) return 1 ;; esac
}

last_value() { # key file... -> last assignment (empty when none)
    local key=$1 v="" file line
    shift
    for file in "$@"; do
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line =~ ^[[:space:]]*${key}=(.*)$ ]]; then
                v=${BASH_REMATCH[1]}
            fi
        done <"$file"
    done
    printf '%s' "$v"
}

# --- collect Upholds= from delta target drop-ins ----------------------------
shopt -s nullglob
declare -A seen=()
targets=()
origins=()
for f in "$DELTA/$UNITS"/*.target.d/*.conf; do
    [[ -f $f ]] || continue
    flabel=$(label "$f")
    n=0
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        [[ $line =~ ^[[:space:]]*Upholds=(.*)$ ]] || continue
        read -r -a vals <<<"${BASH_REMATCH[1]}"
        for t in "${vals[@]}"; do
            [[ -z ${seen[$t]:-} ]] || continue
            seen[$t]=1
            targets+=("$t")
            origins+=("$flabel:$n")
        done
    done <"$f"
done

# --- check each target -------------------------------------------------------
fail=0
violation() {
    printf 'sysext-upholds-guard: %s\n' "$*" >&2
    fail=1
}

for i in "${!targets[@]}"; do
    t=${targets[$i]}
    origin=${origins[$i]}

    # Resolve the main unit through templates, masks and aliases.
    names=("$t")
    main=""
    name=$t
    hops=0
    state=ok
    while :; do
        if p=$(lookup "$name"); then
            :
        elif tmpl=$(template_of "$name") && p=$(lookup "$tmpl"); then
            names+=("$tmpl")
        else
            p=""
        fi
        if [[ -z $p ]]; then
            [[ $hops -eq 0 ]] || state="alias-dangling:$name"
            break
        fi
        if [[ -L $p ]]; then
            target=$(readlink "$p")
            if [[ $target == /dev/null ]]; then
                state="masked:$p"
                break
            fi
            hops=$((hops + 1))
            if ((hops > 8)); then
                state="alias-loop:$p"
                break
            fi
            name=${target##*/}
            names+=("$name")
            continue
        fi
        main=$p
        break
    done

    case "$state" in
        masked:*)
            violation "$origin: $t is upheld but masked ($(label "${state#masked:}") -> /dev/null): upholding a masked unit never starts it; drop the Upholds= or the mask"
            continue
            ;;
        alias-loop:*)
            violation "$origin: $t is upheld but its alias chain ($(label "${state#alias-loop:}")) is longer than 8 hops"
            continue
            ;;
        alias-dangling:*)
            violation "$origin: $t is upheld but its alias points to ${state#alias-dangling:}, which has no unit file in the delta or the base tree"
            continue
            ;;
    esac

    # Drop-ins: per name (instance, template, alias), delta before base; the
    # first file with a given basename wins.
    declare -A dseen=()
    dropins=()
    for n in "${names[@]}"; do
        dnames=("$n")
        if tm=$(template_of "$n"); then dnames+=("$tm"); fi
        for dn in "${dnames[@]}"; do
            for tree in "$DELTA" "$base"; do
                for d in "$tree/$UNITS/$dn.d"/*.conf; do
                    exists "$d" || continue
                    b=${d##*/}
                    [[ -z ${dseen[$b]:-} ]] || continue
                    dseen[$b]=1
                    dropins+=("$d")
                done
            done
        done
    done
    unset dseen
    if ((${#dropins[@]} > 1)); then
        mapfile -t dropins < <(
            for d in "${dropins[@]}"; do
                printf '%s\t%s\n' "${d##*/}" "$d"
            done | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 | cut -f2-
        )
    fi

    ordered=()
    [[ -z $main ]] || ordered+=("$main")
    ordered+=("${dropins[@]}")
    if ((${#ordered[@]} == 0)); then
        violation "$origin: $t is upheld but has no unit file or drop-in in the delta or the base tree (typo? the package may not ship it)"
        continue
    fi

    # Condition lines not exempted by an allow comment directly above.
    cond_file=""
    cond_n=0
    cond_line=""
    contents=()
    for f in "${ordered[@]}"; do
        c=$(content_path "$f")
        [[ -n $c ]] || continue
        contents+=("$c")
        n=0
        prev=""
        while IFS= read -r line || [[ -n $line ]]; do
            n=$((n + 1))
            if [[ -z $cond_file && $line =~ ^[[:space:]]*Condition[A-Za-z]+= ]] &&
                ! [[ $prev =~ ^[[:space:]]*#[[:space:]]*upholds-guard-allow: ]]; then
                cond_file=$f
                cond_n=$n
                cond_line=$line
            fi
            prev=$line
        done <"$c"
    done
    [[ -n $cond_file ]] || continue

    type=$(last_value Type "${contents[@]}")
    rae=$(last_value RemainAfterExit "${contents[@]}")
    if [[ ${type,,} == oneshot ]] && truthy "$rae"; then
        continue
    fi

    violation "$(label "$cond_file"):$cond_n: $t is upheld by $origin but has a condition ($cond_line): an upheld unit whose condition fails is retried forever (snosi#1100); uphold a RemainAfterExit=yes oneshot that Wants= the unit (the himmelblau/k3s pattern)"
done

if ((fail != 0)); then
    echo >&2
    echo "sysext-upholds-guard: $ID has violations. See docs/design/sysexts.md \"Service Activation Pattern (Upholds=)\"." >&2
    exit 1
fi
echo "sysext-upholds-guard: $ID OK (${#targets[@]} upheld units checked)"
