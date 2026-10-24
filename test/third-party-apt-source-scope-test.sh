#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static guard: third-party APT sources must not leak into every build.
#
# mkosi's SandboxTrees= is universal: every image of one invocation shares the
# sandbox and one repository metadata sync, so a third-party repo that is down
# fails every image build. The himmelblau source therefore lives in
# shared/himmelblau/sandbox and is used only by a separate mkosi invocation
# (ADR-0020). This test keeps it that way and stops new third-party sources
# from landing in the shared mkosi.sandbox/ without a scoping decision.
#
# No root, no network, no image build.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scoped_tree=shared/himmelblau/sandbox
scoped_invocation="--dependency=himmelblau --sandbox-tree=$scoped_tree"
just_invocation="--dependency= --dependency=base $scoped_invocation --incremental=no --cache-only=never build"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# A new third-party source must be scoped like himmelblau, or added here only
# with an ADR-backed reason. These are grandfathered: they were shared before
# ADR-0020 and moving them is out of its scope.
third_party_allowlist=(
    1password
    chatgpt
    claude-desktop
    debian-backports
    docker
    edge
    frostyard
    linux-surface
    tailscale
    vscode
)

check_shared_sandbox_allowlist() { # root
    local tree=$1/mkosi.sandbox/etc/apt/sources.list.d
    local expected actual name status=0
    local -a expected_names=() actual_names=()

    if [[ ! -d $tree ]]; then
        fail "missing directory: ${tree#"$1"/}"
        return 1
    fi
    for name in "${third_party_allowlist[@]}"; do
        expected_names+=("$name.sources")
    done
    # apt reads every entry in sources.list.d/, not only *.sources: a *.list
    # file (or a symlink or directory) would also reach the shared sandbox.
    mapfile -t actual_names < <(find "$tree" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
    expected=$(printf '%s\n' "${expected_names[@]}" | sort)
    actual=$(printf '%s\n' "${actual_names[@]-}")
    if [[ $actual != "$expected" ]]; then
        fail "mkosi.sandbox/etc/apt/sources.list.d holds entries outside the allowlist (unexpected: $(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | paste -sd' ' -))"
        status=1
    fi
    # A monolithic sources.list is not an allowlisted third-party source either.
    if [[ -e $1/mkosi.sandbox/etc/apt/sources.list ]]; then
        fail "mkosi.sandbox/etc/apt/sources.list must not exist"
        status=1
    fi
    if ((status == 0)); then
        pass "shared mkosi.sandbox holds only allowlisted third-party APT sources"
    fi
    return "$status"
}

check_sandbox_has_no_himmelblau() { # root
    local status=0
    if [[ ! -d $1/mkosi.sandbox ]]; then
        fail "missing directory: mkosi.sandbox"
        return 1
    fi
    if [[ -e $1/mkosi.sandbox/etc/apt/keyrings/himmelblau.gpg ]]; then
        fail "mkosi.sandbox/etc/apt/keyrings/himmelblau.gpg must not exist"
        status=1
    fi
    if grep -rqF 'himmelblau-idm.org' "$1/mkosi.sandbox"; then
        fail "mkosi.sandbox must not mention himmelblau-idm.org"
        status=1
    fi
    if ((status == 0)); then
        pass "shared mkosi.sandbox carries no himmelblau source or key"
    fi
    return "$status"
}

check_scoped_tree_complete() { # root
    local status=0 file
    for file in "$scoped_tree/etc/apt/sources.list.d/himmelblau.sources" \
        "$scoped_tree/etc/apt/keyrings/himmelblau.gpg"; do
        if [[ ! -f $1/$file ]]; then
            fail "missing scoped himmelblau file: $file"
            status=1
        fi
    done
    if ((status == 0)); then
        pass "shared/himmelblau/sandbox carries the himmelblau source and key"
    fi
    return "$status"
}

check_root_dependencies() { # root
    local deps
    deps=$(awk '
        /^Dependencies=/ { collecting = 1; print; next }
        collecting && /^[[:space:]]/ { print; next }
        collecting { exit }
    ' "$1/mkosi.conf")
    if printf '%s\n' "$deps" | grep -Eq '(^|[[:space:]])himmelblau([[:space:]]|$)'; then
        fail "root mkosi.conf Dependencies= still lists himmelblau"
        return 1
    fi
    pass "root mkosi.conf does not build himmelblau in the shared invocation"
}

check_build_workflow() { # root
    if ! python3 - "$1/.github/workflows/build.yml" "$scoped_invocation" "$just_invocation" <<'PY'
import re
import sys

path, scoped_invocation, just_invocation = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
lines = text.splitlines()


def bad(message):
    print(f"not ok - {message}", file=sys.stderr)
    raise SystemExit(1)


def job_lines(name):
    start = next((i for i, line in enumerate(lines) if line == f"  {name}:"), None)
    if start is None:
        bad(f"build.yml has no {name!r} job")
    end = next(
        (
            i
            for i in range(start + 1, len(lines))
            if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[i])
        ),
        len(lines),
    )
    return lines[start:end]


build = job_lines("build")
steps = []
current = None
for line in build:
    match = re.match(r"^      - name: (.*)$", line)
    if match:
        current = {"name": match.group(1), "lines": [line]}
        steps.append(current)
    elif current is not None:
        current["lines"].append(line)

for step in steps:
    step["text"] = "\n".join(step["lines"])


def step_named(name):
    matches = [index for index, step in enumerate(steps) if step["name"] == name]
    if len(matches) != 1:
        bad(f"build job must have exactly one step named {name!r}; found {len(matches)}")
    return matches[0]


if text.count(f"--sandbox-tree=shared/himmelblau/sandbox") != 1:
    bad("build.yml must pass --sandbox-tree=shared/himmelblau/sandbox exactly once")

main_index = step_named("Build main and sysexts")
main = steps[main_index]["text"]
if "sudo -E mkosi build" not in main:
    bad("'Build main and sysexts' no longer runs 'sudo -E mkosi build'")
if "sysextmv.sh" in main or "manifestmv.sh" in main:
    bad("'Build main and sysexts' must not move outputs; a later step collects both invocations")

himmelblau_index = step_named("Build himmelblau sysext (scoped third-party source)")
himmelblau = steps[himmelblau_index]["text"]
if scoped_invocation not in himmelblau:
    bad(f"himmelblau step does not pass {scoped_invocation}")
if "sudo -E mkosi " + just_invocation not in himmelblau:
    bad("himmelblau step does not run the scoped mkosi invocation")
if "continue-on-error: true" not in himmelblau:
    bad("himmelblau step must set continue-on-error: true")
if not re.search(r"^\s+id: himmelblau\s*$", himmelblau, re.M):
    bad("himmelblau step must set id: himmelblau")

collect_index = step_named("Collect sysext outputs")
collect = steps[collect_index]["text"]
if collect.count("sudo ./sysextmv.sh") != 1 or collect.count("sudo ./manifestmv.sh") != 1:
    bad("'Collect sysext outputs' must run sysextmv.sh and manifestmv.sh")
if collect.index("sudo ./sysextmv.sh") > collect.index("sudo ./manifestmv.sh"):
    bad("'Collect sysext outputs' must run sysextmv.sh before manifestmv.sh")

publish_indexes = [
    index
    for index, step in enumerate(steps)
    if "publish-to-r2" in step["text"] or "r2-upload-action" in step["text"]
]
if not publish_indexes:
    bad("build job has no publish steps")
if not collect_index < min(publish_indexes):
    bad("'Collect sysext outputs' must run before the publish steps")
if not himmelblau_index < collect_index:
    bad("the himmelblau build must run before 'Collect sysext outputs'")

fail_index = step_named("Fail when the himmelblau sysext did not build")
fail_step = steps[fail_index]["text"]
if "if: steps.himmelblau.outcome == 'failure'" not in fail_step:
    bad("final himmelblau check must run on steps.himmelblau.outcome == 'failure'")
if not re.search(r"^\s+exit 1\s*$", fail_step, re.M):
    bad("final himmelblau check must exit 1")
if "::error::" not in fail_step:
    bad("final himmelblau check must print a ::error:: annotation")
if not fail_index > max(publish_indexes):
    bad("final himmelblau check must run after the publish steps")
PY
    then
        return 1
    fi
    pass "build.yml runs the scoped himmelblau step and fails only after publishing"
}

check_other_workflows() { # root
    local workflow status=0
    for workflow in "$1"/.github/workflows/*.yml; do
        [[ ${workflow##*/} == build.yml ]] && continue
        if grep -qF -- "--sandbox-tree=$scoped_tree" "$workflow"; then
            fail "${workflow##*/} must never receive the himmelblau sandbox tree"
            status=1
        fi
    done
    if ((status == 0)); then
        pass "no workflow other than build.yml uses the himmelblau sandbox tree"
    fi
    return "$status"
}

check_justfile() { # root
    local body
    body=$(awk '
        $0 == "_sysexts: _clean" { collecting = 1; next }
        collecting && /^[^[:space:]#]/ { exit }
        collecting { print }
    ' "$1/Justfile")
    if [[ $body != *"$just_invocation"* ]]; then
        fail "_sysexts does not run the scoped himmelblau mkosi invocation"
        return 1
    fi
    if [[ $(grep -cF -- "--sandbox-tree=$scoped_tree" "$1/Justfile") -ne 1 ]]; then
        fail "Justfile may pass the himmelblau sandbox tree only in _sysexts"
        return 1
    fi
    pass "_sysexts builds himmelblau in the scoped second invocation"
}

check_all() { # root
    local status=0
    check_shared_sandbox_allowlist "$1" || status=1
    check_sandbox_has_no_himmelblau "$1" || status=1
    check_scoped_tree_complete "$1" || status=1
    check_root_dependencies "$1" || status=1
    check_build_workflow "$1" || status=1
    check_other_workflows "$1" || status=1
    check_justfile "$1" || status=1
    return "$status"
}

# Negative self-checks: a guard that cannot fail is not a guard. Each fixture
# copies only the files the checks read into a temporary root.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fixture_root() { # name
    local dir="$tmp/$1"
    mkdir -p "$dir/mkosi.sandbox/etc/apt/sources.list.d" \
        "$dir/mkosi.sandbox/etc/apt/keyrings" \
        "$dir/$scoped_tree/etc/apt/sources.list.d" \
        "$dir/$scoped_tree/etc/apt/keyrings" \
        "$dir/.github/workflows"
    local name
    for name in "${third_party_allowlist[@]}"; do
        : >"$dir/mkosi.sandbox/etc/apt/sources.list.d/$name.sources"
    done
    : >"$dir/$scoped_tree/etc/apt/sources.list.d/himmelblau.sources"
    : >"$dir/$scoped_tree/etc/apt/keyrings/himmelblau.gpg"
    {
        echo '[Config]'
        echo 'Dependencies=base'
        echo '             incus'
        echo
        echo '[Distribution]'
    } >"$dir/mkosi.conf"
    cp "$root/.github/workflows/build.yml" "$dir/.github/workflows/build.yml"
    cp "$root/Justfile" "$dir/Justfile"
    printf '%s\n' "$dir"
}

expect_failure() { # description function root
    local description=$1 function=$2 dir=$3
    # Subshell: the fixture's own "not ok" lines must not reach the counters.
    if ( "$function" "$dir" ) >/dev/null 2>&1; then
        fail "self-check: $description was not detected"
    else
        pass "self-check: $description is detected"
    fi
}

# A new third-party source in the shared sandbox.
dir=$(fixture_root scoped-source)
: >"$dir/mkosi.sandbox/etc/apt/sources.list.d/example.sources"
expect_failure "unallowlisted shared APT source" check_shared_sandbox_allowlist "$dir"

# An apt *.list source in the shared sandbox (apt reads these too).
dir=$(fixture_root apt-list-source)
: >"$dir/mkosi.sandbox/etc/apt/sources.list.d/extra.list"
expect_failure "*.list source in the shared sandbox" check_shared_sandbox_allowlist "$dir"

# A monolithic sources.list in the shared sandbox.
dir=$(fixture_root sources-list-file)
: >"$dir/mkosi.sandbox/etc/apt/sources.list"
expect_failure "mkosi.sandbox/etc/apt/sources.list" check_shared_sandbox_allowlist "$dir"

# The himmelblau source put back into the shared sandbox.
dir=$(fixture_root himmelblau-in-sandbox)
cp "$dir/$scoped_tree/etc/apt/sources.list.d/himmelblau.sources" \
    "$dir/mkosi.sandbox/etc/apt/sources.list.d/himmelblau.sources"
cp "$dir/$scoped_tree/etc/apt/keyrings/himmelblau.gpg" \
    "$dir/mkosi.sandbox/etc/apt/keyrings/himmelblau.gpg"
expect_failure "himmelblau source and key in the shared sandbox" \
    check_shared_sandbox_allowlist "$dir"
if ( check_sandbox_has_no_himmelblau "$dir" ) >/dev/null 2>&1; then
    fail "self-check: himmelblau key in the shared sandbox was not detected"
else
    pass "self-check: himmelblau key in the shared sandbox is detected"
fi

# himmelblau back in the root Dependencies= list.
dir=$(fixture_root dependency)
sed -i '/^Dependencies=base$/a\             himmelblau' "$dir/mkosi.conf"
expect_failure "himmelblau in the root Dependencies= list" check_root_dependencies "$dir"

# The scoped invocation dropped from the workflow.
dir=$(fixture_root workflow)
sed -i '/^      - name: Fail when the himmelblau sysext did not build$/,$d' \
    "$dir/.github/workflows/build.yml"
expect_failure "missing final himmelblau fail step" check_build_workflow "$dir"

# The scoped invocation dropped from the Justfile target.
dir=$(fixture_root justfile)
sed -i '/--sandbox-tree=shared\/himmelblau\/sandbox --incremental=no --cache-only=never build$/d' "$dir/Justfile"
expect_failure "missing scoped invocation in _sysexts" check_justfile "$dir"

# The metadata sync flag dropped from the Justfile invocation.
dir=$(fixture_root justfile-cache-only)
sed -i 's/ --cache-only=never//' "$dir/Justfile"
expect_failure "missing --cache-only=never in _sysexts" check_justfile "$dir"

# The non-incremental flag dropped from the Justfile invocation.
dir=$(fixture_root justfile-incremental)
sed -i 's/ --incremental=no//' "$dir/Justfile"
expect_failure "missing --incremental=no in _sysexts" check_justfile "$dir"

# The metadata sync flag dropped from the workflow invocation.
dir=$(fixture_root workflow-cache-only)
sed -i 's/ --cache-only=never//' "$dir/.github/workflows/build.yml"
expect_failure "missing --cache-only=never in build.yml" check_build_workflow "$dir"

check_all "$root" || true

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
