#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixtures for shared/security/no-private-keys.finalize and its sysext
# wrapper, plus wiring checks: every OCI composition and every sysext runs
# the guard, and the image finalize removes the ssl-cert snakeoil pair.
# Fixture keys are fake PEM bodies; no real key material. No root needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT_DIR/shared/security/no-private-keys.finalize"
SYSEXT_GUARD="$ROOT_DIR/shared/sysext/finalize/sysext-no-private-keys.sh"
IMAGE_FINALIZE="$ROOT_DIR/shared/outformat/image/finalize/mkosi.finalize.chroot"
WORK_DIR="$(mktemp -d)"
BUILDROOT="$WORK_DIR/root"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "PASS: $*"; }

fake_key() { # path [label]
    mkdir -p "$(dirname "$1")"
    printf -- '-----BEGIN %sPRIVATE KEY-----\nZmFrZQ==\n-----END %sPRIVATE KEY-----\n' "${2:-}" "${2:-}" >"$1"
}

reset_root() {
    rm -rf "$BUILDROOT"
    mkdir -p "$BUILDROOT"/{etc/ssl/private,etc/ssl/certs,etc/ssh,usr/share/doc,opt,var/lib/dpkg/info}
    printf 'not a key\n' >"$BUILDROOT/usr/share/doc/readme"
}

own() { # relpath package: record the file as shipped unmodified by a package
    local sum
    sum=$(md5sum <"$BUILDROOT/$1")
    printf '%s  %s\n' "${sum%% *}" "$1" >>"$BUILDROOT/var/lib/dpkg/info/$2.md5sums"
}

run() { # script [env...]
    local script=$1
    shift
    if RUN_OUTPUT=$(env "$@" BUILDROOT="$BUILDROOT" SRCDIR="$ROOT_DIR" IMAGE_ID=fixture "$script" 2>&1); then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
}

expect_pass() { # description script
    run "$2"
    if [[ $RUN_STATUS -eq 0 ]]; then pass "$1"; else fail "$1 (exit $RUN_STATUS): $RUN_OUTPUT"; fi
}

expect_reject() { # description path script
    run "$3"
    if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/$2:"* ]]; then
        pass "$1"
    else
        fail "$1 (exit $RUN_STATUS): $RUN_OUTPUT"
    fi
}

# --- image guard ----------------------------------------------------------

reset_root
expect_pass "clean tree passes" "$GUARD"

reset_root
fake_key "$BUILDROOT/etc/ssl/private/ssl-cert-snakeoil.key" "RSA "
expect_reject "build-time snakeoil key is rejected" etc/ssl/private/ssl-cert-snakeoil.key "$GUARD"

reset_root
printf '\x30\x82\x04\xa4\x02\x01\x00' >"$BUILDROOT/etc/ssl/private/server.der"
expect_reject "non-PEM file under /etc/ssl/private is rejected" etc/ssl/private/server.der "$GUARD"

reset_root
printf 'opaque\n' >"$BUILDROOT/etc/ssh/ssh_host_ed25519_key"
expect_reject "ssh host key is rejected" etc/ssh/ssh_host_ed25519_key "$GUARD"

reset_root
fake_key "$BUILDROOT/usr/lib/fixture/id_ed25519" "OPENSSH "
expect_reject "unowned OpenSSH key under /usr is rejected" usr/lib/fixture/id_ed25519 "$GUARD"

reset_root
fake_key "$BUILDROOT/var/lib/fixture/key.pem" "EC "
expect_reject "unowned EC key under /var is rejected" var/lib/fixture/key.pem "$GUARD"

reset_root
mkdir -p "$BUILDROOT/usr/share/keys"
printf -- '-----BEGIN PGP PRIVATE KEY BLOCK-----\nZmFrZQ==\n-----END PGP PRIVATE KEY BLOCK-----\n' \
    >"$BUILDROOT/usr/share/keys/signing.asc"
expect_reject "armored PGP private key is rejected" usr/share/keys/signing.asc "$GUARD"

reset_root
fake_key "$BUILDROOT/usr/share/ovmf/PkKek-1-snakeoil.key"
own usr/share/ovmf/PkKek-1-snakeoil.key ovmf
expect_pass "key byte-identical to its Debian package passes" "$GUARD"

reset_root
fake_key "$BUILDROOT/usr/share/ovmf/PkKek-1-snakeoil.key"
own usr/share/ovmf/PkKek-1-snakeoil.key ovmf
fake_key "$BUILDROOT/usr/share/ovmf/PkKek-1-snakeoil.key" "RSA "
expect_reject "package key rewritten after install is rejected" usr/share/ovmf/PkKek-1-snakeoil.key "$GUARD"

reset_root
mkdir -p "$BUILDROOT/usr/lib/node_modules/ssh2"
printf "const h = '-----BEGIN OPENSSH PRIVATE KEY-----\\n';\n" >"$BUILDROOT/usr/lib/node_modules/ssh2/keyParser.js"
expect_pass "header quoted inside source code is not a key" "$GUARD"

reset_root
fake_key "$BUILDROOT/usr/lib/code-server/test/fixtures/server.key"
printf '/usr/lib/code-server/test/fixtures/server.key\n' >"$BUILDROOT/var/lib/dpkg/info/code-server.list"
run "$GUARD"
if [[ $RUN_STATUS -eq 0 && "$RUN_OUTPUT" == *"without md5sums: /usr/lib/code-server/test/fixtures/server.key"* ]]; then
    pass "package payload without md5sums passes and is logged as unverified"
else
    fail "package payload without md5sums (exit $RUN_STATUS): $RUN_OUTPUT"
fi

reset_root
fake_key "$BUILDROOT/etc/ssl/private/ssl-cert-snakeoil.key"
printf '/etc/ssl/private/ssl-cert-snakeoil.key\n' >"$BUILDROOT/var/lib/dpkg/info/fixture.list"
expect_reject "package ownership does not exempt /etc/ssl/private" etc/ssl/private/ssl-cert-snakeoil.key "$GUARD"

reset_root
mkdir -p "$BUILDROOT/usr/share/dir with space"
fake_key "$BUILDROOT/usr/share/dir with space/k.pem"
expect_reject "paths with spaces are reported" "usr/share/dir with space/k.pem" "$GUARD"

if RUN_OUTPUT=$(env -u BUILDROOT "$GUARD" 2>&1); then
    fail "missing BUILDROOT must fail closed"
else
    pass "missing BUILDROOT fails closed"
fi

# --- sysext wrapper: only the packed trees (/usr, /opt) ---------------------

reset_root
fake_key "$BUILDROOT/etc/ssl/private/ssl-cert-snakeoil.key"
expect_pass "sysext ignores /etc build residue that never ships" "$SYSEXT_GUARD"

reset_root
fake_key "$BUILDROOT/usr/lib/fixture/server.key"
expect_reject "sysext /usr key is rejected" usr/lib/fixture/server.key "$SYSEXT_GUARD"

reset_root
fake_key "$BUILDROOT/opt/fixture/server.key"
expect_reject "sysext /opt key is rejected" opt/fixture/server.key "$SYSEXT_GUARD"

# --- wiring ------------------------------------------------------------------

for composition in floe snow sundog; do
    conf="$ROOT_DIR/shared/composition/$composition/mkosi.conf"
    finalize_line=$(grep -n '^FinalizeScripts=%D/shared/outformat/image/finalize/mkosi.finalize.chroot$' "$conf" | cut -d: -f1 || true)
    guard_line=$(grep -n '^FinalizeScripts=%D/shared/security/no-private-keys.finalize$' "$conf" | cut -d: -f1 || true)
    if [[ -n "$finalize_line" && -n "$guard_line" && "$guard_line" -gt "$finalize_line" ]]; then
        pass "$composition runs the guard after the image finalize"
    else
        fail "$composition must list shared/security/no-private-keys.finalize after mkosi.finalize.chroot"
    fi
done

for conf in "$ROOT_DIR"/mkosi.images/*/mkosi.conf; do
    grep -q '^Format=sysext' "$conf" || continue
    name=$(basename "$(dirname "$conf")")
    if grep -q '^FinalizeScripts=.*%D/shared/sysext/finalize/sysext-no-private-keys\.sh' "$conf"; then
        pass "sysext $name runs the guard"
    else
        fail "sysext $name must list shared/sysext/finalize/sysext-no-private-keys.sh"
    fi
done

if grep -q '^rm -f /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/certs/ssl-cert-snakeoil.pem$' "$IMAGE_FINALIZE" &&
    grep -q "lname '\*ssl-cert-snakeoil.pem' -delete" "$IMAGE_FINALIZE"; then
    pass "image finalize removes the snakeoil pair and its hash link"
else
    fail "image finalize must remove the ssl-cert snakeoil key, cert and hash link"
fi

if ((failures > 0)); then
    echo "no-private-keys-test: $failures failure(s)" >&2
    exit 1
fi
echo "no-private-keys-test: PASSED"
