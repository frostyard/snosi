#!/bin/bash
# Fixture coverage for shared/sysext/publish/drop-published.sh, the build.yml
# step that removes built sysexts whose identity ext/<name>/SHA256SUMS in R2
# already lists, so repogen v0.7.0 never sees a rebuilt published identity.
#
# A fake `aws` on PATH serves a local ext/ tree for the one `s3 sync` call
# the script makes, so the real code path runs. No network, root or build.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/shared/sysext/publish/drop-published.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

test_number=0
failures=0

ok() {
    local name=$1
    shift
    test_number=$((test_number + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$test_number" "$name"
    else
        printf 'not ok %d - %s\n' "$test_number" "$name"
        failures=$((failures + 1))
    fi
}

is_file() { [[ -f $1 ]]; }
not_exists() { [[ ! -e $1 ]]; }
contains() { [[ $1 == *"$2"* ]]; }

# Fake aws: `aws s3 sync s3://BUCKET/ext DEST --endpoint-url URL --exclude '*'
# --include '*/SHA256SUMS' ...` copies every */SHA256SUMS of $FAKE_R2/BUCKET/ext
# into DEST. $FAKE_AWS_FAIL makes it fail like a listing error. Each call's
# arguments are logged to $FAKE_AWS_LOG.
mkdir -p "$work/bin"
cat >"$work/bin/aws" <<'FAKE'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_AWS_LOG"
[[ -z ${FAKE_AWS_FAIL:-} ]] || { echo "fatal error: An error occurred (AccessDenied)" >&2; exit 1; }
[[ $1 == s3 && $2 == sync ]] || { echo "fake aws: unexpected call: $*" >&2; exit 2; }
src=${3#s3://}
dest=$4
mkdir -p "$dest"
[[ -d $FAKE_R2/$src ]] || exit 0
(cd "$FAKE_R2/$src" && find . -mindepth 2 -maxdepth 2 -type f -name SHA256SUMS) |
    while read -r rel; do
        mkdir -p "$dest/$(dirname "$rel")"
        cp "$FAKE_R2/$src/$rel" "$dest/$rel"
    done
FAKE
chmod +x "$work/bin/aws"

export PATH="$work/bin:$PATH"
export FAKE_R2="$work/r2"
export FAKE_AWS_LOG="$work/aws.log"
export R2_ACCOUNT_ID=acct R2_BUCKET=bucket
export AWS_ACCESS_KEY_ID=key AWS_SECRET_ACCESS_KEY=secret
export RUNNER_TEMP="$work"

digest=$(printf '%064d' 0)
publish() { # publish NAME FILENAME...: list FILENAMEs in ext/NAME/SHA256SUMS
    local name=$1 file
    shift
    mkdir -p "$FAKE_R2/bucket/ext/$name"
    for file in "$@"; do
        printf '%s  %s\n' "$digest" "$file" >>"$FAKE_R2/bucket/ext/$name/SHA256SUMS"
    done
}

printf '1..18\n'

# Published state: docker 1.0 as .raw.zst, incus 6.0 as plain .raw, a
# signature that must never be fetched, and an unrelated payload object.
publish docker docker_1.0_13_x86-64.raw.zst
publish incus incus_6.0_13_x86-64.raw
: >"$FAKE_R2/bucket/ext/docker/SHA256SUMS.gpg"
: >"$FAKE_R2/bucket/ext/docker/docker_1.0_13_x86-64.raw.zst"

out="$work/out/sysexts"
mkdir -p "$out"
for f in docker_1.0_13_x86-64.raw.zst docker_1.1_13_x86-64.raw.zst \
    incus_6.0_13_x86-64.raw.zst nix_2.0_13_x86-64.raw.zst docker_1.0_13_arm64.raw.zst; do
    printf 'payload' >"$out/$f"
done
: >"$out/notes.txt"
: >"$work/gh-output"
log=$(GITHUB_OUTPUT="$work/gh-output" "$script" "$out" 2>&1)

ok "drops an identity published with the same filename" \
    not_exists "$out/docker_1.0_13_x86-64.raw.zst"
ok "drops an identity published as .raw when rebuilt as .raw.zst" \
    not_exists "$out/incus_6.0_13_x86-64.raw.zst"
ok "keeps a new version of a published sysext" \
    is_file "$out/docker_1.1_13_x86-64.raw.zst"
ok "keeps a sysext with no SHA256SUMS in R2" \
    is_file "$out/nix_2.0_13_x86-64.raw.zst"
ok "keeps the same version for another architecture" \
    is_file "$out/docker_1.0_13_arm64.raw.zst"
ok "leaves non-payload files alone" is_file "$out/notes.txt"
ok "reports publish=true when payloads remain" \
    grep -qx 'publish=true' "$work/gh-output"
ok "reports the remaining payload count" \
    grep -qx 'remaining=3' "$work/gh-output"
ok "logs the summary" contains "$log" "5 built, 2 already published, 3 to publish"
ok "reads R2 through the account endpoint, not the CDN" \
    grep -q 'sync s3://bucket/ext .* --endpoint-url https://acct.r2.cloudflarestorage.com' "$FAKE_AWS_LOG"
ok "fetches only SHA256SUMS objects" \
    grep -q -- "--exclude \* --include \*/SHA256SUMS" "$FAKE_AWS_LOG"

# Everything already published: nothing remains, the publish step must skip.
rm -rf "$out" && mkdir -p "$out"
printf 'payload' >"$out/docker_1.0_13_x86-64.raw.zst"
: >"$work/gh-output"
GITHUB_OUTPUT="$work/gh-output" "$script" "$out" >/dev/null 2>&1
ok "reports publish=false when every identity is published" \
    grep -qx 'publish=false' "$work/gh-output"
ok "reports remaining=0 when every identity is published" \
    grep -qx 'remaining=0' "$work/gh-output"

# An empty bucket (first publish) keeps everything.
rm -rf "$out" && mkdir -p "$out"
printf 'payload' >"$out/docker_1.0_13_x86-64.raw.zst"
: >"$work/gh-output"
GITHUB_OUTPUT="$work/gh-output" R2_BUCKET=empty "$script" "$out" >/dev/null 2>&1
ok "keeps every payload when R2 has no ext/ prefix" \
    is_file "$out/docker_1.0_13_x86-64.raw.zst"

# Fail closed: a read error from R2 must stop the step and drop nothing.
status=0
FAKE_AWS_FAIL=1 "$script" "$out" >/dev/null 2>&1 || status=$?
ok "fails when R2 cannot be read" test "$status" -ne 0
ok "drops nothing when R2 cannot be read" \
    is_file "$out/docker_1.0_13_x86-64.raw.zst"

# No built payloads is a build fault, not a no-op.
mkdir -p "$work/empty"
status=0
"$script" "$work/empty" >/dev/null 2>&1 || status=$?
ok "fails when the build produced no payloads" test "$status" -ne 0

# Missing credentials fail before any R2 call.
status=0
: >"$FAKE_AWS_LOG"
env -u AWS_SECRET_ACCESS_KEY "$script" "$out" >/dev/null 2>&1 || status=$?
ok "fails without the R2 secret and makes no R2 call" \
    test "$status" -ne 0 -a ! -s "$FAKE_AWS_LOG"

if ((failures > 0)); then
    printf '# %d of %d failed\n' "$failures" "$test_number" >&2
    exit 1
fi
