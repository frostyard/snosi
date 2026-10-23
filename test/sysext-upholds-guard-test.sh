#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture suite for shared/sysext/finalize/sysext-upholds-guard.sh (snosi#1100,
# #1113): a unit upheld from a sysext delta must not carry a Condition*=
# unless it is a RemainAfterExit=yes oneshot. Targets resolve in the delta,
# then in the base tree (package-shipped units). See docs/design/sysexts.md
# "Service Activation Pattern (Upholds=)".
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$root/shared/sysext/finalize/sysext-upholds-guard.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

UNITS=usr/lib/systemd/system
test_number=0
failures=0
case_dir=""
delta=""
base=""

new_case() { # name -> fresh delta/ and base/ trees
    case_dir="$work/$1"
    delta="$case_dir/delta"
    base="$case_dir/base"
    mkdir -p "$delta/$UNITS" "$base/$UNITS" "$case_dir/src"
}

put() { # tree-root relative-path content...
    local f="$1/$2"
    shift 2
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$@" >"$f"
}

uphold() { # target...   (delta multi-user.target drop-in)
    put "$delta" "$UNITS/multi-user.target.d/10-x.conf" '[Unit]' "Upholds=$*"
}

# run_guard -> sets out, status
run_guard() {
    if out=$(BUILDROOT="$delta" SRCDIR="$case_dir/src" IMAGE_ID=testext \
        SNOSI_SYSEXT_BASE_TREE="$base" "$guard" 2>&1); then
        status=0
    else
        status=$?
    fi
}

# check name expected_status [expected_output ...]
check() {
    local name=$1 want_status=$2 want ok=1
    shift 2
    for want in "$@"; do
        [[ $out == *"$want"* ]] || ok=0
    done
    test_number=$((test_number + 1))
    if ((status == want_status && ok == 1)); then
        printf 'ok %d - %s\n' "$test_number" "$name"
    else
        printf 'not ok %d - %s\n' "$test_number" "$name"
        printf '# expected status %d, got %d\n' "$want_status" "$status"
        printf '# expected output to contain: %s\n' "$*"
        while IFS= read -r line; do printf '#   %s\n' "$line"; done <<<"$out"
        failures=$((failures + 1))
    fi
}

svc() { printf '%s\n' '[Unit]' 'Description=x' "$@" '[Service]' 'ExecStart=/bin/true'; }

# --- (a) pass: no condition in the delta ------------------------------------
new_case plain
uphold app.service
svc >"$delta/$UNITS/app.service"
run_guard
check "upheld unit without a condition passes" 0 "testext OK (1 upheld units checked)"

# --- (b) fail: conditioned simple service -----------------------------------
new_case cond
uphold app.service
svc 'ConditionPathExists=/etc/app.conf' >"$delta/$UNITS/app.service"
run_guard
check "conditioned simple service fails" 1 \
    "delta:$UNITS/app.service:3" "app.service is upheld by delta:$UNITS/multi-user.target.d/10-x.conf:2" \
    "ConditionPathExists=/etc/app.conf" "snosi#1100"

# --- (c) pass: conditioned oneshot + RemainAfterExit ------------------------
new_case oneshot
uphold app.service
put "$delta" "$UNITS/app.service" '[Unit]' 'ConditionPathExists=/etc/app.conf' \
    '[Service]' 'Type=oneshot' 'RemainAfterExit=yes' 'ExecStart=/bin/true'
run_guard
check "conditioned Type=oneshot + RemainAfterExit=yes passes" 0 "OK (1 upheld units checked)"

new_case oneshot-no-rae
uphold app.service
put "$delta" "$UNITS/app.service" '[Unit]' 'ConditionPathExists=/etc/app.conf' \
    '[Service]' 'Type=oneshot' 'ExecStart=/bin/true'
run_guard
check "conditioned oneshot without RemainAfterExit fails" 1 "app.service is upheld"

# --- (d) fail: unresolved target --------------------------------------------
new_case unresolved
uphold typo.service
run_guard
check "unresolved target fails" 1 "typo.service is upheld but has no unit file or drop-in"

# --- base tree --------------------------------------------------------------
new_case base-only
uphold app.service
svc 'ConditionPathExists=/etc/app.conf' >"$base/$UNITS/app.service"
run_guard
check "conditioned unit only in the base tree fails" 1 "base:$UNITS/app.service:3"

new_case base-only-ok
uphold app.service
svc >"$base/$UNITS/app.service"
run_guard
check "unit only in the base tree passes" 0 "OK (1 upheld units checked)"

new_case base-dropin-cond
uphold app.service
svc >"$base/$UNITS/app.service"
put "$delta" "$UNITS/app.service.d/10-cond.conf" '[Unit]' 'ConditionPathExists=/etc/x'
run_guard
check "base main unit plus a delta drop-in that adds a Condition fails" 1 \
    "delta:$UNITS/app.service.d/10-cond.conf:2" "app.service is upheld"

new_case dropin-override
uphold app.service
svc >"$base/$UNITS/app.service"
put "$base" "$UNITS/app.service.d/10-cond.conf" '[Unit]' 'ConditionPathExists=/etc/x'
put "$delta" "$UNITS/app.service.d/10-cond.conf" '[Unit]' 'Description=cleared'
run_guard
check "a delta drop-in overrides the base drop-in of the same name" 0 "OK (1 upheld units checked)"

new_case dropin-base-cond
uphold app.service
svc >"$base/$UNITS/app.service"
put "$base" "$UNITS/app.service.d/10-cond.conf" '[Unit]' 'ConditionPathExists=/etc/x'
run_guard
check "a base drop-in with a Condition fails" 1 "base:$UNITS/app.service.d/10-cond.conf:2"

# --- last assignment wins ---------------------------------------------------
new_case rae-dropin
uphold app.service
put "$delta" "$UNITS/app.service" '[Unit]' 'ConditionPathExists=/etc/x' '[Service]' 'Type=oneshot'
put "$delta" "$UNITS/app.service.d/10-rae.conf" '[Service]' 'RemainAfterExit=yes'
run_guard
check "RemainAfterExit=yes from a drop-in passes" 0 "OK (1 upheld units checked)"

new_case rae-reset
uphold app.service
put "$delta" "$UNITS/app.service" '[Unit]' 'ConditionPathExists=/etc/x' \
    '[Service]' 'Type=oneshot' 'RemainAfterExit=yes'
put "$delta" "$UNITS/app.service.d/90-off.conf" '[Service]' 'RemainAfterExit=no'
run_guard
check "a later drop-in setting RemainAfterExit=no fails" 1 "app.service is upheld"

# --- allow comment ----------------------------------------------------------
new_case allow
uphold app.service
svc '# upholds-guard-allow: the path always exists' 'ConditionPathExists=/usr' \
    >"$delta/$UNITS/app.service"
run_guard
check "allow comment directly above exempts the condition" 0 "OK (1 upheld units checked)"

new_case allow-inline
uphold app.service
svc 'ConditionPathExists=/usr # upholds-guard-allow: nope' >"$delta/$UNITS/app.service"
run_guard
check "a trailing inline allow comment does not exempt" 1 "app.service is upheld"

new_case allow-gap
uphold app.service
svc '# upholds-guard-allow: gap' '' 'ConditionPathExists=/usr' >"$delta/$UNITS/app.service"
run_guard
check "an allow comment not directly above does not exempt" 1 "app.service is upheld"

# --- instances, masks, aliases ----------------------------------------------
new_case instance
uphold 'app@one.service'
svc 'ConditionPathExists=/etc/x' >"$base/$UNITS/app@.service"
run_guard
check "an instance resolves through its template" 1 \
    "base:$UNITS/app@.service:3" "app@one.service is upheld"

new_case instance-ok
uphold 'app@one.service'
svc >"$delta/$UNITS/app@.service"
run_guard
check "an instance of an unconditioned template passes" 0 "OK (1 upheld units checked)"

new_case instance-dropin
uphold 'app@one.service'
svc >"$delta/$UNITS/app@.service"
put "$base" "$UNITS/app@.service.d/10-cond.conf" '[Unit]' 'ConditionPathExists=/etc/x'
run_guard
check "a template drop-in applies to an instance" 1 "base:$UNITS/app@.service.d/10-cond.conf:2"

new_case mask
uphold app.service
ln -s /dev/null "$delta/$UNITS/app.service"
run_guard
check "a /dev/null mask fails" 1 "app.service is upheld but masked" "delta:$UNITS/app.service"

new_case mask-base
uphold app.service
svc >"$base/$UNITS/app.service"
ln -s /dev/null "$delta/$UNITS/app.service"
run_guard
check "a delta mask of a base unit fails" 1 "app.service is upheld but masked"

new_case alias
uphold alias.service
svc 'ConditionPathExists=/etc/x' >"$base/$UNITS/real.service"
ln -s real.service "$delta/$UNITS/alias.service"
run_guard
check "an alias symlink resolves to its target unit" 1 "base:$UNITS/real.service:3" "alias.service is upheld"

new_case alias-ok
uphold alias.service
svc >"$delta/$UNITS/real.service"
ln -s /usr/lib/systemd/system/real.service "$delta/$UNITS/alias.service"
run_guard
check "an alias with an absolute target resolves and passes" 0 "OK (1 upheld units checked)"

new_case alias-dangling
uphold alias.service
ln -s gone.service "$delta/$UNITS/alias.service"
run_guard
check "an alias to a missing unit fails" 1 "alias points to gone.service"

new_case alias-loop
uphold a.service
ln -s b.service "$delta/$UNITS/a.service"
ln -s a.service "$delta/$UNITS/b.service"
run_guard
check "an alias loop fails" 1 "longer than 8 hops"

# --- targets and values -----------------------------------------------------
new_case dropin-only
uphold app.service
put "$delta" "$UNITS/app.service.d/10-x.conf" '[Unit]' 'Description=x'
run_guard
check "a target with only a drop-in resolves" 0 "OK (1 upheld units checked)"

new_case multi
uphold a.service b.service a.service ''
svc >"$delta/$UNITS/a.service"
svc 'ConditionPathExists=/x' >"$delta/$UNITS/b.service"
put "$delta" "$UNITS/graphical.target.d/10-y.conf" '[Unit]' 'Upholds=' 'Upholds=c.service'
run_guard
check "all violations are reported, values deduplicated, empty reset ignored" 1 \
    "b.service is upheld" "c.service is upheld but has no unit file" "has violations"

new_case no-upholds
svc 'ConditionPathExists=/x' >"$delta/$UNITS/app.service"
run_guard
check "a delta with no Upholds= passes" 0 "testext OK (0 upheld units checked)"

new_case empty-reset
put "$delta" "$UNITS/multi-user.target.d/10-x.conf" '[Unit]' 'Upholds='
run_guard
check "an empty Upholds= reset is ignored" 0 "OK (0 upheld units checked)"

# --- base tree location -----------------------------------------------------
new_case no-base
uphold app.service
svc >"$delta/$UNITS/app.service"
rm -rf "$base"
run_guard
check "a missing base tree fails instead of passing vacuously" 1 "is not a directory" "vacuously"

new_case default-base
uphold app.service
mkdir -p "$case_dir/src/output/base/$UNITS"
svc 'ConditionPathExists=/x' >"$case_dir/src/output/base/$UNITS/app.service"
if out=$(env -u SNOSI_SYSEXT_BASE_TREE -u MKOSI_CONFIG BUILDROOT="$delta" SRCDIR="$case_dir/src" \
    IMAGE_ID=testext "$guard" 2>&1); then status=0; else status=$?; fi
check "without MKOSI_CONFIG the base tree is \$SRCDIR/output/base" 1 "base:$UNITS/app.service:3"

new_case mkosi-config
uphold app.service
host="$case_dir/host-checkout"
mkdir -p "$host" "$case_dir/src/output/gui-base/$UNITS"
svc 'ConditionPathExists=/x' >"$case_dir/src/output/gui-base/$UNITS/app.service"
jq -n --arg h "$host" \
    '{BaseTrees: [($h + "/output/gui-base")], BuildSources: [{Source: "/elsewhere", Target: "/x"}, {Source: $h, Target: null}]}' \
    >"$case_dir/config.json"
if out=$(env -u SNOSI_SYSEXT_BASE_TREE MKOSI_CONFIG="$case_dir/config.json" BUILDROOT="$delta" \
    SRCDIR="$case_dir/src" IMAGE_ID=testext "$guard" 2>&1); then status=0; else status=$?; fi
check "the base tree is mapped from MKOSI_CONFIG BaseTrees and BuildSources" 1 "base:$UNITS/app.service:3"

new_case mkosi-config-missing
uphold app.service
host="$case_dir/host-checkout"
jq -n --arg h "$host" '{BaseTrees: [($h + "/output/nope")], BuildSources: [{Source: $h, Target: null}]}' \
    >"$case_dir/config.json"
if out=$(env -u SNOSI_SYSEXT_BASE_TREE MKOSI_CONFIG="$case_dir/config.json" BUILDROOT="$delta" \
    SRCDIR="$case_dir/src" IMAGE_ID=testext "$guard" 2>&1); then status=0; else status=$?; fi
check "a base tree mapped from MKOSI_CONFIG that is missing fails" 1 "$case_dir/src/output/nope is not a directory"

# --- wiring -----------------------------------------------------------------
mapfile -t configs < <(git -C "$root" ls-files -- 'mkosi.images/*/mkosi.conf')
wired=0
unwired=0
for config in "${configs[@]}"; do
    grep -Eq '^[[:space:]]*Overlay[[:space:]]*=[[:space:]]*yes' "$root/$config" || continue
    if grep -E '^[[:space:]]*FinalizeScripts=' "$root/$config" |
        grep -Fq '%D/shared/sysext/finalize/sysext-upholds-guard.sh'; then
        wired=$((wired + 1))
    else
        unwired=$((unwired + 1))
        echo "# ${config%/mkosi.conf} does not wire sysext-upholds-guard.sh"
    fi
done
test_number=$((test_number + 1))
if ((wired > 0 && unwired == 0)); then
    echo "ok $test_number - $wired sysexts wire sysext-upholds-guard.sh"
else
    echo "not ok $test_number - every Overlay=yes sysext wires sysext-upholds-guard.sh ($unwired missing)"
    failures=$((failures + 1))
fi

echo
echo "# Results: $((test_number - failures)) passed, $failures failed, $test_number total"
((failures == 0))
