#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/check-profile-dependencies-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

cp "$repo_root/check-profile-dependencies.sh" "$scratch/"

# The guard discovers its inputs from the repo layout rather than hardcoded
# lists, so the fixture reproduces that layout in miniature: one bootc image
# profile (composes shared/bootc-secure/mkosi.conf, so it is discovered) plus a
# native A/B profile that must NOT be discovered, and two sysext images plus the
# base OS image that must NOT be treated as a sysext.
mkdir -p "$scratch/mkosi.profiles/cayo" \
         "$scratch/mkosi.profiles/cayo-ab" \
         "$scratch/mkosi.images/base" \
         "$scratch/mkosi.images/dev" \
         "$scratch/mkosi.images/chatgpt"

cat >"$scratch/mkosi.profiles/cayo/mkosi.conf" <<'EOF'
[Include]
Include=%D/shared/bootc-secure/mkosi.conf
EOF
cat >"$scratch/mkosi.profiles/cayo-ab/mkosi.conf" <<'EOF'
[Include]
Include=%D/shared/native-ab-secure/mkosi.conf
EOF
printf '[Output]\nFormat=directory\n' >"$scratch/mkosi.images/base/mkosi.conf"
printf '[Output]\nFormat=sysext\n' >"$scratch/mkosi.images/dev/mkosi.conf"
printf '[Output]\nFormat=sysext\n' >"$scratch/mkosi.images/chatgpt/mkosi.conf"

mkdir -p "$scratch/.mkosi/bin" "$scratch/path"
cat >"$scratch/path/mkosi" <<'EOF'
#!/bin/bash
echo 'PATH mkosi was used instead of the local checkout' >&2
exit 1
EOF
chmod +x "$scratch/path/mkosi"

# Positive case: every discovered profile depends only on base, so the guard
# must succeed. The stub also asserts it is only ever invoked for the discovered
# bootc image profile (cayo) and never for the excluded native A/B profile.
cat >"$scratch/.mkosi/bin/mkosi" <<'EOF'
#!/bin/bash
prev=""
profile=""
for arg in "$@"; do
    if [[ "$prev" == "--profile" ]]; then profile="$arg"; fi
    prev="$arg"
done
if [[ "$profile" == "cayo-ab" ]]; then
    echo "guard discovered an excluded native A/B profile: $profile" >&2
    exit 1
fi
if [[ "$*" == *"summary"* ]]; then
    printf 'IMAGE: base\n'
fi
EOF
chmod +x "$scratch/.mkosi/bin/mkosi"

PATH="$scratch/path:$PATH" "$scratch/check-profile-dependencies.sh" \
    | grep -qx 'Profile builds depend only on base.'

# Negative case: a profile summary that pulls in a discovered sysext (chatgpt,
# which is intentionally absent from the old hardcoded list) must be detected
# and fail the guard. This proves discovery -- not a stale hardcoded list --
# drives the check.
cat >"$scratch/.mkosi/bin/mkosi" <<'EOF'
#!/bin/bash
if [[ "$*" == *"summary"* ]]; then
    printf 'IMAGE: base\nIMAGE: chatgpt\n'
fi
EOF
chmod +x "$scratch/.mkosi/bin/mkosi"

if PATH="$scratch/path:$PATH" "$scratch/check-profile-dependencies.sh" \
        >"$scratch/neg.out" 2>"$scratch/neg.err"; then
    echo 'check-profile-dependencies-local-mkosi-test: FAILED -- guard passed while a profile pulled in a sysext' >&2
    exit 1
fi
grep -q 'unexpectedly includes sysext dependency chatgpt' "$scratch/neg.err" \
    || { echo 'check-profile-dependencies-local-mkosi-test: FAILED -- missing drift diagnostic' >&2; exit 1; }

printf 'check-profile-dependencies-local-mkosi-test: PASSED\n'
