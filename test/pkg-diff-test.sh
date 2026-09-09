#!/bin/bash
# Fixture suite for the ADR-0014 staged-package inventory library
# (mkosi.images/base/mkosi.extra/usr/lib/snosi/staged-packages.sh): the ONE
# apt-list parser and package differ used by `snosi-update-status --pkg-diff`,
# plus the identity-bound sidecar publish/resolve used by both stagers.
#
# The parser/diff fixtures are real Debian Trixie `apt list --installed` lines
# (arch-qualified names, "<suite>,now" and bare "now" lines, "Listing... Done"
# header, epoch/backport version grammar) -- NOT simplified "name/now version"
# stubs, per ADR-0014's "captured lines from the target image's APT" rule.
#
# Version-ordering assertions require `dpkg --compare-versions` (the dpkg
# DATABASE is never read); on a host without dpkg they TAP-SKIP rather than
# fail, so the parser and sidecar coverage still runs everywhere. validate.yml
# runs on a Debian/Ubuntu runner where dpkg is present.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lib="$root/mkosi.images/base/mkosi.extra/usr/lib/snosi/staged-packages.sh"
fixtures="$root/test/fixtures/pkg-diff"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
export SNOSI_RUN_DIR="$workdir/run"

# shellcheck source=/dev/null
source "$lib"

test_number=0
failures=0
ok() { test_number=$((test_number + 1)); echo "ok $test_number - $1"; }
fail() {
    test_number=$((test_number + 1)); failures=$((failures + 1))
    echo "not ok $test_number - $1"
    [[ $# -gt 1 ]] && printf '# %s\n' "$2"
}
skip() { test_number=$((test_number + 1)); echo "ok $test_number - $1 # SKIP $2"; }
is() { # actual expected label
    if [[ "$1" == "$2" ]]; then ok "$3"; else
        fail "$3" "expected [$2], got [$1]"
    fi
}

# --- parser -----------------------------------------------------------------

parsed="$(apt_list_parse "$fixtures/running.packages.txt")"

field() { grep -P "^$1\t" <<<"$parsed" | cut -f2; }

is "$(field 'libc6:amd64')" '2.41-12' 'arch-qualified key (:amd64) preserved, version parsed'
is "$(field 'libc6:i386')" '2.41-12' 'the i386 Multi-Arch instance is a distinct key'
is "$(field 'bash')" '5.2.37-2' 'bare "now" (local) line parsed'
is "$(field 'vim-common')" '2:9.1.1230-1' 'epoch version kept intact'
is "$(field 'zlib1g:amd64')" '1:1.3.dfsg+really1.3.1-1+b1' 'complex epoch/binNMU version kept intact'

if grep -qiP '^Listing' <<<"$parsed"; then
    fail 'the "Listing... Done" header is not emitted as a package'
else
    ok 'the "Listing... Done" header is skipped'
fi

# every emitted key is the substring before the first "/" of a source line
if awk -F'\t' 'NF!=2 || $1=="" || $2=="" {exit 1}' <<<"$parsed"; then
    ok 'every parsed line is exactly key<TAB>version'
else
    fail 'a parsed line was not key<TAB>version'
fi

# --- diff (dpkg-gated) ------------------------------------------------------

if command -v dpkg >/dev/null 2>&1; then
    got="$(pkg_diff "$fixtures/running.packages.txt" "$fixtures/staged.packages.txt")"
    want="$(cat "$fixtures/expected-diff.txt")"
    is "$got" "$want" 'pkg_diff matches the expected Upgraded/Downgraded/Added/Removed delta'

    # identical lists produce no output
    empty="$(pkg_diff "$fixtures/running.packages.txt" "$fixtures/running.packages.txt")"
    is "$empty" '' 'identical package lists produce no delta'
else
    skip 'pkg_diff delta' 'dpkg not available'
    skip 'identical lists produce no delta' 'dpkg not available'
fi

# --- backing-name shapes ----------------------------------------------------

digest="sha256:$(printf 'a%.0s' {1..64})"
is "$(staged_packages_backing_name digest "$digest")" \
   "staged-packages.sha256-$(printf 'a%.0s' {1..64})" \
   'bootc backing name uses sha256- (no colon)'
is "$(staged_packages_backing_name version 20260909120000)" \
   'staged-packages.20260909120000' \
   'native backing name is the 14-digit version'

if staged_packages_backing_name digest 'sha256:short' >/dev/null 2>&1; then
    fail 'a malformed digest is rejected by backing-name'
else
    ok 'a malformed digest is rejected by backing-name'
fi
if staged_packages_backing_name version 12345 >/dev/null 2>&1; then
    fail 'a malformed version is rejected by backing-name'
else
    ok 'a malformed version is rejected by backing-name'
fi

# --- publish / resolve / identity ------------------------------------------

staged_packages_publish version 20260909120000 "$fixtures/staged.packages.txt" \
    && ok 'publish (native version identity) succeeds' \
    || fail 'publish (native version identity) succeeds'

# idempotent: a second publish of the same identity must not error and must
# not fail on "Directory not empty" (the mv -T directory trap).
staged_packages_publish version 20260909120000 "$fixtures/staged.packages.txt" \
    && ok 'a second publish of the same identity is idempotent (no Directory-not-empty)' \
    || fail 'a second publish of the same identity is idempotent (no Directory-not-empty)'

# staged-packages is always a symlink, never a directory
if [[ -L "$SNOSI_RUN_DIR/staged-packages" ]]; then
    ok 'the published /run/snosi/staged-packages is a symlink'
else
    fail 'the published /run/snosi/staged-packages is a symlink'
fi

matchdir="$(staged_packages_resolve version 20260909120000)" || matchdir=""
if [[ -n $matchdir && -r "$matchdir/packages.txt" && -r "$matchdir/identity" ]]; then
    ok 'resolve returns the backing dir on identity match'
else
    fail 'resolve returns the backing dir on identity match'
fi
is "$(cat "$matchdir/packages.txt")" "$(cat "$fixtures/staged.packages.txt")" \
   'the sidecar packages.txt is the exact staged bytes'
is "$(cat "$matchdir/identity")" 'version=20260909120000' \
   'the identity file holds exactly version=<14-digit>'

# identity mismatch: a sidecar bound to one version must not be returned for a
# different expected version (a manual stage cannot inherit an old inventory).
if staged_packages_resolve version 20260101000000 >/dev/null 2>&1; then
    fail 'resolve rejects a version-identity mismatch'
else
    ok 'resolve rejects a version-identity mismatch'
fi

# cross-kind mismatch: a version sidecar must not resolve for a digest query.
if staged_packages_resolve digest "$digest" >/dev/null 2>&1; then
    fail 'resolve rejects a cross-kind (digest vs version) mismatch'
else
    ok 'resolve rejects a cross-kind (digest vs version) mismatch'
fi

# swap the published symlink to a bootc identity; resolve must follow the new
# generation and read its identity, not the previous one.
staged_packages_publish digest "$digest" "$fixtures/running.packages.txt" \
    && ok 'publish (bootc digest identity) swaps the live symlink' \
    || fail 'publish (bootc digest identity) swaps the live symlink'
newdir="$(staged_packages_resolve digest "$digest")" || newdir=""
is "$(cat "${newdir:-/dev/null}/identity" 2>/dev/null)" "digest=$digest" \
   'after the swap, resolve reads the new generation identity'

# --- static contract (source-level, both stagers + status CLI) -------------
#
# ADR-0014 pins these as source invariants so the two transport paths cannot
# drift (this subsystem's recurring failure mode).

bootc_stage="$root/mkosi.images/base/mkosi.extra/usr/libexec/bootc-update-stage"
native_stage="$root/shared/outformat/ab-root/tree/usr/libexec/snosi-sysupdate-stage"
status_cli="$root/mkosi.images/base/mkosi.extra/usr/bin/snosi-update-status"

# The bootc stager captures packages.txt BEFORE staging: the capture_pulled_packages
# call site must precede the first `bootc switch`/`bootc upgrade`.
cap_line="$(grep -nE '! pkg_temp="\$\(capture_pulled_packages' "$bootc_stage" | head -1 | cut -d: -f1)"
stage_line="$(grep -nE '^[[:space:]]*bootc (switch|upgrade)' "$bootc_stage" | head -1 | cut -d: -f1)"
if [[ -n $cap_line && -n $stage_line && $cap_line -lt $stage_line ]]; then
    ok 'bootc: packages.txt is captured before bootc switch/upgrade'
else
    fail 'bootc: packages.txt is captured before bootc switch/upgrade' \
        "capture line=${cap_line:-none}, first stage line=${stage_line:-none}"
fi

# The bootc already-staged (pulled==staged) branch publishes the sidecar (this
# is what repairs a post-switch publish failure), and the new-stage path does
# too: at least two publish_pkg_sidecar call sites.
if [[ "$(grep -c 'publish_pkg_sidecar ' "$bootc_stage")" -ge 2 ]]; then
    ok 'bootc: both the already-staged and new-stage paths publish the sidecar'
else
    fail 'bootc: both the already-staged and new-stage paths publish the sidecar'
fi

# Publish before prune: the last packages-sidecar publish precedes the last podman prune.
last_pub="$(grep -n 'publish_pkg_sidecar ' "$bootc_stage" | tail -1 | cut -d: -f1)"
last_prune="$(grep -n 'podman image prune' "$bootc_stage" | tail -1 | cut -d: -f1)"
if [[ -n $last_pub && -n $last_prune && $last_pub -lt $last_prune ]]; then
    ok 'bootc: the sidecar is published before the post-stage podman prune'
else
    fail 'bootc: the sidecar is published before the post-stage podman prune'
fi

# The native stager publishes/repairs the sidecar on the success path AND both
# re-assert branches: at least three publish_native_sidecar call sites.
if [[ "$(grep -c 'publish_native_sidecar ' "$native_stage")" -ge 3 ]]; then
    ok 'native: success and both re-assert paths publish the sidecar'
else
    fail 'native: success and both re-assert paths publish the sidecar'
fi

# Atomic swap lives in the ONE library, not re-inlined per stager: neither
# stager touches the published symlink name directly (the only permitted
# mention is the `staged-packages.sh` library path in the source line).
inlined="$(grep -hE 'staged-packages' "$bootc_stage" "$native_stage" | grep -vE 'staged-packages\.sh' || true)"
if [[ -n $inlined ]]; then
    fail 'the staged-packages symlink is owned by the library, not re-inlined in a stager' "$inlined"
else
    ok 'the staged-packages symlink is owned by the library, not re-inlined in a stager'
fi

# The library swaps a SYMLINK onto the live name (rename(2) of a file) and
# never `rm`s the live name first, nor `mv -T`s a directory onto it.
if grep -q 'mv -T "\$linktmp" "\$run_dir/staged-packages"' "$lib"; then
    ok 'library publishes by mv -T of a fresh symlink onto staged-packages'
else
    fail 'library publishes by mv -T of a fresh symlink onto staged-packages'
fi
if grep -qE 'rm .*"\$run_dir/staged-packages"' "$lib"; then
    fail 'library never rm-s the live staged-packages symlink before the swap'
else
    ok 'library never rm-s the live staged-packages symlink before the swap'
fi
if grep -q 'mv -T "\$tmpdir" "\$run_dir/staged-packages"' "$lib"; then
    fail 'library never mv -T-s a directory onto the live staged-packages name'
else
    ok 'library never mv -T-s a directory onto the live staged-packages name'
fi

# The status CLI never builds either side of the diff from the dpkg database.
if grep -qE 'dpkg-query|dpkg[[:space:]]+-l|apt[[:space:]]+list' "$status_cli"; then
    fail 'snosi-update-status does not use dpkg-query / dpkg -l / apt list'
else
    ok 'snosi-update-status does not use dpkg-query / dpkg -l / apt list'
fi

echo "1..$test_number"
[[ $failures -eq 0 ]] || { echo "# $failures failure(s)"; exit 1; }
