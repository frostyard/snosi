#!/bin/bash
# Fixture test for snosi_prune_stale_requires (the initrd 95etc-overlay
# stale-.requires pruning that keeps a retired preset-enabled RequiredBy=
# unit from bricking boot at "Failed to isolate default target").
# Root cause and scope rationale: docs/adr/0013 and etc-overlay-prune.sh.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
prune_lib="$root/shared/outformat/ab-root/tree/usr/lib/dracut/modules.d/95etc-overlay/etc-overlay-prune.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The initrd sources this after dracut-lib; the test provides info().
info() { :; }
# shellcheck source=/dev/null
. "$prune_lib"

test_number=0
failures=0

ok() { # name condition-status
    test_number=$((test_number + 1))
    if [ "$2" -eq 0 ]; then
        printf 'ok %d - %s\n' "$test_number" "$1"
    else
        printf 'not ok %d - %s\n' "$test_number" "$1"
        failures=$((failures + 1))
    fi
}

fresh_fixture() {
    fx="$work/fx-$((test_number + 1))"
    upper="$fx/upper"
    sysroot="$fx/sysroot"
    mkdir -p \
        "$upper/systemd/system/multi-user.target.requires" \
        "$upper/systemd/system/multi-user.target.wants" \
        "$sysroot/usr/lib/systemd/system" \
        "$sysroot/.etc.lower/systemd/system"
}

# 1. A .requires link naming a unit absent everywhere is pruned.
fresh_fixture
ln -s /usr/lib/systemd/system/retired.service \
    "$upper/systemd/system/multi-user.target.requires/retired.service"
snosi_prune_stale_requires "$upper" "$sysroot"
[ ! -L "$upper/systemd/system/multi-user.target.requires/retired.service" ]
ok "dangling .requires link is pruned" $?

# 2. A .requires link whose unit ships in the image /usr is kept.
fresh_fixture
touch "$sysroot/usr/lib/systemd/system/kept.service"
ln -s /usr/lib/systemd/system/kept.service \
    "$upper/systemd/system/multi-user.target.requires/kept.service"
snosi_prune_stale_requires "$upper" "$sysroot"
[ -L "$upper/systemd/system/multi-user.target.requires/kept.service" ]
ok ".requires link to an image-shipped unit is kept" $?

# 3. Resolution is by NAME, not target path: a link whose target path
#    dangles but whose unit name exists in the image search path is kept.
fresh_fixture
touch "$sysroot/usr/lib/systemd/system/moved.service"
ln -s /old/path/moved.service \
    "$upper/systemd/system/multi-user.target.requires/moved.service"
snosi_prune_stale_requires "$upper" "$sysroot"
[ -L "$upper/systemd/system/multi-user.target.requires/moved.service" ]
ok "unit resolved by symlink name, not target path" $?

# 4. A unit defined only in the persistent upper (real file) is kept.
fresh_fixture
touch "$upper/systemd/system/local.service"
ln -s /etc/systemd/system/local.service \
    "$upper/systemd/system/multi-user.target.requires/local.service"
snosi_prune_stale_requires "$upper" "$sysroot"
[ -L "$upper/systemd/system/multi-user.target.requires/local.service" ]
ok "unit defined in the upper itself is kept" $?

# 5. A unit defined in the image /etc lower is kept.
fresh_fixture
touch "$sysroot/.etc.lower/systemd/system/lower.service"
ln -s /etc/systemd/system/lower.service \
    "$upper/systemd/system/multi-user.target.requires/lower.service"
snosi_prune_stale_requires "$upper" "$sysroot"
[ -L "$upper/systemd/system/multi-user.target.requires/lower.service" ]
ok "unit defined in the image /etc lower is kept" $?

# 6. Template instances fall back to their template file.
fresh_fixture
touch "$sysroot/usr/lib/systemd/system/getty@.service"
ln -s /usr/lib/systemd/system/getty@.service \
    "$upper/systemd/system/multi-user.target.requires/getty@tty7.service"
snosi_prune_stale_requires "$upper" "$sysroot"
[ -L "$upper/systemd/system/multi-user.target.requires/getty@tty7.service" ]
ok "template instance resolves through its template file" $?

# 7. Dangling template instance with no template anywhere is pruned.
fresh_fixture
ln -s /usr/lib/systemd/system/gone@.service \
    "$upper/systemd/system/multi-user.target.requires/gone@x.service"
snosi_prune_stale_requires "$upper" "$sysroot"
[ ! -L "$upper/systemd/system/multi-user.target.requires/gone@x.service" ]
ok "dangling template instance is pruned" $?

# 8. .wants links are NEVER touched, even when dangling (sysext units are
#    legitimately absent from the pristine root at initrd time).
fresh_fixture
ln -s /usr/lib/systemd/system/docker.service \
    "$upper/systemd/system/multi-user.target.wants/docker.service"
snosi_prune_stale_requires "$upper" "$sysroot"
[ -L "$upper/systemd/system/multi-user.target.wants/docker.service" ]
ok "dangling .wants link is left alone" $?

# 9. A masked unit (name exists as /dev/null symlink in the upper) counts
#    as existing: the admin's mask is not overridden.
fresh_fixture
ln -s /dev/null "$upper/systemd/system/masked.service"
ln -s /usr/lib/systemd/system/masked.service \
    "$upper/systemd/system/multi-user.target.requires/masked.service"
snosi_prune_stale_requires "$upper" "$sysroot"
[ -L "$upper/systemd/system/multi-user.target.requires/masked.service" ]
ok "requires link to a masked unit is kept" $?

# 10. Non-symlink entries in a .requires dir are untouched.
fresh_fixture
touch "$upper/systemd/system/multi-user.target.requires/notalink.service"
snosi_prune_stale_requires "$upper" "$sysroot"
[ -f "$upper/systemd/system/multi-user.target.requires/notalink.service" ]
ok "regular file in .requires dir is untouched" $?

# 11. No .requires dirs at all: no error, nothing changes.
fresh_fixture
rmdir "$upper/systemd/system/multi-user.target.requires"
snosi_prune_stale_requires "$upper" "$sysroot"
ok "empty fixture runs cleanly" $?

# 12. The regression shape itself: retired snow-linux-live-setup.service
#     pruned from multi-user.target.requires while an unrelated wants
#     enablement for an image unit survives.
fresh_fixture
touch "$sysroot/usr/lib/systemd/system/ssh.service"
ln -s /usr/lib/systemd/system/snow-linux-live-setup.service \
    "$upper/systemd/system/multi-user.target.requires/snow-linux-live-setup.service"
ln -s /usr/lib/systemd/system/ssh.service \
    "$upper/systemd/system/multi-user.target.wants/ssh.service"
snosi_prune_stale_requires "$upper" "$sysroot"
[ ! -L "$upper/systemd/system/multi-user.target.requires/snow-linux-live-setup.service" ] &&
    [ -L "$upper/systemd/system/multi-user.target.wants/ssh.service" ]
ok "2026-08-12 regression shape: stale requires pruned, wants kept" $?

printf '1..%d\n' "$test_number"
exit "$((failures > 0 ? 1 : 0))"
