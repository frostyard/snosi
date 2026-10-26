#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixtures for shared/security/no-private-keys.finalize and its sysext
# wrapper, plus wiring checks: every OCI composition, the installer ISO and
# every sysext run the guard, and the image finalize removes the ssl-cert
# snakeoil pair.
# Fixture keys are fake PEM bodies; no real key material. No root needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT_DIR/shared/security/no-private-keys.finalize"
SYSEXT_GUARD="$ROOT_DIR/shared/sysext/finalize/sysext-no-private-keys.sh"
IMAGE_FINALIZE="$ROOT_DIR/shared/outformat/image/finalize/mkosi.finalize.chroot"
WORK_DIR="$(mktemp -d)"
BUILDROOT="$WORK_DIR/root"
trap 'chmod -R u+rwX "$WORK_DIR" 2>/dev/null; rm -rf "$WORK_DIR"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "PASS: $*"; }

fake_key() { # path [label]
    mkdir -p "$(dirname "$1")"
    printf -- '-----BEGIN %sPRIVATE KEY-----\nZmFrZQ==\n-----END %sPRIVATE KEY-----\n' "${2:-}" "${2:-}" >"$1"
}

reset_root() {
    [[ -e "$BUILDROOT" ]] && chmod -R u+rwX "$BUILDROOT"
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

# Allowlist: a fixture SRCDIR carries its own shared/security/private-key-allowlist.txt.
FIXTURE_SRC="$WORK_DIR/src"
mkdir -p "$FIXTURE_SRC/shared/security"
reset_root
fake_key "$BUILDROOT/usr/lib/vendor/test/fixtures/server.key"
fixture_sha=$(sha256sum <"$BUILDROOT/usr/lib/vendor/test/fixtures/server.key")
printf '# comment\n%s  /usr/lib/vendor/test/fixtures/server.key\n' "${fixture_sha%% *}" \
    >"$FIXTURE_SRC/shared/security/private-key-allowlist.txt"
run_allowlisted() {
    if RUN_OUTPUT=$(BUILDROOT="$BUILDROOT" SRCDIR="$FIXTURE_SRC" IMAGE_ID=fixture "$GUARD" 2>&1); then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
}
run_allowlisted
if [[ $RUN_STATUS -eq 0 && "$RUN_OUTPUT" == *"allowlisted public key: /usr/lib/vendor/test/fixtures/server.key"* ]]; then
    pass "allowlisted fixture with matching sha256 passes"
else
    fail "allowlisted fixture (exit $RUN_STATUS): $RUN_OUTPUT"
fi
fake_key "$BUILDROOT/usr/lib/vendor/test/fixtures/server.key" "RSA "
run_allowlisted
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"sha256 differs from private-key-allowlist.txt"* ]]; then
    pass "allowlisted path with changed bytes is rejected"
else
    fail "allowlisted path with changed bytes (exit $RUN_STATUS): $RUN_OUTPUT"
fi
fake_key "$BUILDROOT/usr/lib/vendor/test/fixtures/other.key"
fake_key "$BUILDROOT/usr/lib/vendor/test/fixtures/server.key"
run_allowlisted
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/usr/lib/vendor/test/fixtures/other.key:"* ]]; then
    pass "allowlist exempts only the listed path"
else
    fail "allowlist must not exempt unlisted paths (exit $RUN_STATUS): $RUN_OUTPUT"
fi

reset_root
fake_key "$BUILDROOT/usr/lib/code-server/node_modules/httpolyglot/test/fixtures/server.key"
expect_reject "repo allowlist does not exempt different bytes at a listed path" \
    usr/lib/code-server/node_modules/httpolyglot/test/fixtures/server.key "$SYSEXT_GUARD"

while read -r sha path; do
    [[ -z "$sha" || "$sha" == \#* ]] && continue
    if [[ "$sha" =~ ^[0-9a-f]{64}$ && "$path" == /* ]]; then
        pass "allowlist entry well formed: $path"
    else
        fail "malformed allowlist entry: $sha $path"
    fi
done <"$ROOT_DIR/shared/security/private-key-allowlist.txt"

reset_root
mkdir -p "$BUILDROOT/usr/share/dir with space"
fake_key "$BUILDROOT/usr/share/dir with space/k.pem"
expect_reject "paths with spaces are reported" "usr/share/dir with space/k.pem" "$GUARD"

# --- fail closed: scan errors must fail, never report clean -----------------
# Permission bits do not stop root, so these fixtures need an unprivileged
# user (validate.yml runs them as the runner user).

expect_scan_error() { # description script
    run "$2"
    if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"refusing to report fixture clean"* &&
        "$RUN_OUTPUT" != *"no build-time private keys"* ]]; then
        pass "$1"
    else
        fail "$1 (exit $RUN_STATUS): $RUN_OUTPUT"
    fi
}

if [[ $EUID -eq 0 ]]; then
    echo "SKIP: fail-closed permission fixtures need a non-root user"
else
    reset_root
    fake_key "$BUILDROOT/usr/lib/hidden/server.key"
    chmod 000 "$BUILDROOT/usr/lib/hidden/server.key"
    expect_scan_error "unreadable file fails the scan" "$GUARD"
    expect_scan_error "unreadable file fails the sysext scan" "$SYSEXT_GUARD"
    chmod 600 "$BUILDROOT/usr/lib/hidden/server.key"

    reset_root
    fake_key "$BUILDROOT/usr/lib/hidden/server.key"
    chmod 000 "$BUILDROOT/usr/lib/hidden"
    expect_scan_error "untraversable directory fails the scan" "$GUARD"
    expect_scan_error "untraversable directory fails the sysext scan" "$SYSEXT_GUARD"
    chmod 755 "$BUILDROOT/usr/lib/hidden"

    reset_root
    printf 'opaque\n' >"$BUILDROOT/usr/share/doc/clean-but-unreadable"
    chmod 000 "$BUILDROOT/usr/share/doc/clean-but-unreadable"
    expect_scan_error "unreadable file without a key still fails the scan" "$GUARD"
    chmod 600 "$BUILDROOT/usr/share/doc/clean-but-unreadable"

    reset_root
    printf '/usr/share/doc/readme\n' >"$BUILDROOT/var/lib/dpkg/info/fixture.list"
    chmod 000 "$BUILDROOT/var/lib/dpkg/info/fixture.list"
    run "$GUARD"
    if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" != *"no build-time private keys"* ]]; then
        pass "unreadable dpkg list fails the guard"
    else
        fail "unreadable dpkg list (exit $RUN_STATUS): $RUN_OUTPUT"
    fi
    chmod 600 "$BUILDROOT/var/lib/dpkg/info/fixture.list"
fi

# Producer failures: shim each external command the guard consumes so it
# fails with its documented error status. Runs as root too: shims, not modes.
# grep's error status is 2; its 1 means "no match" and is a clean result.
SHIM_DIR="$WORK_DIR/shims"
make_shim() { # command
    local status=1
    [[ $1 == grep ]] && status=2
    rm -rf "$SHIM_DIR"
    mkdir -p "$SHIM_DIR"
    printf '#!/bin/sh\necho "%s: simulated failure" >&2\nexit %s\n' "$1" "$status" >"$SHIM_DIR/$1"
    chmod +x "$SHIM_DIR/$1"
}
run_shimmed() { # command script
    make_shim "$1"
    if RUN_OUTPUT=$(PATH="$SHIM_DIR:$PATH" BUILDROOT="$BUILDROOT" SRCDIR="$ROOT_DIR" IMAGE_ID=fixture "$2" 2>&1); then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
}
expect_not_clean() { # description
    if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" != *"no build-time private keys"* ]]; then
        pass "$1"
    else
        fail "$1 (exit $RUN_STATUS): $RUN_OUTPUT"
    fi
}

reset_root
printf '\x30\x82\x04\xa4\x02\x01\x00' >"$BUILDROOT/etc/ssl/private/server.der"
run_shimmed cat "$GUARD"
if [[ $RUN_STATUS -ne 0 && "$RUN_OUTPUT" == *"/etc/ssl/private/server.der:"* ]]; then
    pass "location rule does not depend on cat"
else
    fail "location rule with failing cat (exit $RUN_STATUS): $RUN_OUTPUT"
fi

for producer in find xargs grep; do
    reset_root
    fake_key "$BUILDROOT/usr/lib/fixture/server.key"
    run_shimmed "$producer" "$GUARD"
    expect_not_clean "failing $producer fails the guard"
    run_shimmed "$producer" "$SYSEXT_GUARD"
    expect_not_clean "failing $producer fails the sysext guard"
done

reset_root
fake_key "$BUILDROOT/usr/share/ovmf/PkKek-1-snakeoil.key"
own usr/share/ovmf/PkKek-1-snakeoil.key ovmf
run_shimmed md5sum "$GUARD"
expect_not_clean "failing md5sum fails the guard"

reset_root
fake_key "$BUILDROOT/usr/lib/code-server/node_modules/httpolyglot/test/fixtures/server.key"
run_shimmed sha256sum "$GUARD"
expect_not_clean "failing sha256sum fails the guard"

if RUN_OUTPUT=$(env -u BUILDROOT SRCDIR="$ROOT_DIR" "$GUARD" 2>&1); then
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

# The installer ISO has no image finalize: its postinst removes the SSH host
# keys and the guard is its own FinalizeScript.
if grep -qx 'FinalizeScripts=%D/shared/security/no-private-keys.finalize' \
    "$ROOT_DIR/shared/firn-installer/mkosi.conf"; then
    pass "firn-installer runs the guard"
else
    fail "shared/firn-installer/mkosi.conf must list shared/security/no-private-keys.finalize"
fi

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
