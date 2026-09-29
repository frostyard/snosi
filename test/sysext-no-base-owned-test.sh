#!/bin/bash
# Fixture suite for the base-owned-paths sysext guard (#1011, #1015):
#  - shared/sysext/finalize/sysext-no-base-owned.sh behavior (a delta
#    shipping a base-owned VM-runtime path fails the build; a clean delta
#    and the incus bundle under /usr/incus pass; an empty or missing list
#    fails rather than passing vacuously)
#  - the real list covers the base VM runtime, and base still ships it
#  - wiring: every sysext runs the guard (also enforced by
#    test/sysext-authoring-contract-test.sh's required-finalizer set)
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/shared/sysext/finalize/sysext-no-base-owned.sh"
paths="$root/shared/sysext/base-owned-paths.txt"
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
    if [[ -n ${2:-} ]]; then sed "s/^/#   /" <<<"$2"; fi
}
# The guard names the path its glob matched, which for a trailing dir glob is
# the direct child (share/qemu/* reports /usr/share/qemu/firmware for a file
# below it). Accept any reported offender that is /usr/$1 or a parent of it.
names_path() { # rel output
    local line
    while IFS= read -r line; do
        line=${line#"  "}
        [[ $line == /usr/* ]] || continue
        if [[ "/usr/$1" == "$line" || "/usr/$1" == "$line"/* ]]; then return 0; fi
    done <<<"$2"
    return 1
}

# The script resolves the list as $SRCDIR/shared/sysext/...; build a fake
# SRCDIR per case that carries the REAL list unless a case overrides it.
make_srcdir() { # name [list-content] -> path
    local d="$work/$1/src"
    mkdir -p "$d/shared/sysext"
    if (($# > 1)); then
        printf '%s\n' "$2" >"$d/shared/sysext/base-owned-paths.txt"
    else
        cp "$paths" "$d/shared/sysext/base-owned-paths.txt"
    fi
    echo "$d"
}
make_delta() { # name -> path (empty /usr skeleton)
    local d="$work/$1/delta"
    mkdir -p "$d/usr/bin" "$d/usr/lib/x86_64-linux-gnu" "$d/usr/share"
    echo "$d"
}
run_guard() { # delta srcdir
    BUILDROOT="$1" SRCDIR="$2" IMAGE_ID=testext "$script" 2>&1
}

# --- case 1: clean delta passes -------------------------------------------
src=$(make_srcdir clean)
delta=$(make_delta clean)
touch "$delta/usr/bin/incus" "$delta/usr/lib/x86_64-linux-gnu/libfoo.so.1"
if out=$(run_guard "$delta" "$src"); then
    ok "clean delta passes"
else
    fail "clean delta passes" "$out"
fi

# --- case 2: the incus bundle under /usr/incus is not base-owned ----------
src=$(make_srcdir bundle)
delta=$(make_delta bundle)
mkdir -p "$delta/usr/incus/bin" "$delta/usr/incus/share/qemu"
touch "$delta/usr/incus/bin/qemu-system-x86_64" "$delta/usr/incus/share/qemu/OVMF_CODE.4MB.fd"
if out=$(run_guard "$delta" "$src"); then
    ok "incus bundle under /usr/incus passes"
else
    fail "incus bundle under /usr/incus passes" "$out"
fi

# --- case 3: each base-owned family fails and is named --------------------
for rel in bin/qemu-system-x86_64 bin/qemu-img bin/kvm lib/qemu/qemu-bridge-helper \
    lib/x86_64-linux-gnu/qemu/ui-gtk.so share/qemu/firmware/60-edk2-x86_64.json \
    share/OVMF/OVMF_CODE_4M.fd share/ovmf/OVMF.fd share/seabios/bios-256k.bin; do
    name=${rel//\//_}
    src=$(make_srcdir "$name")
    delta=$(make_delta "$name")
    mkdir -p "$(dirname "$delta/usr/$rel")"
    touch "$delta/usr/$rel"
    if out=$(run_guard "$delta" "$src"); then
        fail "delta shipping /usr/$rel fails" "$out"
    elif names_path "$rel" "$out"; then
        ok "delta shipping /usr/$rel fails and names it"
    else
        fail "delta shipping /usr/$rel names the path" "$out"
    fi
done

# --- case 4: a literal pattern that is absent does not false-positive ----
# bin/kvm has no wildcard, so the shell yields it even when missing.
src=$(make_srcdir literal 'bin/kvm')
delta=$(make_delta literal)
if out=$(run_guard "$delta" "$src"); then
    ok "absent literal pattern passes"
else
    fail "absent literal pattern passes" "$out"
fi

# --- case 5: a dangling symlink still counts ------------------------------
src=$(make_srcdir dangling)
delta=$(make_delta dangling)
ln -s /nonexistent "$delta/usr/bin/qemu-system-x86_64"
if out=$(run_guard "$delta" "$src"); then
    fail "dangling symlink at a base-owned path fails" "$out"
else
    ok "dangling symlink at a base-owned path fails"
fi

# --- case 6: comments/blank lines only refuses; missing list fails --------
src=$(make_srcdir empty '# only a comment

   ')
delta=$(make_delta empty)
if out=$(run_guard "$delta" "$src"); then
    fail "empty pattern list refuses to pass vacuously" "$out"
elif grep -q "vacuously" <<<"$out"; then
    ok "empty pattern list refuses to pass vacuously"
else
    fail "empty pattern list names the vacuous-pass refusal" "$out"
fi
src="$work/missing/src"
mkdir -p "$src/shared/sysext"
delta=$(make_delta missing)
if out=$(run_guard "$delta" "$src"); then
    fail "missing pattern list fails" "$out"
else
    ok "missing pattern list fails"
fi

# --- case 7: base still ships the runtime the list protects ---------------
base_packages=$(awk '/^Packages=/{f=1} f&&/^\[/{f=0} f' "$root/mkosi.images/base/mkosi.conf" |
    sed 's/^Packages=//; s/#.*//' | tr -s ' \t' '\n' | sed '/^$/d')
for package in qemu-system-x86 qemu-utils ovmf; do
    if grep -qx "$package" <<<"$base_packages"; then
        ok "base ships $package"
    else
        fail "base ships $package (the list assumes base owns the VM runtime)"
    fi
done

# --- case 8: every sysext wires the guard ---------------------------------
mapfile -t configs < <(git -C "$root" ls-files -- 'mkosi.images/*/mkosi.conf')
wired=0
for config in "${configs[@]}"; do
    grep -Eq '^[[:space:]]*Overlay[[:space:]]*=[[:space:]]*yes' "$root/$config" || continue
    if grep -E '^[[:space:]]*FinalizeScripts=' "$root/$config" |
        grep -Fq '%D/shared/sysext/finalize/sysext-no-base-owned.sh'; then
        wired=$((wired + 1))
    else
        fail "${config%/mkosi.conf} wires sysext-no-base-owned.sh"
    fi
done
if ((wired > 0)); then
    ok "$wired sysexts wire sysext-no-base-owned.sh"
else
    fail "at least one sysext wires sysext-no-base-owned.sh"
fi

echo
echo "# Results: $((test_number - failures)) passed, $failures failed, $test_number total"
((failures == 0))
