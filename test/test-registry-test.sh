#!/usr/bin/env bash
# Guard for test/registry.tsv — the declarative inventory of the test/ suite.
#
# The repository has no test discovery glob: a test becomes live only by being
# named by hand in a .github/workflows/*.yml step. That wiring step is an
# unenforced convention, and it has been missed (frostyard/snosi#851).
#
# This guard makes the registry the checkable contract. It is deliberately
# NOT fail-closed on unregistered new files, so that in-flight branches adding
# test scripts do not break on merge; it is fail-closed on every way an
# existing, recorded execution path can silently disappear:
#   1. every registry entry names a file that exists under test/
#   2. every entry's class is one of ci|nested|helper|unwired
#   3. every 'ci' entry is referenced by each workflow it names, and those
#      workflows exist  -> catches a test dropped from a workflow step
#   4. every 'nested' entry is referenced by the test/ script it names
#      -> catches a test dropped from its parent test
#   5. no 'helper' or 'unwired' entry is referenced by any workflow
#      -> catches a stale registry that under-reports live coverage
#   6. no duplicate entries
#
# NOTE: this guard is itself listed as `unwired` in test/registry.tsv -- it has
# no runner yet, because wiring it needs a .github/workflows/ change. See the
# Test Registry section of docs/design/testing.md for the exact step to add.
#
# Hermetic: no network, no root, no image build.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

registry="test/registry.tsv"
workflows=".github/workflows"

rc=0
checks=0

ok() {
    checks=$((checks + 1))
    printf 'ok - %s\n' "$1"
}

not_ok() {
    checks=$((checks + 1))
    rc=1
    printf 'not ok - %s\n' "$1"
}

[ -f "$registry" ] || {
    printf 'not ok - %s is missing\n' "$registry"
    exit 1
}

[ -d "$workflows" ] || {
    printf 'not ok - %s is missing\n' "$workflows"
    exit 1
}

# Strip comments and blank lines once; every check reads this.
entries="$(grep -v '^[[:space:]]*#' "$registry" | grep -v '^[[:space:]]*$' || true)"

[ -n "$entries" ] || {
    printf 'not ok - %s declares no entries\n' "$registry"
    exit 1
}

# 6. no duplicate entries
dupes="$(printf '%s\n' "$entries" | cut -f1 | sort | uniq -d)"
if [ -n "$dupes" ]; then
    not_ok "$registry lists duplicate tests: $(printf '%s' "$dupes" | paste -sd' ' -)"
else
    ok "$registry has no duplicate entries"
fi

# Does any workflow reference test/<name>?
referencing_workflows() {
    grep -rl -- "test/$1" "$workflows" 2>/dev/null | xargs -n1 basename 2>/dev/null | sort -u || true
}

while IFS=$'\t' read -r name class runner; do
    [ -n "${name:-}" ] || continue

    # 1. the entry names a real file
    if [ ! -f "test/$name" ]; then
        not_ok "registry entry '$name' names no file under test/"
        continue
    fi

    case "$class" in
    ci)
        # 3. each named workflow exists and still references the test
        missing=""
        IFS=',' read -r -a wfs <<<"$runner"
        for wf in "${wfs[@]}"; do
            [ -n "$wf" ] || continue
            if [ ! -f "$workflows/$wf" ]; then
                missing="$missing $wf(absent)"
            elif ! grep -q -- "test/$name" "$workflows/$wf"; then
                missing="$missing $wf(no-reference)"
            fi
        done
        if [ -n "$missing" ]; then
            not_ok "ci test '$name' is no longer wired into:$missing"
        else
            ok "ci test '$name' is wired into $runner"
        fi
        ;;
    nested)
        # 4. the named parent test still invokes it
        if [ ! -f "test/$runner" ]; then
            not_ok "nested test '$name' names absent runner 'test/$runner'"
        elif ! grep -q -- "$name" "test/$runner"; then
            not_ok "nested test '$name' is no longer invoked by test/$runner"
        else
            ok "nested test '$name' is invoked by test/$runner"
        fi
        ;;
    helper | unwired)
        # 5. registry must not under-report live coverage
        found="$(referencing_workflows "$name" | paste -sd, -)"
        if [ -n "$found" ]; then
            not_ok "'$name' is classed '$class' but is referenced by $found; reclassify it as 'ci'"
        else
            ok "'$name' is classed '$class' and is referenced by no workflow"
        fi
        ;;
    *)
        # 2. unknown class
        not_ok "registry entry '$name' has unknown class '$class'"
        ;;
    esac
done <<<"$entries"

printf '\n%d checks, %s\n' "$checks" "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)"
exit "$rc"
