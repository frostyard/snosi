#!/bin/bash
# Base images compile the shipped xterm-ghostty terminfo source into /usr.
set -euo pipefail
cd "$(dirname "$0")/.."
src=mkosi.images/base/mkosi.extra/usr/share/snosi/terminfo/xterm-ghostty.src
post=mkosi.images/base/mkosi.postinst.chroot
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$src" ] || fail "$src missing"
grep -q '^xterm-ghostty|' "$src" || fail "$src does not define xterm-ghostty"
# g/ghostty belongs to Debian ncurses-term; do not shadow it.
grep -Eq '^xterm-ghostty\|[^,]*\|' "$src" && fail "$src declares extra aliases"
grep -Fqx 'tic -x -o /usr/share/terminfo /usr/share/snosi/terminfo/xterm-ghostty.src' "$post" \
  || fail "$post does not compile the ghostty terminfo"
if command -v tic >/dev/null 2>&1; then
  out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
  tic -x -o "$out" "$src" 2>/dev/null || fail "tic rejects $src"
  [ -f "$out/x/xterm-ghostty" ] || fail "tic did not produce x/xterm-ghostty"
  [ "$(TERM=xterm-ghostty TERMINFO="$out" tput colors)" = 256 ] || fail "compiled entry lacks 256 colors"
fi
echo "PASS: ghostty terminfo"
