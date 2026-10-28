#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture suite for shared/download/verify-attestations.sh and its build.yml
# wiring (ADR-0024). A stub `gh` (GH=) and file:// URLs stand in for GitHub:
# no network, no root, no image build.
# The greps below match literal GitHub expressions and shell text, not expansions.
# shellcheck disable=SC2016
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/shared/download/verify-attestations.sh"
BUILD_WORKFLOW="$ROOT_DIR/.github/workflows/build.yml"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

work=$(mktemp -d "${TMPDIR:-/tmp}/verify-attestations-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

printf 'alpha payload\n' >"$work/alpha.deb"
printf 'beta payload\n' >"$work/beta.deb"
printf 'gamma payload\n' >"$work/gamma.deb"
alpha_sha=$(sha256sum "$work/alpha.deb" | cut -d' ' -f1)
beta_sha=$(sha256sum "$work/beta.deb" | cut -d' ' -f1)
gamma_sha=$(sha256sum "$work/gamma.deb" | cut -d' ' -f1)

# The stub records its arguments, one call per line, and exits with
# $STUB_GH_EXIT (default 0). It never reads GH_TOKEN.
cat >"$work/gh" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >>"${STUB_GH_LOG:?}"
exit "${STUB_GH_EXIT:-0}"
EOS
chmod +x "$work/gh"

write_checksums() {
    local file=$1 beta_hash=${2:-$beta_sha}
    cat >"$file" <<EOS
{
  "alpha": {
    "url": "file://$work/alpha.deb",
    "sha256": "$alpha_sha",
    "version": "1.2.3",
    "attestation": {"repository": "example/alpha-repo", "signer_workflow": ".github/workflows/release.yml"}
  },
  "beta": {
    "url": "file://$work/beta.deb",
    "sha256": "$beta_hash",
    "version": "4.5.6",
    "attestation": {"repository": "example/beta-repo", "signer_workflow": ".github/workflows/publish.yml"}
  },
  "gamma": {
    "url": "file://$work/gamma.deb",
    "sha256": "$gamma_sha",
    "version": "7.8.9"
  }
}
EOS
}

# run_script <checksums-file> [args...]: sets rc and out; the stub's calls are
# in $work/gh.log.
run_script() {
    local checksums=$1
    shift
    : >"$work/gh.log"
    rc=0
    out=$(CHECKSUMS_FILE="$checksums" GH="$work/gh" STUB_GH_LOG="$work/gh.log" \
        "$SCRIPT" "$@" 2>&1) || rc=$?
}

write_checksums "$work/good.json"

# 1. Pass: every attested key is verified, and the unattested key is skipped.
run_script "$work/good.json"
if [[ $rc -eq 0 && $(wc -l <"$work/gh.log") -eq 2 ]] &&
    grep -Fq 'OK alpha' <<<"$out" && grep -Fq 'OK beta' <<<"$out" &&
    ! grep -Fq gamma <<<"$out" && ! grep -Fq gamma "$work/gh.log"; then
    pass 'no KEY verifies every attested key and skips the others'
else
    fail 'no KEY verifies every attested key and skips the others'
    printf '%s\n' "$out" >&2
fi

# 2. Exact gh arguments (the file is a temporary download of the pinned bytes).
if grep -Eqx "attestation verify [^ ]+/alpha\.deb --repo example/alpha-repo --signer-workflow example/alpha-repo/\.github/workflows/release\.yml --source-ref refs/tags/v1\.2\.3 --deny-self-hosted-runners" "$work/gh.log" &&
    grep -Eqx "attestation verify [^ ]+/beta\.deb --repo example/beta-repo --signer-workflow example/beta-repo/\.github/workflows/publish\.yml --source-ref refs/tags/v4\.5\.6 --deny-self-hosted-runners" "$work/gh.log"; then
    pass 'gh gets --repo, --signer-workflow, --source-ref and --deny-self-hosted-runners'
else
    fail 'gh gets --repo, --signer-workflow, --source-ref and --deny-self-hosted-runners'
    cat "$work/gh.log" >&2
fi

# 3. A named key checks only that key.
run_script "$work/good.json" beta
if [[ $rc -eq 0 && $(wc -l <"$work/gh.log") -eq 1 ]] && grep -Fq 'example/beta-repo' "$work/gh.log"; then
    pass 'a named key verifies only that key'
else
    fail 'a named key verifies only that key'
fi

# 4. A failing gh fails the script, for every key, and it names the key.
rc=0
: >"$work/gh.log"
out=$(CHECKSUMS_FILE="$work/good.json" GH="$work/gh" STUB_GH_LOG="$work/gh.log" STUB_GH_EXIT=1 \
    "$SCRIPT" 2>&1) || rc=$?
if [[ $rc -ne 0 && $(wc -l <"$work/gh.log") -eq 2 ]] &&
    grep -Fq 'FAIL alpha' <<<"$out" && grep -Fq 'FAIL beta' <<<"$out" &&
    ! grep -Fq 'OK ' <<<"$out"; then
    pass 'a failed gh verify exits non-zero after trying every key'
else
    fail 'a failed gh verify exits non-zero after trying every key'
    printf '%s\n' "$out" >&2
fi

# 5. A SHA-256 mismatch fails before gh runs for that key.
write_checksums "$work/badsha.json" "$(printf '%064d' 0)"
run_script "$work/badsha.json"
if [[ $rc -ne 0 ]] && grep -Fq 'FAIL beta' <<<"$out" && grep -Fq 'OK alpha' <<<"$out" &&
    [[ $(wc -l <"$work/gh.log") -eq 1 ]] && ! grep -Fq beta-repo "$work/gh.log"; then
    pass 'a SHA-256 mismatch fails and gh is not run for that key'
else
    fail 'a SHA-256 mismatch fails and gh is not run for that key'
    printf '%s\n' "$out" >&2
fi

# 6. A failed download fails.
jq '.beta.url = "file:///nonexistent/beta.deb"' "$work/good.json" >"$work/nodl.json"
run_script "$work/nodl.json" beta
if [[ $rc -ne 0 && ! -s "$work/gh.log" ]] && grep -Fq 'FAIL beta' <<<"$out"; then
    pass 'a failed download fails and gh is not run'
else
    fail 'a failed download fails and gh is not run'
fi

# 7. A named key without attestation metadata fails closed (and an unknown key).
run_script "$work/good.json" gamma
if [[ $rc -ne 0 && ! -s "$work/gh.log" ]] && grep -Fq 'FAIL gamma' <<<"$out"; then
    pass 'a named key without attestation metadata fails'
else
    fail 'a named key without attestation metadata fails'
fi
run_script "$work/good.json" no-such-key
if [[ $rc -ne 0 && ! -s "$work/gh.log" ]]; then
    pass 'an unknown named key fails'
else
    fail 'an unknown named key fails'
fi

# 8. A missing metadata field fails; one good key does not hide a bad one.
jq 'del(.alpha.attestation.signer_workflow)' "$work/good.json" >"$work/nofield.json"
run_script "$work/nofield.json"
if [[ $rc -ne 0 ]] && grep -Fq 'FAIL alpha' <<<"$out" && grep -Fq 'OK beta' <<<"$out"; then
    pass 'a missing attestation field fails'
else
    fail 'a missing attestation field fails'
fi
jq 'del(.alpha.version)' "$work/good.json" >"$work/nover.json"
run_script "$work/nover.json" alpha
if [[ $rc -ne 0 && ! -s "$work/gh.log" ]]; then
    pass 'a missing version fails'
else
    fail 'a missing version fails'
fi

# 9. No attested key at all fails (an empty selection never passes).
jq 'del(.alpha.attestation, .beta.attestation)' "$work/good.json" >"$work/none.json"
run_script "$work/none.json"
if [[ $rc -ne 0 && ! -s "$work/gh.log" ]]; then
    pass 'no key with attestation metadata fails'
else
    fail 'no key with attestation metadata fails'
fi

# 9b. Key names are plain names. A JSON key with a newline must not split into
# 2 list items (that once made the script re-check `notesd` and `maild` and
# never check the crafted entry), and a bad explicit argument must fail before
# any file path is built from it.
jq '. + {"notesd\nmaild": {"attestation": {}}}' "$work/good.json" >"$work/nlkey.json"
jq -e 'keys | map(select(contains("\n"))) | length == 1' "$work/nlkey.json" >/dev/null
run_script "$work/nlkey.json"
if [[ $rc -ne 0 ]] && grep -Fq 'invalid key names' <<<"$out" && grep -Fq 'notesd\nmaild' <<<"$out" &&
    grep -Fq 'OK alpha' <<<"$out" && grep -Fq 'OK beta' <<<"$out"; then
    pass 'an attested entry whose key has a newline fails the run'
else
    fail 'an attested entry whose key has a newline fails the run'
    printf '%s\n' "$out" >&2
fi
# The same entry with a valid key name next to the good pins would pass.
jq '. + {"delta": {"attestation": {}}}' "$work/good.json" >"$work/emptyatt.json"
run_script "$work/emptyatt.json"
if [[ $rc -ne 0 ]] && grep -Fq 'FAIL delta' <<<"$out"; then
    pass 'an attested entry with empty metadata fails by name'
else
    fail 'an attested entry with empty metadata fails by name'
fi
for bad_key in '../x' 'a/b' 'a b' '-x' '.hidden' 'alpha
beta' ''; do
    jq --arg k "$bad_key" '. + {($k): {"attestation": {}}}' "$work/good.json" >"$work/badkey.json"
    run_script "$work/badkey.json"
    if [[ $rc -ne 0 ]] && grep -Fq 'invalid key names' <<<"$out"; then
        pass "a JSON key $(printf '%q' "$bad_key") is rejected"
    else
        fail "a JSON key $(printf '%q' "$bad_key") is rejected"
    fi
    # A non-attested entry with an odd key is not selected and does not fail.
    jq --arg k "$bad_key" '. + {($k): {"url": "x"}}' "$work/good.json" >"$work/oddplain.json"
    run_script "$work/oddplain.json"
    if [[ $rc -eq 0 ]]; then
        pass "an entry without attestation and key $(printf '%q' "$bad_key") is ignored"
    else
        fail "an entry without attestation and key $(printf '%q' "$bad_key") is ignored"
    fi
done
for bad_arg in '../x' 'a/b' 'a b' '-x' '.hidden' 'alpha
beta' ''; do
    run_script "$work/good.json" "$bad_arg"
    if [[ $rc -ne 0 && ! -s "$work/gh.log" ]] && grep -Fq 'invalid key name' <<<"$out"; then
        pass "an explicit key argument $(printf '%q' "$bad_arg") is rejected before any download"
    else
        fail "an explicit key argument $(printf '%q' "$bad_arg") is rejected before any download"
        printf '%s\n' "$out" >&2
    fi
done
# A bad argument next to a good one still fails the run, and the good key is checked.
run_script "$work/good.json" alpha '../x'
if [[ $rc -ne 0 ]] && grep -Fq 'OK alpha' <<<"$out" && grep -Fq 'invalid key name' <<<"$out"; then
    pass 'a bad argument next to a good one fails the run'
else
    fail 'a bad argument next to a good one fails the run'
fi

# 10. A missing gh binary and a missing checksums file fail.
rc=0
CHECKSUMS_FILE="$work/good.json" GH="$work/no-such-gh" "$SCRIPT" >/dev/null 2>&1 || rc=$?
if [[ $rc -ne 0 ]]; then
    pass 'a missing gh fails'
else
    fail 'a missing gh fails'
fi
run_script "$work/no-such-file.json"
if [[ $rc -ne 0 ]]; then
    pass 'a missing checksums file fails'
else
    fail 'a missing checksums file fails'
fi

# 11. Output stays terse: key names and outcomes only.
run_script "$work/good.json"
if ! grep -Eq 'payload|GH_TOKEN' <<<"$out"; then
    pass 'output carries key names and outcomes only'
else
    fail 'output carries key names and outcomes only'
fi

# 12. The real pins carry at least one attested entry.
if jq -e '[to_entries[] | select(.value.attestation != null)] | length > 0' \
    "$ROOT_DIR/shared/download/sysext-checksums.json" >/dev/null; then
    pass 'sysext-checksums.json carries at least one attested entry'
else
    fail 'sysext-checksums.json carries at least one attested entry'
fi

# 13. build.yml runs the script, with GH_TOKEN, right before mkosi builds.
verify_line=$(grep -n 'run: ./shared/download/verify-attestations.sh$' "$BUILD_WORKFLOW" | head -n1 | cut -d: -f1 || true)
mkosi_line=$(grep -n 'sudo -E mkosi build$' "$BUILD_WORKFLOW" | head -n1 | cut -d: -f1 || true)
if [[ -n "$verify_line" && -n "$mkosi_line" && "$verify_line" -lt "$mkosi_line" ]]; then
    pass 'build.yml runs verify-attestations.sh before sudo -E mkosi build'
else
    fail 'build.yml runs verify-attestations.sh before sudo -E mkosi build'
fi
step=$(awk '
    /^      - name: Verify attested sysext downloads$/ { in_step = 1; print; next }
    in_step && /^      - name: / { exit }
    in_step { print }
' "$BUILD_WORKFLOW")
next_step=$(awk '/^      - name: Verify attested sysext downloads$/ { f = 1; next } f && /^      - name: / { print; exit }' "$BUILD_WORKFLOW")
token_line='GH_TOKEN: ${{ github.token }}'
if grep -Fq "$token_line" <<<"$step" &&
    grep -Fq 'run: ./shared/download/verify-attestations.sh' <<<"$step" &&
    [[ "$next_step" == '      - name: Build main and sysexts' ]]; then
    pass 'the verify step sets GH_TOKEN and sits right before the main build step'
else
    fail 'the verify step sets GH_TOKEN and sits right before the main build step'
fi

# 14. check-dependencies.yml pins attested releases only after the same script
# passes on a candidate copy, and fails the job after the PR step.
deps_workflow="$ROOT_DIR/.github/workflows/check-dependencies.yml"
pr_line=$(grep -n 'uses: peter-evans/create-pull-request@' "$deps_workflow" | head -n1 | cut -d: -f1 || true)
final_line=$(grep -n 'name: Fail when an attestation did not verify' "$deps_workflow" | head -n1 | cut -d: -f1 || true)
if grep -Fq 'CHECKSUMS_FILE="$cand" ./shared/download/verify-attestations.sh "$key"' "$deps_workflow" &&
    grep -Fq 'pin_attested notesd' "$deps_workflow" && grep -Fq 'pin_attested maild' "$deps_workflow" &&
    grep -Fq 'GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}' "$deps_workflow" &&
    [[ -n "$pr_line" && -n "$final_line" && "$pr_line" -lt "$final_line" ]]; then
    pass 'check-dependencies.yml verifies a candidate pin and fails the job after the PR step'
else
    fail 'check-dependencies.yml verifies a candidate pin and fails the job after the PR step'
fi

# 15. Behaviour of pin_attested, the function of the `Update sysext checksums`
# step in check-dependencies.yml, run with a stub curl and a stub gh in a copy
# of the repository's download scripts.
pin_fn="$work/pin_attested.sh"
sed -n '/^          pin_attested() {$/,/^          }$/p' "$deps_workflow" | sed 's/^          //' >"$pin_fn"
if [[ $(wc -l <"$pin_fn") -lt 5 ]] || ! grep -q '^pin_attested() {$' "$pin_fn"; then
    fail 'pin_attested is extracted from check-dependencies.yml'
else
    pass 'pin_attested is extracted from check-dependencies.yml'
fi

mkdir -p "$work/pinrepo/shared/download" "$work/pinbin"
cp "$ROOT_DIR/shared/download/verified-download.sh" "$ROOT_DIR/shared/download/verify-attestations.sh" \
    "$work/pinrepo/shared/download/"
cat >"$work/pinbin/curl" <<'EOS'
#!/bin/bash
# Stub curl: writes $STUB_CURL_PAYLOAD to the -o/--output file; a URL that
# contains /missing/ fails like a 404.
out=""
url=""
while (($# > 0)); do
    case "$1" in
    -o | --output) out=$2; shift ;;
    http://* | https://*) url=$1 ;;
    esac
    shift
done
printf '%s\n' "$url" >>"${STUB_CURL_LOG:?}"
[[ "$url" != */missing/* ]] || exit 22
cp "${STUB_CURL_PAYLOAD:?}" "$out"
EOS
chmod +x "$work/pinbin/curl"
printf 'new notesd payload\n' >"$work/pin-payload.deb"
pin_payload_sha=$(sha256sum "$work/pin-payload.deb" | cut -d' ' -f1)
cat >"$work/pin-before.json" <<EOS
{
  "other": {"url": "https://example.invalid/other.deb", "sha256": "$(printf '%064d' 7)", "version": "9.9.9"},
  "notesd": {
    "url": "https://example.invalid/releases/download/v0.1.0/notesd_0.1.0.deb",
    "sha256": "$(printf '%064d' 1)",
    "version": "0.1.0",
    "attestation": {"repository": "example/notes", "signer_workflow": ".github/workflows/release.yml"}
  }
}
EOS

# run_pin <version> <url> [gh exit status]: runs pin_attested on a fresh copy of
# the fixture in `bash -e`, like a workflow step. Sets pin_rc, pin_out, and the
# files pin_json, curl.log and gh.log.
run_pin() {
    local version=$1 url=$2 gh_status=${3:-0}
    pin_json="$work/pinrepo/shared/download/sysext-checksums.json"
    cp "$work/pin-before.json" "$pin_json"
    : >"$work/curl.log"
    : >"$work/gh.log"
    cat >"$work/pin-run.sh" <<EOS
CHECKSUMS="shared/download/sysext-checksums.json"
ATTESTATION_FAILED=""
$(cat "$pin_fn")
pin_attested notesd '$version' '$url'
printf 'ATTESTATION_FAILED=[%s]\n' "\$ATTESTATION_FAILED"
EOS
    pin_rc=0
    pin_out=$(cd "$work/pinrepo" && PATH="$work/pinbin:$PATH" GH="$work/gh" STUB_GH_LOG="$work/gh.log" \
        STUB_GH_EXIT="$gh_status" STUB_CURL_LOG="$work/curl.log" STUB_CURL_PAYLOAD="$work/pin-payload.deb" \
        bash -e "$work/pin-run.sh" 2>&1) || pin_rc=$?
}

run_pin 0.2.0 'https://example.invalid/releases/download/v0.2.0/notesd_0.2.0.deb'
if [[ $pin_rc -eq 0 ]] &&
    jq -e --arg s "$pin_payload_sha" '
        .notesd.version == "0.2.0" and .notesd.sha256 == $s
        and .notesd.url == "https://example.invalid/releases/download/v0.2.0/notesd_0.2.0.deb"
        and .notesd.attestation == {"repository": "example/notes", "signer_workflow": ".github/workflows/release.yml"}' \
        "$pin_json" >/dev/null &&
    jq -e '.other.version == "9.9.9"' "$pin_json" >/dev/null &&
    grep -Fq 'ATTESTATION_FAILED=[]' <<<"$pin_out" && grep -Fq 'Pinned notesd 0.2.0' <<<"$pin_out" &&
    grep -Fq -- '--source-ref refs/tags/v0.2.0' "$work/gh.log" &&
    grep -Fq -- '--repo example/notes' "$work/gh.log"; then
    pass 'pin_attested writes the new pin and keeps .attestation after a good verify'
else
    fail 'pin_attested writes the new pin and keeps .attestation after a good verify'
    printf '%s\n' "$pin_out" >&2
fi

run_pin 0.2.0 'https://example.invalid/releases/download/v0.2.0/notesd_0.2.0.deb' 1
if [[ $pin_rc -eq 0 ]] && cmp -s "$work/pin-before.json" "$pin_json" &&
    grep -Fq 'ATTESTATION_FAILED=[notesd ]' <<<"$pin_out" && grep -Fq '::error::notesd 0.2.0 is not pinned' <<<"$pin_out" &&
    ! grep -Fq 'Pinned' <<<"$pin_out"; then
    pass 'pin_attested leaves the file byte-identical and records the key after a failed verify'
else
    fail 'pin_attested leaves the file byte-identical and records the key after a failed verify'
    printf '%s\n' "$pin_out" >&2
fi

run_pin 0.2.0 'https://example.invalid/releases/download/v0.2.0/missing/notesd_0.2.0.deb'
if [[ $pin_rc -eq 0 ]] && cmp -s "$work/pin-before.json" "$pin_json" && [[ ! -s "$work/gh.log" ]] &&
    grep -Fq 'ATTESTATION_FAILED=[notesd ]' <<<"$pin_out"; then
    pass 'pin_attested records the key and runs no verify after a failed download'
else
    fail 'pin_attested records the key and runs no verify after a failed download'
    printf '%s\n' "$pin_out" >&2
fi

for bad_version in 'v0.2.0' '0.2.0;touch-x' '../0.2.0' '$(id)' ''; do
    run_pin "$bad_version" 'https://example.invalid/releases/download/v0.2.0/notesd_0.2.0.deb'
    if [[ $pin_rc -eq 0 ]] && cmp -s "$work/pin-before.json" "$pin_json" &&
        [[ ! -s "$work/gh.log" && ! -s "$work/curl.log" ]] &&
        grep -Fq 'ATTESTATION_FAILED=[notesd ]' <<<"$pin_out" && grep -Fq 'not a plain version' <<<"$pin_out"; then
        pass "pin_attested refuses the tag $(printf '%q' "$bad_version") before any download"
    else
        fail "pin_attested refuses the tag $(printf '%q' "$bad_version") before any download"
        printf '%s\n' "$pin_out" >&2
    fi
done

# The last step fails the job after the PR step when a key was recorded.
final_step=$(awk '
    /^      - name: Fail when an attestation did not verify$/ { in_step = 1; print; next }
    in_step && /^      - name: / { exit }
    in_step && /^  [A-Za-z0-9_-]+:/ { exit }
    in_step { print }
' "$deps_workflow")
update_step=$(awk '
    /^      - name: Update sysext checksums$/ { in_step = 1; print; next }
    in_step && /^      - name: / { exit }
    in_step { print }
' "$deps_workflow")
if grep -Fq "if: \${{ !cancelled() && steps.update.outputs.attestation_failed != '' }}" <<<"$final_step" &&
    grep -Fq 'ATTESTATION_FAILED: ${{ steps.update.outputs.attestation_failed }}' <<<"$final_step" &&
    [[ $(grep -Ev '^[[:space:]]*(#|$)' <<<"$final_step" | tail -n1) == '          exit 1' ]] &&
    grep -Fq '        id: update' <<<"$update_step" &&
    grep -Fq 'echo "attestation_failed=${ATTESTATION_FAILED% }" >> "$GITHUB_OUTPUT"' <<<"$update_step"; then
    pass 'the final step fails the job on steps.update.outputs.attestation_failed, even after a failed step'
else
    fail 'the final step fails the job on steps.update.outputs.attestation_failed, even after a failed step'
    printf '%s\n' "$final_step" >&2
fi

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
