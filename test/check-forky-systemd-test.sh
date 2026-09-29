#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture test for the Forky systemd family sentinel:
# shared/download/check-forky-systemd.sh (driving the real
# latest-apt-version.sh through a PATH-stubbed curl), the committed
# shared/download/forky-versions.json, the recheck obligations its PR body
# names, and the check-packages.yml job that runs it. No root, no network.
# shellcheck disable=SC2016 # Assertions match literal Markdown and YAML text.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/shared/download/check-forky-systemd.sh"
HELPER="$ROOT_DIR/shared/download/latest-apt-version.sh"
SENTINEL="$ROOT_DIR/shared/download/forky-versions.json"
WORKFLOW="$ROOT_DIR/.github/workflows/check-packages.yml"
SOURCES_URL=https://deb.debian.org/debian/dists/forky/main/source/Sources.gz
VERSION_RE='^([0-9]+:)?[0-9][A-Za-z0-9.+~-]*$'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

cat >"$work/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$MOCK_CURL_ARGS"
cat "$MOCK_CURL_PAYLOAD"
exit "${MOCK_CURL_STATUS:-0}"
EOF
chmod +x "$work/bin/curl"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { # description command...
    local description=$1
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}
contains() { [[ $1 == *"$2"* ]]; }
is_debian_version() { [[ $1 =~ $VERSION_RE ]]; }
selects_forky_family() { # conf
    grep -qE '^[[:space:]]*(Packages=)?[[:space:]]*systemd/forky[[:space:]]*$' "$1" &&
        grep -qE '^[[:space:]]*udev/forky[[:space:]]*$' "$1"
}

# A Sources index in the real stanza shape: a multi-line Binary field, a
# Package-List whose continuation lines name systemd, and neighbouring source
# packages whose names contain "systemd" with larger versions.
make_sources() { # systemd-version -> $work/Sources.gz
    cat >"$work/Sources" <<EOF
Package: python-systemd
Binary: python3-systemd
Version: 999-1

Package: systemd
Binary: libnss-myhostname, libnss-mymachines, libnss-systemd, libpam-systemd,
 libsystemd-shared, libsystemd0, libudev1, systemd, systemd-boot,
 systemd-cryptsetup, systemd-tpm, systemd-ukify, udev
Version: $1
Maintainer: Debian systemd Maintainers <pkg-systemd-maintainers@lists.alioth.debian.org>
Package-List:
 systemd deb admin important arch=linux-any
 udev deb admin important arch=linux-any

Package: systemd-cron
Version: 1000-1
EOF
    gzip -c "$work/Sources" >"$work/Sources.gz"
}

# run_check sentinel-json -> sets status/output; leaves the sentinel at
# $work/forky-versions.json, outputs at $work/github-output, body at
# $work/body.md.
run_check() {
    printf '%s\n' "$1" >"$work/forky-versions.json"
    cp "$work/forky-versions.json" "$work/sentinel.before"
    rm -f "$work/body.md" "$work/curl.args"
    : >"$work/github-output"
    set +e
    output=$(FORKY_VERSIONS_FILE="$work/forky-versions.json" \
        GITHUB_OUTPUT="$work/github-output" "$SCRIPT" "$work/body.md" 2>&1)
    status=$?
    set -e
}
sentinel_version() { jq -r '.systemd' "$work/forky-versions.json"; }
sentinel_unchanged() { cmp -s "$work/sentinel.before" "$work/forky-versions.json"; }
output_has() { grep -qxF "$1" "$work/github-output"; }
body_has() { grep -qF -- "$1" "$work/body.md"; }

export PATH="$work/bin:$PATH"
export MOCK_CURL_PAYLOAD="$work/Sources.gz"
export MOCK_CURL_ARGS="$work/curl.args"

# --- A newer Forky version rewrites the sentinel and writes the PR body.
make_sources 262-1
run_check '{"systemd": "261.2-1", "other": "kept"}'
check 'a newer Forky systemd succeeds' test "$status" -eq 0
check 'has_update=true is emitted' output_has 'has_update=true'
check 'previous acknowledged version is emitted' output_has 'previous=261.2-1'
check 'latest Forky version is emitted' output_has 'latest=262-1'
check 'sentinel records the new version' test "$(sentinel_version)" = 262-1
check 'sentinel keeps unrelated keys' test "$(jq -r '.other' "$work/forky-versions.json")" = kept
check 'neighbouring source packages are not mistaken for systemd' \
    test "$(sentinel_version)" != 999-1
args=$(cat "$work/curl.args")
check 'the Forky main Sources index is fetched' contains "$args" "$SOURCES_URL"
check 'curl keeps the 60-second transfer limit' contains "$args" '--max-time 60'
check 'curl keeps the 50 MiB compressed-size limit' contains "$args" '--max-filesize 52428800'

check 'PR body states the version change' body_has '**261.2-1 -> 262-1**'
check 'PR body names the Task 4 bwrap build/root check' body_has '**Bootc secure composition (Task 4): bwrap build/root check.**'
check 'PR body names bootc --version and bootc container --help' \
    body_has '`bootc --version` and `bootc container --help`'
check 'PR body asks for the Task 4 "Last repeated" record' body_has '"Last repeated" entry in AGENTS.md'
check 'PR body names the Issue 517 dracut drop-in re-check' body_has '**Issue 517: dracut gpt-auto udev drop-in.**'
check 'PR body names 90-image-dissect.rules' body_has '/usr/lib/udev/rules.d/90-image-dissect.rules'
check 'PR body names the NvPCR mask re-check' body_has '**NvPCR masks.**'
check 'PR body names the bootc NvPCR finalize' body_has '`shared/bootc-secure/finalize/disable-nvpcr.chroot`'
check 'PR body names the native NvPCR finalize' body_has '`shared/native-ab-secure/finalize/disable-nvpcr.chroot`'
check 'PR body gives the systemd 262 NvPCR reason' body_has '`ukify --sign-initrd-pcrs` initrd policy'
check 'PR body lists exactly three recheck items' test "$(grep -c '^- \[ \] ' "$work/body.md")" -eq 3
check 'PR body links the new changelog' \
    body_has 'https://metadata.ftp-master.debian.org/changelogs/main/s/systemd/systemd_262-1_changelog'

# Every repository path the body names must exist, so a moved file cannot
# leave the PR pointing reviewers at nothing.
missing=""
while IFS= read -r path; do
    [[ -e "$ROOT_DIR/$path" ]] || missing="$missing $path"
done < <(grep -oE '`(shared|test|mkosi\.profiles)/[^`]+`' "$work/body.md" | tr -d '`' | sort -u)
check "every repository path in the PR body exists${missing:+ (missing:$missing)}" test -z "$missing"
cp "$work/body.md" "$work/generated-body.md"

# --- Same version: nothing changes and no PR body is written.
run_check '{"systemd": "262-1"}'
check 'an unchanged Forky systemd succeeds' test "$status" -eq 0
check 'unchanged: has_update=false' output_has 'has_update=false'
check 'unchanged: sentinel is byte-identical' sentinel_unchanged
check 'unchanged: no PR body is written' test ! -e "$work/body.md"

# --- An older reading is a stale CDN backend, never a downgrade PR.
make_sources 261.2-1
run_check '{"systemd": "262-1"}'
check 'a stale mirror reading succeeds' test "$status" -eq 0
check 'stale mirror: has_update=false' output_has 'has_update=false'
check 'stale mirror: a workflow warning is printed' contains "$output" '::warning::'
check 'stale mirror: sentinel is byte-identical' sentinel_unchanged
check 'stale mirror: no PR body is written' test ! -e "$work/body.md"

# --- Ordering is Debian's, not lexical.
make_sources 261.10-1
run_check '{"systemd": "261.9-1"}'
check 'dpkg ordering: 261.10-1 is newer than 261.9-1' output_has 'has_update=true'
make_sources 262-1
run_check '{"systemd": "262~rc3-1"}'
check 'dpkg ordering: 262-1 is newer than 262~rc3-1' output_has 'has_update=true'
make_sources 1:263-1
run_check '{"systemd": "262-1"}'
check 'an epoch version is accepted' output_has 'latest=1:263-1'
check 'the changelog URL drops the epoch' \
    body_has 'https://metadata.ftp-master.debian.org/changelogs/main/s/systemd/systemd_263-1_changelog'

# --- Fail closed: no output, sentinel untouched, no PR body.
assert_fails_closed() { # description expected-message
    check "$1: exits non-zero" test "$status" -ne 0
    check "$1: reports '$2'" contains "$output" "$2"
    check "$1: sentinel is byte-identical" sentinel_unchanged
    check "$1: no PR body is written" test ! -e "$work/body.md"
    check "$1: no step outputs are emitted" test ! -s "$work/github-output"
}

make_sources 262-1
export MOCK_CURL_STATUS=28
run_check '{"systemd": "261.2-1"}'
assert_fails_closed 'a failed download' 'failed to download bounded APT index'
unset MOCK_CURL_STATUS

sed '/^Package: systemd$/,/^$/d' "$work/Sources" | gzip -c >"$work/Sources.gz"
run_check '{"systemd": "261.2-1"}'
assert_fails_closed 'systemd missing from Forky' 'no version found for systemd'

make_sources '262-1;touch'
run_check '{"systemd": "261.2-1"}'
assert_fails_closed 'a non-Debian served version' 'non-Debian systemd version'

make_sources 262-1
run_check '{}'
assert_fails_closed 'a sentinel without .systemd' 'has no string .systemd version'
run_check '{"systemd": 262}'
assert_fails_closed 'a non-string sentinel version' 'has no string .systemd version'
run_check '{"systemd": "not a version"}'
assert_fails_closed 'a malformed sentinel version' 'is not a Debian version'

set +e
"$SCRIPT" >/dev/null 2>&1
usage_status=$?
set -e
check 'missing PR body argument is a usage error' test "$usage_status" -eq 2

# --- Forky's real index is over the helper's 50 MiB decompressed default
# (~60 MiB on 2026-09-29); the script's raised cap must admit it.
{
    cat "$work/Sources"
    printf '\nPackage: padding\nVersion: 0-1\nChecksums-Sha256:\n'
    # Process substitution: yes's SIGPIPE must not trip pipefail.
    head -c 54525952 < <(yes ' 0000000000000000000000000000000000000000000000000000000000000000 1234 padding_0-1.dsc')
} | gzip -1 >"$work/Sources.gz"
set +e
default_output=$("$HELPER" "$SOURCES_URL" systemd 2>&1)
default_status=$?
set -e
check 'the large fixture fails under the helper default cap' test "$default_status" -ne 0
check 'the large fixture exceeds the 50 MiB decompressed default' \
    contains "$default_output" 'decompressed APT index exceeds 52428800 bytes'
run_check '{"systemd": "261.2-1"}'
check 'a >50 MiB Forky Sources index is accepted' output_has 'latest=262-1'

# --- The committed sentinel.
check 'committed forky-versions.json holds only .systemd' \
    test "$(jq -c 'keys' "$SENTINEL")" = '["systemd"]'
committed=$(jq -r '.systemd' "$SENTINEL")
check "committed Forky systemd version is a Debian version ($committed)" \
    is_debian_version "$committed"

# --- The sentinel must cover every composition that selects systemd/forky,
# and every composition the body names must still select it. Derived, not
# listed, so a new Forky consumer cannot go unmentioned.
mapfile -t consumers < <(cd "$ROOT_DIR" &&
    grep -rlE '^[[:space:]]*(Packages=)?[[:space:]]*systemd/forky[[:space:]]*$' \
        --include='*.conf' shared mkosi.profiles mkosi.images | sort)
check 'at least one composition selects systemd/forky' test "${#consumers[@]}" -gt 0
for conf in "${consumers[@]}"; do
    check "PR body names Forky consumer $conf" grep -qF "\`$conf\`" "$work/generated-body.md"
done
while IFS= read -r conf; do
    check "$conf still selects systemd/forky and udev/forky" \
        selects_forky_family "$ROOT_DIR/$conf"
done < <(grep -oE '`[^`]*/mkosi\.conf`' "$work/generated-body.md" | tr -d '`' | sort -u)

# --- The AGENTS.md obligations the body cites still exist under these names.
agents="$ROOT_DIR/AGENTS.md"
check 'AGENTS.md keeps the Task 4 bootc secure composition section' grep -qF '**Bootc secure composition (Task 4' "$agents"
check 'AGENTS.md keeps the Task 4 build/root recheck rule' grep -qF 'Repeat that build/root check when either the' "$agents"
check 'AGENTS.md keeps the Task 4 "Last repeated" record' grep -qF '**Last repeated' "$agents"
check 'AGENTS.md keeps the Issue 517 section' grep -qF '**Issue 517' "$agents"
check 'AGENTS.md documents the Forky systemd sentinel' grep -qF 'shared/download/forky-versions.json' "$agents"

# --- check-packages.yml job wiring: token scope, timeout, PR plumbing.
job=$(awk '
    $0 == "  check-forky-systemd:" { in_job = 1; print; next }
    in_job && /^  [[:alnum:]_-]+:$/ { exit }
    in_job { print }
' "$WORKFLOW")
job_has() { grep -qxF -- "$1" <<<"$job"; }
check 'check-packages.yml keeps empty workflow-level permissions' grep -qx 'permissions: {}' "$WORKFLOW"
check 'check-forky-systemd job exists' test -n "$job"
check 'job has the 15-minute token-lifetime bound' job_has '    timeout-minutes: 15'
permissions=$(awk '
    $0 == "    permissions:" { in_perm = 1; next }
    in_perm && /^      [[:alnum:]_-]+:/ { print; next }
    in_perm { exit }
' <<<"$job")
check 'job token is exactly contents+pull-requests write' \
    test "$permissions" = $'      contents: write\n      pull-requests: write'
check 'checkout does not persist credentials' job_has '          persist-credentials: false'
check 'job runs the script with a RUNNER_TEMP PR body' \
    job_has '        run: ./shared/download/check-forky-systemd.sh "$RUNNER_TEMP/forky-systemd-pr-body.md"'
check 'PR step is gated on has_update' job_has "        if: steps.forky.outputs.has_update == 'true'"
check 'PR commits only the sentinel' job_has '          add-paths: shared/download/forky-versions.json'
check 'PR body comes from the generated file' \
    job_has '          body-path: ${{ runner.temp }}/forky-systemd-pr-body.md'
check 'PR uses a dedicated branch' job_has '          branch: auto-update-forky-systemd'

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
