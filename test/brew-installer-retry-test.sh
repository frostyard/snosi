#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Root-free, network-free fixture for brew.chroot installer retries.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/shared/scripts/build/brew.chroot"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() {
    local description=$1 expected=$2 actual=$3
    if [[ "$actual" == "$expected" ]]; then pass "$description"; else fail "$description (got '$actual')"; fi
}
assert_absent() {
    local description=$1 path=$2
    if [[ ! -e "$path" ]]; then pass "$description"; else fail "$description ($path remains)"; fi
}

mkdir -p "$work/bin" "$work/src/shared/download"
cat >"$work/src/shared/download/verified-download.sh" <<'EOF'
verified_download() {
    cp "$FAKE_INSTALLER" "$2"
}
EOF
cat >"$work/bin/tar" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$TAR_ARGS"
while (($#)); do
    if [[ "$1" == "-cvf" ]]; then
        touch "$2"
        exit 0
    fi
    shift
done
exit 2
EOF
cat >"$work/bin/setfattr" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"$work/bin/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >>"$SLEEP_LOG"
EOF
chmod +x "$work/bin/"*

run_brew() {
    local fixture=$1 installer=$2
    mkdir -p "$fixture/dest" "$fixture/tmp"
    set +e
    OUT=$(env \
        PATH="$work/bin:$PATH" \
        SRCDIR="$work/src" \
        DESTDIR="$fixture/dest" \
        BREW_HOME="$fixture/home" \
        BREW_INSTALLER="$fixture/tmp/brew-install" \
        BREW_DOCKERENV="$fixture/tmp/dockerenv" \
        BREW_INSTALL_ATTEMPTS=3 \
        BREW_RETRY_DELAY=7 \
        FAKE_INSTALLER="$installer" \
        TAR_ARGS="$fixture/tar.args" \
        SLEEP_LOG="$fixture/sleep.log" \
        bash "$SCRIPT" 2>&1)
    RC=$?
    set -e
}

success="$work/success"
mkdir -p "$success"
cat >"$success/installer" <<EOF
count_file="$success/count"
count=\$((\$(cat "\$count_file" 2>/dev/null || echo 0) + 1))
printf '%s\n' "\$count" >"\$count_file"
if [[ -e "\$HOME/.linuxbrew/partial" ]]; then
    echo "dirty prefix reached retry" >&2
    exit 42
fi
mkdir -p "\$HOME/.linuxbrew"
if ((count < 3)); then
    touch "\$HOME/.linuxbrew/partial"
    exit 1
fi
touch "\$HOME/.linuxbrew/brew"
EOF
run_brew "$success" "$success/installer"
assert_eq 'transient installer failure is retried to success' 0 "$RC"
assert_eq 'installer succeeds on third attempt' 3 "$(cat "$success/count")"
assert_eq 'retry delay runs between attempts' $'7\n7' "$(cat "$success/sleep.log")"
[[ "$OUT" == *'attempt 1/3 failed'* && "$OUT" == *'attempt 2/3 failed'* ]] &&
    pass 'retry diagnostics identify failed attempts' ||
    fail 'retry diagnostics identify failed attempts'
[[ -f "$success/dest/usr/share/homebrew.tar.zst" ]] &&
    pass 'successful retry produces Homebrew archive' ||
    fail 'successful retry produces Homebrew archive'
[[ $(cat "$success/tar.args") == *"$success/home/.linuxbrew"* ]] &&
    pass 'archive reads successful clean prefix' ||
    fail 'archive reads successful clean prefix'
assert_absent 'successful run removes installer' "$success/tmp/brew-install"
assert_absent 'successful run removes dockerenv marker' "$success/tmp/dockerenv"
assert_absent 'successful run removes temporary Homebrew tree' "$success/home"

failure="$work/failure"
mkdir -p "$failure"
cat >"$failure/installer" <<EOF
count_file="$failure/count"
count=\$((\$(cat "\$count_file" 2>/dev/null || echo 0) + 1))
printf '%s\n' "\$count" >"\$count_file"
mkdir -p "\$HOME/.linuxbrew"
touch "\$HOME/.linuxbrew/partial"
exit 1
EOF
run_brew "$failure" "$failure/installer"
[[ $RC -ne 0 ]] && pass 'persistent installer failure remains fatal' || fail 'persistent installer failure remains fatal'
assert_eq 'persistent failure stops at retry budget' 3 "$(cat "$failure/count")"
[[ "$OUT" == *'failed after 3 attempts'* ]] &&
    pass 'exhausted retry budget reports final failure' ||
    fail 'exhausted retry budget reports final failure'
assert_absent 'failed run does not produce archive' "$failure/dest/usr/share/homebrew.tar.zst"
assert_absent 'failed run removes installer' "$failure/tmp/brew-install"
assert_absent 'failed run removes dockerenv marker' "$failure/tmp/dockerenv"
assert_absent 'failed run removes partial Homebrew tree' "$failure/home"

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
