#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture suite for shared/sysext/finalize/sysext-lodge-accounts-guard.sh
# (snosi#1245): the Lodge app daemons resolve the system user lodge at start,
# so a Lodge app sysext must ship lodge's own sysusers line, the lodge sysext
# must ship it in its own file, and every account a system unit names must be
# declared by the delta's sysusers.d files. A repository check requires the
# finalizer in the five suite sysexts. See docs/design/sysexts.md and ADR-0035.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$root/shared/sysext/finalize/sysext-lodge-accounts-guard.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

UNITS=usr/lib/systemd/system
SYSUSERS=usr/lib/sysusers.d
APPS=usr/share/lodge/apps
LODGE_USER_LINE="u lodge - \"lodge, the tailnet web shell for frostyard's apps\" /var/lib/lodge"
SUITE="lodge notesd maild porterd readd"
test_number=0
failures=0
delta=""

new_case() { # name -> fresh delta/ tree
    delta="$work/$1/delta"
    mkdir -p "$delta/usr/lib"
}

put() { # tree-root relative-path content...
    local f="$1/$2"
    shift 2
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$@" >"$f"
}

run_guard() { # -> sets out, status
    if out=$(BUILDROOT="$delta" IMAGE_ID=testext "$guard" 2>&1); then
        status=0
    else
        status=$?
    fi
}

check() { # name expected_status [expected_output ...]
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

# The maild 0.2.0 shape: a Lodge app, units naming user frostmail and group
# lodge, groups lodge and lodge-apps declared, user lodge missing.
old_shape() { # tree-root [sysusers extra line ...]
    local tree=$1
    shift
    put "$tree" "$APPS/mail/app.json" '{"name": "mail"}'
    put "$tree" "$UNITS/frostmail.service" \
        '[Service]' 'User=frostmail' 'Group=frostmail' 'ExecStart=/bin/true'
    put "$tree" "$UNITS/frostmail.socket" \
        '[Socket]' 'SocketUser=frostmail' 'SocketGroup=lodge' 'ListenStream=/run/frostmail/sock'
    put "$tree" "$SYSUSERS/frostmail.conf" \
        'u frostmail - "Frostmail mail engine" /var/lib/frostmail' \
        'g lodge -' 'g lodge-apps -' 'm frostmail lodge-apps' "$@"
}

new_case empty-delta
run_guard
check "empty delta passes" 0 "OK (system units: 0, drop-ins: 0, sysusers files: 0"

new_case no-app-no-lodge
put "$delta" usr/bin/tool '#!/bin/sh'
run_guard
check "a delta without a Lodge app, lodge.conf or units passes" 0 "OK (system units: 0, drop-ins: 0"

new_case old-maild
old_shape "$delta"
run_guard
check "maild 0.2.0 shape without user lodge fails" 1 \
    "user lodge" "#1245" "no /$SYSUSERS/*.conf declares user lodge"

new_case old-maild-fixed
old_shape "$delta" "$LODGE_USER_LINE"
run_guard
check "maild shape with lodge's own line passes" 0 "OK (system units: 2"

new_case wrong-gecos
old_shape "$delta" 'u lodge - "the lodge user" /var/lib/lodge'
run_guard
check "a user lodge line with another GECOS fails" 1 "user lodge" "#1245"

new_case lodge-sysext-empty
put "$delta" "$SYSUSERS/lodge.conf" \
    'g lodge-apps -' 'm lodge lodge-apps'
put "$delta" "$UNITS/lodge.service" '[Service]' 'User=lodge' 'Group=lodge'
run_guard
check "the lodge sysext without its user line fails" 1 \
    "no line: u lodge -" "byte for byte"

new_case lodge-sysext
put "$delta" "$SYSUSERS/lodge.conf" \
    'u lodge - "lodge, the tailnet web shell for frostyard'"'"'s apps" /var/lib/lodge' \
    'g lodge-apps -' 'm lodge lodge-apps'
put "$delta" "$UNITS/lodge.service" '[Service]' 'User=lodge' 'Group=lodge'
run_guard
check "the lodge sysext with its user line passes" 0 "OK (system units: 1"

new_case app-line-in-lodge-conf
put "$delta" "$APPS/notes/app.json" '{"name": "notes"}'
put "$delta" "$SYSUSERS/other.conf" "$LODGE_USER_LINE"
run_guard
check "the line in any sysusers file counts for an app" 0 "OK (system units: 0, drop-ins: 0, sysusers files: 1, Lodge apps: 1)"

new_case undeclared-socket-user
put "$delta" "$UNITS/frostnotes-lodge.socket" \
    '[Socket]' 'SocketUser=frostnotes' 'SocketGroup=lodge' 'ListenStream=/run/x/sock'
put "$delta" "$SYSUSERS/frostnotes.conf" 'g lodge -'
run_guard
check "a socket user that no sysusers file declares fails" 1 \
    "names user frostnotes" "add a u line for it"

new_case group-from-membership
put "$delta" "$UNITS/frostnotes.service" \
    '[Service]' 'User=frostnotes' 'Group=lodge-apps' 'ExecStart=/bin/true'
put "$delta" "$SYSUSERS/frostnotes.conf" \
    'u frostnotes - "Frostnotes notes daemon" /var/lib/frostnotes' \
    'm frostnotes lodge-apps'
run_guard
check "a group of an m line counts as declared" 0 "OK (system units: 1"

new_case undeclared-group
put "$delta" "$UNITS/frostnotes.socket" \
    '[Socket]' 'SocketGroup=lodge-apps' 'ListenStream=/run/x/sock'
put "$delta" "$SYSUSERS/frostnotes.conf" 'u frostnotes - "Frostnotes" /var/lib/frostnotes'
run_guard
check "a socket group that no sysusers file declares fails" 1 \
    "names group lodge-apps" "an m line whose second field is"

new_case dynamic-user
put "$delta" "$UNITS/app.service" \
    '[Service]' 'DynamicUser=yes' 'User=foo' 'Group=foo' 'ExecStart=/bin/true'
run_guard
check "a DynamicUser=yes unit skips User= and Group=" 0 "OK (system units: 1, drop-ins: 0, sysusers files: 0"

new_case root-and-numeric
put "$delta" "$UNITS/app.service" \
    '[Service]' 'User=root' 'Group=0' 'ExecStart=/bin/true'
put "$delta" "$UNITS/other.service" \
    '[Service]' 'User=  root  ' 'ExecStart=/bin/true'
run_guard
check "root and numeric ids need no sysusers line" 0 "OK (system units: 2"

new_case specifier
put "$delta" "$UNITS/app.service" \
    '[Service]' 'User=%i' 'Group=app' 'ExecStart=/bin/true'
put "$delta" "$SYSUSERS/app.conf" 'g app -'
run_guard
check "a specifier is not checked" 0 "OK (system units: 1"

new_case empty-value
put "$delta" "$UNITS/app.service" '[Service]' 'User=' 'ExecStart=/bin/true'
run_guard
check "an empty value is not checked" 0 "OK (system units: 1"

new_case comments-only-sysusers
put "$delta" "$UNITS/app.service" '[Service]' 'User=app' 'ExecStart=/bin/true'
put "$delta" "$SYSUSERS/app.conf" '# u app - "App" /var/lib/app' ''
run_guard
check "a commented sysusers line declares nothing" 1 "names user app"

# --- rule 3: no account key in a drop-in, unit files only -------------------
new_case dropin-user
put "$delta" "$UNITS/frostmail.service" '[Service]' 'User=frostmail' 'ExecStart=/bin/true'
put "$delta" "$UNITS/frostmail.service.d/10-user.conf" '[Service]' 'User=missing'
put "$delta" "$SYSUSERS/frostmail.conf" 'u frostmail - "Frostmail" /var/lib/frostmail'
run_guard
check "a drop-in that sets User= fails closed" 1 \
    "10-user.conf sets User= in a drop-in" "set it in the unit file"

new_case type-wide-dropin
put "$delta" "$UNITS/service.d/10.conf" '[Service]' 'User=x'
run_guard
check "a type-wide service.d drop-in that sets User= fails closed" 1 \
    "service.d/10.conf sets User="

new_case prefix-dropin
put "$delta" "$UNITS/frost-.service.d/10.conf" '[Service]' 'SupplementaryGroups=x'
run_guard
check "a prefix drop-in that sets SupplementaryGroups= fails closed" 1 \
    "frost-.service.d/10.conf sets SupplementaryGroups="

new_case template-dropin
put "$delta" "$UNITS/app@.service" '[Service]' 'ExecStart=/bin/true'
put "$delta" "$UNITS/app@.service.d/10.conf" '[Service]' 'DynamicUser=no'
run_guard
check "a template drop-in that sets DynamicUser= fails closed" 1 \
    "app@.service.d/10.conf sets DynamicUser="

new_case dropin-other-section
put "$delta" "$UNITS/app.service" '[Service]' 'User=app' 'ExecStart=/bin/true'
put "$delta" "$UNITS/app.service.d/10-x.conf" '[Unit]' 'SocketGroup=ghost'
put "$delta" "$SYSUSERS/app.conf" 'u app - "App" /var/lib/app'
run_guard
check "an account key outside its section in a drop-in still fails closed" 1 \
    "10-x.conf sets SocketGroup="

new_case target-dropin
put "$delta" "$UNITS/multi-user.target.d/10-x.conf" '[Unit]' 'Upholds=a.service'
run_guard
check "a Upholds= drop-in passes" 0 "OK (system units: 0, drop-ins: 1"

new_case harmless-dropin
put "$delta" "$UNITS/app.service" '[Service]' 'User=app' 'ExecStart=/bin/true'
put "$delta" "$UNITS/app.service.d/10-env.conf" '[Service]' 'Environment=A=1'
put "$delta" "$SYSUSERS/app.conf" 'u app - "App" /var/lib/app'
run_guard
check "a drop-in without an account key passes" 0 "OK (system units: 1, drop-ins: 1"

new_case comment-only-dropin
put "$delta" "$UNITS/app.service" '[Service]' 'User=app' 'ExecStart=/bin/true'
put "$delta" "$UNITS/app.service.d/10-x.conf" '# User=missing' '[Service]' '; User=missing2'
put "$delta" "$SYSUSERS/app.conf" 'u app - "App" /var/lib/app'
run_guard
check "an account key in a drop-in comment passes" 0 "OK (system units: 1, drop-ins: 1"

new_case dynamic-with-supplementary
put "$delta" "$UNITS/app.service" \
    '[Service]' 'DynamicUser=yes' 'SupplementaryGroups=missing' 'ExecStart=/bin/true'
run_guard
check "SupplementaryGroups= is checked for a dynamic user" 1 "names group missing"

new_case comment-continuation
put "$delta" "$UNITS/app.service" '[Service]' 'ExecStart=/bin/true' "# note \\" 'User=missing'
run_guard
check "a comment ending with a backslash does not swallow the next line" 1 \
    "names user missing"

new_case continuation-with-comment
put "$delta" "$UNITS/app.service" \
    '[Service]' 'User=app' "SupplementaryGroups=a \\" '# comment' 'b'
put "$delta" "$SYSUSERS/app.conf" 'u app - "App" /var/lib/app' 'g a -'
run_guard
check "a comment inside a continued value is dropped" 1 "names group b"

new_case template-unit
put "$delta" "$UNITS/app@.service" '[Service]' 'User=missing' 'ExecStart=/bin/true'
run_guard
check "a template unit file is checked as a file" 1 "names user missing"

new_case template-specifier
put "$delta" "$UNITS/app@.service" '[Service]' 'User=%i' 'ExecStart=/bin/true'
run_guard
check "a template unit specifier is not checked" 0 "OK (system units: 1"

new_case supplementary-group-missing
put "$delta" "$UNITS/frostporter.service" \
    '[Service]' 'User=frostporter' 'SupplementaryGroups=lodge-apps lodge-agents'
put "$delta" "$SYSUSERS/frostporter.conf" \
    'u frostporter - "Porter" /var/lib/frostporter' 'm frostporter lodge-apps'
run_guard
check "an undeclared SupplementaryGroups= entry fails" 1 "names group lodge-agents"

new_case supplementary-group-declared
put "$delta" "$UNITS/frostporter.service" \
    '[Service]' 'User=frostporter' 'SupplementaryGroups=lodge-apps lodge-agents'
put "$delta" "$SYSUSERS/frostporter.conf" \
    'u frostporter - "Porter" /var/lib/frostporter' \
    'm frostporter lodge-apps' 'g lodge-agents -'
run_guard
check "declared SupplementaryGroups= entries pass" 0 "OK (system units: 1"

new_case supplementary-reset
put "$delta" "$UNITS/app.service" \
    '[Service]' 'User=app' 'SupplementaryGroups=bad' 'SupplementaryGroups=' 'SupplementaryGroups=good'
put "$delta" "$SYSUSERS/app.conf" 'u app - "App" /var/lib/app' 'g good -'
run_guard
check "an empty SupplementaryGroups= clears the list" 0 "OK (system units: 1"

new_case dynamic-then-static
put "$delta" "$UNITS/app.service" \
    '[Service]' 'DynamicUser=yes' 'DynamicUser=no' 'User=missing' 'ExecStart=/bin/true'
run_guard
check "DynamicUser=no after yes does not skip the account checks" 1 "names user missing"

new_case last-assignment-wins
put "$delta" "$UNITS/app.service" \
    '[Service]' 'User=missing' 'User=ok' 'ExecStart=/bin/true'
put "$delta" "$SYSUSERS/app.conf" 'u ok - "Ok" /var/lib/ok'
run_guard
check "the last User= assignment wins" 0 "OK (system units: 1"

new_case wrong-section
put "$delta" "$UNITS/app.service" \
    '[Unit]' 'User=missing1' '[Service]' 'ExecStart=/bin/true' '[Install]' 'User=missing2'
run_guard
check "User= outside [Service] is not checked" 0 "OK (system units: 1"

new_case line-continuation
put "$delta" "$UNITS/app.service" \
    '[Service]' 'User=app' "SupplementaryGroups=a \\" 'b'
put "$delta" "$SYSUSERS/app.conf" 'u app - "App" /var/lib/app' 'g a -'
run_guard
check "a continued line names its second account" 1 "names group b"

new_case locked-user
put "$delta" "$UNITS/app.service" '[Service]' 'User=locked' 'ExecStart=/bin/true'
put "$delta" "$SYSUSERS/app.conf" 'u! locked - "App" /'
run_guard
check "a u! line declares its user" 0 "OK (system units: 1"

# --- repository check -------------------------------------------------------
# The five suite sysexts wire the guard, and no other sysext does.
for name in $SUITE; do
    config="$root/mkosi.images/$name/mkosi.conf"
    test_number=$((test_number + 1))
    if grep -E '^[[:space:]]*FinalizeScripts=' "$config" |
        grep -Fq 'sysext-lodge-accounts-guard.sh'; then
        printf 'ok %d - %s wires sysext-lodge-accounts-guard.sh\n' "$test_number" "$name"
    else
        printf 'not ok %d - %s does not wire sysext-lodge-accounts-guard.sh in FinalizeScripts=\n' \
            "$test_number" "$name"
        failures=$((failures + 1))
    fi
done

extra=0
for config in "$root"/mkosi.images/*/mkosi.conf; do
    name=${config#"$root"/mkosi.images/}
    name=${name%%/*}
    case " $SUITE " in
        *" $name "*) continue ;;
    esac
    if grep -Fq 'sysext-lodge-accounts-guard.sh' "$config"; then
        echo "# $name wires the guard but is not a suite sysext"
        extra=$((extra + 1))
    fi
done
test_number=$((test_number + 1))
if ((extra == 0)); then
    echo "ok $test_number - only the five suite sysexts wire the guard"
else
    echo "not ok $test_number - $extra sysexts outside the suite wire the guard"
    failures=$((failures + 1))
fi

echo
echo "# Results: $((test_number - failures)) passed, $failures failed, $test_number total"
((failures == 0))
