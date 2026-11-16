#!/bin/bash
# Fixture suite for the product-Mesa strip finalizer (#1318):
#  - shared/sysext/finalize/sysext-strip-product-mesa.sh behavior: a delta
#    carrying the trixie Mesa runtime loses it, a clean delta passes
#    unchanged, an empty pattern list and a missing delta /usr fail
#  - the real shared/sysext/product-mesa-paths.txt covers every 25.0.7
#    runtime path dev and incus shipped, and keeps the Mesa consumers
#    (libglvnd, libvulkan.so.1, libdrm, headers, the unsuffixed libgbm.so)
#  - precondition: every product pins the Mesa runtime from
#    trixie-backports, for both suites, in the kernel fragment its profile
#    includes. Without it the strip would leave that product with no Mesa.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/shared/sysext/finalize/sysext-strip-product-mesa.sh"
paths="$root/shared/sysext/product-mesa-paths.txt"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

test_number=0
failures=0
ok() {
    test_number=$((test_number + 1))
    echo "ok $test_number - $1"
}
fail() {
    test_number=$((test_number + 1))
    failures=$((failures + 1))
    echo "not ok $test_number - $1"
    if [[ -n ${2:-} ]]; then
        while IFS= read -r line; do echo "#   $line"; done <<<"$2"
    fi
}

# The script resolves the list as $SRCDIR/shared/sysext/...; build a fake
# SRCDIR per case so a test never depends on (or mutates) the real file.
make_srcdir() { # name [list-content] -> path
    local d="$work/$1/src"
    mkdir -p "$d/shared/sysext"
    if (($# > 1)); then
        printf '%s\n' "$2" >"$d/shared/sysext/product-mesa-paths.txt"
    else
        cp "$paths" "$d/shared/sysext/product-mesa-paths.txt"
    fi
    mkdir -p "$d/shared/sysext/finalize"
    echo "$d"
}
make_delta() { # name -> path (empty /usr skeleton)
    local d="$work/$1/delta"
    mkdir -p "$d/usr/lib/x86_64-linux-gnu" "$d/usr/include/EGL"
    echo "$d"
}
run_strip() { # delta srcdir
    BUILDROOT="$1" SRCDIR="$2" IMAGE_ID=testext "$script" 2>&1
}

# The trixie 25.0.7 Mesa runtime files dev and incus carried in their deltas
# (relative to the delta's /usr), by package.
mesa_25=( \
    lib/x86_64-linux-gnu/libgallium-25.0.7-2+deb13u1.so \
    lib/x86_64-linux-gnu/libgbm.so.1 \
    lib/x86_64-linux-gnu/libgbm.so.1.0.0 \
    lib/x86_64-linux-gnu/gbm/dri_gbm.so \
    lib/x86_64-linux-gnu/libEGL_mesa.so.0 \
    lib/x86_64-linux-gnu/libEGL_mesa.so.0.0.0 \
    share/glvnd/egl_vendor.d/50_mesa.json \
    lib/x86_64-linux-gnu/dri/libdril_dri.so \
    lib/x86_64-linux-gnu/dri/swrast_dri.so \
    share/drirc.d/00-mesa-defaults.conf \
    lib/x86_64-linux-gnu/libGLX_mesa.so.0 \
    lib/x86_64-linux-gnu/libGLX_mesa.so.0.0.0 \
    lib/x86_64-linux-gnu/libGLX_indirect.so.0 \
)
# Mesa consumers and loaders a sysext legitimately ships: they stay.
keep_paths=( \
    lib/x86_64-linux-gnu/libfoo.so.1 \
    lib/x86_64-linux-gnu/libgbm.so \
    lib/x86_64-linux-gnu/libEGL.so.1 \
    include/EGL/eglmesaext.h \
)

# populate_mesa_delta <delta>: every 25.0.7 Mesa path (symlinks where apt
# ships a symlink) plus the kept paths.
populate_mesa_delta() {
    local delta=$1 p
    for p in "${mesa_25[@]}"; do
        mkdir -p "$delta/usr/$(dirname -- "$p")"
        case "$p" in
            */libgbm.so.1) touch "$delta/usr/lib/x86_64-linux-gnu/libgbm.so.1.0.0" ;;
            */libEGL_mesa.so.0) touch "$delta/usr/lib/x86_64-linux-gnu/libEGL_mesa.so.0.0.0" ;;
            */libGLX_mesa.so.0) touch "$delta/usr/lib/x86_64-linux-gnu/libGLX_mesa.so.0.0.0" ;;
            */dri/swrast_dri.so) touch "$delta/usr/lib/x86_64-linux-gnu/dri/libdril_dri.so" ;;
        esac
        touch "$delta/usr/$p"
    done
    # apt's DRI symlinks point at libdril_dri.so
    rm -f "$delta/usr/lib/x86_64-linux-gnu/dri/swrast_dri.so"
    ln -s libdril_dri.so "$delta/usr/lib/x86_64-linux-gnu/dri/swrast_dri.so"
    for p in "${keep_paths[@]}"; do
        mkdir -p "$delta/usr/$(dirname -- "$p")"
        touch "$delta/usr/$p"
    done
    # the development symlinks apt ships next to the versioned libs
    ln -sfn libgbm.so.1.0.0 "$delta/usr/lib/x86_64-linux-gnu/libgbm.so.1"
    ln -sfn libgbm.so.1 "$delta/usr/lib/x86_64-linux-gnu/libgbm.so"
    ln -sfn libEGL_mesa.so.0.0.0 "$delta/usr/lib/x86_64-linux-gnu/libEGL_mesa.so.0"
    ln -sfn libGLX_mesa.so.0.0.0 "$delta/usr/lib/x86_64-linux-gnu/libGLX_mesa.so.0"
}

# --- case a: a delta with the trixie Mesa runtime loses every Mesa path ---
src=$(make_srcdir full)
delta=$(make_delta full)
populate_mesa_delta "$delta"
if out=$(run_strip "$delta" "$src"); then
    missing=()
    for p in "${mesa_25[@]}"; do
        [[ -e "$delta/usr/$p" || -L "$delta/usr/$p" ]] && missing+=("/usr/$p")
    done
    app_dirs=()
    for p in lib/x86_64-linux-gnu/dri lib/x86_64-linux-gnu/gbm; do
        [[ -d "$delta/usr/$p" ]] && app_dirs+=("/usr/$p")
    done
    if ((${#missing[@]} == 0)); then
        ok "every trixie Mesa 25.0.7 runtime path is removed from the delta"
    else
        fail "every trixie Mesa 25.0.7 runtime path is removed" "still present: ${missing[*]}"
    fi
    if ((${#app_dirs[@]} == 0)); then
        ok "the emptied dri/ and gbm/ directories are removed"
    else
        fail "the emptied dri/ and gbm/ directories are removed" "still present: ${app_dirs[*]}"
    fi
    kept=()
    for p in "${keep_paths[@]}"; do
        [[ -e "$delta/usr/$p" || -L "$delta/usr/$p" ]] || kept+=("/usr/$p")
    done
    if ((${#kept[@]} == 0)); then
        ok "the Mesa consumers and headers are kept (libfoo.so.1, libgbm.so, libEGL.so.1, eglmesaext.h)"
    else
        fail "the Mesa consumers and headers are kept" "removed: ${kept[*]}"
    fi
    if [[ $out == *"delta stripped of"* ]]; then
        ok "the summary line reports the strip"
    else
        fail "the summary line reports the strip" "$out"
    fi
else
    fail "a delta with the trixie Mesa runtime is stripped" "$out"
fi

# --- case b: a clean delta passes and is unchanged ------------------------
src=$(make_srcdir clean)
delta=$(make_delta clean)
touch "$delta/usr/lib/x86_64-linux-gnu/libfoo.so.1" \
    "$delta/usr/include/EGL/eglmesaext.h"
before=$(cd "$delta" && find . | LC_ALL=C sort)
if out=$(run_strip "$delta" "$src"); then
    after=$(cd "$delta" && find . | LC_ALL=C sort)
    if [[ $before == "$after" ]]; then
        ok "a clean delta passes and changes nothing"
    else
        fail "a clean delta passes and changes nothing" "$out"
    fi
else
    fail "a clean delta passes" "$out"
fi

# --- case c: an empty pattern list fails rather than passing vacuously ----
src=$(make_srcdir empty '# only comments

# here')
delta=$(make_delta empty)
if out=$(run_strip "$delta" "$src"); then
    fail "a pattern-free path list fails" "$out"
elif [[ $out == *vacuously* ]]; then
    ok "a pattern-free path list refuses to pass vacuously"
else
    fail "a pattern-free path list error message" "$out"
fi

# --- case c2: a missing path list fails, a missing delta /usr fails -------
delta=$(make_delta nolist)
if out=$(BUILDROOT="$delta" SRCDIR="$work/nolist/does-not-exist" IMAGE_ID=testext "$script" 2>&1); then
    fail "a missing path list fails" "$out"
elif [[ $out == *"not found"* ]]; then
    ok "a missing path list fails"
else
    fail "a missing path list error message" "$out"
fi
mkdir -p "$work/nousr/delta"
if out=$(BUILDROOT="$work/nousr/delta" SRCDIR="$src" IMAGE_ID=testext "$script" 2>&1); then
    fail "a delta without /usr fails" "$out"
elif [[ $out == *"no /usr"* ]]; then
    ok "a delta without /usr fails"
else
    fail "a delta without /usr error message" "$out"
fi

# --- case d: the REAL list covers every shipped 25.0.7 path and keeps the
# Mesa consumers the products and sysexts still need ----------------------
delta=$(make_delta real)
populate_mesa_delta "$delta"
# The vulkan side of the same family, and the loaders/libraries to keep.
for p in \
    lib/x86_64-linux-gnu/libvulkan_lvp.so \
    lib/x86_64-linux-gnu/libVkLayer_MESA_device_select.so \
    share/vulkan/icd.d/lvp_icd.x86_64.json \
    share/vulkan/implicit_layer.d/VkLayer_MESA_device_select.json; do
    mkdir -p "$delta/usr/$(dirname -- "$p")"
    touch "$delta/usr/$p"
done
for p in \
    lib/x86_64-linux-gnu/libvulkan.so.1 \
    lib/x86_64-linux-gnu/libdrm.so.2 \
    lib/x86_64-linux-gnu/libLLVM-19.so.1 \
    lib/x86_64-linux-gnu/libGLESv2.so.2; do
    mkdir -p "$delta/usr/$(dirname -- "$p")"
    touch "$delta/usr/$p"
done
if out=$(run_strip "$delta" "$root"); then
    missing=()
    for p in "${mesa_25[@]}" \
        lib/x86_64-linux-gnu/libvulkan_lvp.so \
        lib/x86_64-linux-gnu/libVkLayer_MESA_device_select.so \
        share/vulkan/icd.d/lvp_icd.x86_64.json \
        share/vulkan/implicit_layer.d/VkLayer_MESA_device_select.json; do
        [[ -e "$delta/usr/$p" || -L "$delta/usr/$p" ]] && missing+=("/usr/$p")
    done
    if ((${#missing[@]} == 0)); then
        ok "the real product-mesa-paths.txt matches every shipped Mesa runtime path"
    else
        fail "the real product-mesa-paths.txt matches every shipped Mesa runtime path" "still present: ${missing[*]}"
    fi
    kept=()
    for p in "${keep_paths[@]}" \
        lib/x86_64-linux-gnu/libvulkan.so.1 \
        lib/x86_64-linux-gnu/libdrm.so.2 \
        lib/x86_64-linux-gnu/libLLVM-19.so.1 \
        lib/x86_64-linux-gnu/libGLESv2.so.2; do
        [[ -e "$delta/usr/$p" || -L "$delta/usr/$p" ]] || kept+=("/usr/$p")
    done
    if ((${#kept[@]} == 0)); then
        ok "the real list keeps libvulkan.so.1, libdrm, libllvm and libGLESv2"
    else
        fail "the real list keeps libvulkan.so.1, libdrm, libllvm and libGLESv2" "removed: ${kept[*]}"
    fi
else
    fail "the real path list strips a delta" "$out"
fi

# --- case e: every product pins its own Mesa runtime (the strip's premise) -
mesa_packages=(libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium)
for product in snow snowfield floe sundog; do
    profile="$root/mkosi.profiles/$product/mkosi.conf"
    fragment=no
    suite_files=()
    while IFS= read -r include; do
        include=${include#Include=}
        include=${include#%D/}
        case "$include" in
            shared/kernel/backports/mkosi.conf | shared/kernel/surface/mkosi.conf)
                fragment=$include
                while IFS= read -r inner; do
                    inner=${inner#Include=}
                    inner=${inner#%D/}
                    suite_files+=("$root/$inner")
                done < <(grep -E '^[[:space:]]*Include[[:space:]]*=' "$root/$include")
                ;;
        esac
    done < <(grep -E '^[[:space:]]*Include[[:space:]]*=' "$profile")
    if [[ $fragment == no ]]; then
        fail "$product includes a kernel fragment that pins Mesa"
        continue
    fi
    if ((${#suite_files[@]} == 0)); then
        fail "$product's kernel fragment ($fragment) includes suite files"
        continue
    fi
    for suite_file in "${suite_files[@]}"; do
        for pkg in "${mesa_packages[@]}"; do
            if grep -Eq "^[[:space:]]*$pkg(/[[:alnum:]-]+)?[[:space:]]*\$" "$suite_file"; then
                ok "$product: ${suite_file#"$root/"} lists $pkg"
            else
                fail "$product: ${suite_file#"$root/"} lists $pkg"
            fi
        done
    done
done

echo
echo "# Results: $((test_number - failures)) passed, $failures failed, $test_number total"
((failures == 0))
