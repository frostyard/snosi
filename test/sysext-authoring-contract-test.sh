#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Repository-wide structural contract for tracked mkosi sysext definitions.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

validation_failures=0
test_failures=0

validation_error() {
    echo "FAIL: $*" >&2
    validation_failures=$((validation_failures + 1))
}

validate_inventory() {
    local root=$1
    local config config_path name required_paths metadata_dir
    local expected_transfer expected_feature file remainder component
    local -a configs key_packages transfers features metadata_files
    local -A components=() orphan_reported=()

    validation_failures=0
    mapfile -t configs < <(
        git -C "$root" ls-files -- 'mkosi.images/*/mkosi.conf' |
            while IFS= read -r config; do
                grep -Eq '^[[:space:]]*Overlay[[:space:]]*=[[:space:]]*yes[[:space:]]*$' \
                    "$root/$config" && printf '%s\n' "$config"
            done
    )

    if ((${#configs[@]} == 0)); then
        validation_error "no tracked Overlay=yes sysext configs found"
    fi

    for config in "${configs[@]}"; do
        name=${config#mkosi.images/}
        name=${name%/mkosi.conf}
        config_path="$root/$config"
        components["$name"]=1

        required_paths="mkosi.images/$name/required-paths.txt"
        if ! git -C "$root" ls-files --error-unmatch -- "$required_paths" >/dev/null 2>&1; then
            validation_error "$name: missing tracked required-paths.txt"
        elif ! awk '!/^[[:space:]]*(#|$)/ { found=1 } END { exit !found }' \
            "$root/$required_paths"; then
            validation_error "$name: required-paths.txt has no path entries"
        fi

        mapfile -t key_packages < <(
            grep -E '^[[:space:]]*Environment=' "$config_path" |
                grep -Eo 'KEYPACKAGE=[^[:space:],]+' || true
        )
        if ((${#key_packages[@]} != 1)) || [[ ${key_packages[0]:-} == "KEYPACKAGE=" ]]; then
            validation_error "$name: mkosi.conf must define exactly one nonempty KEYPACKAGE"
        fi

        for file in \
            '%D/shared/sysext/finalize/sysext-usr-only.sh' \
            '%D/shared/sysext/finalize/sysext-required-paths.sh' \
            '%D/shared/sysext/finalize/sysext-strip-icon-cache.sh'; do
            grep -E '^[[:space:]]*FinalizeScripts=' "$config_path" |
                grep -Fq "$file" ||
                validation_error "$name: mkosi.conf is missing finalizer $file"
        done

        metadata_dir="mkosi.images/base/mkosi.extra/usr/lib/sysupdate.$name.d"
        expected_transfer="$metadata_dir/$name.transfer"
        expected_feature="$metadata_dir/$name.feature"
        mapfile -t transfers < <(git -C "$root" ls-files -- "$metadata_dir/*.transfer")
        mapfile -t features < <(git -C "$root" ls-files -- "$metadata_dir/*.feature")

        if ((${#transfers[@]} != 1)) || [[ ${transfers[0]:-} != "$expected_transfer" ]]; then
            validation_error "$name: expected exactly one matching $expected_transfer"
        else
            grep -qx "Features=$name" "$root/$expected_transfer" ||
                validation_error "$name: transfer must select Features=$name"
            grep -qx 'Verify=true' "$root/$expected_transfer" ||
                validation_error "$name: transfer must set Verify=true"
        fi

        if ((${#features[@]} != 1)) || [[ ${features[0]:-} != "$expected_feature" ]]; then
            validation_error "$name: expected exactly one matching $expected_feature"
        fi
    done

    mapfile -t metadata_files < <(
        git -C "$root" ls-files -- \
            'mkosi.images/base/mkosi.extra/usr/lib/sysupdate.*.d/*'
    )
    for file in "${metadata_files[@]}"; do
        remainder=${file#mkosi.images/base/mkosi.extra/usr/lib/sysupdate.}
        component=${remainder%%.d/*}
        if [[ -z ${components["$component"]+x} && -z ${orphan_reported["$component"]+x} ]]; then
            validation_error "$component: orphan component-scoped sysext metadata"
            orphan_reported["$component"]=1
        fi
    done

    if ((validation_failures > 0)); then
        return 1
    fi

    echo "ok - ${#configs[@]} tracked sysext authoring contracts"
}

write_valid_fixture() {
    local root=$1
    local metadata_dir="$root/mkosi.images/base/mkosi.extra/usr/lib/sysupdate.fixture.d"

    mkdir -p "$root/mkosi.images/fixture" "$metadata_dir"
    cat >"$root/mkosi.images/fixture/mkosi.conf" <<'EOF'
[Output]
Overlay=yes

[Content]
FinalizeScripts=%D/shared/sysext/finalize/sysext-usr-only.sh,%D/shared/sysext/finalize/sysext-required-paths.sh,%D/shared/sysext/finalize/sysext-strip-icon-cache.sh

[Build]
Environment=KEYPACKAGE=fixture-package
EOF
    printf '/usr/bin/fixture\n' >"$root/mkosi.images/fixture/required-paths.txt"
    cat >"$metadata_dir/fixture.transfer" <<'EOF'
[Transfer]
Features=fixture
Verify=true
EOF
    cat >"$metadata_dir/fixture.feature" <<'EOF'
[Feature]
Description=Fixture sysext
Enabled=false
EOF

    git -C "$root" init -q
    git -C "$root" add .
}

fixture_pass() {
    echo "PASS: $*"
}

fixture_fail() {
    echo "FAIL: $*" >&2
    test_failures=$((test_failures + 1))
}

run_negative_fixture() {
    local case_name=$1
    local expected=$2
    local root="$work_dir/$case_name"
    local metadata_dir="$root/mkosi.images/base/mkosi.extra/usr/lib"
    local output

    write_valid_fixture "$root"
    case "$case_name" in
        missing-required-paths)
            rm "$root/mkosi.images/fixture/required-paths.txt"
            git -C "$root" add -A
            ;;
        empty-required-paths)
            : >"$root/mkosi.images/fixture/required-paths.txt"
            git -C "$root" add mkosi.images/fixture/required-paths.txt
            ;;
        missing-keypackage)
            sed -i '/KEYPACKAGE=/d' "$root/mkosi.images/fixture/mkosi.conf"
            git -C "$root" add mkosi.images/fixture/mkosi.conf
            ;;
        missing-finalizer)
            sed -i 's#,%D/shared/sysext/finalize/sysext-strip-icon-cache.sh##' \
                "$root/mkosi.images/fixture/mkosi.conf"
            git -C "$root" add mkosi.images/fixture/mkosi.conf
            ;;
        missing-usr-only-finalizer)
            sed -i 's#%D/shared/sysext/finalize/sysext-usr-only.sh,##' \
                "$root/mkosi.images/fixture/mkosi.conf"
            git -C "$root" add mkosi.images/fixture/mkosi.conf
            ;;
        mismatched-feature)
            sed -i 's/Features=fixture/Features=other/' \
                "$metadata_dir/sysupdate.fixture.d/fixture.transfer"
            git -C "$root" add "$metadata_dir/sysupdate.fixture.d/fixture.transfer"
            ;;
        unsigned-transfer)
            sed -i 's/Verify=true/Verify=false/' \
                "$metadata_dir/sysupdate.fixture.d/fixture.transfer"
            git -C "$root" add "$metadata_dir/sysupdate.fixture.d/fixture.transfer"
            ;;
        orphan-metadata)
            mkdir -p "$metadata_dir/sysupdate.orphan.d"
            printf '[Feature]\nDescription=Orphan\n' \
                >"$metadata_dir/sysupdate.orphan.d/orphan.feature"
            git -C "$root" add "$metadata_dir/sysupdate.orphan.d/orphan.feature"
            ;;
        *)
            fixture_fail "unknown fixture case $case_name"
            return
            ;;
    esac

    if output=$(validate_inventory "$root" 2>&1); then
        fixture_fail "$case_name was accepted"
    elif [[ $output == *"$expected"* ]]; then
        fixture_pass "$case_name is rejected"
    else
        fixture_fail "$case_name produced the wrong diagnostic: $output"
    fi
}

if [[ ${1:-} == --validate ]]; then
    [[ $# -eq 2 ]] || {
        echo "Usage: $0 --validate <repository-root>" >&2
        exit 2
    }
    validate_inventory "$2"
    exit
elif (($# != 0)); then
    echo "Usage: $0 [--validate <repository-root>]" >&2
    exit 2
fi

valid_fixture="$work_dir/valid"
write_valid_fixture "$valid_fixture"
if output=$(validate_inventory "$valid_fixture" 2>&1); then
    fixture_pass "valid component is accepted"
else
    fixture_fail "valid component was rejected: $output"
fi

run_negative_fixture missing-required-paths "missing tracked required-paths.txt"
run_negative_fixture empty-required-paths "required-paths.txt has no path entries"
run_negative_fixture missing-keypackage "exactly one nonempty KEYPACKAGE"
run_negative_fixture missing-finalizer "sysext-strip-icon-cache.sh"
run_negative_fixture missing-usr-only-finalizer "sysext-usr-only.sh"
run_negative_fixture mismatched-feature "transfer must select Features=fixture"
run_negative_fixture unsigned-transfer "transfer must set Verify=true"
run_negative_fixture orphan-metadata "orphan component-scoped sysext metadata"

if ! validate_inventory "$repo_root"; then
    test_failures=$((test_failures + 1))
fi

if ((test_failures > 0)); then
    exit 1
fi

echo "sysext-authoring-contract-test: PASSED"
