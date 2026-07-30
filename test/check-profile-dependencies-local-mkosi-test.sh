#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/check-profile-dependencies-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

cp "$repo_root/check-profile-dependencies.sh" "$scratch/"
mkdir -p "$scratch/.mkosi/bin" "$scratch/path"

cat >"$scratch/.mkosi/bin/mkosi" <<'EOF'
#!/bin/bash
if [[ "$*" == *"summary"* ]]; then
    printf 'IMAGE: base\n'
fi
EOF
chmod +x "$scratch/.mkosi/bin/mkosi"

cat >"$scratch/path/mkosi" <<'EOF'
#!/bin/bash
echo 'PATH mkosi was used instead of the local checkout' >&2
exit 1
EOF
chmod +x "$scratch/path/mkosi"

PATH="$scratch/path:$PATH" "$scratch/check-profile-dependencies.sh" \
    | grep -qx 'Profile builds depend only on base.'

printf 'check-profile-dependencies-local-mkosi-test: PASSED\n'
