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
#  3. Every account the delta's system units name is declared by the delta's
#     sysusers.d files, and no drop-in sets an account key.
#     - Drop-ins: this guard does not emulate systemd's drop-in merging. That
#       merge takes in <unit>.d, a template's <template>.d, a type-wide
#       service.d or socket.d, a prefix directory such as frost-.service.d,
#       and the same file name in several of them in a precedence order. A
#       delta that sets an account key in any of them fails closed: the key
#       belongs in the unit file. Every *.conf file in every *.d directory
#       directly under usr/lib/systemd/system is read, and any of User=,
#       Group=, SupplementaryGroups=, DynamicUser=, SocketUser= or
#       SocketGroup= in any section fails the build. A drop-in without those
#       keys, such as the multi-user.target.d Upholds= drop-ins, passes.
#     - Units: each regular *.service and *.socket file directly under
#       usr/lib/systemd/system, templates included. One file is parsed as
#       systemd.syntax(7) reads it: a line whose first non-blank character is
#       # or ; is a comment and is dropped, also inside a continued value; a
#       line that ends with \ joins the next non-comment line, and the \ is
#       replaced by a space. Keys count only in their own section: User=,
#       Group=, SupplementaryGroups= and DynamicUser= in [Service], SocketUser=
#       and SocketGroup= in [Socket]. Of the scalar keys the last assignment
#       wins and an empty value unsets it; SupplementaryGroups= accumulates and
#       an empty assignment clears the list. An effective DynamicUser= of yes,
#       true, 1 or on skips the User= and Group= checks only: systemd creates
#       no supplementary groups for a dynamic user either, but the socket keys
#       are independent of it.
#     A user is declared by a u or u! line or the first field of an m line, a
#     group by a u, u! or g line or the second field of an m line. An empty
#     value, root, a numeric id and a value with a % specifier are skipped.
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

# 3. Every account the system units name, and no account key in a drop-in.
# One parser for both file kinds, because the comment and continuation rules
# are the same. mode=dropin prints the account keys the file sets, and
# mode=unit prints the effective settings of the unit file.
unit_parser() { # mode file
    awk -v mode="$1" '
        function trim(text) {
            sub(/^[[:space:]]+/, "", text)
            sub(/[[:space:]]+$/, "", text)
            return text
        }
        function handle(line,   text, bracket, eq, key, value) {
            text = trim(line)
            if (text == "") return
            if (text ~ /^\[/) {
                bracket = index(text, "]")
                if (bracket > 0) section = substr(text, 2, bracket - 2)
                return
            }
            eq = index(text, "=")
            if (eq == 0) return
            key = trim(substr(text, 1, eq - 1))
            value = trim(substr(text, eq + 1))
            if (mode == "dropin") {
                if (key ~ /^(User|Group|SupplementaryGroups|DynamicUser|SocketUser|SocketGroup)$/) print key
                return
            }
            if (section == "Service") {
                if (key == "User") user = value
                else if (key == "Group") group = value
                else if (key == "SupplementaryGroups")
                    sup = (value == "") ? "" : ((sup == "") ? value : sup " " value)
                else if (key == "DynamicUser") dynamic = value
            } else if (section == "Socket") {
                if (key == "SocketUser") socketuser = value
                else if (key == "SocketGroup") socketgroup = value
            }
        }
        {
            line = $0
            if (trim(line) ~ /^[#;]/) next
            if (joining) {
                line = build line
                joining = 0
                build = ""
            }
            if (line ~ /\\$/) {
                sub(/\\$/, " ", line)
                build = line
                joining = 1
                next
            }
            handle(line)
        }
        END {
            if (joining) handle(build)
            if (mode == "dropin") exit 0
            printf "dynamic\t%s\n", dynamic
            printf "user\t%s\n", user
            printf "group\t%s\n", group
            printf "sup\t%s\n", sup
            printf "socketuser\t%s\n", socketuser
            printf "socketgroup\t%s\n", socketgroup
        }
    ' "$2"
}

dropins=()
for dir in "$DELTA/$SYSTEM_UNITS"/*.d; do
    [[ -d $dir ]] || continue
    for file in "$dir"/*.conf; do
        [[ -f $file ]] || continue
        dropins+=("$file")
    done
done

for file in "${dropins[@]}"; do
    key=$(unit_parser dropin "$file")
    if [[ -n $key ]]; then
        rel=${file#"$DELTA"/}
        die "/$rel sets $key= in a drop-in; this guard checks accounts only in unit files, so set it in the unit file (snosi#1245; ADR-0035)"
    fi
done

declare -A users=() groups=()
for file in "${sysusers[@]}"; do
    while IFS= read -r line; do
        read -ra fields <<<"$line"
        type=${fields[0]:-}
        name=${fields[1]:-}
        [[ -n $name ]] || continue
        case $type in
            'u!' | u)
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

units=()
for file in "$DELTA/$SYSTEM_UNITS"/*.service "$DELTA/$SYSTEM_UNITS"/*.socket; do
    [[ -f $file ]] || continue
    units+=("$file")
done

for file in "${units[@]}"; do
    name=${file##*/}
    declare -A setting=()
    while IFS=$'\t' read -r key value; do
        setting[$key]=$value
    done < <(unit_parser unit "$file")
    skip=0
    dynamic=${setting[dynamic]:-}
    case ${dynamic,,} in
        yes | true | 1 | on) skip=1 ;;
    esac
    accounts=()
    if ((skip == 0)); then
        if [[ -n ${setting[user]:-} ]]; then accounts+=("user"$'\t'"${setting[user]}"); fi
        if [[ -n ${setting[group]:-} ]]; then accounts+=("group"$'\t'"${setting[group]}"); fi
    fi
    read -ra supplementary <<<"${setting[sup]:-}"
    for account in "${supplementary[@]}"; do
        accounts+=("group"$'\t'"$account")
    done
    if [[ -n ${setting[socketuser]:-} ]]; then accounts+=("user"$'\t'"${setting[socketuser]}"); fi
    if [[ -n ${setting[socketgroup]:-} ]]; then accounts+=("group"$'\t'"${setting[socketgroup]}"); fi
    for account in "${accounts[@]}"; do
        kind=${account%%$'\t'*}
        value=${account#*$'\t'}
        [[ -n $value ]] || continue
        [[ $value != root ]] || continue
        [[ ! $value =~ ^[0-9]+$ ]] || continue
        [[ $value != *%* ]] || continue
        if [[ $kind == user ]]; then
            [[ -n ${users[$value]:-} ]] || die "/$SYSTEM_UNITS/$name names user $value, which no /$SYSUSERS/*.conf in the delta declares: add a u line for it (or an m line whose first field is $value)"
        else
            [[ -n ${groups[$value]:-} ]] || die "/$SYSTEM_UNITS/$name names group $value, which no /$SYSUSERS/*.conf in the delta declares: add a g or u line for it (or an m line whose second field is $value)"
        fi
    done
done

echo "sysext-lodge-accounts-guard: $ID OK (system units: ${#units[@]}, drop-ins: ${#dropins[@]}, sysusers files: ${#sysusers[@]}, Lodge apps: ${#apps[@]})"
