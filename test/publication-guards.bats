#!/usr/bin/env bats
# SPDX-License-Identifier: LGPL-2.1-or-later

setup() {
    REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    FIXTURE=$(mktemp -d "$BATS_TEST_TMPDIR/publication-guards.XXXXXX")
}

assert_status() {
    local expected=$1

    if [[ $status -ne $expected ]]; then
        printf 'expected status %s, got %s\noutput:\n%s\n' \
            "$expected" "$status" "$output" >&2
        return 1
    fi
}

assert_output_contains() {
    local expected=$1

    if [[ $output != *"$expected"* ]]; then
        printf 'expected output to contain: %s\nactual output:\n%s\n' \
            "$expected" "$output" >&2
        return 1
    fi
}

refute_output_contains() {
    local unexpected=$1

    if [[ $output == *"$unexpected"* ]]; then
        printf 'expected output not to contain: %s\nactual output:\n%s\n' \
            "$unexpected" "$output" >&2
        return 1
    fi
}

make_native_fixture() {
    mkdir -p "$FIXTURE/shared/native-ab/keys" "$FIXTURE/.github/workflows"
    cp -a "$REPO_ROOT/mkosi.profiles" "$FIXTURE/"
    cp -a "$REPO_ROOT/shared/native-ab-secure" "$FIXTURE/shared/"
    cp "$REPO_ROOT/shared/native-ab/keys/import-pubring.gpg" \
        "$FIXTURE/shared/native-ab/keys/"
    cp "$REPO_ROOT/.github/workflows/build-native-images.yml" \
        "$FIXTURE/.github/workflows/"
}

initialize_fixture_repository() {
    git -C "$FIXTURE" init --quiet
    git -C "$FIXTURE" add .
}

@test "bootc guard accepts the repository publication contract" {
    run env SNOSI_BOOTC_GUARD_ROOT="$REPO_ROOT" \
        "$REPO_ROOT/check-bootc-publication-guard.sh"

    assert_status 0
    assert_output_contains "PASS: bootc publication guard satisfied"
}

@test "bootc guard fails closed for an incomplete publication root" {
    run env SNOSI_BOOTC_GUARD_ROOT="$FIXTURE" \
        "$REPO_ROOT/check-bootc-publication-guard.sh"

    assert_status 1
    assert_output_contains "missing bootc profile"
    assert_output_contains "missing publication workflow"
    assert_output_contains "missing secure image verifier"
}

@test "bootc guard mutation fixture suite passes under BATS" {
    run "$REPO_ROOT/test/bootc-publication-guard-test.sh"

    assert_status 0
    assert_output_contains "passing assertions, 0 failures"
}

@test "native guard accepts secure production profiles and an unpublishable raw profile" {
    make_native_fixture

    run env SNOSI_NATIVE_GUARD_ROOT="$FIXTURE" \
        "$REPO_ROOT/check-native-publication-guard.sh"

    assert_status 0
    assert_output_contains "cayo-ab/mkosi.conf satisfies the native publication guard"
    assert_output_contains "cayo-ab-raw/mkosi.conf remains unpublishable"
}

@test "native guard rejects a missing Secure Boot marker" {
    make_native_fixture
    sed -i '/^SecureBoot=yes$/d' "$FIXTURE/shared/native-ab-secure/mkosi.conf"

    run env SNOSI_NATIVE_GUARD_ROOT="$FIXTURE" \
        "$REPO_ROOT/check-native-publication-guard.sh"

    assert_status 1
    assert_output_contains "missing SecureBoot=yes"
}

@test "native guard rejects publication markers on the raw development profile" {
    make_native_fixture
    printf '\nSecureBoot=yes\n' >>"$FIXTURE/mkosi.profiles/cayo-ab-raw/mkosi.conf"

    run env SNOSI_NATIVE_GUARD_ROOT="$FIXTURE" \
        "$REPO_ROOT/check-native-publication-guard.sh"

    assert_status 1
    assert_output_contains "raw dev fixture must never carry publication markers"
}

@test "native guard rejects a pull request job that can access production secrets" {
    make_native_fixture
    sed -i "s/if: github.event_name == 'pull_request'/if: github.event_name != 'pull_request'/" \
        "$FIXTURE/.github/workflows/build-native-images.yml"

    run env SNOSI_NATIVE_GUARD_ROOT="$FIXTURE" \
        "$REPO_ROOT/check-native-publication-guard.sh"

    assert_status 1
    assert_output_contains "build-pr must run only on pull requests"
}

@test "runtime etc guard accepts marker files, explicit allowances, and build-time mutations" {
    mkdir -p "$FIXTURE/shared/example/tree/usr/lib/systemd/system" \
        "$FIXTURE/build"
    cat >"$FIXTURE/shared/example/tree/usr/lib/systemd/system/safe.service" <<'EOF'
[Unit]
ConditionPathExists=!/var/lib/example.done
[Service]
ExecStart=/usr/bin/true
ExecStartPost=/usr/bin/touch /var/lib/example.done
# etc-guard-allow: generated unit exists only at runtime
ExecReload=/usr/bin/systemctl enable generated.service
EOF
    cat >"$FIXTURE/build/mkosi.finalize" <<'EOF'
#!/bin/bash
systemctl enable image-defined.service
EOF
    initialize_fixture_repository

    run env SNOSI_RUNTIME_ETC_GUARD_ROOT="$FIXTURE" \
        "$REPO_ROOT/check-runtime-etc-guard.sh"

    assert_status 0
}

@test "runtime etc guard rejects service state changes and filesystem deletion" {
    mkdir -p "$FIXTURE/shared/example/tree/usr/libexec"
    cat >"$FIXTURE/shared/example/tree/usr/libexec/mutate-etc" <<'EOF'
#!/bin/bash
systemctl disable example.service
rm -f /etc/example.conf
mv /etc/old.conf /var/lib/example.conf
find /etc/example -type f -delete
EOF
    initialize_fixture_repository

    run env SNOSI_RUNTIME_ETC_GUARD_ROOT="$FIXTURE" \
        "$REPO_ROOT/check-runtime-etc-guard.sh"

    assert_status 1
    assert_output_contains "runtime systemctl enable/disable mutates /etc"
    assert_output_contains "runtime deletion/rename under /etc"
    assert_output_contains "Runtime /etc mutation check FAILED"
}

@test "runtime etc guard rejects tmpfiles removal under etc" {
    mkdir -p "$FIXTURE/mkosi.extra/usr/lib/tmpfiles.d"
    printf 'R /etc/example - - - -\n' \
        >"$FIXTURE/mkosi.extra/usr/lib/tmpfiles.d/example.conf"
    initialize_fixture_repository

    run env SNOSI_RUNTIME_ETC_GUARD_ROOT="$FIXTURE" \
        "$REPO_ROOT/check-runtime-etc-guard.sh"

    assert_status 1
    assert_output_contains "tmpfiles removal type targeting /etc"
}

@test "inline runtime allowance does not exempt the following violation" {
    mkdir -p "$FIXTURE/shared/example/tree/usr/libexec"
    cat >"$FIXTURE/shared/example/tree/usr/libexec/mutate-etc" <<'EOF'
#!/bin/bash
rm -f /etc/exempt.conf # etc-guard-allow: generated only at runtime
rm -f /etc/blocked.conf
EOF
    initialize_fixture_repository

    run env SNOSI_RUNTIME_ETC_GUARD_ROOT="$FIXTURE" \
        "$REPO_ROOT/check-runtime-etc-guard.sh"

    assert_status 1
    assert_output_contains "/etc/blocked.conf"
    refute_output_contains "/etc/exempt.conf"
}

@test "duplicate package guard accepts unique entries and ignores saved configurations" {
    mkdir -p "$FIXTURE/mkosi.profiles/example" "$FIXTURE/saved-unused/legacy"
    cat >"$FIXTURE/mkosi.profiles/example/mkosi.conf" <<'EOF'
[Content]
Packages=alpha
         beta # inline comments are ignored
EOF
    cat >"$FIXTURE/saved-unused/legacy/mkosi.conf" <<'EOF'
[Content]
Packages=duplicate
         duplicate
EOF
    initialize_fixture_repository

    run env SNOSI_DUPLICATE_PACKAGES_GUARD_ROOT="$FIXTURE" \
        "$REPO_ROOT/check-duplicate-packages.sh"

    assert_status 0
    assert_output_contains "No duplicate package entries found"
}

@test "duplicate package guard reports repeated package lines" {
    mkdir -p "$FIXTURE/mkosi.profiles/example"
    cat >"$FIXTURE/mkosi.profiles/example/mkosi.conf" <<'EOF'
[Content]
Packages=alpha
         alpha # duplicate
EOF
    initialize_fixture_repository

    run env SNOSI_DUPLICATE_PACKAGES_GUARD_ROOT="$FIXTURE" \
        "$REPO_ROOT/check-duplicate-packages.sh"

    assert_status 1
    assert_output_contains "Duplicate package entries in mkosi.profiles/example/mkosi.conf"
    assert_output_contains "alpha: lines 2, 3"
}
