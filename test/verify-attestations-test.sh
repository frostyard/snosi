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

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
