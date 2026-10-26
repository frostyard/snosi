#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Contract for the branch-only publication path in build-images.yml.
#
# A workflow_dispatch on a branch other than main exists only to publish ONE
# signed Snow version tag for a lab lifecycle test. That path must build snow
# alone and must not reach any main-only side effect: `latest` promotion, the
# R2 manifest upload, the snow-tag artifact, or the release job. Everything a
# lab test needs (immutable version tag, signature, SBOM, attestation,
# re-verification) stays.
#
# The version tag is an immutable image tag, so a branch dispatch must not be
# able to collide with a main run: it backdates the tag and refuses an existing
# one before the push.
#
# Static and hermetic: no network, no registry, no dispatch. The two generated
# shell blocks are executed against a skopeo shim, and a mutation suite proves
# that each part of the contract is load-bearing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The mutation suite points the whole test at a mutated copy.
workflow_file=${SNOSI_BUILD_IMAGES_WORKFLOW:-$ROOT_DIR/.github/workflows/build-images.yml}

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

[[ -f $workflow_file ]] || {
    printf 'not ok - missing %s\n' "$workflow_file" >&2
    exit 1
}

job_block() { # job name
    awk -v header="  $1:" '
        $0 == header { capture = 1 }
        capture && /^  [A-Za-z0-9_-]+:$/ && $0 != header { exit }
        capture { print }
    ' "$workflow_file"
}

step_block() { # step name
    awk -v header="      - name: $1" '
        $0 == header { capture = 1 }
        capture && /^      - name: / && $0 != header { exit }
        capture { print }
    ' "$workflow_file"
}

step_count() { # step name
    grep -c -F -- "      - name: $1" "$workflow_file" || true
}

step_script() { # step name
    # The step's `run: |` body, dedented by ten spaces, for direct execution.
    awk -v header="      - name: $1" '
        $0 == header { in_step = 1; next }
        in_step && /^      - name: / { exit }
        in_step && /^        run: \|$/ { in_run = 1; next }
        in_run && /^          / { print substr($0, 11); next }
        in_run { exit }
    ' "$workflow_file"
}

step_line() { # step name
    grep -n -F -- "      - name: $1" "$workflow_file" | head -1 | cut -d: -f1
}

assert_step_condition() { # description step expected-condition
    local description=$1 name=$2 expected=$3 block
    if [[ $(step_count "$name") -ne 1 ]]; then
        fail "$description (expected exactly one step named $name)"
        return
    fi
    block=$(step_block "$name")
    if grep -Fqx "        if: $expected" <<<"$block"; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_step_ungated() { # description step
    local description=$1 name=$2 block
    if [[ $(step_count "$name") -ne 1 ]]; then
        fail "$description (expected exactly one step named $name)"
        return
    fi
    block=$(step_block "$name")
    if grep -Eq '^        if: ' <<<"$block"; then
        fail "$description"
    else
        pass "$description"
    fi
}

# 1. The dispatch trigger exists, and the branch path cannot read a dispatch
#    input that would widen it.
if grep -Fqx '  workflow_dispatch:' "$workflow_file"; then
    pass 'workflow_dispatch trigger is present'
else
    fail 'workflow_dispatch trigger is missing'
fi

secure=$(job_block secure-build)
if [[ -z $secure ]]; then
    printf 'not ok - missing secure-build job\n' >&2
    exit 1
fi

# 2. The job condition: main plus a branch dispatch, never a pull request.
condition=$(awk '
    /^    if: / { capture = 1 }
    capture && !/^    if: / && /^    [A-Za-z0-9_-]+:/ { exit }
    capture { print }
' <<<"$secure")

if grep -Fqx "      github.event_name != 'pull_request' &&" <<<"$condition"; then
    pass 'secure-build excludes pull requests'
else
    fail 'secure-build must exclude pull requests'
fi
if grep -Fq "      (github.ref == 'refs/heads/main' ||" <<<"$condition"; then
    pass 'secure-build keeps the main publication path'
else
    fail 'secure-build must keep the main publication path'
fi
if grep -Fq "      (github.event_name == 'workflow_dispatch' &&" <<<"$condition" &&
        grep -Fqx "      startsWith(github.ref, 'refs/heads/')))" <<<"$condition"; then
    pass 'secure-build allows a workflow_dispatch on a branch'
else
    fail 'secure-build must allow a workflow_dispatch on a branch'
fi
if grep -Fq "event_name == 'pull_request'" <<<"$condition"; then
    fail 'secure-build condition must not permit a pull request'
else
    pass 'secure-build condition permits no pull request'
fi
if [[ $(grep -c -F '||' <<<"$condition") -eq 1 ]]; then
    pass 'secure-build condition holds exactly one disjunction'
else
    fail 'secure-build condition must hold exactly one disjunction'
fi

# 3. The matrix: main gets all four products, any other ref gets snow alone.
include_line=$(grep -F '        include: ' <<<"$secure" || true)
if [[ $(wc -l <<<"$include_line") -eq 1 ]]; then
    pass 'secure-build has one matrix include expression'
else
    fail 'secure-build must have one matrix include expression'
fi
if grep -Fq "\${{ github.ref == 'refs/heads/main' &&" <<<"$include_line"; then
    pass 'the matrix is selected by the ref'
else
    fail 'the matrix must be selected by the ref'
fi
if grep -Fq 'fromJSON(' <<<"$include_line"; then
    pass 'the matrix uses explicit fromJSON product lists'
else
    fail 'the matrix must use explicit fromJSON product lists'
fi

main_part=${include_line%%||*}
off_main_part=${include_line#*|| }
main_profiles=$(grep -o '"profile":"[a-z]*"' <<<"$main_part" |
    cut -d'"' -f4 | sort | paste -sd' ' -)
off_main_profiles=$(grep -o '"profile":"[a-z]*"' <<<"$off_main_part" |
    cut -d'"' -f4 | sort | paste -sd' ' -)

if [[ $main_profiles == 'floe snow snowfield sundog' ]]; then
    pass 'main builds all four products'
else
    fail "main must build all four products (found: ${main_profiles:-none})"
fi
if [[ $off_main_profiles == 'snow' ]]; then
    pass 'a non-main ref builds snow alone'
else
    fail "a non-main ref must build snow alone (found: ${off_main_profiles:-none})"
fi
if grep -Eq 'inputs\.' <<<"${include_line}${condition}"; then
    fail 'the branch-dispatch path must not read workflow_dispatch inputs'
else
    pass 'the branch-dispatch path reads no dispatch inputs'
fi

# 4. Main-only side effects are gated on the ref, not only on the profile.
assert_step_condition 'latest promotion is main-only' \
    'Promote validated digest to latest' "github.ref == 'refs/heads/main'"
assert_step_condition 'the R2 manifest upload is main-only' \
    'Upload manifests to R2' "github.ref == 'refs/heads/main'"
assert_step_condition 'the snow-tag record is main-only' \
    'Record snow tag for release job' \
    "github.ref == 'refs/heads/main' && matrix.profile == 'snow'"
assert_step_condition 'the snow-tag artifact upload is main-only' \
    'Upload snow tag artifact' \
    "github.ref == 'refs/heads/main' && matrix.profile == 'snow'"

# 5. The release job stays push-on-main only, and keeps its artifact contract.
release=$(job_block release)
if [[ -z $release ]]; then
    fail 'missing release job'
else
    if grep -Fxq '    needs: secure-build' <<<"$release"; then
        pass 'release still needs the secure build'
    else
        fail 'release must still need the secure build'
    fi
    release_condition=$(awk '
        /^    if: / { capture = 1 }
        capture && !/^    if: / && /^    [A-Za-z0-9_-]+:/ { exit }
        capture { print }
    ' <<<"$release")
    if grep -Fq "github.event_name == 'push'" <<<"$release_condition" &&
            grep -Fq "github.ref == 'refs/heads/main'" <<<"$release_condition"; then
        pass 'release stays push-on-main only'
    else
        fail 'release must stay push-on-main only'
    fi
fi

# 6. What a lab test needs from a branch stays available: the immutable tag,
#    its signature, the SBOM, the attestation and the re-verification.
for name in \
    'Push immutable version tag' \
    'Sign immutable image digest' \
    'Upload SBOM' \
    'Sign SBOM' \
    'Attest build provenance' \
    'Re-verify key signature after attestation'; do
    assert_step_ungated "'$name' still runs on a branch" "$name"
done

# 7. No other side effect of the job reaches out off main. The job block is the
#    authoritative scope: the trigger filters live outside it. Comments are
#    stripped first: prose about dispatches is not a dispatch call.
secure_code=$(grep -v -E '^[[:space:]]*#' <<<"$secure")
no_other_side_effect=1
for token in 'cloudflare' 'Cloudflare' 'gh workflow run' 'dispatches' \
    'build-installer-iso' 'awslabs' 'rclone'; do
    if grep -Fq -- "$token" <<<"$secure_code"; then
        fail "secure-build must not reach '$token' at all"
        no_other_side_effect=0
    fi
done
((no_other_side_effect == 1)) &&
    pass 'secure-build reaches no other external side effect'

r2_steps=$(step_count 'Upload manifests to R2')
if [[ $r2_steps -eq 1 ]]; then
    pass 'exactly one R2 upload step exists'
else
    fail "exactly one R2 upload step must exist (found: $r2_steps)"
fi

# 8. The version tag: main uses "now", a branch dispatch backdates it by four
#    hours so a later main run can never create the same immutable tag.
version_steps=$(grep -c -F -- '      - name: Generate version tag' <<<"$secure")
if [[ $version_steps -eq 1 ]]; then
    pass 'the secure build has exactly one version tag step'
else
    fail "the secure build must have exactly one version tag step (found: $version_steps)"
fi
version_block=$(step_block 'Generate version tag')
# shellcheck disable=SC2016 # Workflow literal, not an expansion.
if grep -Fqx '          REF: ${{ github.ref }}' <<<"$version_block"; then
    pass 'the version step selects its branch by github.ref'
else
    fail 'the version step must select its branch by github.ref'
fi
version_script=$(step_script 'Generate version tag')
# shellcheck disable=SC2016 # Workflow literal, not an expansion.
if grep -Fqx '  tag=$(date +%Y%m%d%H%M%S)' <<<"$version_script"; then
    pass 'main derives the version from the current time'
else
    fail 'main must derive the version from the current time'
fi
if grep -Fqx "  tag=\$(date -u -d '-4 hours' +%Y%m%d%H%M%S)" <<<"$version_script"; then
    pass 'a non-main ref backdates the version by four hours'
else
    fail 'a non-main ref must backdate the version by four hours'
fi
# shellcheck disable=SC2016 # Workflow literal, not an expansion.
if grep -Fq '[[ $tag =~ ^[0-9]{14}$ ]]' <<<"$version_script"; then
    pass 'the version step keeps the 14-digit format'
else
    fail 'the version step must keep the 14-digit format'
fi

tag_epoch() { # 14-digit tag
    local t=$1
    date -u -d "${t:0:4}-${t:4:2}-${t:6:2} ${t:8:2}:${t:10:2}:${t:12:2}" +%s
}

run_version_step() { # ref
    local out
    out=$(mktemp)
    if ! GITHUB_OUTPUT="$out" REF="$1" bash -c "$version_script" >/dev/null 2>&1; then
        rm -f "$out"
        return 1
    fi
    sed -n 's/^tag=//p' "$out"
    rm -f "$out"
}

# main keeps `date +...` unchanged: the runners are UTC, so "now" is the UTC
# second there. A branch dispatch backdates against `date -u` explicitly.
main_tag=$(run_version_step refs/heads/main)
local_now=$(date +%Y%m%d%H%M%S)
main_offset=999999
if [[ $main_tag =~ ^[0-9]{14}$ ]]; then
    main_offset=$(($(tag_epoch "$main_tag") - $(tag_epoch "$local_now")))
fi
if ((main_offset > -6 && main_offset < 6)); then
    pass 'main produces the current second'
else
    fail "main must produce the current second (got: ${main_tag:-none})"
fi
branch_tag=$(run_version_step refs/heads/lab-test)
utc_now=$(date -u +%Y%m%d%H%M%S)
branch_offset=999999
if [[ $branch_tag =~ ^[0-9]{14}$ ]]; then
    branch_offset=$(($(tag_epoch "$branch_tag") - $(tag_epoch "$utc_now")))
fi
if ((branch_offset > -14500 && branch_offset < -14300)); then
    pass 'a non-main ref produces the UTC second four hours back'
else
    fail "a non-main ref must produce the UTC second four hours back (got: ${branch_tag:-none})"
fi

# 9. The existence check: non-main only, immediately before the push, and it
#    fails closed on a registry, authentication or tag-list error.
assert_step_condition 'the version-tag existence check is non-main only' \
    'Refuse an existing version tag' "github.ref != 'refs/heads/main'"

check_behaviour=1
if [[ $(grep -c -F -- '      - name: Refuse an existing version tag' <<<"$secure") -ne 1 ]]; then
    fail 'the secure build must hold exactly one version-tag existence check'
    check_behaviour=0
fi
if [[ $(grep -c -F -- '      - name: Push immutable version tag' <<<"$secure") -ne 1 ]]; then
    fail 'the secure build must hold exactly one push step'
    check_behaviour=0
fi
if ((check_behaviour == 1)); then
    check_line=$(step_line 'Refuse an existing version tag')
    push_line=$(step_line 'Push immutable version tag')
    if ((check_line < push_line)); then
        pass 'the existence check runs before the push'
    else
        fail 'the existence check must run before the push'
    fi
    next_step_line=$(awk -v start="$check_line" '
        NR > start && /^      - name: / { print NR; exit }
    ' "$workflow_file")
    if [[ ${next_step_line:-0} == "$push_line" ]]; then
        pass 'the existence check is the step immediately before the push'
    else
        fail 'the existence check must be the step immediately before the push'
    fi

    check_script=$(step_script 'Refuse an existing version tag')
    # shellcheck disable=SC2016 # Workflow literal, not an expansion.
    if grep -Fq 'skopeo list-tags --authfile "$auth_file"' <<<"$check_script" &&
            grep -Fq 'skopeo login --authfile "$auth_file"' <<<"$check_script"; then
        pass 'the existence check reads tags through one explicit auth file'
    else
        fail 'the existence check must read tags through one explicit auth file'
    fi

    # Execute the step against a skopeo shim: registry answers are fixtures.
    shim_dir=$(mktemp -d)
    tag_dir=$(mktemp -d)
    trap 'rm -rf "${shim_dir:-}" "${tag_dir:-}"' EXIT
    cat >"$shim_dir/skopeo" <<'SHIM'
#!/bin/bash
case $1 in
    login) exit "${SHIM_LOGIN_STATUS:-0}" ;;
    list-tags)
        [[ ${SHIM_LIST_STATUS:-0} -eq 0 ]] || {
            echo "reading manifest: authentication required" >&2
            exit "${SHIM_LIST_STATUS}"
        }
        cat "$SHIM_TAG_FILE"
        ;;
    *) echo "unexpected skopeo call: $*" >&2; exit 1 ;;
esac
SHIM
    chmod +x "$shim_dir/skopeo"
    tag_file="$tag_dir/tags.json"

    run_check_step() { # tag-json-file [list-status] [login-status]
        PATH="$shim_dir:$PATH" \
            IMAGE=ghcr.io/frostyard/snow \
            VERSION_TAG=20261026060000 \
            GH_TOKEN=token \
            GHCR_USER=actor \
            SHIM_TAG_FILE="$1" \
            SHIM_LIST_STATUS="${2:-0}" \
            SHIM_LOGIN_STATUS="${3:-0}" \
            bash -c "$check_script" >/dev/null 2>&1
    }

    printf '%s' '{"Name":"ghcr.io/frostyard/snow","Tags":["20260101000000","latest"]}' \
        >"$tag_file"
    if run_check_step "$tag_file"; then
        pass 'the existence check passes for a free tag'
    else
        fail 'the existence check must pass for a free tag'
    fi

    printf '%s' '{"Name":"ghcr.io/frostyard/snow","Tags":["20261026060000"]}' \
        >"$tag_file"
    if run_check_step "$tag_file"; then
        fail 'the existence check must refuse an existing tag'
    else
        pass 'the existence check refuses an existing tag'
    fi

    printf '%s' '{"Name":"ghcr.io/frostyard/snow","Tags":[]}' >"$tag_file"
    if run_check_step "$tag_file" 1; then
        fail 'a tag-list error must not be treated as an absent tag'
    else
        pass 'a tag-list error fails the job'
    fi
    if run_check_step "$tag_file" 0 1; then
        fail 'a registry login error must not be treated as an absent tag'
    else
        pass 'a registry login error fails the job'
    fi
    printf '%s' 'not json' >"$tag_file"
    if run_check_step "$tag_file"; then
        fail 'unreadable tag-list output must not be treated as an absent tag'
    else
        pass 'unreadable tag-list output fails the job'
    fi
    rm -rf "$shim_dir" "$tag_dir"
    trap - EXIT
fi

# 10. Publication is serialized for every non-main ref: one shared job-level
#     concurrency group with no cancel, so two branch dispatches on different
#     branches cannot both generate and push the same backdated version tag.
#     main keeps its own group and its workflow-level cancel.
if [[ $(grep -c -x -F '    concurrency:' <<<"$secure") -eq 1 ]]; then
    pass 'the secure build has exactly one job-level concurrency block'
else
    fail 'the secure build must have exactly one job-level concurrency block'
fi
job_concurrency=$(awk '
    /^    concurrency:$/ { capture = 1; next }
    capture && /^    [A-Za-z0-9_-]+:/ { exit }
    capture { print }
' <<<"$secure")
job_group=$(sed -n 's/^      group: //p' <<<"$job_concurrency")
job_cancel=$(sed -n 's/^      cancel-in-progress: //p' <<<"$job_concurrency")
# shellcheck disable=SC2016 # Workflow expression, not an expansion.
if [[ $job_group == "\${{ github.ref == 'refs/heads/main' && format('secure-build-{0}-{1}', github.ref, matrix.profile) || 'snosi-branch-snow-publication' }}" ]]; then
    pass 'the job concurrency group names the shared non-main group'
else
    fail "the job concurrency group must name the shared non-main group (got: ${job_group:-none})"
fi
if [[ $job_cancel == 'false' ]]; then
    pass 'the job concurrency never cancels in progress'
else
    fail "the job concurrency must not cancel in progress (got: ${job_cancel:-none})"
fi
main_group_part=${job_group%%||*}
off_main_group=${job_group#*|| }
# shellcheck disable=SC2016 # Workflow expression, not an expansion.
if grep -Fq "github.ref == 'refs/heads/main' && format('secure-build-{0}-{1}', github.ref, matrix.profile)" \
        <<<"$main_group_part"; then
    pass 'main keeps its own concurrency group'
else
    fail 'main must keep its own concurrency group'
fi
if ! grep -Eq 'github\.|matrix\.|needs\.|inputs\.' <<<"$off_main_group"; then
    pass 'every non-main ref shares one concurrency group'
else
    fail 'every non-main ref must share one concurrency group'
fi

# Evaluate the group the way the expression reads: main formats the template
# with (github.ref, matrix.profile), every other ref gets the constant.
main_format=$(sed -n "s/^.*github.ref == 'refs\/heads\/main' && \(format([^)]*)\).*$/\1/p" \
    <<<"$job_group")
group_template=$(sed -n "s/^format('\([^']*\)'.*$/\1/p" <<<"$main_format")
main_args=$(sed -n "s/^format('[^']*', \(.*\))$/\1/p" <<<"$main_format")
fallback_group=$(sed -n "s/^'\([^']*\)'.*$/\1/p" <<<"$off_main_group")

arg_names=()
if [[ -n $main_args ]]; then
    IFS=',' read -r -a arg_names <<<"$main_args"
    for index in "${!arg_names[@]}"; do
        name=${arg_names[index]# }
        arg_names[index]=${name% }
    done
fi

main_ref_literal=$(sed -n "s/^.*github.ref == '\([^']*\)'.*$/\1/p" <<<"$job_group")

group_name() { # ref profile
    local ref=$1 profile=$2 out index value
    if [[ $ref != "$main_ref_literal" ]]; then
        printf '%s' "$fallback_group"
        return
    fi
    out=$group_template
    for index in "${!arg_names[@]}"; do
        case ${arg_names[index]} in
            github.ref) value=$ref ;;
            matrix.profile) value=$profile ;;
            *) value='?' ;;
        esac
        out=${out//\{$index\}/$value}
    done
    printf '%s' "$out"
}

if [[ $group_template == *'{1}'* && $main_args == *'matrix.profile'* ]]; then
    pass 'the main concurrency group is keyed by profile'
else
    fail 'the main concurrency group must be keyed by profile'
fi

main_groups=''
for profile in $main_profiles; do
    main_groups+="$(group_name refs/heads/main "$profile")"$'\n'
done
distinct_main_groups=$(printf '%s' "$main_groups" | sort -u | grep -c . )
if [[ $distinct_main_groups -eq 4 ]] && [[ $(printf '%s' "$main_groups" | grep -c .) -eq 4 ]]; then
    pass 'the four main profiles get four distinct concurrency groups'
else
    fail "the four main profiles must get four distinct concurrency groups (found: $distinct_main_groups)"
fi

first_branch_group=$(group_name refs/heads/lab-one '')
second_branch_group=$(group_name refs/heads/lab-two '')
if [[ -n $fallback_group && $first_branch_group == "$fallback_group" &&
        $second_branch_group == "$fallback_group" ]]; then
    pass 'different non-main refs get the same concurrency group'
else
    fail "different non-main refs must get the same concurrency group (got: ${first_branch_group:-none} / ${second_branch_group:-none})"
fi

workflow_concurrency=$(awk '
    /^concurrency:$/ { capture = 1; next }
    capture && /^[a-z]/ { exit }
    capture { print }
' "$workflow_file")
# shellcheck disable=SC2016 # Workflow literal, not an expansion.
if grep -Fqx '  group: ${{ github.workflow }}-${{ github.ref || github.run_id }}' \
        <<<"$workflow_concurrency"; then
    pass 'the workflow-level concurrency group is unchanged'
else
    fail 'the workflow-level concurrency group must stay unchanged'
fi
# shellcheck disable=SC2016 # Workflow literal, not an expansion.
if grep -Fqx "  cancel-in-progress: \${{ github.event_name == 'push' || github.event_name == 'pull_request' }}" \
        <<<"$workflow_concurrency"; then
    pass 'main and PR runs keep their workflow-level cancel'
else
    fail 'main and PR runs must keep their workflow-level cancel'
fi

# 11. Mutation fixtures: each guard above must be load-bearing. Each one mutates
#     a copy of the workflow and re-runs this test against it, which must fail.
mut_remove_backdate() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
old = "            tag=$(date -u -d '-4 hours' +%Y%m%d%H%M%S)\n"
assert old in text
path.write_text(text.replace(old, "            tag=$(date +%Y%m%d%H%M%S)\n", 1))
PY
}

mut_backdate_main() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
old = "            tag=$(date +%Y%m%d%H%M%S)\n          else\n"
assert old in text
path.write_text(text.replace(
    old, "            tag=$(date -u -d '-4 hours' +%Y%m%d%H%M%S)\n          else\n", 1))
PY
}

mut_remove_check() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
start = next(i for i, line in enumerate(lines)
             if line == "      - name: Refuse an existing version tag\n")
end = next(i for i in range(start + 1, len(lines))
           if lines[i] == "      - name: Push immutable version tag\n")
del lines[start:end]
path.write_text("".join(lines))
PY
}

mut_ungate_check() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
old = "        if: github.ref != 'refs/heads/main'\n"
assert text.count(old) == 1
path.write_text(text.replace(old, "", 1))
PY
}

mut_move_check_after_push() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
header = "      - name: Refuse an existing version tag\n"
push = "      - name: Push immutable version tag\n"
start = text.index(header)
end = text.index(push)
block = text[start:end]
text = text[:start] + text[end:]
marker = "      - name: Log in to ghcr.io\n"
text = text.replace(marker, block + marker, 1)
path.write_text(text)
PY
}

mut_ignore_lookup_error() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
old = (
    '          if ! tags=$(skopeo list-tags --authfile "$auth_file" \\\n'
    '                  "docker://$IMAGE" 2>&1); then\n'
    '            echo "::error::cannot list tags for $IMAGE: $tags" >&2\n'
    '            exit 1\n'
    '          fi\n'
)
assert old in text
new = ('          tags=$(skopeo list-tags --authfile "$auth_file" '
       '"docker://$IMAGE" 2>/dev/null || echo \'{"Tags":[]}\')\n')
path.write_text(text.replace(old, new, 1))
PY
}

mut_remove_job_concurrency() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
start = lines.index("    concurrency:\n")
end = start + 1
while lines[end].startswith("      "):
    end += 1
del lines[start:end]
path.write_text("".join(lines))
PY
}

mut_per_ref_group() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
old = (
    "      group: ${{ github.ref == 'refs/heads/main' && "
    "format('secure-build-{0}-{1}', github.ref, matrix.profile) || "
    "'snosi-branch-snow-publication' }}\n"
)
assert old in text
path.write_text(text.replace(
    old, "      group: ${{ format('secure-build-{0}-{1}', github.ref, matrix.profile) }}\n", 1))
PY
}

mut_enable_job_cancel() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
old = "      cancel-in-progress: false\n"
assert text.count(old) == 1
path.write_text(text.replace(old, "      cancel-in-progress: true\n", 1))
PY
}

mut_drop_profile_from_main_group() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
old = "format('secure-build-{0}-{1}', github.ref, matrix.profile)"
assert old in text
path.write_text(text.replace(old, "format('secure-build-{0}', github.ref)", 1))
PY
}

mut_drop_main_group() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
old = (
    "      group: ${{ github.ref == 'refs/heads/main' && "
    "format('secure-build-{0}-{1}', github.ref, matrix.profile) || "
    "'snosi-branch-snow-publication' }}\n"
)
assert old in text
path.write_text(text.replace(
    old, "      group: ${{ 'snosi-branch-snow-publication' }}\n", 1))
PY
}

mutate_and_expect_failure() { # description mutation-function
    local dir
    [[ -n ${SNOSI_BRANCH_DISPATCH_NO_FIXTURES:-} ]] && return 0
    dir=$(mktemp -d)
    cp "$ROOT_DIR/.github/workflows/build-images.yml" "$dir/build-images.yml"
    "$2" "$dir/build-images.yml"
    if SNOSI_BRANCH_DISPATCH_NO_FIXTURES=1 \
            SNOSI_BUILD_IMAGES_WORKFLOW="$dir/build-images.yml" \
            bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
        fail "$1"
    else
        pass "$1"
    fi
    rm -rf "$dir"
}

mutate_and_expect_failure 'a removed four-hour backdate fails' mut_remove_backdate
mutate_and_expect_failure 'a backdated main version fails' mut_backdate_main
mutate_and_expect_failure 'a removed existence check fails' mut_remove_check
mutate_and_expect_failure 'an existence check without its non-main gate fails' \
    mut_ungate_check
mutate_and_expect_failure 'an existence check after the push fails' \
    mut_move_check_after_push
mutate_and_expect_failure 'a tag-list error read as an absent tag fails' \
    mut_ignore_lookup_error
mutate_and_expect_failure 'a removed job-level concurrency fails' \
    mut_remove_job_concurrency
mutate_and_expect_failure 'a per-ref job concurrency group fails' \
    mut_per_ref_group
mutate_and_expect_failure 'a cancelling job concurrency fails' \
    mut_enable_job_cancel
mutate_and_expect_failure 'a shared group for main and branches fails' \
    mut_drop_main_group
mutate_and_expect_failure 'a main group without the profile fails' \
    mut_drop_profile_from_main_group

printf '\n%d passing assertions, %d failures\n' "$PASS" "$FAIL"
((FAIL == 0))
