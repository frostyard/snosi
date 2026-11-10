#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Finalize script for the five Lodge suite sysexts (lodge, notesd, maild,
# porterd, readd): fail the build if the delta breaks the account contract of
# the Lodge suite. Lodge's own sysusers line creates
# the system user lodge; a Lodge app daemon resolves that user at start, and a
# unit may name an account only if the delta declares it.
#
# Why (snosi#1245): lodgeapp.LoadEnv in frostyard/lodge resolves the system
# user lodge at start. maild 0.2.0 and notesd 0.2.0 declared only the GROUP
# lodge in their sysusers.d file. With `updex features enable maild notesd
# --now` and without the lodge feature, frostmail.service crash-looped with
# "unknown user lodge" and the notesd units hit their start limits.
# systemd-sysusers creates no user for a group line, so each app sysext must
# declare the user itself.
#
# $BUILDROOT is the delta, and $IMAGE_ID names the sysext. The rules are:
#
#  1. A delta that ships usr/lib/sysusers.d/lodge.conf (the lodge sysext
#     itself) holds LODGE_USER_LINE as an exact full line there.
#  2. A delta that ships a Lodge app manifest (usr/share/lodge/apps/*/app.json)
#     holds LODGE_USER_LINE as an exact full line in at least one of its
#     usr/lib/sysusers.d/*.conf files. The line is byte-identical to lodge's
#     own, so the first merge of any suite sysext creates the same account.
#  3. Every User=, Group=, SocketUser= and SocketGroup= value of the delta's
#     system units is declared by the delta's sysusers.d files: a user by a u
#     line or the first field of an m line, a group by a u or g line or the
#     second field of an m line. root, numeric ids, specifiers and an empty
#     value are skipped, and so is a unit with DynamicUser=yes.
set -euo pipefail

ID=${IMAGE_ID:?sysext-lodge-accounts-guard: IMAGE_ID not set}
DELTA=${BUILDROOT:?sysext-lodge-accounts-guard: BUILDROOT not set}
SYSUSERS=usr/lib/sysusers.d
SYSTEM_UNITS=usr/lib/systemd/system
LODGE_CONF=$SYSUSERS/lodge.conf
APPS=usr/share/lodge/apps
# The exact line lodge's own usr/lib/sysusers.d/lodge.conf ships. Every suite
# sysext repeats it unchanged, so all of them declare one account.
LODGE_USER_LINE="u lodge - \"lodge, the tailnet web shell for frostyard's apps\" /var/lib/lodge"

die() {
    echo "sysext-lodge-accounts-guard: $*" >&2
    exit 1
}

[[ -d $DELTA ]] || die "delta buildroot $DELTA is not a directory"

shopt -s nullglob dotglob

units=()
for file in "$DELTA/$SYSTEM_UNITS"/*; do
    [[ $file == *.service || $file == *.socket ]] || continue
    [[ -f $file ]] || continue
    units+=("$file")
done

apps=()
for file in "$DELTA/$APPS"/*/app.json; do
    [[ -f $file ]] || continue
    apps+=("$file")
done

sysusers=()
for file in "$DELTA/$SYSUSERS"/*.conf; do
    [[ -f $file ]] || continue
    sysusers+=("$file")
done

has_lodge_user_line() { # file
    grep -Fxq -- "$LODGE_USER_LINE" "$1"
}

# 1. The lodge sysext itself.
if [[ -f $DELTA/$LODGE_CONF ]] && ! has_lodge_user_line "$DELTA/$LODGE_CONF"; then
    die "/$LODGE_CONF of $ID has no line: $LODGE_USER_LINE (lodge's own sysusers line, byte for byte)"
fi

# 2. A Lodge app sysext.
if ((${#apps[@]} > 0)); then
    found=0
    for file in "${sysusers[@]}"; do
        if has_lodge_user_line "$file"; then
            found=1
            break
        fi
    done
    if ((found == 0)); then
        die "$ID ships the Lodge app ${apps[0]#"$DELTA"/} but no /$SYSUSERS/*.conf declares user lodge with lodge's own line: $LODGE_USER_LINE. The app daemon resolves the system user lodge at start, so without the line its unit fails at start while the lodge feature is not enabled (snosi#1245; docs/design/sysexts.md)"
    fi
fi

if ((${#units[@]} == 0)); then
    if ((${#apps[@]} == 0)) && [[ ! -f $DELTA/$LODGE_CONF ]]; then
        echo "sysext-lodge-accounts-guard: $ID OK (no Lodge app, no lodge.conf, no system units)"
    else
        echo "sysext-lodge-accounts-guard: $ID OK (system units: 0, sysusers files: ${#sysusers[@]}, Lodge apps: ${#apps[@]})"
    fi
    exit 0
fi

# 3. Every account the system units name.
declare -A users=() groups=()
for file in "${sysusers[@]}"; do
    while IFS= read -r line; do
        read -ra fields <<<"$line"
        type=${fields[0]:-}
        name=${fields[1]:-}
        [[ -n $name ]] || continue
        case $type in
            u)
                users[$name]=1
                groups[$name]=1
                ;;
            g) groups[$name]=1 ;;
            m)
                group=${fields[2]:-}
                [[ -n $group ]] || continue
                users[$name]=1
                groups[$group]=1
                ;;
        esac
    done < <(grep -Ev '^[[:space:]]*(#|$)' "$file" || true)
done

# One KIND<TAB>NAME line per account the unit names.
unit_accounts() { # file
    awk '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            eq = index(line, "=")
            if (eq == 0) next
            key = substr(line, 1, eq - 1)
            sub(/[[:space:]]+$/, "", key)
            if (key !~ /^(User|Group|SocketUser|SocketGroup)$/) next
            value = substr(line, eq + 1)
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            if (value == "") next
            kind = (key ~ /^(User|SocketUser)$/) ? "user" : "group"
            printf "%s\t%s\n", kind, value
        }
    ' "$1"
}

checked=0
for file in "${units[@]}"; do
    unit=${file#"$DELTA"/}
    if grep -Eqi '^[[:space:]]*DynamicUser[[:space:]]*=[[:space:]]*(yes|true|1|on)[[:space:]]*$' "$file"; then
        continue
    fi
    checked=$((checked + 1))
    while IFS=$'\t' read -r kind name; do
        [[ -n $name ]] || continue
        [[ $name != root ]] || continue
        [[ ! $name =~ ^[0-9]+$ ]] || continue
        [[ $name != *%* ]] || continue
        if [[ $kind == user ]]; then
            [[ -n ${users[$name]:-} ]] || die "/$unit names user $name, which no /$SYSUSERS/*.conf in the delta declares: add a u line for it (or an m line whose first field is $name)"
        else
            [[ -n ${groups[$name]:-} ]] || die "/$unit names group $name, which no /$SYSUSERS/*.conf in the delta declares: add a g or u line for it (or an m line whose second field is $name)"
        fi
    done < <(unit_accounts "$file")
done

echo "sysext-lodge-accounts-guard: $ID OK (system units: $checked, sysusers files: ${#sysusers[@]}, Lodge apps: ${#apps[@]})"
