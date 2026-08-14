#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/check-profile-dependencies-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

cp "$repo_root/check-profile-dependencies.sh" "$scratch/"
mkdir -p \
    "$scratch/.mkosi/bin" \
    "$scratch/path" \
    "$scratch/mkosi.profiles/cayo-ab" \
    "$scratch/mkosi.profiles/firn-installer" \
    "$scratch/mkosi.profiles/future-product" \
    "$scratch/mkosi.profiles/native-installer"

cat >"$scratch/mkosi.conf" <<'EOF'
[Config]
Dependencies=base
             fixture-sysext

[Output]
Format=none
EOF

for profile in cayo-ab firn-installer future-product native-installer; do
    printf '[Config]\n' >"$scratch/mkosi.profiles/$profile/mkosi.conf"
done

cat >"$scratch/.mkosi/bin/mkosi" <<'EOF'
#!/bin/bash
set -euo pipefail

profile=
while (($# > 0)); do
    if [[ $1 == --profile ]]; then
        profile=$2
        shift 2
    else
        shift
    fi
done

[[ -n $profile ]] || {
    echo "missing --profile" >&2
    exit 1
}
printf '%s\n' "$profile" >>"$MKOSI_CALL_LOG"

if [[ $profile != firn-installer && $profile != native-installer &&
    $profile != "${MKOSI_EMPTY_PROFILE:-}" ]]; then
    printf 'IMAGE: base\n'
fi
if [[ $profile == "${MKOSI_EXTRA_PROFILE:-}" ]]; then
    printf 'IMAGE: %s\n' "$MKOSI_EXTRA_DEPENDENCY"
fi
EOF
chmod +x "$scratch/.mkosi/bin/mkosi"

cat >"$scratch/path/mkosi" <<'EOF'
#!/bin/bash
echo 'PATH mkosi was used instead of the local checkout' >&2
exit 1
EOF
chmod +x "$scratch/path/mkosi"

git -C "$scratch" init -q
git -C "$scratch" add mkosi.conf mkosi.profiles

call_log="$scratch/mkosi-calls"
run_guard() {
    (
        cd "$scratch"
        PATH="$scratch/path:$PATH" MKOSI_CALL_LOG="$call_log" \
            ./check-profile-dependencies.sh
    )
}

expect_failure() {
    local description=$1
    local expected=$2
    local output
    shift 2

    if output=$("$@" 2>&1); then
        echo "FAIL: $description was accepted" >&2
        exit 1
    elif [[ $output != *"$expected"* ]]; then
        echo "FAIL: $description produced the wrong diagnostic: $output" >&2
        exit 1
    fi
    echo "PASS: $description"
}

run_with_new_sysext() {
    MKOSI_EXTRA_PROFILE=future-product \
        MKOSI_EXTRA_DEPENDENCY=newly-listed-sysext \
        run_guard
}

run_without_product_base() {
    MKOSI_EMPTY_PROFILE=cayo-ab run_guard
}

run_with_installer_sysext() {
    MKOSI_EXTRA_PROFILE=native-installer \
        MKOSI_EXTRA_DEPENDENCY=fixture-sysext \
        run_guard
}

run_with_installer_base() {
    MKOSI_EXTRA_PROFILE=firn-installer \
        MKOSI_EXTRA_DEPENDENCY=base \
        run_guard
}

: >"$call_log"
run_guard | grep -qx 'Checked 4 profiles against 1 sysext dependencies.'
for profile in cayo-ab firn-installer future-product native-installer; do
    grep -qx "$profile" "$call_log" || {
        echo "FAIL: tracked profile $profile was not evaluated" >&2
        exit 1
    }
done
echo "PASS: tracked product and installer profiles use repository-local mkosi"

sed -i '/fixture-sysext/a\             newly-listed-sysext' "$scratch/mkosi.conf"
expect_failure \
    "new root sysext dependency is rejected without changing the guard" \
    "unexpectedly includes sysext dependency newly-listed-sysext" \
    run_with_new_sysext

expect_failure \
    "native product profile without base is rejected" \
    "Product profile cayo-ab must depend only on base." \
    run_without_product_base

expect_failure \
    "dedicated installer profile rejects inherited sysexts" \
    "Profile native-installer unexpectedly includes sysext dependency fixture-sysext." \
    run_with_installer_sysext

expect_failure \
    "dedicated installer profile remains dependency-free" \
    "Installer profile firn-installer must have no image dependencies." \
    run_with_installer_base

printf 'check-profile-dependencies-local-mkosi-test: PASSED\n'
