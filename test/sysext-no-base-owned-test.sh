#!/bin/bash
# Fixture suite for the base-owned-paths sysext guard (#1011, #1015):
#  - shared/sysext/finalize/sysext-no-base-owned.sh behavior (a delta
#    shipping a base-owned VM-runtime path fails the build; a clean delta
#    and the incus bundle under /usr/incus pass; an empty or missing list
#    fails rather than passing vacuously)
#  - non-directory copies, base-tree resolution, and the report limit
#  - the real list covers the base VM runtime, and base still ships it
#  - wiring: every sysext runs the guard (also enforced by
#    test/sysext-authoring-contract-test.sh's required-finalizer set)
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/shared/sysext/finalize/sysext-no-base-owned.sh"
paths="$root/shared/sysext/base-owned-paths.txt"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
empty_base="$work/empty-base"
mkdir -p "$empty_base/usr"

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
make_delta() { # name [tree-name] -> path (empty /usr skeleton)
    local d="$work/$1/${2:-delta}"
    mkdir -p "$d/usr/bin" "$d/usr/lib/x86_64-linux-gnu" "$d/usr/share"
    echo "$d"
}
run_guard_env() { # delta srcdir [env assignments]
    local buildroot=$1 srcdir=$2
    shift 2
    env -u MKOSI_CONFIG -u SNOSI_SYSEXT_BASE_TREE BUILDROOT="$buildroot" \
        SRCDIR="$srcdir" IMAGE_ID=testext "$@" "$script" 2>&1
}
run_guard() { # delta srcdir [base-tree override]
    run_guard_env "$1" "$2" SNOSI_SYSEXT_BASE_TREE="${3:-$empty_base}"
}
new_copy_case() { # name
    src=$(make_srcdir "$1")
    delta=$(make_delta "$1")
    base=$(make_delta "$1" base)
}
copy_header='sysext-no-base-owned: testext delta ships copies of base-tree paths:'
copy_success_re='^sysext-no-base-owned: testext delta clean \(no base-tree copies against .+\)$'
copy_paths() {
    grep '^  /usr/' <<<"$1" || true
}
expect_duplicate() { # name rel guard-command [args...]
    local name=$1 rel=$2 out status=0
    shift 2
    out=$("$@") || status=$?
    if ((status == 1)) && grep -Fxq "$copy_header" <<<"$out" &&
        [[ $(copy_paths "$out") == "  /usr/$rel" ]]; then
        ok "$name"
    else
        fail "$name" "$out"
    fi
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

# --- base-tree copies ----------------------------------------------------
rel=lib/x86_64-linux-gnu/libgbm.so.1
new_copy_case duplicate-file
touch "$base/usr/$rel" "$delta/usr/$rel"
expect_duplicate "duplicate regular file fails and names its path" "$rel" run_guard "$delta" "$src" "$base"

new_copy_case duplicate-symlink
rel=lib/link-to-dir
# Symlinks to real directories count, but their children must not be walked.
mkdir -p "$base/target" "$delta/target"
touch "$base/target/child" "$delta/target/child"
ln -s "$base/target" "$base/usr/$rel"
ln -s "$delta/target" "$delta/usr/$rel"
expect_duplicate "duplicate directory symlink fails without walking its target" "$rel" run_guard "$delta" "$src" "$base"

new_copy_case symlink-over-file
rel=lib/link-over-file
touch "$base/usr/$rel"
ln -s /nonexistent "$delta/usr/$rel"
expect_duplicate "delta symlink over a base file fails" "$rel" run_guard "$delta" "$src" "$base"

new_copy_case file-over-dangling
rel=lib/file-over-dangling
ln -s /nonexistent "$base/usr/$rel"
touch "$delta/usr/$rel"
expect_duplicate "delta file over a dangling base symlink fails" "$rel" run_guard "$delta" "$src" "$base"

new_copy_case shared-directory
touch "$delta/usr/lib/unique"
if out=$(run_guard "$delta" "$src" "$base") && grep -Eq "$copy_success_re" <<<"$out"; then
    ok "shared real directory with a unique file passes"
else
    fail "shared real directory with a unique file passes" "$out"
fi

new_copy_case copy-with-space
rel='lib/file with a space'
touch "$base/usr/$rel" "$delta/usr/$rel"
expect_duplicate "duplicate path with spaces fails and names its path" "$rel" run_guard "$delta" "$src" "$base"

src=$(make_srcdir missing-base)
delta=$(make_delta missing-base)
status=0
out=$(run_guard "$delta" "$src" "$work/missing-base/absent") || status=$?
if ((status == 1)) && grep -Fq 'refusing to pass vacuously' <<<"$out"; then
    ok "missing base tree refuses to pass vacuously"
else
    fail "missing base tree refuses to pass vacuously" "$out"
fi

src=$(make_srcdir default-base)
delta=$(make_delta default-base)
rel=lib/default-copy
mkdir -p "$src/output/base/usr/lib"
touch "$src/output/base/usr/$rel" "$delta/usr/$rel"
expect_duplicate 'duplicate in $SRCDIR/output/base fails without an override or MKOSI_CONFIG' \
    "$rel" run_guard_env "$delta" "$src"

src=$(make_srcdir mkosi-config)
delta=$(make_delta mkosi-config)
rel=lib/gui-copy
config="$work/mkosi-config/config.json"
mkdir -p "$src/output/gui-base/usr/lib"
touch "$src/output/gui-base/usr/$rel" "$delta/usr/$rel"
jq -n --arg h "$work/mkosi-config/host-checkout" \
    '{BaseTrees: [($h + "/output/gui-base")], BuildSources: [{Source: "/elsewhere", Target: "/x"}, {Source: $h, Target: null}]}' \
    >"$config"
expect_duplicate "duplicate in the gui-base tree mapped from MKOSI_CONFIG fails" \
    "$rel" run_guard_env "$delta" "$src" MKOSI_CONFIG="$config"

# The mapped tree is the one checked: a clean delta names it in the success line.
rm "$delta/usr/$rel"
if out=$(run_guard_env "$delta" "$src" MKOSI_CONFIG="$config") &&
    grep -Fxq "sysext-no-base-owned: testext delta clean (no base-tree copies against $src/output/gui-base)" <<<"$out"; then
    ok "a clean delta names the gui-base tree mapped from MKOSI_CONFIG"
else
    fail "a clean delta names the gui-base tree mapped from MKOSI_CONFIG" "$out"
fi

# An unmapped BaseTrees= entry must not fall back to $SRCDIR/output/base.
src=$(make_srcdir unmapped-config)
delta=$(make_delta unmapped-config)
mkdir -p "$src/output/base/usr"
config="$work/unmapped-config/config.json"
jq -n --arg h "$work/unmapped-config/host-checkout" \
    '{BaseTrees: ["/nowhere/output/gui-base"], BuildSources: [{Source: $h, Target: null}]}' >"$config"
status=0
out=$(run_guard_env "$delta" "$src" MKOSI_CONFIG="$config") || status=$?
if ((status == 1)) && grep -Fq 'is not under a BuildSources= source; refusing to pass vacuously' <<<"$out"; then
    ok "an unmapped BaseTrees= entry refuses to fall back to output/base"
else
    fail "an unmapped BaseTrees= entry refuses to fall back to output/base" "$out"
fi

# A delta that cannot be listed fails closed with a reason.
new_copy_case unlistable
mkdir -p "$delta/usr/lib/locked"
touch "$delta/usr/lib/locked/file"
chmod 000 "$delta/usr/lib/locked"
status=0
out=$(run_guard "$delta" "$src" "$base") || status=$?
chmod 755 "$delta/usr/lib/locked"
if [[ $(id -u) -eq 0 ]]; then
    ok "unlistable delta check skipped as root (root reads mode-000 directories)"
elif ((status == 1)) && grep -Fq 'could not list the delta' <<<"$out"; then
    ok "a delta that cannot be listed fails closed with a reason"
else
    fail "a delta that cannot be listed fails closed with a reason" "$out"
fi

new_copy_case copy-limit
for i in {50..1}; do
    printf -v rel 'lib/copy-%02d' "$i"
    touch "$base/usr/$rel" "$delta/usr/$rel"
done
status=0
out=$(run_guard "$delta" "$src" "$base") || status=$?
if ((status == 1)) && [[ $(copy_paths "$out") == "$(printf '  /usr/lib/copy-%02d\n' {1..50})" ]] &&
    ! grep -q '^  \.\.\. and ' <<<"$out"; then
    ok "50 duplicates print exactly 50 sorted paths and no remainder"
else
    fail "50 duplicates print exactly 50 sorted paths and no remainder" "$out"
fi
touch "$base/usr/lib/copy-00" "$delta/usr/lib/copy-00"
status=0
out=$(run_guard "$delta" "$src" "$base") || status=$?
if ((status == 1)) && [[ $(copy_paths "$out") == "$(printf '  /usr/lib/copy-%02d\n' {0..49})" ]] &&
    [[ $(grep '^  \.\.\. and ' <<<"$out") == '  ... and 1 more' ]]; then
    ok "51 duplicates print exactly 50 sorted paths and one remaining"
else
    fail "51 duplicates print exactly 50 sorted paths and one remaining" "$out"
fi

new_copy_case both-clean
touch "$base/usr/lib/base-only" "$delta/usr/lib/delta-only"
if out=$(run_guard "$delta" "$src" "$base") && grep -Eq "$copy_success_re" <<<"$out" &&
    grep -Eq '^sysext-no-base-owned: testext delta clean \([0-9]+ base-owned patterns checked\)$' <<<"$out"; then
    ok "clean delta with a non-empty base prints both success lines"
else
    fail "clean delta with a non-empty base prints both success lines" "$out"
fi

new_copy_case both-fail
touch "$delta/usr/bin/qemu-img" "$delta/usr/lib/shared" "$base/usr/lib/shared"
status=0
out=$(run_guard "$delta" "$src" "$base") || status=$?
old_header='sysext-no-base-owned: testext delta ships paths the base image owns:'
if ((status == 1)) && [[ $(grep '^sysext-no-base-owned:' <<<"$out") == "$old_header"$'\n'"$copy_header" ]] &&
    [[ $(copy_paths "$out") == $'  /usr/bin/qemu-img\n  /usr/lib/shared' ]]; then
    ok "both checks report their offenders, with the glob check first"
else
    fail "both checks report their offenders, with the glob check first" "$out"
fi

echo
echo "# Results: $((test_number - failures)) passed, $failures failed, $test_number total"
((failures == 0))
