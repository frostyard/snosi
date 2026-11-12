#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$ROOT_DIR/mkosi.images/1password/opt-links.sh"
postinst="$ROOT_DIR/mkosi.images/1password/mkosi.postinst.chroot"
finalize="$ROOT_DIR/mkosi.images/1password/mkosi.finalize"
required="$ROOT_DIR/mkosi.images/1password/required-paths.txt"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
lib="$work/usr/lib/1Password"
bin="$work/usr/bin"
mkdir -p "$lib" "$bin"
touch "$lib/1password" "$lib/1password-mcp" "$lib/op-ssh-sign"

# The 1Password deb postinst creates absolute links into /opt/1Password, which
# the relocation to /usr/lib/1Password leaves dangling.
ln -s /opt/1Password/1password-mcp "$bin/1password-mcp"
ln -s /opt/1Password/1password-mcp "$lib/onepassword-mcp"
ln -s /usr/lib/1Password/1password "$bin/1password"
ln -s /opt/other/app "$bin/other"

if "$script" check "$work"; then
    echo 'FAIL: stale /opt links passed validation' >&2; exit 1
fi
"$script" rewrite "$work"
"$script" check "$work"
for link in "$bin/1password-mcp" "$lib/onepassword-mcp"; do
    target="$(readlink "$link")"
    if [[ "$target" != /usr/lib/1Password/1password-mcp ]]; then
        echo "FAIL: $link still reads $target" >&2; exit 1
    fi
done
target="$(readlink "$bin/other")"
if [[ "$target" != /opt/other/app ]]; then
    echo "FAIL: unrelated link $bin/other was rewritten to $target" >&2; exit 1
fi

# A dangling link that names no /opt path must still fail the check.
rm "$lib/op-ssh-sign"
ln -s /usr/lib/1Password/op-ssh-sign "$bin/op-ssh-sign"
if "$script" check "$work"; then
    echo 'FAIL: dangling usr/bin link passed validation' >&2; exit 1
fi
rm "$bin/op-ssh-sign"
touch "$lib/op-ssh-sign"

# A dangling relative link inside the relocated tree must fail the check too.
ln -s missing "$lib/foo"
if "$script" check "$work"; then
    echo 'FAIL: dangling relative link passed validation' >&2; exit 1
fi
rm "$lib/foo"
"$script" check "$work"

# A root with no 1Password link (a wrong ROOT) must fail, not pass vacuously.
mkdir -p "$work/empty/usr/bin"
if "$script" check "$work/empty"; then
    echo 'FAIL: a root with no 1Password link passed validation' >&2; exit 1
fi

# Static wiring: the rewrite runs in the postinst after the /opt move and the
# check runs in the finalize script.
mv_line="$(grep -n '^mv /opt/1Password /usr/lib/1Password$' "$postinst" | head -1 | cut -d: -f1)" || true
# The matched text is literal shell source, not an expansion.
# shellcheck disable=SC2016
rewrite_re='^[[:space:]]*"\$SRCDIR/mkosi\.images/1password/opt-links\.sh" rewrite /$'
rewrite_line="$(grep -nE "$rewrite_re" "$postinst" | head -1 | cut -d: -f1)" || true
if [[ -z "$mv_line" || -z "$rewrite_line" ]]; then
    echo 'FAIL: mkosi.postinst.chroot does not run opt-links.sh rewrite after the move' >&2; exit 1
fi
if (( rewrite_line < mv_line )); then
    echo 'FAIL: mkosi.postinst.chroot runs opt-links.sh rewrite before the /opt move' >&2; exit 1
fi
# The matched text is literal shell source, not an expansion.
# shellcheck disable=SC2016
check_re='^[[:space:]]*"\$SRCDIR/mkosi\.images/1password/opt-links\.sh" check "\$BUILDROOT"$'
if ! grep -Eq "$check_re" "$finalize"; then
    echo 'FAIL: mkosi.finalize does not run opt-links.sh check' >&2; exit 1
fi
for path in /usr/bin/1password-mcp /usr/lib/1Password/1password-mcp; do
    if ! grep -Fxq "$path" "$required"; then
        echo "FAIL: required-paths.txt does not list $path" >&2; exit 1
    fi
done
echo '1password-links-test: PASSED'
